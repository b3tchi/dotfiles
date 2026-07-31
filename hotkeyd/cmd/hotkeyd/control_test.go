package main

// Control-socket coverage (sp023 Task 3). Everything here runs over a REAL
// unix socket in t.TempDir() — the listener's whole job is I/O framing under
// a deadline, and a fake net.Conn would test the framing while silently
// dropping the two properties that actually matter: that a hung client
// cannot wedge the run loop, and that an oversized write cannot make the
// daemon allocate without bound.
//
// The run loop itself is stood in for by serveControl's drainer, which is
// exactly what (*Daemon).Run's control case does — daemon_test.go covers the
// wiring of that case separately (TestRun_ControlCase_*), so a deleted select
// case fails there rather than here.

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

	"hotkeyd/internal/bind"
	"hotkeyd/internal/layer"
)

// ---------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------

// testControlTimeout is deliberately short so the silent-client test does
// not take seconds; production uses controlReadTimeout.
const testControlTimeout = 120 * time.Millisecond

func newTestControl(t *testing.T, readTimeout time.Duration) (*ControlListener, *fakeLogger, string) {
	t.Helper()
	logger := &fakeLogger{}
	path := filepath.Join(t.TempDir(), "hotkeyd-99-ctl.sock")
	l, err := NewControlListener(ControlConfig{
		Path:        path,
		Log:         logger.log,
		ReadTimeout: readTimeout,
	})
	if err != nil {
		t.Fatalf("NewControlListener: %v", err)
	}
	t.Cleanup(func() { _ = l.Close() })
	return l, logger, path
}

// serveControl stands in for (*Daemon).Run's control case: a SINGLE
// goroutine draining the command channel, so every assertion about
// serialization below is an assertion about the real single-threaded
// discipline (SetExternalLayer is only ever called from the run loop).
func serveControl(t *testing.T, l *ControlListener, handle func(string) error) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for cmd := range l.Commands() {
			cmd.reply <- handle(cmd.layer)
		}
	}()
	t.Cleanup(func() {
		_ = l.Close()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Error("control drainer did not stop after Close — Commands() was never closed")
		}
	})
}

// request writes one raw line and reads one reply line, both under a
// deadline, so a broken listener fails the test instead of hanging it.
func request(t *testing.T, path, line string) (controlReply, error) {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		return controlReply{}, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte(line)); err != nil {
		return controlReply{}, err
	}
	raw, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil && raw == "" {
		return controlReply{}, err
	}
	var rep controlReply
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &rep); err != nil {
		return controlReply{}, fmt.Errorf("reply %q is not JSON: %w", raw, err)
	}
	return rep, nil
}

func setLayerLine(name string) string {
	return fmt.Sprintf("{\"set_layer\":%q}\n", name)
}

// ---------------------------------------------------------------------
// happy path
// ---------------------------------------------------------------------

func TestControl_HappyPath_ForwardsNameAndRepliesOK(t *testing.T) {
	l, _, path := newTestControl(t, testControlTimeout)
	var mu sync.Mutex
	var got []string
	serveControl(t, l, func(name string) error {
		mu.Lock()
		got = append(got, name)
		mu.Unlock()
		return nil
	})

	rep, err := request(t, path, setLayerLine("screenshot-drag"))
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	if !rep.OK || rep.Error != "" {
		t.Fatalf("reply = %+v, want {ok:true}", rep)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 1 || got[0] != "screenshot-drag" {
		t.Fatalf("handler saw %v, want [screenshot-drag] — the name must cross the channel verbatim", got)
	}
}

func TestControl_HandlerRefusal_RepliesNotOKWithTheNamedError(t *testing.T) {
	l, _, path := newTestControl(t, testControlTimeout)
	serveControl(t, l, func(name string) error {
		return fmt.Errorf("%w: %q", layer.ErrNoSuchLayer, name)
	})

	rep, err := request(t, path, setLayerLine("nope"))
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	if rep.OK {
		t.Fatal("a refused request replied ok:true")
	}
	if !strings.Contains(rep.Error, "no such layer") || !strings.Contains(rep.Error, "nope") {
		t.Fatalf("reply error = %q, want the sentinel text AND the offending name (us019 AC4)", rep.Error)
	}
}

// TestControl_EmptySetLayer_ClearsViaDefault pins the clear verb's shape:
// `{"set_layer":"default"}` is an ordinary request, not a special case at
// the wire level.
func TestControl_EmptySetLayer_ClearsViaDefault(t *testing.T) {
	l, _, path := newTestControl(t, testControlTimeout)
	var mu sync.Mutex
	var got []string
	serveControl(t, l, func(name string) error {
		mu.Lock()
		got = append(got, name)
		mu.Unlock()
		return nil
	})
	if _, err := request(t, path, setLayerLine(layer.DefaultLayer)); err != nil {
		t.Fatalf("request: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 1 || got[0] != layer.DefaultLayer {
		t.Fatalf("handler saw %v, want [%s]", got, layer.DefaultLayer)
	}
}

// ---------------------------------------------------------------------
// malformed input — every one answers named, none is a silent drop
// ---------------------------------------------------------------------

func TestControl_MalformedRequests_AlwaysAnswerNamed(t *testing.T) {
	cases := []struct {
		name      string
		line      string
		wantInErr string
	}{
		{"garbage", "this is not json\n", "malformed"},
		{"empty line", "\n", "empty"},
		{"missing key", "{\"other\":\"x\"}\n", "set_layer"},
		{"json null body", "null\n", "set_layer"},
		{"array not object", "[1,2,3]\n", "malformed"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			l, _, path := newTestControl(t, testControlTimeout)
			var calls int
			var mu sync.Mutex
			serveControl(t, l, func(string) error {
				mu.Lock()
				calls++
				mu.Unlock()
				return nil
			})

			rep, err := request(t, path, tc.line)
			if err != nil {
				t.Fatalf("request: %v — a malformed line must still get a reply, never a silent drop", err)
			}
			if rep.OK {
				t.Fatalf("malformed line %q replied ok:true", tc.line)
			}
			if !strings.Contains(rep.Error, tc.wantInErr) {
				t.Fatalf("reply error = %q, want it to name %q", rep.Error, tc.wantInErr)
			}
			mu.Lock()
			defer mu.Unlock()
			if calls != 0 {
				t.Fatalf("a malformed request reached the run loop %d time(s) — parsing must fail in the connection's own goroutine", calls)
			}
		})
	}
}

// TestControl_OversizedLine_RefusedNamedAndDaemonUnaffected is the bounded-
// read criterion. The request is far larger than the bound and carries NO
// newline, so an unbounded ReadString would buffer all of it; the assertion
// that the NEXT request still succeeds is what proves the daemon survived.
func TestControl_OversizedLine_RefusedNamedAndDaemonUnaffected(t *testing.T) {
	l, _, path := newTestControl(t, testControlTimeout)
	var mu sync.Mutex
	var calls int
	serveControl(t, l, func(string) error {
		mu.Lock()
		calls++
		mu.Unlock()
		return nil
	})

	huge := "{\"set_layer\":\"" + strings.Repeat("x", maxControlRequestBytes*4) + "\"}\n"
	rep, err := request(t, path, huge)
	if err != nil {
		t.Fatalf("oversized request: %v", err)
	}
	if rep.OK {
		t.Fatal("oversized request replied ok:true")
	}
	if !strings.Contains(rep.Error, "too large") {
		t.Fatalf("reply error = %q, want it to name the size refusal", rep.Error)
	}

	rep2, err := request(t, path, setLayerLine("screenshot-drag"))
	if err != nil || !rep2.OK {
		t.Fatalf("the daemon stopped serving after an oversized request: rep=%+v err=%v", rep2, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if calls != 1 {
		t.Fatalf("run loop saw %d commands, want exactly 1 (the oversized one must never reach it)", calls)
	}
}

// ---------------------------------------------------------------------
// hung / silent clients
// ---------------------------------------------------------------------

// TestControl_SilentClient_TimesOutAndNeverBlocksTheRunLoop is the two
// assertions the success criterion names in one test: a client that connects
// and says nothing is dropped on the read deadline, and — while it is still
// hanging — a well-behaved client is served promptly, proving the silent
// connection never occupied the run loop.
func TestControl_SilentClient_TimesOutAndNeverBlocksTheRunLoop(t *testing.T) {
	l, _, path := newTestControl(t, testControlTimeout)
	served := make(chan string, 4)
	serveControl(t, l, func(name string) error {
		served <- name
		return nil
	})

	silent, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer silent.Close()

	// The run loop must still be reachable while `silent` hangs.
	start := time.Now()
	rep, err := request(t, path, setLayerLine("screenshot-drag"))
	if err != nil {
		t.Fatalf("second client was not served while a silent one hung: %v", err)
	}
	if !rep.OK {
		t.Fatalf("second client got %+v", rep)
	}
	if elapsed := time.Since(start); elapsed > testControlTimeout {
		t.Fatalf("serving a live client took %s (> one read timeout) — the silent connection is blocking the loop", elapsed)
	}
	select {
	case got := <-served:
		if got != "screenshot-drag" {
			t.Fatalf("run loop saw %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("run loop never saw the live request")
	}

	// And the silent connection is eventually closed by the deadline —
	// asserted through the client end, which is what a real caller sees.
	_ = silent.SetReadDeadline(time.Now().Add(2 * time.Second))
	raw, readErr := bufio.NewReader(silent).ReadString('\n')
	if readErr != nil && raw == "" {
		t.Fatalf("silent client got neither a named reply nor a close: %v", readErr)
	}
	if raw != "" {
		var rep controlReply
		if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &rep); err != nil {
			t.Fatalf("silent client's reply %q is not JSON: %v", raw, err)
		}
		if rep.OK || !strings.Contains(rep.Error, "timed out") {
			t.Fatalf("silent client reply = %+v, want a named read-timeout refusal", rep)
		}
	}
	// A silent client must never have reached the run loop.
	select {
	case extra := <-served:
		t.Fatalf("a silent client produced a command %q on the run loop", extra)
	default:
	}
}

// ---------------------------------------------------------------------
// concurrency + ordering
// ---------------------------------------------------------------------

// TestControl_ConcurrentRequests_AllAnsweredExactlyOnce is the -race
// workhorse: N clients at once, one drainer, every reply accounted for.
func TestControl_ConcurrentRequests_AllAnsweredExactlyOnce(t *testing.T) {
	l, _, path := newTestControl(t, 2*time.Second)
	var mu sync.Mutex
	seen := map[string]int{}
	serveControl(t, l, func(name string) error {
		mu.Lock()
		seen[name]++
		mu.Unlock()
		return nil
	})

	const n = 12
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			rep, err := request(t, path, setLayerLine(fmt.Sprintf("layer-%d", i)))
			if err != nil {
				errs <- err
				return
			}
			if !rep.OK {
				errs <- fmt.Errorf("request %d refused: %s", i, rep.Error)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("concurrent request failed: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != n {
		t.Fatalf("run loop saw %d distinct names, want %d", len(seen), n)
	}
	for name, count := range seen {
		if count != 1 {
			t.Errorf("%s was delivered %d times, want exactly 1", name, count)
		}
	}
}

// TestControl_EnterThenClear_SerializedWithDeterministicFinalState is the
// "two rapid requests racing" edge case: enter then clear, both answered in
// order, and the state the single-threaded handler ends in is the SECOND
// request's — never an interleaving.
func TestControl_EnterThenClear_SerializedWithDeterministicFinalState(t *testing.T) {
	l, _, path := newTestControl(t, 2*time.Second)
	var mu sync.Mutex
	var order []string
	state := layer.DefaultLayer
	serveControl(t, l, func(name string) error {
		mu.Lock()
		order = append(order, name)
		state = name
		mu.Unlock()
		return nil
	})

	if rep, err := request(t, path, setLayerLine("screenshot-drag")); err != nil || !rep.OK {
		t.Fatalf("enter: rep=%+v err=%v", rep, err)
	}
	if rep, err := request(t, path, setLayerLine(layer.DefaultLayer)); err != nil || !rep.OK {
		t.Fatalf("clear: rep=%+v err=%v", rep, err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(order) != 2 || order[0] != "screenshot-drag" || order[1] != layer.DefaultLayer {
		t.Fatalf("handler order = %v, want [screenshot-drag default]", order)
	}
	if state != layer.DefaultLayer {
		t.Fatalf("final state = %q, want %q", state, layer.DefaultLayer)
	}
}

// ---------------------------------------------------------------------
// lifecycle
// ---------------------------------------------------------------------

func TestControl_Close_RemovesSocketAndClosesCommands(t *testing.T) {
	l, _, path := newTestControl(t, testControlTimeout)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("socket was not created at %s: %v", path, err)
	}
	if err := l.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("socket file survived Close (stat err = %v) — shutdown must unlink it", err)
	}
	if _, ok := <-l.Commands(); ok {
		t.Fatal("Commands() still open after Close — Run's select would spin")
	}
	if err := l.Close(); err != nil {
		t.Fatalf("second Close must be a no-op, got %v", err)
	}
}

// TestControl_StaleSocketFile_UnlinkedAtBind is the SIGKILLed-predecessor
// case. Safe unconditionally because the caller already holds this display's
// single-instance flock (proc.AcquireLock) — the same guarantee
// layer.NewStatePublisher documents.
func TestControl_StaleSocketFile_UnlinkedAtBind(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "hotkeyd-99-ctl.sock")
	if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
		t.Fatalf("seed stale file: %v", err)
	}
	l, err := NewControlListener(ControlConfig{Path: path, ReadTimeout: testControlTimeout})
	if err != nil {
		t.Fatalf("NewControlListener over a stale socket file: %v", err)
	}
	defer l.Close()
	serveControl(t, l, func(string) error { return nil })
	if rep, err := request(t, path, setLayerLine("screenshot-drag")); err != nil || !rep.OK {
		t.Fatalf("rebound socket does not serve: rep=%+v err=%v", rep, err)
	}
}

// TestControl_MissingRuntimeDir_FailsNamed is adr0014's fail-fast framing at
// this surface: a vanished $XDG_RUNTIME_DIR is a precondition the listener
// cannot re-establish from the inside, so it returns a NAMED error for the
// caller to act on (main.go logs it and serves without the socket) instead
// of a respawning bind loop.
func TestControl_MissingRuntimeDir_FailsNamed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gone", "hotkeyd-99-ctl.sock")
	l, err := NewControlListener(ControlConfig{Path: path, ReadTimeout: testControlTimeout})
	if err == nil {
		l.Close()
		t.Fatal("binding under a missing directory succeeded")
	}
	var unavailable *ErrControlUnavailable
	if !errors.As(err, &unavailable) {
		t.Fatalf("error %v (%T) is not *ErrControlUnavailable — adr0014 wants a named failure", err, err)
	}
	if !strings.Contains(err.Error(), "control socket") {
		t.Fatalf("error %q does not name the control socket", err.Error())
	}
}

// TestControl_RequestDuringShutdown_NoReplyDeadlock covers the edge case: a
// request in flight when the daemon stops must not wedge the client and must
// not stop Close() from completing. No drainer runs here, so the request is
// parked exactly where a real shutdown would strand it.
func TestControl_RequestDuringShutdown_NoReplyDeadlock(t *testing.T) {
	l, _, path := newTestControl(t, 2*time.Second)
	// NOTE: no serveControl — nothing drains Commands(), which is what the
	// run loop looks like once it has broken out of its select.

	done := make(chan error, 1)
	go func() {
		_, err := request(t, path, setLayerLine("screenshot-drag"))
		done <- err
	}()

	// Let the request reach the parked send before shutting down.
	time.Sleep(50 * time.Millisecond)

	closed := make(chan error, 1)
	go func() { closed <- l.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatalf("Close during an in-flight request: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close() deadlocked on an in-flight control request")
	}

	select {
	case err := <-done:
		if err != nil && !strings.Contains(err.Error(), "EOF") {
			t.Fatalf("in-flight client error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("in-flight client hung across shutdown — no reply and no close")
	}
}

// ---------------------------------------------------------------------
// daemon-side authority: validateControlLayer, the COMPILED-table gate
// ---------------------------------------------------------------------

func TestValidateControlLayer_AcceptsOnlyExternalNamesAndDefault(t *testing.T) {
	layers := map[string]bind.Layer{
		"drag": {External: true},
		"nav":  {ExitKeys: []string{"q"}},
	}
	cases := []struct {
		name      string
		arg       string
		wantErr   error
		wantInMsg string
	}{
		{"declared external", "drag", nil, ""},
		{"clear", layer.DefaultLayer, nil, ""},
		{"empty means clear", "", nil, ""},
		{"undeclared name", "bogus", layer.ErrNoSuchLayer, "bogus"},
		{"chord layer", "nav", layer.ErrNotExternalLayer, "nav"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateControlLayer(layers, tc.arg)
			if tc.wantErr == nil {
				if err != nil {
					t.Fatalf("validateControlLayer(%q) = %v, want nil", tc.arg, err)
				}
				return
			}
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("validateControlLayer(%q) = %v, want %v", tc.arg, err, tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantInMsg) {
				t.Fatalf("error %q does not name the offending layer %q (us019 AC4)", err.Error(), tc.wantInMsg)
			}
		})
	}
}

// ---------------------------------------------------------------------
// adr0012: the STATE socket still never reads client bytes
// ---------------------------------------------------------------------

// TestStateSocket_GarbageFromClient_ChangesNothing is the literal-adr0012
// assertion this task owes: a client that WRITES to the state feed gets no
// state change, no disconnect, and no behavior beyond today's. The control
// verb lives on its own socket precisely so this stays true.
func TestStateSocket_GarbageFromClient_ChangesNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-99.sock")
	pub, err := layer.NewStatePublisher(path, layer.State{Layer: layer.DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer pub.Close()

	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	rd := bufio.NewReader(conn)
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	first, err := rd.ReadString('\n')
	if err != nil {
		t.Fatalf("replay read: %v", err)
	}
	if !strings.Contains(first, "\"layer\":\"default\"") {
		t.Fatalf("replay line = %q, want the default state", first)
	}

	// Write the exact shape the CONTROL socket would accept. On the state
	// socket it must be inert.
	if _, err := conn.Write([]byte(setLayerLine("screenshot-drag"))); err != nil {
		t.Fatalf("write to state socket: %v", err)
	}
	time.Sleep(50 * time.Millisecond)

	if got := pub.ClientCount(); got != 1 {
		t.Fatalf("ClientCount = %d after the client wrote garbage, want 1 — writing must not disconnect a subscriber", got)
	}

	// The publisher's current state is unchanged: a NEW subscriber still
	// replays default, i.e. the write mutated nothing.
	probe, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("second dial: %v", err)
	}
	defer probe.Close()
	_ = probe.SetDeadline(time.Now().Add(2 * time.Second))
	replay, err := bufio.NewReader(probe).ReadString('\n')
	if err != nil {
		t.Fatalf("second replay read: %v", err)
	}
	if !strings.Contains(replay, "\"layer\":\"default\"") {
		t.Fatalf("a client write changed published state: replay = %q", replay)
	}

	// And the feed still works for the writer afterwards.
	pub.Publish(layer.State{Layer: "screenshot-drag"})
	line, err := rd.ReadString('\n')
	if err != nil {
		t.Fatalf("post-garbage publish read: %v", err)
	}
	if !strings.Contains(line, "\"layer\":\"screenshot-drag\"") {
		t.Fatalf("post-garbage line = %q", line)
	}
}
