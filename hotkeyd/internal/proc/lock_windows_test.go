package proc

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestPaths_UnderLocalAppDataKeyedOnDesktop(t *testing.T) {
	base := t.TempDir()
	t.Setenv("LOCALAPPDATA", base)
	dir := filepath.Join(base, "hotkeyd")
	for _, c := range []struct{ got, want string }{
		{LockPath("kwi3t-12-x"), filepath.Join(dir, "kwi3t-12-x.lock")},
		{ControlPath("kwi3t-12-x"), filepath.Join(dir, "kwi3t-12-x.sock")},
		{GrabReportPath("kwi3t-12-x"), filepath.Join(dir, "kwi3t-12-x.grabs")},
		{ControlPath(`a b\c.d`), filepath.Join(dir, "a_b_c_d.sock")},
		{ControlPath(""), filepath.Join(dir, "Default.sock")},
		{ControlPath(":10.0"), filepath.Join(dir, "10.sock")},
	} {
		if c.got != c.want {
			t.Errorf("got %q, want %q", c.got, c.want)
		}
	}
}

func TestExpandHome(t *testing.T) {
	t.Setenv("USERPROFILE", `C:\Users\Jan Bečka`)
	for in, want := range map[string]string{
		"~":         `C:\Users\Jan Bečka`,
		"~/x.exe":   `C:\Users\Jan Bečka\x.exe`,
		`~\a/b.exe`: `C:\Users\Jan Bečka\a\b.exe`,
		"wt.exe":    "wt.exe",
		"a~/b":      "a~/b",
		`C:\x\~\y`:  `C:\x\~\y`,
	} {
		if got := ExpandHome(in); got != want {
			t.Errorf("ExpandHome(%q) = %q, want %q", in, got, want)
		}
	}
}

// A second hotkeyd for the same desktop - another process holding the
// lock - is refused, and the refusal names the holder's pid.
func TestLock_SecondHotkeydRefusedNamingHolderPid(t *testing.T) {
	base := t.TempDir()
	t.Setenv("LOCALAPPDATA", base)
	path := LockPath("kwi3t-lock")
	ready := filepath.Join(base, "ready")
	holder := startHelper(t, "locker", "LOCKER_PATH="+path, "LOCKER_READY="+ready)
	if got := waitFile(t, ready, 15*time.Second); got != strconv.Itoa(holder.Process.Pid) {
		t.Fatalf("locker: %q", got)
	}

	_, err := AcquireLock(path)
	var running *ErrAlreadyRunning
	if !errors.As(err, &running) {
		t.Fatalf("AcquireLock with the lock held elsewhere = %v, want *ErrAlreadyRunning", err)
	}
	if running.PID != holder.Process.Pid || !strings.Contains(err.Error(), fmt.Sprintf("pid %d", holder.Process.Pid)) {
		t.Fatalf("refusal %q (PID %d) does not name the holder %d", err, running.PID, holder.Process.Pid)
	}
}

// A lock left by a killed hotkeyd is taken over, and that is said exactly
// once, naming the dead pid. Re-taking our own lock later says nothing.
func TestLock_StaleLockFromKilledHolderTakenOverSaidOnce(t *testing.T) {
	base := t.TempDir()
	t.Setenv("LOCALAPPDATA", base)
	path := LockPath("kwi3t-stale")
	ready := filepath.Join(base, "ready")
	holder := startHelper(t, "locker", "LOCKER_PATH="+path, "LOCKER_READY="+ready)
	waitFile(t, ready, 15*time.Second)
	if err := holder.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = holder.Wait()

	var said []string
	old := Log
	Log = func(m string) { said = append(said, m) }
	t.Cleanup(func() { Log = old })

	l, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("AcquireLock over a dead holder's lock: %v", err)
	}
	if len(said) != 1 || !strings.Contains(said[0], fmt.Sprintf("pid %d", holder.Process.Pid)) {
		t.Fatalf("said %q, want one line naming the dead pid %d", said, holder.Process.Pid)
	}
	if pid, _ := LockPID(path); pid != os.Getpid() {
		t.Fatalf("lock names pid %d after takeover, want %d", pid, os.Getpid())
	}
	if !HasHeartbeat(path) {
		t.Fatal("lock has no heartbeat marker after takeover")
	}
	l.Release()

	l, err = AcquireLock(path)
	if err != nil {
		t.Fatalf("re-acquire: %v", err)
	}
	l.Release()
	if len(said) != 1 {
		t.Fatalf("re-taking our own lock said %q", said[1:])
	}
}

// LockHeld (sp012 Task 7, what `hotkeyd recover` asks before it ends the
// pid a lock names): true while another process holds the lock, false once
// that holder is dead or when there is no lock file, and asking never
// takes the lock away from anybody.
func TestLockHeld_TrueOnlyWhileAHolderLives(t *testing.T) {
	base := t.TempDir()
	t.Setenv("LOCALAPPDATA", base)
	path := LockPath("kwi3t-held")
	if LockHeld(path) {
		t.Fatal("LockHeld with no lock file = true")
	}
	ready := filepath.Join(base, "ready")
	holder := startHelper(t, "locker", "LOCKER_PATH="+path, "LOCKER_READY="+ready)
	waitFile(t, ready, 15*time.Second)
	if !LockHeld(path) {
		t.Fatal("LockHeld while the locker holds it = false")
	}
	if !LockHeld(path) {
		t.Fatal("asking twice changed the answer")
	}
	if err := holder.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = holder.Wait()
	if LockHeld(path) {
		t.Fatal("LockHeld after the holder was killed = true")
	}
	// Asking left it free: a daemon can still take it.
	l, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("AcquireLock after LockHeld: %v", err)
	}
	defer l.Release()
	if !LockHeld(path) {
		t.Fatal("LockHeld while this process holds it = false")
	}
}

// kwi3-hoex.30: a holder that RELEASES its lock (a daemon's clean
// shutdown) leaves the file naming no pid, so the next start has nobody to
// take over from and says nothing.
func TestLock_CleanReleaseLeavesNoPidAndTheNextStartSaysNothing(t *testing.T) {
	base := t.TempDir()
	t.Setenv("LOCALAPPDATA", base)
	path := LockPath("kwi3t-clean")
	ready := filepath.Join(base, "ready")
	holder := startHelper(t, "locker", "LOCKER_PATH="+path, "LOCKER_READY="+ready, "LOCKER_RELEASE=1")
	waitFile(t, ready, 15*time.Second)
	if err := holder.Wait(); err != nil {
		t.Fatalf("locker: %v", err)
	}
	if pid, ok := LockPID(path); ok {
		t.Fatalf("a released lock still names pid %d", pid)
	}
	if LockHeld(path) {
		t.Fatal("LockHeld after the holder released = true")
	}

	var said []string
	old := Log
	Log = func(m string) { said = append(said, m) }
	t.Cleanup(func() { Log = old })
	l, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("AcquireLock after a clean release: %v", err)
	}
	defer l.Release()
	if len(said) != 0 {
		t.Fatalf("the start after a clean release said %q, want nothing", said)
	}
	if pid, _ := LockPID(path); pid != os.Getpid() {
		t.Fatalf("lock names pid %d, want %d", pid, os.Getpid())
	}
}
