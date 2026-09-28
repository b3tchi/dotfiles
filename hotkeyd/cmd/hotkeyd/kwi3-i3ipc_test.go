package main

// kwi3-55l.22: ~/.local/state/hotkeyd-40.log (a real kwi3 session, :40,
// $KWI3SOCK set, commands dispatched via kwi3rpc) carried 8841 lines of
// "hotkeyd: i3: i3 ipc: resolving socket path: i3 --get-socketpath: exit
// status 1" -- measured at one line roughly every 5s per running
// hotkeyd process (1768 lines / 8875s elapsed on the daemon's own
// `--display :40` instance -- internal/i3's reconnectBackoff is exactly
// 5s, so this is that backoff firing, not a tight loop). Root cause:
// main.go's run() constructed a real i3.Client UNCONDITONALLY (kwi3Sock
// checked only for effectiveBinds/daeCfg.Kwi3, never for whether an
// i3.Client should exist at all), and NewDaemon's wireI3Mode()
// unconditionally called Subscribe("mode") + BindingState() on it, with
// pumpI3() unconditionally calling PollEvents() every run-loop iteration
// (every X event AND every idle tick) -- each of those three i3.Client
// methods dials through connectLocked(), which resolves the i3 socket
// path via `i3 --get-socketpath` whenever not already connected, and
// retries at most once per reconnectBackoff (5s) forever since a kwi3
// display never has an i3 to answer it. i3 "mode" is also an i3-only
// concept -- kwi3 has no modes, the same reason kwi3rpc.Translate already
// refuses "sticky toggle"/scratchpad chords by name (kwi3translate_test.go)
// -- so there is nothing to subscribe to on a kwi3 session even in
// principle.
//
// This file proves the fix at the Daemon level, gated on d.kwi3 (the same
// $KWI3SOCK-derived signal that already selects the kwi3rpc dispatch seam
// in dispatch(), and Kwi3OnlyBinds via effectiveBinds in main.go) rather
// than on d.i3 happening to be nil -- so the guard holds even in
// kwi3dispatch_test.go's own harness, which deliberately wires a
// non-nil fakeI3Client ALONGSIDE Kwi3 to test dispatch()'s routing. A
// second test proves main.go's own half of the fix (no i3.Client
// constructed at all for a kwi3 session) is safe on the Daemon side: a
// genuinely nil d.i3 must not panic wireI3Mode/pumpI3/shutdown.
//
// "hotkeyd state-tail" processes (pgrep -a hotkeyd on the live :40
// session) are NOT part of this bug: statetail.go's stateTail() dials
// only the daemon's own layer-state unix socket (layer.SocketPath) --
// there is no i3.Client, no i3SocketResolver, and no exec.Command
// anywhere in that code path, checked by inspection (statetail.go)
// rather than restated here as a test, since there is no i3 IPC call
// site in that file to assert never fired.

import (
	"os"
	"syscall"
	"testing"
	"time"

	"hotkeyd/internal/layer"
	"hotkeyd/internal/x11"
)

// newKwi3SessionHarness builds a Daemon with BOTH a live fakeI3Client and
// Kwi3 wired, in exactly one NewDaemon() call -- deliberately not reusing
// newKwi3Harness/newKwi3HarnessWith (kwi3dispatch_test.go), which build a
// PLAIN i3 daemon first (via newHarness) and then a second, real one on top
// of the same h.i3c: that first, throwaway construction legitimately calls
// Subscribe/BindingState on h.i3c (it has no Kwi3 set), which would pollute
// exactly the counters this file's tests assert on. A single construction
// here means every call recorded on h.i3c came from the kwi3-session
// Daemon under test, nothing else.
func newKwi3SessionHarness(t *testing.T, k kwi3Dispatcher) *harness {
	t.Helper()
	h := &harness{
		events:    make(chan x11.Event, 8),
		i3c:       &fakeI3Client{},
		grabs:     &fakeGrabs{active: map[string]GrabbedChord{}, wanted: []string{}},
		devices:   &fakeDevices{},
		lock:      &fakeLock{},
		pub:       &fakeCloser{},
		xConn:     &fakeCloser{},
		logger:    &fakeLogger{},
		modDown:   map[string]bool{},
		control:   make(chan controlCmd),
		ctlCloser: &fakeCloser{},
		states:    &stateRecorder{},
	}
	h.engine = layer.NewEngine(testBinds(), testLayers(), layer.Config{Mod: "Mod4", Publisher: h.states})
	h.dae = NewDaemon(DaemonConfig{
		Events:        h.events,
		I3:            h.i3c,
		Kwi3:          k,
		Grabs:         h.grabs,
		Devices:       h.devices,
		Engine:        h.engine,
		Lock:          h.lock,
		Publisher:     h.pub,
		XConn:         h.xConn,
		Control:       h.control,
		ControlCloser: h.ctlCloser,
		NewModQuery:   func() layer.ModifierDown { return func(string) (bool, error) { return false, nil } },
		Run:           func(string) error { return nil },
		Binds:         testBinds(),
		Layers:        testLayers(),
		Mod:           "Mod4",
		Display:       ":99",
		Log:           h.logger.log,
		IdleTick:      neverFiresTick,
		HoldTick:      neverFiresTick,
	})
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	return h
}

// TestWireI3Mode_Kwi3Session_NeverSubscribesOrPolls is the core regression
// test: with d.kwi3 set (main.go's signal for a kwi3 session) NewDaemon's
// own construction-time wireI3Mode() call must not touch the i3.Client at
// all -- not Subscribe, not BindingState -- even though this harness (like
// production's kwi3dispatch_test.go fixtures) wires a live fakeI3Client
// alongside it. Kills the mutant that re-guards this on "d.i3 == nil"
// instead of "d.kwi3 != nil": that version would still retry the moment
// anything (a future refactor, a test fixture) left I3 non-nil on a kwi3
// session.
func TestWireI3Mode_Kwi3Session_NeverSubscribesOrPolls(t *testing.T) {
	k := &fakeKwi3{}
	h := newKwi3SessionHarness(t, k)

	if len(h.i3c.subscribed) != 0 {
		t.Fatalf("kwi3 session subscribed to i3 events: %v (this is what dials `i3 --get-socketpath` on a display with no i3)", h.i3c.subscribed)
	}
	if n := h.i3c.bindingStateCallCount(); n != 0 {
		t.Fatalf("kwi3 session called i3 BindingState() %d time(s), want 0", n)
	}
	if !h.logger.contains("no i3 IPC client is started") {
		t.Fatalf("wireI3Mode did not log why i3 IPC was skipped on a kwi3 session; log lines: %v", h.logger.all())
	}
}

// TestPumpI3_Kwi3Session_NeverCallsPollEvents is pumpI3's own half of the
// same guard: called directly (not through Run's loop) because pumpI3 runs
// on EVERY X event and EVERY idle tick in production -- the 8841-line log
// was exactly this call, repeated for hours. Several calls prove it is not
// merely "not called yet" but structurally skipped.
func TestPumpI3_Kwi3Session_NeverCallsPollEvents(t *testing.T) {
	k := &fakeKwi3{}
	h := newKwi3SessionHarness(t, k)
	mark := len(h.logger.all())

	for i := 0; i < 20; i++ {
		h.dae.pumpI3()
	}

	if n := h.i3c.pollEventsCount(); n != 0 {
		t.Fatalf("kwi3 session called i3 PollEvents() %d time(s) across 20 pumpI3() calls, want 0 -- this is the exact retry that filled hotkeyd-40.log", n)
	}
	// pumpI3 must not add its own per-call log line (wireI3Mode already
	// explained once, at construction) -- a log line per pumpI3 call would
	// just move the flood from "i3 ipc: resolving socket path" to
	// something else at the same 5s-or-faster rate.
	if lines := logsSince(h, mark); len(lines) != 0 {
		t.Fatalf("pumpI3() logged on a kwi3 session (want silent, already explained once): %q", lines)
	}
}

// TestDaemon_Kwi3Session_NilI3Client_NeverPanics is main.go's own half of
// the fix, exercised at the Daemon level without needing Xvfb or a real
// display: run() no longer constructs an i3.Client AT ALL when $KWI3SOCK
// selects the kwi3 session (kwi3-55l.22), so DaemonConfig.I3 is a genuine
// nil interface in production, not merely a fake standing in for "no
// client". wireI3Mode, pumpI3 and shutdown's i3.Close() must all tolerate
// that without panicking -- the shutdown path in particular, since a
// naive `d.i3.Close()` with no nil guard panics on every clean exit of a
// real kwi3 session.
func TestDaemon_Kwi3Session_NilI3Client_NeverPanics(t *testing.T) {
	logger := &fakeLogger{}
	engine := layer.NewEngine(testBinds(), testLayers(), layer.Config{Mod: "Mod4"})
	k := &fakeKwi3{}

	dae := NewDaemon(DaemonConfig{
		Events:      make(chan x11.Event),
		Kwi3:        k, // I3 deliberately omitted: nil, exactly as run() wires a kwi3 session now
		Grabs:       &fakeGrabs{active: map[string]GrabbedChord{}, wanted: []string{}},
		Devices:     &fakeDevices{},
		Engine:      engine,
		Lock:        &fakeLock{},
		Publisher:   &fakeCloser{},
		XConn:       &fakeCloser{},
		NewModQuery: func() layer.ModifierDown { return func(string) (bool, error) { return false, nil } },
		Run:         func(string) error { return nil },
		Binds:       testBinds(),
		Layers:      testLayers(),
		Mod:         "Mod4",
		Display:     ":99",
		Log:         logger.log,
		IdleTick:    neverFiresTick,
		HoldTick:    neverFiresTick,
	})

	// Construction itself must not have panicked to reach here. Exercise
	// pumpI3 directly too (Run's loop calls it every iteration).
	dae.pumpI3()
	dae.pumpI3()

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(20 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	done := make(chan int, 1)
	go func() { done <- dae.Run(sig) }()
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("exit code = %d, want 0", code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return within timeout -- a nil i3.Client wedged shutdown or the run loop")
	}
}
