package kwi3rpc

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeServer is a minimal in-process kwi3 rpc socket: one unix listener,
// one connection at a time, a caller-supplied handler that decides what
// each request line gets back. Good enough to test Client without a real
// core/rpc.js anywhere - the wire shape (NDJSON, jsonrpc 2.0) is the
// contract under test, not Logic's behaviour.
type fakeServer struct {
	t        *testing.T
	addr     string
	ln       net.Listener
	mu       sync.Mutex
	handler  func(method string, params interface{}) (result interface{}, errCode int, errMsg string)
	fragment bool // if true, write the reply one byte at a time
}

func newFakeServer(t *testing.T) *fakeServer {
	t.Helper()
	dir := t.TempDir()
	addr := filepath.Join(dir, "kwi3.rpc.sock")
	ln, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatalf("listen: %s", err)
	}
	s := &fakeServer{t: t, addr: addr, ln: ln}
	s.handler = func(method string, params interface{}) (interface{}, int, string) {
		return map[string]interface{}{}, 0, ""
	}
	go s.acceptLoop()
	t.Cleanup(func() { ln.Close() })
	return s
}

func (s *fakeServer) acceptLoop() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			return
		}
		go s.serve(conn)
	}
}

func (s *fakeServer) serve(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		var req struct {
			ID     int64       `json:"id"`
			Method string      `json:"method"`
			Params interface{} `json:"params"`
		}
		if err := json.Unmarshal(line, &req); err != nil {
			continue
		}
		s.mu.Lock()
		h := s.handler
		frag := s.fragment
		s.mu.Unlock()
		result, code, msg := h(req.Method, req.Params)
		var reply map[string]interface{}
		if code != 0 {
			reply = map[string]interface{}{"jsonrpc": "2.0", "id": req.ID,
				"error": map[string]interface{}{"code": code, "message": msg}}
		} else {
			reply = map[string]interface{}{"jsonrpc": "2.0", "id": req.ID, "result": result}
		}
		out, _ := json.Marshal(reply)
		out = append(out, '\n')
		if frag {
			for _, b := range out {
				conn.Write([]byte{b})
			}
		} else {
			conn.Write(out)
		}
	}
}

func (s *fakeServer) setHandler(h func(method string, params interface{}) (interface{}, int, string)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handler = h
}

func newTestClient(t *testing.T, addr string) *Client {
	t.Helper()
	c := New(addr)
	t.Cleanup(func() { c.Close() })
	return c
}

func TestClientCallRoundTrip(t *testing.T) {
	s := newFakeServer(t)
	s.setHandler(func(method string, params interface{}) (interface{}, int, string) {
		if method != "workspace.list" {
			t.Errorf("server got method %q, want workspace.list", method)
		}
		return []interface{}{map[string]interface{}{"id": 1, "num": 1}}, 0, ""
	})
	c := newTestClient(t, s.addr)
	raw, err := c.Call("workspace.list", nil)
	if err != nil {
		t.Fatalf("Call: %s", err)
	}
	var got []map[string]interface{}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("decode result: %s", err)
	}
	if len(got) != 1 || got[0]["num"].(float64) != 1 {
		t.Fatalf("got %#v", got)
	}
}

func TestClientCallSendsParams(t *testing.T) {
	s := newFakeServer(t)
	var gotParams interface{}
	s.setHandler(func(method string, params interface{}) (interface{}, int, string) {
		gotParams = params
		return map[string]interface{}{}, 0, ""
	})
	c := newTestClient(t, s.addr)
	if _, err := c.Call("workspace.focus", map[string]interface{}{"num": 2}); err != nil {
		t.Fatalf("Call: %s", err)
	}
	m, ok := gotParams.(map[string]interface{})
	if !ok || m["num"].(float64) != 2 {
		t.Fatalf("server saw params %#v", gotParams)
	}
}

func TestClientErrorReplyBecomesError(t *testing.T) {
	s := newFakeServer(t)
	s.setHandler(func(method string, params interface{}) (interface{}, int, string) {
		return nil, -32001, "no such window 999"
	})
	c := newTestClient(t, s.addr)
	_, err := c.Call("window.focus", map[string]interface{}{"id": 999})
	if err == nil {
		t.Fatalf("expected an error")
	}
	rerr, ok := err.(*RPCError)
	if !ok {
		t.Fatalf("expected *RPCError, got %T: %s", err, err)
	}
	if rerr.Code != -32001 || rerr.Message != "no such window 999" {
		t.Fatalf("got %#v", rerr)
	}
}

func TestClientFragmentedReply(t *testing.T) {
	s := newFakeServer(t)
	s.fragment = true
	s.setHandler(func(method string, params interface{}) (interface{}, int, string) {
		return map[string]interface{}{"module": map[string]interface{}{"w": 8, "h": 21}}, 0, ""
	})
	c := newTestClient(t, s.addr)
	raw, err := c.Call("grid.get", nil)
	if err != nil {
		t.Fatalf("Call: %s", err)
	}
	var got map[string]interface{}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("decode: %s", err)
	}
	mod := got["module"].(map[string]interface{})
	if mod["w"].(float64) != 8 || mod["h"].(float64) != 21 {
		t.Fatalf("got %#v", got)
	}
}

func TestClientDialFailureIsAnError(t *testing.T) {
	dir := t.TempDir()
	c := New(filepath.Join(dir, "nosuchsocket"))
	defer c.Close()
	if _, err := c.Call("workspace.list", nil); err == nil {
		t.Fatalf("expected an error dialing a socket that does not exist")
	}
}

// A dial failure is marked ErrUnreachable, so the daemon can tell "kwi3 is
// down - the client already said so once" from every other error (which it
// logs per chord).
func TestClientDialFailureIsErrUnreachable(t *testing.T) {
	c := New(filepath.Join(t.TempDir(), "nosuchsocket"))
	defer c.Close()
	_, err := c.Call("workspace.list", nil)
	if !errors.Is(err, ErrUnreachable) {
		t.Fatalf("dial failure should wrap ErrUnreachable, got %v", err)
	}
	if err := c.Dispatch("focus left"); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("Dispatch's dial failure should wrap ErrUnreachable, got %v", err)
	}
	if _, err := Translate("sticky toggle"); errors.Is(err, ErrUnreachable) {
		t.Fatalf("an unsupported verb must not read as ErrUnreachable")
	}
}

func TestClientDialFailureLogsOnce(t *testing.T) {
	dir := t.TempDir()
	var lines []string
	var mu sync.Mutex
	c := New(filepath.Join(dir, "nosuchsocket"), WithLog(func(s string) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, s)
	}))
	defer c.Close()
	for i := 0; i < 5; i++ {
		c.Call("workspace.list", nil)
	}
	mu.Lock()
	n := len(lines)
	mu.Unlock()
	if n != 1 {
		t.Fatalf("expected exactly one log line across 5 failed calls (log once, not spam per chord), got %d: %v", n, lines)
	}
}

// TestClientReconnectsAfterServerRestart is the "kwi3 restarts" edge case:
// the chord in flight when the connection dies is dropped (this Call
// fails), but the NEXT one redials and succeeds - no queueing, no silent
// resend of the dropped one.
func TestClientReconnectsAfterServerRestart(t *testing.T) {
	dir := t.TempDir()
	addr := filepath.Join(dir, "kwi3.rpc.sock")
	ln1, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatalf("listen: %s", err)
	}
	serve := func(ln net.Listener) {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		r := bufio.NewReader(conn)
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		var req struct {
			ID int64 `json:"id"`
		}
		json.Unmarshal(line, &req)
		reply, _ := json.Marshal(map[string]interface{}{"jsonrpc": "2.0", "id": req.ID, "result": map[string]interface{}{}})
		conn.Write(append(reply, '\n'))
	}
	go serve(ln1)

	c := New(addr)
	defer c.Close()
	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("first call: %s", err)
	}
	ln1.Close() // kwi3 "restarts": the old listener is gone

	// The connection is now dead server-side (server closed after one
	// reply); a call issued now must fail rather than hang.
	deadline := time.Now().Add(2 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		if _, lastErr = c.Call("workspace.list", nil); lastErr != nil {
			break
		}
	}
	if lastErr == nil {
		t.Fatalf("expected the call against the dead connection to fail")
	}

	os.Remove(addr)
	ln2, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatalf("re-listen: %s", err)
	}
	defer ln2.Close()
	go serve(ln2)

	// Give the new listener a moment to be ready to Accept - the retry
	// loop below is what actually waits, this just avoids a guaranteed
	// first-attempt miss.
	var reconnected bool
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := c.Call("workspace.list", nil); err == nil {
			reconnected = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !reconnected {
		t.Fatalf("client did not reconnect after the server restarted")
	}
}

// TestClientFirstCallAfterRestartLandsWithoutExternalRetry is the kwi3-5a8
// regression: the OLD behaviour left the dead connection cached until a
// Call failed on it, so the very first chord issued after kwi3 restarts
// wrote to the dead connection, failed, and was DROPPED even though kwi3
// was already back up and ready to accept. This test issues exactly one
// Call immediately after the restart - no external retry loop, unlike
// TestClientReconnectsAfterServerRestart above - and it must succeed.
//
// This is safe to retry transparently because a WRITE failure means the
// request was never delivered anywhere: empirically (see the write-to-a
// peer-closed-AF_UNIX-socket experiment cited in client.go's writeLocked
// doc comment), a write against a connection whose peer already closed
// fails immediately (EPIPE) rather than silently buffering, so "the write
// failed" is a trustworthy "never sent" signal on this transport.
func TestClientFirstCallAfterRestartLandsWithoutExternalRetry(t *testing.T) {
	dir := t.TempDir()
	addr := filepath.Join(dir, "kwi3.rpc.sock")

	ln1, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatalf("listen: %s", err)
	}
	serveOnce := func(ln net.Listener) {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		r := bufio.NewReader(conn)
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		var req struct {
			ID int64 `json:"id"`
		}
		json.Unmarshal(line, &req)
		reply, _ := json.Marshal(map[string]interface{}{"jsonrpc": "2.0", "id": req.ID, "result": map[string]interface{}{}})
		conn.Write(append(reply, '\n'))
		// conn closes here (defer) - the same as kwi3 exiting right after
		// answering, which is what leaves the client's cached connection
		// dead by the time the NEXT chord's Call runs.
	}
	go serveOnce(ln1)

	c := New(addr)
	defer c.Close()
	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("first call: %s", err)
	}

	// kwi3 "restarts": old listener gone, a fresh one bound at the same
	// path and ready to Accept before the next chord fires - the case
	// where the drop was observed (kwi3 already back, but the client still
	// held the stale connection from before the restart).
	ln1.Close()
	os.Remove(addr)
	ln2, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatalf("re-listen: %s", err)
	}
	defer ln2.Close()
	go serveOnce(ln2)

	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("the first chord after kwi3 restarts must land, not be dropped: %s", err)
	}
}

// TestClientReadFailureIsNotRetried is the negative half of kwi3-5a8: a
// failure on the READ side (kwi3 accepted the request and may already have
// run it before dying, e.g. mid-command) must NEVER be retried - retrying
// would risk sending the same command twice. This asserts the request
// reaches the server exactly once even though the Call itself reports an
// error to the caller.
func TestClientReadFailureIsNotRetried(t *testing.T) {
	dir := t.TempDir()
	addr := filepath.Join(dir, "kwi3.rpc.sock")
	ln, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatalf("listen: %s", err)
	}
	defer ln.Close()

	var mu sync.Mutex
	requestCount := 0
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		r := bufio.NewReader(conn)
		if _, err := r.ReadBytes('\n'); err != nil {
			return
		}
		mu.Lock()
		requestCount++
		mu.Unlock()
		// Simulate kwi3 dying after receiving the request (and possibly
		// having already run it) but before writing any reply: close with
		// no bytes written back.
	}()

	c := New(addr)
	defer c.Close()
	if _, err := c.Call("window.close", map[string]interface{}{"id": 1}); err == nil {
		t.Fatalf("expected a read-side error")
	}

	mu.Lock()
	n := requestCount
	mu.Unlock()
	if n != 1 {
		t.Fatalf("a read failure must never be retried (kwi3 may already have run the command) - expected exactly 1 request delivered, got %d", n)
	}
}

func TestClientMalformedReplyIsAnError(t *testing.T) {
	dir := t.TempDir()
	addr := filepath.Join(dir, "kwi3.rpc.sock")
	ln, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatalf("listen: %s", err)
	}
	defer ln.Close()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		r := bufio.NewReader(conn)
		r.ReadBytes('\n')
		conn.Write([]byte("not json at all\n"))
	}()
	c := New(addr)
	defer c.Close()
	if _, err := c.Call("workspace.list", nil); err == nil {
		t.Fatalf("expected an error decoding a malformed reply")
	}
}

// -- Dispatch: Translate + Call wired together --

func TestDispatchSimpleCommand(t *testing.T) {
	s := newFakeServer(t)
	var gotMethod string
	var gotParams interface{}
	s.setHandler(func(method string, params interface{}) (interface{}, int, string) {
		gotMethod = method
		gotParams = params
		return map[string]interface{}{}, 0, ""
	})
	c := newTestClient(t, s.addr)
	if err := c.Dispatch("focus left"); err != nil {
		t.Fatalf("Dispatch: %s", err)
	}
	if gotMethod != "window.focus" {
		t.Fatalf("got method %q", gotMethod)
	}
	if gotParams.(map[string]interface{})["direction"] != "left" {
		t.Fatalf("got params %#v", gotParams)
	}
}

func TestDispatchCompoundCommandRunsBothCalls(t *testing.T) {
	s := newFakeServer(t)
	var methods []string
	var mu sync.Mutex
	s.setHandler(func(method string, params interface{}) (interface{}, int, string) {
		mu.Lock()
		methods = append(methods, method)
		mu.Unlock()
		return map[string]interface{}{}, 0, ""
	})
	c := newTestClient(t, s.addr)
	if err := c.Dispatch("split h;exec notify-send 'tile side'"); err != nil {
		t.Fatalf("Dispatch: %s", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(methods) != 2 || methods[0] != "layout.split" || methods[1] != "exec" {
		t.Fatalf("got methods %v", methods)
	}
}

func TestDispatchUnsupportedVerbReturnsError(t *testing.T) {
	s := newFakeServer(t)
	c := newTestClient(t, s.addr)
	err := c.Dispatch("sticky toggle")
	if err == nil {
		t.Fatalf("expected an error")
	}
	if _, ok := err.(*UnsupportedVerbError); !ok {
		t.Fatalf("expected *UnsupportedVerbError, got %T: %s", err, err)
	}
}

func TestDispatchWorkspaceNeighbourResolvesLocally(t *testing.T) {
	s := newFakeServer(t)
	var lastMethod string
	var lastParams interface{}
	s.setHandler(func(method string, params interface{}) (interface{}, int, string) {
		lastMethod = method
		lastParams = params
		if method == "workspace.list" {
			return []interface{}{
				map[string]interface{}{"id": 1, "num": 1, "focused": false},
				map[string]interface{}{"id": 2, "num": 2, "focused": true},
				map[string]interface{}{"id": 3, "num": 3, "focused": false},
			}, 0, ""
		}
		return map[string]interface{}{}, 0, ""
	})
	c := newTestClient(t, s.addr)
	if err := c.Dispatch("workspace next"); err != nil {
		t.Fatalf("Dispatch: %s", err)
	}
	if lastMethod != "workspace.focus" {
		t.Fatalf("expected the last wire call to be workspace.focus, got %q", lastMethod)
	}
	if lastParams.(map[string]interface{})["num"].(float64) != 3 {
		t.Fatalf("expected num 3 (focused was 2, next wraps forward), got %#v", lastParams)
	}
	// And "workspace.neighbour" must never be what actually goes on the
	// wire - only the two real methods above are ever sent.
	if strings.Contains(fmt.Sprintf("%v", lastMethod), "neighbour") {
		t.Fatalf("the pseudo-method leaked onto the wire: %q", lastMethod)
	}
}
