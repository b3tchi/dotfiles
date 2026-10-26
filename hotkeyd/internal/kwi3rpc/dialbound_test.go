package kwi3rpc

import (
	"errors"
	"net"
	"os"
	"testing"
	"time"
)

// kwi3-hoex.22: WithCallTimeout bounds the dial a Call has to make, not
// only its write and reply. The dial is replaced by one that hangs - a
// real AF_UNIX connect is refused at once on a full backlog on both
// OSes, so no real socket can be made to hang it - and the Call must
// return on time with the transport failure every unreachable kwi3 gets.
func TestCallTimeoutBoundsTheDial(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	c := New("/nonexistent/kwi3.sock", WithCallTimeout(300*time.Millisecond))
	c.dial = func(string, time.Duration) (net.Conn, error) {
		<-release
		return nil, errors.New("released")
	}
	start := time.Now()
	ret := make(chan error, 1)
	go func() { _, err := c.Call("workspace.list", nil); ret <- err }()
	select {
	case err := <-ret:
		if !errors.Is(err, ErrUnreachable) || !errors.Is(err, os.ErrDeadlineExceeded) {
			t.Fatalf("err = %v, want ErrUnreachable wrapping a connect deadline", err)
		}
		if took := time.Since(start); took < 300*time.Millisecond {
			t.Fatalf("gave up after %s, before its 300ms", took)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Call still blocked in its dial after 3s - the dial is unbounded")
	}
}

// With no WithCallTimeout the dial is not bounded (chord dispatch's
// behaviour, unchanged): the dialer is asked with timeout 0.
func TestNoCallTimeoutLeavesTheDialUnbounded(t *testing.T) {
	var got time.Duration = -1
	c := New("/nonexistent/kwi3.sock")
	c.dial = func(_ string, timeout time.Duration) (net.Conn, error) {
		got = timeout
		return nil, errors.New("refused")
	}
	if _, err := c.Call("workspace.list", nil); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("err = %v, want ErrUnreachable", err)
	}
	if got != 0 {
		t.Fatalf("dial timeout = %s, want 0", got)
	}
}
