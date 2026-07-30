package i3

import (
	"encoding/json"
	"errors"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeI3 is an in-process i3 IPC server: it accepts one connection at a
// time and lets the test script exactly what that connection reads and
// replies. It exists so client.go's behaviour (retry, reconnect backoff,
// event interleaving, success:false propagation) can be driven and asserted
// without a real i3 process.
type fakeI3 struct {
	t    *testing.T
	ln   net.Listener
	path string

	mu     sync.Mutex
	conns  []net.Conn
	accept chan net.Conn
}

func startFakeI3(t *testing.T) *fakeI3 {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "i3ipc.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	f := &fakeI3{t: t, ln: ln, path: path, accept: make(chan net.Conn, 8)}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			f.mu.Lock()
			f.conns = append(f.conns, c)
			f.mu.Unlock()
			f.accept <- c
		}
	}()
	t.Cleanup(func() {
		ln.Close()
		f.mu.Lock()
		defer f.mu.Unlock()
		for _, c := range f.conns {
			c.Close()
		}
	})
	return f
}

// nextConn waits for the next accepted connection.
func (f *fakeI3) nextConn(t *testing.T) net.Conn {
	t.Helper()
	select {
	case c := <-f.accept:
		return c
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for client to connect")
		return nil
	}
}

// recvRequest reads one frame off conn (a request from the client under
// test) and returns its type + payload.
func recvRequest(t *testing.T, conn net.Conn) frame {
	t.Helper()
	f, err := readFrame(conn)
	if err != nil {
		t.Fatalf("fake i3: reading request: %v", err)
	}
	return f
}

// reply sends a well-formed reply frame back.
func reply(t *testing.T, conn net.Conn, mtype uint32, payload []byte) {
	t.Helper()
	if err := writeFrame(conn, mtype, payload); err != nil {
		t.Fatalf("fake i3: writing reply: %v", err)
	}
}

// sendEvent sends an unsolicited event frame (EventMask set).
func sendEvent(t *testing.T, conn net.Conn, kind uint32, payload []byte) {
	t.Helper()
	if err := writeFrame(conn, kind|EventMask, payload); err != nil {
		t.Fatalf("fake i3: writing event: %v", err)
	}
}

func pathFn(f *fakeI3) func() (string, error) {
	return func() (string, error) { return f.path, nil }
}

// --- Command -----------------------------------------------------------

func TestClient_Command_Success(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		req := recvRequest(t, conn)
		if req.mtype != MsgRunCommand {
			t.Errorf("mtype = %d, want MsgRunCommand", req.mtype)
		}
		if string(req.payload) != "workspace 2" {
			t.Errorf("payload = %q", req.payload)
		}
		reply(t, conn, MsgRunCommand, []byte(`[{"success":true}]`))
	}()

	ok, i3Err, err := c.Command("workspace 2")
	<-done
	if err != nil {
		t.Fatalf("Command: unexpected error: %v", err)
	}
	if !ok {
		t.Errorf("ok = false, want true")
	}
	if i3Err != "" {
		t.Errorf("i3Err = %q, want empty", i3Err)
	}
}

func TestClient_Command_SuccessFalse_SurfacesI3ErrorText(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		recvRequest(t, conn)
		reply(t, conn, MsgRunCommand,
			[]byte(`[{"success":false,"error":"No such command \"bogus\""}]`))
	}()

	ok, i3Err, err := c.Command("bogus")
	<-done
	if err != nil {
		t.Fatalf("Command: unexpected transport error: %v", err)
	}
	if ok {
		t.Errorf("ok = true, want false on success:false reply")
	}
	if i3Err == "" || !strings.Contains(i3Err, "No such command") {
		t.Errorf("i3Err = %q, want it to contain i3's error text", i3Err)
	}
}

func TestClient_Command_MultiCommandReply_AnyFailureIsOverallFailure(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		recvRequest(t, conn)
		reply(t, conn, MsgRunCommand,
			[]byte(`[{"success":true},{"success":false,"error":"boom"}]`))
	}()

	ok, i3Err, err := c.Command("a; b")
	<-done
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ok {
		t.Error("ok = true, want false: one of two commands failed")
	}
	if !strings.Contains(i3Err, "boom") {
		t.Errorf("i3Err = %q, want it to mention the failing command's error", i3Err)
	}
}

func TestClient_Command_TransportDeath_RetriesOnceThenFails(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	var attempts int
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 2; i++ {
			conn := f.nextConn(t)
			attempts++
			recvRequest(t, conn)
			conn.Close() // simulate i3 dying mid-reply, both attempts
		}
	}()

	ok, _, err := c.Command("workspace 2")
	<-done
	if err == nil {
		t.Fatal("expected an error after both attempts fail")
	}
	if ok {
		t.Error("ok = true on a transport failure, want false")
	}
	if attempts != 2 {
		t.Errorf("attempts = %d, want exactly 2 (one retry, adr0014: bounded)", attempts)
	}
}

func TestClient_Command_TransportDeath_ThenReconnectSucceeds(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn1 := f.nextConn(t)
		recvRequest(t, conn1)
		conn1.Close() // first attempt dies

		conn2 := f.nextConn(t)
		recvRequest(t, conn2)
		reply(t, conn2, MsgRunCommand, []byte(`[{"success":true}]`))
	}()

	ok, _, err := c.Command("workspace 2")
	<-done
	if err != nil {
		t.Fatalf("Command: unexpected error: %v", err)
	}
	if !ok {
		t.Error("ok = false, want true: the retry succeeded")
	}
}

// --- GetConfig -----------------------------------------------------------

func TestClient_GetConfig(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		req := recvRequest(t, conn)
		if req.mtype != MsgGetConfig {
			t.Errorf("mtype = %d, want MsgGetConfig", req.mtype)
		}
		cfg, _ := json.Marshal(map[string]string{"config": "bindsym $mod+a nop"})
		reply(t, conn, MsgGetConfig, cfg)
	}()

	cfg, err := c.GetConfig()
	<-done
	if err != nil {
		t.Fatalf("GetConfig: %v", err)
	}
	if cfg != "bindsym $mod+a nop" {
		t.Errorf("cfg = %q", cfg)
	}
}

// --- Subscribe / BindingState -------------------------------------------

func TestClient_Subscribe_ThenBindingState(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		// Connecting with a pending subscription sends SUBSCRIBE first.
		req := recvRequest(t, conn)
		if req.mtype != MsgSubscribe {
			t.Errorf("mtype = %d, want MsgSubscribe", req.mtype)
		}
		if string(req.payload) != `["mode"]` {
			t.Errorf("subscribe payload = %q", req.payload)
		}
		reply(t, conn, MsgSubscribe, []byte(`{"success":true}`))

		req = recvRequest(t, conn)
		if req.mtype != MsgGetBindingState {
			t.Errorf("mtype = %d, want MsgGetBindingState", req.mtype)
		}
		reply(t, conn, MsgGetBindingState, []byte(`{"name":"resize"}`))
	}()

	if err := c.Subscribe("mode"); err != nil {
		t.Fatalf("Subscribe: %v", err)
	}
	state, err := c.BindingState()
	<-done
	if err != nil {
		t.Fatalf("BindingState: %v", err)
	}
	if state != "resize" {
		t.Errorf("state = %q, want %q", state, "resize")
	}
}

func TestClient_Subscribe_DoesNotDuplicateWantedEvents(t *testing.T) {
	// hotkeyd.py's subscribe() re-sends SUBSCRIBE with the FULL wanted set
	// on every call once connected (it does not skip the wire round trip
	// just because nothing changed) -- replicated here rather than
	// invented, since the extracted matrix is about the wanted-set
	// bookkeeping, not about suppressing a harmless re-registration. What
	// must hold is that subscribing to an event already wanted does not
	// grow the set: the payload sent on the wire stays exactly `["mode"]`
	// on both calls, never `["mode","mode"]`.
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	const rounds = 2
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		for i := 0; i < rounds; i++ {
			req := recvRequest(t, conn)
			if string(req.payload) != `["mode"]` {
				t.Errorf("round %d: subscribe payload = %q, want [\"mode\"] (not duplicated)", i, req.payload)
			}
			reply(t, conn, MsgSubscribe, []byte(`{"success":true}`))
		}
	}()

	if err := c.Subscribe("mode"); err != nil {
		t.Fatalf("first Subscribe: %v", err)
	}
	if err := c.Subscribe("mode"); err != nil {
		t.Fatalf("second Subscribe: %v", err)
	}
	<-done
}

// --- PollEvents / event dispatch -----------------------------------------

func TestClient_PollEvents_DispatchesQueuedEvent(t *testing.T) {
	f := startFakeI3(t)

	var mu sync.Mutex
	var gotKind uint32
	var gotMode string
	handler := func(kind uint32, data map[string]any) {
		mu.Lock()
		defer mu.Unlock()
		gotKind = kind
		if data != nil {
			if v, ok := data["change"].(string); ok {
				gotMode = v
			}
		}
	}

	c := NewClient(pathFn(f), handler)
	defer c.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		req := recvRequest(t, conn)
		if req.mtype != MsgSubscribe {
			t.Errorf("mtype = %d, want MsgSubscribe", req.mtype)
		}
		reply(t, conn, MsgSubscribe, []byte(`{"success":true}`))
		sendEvent(t, conn, EventMode, []byte(`{"change":"resize"}`))
	}()

	if err := c.Subscribe("mode"); err != nil {
		t.Fatalf("Subscribe: %v", err)
	}
	<-done

	// Give the event time to actually land in the kernel socket buffer.
	deadline := time.Now().Add(2 * time.Second)
	for {
		reconnected, err := c.PollEvents()
		if err != nil {
			t.Fatalf("PollEvents: %v", err)
		}
		if reconnected {
			t.Error("reconnected = true on an already-open connection")
		}
		mu.Lock()
		got := gotMode
		mu.Unlock()
		if got == "resize" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for the mode event to be dispatched")
		}
		time.Sleep(10 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()
	if gotKind != EventMode {
		t.Errorf("gotKind = %d, want EventMode", gotKind)
	}
}

// TestClient_pollReadableLocked_SeesDataWrittenBeforeThePoll is a targeted
// regression test for a genuine platform gotcha found during implementation
// (not a goroutine race): internal/poll, when a read's deadline has
// ALREADY expired by the time the read runs, returns a timeout error
// WITHOUT ever attempting the underlying syscall -- so data already
// sitting in the kernel socket buffer is invisible to a naive
// SetReadDeadline(time.Now())-then-Peek check, deterministically, every
// time. Reproduced outside this package with a minimal stdlib-only
// dial/accept/write/peek program before being understood and fixed here by
// arming pollReadTimeout (a small POSITIVE offset) instead of time.Now()
// itself. This test gives the event a full 20ms to land in the kernel
// buffer BEFORE polling, so a regression back to the exact-now deadline
// fails this test on every run, not intermittently.
func TestClient_pollReadableLocked_SeesDataWrittenBeforeThePoll(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()
	impl := c.(*client)

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		recvRequest(t, conn) // SUBSCRIBE
		reply(t, conn, MsgSubscribe, []byte(`{"success":true}`))
		sendEvent(t, conn, EventMode, []byte(`{"change":"resize"}`))
	}()
	if err := c.Subscribe("mode"); err != nil {
		t.Fatalf("Subscribe: %v", err)
	}
	<-done
	time.Sleep(20 * time.Millisecond) // let the event settle well before polling

	impl.mu.Lock()
	ready, err := impl.pollReadableLocked()
	impl.mu.Unlock()
	if err != nil {
		t.Fatalf("pollReadableLocked: %v", err)
	}
	if !ready {
		t.Fatal("ready = false for data written 20ms before the poll -- the deadline-in-the-past gotcha regressed")
	}
}

func TestClient_PollEvents_NoSubscription_NeverReconnects(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	// Nothing has ever subscribed or sent a command, so there is no
	// connection to keep alive -- PollEvents must be a no-op, not attempt a
	// dial (mirrors hotkeyd.py: "if not self._subs: return False").
	reconnected, err := c.PollEvents()
	if err != nil {
		t.Fatalf("PollEvents: unexpected error: %v", err)
	}
	if reconnected {
		t.Error("reconnected = true with nothing subscribed")
	}

	select {
	case <-f.accept:
		t.Fatal("PollEvents dialed the socket despite no subscription")
	case <-time.After(100 * time.Millisecond):
	}
}

// --- Fileno ---------------------------------------------------------------

func TestClient_Fileno_NotOKBeforeConnect(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	if _, ok := c.Fileno(); ok {
		t.Error("Fileno ok = true before any connection was made")
	}
}

func TestClient_Fileno_OKAfterConnect(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		recvRequest(t, conn)
		reply(t, conn, MsgGetConfig, []byte(`{"config":""}`))
	}()
	if _, err := c.GetConfig(); err != nil {
		t.Fatalf("GetConfig: %v", err)
	}
	<-done

	fd, ok := c.Fileno()
	if !ok {
		t.Fatal("Fileno ok = false after a successful connect")
	}
	if fd < 0 {
		t.Errorf("fd = %d, want a valid non-negative descriptor", fd)
	}
}

// --- i3 restart / reconnect-backoff behaviour matrix ----------------------

func TestClient_PollEvents_ReconnectsAfterEOF_RateBoundedNotTight(t *testing.T) {
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	// Fake a controllable clock so the 5s adr0014 backoff doesn't cost real
	// wall-clock time in the suite. client_test.go is in-package, so it can
	// reach the unexported clock hook directly.
	impl := c.(*client)
	now := time.Now()
	impl.now = func() time.Time { return now }

	// First connection: subscribe, then i3 "restarts" (EOF).
	done1 := make(chan struct{})
	go func() {
		defer close(done1)
		conn := f.nextConn(t)
		recvRequest(t, conn) // SUBSCRIBE
		reply(t, conn, MsgSubscribe, []byte(`{"success":true}`))
		conn.Close() // i3 died
	}()
	if err := c.Subscribe("mode"); err != nil {
		t.Fatalf("Subscribe: %v", err)
	}
	<-done1

	// Drain the EOF: PollEvents must observe the dead connection and close
	// it, returning a named error rather than hanging or panicking.
	deadline := time.Now().Add(2 * time.Second)
	for {
		_, err := c.PollEvents()
		if err != nil {
			if !errors.Is(err, ErrClosed) {
				t.Fatalf("PollEvents error = %v, want ErrClosed", err)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting PollEvents to observe the EOF")
		}
		time.Sleep(5 * time.Millisecond)
	}

	// The death above was discovered MID-CALL (inside the drain loop, with
	// conn already non-nil going in), so -- mirroring hotkeyd.py's
	// poll_events() exactly, where _retry_at is likewise only touched
	// inside the `if self._sock is None:` branch at entry -- retryAt was
	// never armed by that call. The NEXT PollEvents call therefore attempts
	// ONE reconnect completely ungated. adr0014's backoff only starts
	// bounding attempts from here: service this attempt, but let it die
	// too (accepted, then closed before replying), so it fails cleanly
	// (never hangs on an unanswered connect) and arms retryAt for the
	// gated check that follows.
	done2 := make(chan struct{})
	go func() {
		defer close(done2)
		conn := f.nextConn(t)
		recvRequest(t, conn) // SUBSCRIBE, re-sent on every (re)connect
		conn.Close()         // dies again before replying
	}()
	reconnected, err := c.PollEvents()
	<-done2
	if err == nil {
		t.Fatal("expected an error: the ungated reconnect attempt died before replying")
	}
	if reconnected {
		t.Error("reconnected = true from a reconnect attempt that itself failed")
	}

	// Immediately after THAT failure, with the clock unmoved, retryAt IS
	// now armed -- PollEvents must not dial again. That is the "no
	// unbounded inline retry" adr0014 requirement. Prove it structurally:
	// no new connection shows up.
	reconnected, err = c.PollEvents()
	if err != nil {
		t.Fatalf("PollEvents (should be gated by backoff): %v", err)
	}
	if reconnected {
		t.Error("reconnected = true before the backoff window elapsed")
	}
	select {
	case <-f.accept:
		t.Fatal("PollEvents dialed again before the adr0014 backoff window elapsed")
	case <-time.After(100 * time.Millisecond):
	}

	// Advance the fake clock past the backoff window: now a reconnect
	// attempt is allowed, and it must re-subscribe (mirrors hotkeyd.py's
	// _connect() re-sending SUBSCRIBE for every remembered subscription).
	impl.mu.Lock()
	retryAt := impl.retryAt
	impl.mu.Unlock()
	impl.now = func() time.Time { return retryAt.Add(time.Millisecond) }

	done3 := make(chan struct{})
	go func() {
		defer close(done3)
		conn := f.nextConn(t)
		req := recvRequest(t, conn)
		if req.mtype != MsgSubscribe {
			t.Errorf("reconnect mtype = %d, want MsgSubscribe (re-subscribe on reconnect)", req.mtype)
		}
		reply(t, conn, MsgSubscribe, []byte(`{"success":true}`))
	}()

	reconnected, err = c.PollEvents()
	<-done3
	if err != nil {
		t.Fatalf("PollEvents after backoff elapsed: %v", err)
	}
	if !reconnected {
		t.Error("reconnected = false, want true: this poll re-established the connection")
	}
}

func TestClient_PollEvents_FreshReconnectReportedEvenWhenCausedByAnotherCall(t *testing.T) {
	// Mirrors hotkeyd.py's generation counter: a reconnect made by ANY
	// path (here, Command) must be reported exactly once by the next
	// PollEvents call, because that is the daemon's cue to re-read i3's
	// binding state after a restart resets it.
	f := startFakeI3(t)
	c := NewClient(pathFn(f), nil)
	defer c.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn := f.nextConn(t)
		recvRequest(t, conn)
		reply(t, conn, MsgRunCommand, []byte(`[{"success":true}]`))
	}()
	if _, _, err := c.Command("nop"); err != nil {
		t.Fatalf("Command: %v", err)
	}
	<-done

	reconnected, err := c.PollEvents()
	if err != nil {
		t.Fatalf("PollEvents: %v", err)
	}
	if !reconnected {
		t.Error("reconnected = false, want true: Command's connect was never reported yet")
	}

	// A second call with nothing new happening must not report it again.
	reconnected, err = c.PollEvents()
	if err != nil {
		t.Fatalf("PollEvents (second call): %v", err)
	}
	if reconnected {
		t.Error("reconnected = true on a second call with no new connect")
	}
}

// --- interface shape --------------------------------------------------

// TestClientInterface_Satisfied is a compile-time assertion that *client
// implements Client in full. The structural guarantee this task exists to
// provide -- a stub missing any one Client method fails to build, rather
// than degrading silently the way hotkeyd.py's getattr(self.i3, "method",
// None) seams did -- was verified manually during implementation by
// building a hand-written stub missing BindingState and confirming
// `go build` rejected it; see the task's bd notes for that transcript. That
// broken stub is deliberately not committed here (a permanently-failing
// build target is not a test).
func TestClientInterface_Satisfied(t *testing.T) {
	var _ Client = (*client)(nil)
}
