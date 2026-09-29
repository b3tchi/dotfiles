package main

// kwi3-55l.25: on a kwi3 session hotkeyd reports its active layer to kwi3 as
// `mode.set {name}` (ft010), so kwi3 can paint its focus ring in that
// mode's modeFrame colour. What is measured is what reached a real unix
// socket speaking kwi3's wire shape (NDJSON JSON-RPC 2.0) - not the
// reporter's internals - and that an i3 session gets nothing at all.
//
// kwi3-55l.29: on Jan's table `resize` is a held-modifier SUB-LAYER inside
// the `nav` layer (layer=nav mod=resize), not a layer of its own, so
// reporting only State.Layer never sends kwi3 "resize" at all and the ring
// stays whatever colour `nav` painted it (none - `nav` has no modeFrame
// entry). The reported name is now the EFFECTIVE mode: the active mod
// sub-layer's label when one is held (State.Mod, e.g. "resize" - the exact
// key config.js's `modeFrame` uses), else the layer name - matching
// bind.Layer.Mods' label convention (internal/bind/bind.go) and the state
// feed's own wire shape (layer + mod, publisher.go's wireState).

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"hotkeyd/internal/kwi3rpc"
	"hotkeyd/internal/layer"
)

// modeServer is a fake kwi3 rpc socket that records every request's method
// and params.name, and answers each (or, with hang set, never answers).
type modeServer struct {
	addr  string
	ln    net.Listener
	mu    sync.Mutex
	reqs  []string // "method name"
	hang  bool
	drop  int // kwi3-55l.28: the next `drop` requests are read, recorded and answered by closing the connection
	conns int
	live  []net.Conn
}

func newModeServer(t *testing.T, hang bool) *modeServer {
	t.Helper()
	return newModeServerAt(t, filepath.Join(t.TempDir(), "kwi3.rpc.sock"), hang)
}

func newModeServerAt(t *testing.T, addr string, hang bool) *modeServer {
	t.Helper()
	ln, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatalf("listen: %s", err)
	}
	s := &modeServer{addr: addr, ln: ln, hang: hang}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			s.mu.Lock()
			s.conns++
			s.live = append(s.live, c)
			s.mu.Unlock()
			go s.serve(c)
		}
	}()
	t.Cleanup(s.stop)
	return s
}

// stop is kwi3 exiting: the listener and every open connection close, and
// the socket path is removed so a fresh server can bind it.
func (s *modeServer) stop() {
	s.ln.Close()
	s.mu.Lock()
	for _, c := range s.live {
		c.Close()
	}
	s.live = nil
	s.mu.Unlock()
	os.Remove(s.addr)
}

func (s *modeServer) setDrop(n int) {
	s.mu.Lock()
	s.drop = n
	s.mu.Unlock()
}

func (s *modeServer) serve(c net.Conn) {
	defer c.Close()
	r := bufio.NewReader(c)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		var req struct {
			ID     int64  `json:"id"`
			Method string `json:"method"`
			Params struct {
				Name string `json:"name"`
			} `json:"params"`
		}
		if json.Unmarshal(line, &req) != nil {
			continue
		}
		s.mu.Lock()
		s.reqs = append(s.reqs, req.Method+" "+req.Params.Name)
		hang := s.hang
		drop := s.drop > 0
		if drop {
			s.drop--
		}
		s.mu.Unlock()
		if drop {
			return // deferred Close: the caller's read fails, nothing was acknowledged
		}
		if hang {
			continue
		}
		reply, _ := json.Marshal(map[string]interface{}{
			"jsonrpc": "2.0", "id": req.ID, "result": map[string]string{"name": req.Params.Name}})
		c.Write(append(reply, '\n'))
	}
}

func (s *modeServer) got() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.reqs...)
}

// waitFor polls the server's record until it has n requests or 2s pass.
func (s *modeServer) waitFor(t *testing.T, n int) []string {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if g := s.got(); len(g) >= n {
			return g
		}
		time.Sleep(5 * time.Millisecond)
	}
	return s.got()
}

type recPublisher struct {
	mu  sync.Mutex
	got []layer.State
}

func (r *recPublisher) Publish(st layer.State) {
	r.mu.Lock()
	r.got = append(r.got, st)
	r.mu.Unlock()
}

func TestKwi3ModeReportsLayerChanges(t *testing.T) {
	srv := newModeServer(t, false)
	rec := &recPublisher{}
	var logs []string
	var logMu sync.Mutex
	logf := func(s string) { logMu.Lock(); logs = append(logs, s); logMu.Unlock() }

	pub, closer := enginePublisher(rec, srv.addr, logf)
	if closer == nil {
		t.Fatal("kwi3 session: expected a closer for the mode reporter")
	}
	defer closer.Close()

	// Startup: the engine's own starting layer, so a kwi3 left in "resize"
	// by a previous hotkeyd that died mid-mode is put back.
	if g := srv.waitFor(t, 1); len(g) < 1 || g[0] != "mode.set default" {
		t.Fatalf("startup: want [mode.set default], got %v", g)
	}

	// Plain layer change, no mod involved.
	pub.Publish(layer.State{Layer: "screenshot"})
	srv.waitFor(t, 2)
	pub.Publish(layer.State{Layer: layer.DefaultLayer})
	g := srv.waitFor(t, 3)
	time.Sleep(50 * time.Millisecond)
	g = srv.got()
	want := []string{"mode.set default", "mode.set screenshot", "mode.set default"}
	if strings.Join(g, "|") != strings.Join(want, "|") {
		t.Fatalf("plain layer change: want %v, got %v", want, g)
	}

	// The state feed (bars) still gets EVERY state.
	rec.mu.Lock()
	n := len(rec.got)
	rec.mu.Unlock()
	if n != 2 {
		t.Fatalf("tee: the wrapped publisher should see both states, saw %d", n)
	}
	logMu.Lock()
	defer logMu.Unlock()
	if len(logs) != 0 {
		t.Fatalf("a healthy kwi3 should log nothing, got %v", logs)
	}
}

// TestKwi3ModeReportsEffectiveModSubLayer is kwi3-55l.29: on Jan's table
// `resize` is a held-modifier sub-layer INSIDE `nav` (layer=nav mod=resize),
// not its own layer, so kwi3 must be told the EFFECTIVE mode - the mod
// label when one is held, else the layer name - not the bare layer name.
func TestKwi3ModeReportsEffectiveModSubLayer(t *testing.T) {
	srv := newModeServer(t, false)
	rec := &recPublisher{}
	logf := func(s string) { t.Fatalf("unexpected log: %s", s) }
	pub, closer := enginePublisher(rec, srv.addr, logf)
	defer closer.Close()

	srv.waitFor(t, 1) // startup: mode.set default

	// Plain layer change into nav, no mod held yet: effective mode is the
	// layer name itself.
	pub.Publish(layer.State{Layer: "nav"})
	srv.waitFor(t, 2)

	// Alt held: layer=nav mod=resize (the live log line this task is named
	// after: "transition layer=nav->nav mod=none->resize"). The EFFECTIVE
	// mode is the mod's label, "resize" - config.js's modeFrame key.
	pub.Publish(layer.State{Layer: "nav", Mod: "resize"})
	srv.waitFor(t, 3)

	// Duplicate: same effective mode (layer AND mod both unchanged) must
	// not be re-sent - the .25 dedup rule survives, now keyed on the
	// effective name rather than the bare layer.
	pub.Publish(layer.State{Layer: "nav", Mod: "resize"})
	time.Sleep(50 * time.Millisecond)
	if g := srv.got(); len(g) != 3 {
		t.Fatalf("duplicate effective mode must not be resent: got %v", g)
	}

	// Alt released, still in nav: effective mode reverts to the layer name.
	pub.Publish(layer.State{Layer: "nav"})
	srv.waitFor(t, 4)

	// Escape back to the default layer.
	pub.Publish(layer.State{Layer: layer.DefaultLayer})
	g := srv.waitFor(t, 5)
	time.Sleep(50 * time.Millisecond)
	g = srv.got()
	want := []string{
		"mode.set default", // startup
		"mode.set nav",     // plain layer change
		"mode.set resize",  // mod sub-layer engaged
		"mode.set nav",     // mod released
		"mode.set default", // Escape to default
	}
	if strings.Join(g, "|") != strings.Join(want, "|") {
		t.Fatalf("effective-mode sequence: want %v, got %v", want, g)
	}

	// The state feed (bars) still gets every Publish call, duplicate
	// included - only the kwi3 report is deduplicated.
	rec.mu.Lock()
	n := len(rec.got)
	rec.mu.Unlock()
	if n != 5 {
		t.Fatalf("tee: the wrapped publisher should see all 5 Publish calls, saw %d", n)
	}
}

func TestKwi3ModeNeverBlocksOnAWedgedKwi3(t *testing.T) {
	srv := newModeServer(t, true) // reads requests, never replies
	pub, closer := enginePublisher(nil, srv.addr, func(string) {})
	defer closer.Close()
	srv.waitFor(t, 1)
	start := time.Now()
	for i := 0; i < 50; i++ {
		if i%2 == 0 {
			pub.Publish(layer.State{Layer: "resize"})
		} else {
			pub.Publish(layer.State{Layer: layer.DefaultLayer})
		}
	}
	if d := time.Since(start); d > 100*time.Millisecond {
		t.Fatalf("Publish blocked behind a wedged kwi3: 50 layer changes took %s", d)
	}
}

func TestKwi3ModeUnreachableLogsOnce(t *testing.T) {
	addr := filepath.Join(t.TempDir(), "nobody.sock")
	var logs []string
	var mu sync.Mutex
	pub, closer := enginePublisher(nil, addr, func(s string) { mu.Lock(); logs = append(logs, s); mu.Unlock() })
	defer closer.Close()
	for i := 0; i < 10; i++ {
		pub.Publish(layer.State{Layer: []string{"resize", layer.DefaultLayer}[i%2]})
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if len(logs) != 1 {
		t.Fatalf("an unreachable kwi3 should cost exactly one log line, got %d: %v", len(logs), logs)
	}
}

func TestI3SessionHasNoModeReporter(t *testing.T) {
	rec := &recPublisher{}
	pub, closer := enginePublisher(rec, "", func(string) {})
	if closer != nil {
		t.Fatal("i3 session (no $KWI3SOCK): no mode reporter may exist")
	}
	if pub != layer.Publisher(rec) {
		t.Fatalf("i3 session: the state publisher must be passed through untouched, got %T", pub)
	}
	// A nil state publisher on an i3 session stays nil (engine: "no feed").
	if p, c := enginePublisher(nil, "", func(string) {}); p != nil || c != nil {
		t.Fatalf("i3 session with no state feed: want (nil, nil), got (%v, %v)", p, c)
	}
}

// fastModeRetry shrinks the reporter's retry backoff for one test.
func fastModeRetry(t *testing.T, min, max time.Duration) {
	t.Helper()
	oldMin, oldMax := modeRetryMin, modeRetryMax
	modeRetryMin, modeRetryMax = min, max
	t.Cleanup(func() { modeRetryMin, modeRetryMax = oldMin, oldMax })
}

func joined(g []string) string { return strings.Join(g, "|") }

// TestKwi3ModeRetriesAFailedCallUntilAcked is kwi3-55l.28 case (b): a
// mode.set that failed (here: kwi3 read it and hung up without answering,
// as a timeout would) used to be dropped for good - the ring stayed red
// after leaving resize until the next mode change. The CURRENT mode is
// retried with backoff until kwi3 acknowledges it.
func TestKwi3ModeRetriesAFailedCallUntilAcked(t *testing.T) {
	fastModeRetry(t, 10*time.Millisecond, 40*time.Millisecond)
	srv := newModeServer(t, false)
	pub, rep := enginePublisher(nil, srv.addr, func(string) {})
	defer rep.Close()
	srv.waitFor(t, 1) // startup default, acked

	pub.Publish(layer.State{Layer: "nav", Mod: "resize"})
	srv.waitFor(t, 2) // resize, acked

	srv.setDrop(2) // the next two mode.set calls fail
	pub.Publish(layer.State{Layer: layer.DefaultLayer})
	g := srv.waitFor(t, 5)
	time.Sleep(100 * time.Millisecond) // nothing more once acked
	g = srv.got()
	want := []string{"mode.set default", "mode.set resize",
		"mode.set default", "mode.set default", "mode.set default"}
	if joined(g) != joined(want) {
		t.Fatalf("failed call must be retried until acked, then stop:\nwant %v\ngot  %v", want, g)
	}
}

// TestKwi3ModeDedupComparesAgainstAcked is kwi3-55l.28: duplicate
// suppression keys on the last mode kwi3 ACKNOWLEDGED, not the last one
// queued. A repeat of an acked mode sends nothing; a repeat of a mode whose
// call failed is sent again at once (the backoff here is long enough that
// only the Publish itself can explain the resend).
func TestKwi3ModeDedupComparesAgainstAcked(t *testing.T) {
	fastModeRetry(t, time.Hour, time.Hour)
	srv := newModeServer(t, false)
	pub, rep := enginePublisher(nil, srv.addr, func(string) {})
	defer rep.Close()
	srv.waitFor(t, 1)

	pub.Publish(layer.State{Layer: "resize"})
	srv.waitFor(t, 2)
	pub.Publish(layer.State{Layer: "resize"}) // acked: suppressed
	time.Sleep(50 * time.Millisecond)
	if g := srv.got(); len(g) != 2 {
		t.Fatalf("repeat of an acked mode must not be resent: %v", g)
	}

	srv.setDrop(1)
	pub.Publish(layer.State{Layer: layer.DefaultLayer}) // fails
	srv.waitFor(t, 3)
	time.Sleep(50 * time.Millisecond)
	pub.Publish(layer.State{Layer: layer.DefaultLayer}) // not acked: sent again
	g := srv.waitFor(t, 4)
	time.Sleep(50 * time.Millisecond)
	g = srv.got()
	want := []string{"mode.set default", "mode.set resize", "mode.set default", "mode.set default"}
	if joined(g) != joined(want) {
		t.Fatalf("dedup against acked:\nwant %v\ngot  %v", want, g)
	}
}

// TestKwi3ModeResentAfterKwi3Restart is kwi3-55l.28 case (a): kwi3
// restarts while hotkeyd sits in resize; the new kwi3 starts in "default".
// When the chord client's connection is re-established (its OnConnect hook,
// wired to the reporter's Resync in main.go) the reporter resends its
// CURRENT mode to the new kwi3, even though the old kwi3 had acked it.
func TestKwi3ModeResentAfterKwi3Restart(t *testing.T) {
	fastModeRetry(t, 10*time.Millisecond, 40*time.Millisecond)
	srv := newModeServer(t, false)
	pub, rep := enginePublisher(nil, srv.addr, func(string) {})
	defer rep.Close()
	chords := kwi3rpc.New(srv.addr, kwi3rpc.WithOnConnect(rep.Resync))
	defer chords.Close()

	srv.waitFor(t, 1)
	pub.Publish(layer.State{Layer: "nav", Mod: "resize"})
	srv.waitFor(t, 2)

	srv.stop() // kwi3 exits
	srv2 := newModeServerAt(t, srv.addr, false)

	// The first chord after the restart dials the new kwi3.
	if _, err := chords.Call("workspace.list", nil); err != nil {
		t.Fatalf("chord after restart: %s", err)
	}
	g := srv2.waitFor(t, 2)
	time.Sleep(50 * time.Millisecond)
	g = srv2.got()
	sawResize := false
	for _, r := range g {
		if r == "mode.set resize" {
			sawResize = true
		} else if r != "workspace.list " {
			t.Fatalf("new kwi3 got an unexpected request %q (all: %v)", r, g)
		}
	}
	if !sawResize {
		t.Fatalf("the restarted kwi3 must be told the current mode: got %v", g)
	}
}
