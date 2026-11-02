// Package xvfbtest starts an Xvfb on a display of its own, for tests.
//
// It is the one copy of the rig every Xvfb test in this module uses
// (cmd/hotkeyd, internal/i3, internal/x11). A test that picks a FIXED
// display - cmd/hotkeyd's :198 and :187 did (kwi3-j94x) - shares it with
// every other run of the same test at the same time: two worktrees, two
// agents, a `go test` and a `go test -tags phone`. The loser's Xvfb exits
// "Server is already active", and the loser goes on against the WINNER's
// server: its daemon grabs on the other run's display, its chord lands on
// the other run's i3, and either run fails or skips for a reason that has
// nothing to do with the code under test (measured: two concurrent
// -count=20 runs, both red). Picking a random number and then checking
// that the socket answers is not enough either - an answering socket can
// be someone else's server.
//
// So a display is OURS only when /tmp/.X<n>-lock names our Xvfb's pid
// while that process lives: the X server writes that lock before it
// listens and refuses a display whose lock names a live process
// (kwi3-hoex.31's internal/i3 rig, now shared). Losing the race costs one
// retry on another number.
//
// This is not a _test.go file because a _test.go file cannot be imported
// from another package; nothing outside a test imports it.
package xvfbtest

import (
	"fmt"
	"math/rand/v2"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// First and Span bound the display numbers Start picks from: 200..2199,
// clear of a real session's :0/:10/:40/:60 and of the 100s other rigs in
// this tree name by hand.
const (
	First = 200
	Span  = 2000
)

// DefaultArgs are the Xvfb arguments after the display. -noreset: without
// it Xvfb regenerates the moment its last client disconnects, and a probe's
// own open/close followed by a test's next connect races that reset.
var DefaultArgs = []string{"-screen", "0", "800x600x24", "-nolisten", "tcp", "-noreset"}

// Seams for this package's own tests.
var (
	pickNum = func() int { return First + rand.IntN(Span) }
	answers = Answers
)

// Server is an Xvfb this process started, on a display it holds.
type Server struct {
	Num     int    // display number
	Display string // ":<Num>"

	cmd    *exec.Cmd
	exited chan struct{}
	log    *syncBuffer
	once   sync.Once
}

// Start starts an Xvfb on a display of its own and returns it once it
// serves, with t.Cleanup stopping it. extra is appended to DefaultArgs.
// It skips the test when Xvfb is not on PATH.
func Start(t testing.TB, extra ...string) *Server {
	t.Helper()
	return StartWith(t, func(int) []string { return extra })
}

// StartWith is Start with the extra arguments made for the display number
// each attempt tries - for an argument that names it, such as an -auth
// file holding a cookie for that display.
func StartWith(t testing.TB, extra func(n int) []string) *Server {
	t.Helper()
	if _, err := exec.LookPath("Xvfb"); err != nil {
		t.Skipf("Xvfb not available on PATH: %v", err)
	}
	var said string
	for attempt := 0; attempt < 20; attempt++ {
		n := pickNum()
		if answers(n) {
			continue // a server is already there
		}
		args := append([]string{fmt.Sprintf(":%d", n)}, DefaultArgs...)
		args = append(args, extra(n)...)
		s := &Server{
			Num:     n,
			Display: fmt.Sprintf(":%d", n),
			cmd:     exec.Command("Xvfb", args...),
			exited:  make(chan struct{}),
			log:     &syncBuffer{},
		}
		s.cmd.Stdout, s.cmd.Stderr = s.log, s.log
		if err := s.cmd.Start(); err != nil {
			t.Fatalf("starting Xvfb: %v", err)
		}
		go func() { _ = s.cmd.Wait(); close(s.exited) }()
		if s.ownsDisplay(5*time.Second) && waitFor(n, 5*time.Second) {
			t.Cleanup(s.Stop)
			return s
		}
		s.Stop() // lost the display to another server (or never served): try another
		said = s.Log()
	}
	t.Fatalf("could not start an Xvfb on a display of its own in 20 tries; the last one said: %s", said)
	return nil
}

// Pid is the Xvfb's process id.
func (s *Server) Pid() int { return s.cmd.Process.Pid }

// Log is what the Xvfb has printed so far.
func (s *Server) Log() string { return s.log.String() }

// Exited is closed once the Xvfb has exited and been reaped.
func (s *Server) Exited() <-chan struct{} { return s.exited }

// Kill SIGKILLs the Xvfb - a hard X server death, for a test of what
// happens to its clients - and waits for it. Its lock and socket file are
// left for Stop, which t.Cleanup runs.
func (s *Server) Kill() error {
	if err := s.cmd.Process.Kill(); err != nil { // our own child, by its handle
		return err
	}
	<-s.exited
	return nil
}

// Stop ends the Xvfb with SIGTERM, so it removes its own lock and socket
// on the way out, falling back to SIGKILL if it hangs. A SIGKILLed Xvfb
// (here, or by Kill) strands both, so Stop then removes them - only while
// the lock still names this Xvfb's pid, never another server's. Safe to
// call more than once.
func (s *Server) Stop() {
	s.once.Do(func() {
		_ = s.cmd.Process.Signal(syscall.SIGTERM) // our own child; a no-op once reaped
		select {
		case <-s.exited:
		case <-time.After(2 * time.Second):
			_ = s.cmd.Process.Kill()
			<-s.exited
		}
		if LockNames(s.Num, s.Pid()) {
			_ = os.Remove(SocketPath(s.Num))
			_ = os.Remove(LockPath(s.Num))
		}
	})
}

func (s *Server) ownsDisplay(within time.Duration) bool {
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		select {
		case <-s.exited:
			return false
		default:
		}
		if LockNames(s.Num, s.Pid()) {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

// LockPath is the X server lock for display n.
func LockPath(n int) string { return fmt.Sprintf("/tmp/.X%d-lock", n) }

// SocketPath is the X socket file for display n.
func SocketPath(n int) string { return fmt.Sprintf("/tmp/.X11-unix/X%d", n) }

// LockNames reports whether display n's lock names pid.
func LockNames(n, pid int) bool {
	b, err := os.ReadFile(LockPath(n))
	return err == nil && strings.TrimSpace(string(b)) == fmt.Sprint(pid)
}

// Answers reports whether an X server takes a connection for display n,
// at its socket file or at its abstract name: under WSLg /tmp/.X11-unix is
// a read-only mount, so Xvfb binds "@/tmp/.X11-unix/X<n>" alone. A socket
// file a dead server left behind does not answer.
func Answers(n int) bool {
	for _, addr := range []string{SocketPath(n), "@" + SocketPath(n)} {
		if c, err := net.DialTimeout("unix", addr, 250*time.Millisecond); err == nil {
			c.Close()
			return true
		}
	}
	return false
}

func waitFor(n int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if Answers(n) {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}

// syncBuffer is a strings.Builder exec's copier may write while a test
// reads it.
type syncBuffer struct {
	mu sync.Mutex
	b  strings.Builder
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}
