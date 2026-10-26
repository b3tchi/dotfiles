package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// hangControlConnect makes every control connect hang until the test ends -
// a daemon whose accept never comes. A real socket cannot be made to do
// this on demand: a full backlog is refused at once on Linux (EAGAIN) and
// on Windows (WSAENOBUFS), measured for kwi3-hoex.22. The path the client
// is given names nothing, so a client that bypassed controlConnect and
// dialled for itself fails at once with the OS's own error instead of the
// deadline this asserts.
func hangControlConnect(t *testing.T) string {
	t.Helper()
	release := make(chan struct{})
	old := controlConnect
	controlConnect = func(string, time.Duration) (net.Conn, error) {
		<-release
		return nil, errors.New("released")
	}
	t.Cleanup(func() { controlConnect = old; close(release) })
	return filepath.Join(t.TempDir(), "absent-ctl.sock")
}

// returnsWithin fails the test, instead of hanging it, when f has not
// returned within limit.
func returnsWithin(t *testing.T, limit time.Duration, f func()) time.Duration {
	t.Helper()
	start := time.Now()
	ret := make(chan struct{})
	go func() { f(); close(ret) }()
	select {
	case <-ret:
		return time.Since(start)
	case <-time.After(limit):
		t.Fatalf("still blocked after %s - the connect is unbounded", limit)
		return 0
	}
}

// kwi3-hoex.22: controlCall's timeout covers the connect, so --health's
// status request and recover's stop request return on time from a daemon
// that never accepts.
func TestControlCallBoundsTheConnect(t *testing.T) {
	path := hangControlConnect(t)
	tr := true
	var err error
	took := returnsWithin(t, 3*time.Second, func() {
		_, err = controlCall(path, controlRequest{Status: &tr}, 300*time.Millisecond)
	})
	if !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("err = %v, want a connect deadline (os.ErrDeadlineExceeded)", err)
	}
	if took < 300*time.Millisecond {
		t.Fatalf("gave up after %s, before its 300ms", took)
	}
}

// set-layer's exchange goes through the same bounded connect.
func TestDialSetLayerBoundsTheConnect(t *testing.T) {
	path := hangControlConnect(t)
	var err error
	returnsWithin(t, 3*time.Second, func() {
		_, _, err = dialSetLayer(path, "x", 300*time.Millisecond)
	})
	if !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("err = %v, want a connect deadline (os.ErrDeadlineExceeded)", err)
	}
}

// The real connect still works against a real control listener, and a
// socket with nothing behind it still fails with the OS's refusal, not a
// timeout.
func TestControlConnectRealSocket(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ctl.sock")
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Skipf("no AF_UNIX here: %v", err)
	}
	defer l.Close()
	c, err := dialControl(path, time.Second)
	if err != nil {
		t.Fatalf("dialControl: %v", err)
	}
	c.Close()
	if _, err := dialControl(filepath.Join(t.TempDir(), "none.sock"), time.Second); err == nil || errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("missing socket: err = %v, want the OS's refusal", err)
	}
}
