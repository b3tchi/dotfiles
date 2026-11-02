package i3

import (
	"fmt"
	"math/rand/v2"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// requireBinary skips the test if name is not on PATH -- mirrors
// internal/x11's xvfb_integration_test.go helper of the same name (kept
// local rather than imported: this task stays inside internal/i3).
func requireBinary(t *testing.T, name string) {
	t.Helper()
	if _, err := exec.LookPath(name); err != nil {
		t.Skipf("%s not available on PATH: %v", name, err)
	}
}

// startLiveI3 launches Xvfb + a real i3 on a scratch display and ipc
// socket, mirroring test-hotkeyd.sh stage 6's rig (same display number
// convention, same "I3SOCK pinned" reasoning: unpinned, i3-msg/this
// client would follow the AMBIENT $I3SOCK on a developer machine and
// silently test the WRONG i3 -- dotfiles-qvou). Returns the socket path, a
// killI3 func that kills ONLY this test's i3 process (for the death-path
// test, without touching any other i3 running on the host), and a cleanup
// func; skips cleanly if Xvfb or i3 is missing.
func startLiveI3(t *testing.T) (sockPath string, killI3 func(), cleanup func()) {
	t.Helper()
	requireBinary(t, "Xvfb")
	requireBinary(t, "i3")

	dir := t.TempDir()
	sockPath = filepath.Join(dir, "i3ipc-live.sock")
	cfgPath := filepath.Join(dir, "i3-live.conf")
	if err := os.WriteFile(cfgPath,
		[]byte(fmt.Sprintf("font pango:monospace 10\nipc-socket %s\nbindsym Mod4+F11 nop taken-by-i3\n", sockPath)),
		0o644); err != nil {
		t.Fatalf("writing i3 config: %v", err)
	}

	xvfb := startOwnXvfb(t)
	display := fmt.Sprintf(":%d", xvfb.num)

	// --shmlog-size 0: no SHM log. i3 unlinks its 25 MB /dev/shm/i3-log-<pid>
	// only on a clean exit, and killI3 is a SIGKILL, so every run of this
	// package used to leave two behind (kwi3-hoex.31: 476 of them had filled
	// /dev/shm, and i3 then failed to start - "Could not ftruncate SHM
	// segment for the i3 log: No space left on device").
	i3Cmd := exec.Command("i3", "--shmlog-size", "0", "-c", cfgPath)
	i3Cmd.Env = append(os.Environ(), "DISPLAY="+display)
	i3Out := &syncBuilder{} // i3's own words, for a start that fails
	i3Cmd.Stdout, i3Cmd.Stderr = i3Out, i3Out
	if err := i3Cmd.Start(); err != nil {
		xvfb.stop()
		t.Fatalf("starting i3: %v", err)
	}

	i3Killed := false
	killI3 = func() {
		if i3Killed {
			return
		}
		i3Killed = true
		i3Cmd.Process.Kill()
		i3Cmd.Wait()
	}
	cleanup = func() {
		killI3()
		xvfb.stop()
		os.Remove(sockPath)
	}

	// The socket FILE is not readiness: i3 binds it before it listens, so
	// one i3-msg straight after it appears can be refused (kwi3-hoex.31,
	// measured: about 1 in 15 starts with four runs at once, i3 silent).
	// Ask until it answers, within the same 5 s.
	var probe string
	ready := false
	deadline := time.Now().Add(5 * time.Second)
	for !ready && time.Now().Before(deadline) {
		if _, err := os.Stat(sockPath); err == nil {
			ready, probe = i3Answers(display, sockPath)
		}
		if !ready {
			time.Sleep(50 * time.Millisecond)
		}
	}
	if !ready {
		cleanup()
		t.Fatalf("live i3 did not start on %s; last i3-msg: %q; i3 said:\n%s", display, probe, i3Out.String())
	}
	return sockPath, killI3, cleanup
}

// startOwnXvfb starts an Xvfb on a display of its own and returns it once
// it serves: a random number in 200..2199 (internal/x11's range), tried
// again elsewhere when that display is someone else's. It used to be a
// fixed :97, so two runs of this package at once - two `go test` runs, two
// worktrees, two agents - shared one display: the loser's Xvfb exited
// "already active", its i3 met the winner's i3 on the winner's server, and
// either run could fail "live i3 did not start" (kwi3-hoex.31, measured:
// two concurrent -count=10 runs, both red). Ours is decided by the X lock,
// which Xvfb writes before it listens: /tmp/.X<n>-lock naming OUR pid
// while the process lives, never a socket that merely answers.
func startOwnXvfb(t *testing.T) *ownXvfb {
	t.Helper()
	for attempt := 0; attempt < 20; attempt++ {
		n := 200 + rand.IntN(2000)
		xSock := fmt.Sprintf("/tmp/.X11-unix/X%d", n)
		if xAnswers(xSock) {
			continue // a server is already there
		}
		xvfb := exec.Command("Xvfb", fmt.Sprintf(":%d", n), "-screen", "0", "800x600x24", "-nolisten", "tcp", "-noreset")
		if err := xvfb.Start(); err != nil {
			t.Fatalf("starting Xvfb: %v", err)
		}
		x := &ownXvfb{cmd: xvfb, num: n, exited: make(chan struct{})}
		go func() { _ = xvfb.Wait(); close(x.exited) }()
		if ownsDisplay(xvfb.Process.Pid, n, x.exited, 5*time.Second) && waitForX(xSock, 5*time.Second) {
			return x
		}
		x.stop() // lost the display to another server (or never served): try another
	}
	t.Fatal("could not start an Xvfb on a display of its own in 20 tries")
	return nil
}

// ownXvfb is a test Xvfb this process started, and the display it holds.
type ownXvfb struct {
	cmd    *exec.Cmd
	num    int
	exited chan struct{}
}

// stop ends it with SIGTERM, so it removes its own /tmp/.X<n>-lock on the
// way out, falling back to SIGKILL if it hangs. A SIGKILLed Xvfb strands
// the lock, and every run of the suite used to leave one per test.
func (x *ownXvfb) stop() {
	_ = x.cmd.Process.Signal(syscall.SIGTERM) // our own child, by its handle
	select {
	case <-x.exited:
	case <-time.After(2 * time.Second):
		_ = x.cmd.Process.Kill()
		<-x.exited
	}
	removeOwnXLock(x.num, x.cmd.Process.Pid)
}

// ownsDisplay waits until /tmp/.X<n>-lock names pid, or the server exits.
func ownsDisplay(pid, n int, exited <-chan struct{}, within time.Duration) bool {
	lock := fmt.Sprintf("/tmp/.X%d-lock", n)
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		select {
		case <-exited:
			return false
		default:
		}
		if b, err := os.ReadFile(lock); err == nil && strings.TrimSpace(string(b)) == fmt.Sprint(pid) {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

// syncBuilder is a strings.Builder exec's copier may write while the test
// reads it.
type syncBuilder struct {
	mu sync.Mutex
	b  strings.Builder
}

func (s *syncBuilder) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuilder) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// waitForX waits for an X socket, which may exist only in Linux's
// abstract namespace: under WSLg /tmp/.X11-unix is a read-only mount, so
// Xvfb cannot create the file and binds "@/tmp/.X11-unix/X<n>" alone.
func waitForX(path string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if xAnswers(path) {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

// xAnswers is one look for an X socket: its file, else its abstract name.
func xAnswers(path string) bool {
	if _, err := os.Stat(path); err == nil {
		return true
	}
	if c, err := net.Dial("unix", "@"+path); err == nil {
		c.Close()
		return true
	}
	return false
}

// i3Answers probes readiness the same way test-hotkeyd.sh does: a real
// i3-msg round trip with I3SOCK pinned, so a socket file existing (i3 not
// yet finished its own startup) is not mistaken for readiness. It says
// what i3-msg printed, for a start that never answers.
func i3Answers(display, sockPath string) (bool, string) {
	cmd := exec.Command("i3-msg", "-t", "get_version")
	cmd.Env = append(os.Environ(), "DISPLAY="+display, "I3SOCK="+sockPath)
	out, err := cmd.CombinedOutput()
	return err == nil, strings.TrimSpace(string(out))
}

func TestIntegration_Client_AgainstRealI3(t *testing.T) {
	sockPath, _, cleanup := startLiveI3(t)
	defer cleanup()

	c := NewClient(func() (string, error) { return sockPath, nil }, nil)
	defer c.Close()

	t.Run("Command", func(t *testing.T) {
		ok, i3Err, err := c.Command("nop hello-from-hotkeyd-i3-client")
		if err != nil {
			t.Fatalf("Command: unexpected transport error: %v", err)
		}
		if !ok {
			t.Errorf("ok = false, i3Err = %q", i3Err)
		}
	})

	t.Run("Command_SurfacesI3Error", func(t *testing.T) {
		// A syntactically invalid command i3 itself rejects -- proves
		// success:false and its error text really do come from i3, not a
		// fixture, over the real protocol.
		ok, i3Err, err := c.Command("this is not a real i3 command")
		if err != nil {
			t.Fatalf("Command: unexpected transport error: %v", err)
		}
		if ok {
			t.Error("ok = true for a nonsense command, want false")
		}
		if i3Err == "" {
			t.Error("i3Err = empty, want i3's own rejection text")
		}
	})

	t.Run("GetConfig", func(t *testing.T) {
		cfg, err := c.GetConfig()
		if err != nil {
			t.Fatalf("GetConfig: %v", err)
		}
		if !strings.Contains(cfg, "Mod4+F11") {
			t.Errorf("config = %q, want it to contain the fixture's bindsym", cfg)
		}
	})

	t.Run("Subscribe_and_BindingState", func(t *testing.T) {
		if err := c.Subscribe("mode"); err != nil {
			t.Fatalf("Subscribe: %v", err)
		}
		state, err := c.BindingState()
		if err != nil {
			t.Fatalf("BindingState: %v", err)
		}
		if state != "default" {
			t.Errorf("state = %q, want %q (no mode entered)", state, "default")
		}
	})

	t.Run("Fileno_reflects_live_connection", func(t *testing.T) {
		if _, ok := c.Fileno(); !ok {
			t.Error("Fileno ok = false after successful requests against a live i3")
		}
	})
}

// TestIntegration_Client_I3Death exercises the extracted behaviour matrix
// against a REAL i3 process instead of the in-process fake: killing i3
// must surface a named, non-hanging error rather than wedging the client.
func TestIntegration_Client_I3Death(t *testing.T) {
	sockPath, killI3, cleanup := startLiveI3(t)
	defer cleanup()

	c := NewClient(func() (string, error) { return sockPath, nil }, nil)
	defer c.Close()

	// Establish the persistent connection against the LIVE i3 first, so
	// killing it below is a genuine "i3 dies mid-session" scenario, not
	// just "the socket never existed".
	if _, err := c.GetConfig(); err != nil {
		t.Fatalf("GetConfig against live i3: %v", err)
	}
	killI3()

	done := make(chan struct{})
	var ok bool
	var err error
	go func() {
		defer close(done)
		ok, _, err = c.Command("nop should-fail")
	}()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Command did not return within 10s after i3 was killed -- adr0014 violation (unbounded block)")
	}
	if err == nil {
		t.Fatal("expected a transport error dispatching to a dead i3")
	}
	if ok {
		t.Error("ok = true dispatching to a dead i3, want false")
	}
}

// removeOwnXLock deletes /tmp/.X<n>-lock only when it names pid: an Xvfb
// that lost the display to another server must not take that server's
// lock with it.
func removeOwnXLock(dispNum, pid int) {
	lock := fmt.Sprintf("/tmp/.X%d-lock", dispNum)
	if b, err := os.ReadFile(lock); err == nil && strings.TrimSpace(string(b)) == fmt.Sprint(pid) {
		os.Remove(lock)
	}
}
