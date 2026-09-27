package main

// Routing coverage for dispatch()'s kwi3 seam (sp004 Task 16, kwi3-234.16).
//
// The edge case this file exists for is "$KWI3SOCK set but dead: fall back
// to nothing and log once - NEVER send kwi3 chords to another i3". Review
// #1 of kwi3-234.16 proved it had no test that could fail: making a
// kwi3Dispatcher error fall through to d.i3.Command() left every Go test
// and the whole host-test green while a real co-resident i3's focus moved.
// Every test below counts what reached the i3 commander, so that mutant -
// and any other shape of "on error, try i3" - fails here.

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwi3rpc"
	"hotkeyd/internal/layer"
)

// fakeKwi3 is a kwi3Dispatcher with no socket: it records every command it
// was handed and answers with errFn's verdict (nil = success).
type fakeKwi3 struct {
	mu     sync.Mutex
	cmds   []string
	errFn  func(cmd string) error
	closed bool
}

func (f *fakeKwi3) Dispatch(cmd string) error {
	f.mu.Lock()
	f.cmds = append(f.cmds, cmd)
	fn := f.errFn
	f.mu.Unlock()
	if fn != nil {
		return fn(cmd)
	}
	return nil
}

func (f *fakeKwi3) Close() error {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
	return nil
}

func (f *fakeKwi3) sent() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.cmds...)
}

// newKwi3Harness is newHarness with the Kwi3 seam set - the daemon a kwi3
// session builds (main.go sets DaemonConfig.Kwi3 whenever $KWI3SOCK is
// non-empty). mark is the number of log lines NewDaemon itself wrote (its
// startup list of chords with no ft010 method), so a test can count only
// what dispatch() logged.
func newKwi3Harness(t *testing.T, k kwi3Dispatcher) (h *harness, mark int) {
	return newKwi3HarnessWith(t, func(func(string)) kwi3Dispatcher { return k })
}

// newKwi3HarnessWith builds the dispatcher from the harness's own log sink,
// so a real kwi3rpc.Client logs to the same place the daemon does - exactly
// main.go's wiring (daemonLog is passed to both).
func newKwi3HarnessWith(t *testing.T, mk func(log func(string)) kwi3Dispatcher) (h *harness, mark int) {
	t.Helper()
	h = newHarness(t)
	k := mk(h.logger.log)
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
	if n := len(h.i3c.commandsSent()); n != 0 {
		t.Fatalf("NewDaemon itself sent %d i3 command(s) - the counts below would be meaningless", n)
	}
	return h, len(h.logger.all())
}

// logsSince returns the log lines written after mark.
func logsSince(h *harness, mark int) []string {
	return h.logger.all()[mark:]
}

// chords are three ordinary movement chords from the real table - each one
// a thing a co-resident i3 would happily act on if it ever received it.
var chords = []string{"focus left", "focus right", "move up"}

func dispatchChords(h *harness) {
	for _, c := range chords {
		h.dae.dispatch(bind.Command(c))
	}
}

// A dead $KWI3SOCK, through the REAL kwi3rpc.Client (not a fake), wired the
// way main.go wires it: both the client and the daemon log to the same
// place. Several chords: zero reach i3, and exactly one line is logged.
func TestKwi3Dispatch_DeadSocket_NeverReachesI3_LogsOnce(t *testing.T) {
	dead := filepath.Join(t.TempDir(), "kwi3-gone.sock")
	h, mark := newKwi3HarnessWith(t, func(log func(string)) kwi3Dispatcher {
		return kwi3rpc.New(dead, kwi3rpc.WithLog(log))
	})

	dispatchChords(h)
	dispatchChords(h)

	if got := h.i3c.commandsSent(); len(got) != 0 {
		t.Fatalf("a kwi3 chord with $KWI3SOCK dead reached i3: %v", got)
	}
	lines := logsSince(h, mark)
	if len(lines) != 1 {
		t.Fatalf("want exactly one log line across %d dropped chords (log once), got %d: %q",
			2*len(chords), len(lines), lines)
	}
	if !strings.Contains(lines[0], dead) {
		t.Fatalf("the one log line should name the dead socket %s, got %q", dead, lines[0])
	}
}

// The same routing guarantee against every error SHAPE a kwi3Dispatcher can
// return, through a fake: a transport error, kwi3's -32001 "no such
// window", and a verb Translate cannot map. Each is logged naming the
// chord, nothing reaches i3, and the daemon keeps dispatching (the next
// chord still reaches kwi3).
func TestKwi3Dispatch_ErrorNeverFallsBackToI3(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want string // a substring the log line must carry
	}{
		{"transport", errors.New("kwi3rpc: read from /x: EOF"), "EOF"},
		{"rpc -32001", &kwi3rpc.RPCError{Code: -32001, Message: "no such window"}, "-32001"},
		{"unsupported verb", &kwi3rpc.UnsupportedVerbError{Cmd: "sticky toggle", Why: "kwi3 has no sticky"}, "sticky"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			k := &fakeKwi3{errFn: func(string) error { return tc.err }}
			h, mark := newKwi3Harness(t, k)

			dispatchChords(h)

			if got := h.i3c.commandsSent(); len(got) != 0 {
				t.Fatalf("kwi3 answered %v and the chord went to i3 instead: %v", tc.err, got)
			}
			if got := k.sent(); len(got) != len(chords) {
				t.Fatalf("daemon stopped dispatching after an error: kwi3 got %v, want all of %v", got, chords)
			}
			lines := logsSince(h, mark)
			if len(lines) != len(chords) {
				t.Fatalf("want one log line per failed chord (%d), got %d: %q", len(chords), len(lines), lines)
			}
			for i, l := range lines {
				if !strings.Contains(l, chords[i]) || !strings.Contains(l, tc.want) {
					t.Fatalf("log line %d should name chord %q and %q, got %q", i, chords[i], tc.want, l)
				}
			}
		})
	}
}

// Unsupported verb through the REAL client: Translate refuses before any
// dial, so nothing is sent anywhere - not to kwi3, and not to i3.
func TestKwi3Dispatch_RealClient_UnsupportedVerb_NeverReachesI3(t *testing.T) {
	sock := filepath.Join(t.TempDir(), "never-dialled.sock")
	h, mark := newKwi3HarnessWith(t, func(log func(string)) kwi3Dispatcher {
		return kwi3rpc.New(sock, kwi3rpc.WithLog(log))
	})

	h.dae.dispatch(bind.Command("sticky toggle"))

	if got := h.i3c.commandsSent(); len(got) != 0 {
		t.Fatalf("an unsupported kwi3 verb reached i3: %v", got)
	}
	lines := logsSince(h, mark)
	if len(lines) != 1 || !strings.Contains(lines[0], "sticky toggle") {
		t.Fatalf("want one log line naming the chord, got %q", lines)
	}
}

// Success: kwi3 gets the command exactly once, i3 gets nothing, nothing is
// logged.
func TestKwi3Dispatch_Success_OnlyKwi3(t *testing.T) {
	k := &fakeKwi3{}
	h, mark := newKwi3Harness(t, k)

	dispatchChords(h)

	if got := h.i3c.commandsSent(); len(got) != 0 {
		t.Fatalf("kwi3 session sent to i3: %v", got)
	}
	if got := k.sent(); strings.Join(got, "|") != strings.Join(chords, "|") {
		t.Fatalf("kwi3 got %v, want exactly %v", got, chords)
	}
	if lines := logsSince(h, mark); len(lines) != 0 {
		t.Fatalf("a successful dispatch logged: %q", lines)
	}
}

// $KWI3SOCK unset (DaemonConfig.Kwi3 nil, as newHarness builds it): the i3
// path exactly as before - each chord reaches i3 once, in order.
func TestKwi3Dispatch_NoKwi3_I3PathUnchanged(t *testing.T) {
	h := newHarness(t)

	dispatchChords(h)

	if got := h.i3c.commandsSent(); strings.Join(got, "|") != strings.Join(chords, "|") {
		t.Fatalf("i3 session: i3 got %v, want exactly %v", got, chords)
	}
}

// The same guarantee through Run's real key path (press -> engine ->
// dispatchAll), not only a direct dispatch() call.
func TestKwi3Dispatch_KeyPressDuringOutage_NeverReachesI3(t *testing.T) {
	k := &fakeKwi3{errFn: func(string) error { return errors.New("kwi3rpc: dial /x: connection refused") }}
	h, _ := newKwi3Harness(t, k)
	h.grabs.wanted = []string{"a"}
	h.grabs.active = map[string]GrabbedChord{"a": {Code: 38, Mask: 0}}

	h.events <- xiKeyEvent(xiEvtKeyPress, 7, 38, 0, false)

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)

	if got := k.sent(); len(got) != 1 || got[0] != "test command a" {
		t.Fatalf("the key press never reached kwi3: %v", got)
	}
	if got := h.i3c.commandsSent(); len(got) != 0 {
		t.Fatalf("a key press during a kwi3 outage reached i3: %v", got)
	}
}
