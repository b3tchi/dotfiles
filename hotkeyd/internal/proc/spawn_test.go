package proc

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestRun_ExecutesTheCommand(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "ran")

	if err := Run(fmt.Sprintf("touch %s", shellQuote(marker))); err != nil {
		t.Fatalf("Run: %v", err)
	}

	waitForFile(t, marker, 2*time.Second)
}

func TestStart_NoZombieAccumulation(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "exit 0")
	started, err := start(cmd)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	pid := started.Process.Pid

	deadline := time.Now().Add(2 * time.Second)
	for {
		proc, _ := os.FindProcess(pid) // Unix: always succeeds regardless of liveness
		err := proc.Signal(syscall.Signal(0))
		if err != nil {
			// ESRCH: the kernel has fully reaped this pid -- it never
			// lingered as a zombie waiting for a Wait() that never came.
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("pid %d still present (zombie or otherwise) after timeout -- not reaped", pid)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestStart_DoesNotLeakParentFDsIntoChild proves the spawn path protects
// against inherited file descriptors the daemon never intended to hand a
// child -- the concrete worry named in the task: the X11 connection or
// the i3 IPC socket. It opens a RAW, non-CLOEXEC file descriptor (the
// shape a hand-rolled socket that forgot SOCK_CLOEXEC would produce --
// stdlib-created fds are already CLOEXEC by default, so this simulates
// the actual risk rather than testing something Go already guarantees),
// spawns a child via start(), and asserts that fd number is absent from
// the child's own /proc/self/fd listing.
func TestStart_DoesNotLeakParentFDsIntoChild(t *testing.T) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0) // deliberately no SOCK_CLOEXEC
	if err != nil {
		t.Fatalf("Socketpair: %v", err)
	}
	defer syscall.Close(fds[0])
	defer syscall.Close(fds[1])
	leaked := fds[0]

	dir := t.TempDir()
	outFile := filepath.Join(dir, "fds.txt")
	doneFile := filepath.Join(dir, "done")

	cmd := exec.Command("/bin/sh", "-c",
		fmt.Sprintf("ls /proc/self/fd > %s; touch %s", shellQuote(outFile), shellQuote(doneFile)))
	if _, err := start(cmd); err != nil {
		t.Fatalf("start: %v", err)
	}

	waitForFile(t, doneFile, 2*time.Second)

	data, err := os.ReadFile(outFile)
	if err != nil {
		t.Fatalf("ReadFile(%s): %v", outFile, err)
	}
	childFDs := strings.Fields(string(data))
	target := strconv.Itoa(leaked)
	for _, f := range childFDs {
		if f == target {
			t.Fatalf("child's /proc/self/fd contains %s (the parent's raw non-CLOEXEC socket) -- leaked into the child: %q", target, string(data))
		}
	}
}

// TestStart_DetachesIntoOwnSession proves the spawned child is
// setsid-detached: it has its own session id, distinct from the test
// process's, so a signal sent to the daemon's process group (a session
// leader's SIGTERM/SIGKILL, or a controlling-terminal SIGHUP) does not
// reach children started this way.
func TestStart_DetachesIntoOwnSession(t *testing.T) {
	dir := t.TempDir()
	outFile := filepath.Join(dir, "sid")
	doneFile := filepath.Join(dir, "done")

	cmd := exec.Command("/bin/sh", "-c",
		fmt.Sprintf("ps -o sid= -p $$ > %s; touch %s", shellQuote(outFile), shellQuote(doneFile)))
	started, err := start(cmd)
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	waitForFile(t, doneFile, 2*time.Second)

	data, err := os.ReadFile(outFile)
	if err != nil {
		t.Fatalf("ReadFile(%s): %v", outFile, err)
	}
	childSID, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatalf("parse child sid from %q: %v", string(data), err)
	}
	if childSID != started.Process.Pid {
		t.Fatalf("child sid = %d, want its own pid %d (setsid session leader)", childSID, started.Process.Pid)
	}
}

func waitForFile(t *testing.T, path string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s to appear", path)
}

// shellQuote wraps p in single quotes for safe interpolation into a
// `sh -c` string built by the tests above (t.TempDir() paths never
// contain a single quote, but this keeps the intent explicit).
func shellQuote(p string) string {
	if !strings.Contains(p, "'") {
		return "'" + p + "'"
	}
	var b bytes.Buffer
	b.WriteByte('\'')
	for _, r := range p {
		if r == '\'' {
			b.WriteString(`'\''`)
		} else {
			b.WriteRune(r)
		}
	}
	b.WriteByte('\'')
	return b.String()
}
