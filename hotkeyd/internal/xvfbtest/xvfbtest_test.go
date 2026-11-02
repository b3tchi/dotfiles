package xvfbtest

import (
	"fmt"
	"net"
	"os"
	"testing"
)

// freeNum is a display number nothing serves and nothing has locked.
func freeNum(t *testing.T) int {
	t.Helper()
	for i := 0; i < 50; i++ {
		n := pickNum()
		if _, err := os.Stat(LockPath(n)); err == nil {
			continue
		}
		if !Answers(n) {
			return n
		}
	}
	t.Fatal("no free display number")
	return 0
}

// The race a fixed or merely random display loses: the number looked free,
// but by the time our Xvfb starts, another server holds it and ANSWERS on
// it. Here that server is this test process - its lock (naming a live pid,
// ours) and an abstract listener - and the free-looking check is made to
// say "free". Our Xvfb refuses the display and exits; a rig that only
// waits for the socket to answer would hand the test the other server.
func TestStart_DisplayAnotherServerHolds_NotAdopted(t *testing.T) {
	n := freeNum(t)
	f, err := os.OpenFile(LockPath(n), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o444)
	if err != nil {
		t.Fatalf("creating the other server's lock: %v", err)
	}
	fmt.Fprintf(f, "%10d\n", os.Getpid())
	f.Close()
	t.Cleanup(func() {
		if LockNames(n, os.Getpid()) {
			os.Remove(LockPath(n))
		}
	})
	ln, err := net.Listen("unix", "@"+SocketPath(n))
	if err != nil {
		t.Fatalf("the other server's listener: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()

	origPick, origAnswers := pickNum, answers
	t.Cleanup(func() { pickNum, answers = origPick, origAnswers })
	first := true
	pickNum = func() int {
		if first {
			first = false
			return n
		}
		return origPick()
	}
	answers = func(k int) bool { return k != n && Answers(k) }

	s := Start(t)
	if s.Num == n {
		t.Fatalf("Start adopted :%d, whose lock names pid %d, not its Xvfb's %d", n, os.Getpid(), s.Pid())
	}
	if !LockNames(s.Num, s.Pid()) {
		t.Fatalf("Start returned :%d, whose lock does not name its Xvfb (pid %d)", s.Num, s.Pid())
	}
	if !LockNames(n, os.Getpid()) {
		t.Fatalf("the other server's lock on :%d was touched", n)
	}
}

func TestStop_RemovesOwnLock(t *testing.T) {
	s := Start(t)
	if !LockNames(s.Num, s.Pid()) {
		t.Fatalf("Xvfb up on %s but its lock does not name it", s.Display)
	}
	s.Stop()
	if _, err := os.Stat(LockPath(s.Num)); !os.IsNotExist(err) {
		t.Fatalf("Stop left %s behind (stat err: %v)", LockPath(s.Num), err)
	}
	if Answers(s.Num) {
		t.Fatalf("%s still answers after Stop", s.Display)
	}
	s.Stop() // a second Stop (t.Cleanup's) is a no-op
}

// A SIGKILLed Xvfb cannot remove its lock; Stop does, since it names it.
func TestKillThenStop_RemovesOwnLock(t *testing.T) {
	s := Start(t)
	if err := s.Kill(); err != nil {
		t.Fatalf("Kill: %v", err)
	}
	if !LockNames(s.Num, s.Pid()) {
		t.Skipf("this Xvfb removed its lock even on SIGKILL; nothing for Stop to do")
	}
	s.Stop()
	if _, err := os.Stat(LockPath(s.Num)); !os.IsNotExist(err) {
		t.Fatalf("Stop left the killed Xvfb's %s behind (stat err: %v)", LockPath(s.Num), err)
	}
}

// Another server took the display after ours died: its lock is not ours to
// remove.
func TestKillThenStop_LeavesAnotherServersLock(t *testing.T) {
	s := Start(t)
	if err := s.Kill(); err != nil {
		t.Fatalf("Kill: %v", err)
	}
	if err := os.WriteFile(LockPath(s.Num), []byte(fmt.Sprintf("%10d\n", os.Getpid())), 0o444); err != nil {
		// Still our dead Xvfb's file (0444): replace it the way a new server does.
		os.Remove(LockPath(s.Num))
		if err := os.WriteFile(LockPath(s.Num), []byte(fmt.Sprintf("%10d\n", os.Getpid())), 0o444); err != nil {
			t.Fatalf("writing the other server's lock: %v", err)
		}
	}
	t.Cleanup(func() {
		if LockNames(s.Num, os.Getpid()) {
			os.Remove(LockPath(s.Num))
		}
	})
	s.Stop()
	if !LockNames(s.Num, os.Getpid()) {
		t.Fatalf("Stop removed %s, which names another server (pid %d)", LockPath(s.Num), os.Getpid())
	}
}
