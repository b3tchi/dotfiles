package i3

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
	display := ":97"
	sockPath = filepath.Join(dir, "i3ipc-live.sock")
	cfgPath := filepath.Join(dir, "i3-live.conf")
	if err := os.WriteFile(cfgPath,
		[]byte(fmt.Sprintf("font pango:monospace 10\nipc-socket %s\nbindsym Mod4+F11 nop taken-by-i3\n", sockPath)),
		0o644); err != nil {
		t.Fatalf("writing i3 config: %v", err)
	}

	xvfb := exec.Command("Xvfb", display, "-screen", "0", "800x600x24", "-nolisten", "tcp")
	if err := xvfb.Start(); err != nil {
		t.Fatalf("starting Xvfb: %v", err)
	}
	xSockPath := fmt.Sprintf("/tmp/.X11-unix/X%s", strings.TrimPrefix(display, ":"))
	if !waitForPath(xSockPath, 5*time.Second) {
		xvfb.Process.Kill()
		xvfb.Wait()
		t.Fatal("Xvfb did not create its socket in time")
	}

	i3Cmd := exec.Command("i3", "-c", cfgPath)
	i3Cmd.Env = append(os.Environ(), "DISPLAY="+display)
	if err := i3Cmd.Start(); err != nil {
		xvfb.Process.Kill()
		xvfb.Wait()
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
		xvfb.Process.Kill()
		xvfb.Wait()
		os.Remove(sockPath)
	}

	ready := waitForPath(sockPath, 5*time.Second) && i3Answers(display, sockPath)
	if !ready {
		cleanup()
		t.Fatal("live i3 did not start")
	}
	return sockPath, killI3, cleanup
}

func waitForPath(path string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

// i3Answers probes readiness the same way test-hotkeyd.sh does: a real
// i3-msg round trip with I3SOCK pinned, so a socket file existing (i3 not
// yet finished its own startup) is not mistaken for readiness.
func i3Answers(display, sockPath string) bool {
	cmd := exec.Command("i3-msg", "-t", "get_version")
	cmd.Env = append(os.Environ(), "DISPLAY="+display, "I3SOCK="+sockPath)
	return cmd.Run() == nil
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
