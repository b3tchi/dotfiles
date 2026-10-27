//go:build windows

package main

// kwi3-hoex.30: `hotkeyd stop` on real Windows, through hotkeyd/test-win32.sh
// (the "_Windows_" name is its filter): this test binary run as hotkeyd
// (recover_windows_test.go's TestMain) is the daemon, and `<test.exe> stop`
// is the stop.
//
// SAFETY, as recover_windows_test.go: every daemon is a DRY RUN (nothing
// registered, no hook), %LOCALAPPDATA% is private per test, $KWI3SOCK is a
// pipe this test serves or one nobody serves. The only processes ended are
// this test's own children - by the stop under test (only ever this
// binary, a copy of it named hotkeyd.exe, or nothing), or by their own
// handle in cleanup.

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"hotkeyd/internal/proc"
)

// asLockHolderEnv names a ready file: the binary takes this desktop's lock,
// writes its pid there and holds the lock for a minute, with no control
// socket - a daemon whose control socket is absent.
const asLockHolderEnv = "HOTKEYD_TEST_LOCK_HOLDER"

func holdLock(ready string) int {
	l, err := proc.AcquireLock(proc.LockPath(resolveDisplay("")))
	if err != nil {
		_ = os.WriteFile(ready, []byte("ERR "+err.Error()), 0o644)
		return 1
	}
	defer l.Release()
	_ = os.WriteFile(ready, []byte(strconv.Itoa(os.Getpid())), 0o644)
	time.Sleep(time.Minute)
	return 0
}

// syncBuf is a bytes.Buffer a child's stderr copier may write while the
// test reads it.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

var _ io.Writer = (*syncBuf)(nil)

// runStopProcess runs `<exe> stop` with env; exit code and combined output.
func runStopProcess(t *testing.T, exe string, env []string) (int, string, time.Duration) {
	t.Helper()
	cmd := exec.Command(exe, "stop")
	cmd.Env = env
	start := time.Now()
	out, err := cmd.CombinedOutput()
	took := time.Since(start)
	code := 0
	if err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("stop: %v", err)
		}
		code = ee.ExitCode()
	}
	t.Logf("stop (%s) exit %d:\n%s", took.Round(time.Millisecond), code, out)
	return code, string(out), took
}

// startDaemonLogged starts this binary as a dry-run daemon, its stderr
// kept.
func startDaemonLogged(t *testing.T, pipe string) (*exec.Cmd, *syncBuf, chan error) {
	t.Helper()
	cmd := exec.Command(selfExe(t), "--input", "win32")
	cmd.Env = hotkeydEnv(pipe)
	buf := &syncBuf{}
	cmd.Stderr = buf
	if err := cmd.Start(); err != nil {
		t.Fatalf("start hotkeyd: %v", err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill() // our own child, by its handle
		}
	})
	return cmd, buf, done
}

func waitExit(t *testing.T, done chan error, within time.Duration, what string) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(within):
		t.Fatalf("%s is still running %s later", what, within)
		return nil
	}
}

// A running daemon: stop exits 0, the daemon shut down on the control
// socket's stop (exit 0, its chords released, its lock let go and emptied),
// and the next start takes the lock with no "taking over" line.
func TestStop_Windows_DaemonUp_StopsCleanly_NextStartSaysNoTakeover(t *testing.T) {
	privateLocalAppData(t)
	pipe := testPipeName()
	serveKwi3Pipe(t, pipe)
	t.Cleanup(func() { stopOwnDaemon(t) })
	lp := proc.LockPath(resolveDisplay(""))

	old, oldLog, oldDone := startDaemonLogged(t, pipe)
	t.Logf("before: %s", waitHealthy(t, 10*time.Second))

	code, out, _ := runStopProcess(t, selfExe(t), hotkeydEnv(pipe))
	if code != 0 {
		t.Fatalf("stop = %d, want 0", code)
	}
	if err := waitExit(t, oldDone, 3*time.Second, "the stopped daemon"); err != nil {
		t.Fatalf("the daemon exited with %v, want 0 after the control socket's stop", err)
	}
	t.Logf("daemon log:\n%s", oldLog.String())
	if !strings.Contains(out, fmt.Sprintf("pid %d stopped", old.Process.Pid)) || strings.Contains(out, "BY PID") || strings.Contains(out, "ended by pid") {
		t.Fatalf("stop output does not show a clean control stop of pid %d:\n%s", old.Process.Pid, out)
	}
	if !strings.Contains(oldLog.String(), "control: stop requested") {
		t.Fatal("the daemon never logged the control socket's stop")
	}
	if proc.LockHeld(lp) {
		t.Fatal("the lock is still held after stop")
	}
	if pid, ok := proc.LockPID(lp); ok {
		t.Fatalf("the lock still names pid %d after a clean stop", pid)
	}
	if code, msg := runHealth(""); code == HealthOK {
		t.Fatalf("--health after stop = %d %q, want not serving", code, msg)
	}

	// The next start: no "taking over", and stop works on it again.
	_, newLog, newDone := startDaemonLogged(t, pipe)
	waitHealthy(t, 10*time.Second)
	if code, _, _ := runStopProcess(t, selfExe(t), hotkeydEnv(pipe)); code != 0 {
		t.Fatalf("second stop = %d, want 0", code)
	}
	waitExit(t, newDone, 3*time.Second, "the second daemon")
	t.Logf("second daemon log:\n%s", newLog.String())
	if strings.Contains(newLog.String(), "taking over") {
		t.Fatalf("the start after a clean stop took over a stale lock:\n%s", newLog.String())
	}
}

func TestStop_Windows_NoneRunning_ExitsZeroNotRunning(t *testing.T) {
	privateLocalAppData(t)
	code, out, _ := runStopProcess(t, selfExe(t), hotkeydEnv(testPipeName()))
	if code != 0 || !strings.Contains(out, "not running") {
		t.Fatalf("stop with none running = %d %q, want 0 saying not running", code, out)
	}
}

// startLockHolder starts exe as a lock holder with no control socket and
// waits until it holds the lock; its pid.
func startLockHolder(t *testing.T, exe string) (*exec.Cmd, chan error) {
	t.Helper()
	ready := filepath.Join(t.TempDir(), "ready")
	cmd := exec.Command(exe)
	cmd.Env = append(os.Environ(), asLockHolderEnv+"="+ready)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start lock holder: %v", err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill() // our own child, by its handle
		}
	})
	deadline := time.Now().Add(15 * time.Second)
	for {
		if b, err := os.ReadFile(ready); err == nil && len(b) > 0 {
			if strings.HasPrefix(string(b), "ERR") {
				t.Fatalf("lock holder: %s", b)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the lock holder never took the lock")
		}
		time.Sleep(50 * time.Millisecond)
	}
	return cmd, done
}

// A daemon whose control socket is absent is ended by the pid its lock
// names: this very binary, and a copy of it named hotkeyd.exe.
func TestStop_Windows_NoControlSocket_EndedByPid(t *testing.T) {
	for _, tc := range []struct {
		name string
		exe  func(t *testing.T) string
	}{
		{"this binary", selfExe},
		{"hotkeyd.exe", func(t *testing.T) string {
			dst := filepath.Join(t.TempDir(), "hotkeyd.exe")
			src, err := os.ReadFile(selfExe(t))
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(dst, src, 0o755); err != nil {
				t.Fatal(err)
			}
			return dst
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			privateLocalAppData(t)
			holder, done := startLockHolder(t, tc.exe(t))
			code, out, took := runStopProcess(t, selfExe(t), hotkeydEnv(testPipeName()))
			if code != 0 {
				t.Fatalf("stop = %d, want 0", code)
			}
			waitExit(t, done, 3*time.Second, "the lock holder")
			if !strings.Contains(out, "BY PID") || !strings.Contains(out, fmt.Sprintf("pid %d ended by pid", holder.Process.Pid)) {
				t.Fatalf("stop output does not show pid %d ended by pid:\n%s", holder.Process.Pid, out)
			}
			if took > stopWait+3*time.Second {
				t.Fatalf("stop took %s", took)
			}
			if proc.LockHeld(proc.LockPath(resolveDisplay(""))) {
				t.Fatal("the lock is still held")
			}
		})
	}
}

// A lock naming a pid that is not hotkeyd - a ping.exe this test started -
// is refused: exit 1 naming the image, and the process left running.
func TestStop_Windows_LockNamesNotHotkeyd_RefusedNothingEnded(t *testing.T) {
	privateLocalAppData(t)
	ping := exec.Command("ping.exe", "-n", "60", "127.0.0.1")
	if err := ping.Start(); err != nil {
		t.Fatal(err)
	}
	pingDone := make(chan struct{})
	go func() { _ = ping.Wait(); close(pingDone) }()
	t.Cleanup(func() {
		_ = ping.Process.Kill() // our own child, by its handle
		<-pingDone
	})

	// The lock held by THIS process, its file naming ping's pid: the
	// lock byte is at 4 GiB, so the pid line stays writable.
	lp := proc.LockPath(resolveDisplay(""))
	l, err := proc.AcquireLock(lp)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Release()
	if err := os.WriteFile(lp, []byte(fmt.Sprintf("%d\n%s\n", ping.Process.Pid, proc.LockMarker)), 0o644); err != nil {
		t.Fatal(err)
	}

	code, out, _ := runStopProcess(t, selfExe(t), hotkeydEnv(testPipeName()))
	if code != 1 {
		t.Fatalf("stop = %d, want 1", code)
	}
	if !strings.Contains(strings.ToLower(out), "ping.exe") || !strings.Contains(out, "nothing ended") {
		t.Fatalf("stop output does not name ping.exe and nothing ended:\n%s", out)
	}
	select {
	case <-pingDone:
		t.Fatal("stop ended a pid that is not hotkeyd")
	case <-time.After(300 * time.Millisecond):
	}
	if !pidAlive(ping.Process.Pid) {
		t.Fatal("ping is not alive after a refused stop")
	}
}
