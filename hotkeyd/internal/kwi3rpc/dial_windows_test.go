//go:build windows

package kwi3rpc

// sp012 Task 2: the client dials the Win32 host's named pipe. These run as
// a GOOS=windows test binary on real Windows, against a pipe server written
// here with CreateNamedPipe - a real pipe, the same kernel object Qt's
// QLocalServer creates for i3kwin-win32 - never the host's own
// \\.\pipe\kwi3-<user>-<desktop>: every name below carries this process's
// pid and a counter.

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

var (
	k32                     = syscall.NewLazyDLL("kernel32.dll")
	procCreateNamedPipeW    = k32.NewProc("CreateNamedPipeW")
	procConnectNamedPipe    = k32.NewProc("ConnectNamedPipe")
	procDisconnectNamedPipe = k32.NewProc("DisconnectNamedPipe")
	procFlushFileBuffers    = k32.NewProc("FlushFileBuffers")
	pipeSeq                 int64
)

const (
	pipeAccessDuplex     = 0x3
	pipeTypeByteWait     = 0x0 // PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT
	errorPipeConnected   = syscall.Errno(535)
	pipeUnlimitedInstanc = 255
)

func testPipeName() string {
	return fmt.Sprintf(`\\.\pipe\kwi3rpc-test-%d-%d`, os.Getpid(), atomic.AddInt64(&pipeSeq, 1))
}

// pipeServer is fakeServer's twin over a named pipe: one listening
// instance at a time, each connected instance served on its own goroutine.
type pipeServer struct {
	t       *testing.T
	name    string
	maxInst int
	mu      sync.Mutex
	handler func(method string) (reply bool, result interface{})
	// oneShot: after the first reply the server hangs up (kwi3 restarting).
	oneShot  bool
	fragment bool
	stopped  atomic.Bool
	done     chan struct{}
}

func startPipeServer(t *testing.T, name string, maxInst int) *pipeServer {
	t.Helper()
	s := &pipeServer{t: t, name: name, maxInst: maxInst, done: make(chan struct{}),
		handler: func(string) (bool, interface{}) { return true, map[string]interface{}{} }}
	// Create the first instance before returning, so a dial right after
	// startPipeServer never races the listen goroutine.
	h, err := s.create()
	if err != nil {
		t.Fatalf("CreateNamedPipe %s: %v", name, err)
	}
	go s.listen(h)
	t.Cleanup(s.stop)
	return s
}

func (s *pipeServer) create() (syscall.Handle, error) {
	name, _ := syscall.UTF16PtrFromString(s.name)
	r, _, err := procCreateNamedPipeW.Call(uintptr(unsafe.Pointer(name)),
		pipeAccessDuplex, pipeTypeByteWait, uintptr(s.maxInst), 65536, 65536, 0, 0)
	if syscall.Handle(r) == syscall.InvalidHandle {
		return syscall.InvalidHandle, err
	}
	return syscall.Handle(r), nil
}

func (s *pipeServer) listen(h syscall.Handle) {
	defer close(s.done)
	for {
		r, _, err := procConnectNamedPipe.Call(uintptr(h), 0)
		if r == 0 && !errors.Is(err, errorPipeConnected) {
			syscall.CloseHandle(h)
			return
		}
		if s.stopped.Load() {
			procDisconnectNamedPipe.Call(uintptr(h))
			syscall.CloseHandle(h)
			return
		}
		go s.serve(h)
		for {
			if s.stopped.Load() {
				return
			}
			nh, err := s.create()
			if err == nil {
				h = nh
				break
			}
			// Every instance taken (maxInst): wait for one to be freed.
			time.Sleep(10 * time.Millisecond)
		}
	}
}

// stop ends the listen loop: no new instance is created, and the one
// parked in ConnectNamedPipe is woken by a throwaway client. Instances
// already connected are left to their own client.
func (s *pipeServer) stop() {
	if s.stopped.Swap(true) {
		<-s.done
		return
	}
	name, _ := syscall.UTF16PtrFromString(s.name)
	deadline := time.Now().Add(3 * time.Second)
	for {
		select {
		case <-s.done:
			return
		default:
		}
		if h, err := syscall.CreateFile(name, syscall.GENERIC_READ|syscall.GENERIC_WRITE,
			0, nil, syscall.OPEN_EXISTING, 0, 0); err == nil {
			syscall.CloseHandle(h)
		}
		if time.Now().After(deadline) {
			s.t.Errorf("pipe server %s did not stop", s.name)
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

type handleRW syscall.Handle

func (h handleRW) Read(p []byte) (int, error) {
	var n uint32
	if err := syscall.ReadFile(syscall.Handle(h), p, &n, nil); err != nil {
		return int(n), err
	}
	if n == 0 {
		return 0, io.EOF
	}
	return int(n), nil
}

func (h handleRW) Write(p []byte) (int, error) {
	var n uint32
	err := syscall.WriteFile(syscall.Handle(h), p, &n, nil)
	return int(n), err
}

func (s *pipeServer) serve(h syscall.Handle) {
	defer func() {
		procFlushFileBuffers.Call(uintptr(h)) // let the client read what was written
		procDisconnectNamedPipe.Call(uintptr(h))
		syscall.CloseHandle(h)
	}()
	r := bufio.NewReader(handleRW(h))
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		var req struct {
			ID     int64  `json:"id"`
			Method string `json:"method"`
		}
		if json.Unmarshal(line, &req) != nil {
			continue
		}
		s.mu.Lock()
		hd, frag, once := s.handler, s.fragment, s.oneShot
		s.mu.Unlock()
		reply, result := hd(req.Method)
		if !reply {
			if once {
				return // hang up without answering
			}
			continue // never answer this one
		}
		out, _ := json.Marshal(map[string]interface{}{"jsonrpc": "2.0", "id": req.ID, "result": result})
		out = append(out, '\n')
		if frag {
			for _, b := range out {
				handleRW(h).Write([]byte{b})
			}
		} else {
			handleRW(h).Write(out)
		}
		if once {
			return
		}
	}
}

func (s *pipeServer) set(f func(*pipeServer)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f(s)
}

func workspaceListHandler(method string) (bool, interface{}) {
	if method != "workspace.list" {
		return true, map[string]interface{}{}
	}
	return true, []map[string]interface{}{
		{"id": 3, "num": 1, "name": "1", "focused": true},
		{"id": 7, "num": 2, "name": "2", "focused": false},
	}
}

func TestPipePathIsRecognised(t *testing.T) {
	for path, want := range map[string]bool{
		`\\.\pipe\kwi3-jan-Default`: true,
		`\\.\PIPE\kwi3-jan-Default`: true,
		`\\.\pipe\`:                 true,
		`C:\Users\x\kwi3.rpc.sock`:  false,
		`/tmp/kwi3.rpc.sock`:        false,
		`\\.\pip`:                   false,
		``:                          false,
	} {
		if got := isPipePath(path); got != want {
			t.Errorf("isPipePath(%q) = %v, want %v", path, got, want)
		}
	}
}

// Criterion 1's shape against a test pipe: $KWI3SOCK=\\.\pipe\... dials the
// pipe and workspace.list answers.
func TestPipeClientWorkspaceList(t *testing.T) {
	s := startPipeServer(t, testPipeName(), pipeUnlimitedInstanc)
	s.set(func(s *pipeServer) { s.handler = workspaceListHandler })
	c := New(s.name)
	defer c.Close()
	raw, err := c.Call("workspace.list", nil)
	if err != nil {
		t.Fatalf("workspace.list over %s: %v", s.name, err)
	}
	var list []struct {
		Num     int  `json:"num"`
		Focused bool `json:"focused"`
	}
	if err := json.Unmarshal(raw, &list); err != nil || len(list) != 2 || !list[0].Focused || list[1].Num != 2 {
		t.Fatalf("workspace.list: got %s (%v)", raw, err)
	}
	// The connection is kept: a second call rides the same instance.
	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("second call: %v", err)
	}
	// And Dispatch's local next/prev arithmetic works over a pipe too.
	if err := c.Dispatch("workspace next"); err != nil {
		t.Fatalf("Dispatch over pipe: %v", err)
	}
}

// A pipe delivers the reply in pieces: a byte at a time, no trailing write
// coalescing. ReadBytes('\n') must still assemble one line.
func TestPipeClientFragmentedReply(t *testing.T) {
	s := startPipeServer(t, testPipeName(), pipeUnlimitedInstanc)
	s.set(func(s *pipeServer) { s.handler = workspaceListHandler; s.fragment = true })
	c := New(s.name)
	defer c.Close()
	raw, err := c.Call("workspace.list", nil)
	if err != nil || !strings.Contains(string(raw), `"focused":true`) {
		t.Fatalf("fragmented reply: %s, %v", raw, err)
	}
}

// Criterion 2: a pipe that does not exist fails within 1 s, names the pipe,
// is ErrUnreachable, logs once - and the next Call, once the pipe exists,
// connects with no help.
func TestPipeMissingFailsFastNamedAndRetries(t *testing.T) {
	name := testPipeName()
	var logs []string
	var mu sync.Mutex
	c := New(name, WithLog(func(l string) { mu.Lock(); logs = append(logs, l); mu.Unlock() }))
	defer c.Close()
	for i := 0; i < 3; i++ {
		start := time.Now()
		_, err := c.Call("workspace.list", nil)
		took := time.Since(start)
		if err == nil {
			t.Fatal("no pipe: expected an error")
		}
		if took > time.Second {
			t.Fatalf("a missing pipe took %s to fail, want < 1s", took)
		}
		if !errors.Is(err, ErrUnreachable) {
			t.Fatalf("missing pipe should be ErrUnreachable: %v", err)
		}
		if !strings.Contains(err.Error(), name) || !strings.Contains(err.Error(), "does not exist") {
			t.Fatalf("error should name the pipe and say it does not exist: %v", err)
		}
	}
	s := startPipeServer(t, name, pipeUnlimitedInstanc)
	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("pipe now exists, the next call should connect: %v", err)
	}
	s.stop()
	mu.Lock()
	defer mu.Unlock()
	if len(logs) != 2 || !strings.Contains(logs[0], "cannot reach") || !strings.Contains(logs[1], "reconnected") {
		t.Fatalf("want one down line and one up line, got %q", logs)
	}
}

// occupy takes the pipe's only instance with a raw client handle.
func occupy(t *testing.T, name string) syscall.Handle {
	t.Helper()
	p, _ := syscall.UTF16PtrFromString(name)
	h, err := syscall.CreateFile(p, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil, syscall.OPEN_EXISTING, 0, 0)
	if err != nil {
		t.Fatalf("occupy %s: %v", name, err)
	}
	return h
}

// Criterion 3, half one: a busy pipe (its one instance taken) is WAITED on,
// not failed at once - the instance freed 500 ms in, the dial lands.
func TestPipeBusyIsWaitedOn(t *testing.T) {
	s := startPipeServer(t, testPipeName(), 1)
	occupant := occupy(t, s.name)
	go func() {
		time.Sleep(500 * time.Millisecond)
		syscall.CloseHandle(occupant)
	}()
	c := New(s.name)
	defer c.Close()
	start := time.Now()
	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("busy pipe freed after 500ms: the dial should have waited and landed: %v", err)
	}
	if took := time.Since(start); took < 400*time.Millisecond {
		t.Fatalf("connected after %s: the instance was not free yet - was the pipe busy at all?", took)
	}
}

// Criterion 3, half two: a pipe that stays busy fails after the 2 s wait,
// named, and no sooner.
func TestPipeBusyGivesUpAfterTwoSeconds(t *testing.T) {
	s := startPipeServer(t, testPipeName(), 1)
	occupant := occupy(t, s.name)
	defer syscall.CloseHandle(occupant)
	c := New(s.name)
	defer c.Close()
	start := time.Now()
	_, err := c.Call("workspace.list", nil)
	took := time.Since(start)
	if err == nil {
		t.Fatal("a pipe that stays busy should fail")
	}
	if took < 1900*time.Millisecond || took > 3*time.Second {
		t.Fatalf("gave up after %s, want about 2s", took)
	}
	if !errors.Is(err, ErrUnreachable) || !strings.Contains(err.Error(), s.name) || !strings.Contains(err.Error(), "busy") {
		t.Fatalf("error should be ErrUnreachable, name the pipe and say busy: %v", err)
	}
}

// Edge case: the host restarts. Its old instance hangs up; a new host
// serves the same name; the very next Call lands on it (writeLocked's one
// redial), and OnConnect fires once per successful dial -
// TestClientOnConnectFiresPerSuccessfulDial's shape over a pipe, two host
// starts.
func TestPipeClientReconnectsAcrossHostRestart(t *testing.T) {
	name := testPipeName()
	var fired atomic.Int32
	c := New(name, WithOnConnect(func() { fired.Add(1) }))
	defer c.Close()

	s1 := startPipeServer(t, name, pipeUnlimitedInstanc)
	s1.set(func(s *pipeServer) { s.oneShot = true })
	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("first host: %v", err)
	}
	s1.stop() // the old host is gone; its instance already hung up

	s2 := startPipeServer(t, name, pipeUnlimitedInstanc)
	s2.set(func(s *pipeServer) { s.handler = workspaceListHandler })
	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("first call after the restart should land on the new host: %v", err)
	}
	if n := fired.Load(); n != 2 {
		t.Fatalf("two host starts: want OnConnect twice, got %d", n)
	}
}

// Edge case: the host dies mid-call - the read returns EOF. That Call fails
// (never resent: the host may have run it) and the next one reconnects.
func TestPipeReadEOFFailsCallThenReconnects(t *testing.T) {
	s := startPipeServer(t, testPipeName(), pipeUnlimitedInstanc)
	s.set(func(s *pipeServer) {
		s.oneShot = true
		s.handler = func(string) (bool, interface{}) { return false, nil }
	})
	c := New(s.name)
	defer c.Close()
	_, err := c.Call("workspace.list", nil)
	if err == nil || !errors.Is(err, io.EOF) {
		t.Fatalf("a host hanging up mid-call should read as EOF, got %v", err)
	}
	s.set(func(s *pipeServer) { s.oneShot = false; s.handler = workspaceListHandler })
	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("the next call should reconnect: %v", err)
	}
}

// WithCallTimeout works on a pipe (the handle is overlapped, so deadlines
// apply): a host that never answers costs one timeout, then the next Call
// redials.
func TestPipeCallTimeout(t *testing.T) {
	s := startPipeServer(t, testPipeName(), pipeUnlimitedInstanc)
	s.set(func(s *pipeServer) { s.handler = func(string) (bool, interface{}) { return false, nil } })
	c := New(s.name, WithCallTimeout(300*time.Millisecond))
	defer c.Close()
	start := time.Now()
	if _, err := c.Call("workspace.list", nil); err == nil {
		t.Fatal("a host that never answers should time out")
	}
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("timeout of 300ms took %s - deadlines are not applied to the pipe", took)
	}
	s.set(func(s *pipeServer) { s.handler = workspaceListHandler })
	if _, err := c.Call("workspace.list", nil); err != nil {
		t.Fatalf("after a timeout the next call should redial: %v", err)
	}
}

// Edge case: a $KWI3SOCK that is a filesystem path on Windows is dialled as
// AF_UNIX, not as a pipe. (Short test name on purpose: t.TempDir() embeds
// it, and Windows' AF_UNIX sun_path is 108 bytes - the longer-named
// client_test.go tests overflow it under %TEMP%.)
func TestFsPathIsUnix(t *testing.T) {
	addr := filepath.Join(t.TempDir(), "k.sock")
	ln, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatalf("listen unix %s: %v", addr, err)
	}
	s := &fakeServer{t: t, addr: addr, ln: ln,
		handler: func(string, interface{}) (interface{}, int, string) { return []int{1}, 0, "" }}
	go s.acceptLoop()
	defer ln.Close()
	c := New(addr)
	defer c.Close()
	raw, err := c.Call("workspace.list", nil)
	if err != nil || string(raw) != "[1]" {
		t.Fatalf("AF_UNIX at %s: %s, %v", addr, raw, err)
	}
	if c.conn.RemoteAddr().Network() != "unix" {
		t.Fatalf("dialled as %q, want unix", c.conn.RemoteAddr().Network())
	}
	c.Close()
	// And a missing filesystem path is AF_UNIX's error, never "pipe ...".
	_, err = New(filepath.Join(t.TempDir(), "none.sock")).Call("workspace.list", nil)
	if err == nil || strings.Contains(err.Error(), "pipe") {
		t.Fatalf("missing fs path should fail as a socket, not a pipe: %v", err)
	}
}

// TestLiveHostPipe is the integration run against a REAL i3kwin-win32,
// skipped unless a rig names the host's pipe in $KWI3RPC_LIVE_PIPE (the
// host's own "rpc socket on <pipe>" line, on a fresh CreateDesktop desktop -
// never Jan's). workspace.list must answer. With $KWI3RPC_LIVE_SYNC (a
// directory) it also rides a host restart: it writes first-ok, waits for
// the rig to stop the host and start a new one on the same desktop name and
// write restarted, and then ONE Call must land on the new host, with
// OnConnect fired once per host.
func TestLiveHostPipe(t *testing.T) {
	pipe := os.Getenv("KWI3RPC_LIVE_PIPE")
	if pipe == "" {
		t.Skip("KWI3RPC_LIVE_PIPE not set: no live host to dial")
	}
	var fired atomic.Int32
	c := New(pipe, WithOnConnect(func() { fired.Add(1) }))
	defer c.Close()
	// list is one workspace.list: it must answer a JSON array. A host
	// adopts its first window a moment after it says "running", so until
	// then the array may be empty; poll (on the SAME connection) says how
	// long to keep asking for a non-empty one.
	list := func(when string, poll time.Duration) {
		deadline := time.Now().Add(poll)
		for {
			raw, err := c.Call("workspace.list", nil)
			if err != nil {
				t.Fatalf("%s: workspace.list over %s: %v", when, pipe, err)
			}
			var ws []struct {
				Num     int  `json:"num"`
				Focused bool `json:"focused"`
			}
			if err := json.Unmarshal(raw, &ws); err != nil {
				t.Fatalf("%s: workspace.list answered %s (%v)", when, raw, err)
			}
			if len(ws) > 0 || time.Now().After(deadline) {
				t.Logf("%s: workspace.list over %s: %s", when, pipe, raw)
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	list("first host", 10*time.Second)
	sync := os.Getenv("KWI3RPC_LIVE_SYNC")
	if sync == "" {
		return
	}
	if err := os.WriteFile(filepath.Join(sync, "first-ok"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(90 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(sync, "restarted")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the rig never wrote restarted")
		}
		time.Sleep(50 * time.Millisecond)
	}
	list("after restart, first call", 0)
	list("after restart, the new host's windows", 10*time.Second)
	if n := fired.Load(); n != 2 {
		t.Fatalf("two host starts: want OnConnect twice, got %d", n)
	}
}
