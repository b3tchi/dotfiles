package main

// kwi3-55l.25: on a kwi3 session hotkeyd reports its active layer to kwi3 as
// `mode.set {name}` (ft010), so kwi3 can paint its focus ring in that
// mode's modeFrame colour. What is measured is what reached a real unix
// socket speaking kwi3's wire shape (NDJSON JSON-RPC 2.0) - not the
// reporter's internals - and that an i3 session gets nothing at all.

import (
	"bufio"
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

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
	conns int
}

func newModeServer(t *testing.T, hang bool) *modeServer {
	t.Helper()
	addr := filepath.Join(t.TempDir(), "kwi3.rpc.sock")
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
			s.mu.Unlock()
			go s.serve(c)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return s
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
		s.mu.Unlock()
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

	pub.Publish(layer.State{Layer: "resize"})
	srv.waitFor(t, 2)
	// A held-modifier sublayer change inside the same layer is not a mode change.
	pub.Publish(layer.State{Layer: "resize", Mod: "Mod1"})
	pub.Publish(layer.State{Layer: layer.DefaultLayer})
	g := srv.waitFor(t, 3)
	time.Sleep(50 * time.Millisecond)
	g = srv.got()
	want := []string{"mode.set default", "mode.set resize", "mode.set default"}
	if strings.Join(g, "|") != strings.Join(want, "|") {
		t.Fatalf("mode.set sequence: want %v, got %v", want, g)
	}

	// The state feed (bars) still gets EVERY state, Mod changes included.
	rec.mu.Lock()
	n := len(rec.got)
	rec.mu.Unlock()
	if n != 3 {
		t.Fatalf("tee: the wrapped publisher should see all 3 states, saw %d", n)
	}
	logMu.Lock()
	defer logMu.Unlock()
	if len(logs) != 0 {
		t.Fatalf("a healthy kwi3 should log nothing, got %v", logs)
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
