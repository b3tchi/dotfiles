package dialbound

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// hang is a connect that never completes until release is closed - the
// shape a real AF_UNIX connect cannot be made to take on demand (a full
// backlog answers at once on both OSes, see the package doc).
func hang(release <-chan struct{}, delivered chan<- *closeConn) func() (net.Conn, error) {
	return func() (net.Conn, error) {
		<-release
		a, b := net.Pipe()
		b.Close()
		c := &closeConn{Conn: a, closed: make(chan struct{})}
		delivered <- c
		return c, nil
	}
}

// closeConn records its Close.
type closeConn struct {
	net.Conn
	closed chan struct{}
}

func (c *closeConn) Close() error {
	close(c.closed)
	return c.Conn.Close()
}

// within runs f and fails the test, instead of hanging it, when f has not
// returned within limit.
func within(t *testing.T, limit time.Duration, f func()) time.Duration {
	t.Helper()
	start := time.Now()
	ret := make(chan struct{})
	go func() { f(); close(ret) }()
	select {
	case <-ret:
		return time.Since(start)
	case <-time.After(limit):
		t.Fatalf("did not return within %s - the connect is unbounded", limit)
		return 0
	}
}

func TestBoundReturnsWhenTheConnectHangs(t *testing.T) {
	release := make(chan struct{})
	delivered := make(chan *closeConn, 1)
	defer close(release)
	var err error
	took := within(t, 3*time.Second, func() {
		_, err = Bound(200*time.Millisecond, hang(release, delivered))
	})
	if !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("err = %v, want os.ErrDeadlineExceeded", err)
	}
	if took < 200*time.Millisecond {
		t.Fatalf("gave up after %s, before its 200ms", took)
	}
}

// A connect that completes after Bound gave up is closed, not leaked.
func TestBoundClosesALateConnection(t *testing.T) {
	release := make(chan struct{})
	delivered := make(chan *closeConn, 1)
	var err error
	within(t, 3*time.Second, func() { _, err = Bound(50*time.Millisecond, hang(release, delivered)) })
	if err == nil {
		t.Fatal("Bound returned a connection from a connect that had not completed")
	}
	close(release)
	c := <-delivered
	select {
	case <-c.closed:
	case <-time.After(2 * time.Second):
		t.Fatal("the late connection was never closed")
	}
}

func TestBoundPassesAPromptResultThrough(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	c, err := Bound(time.Second, func() (net.Conn, error) { return a, nil })
	if err != nil || c != a {
		t.Fatalf("Bound = %v, %v; want the dialled conn", c, err)
	}
	c.Close()
	want := errors.New("refused")
	if _, err := Bound(time.Second, func() (net.Conn, error) { return nil, want }); err != want {
		t.Fatalf("err = %v, want the dial's own %v", err, want)
	}
}

func TestBoundZeroIsUnbounded(t *testing.T) {
	calls := 0
	_, _ = Bound(0, func() (net.Conn, error) { calls++; time.Sleep(20 * time.Millisecond); return nil, errors.New("x") })
	if calls != 1 {
		t.Fatalf("dial called %d times", calls)
	}
}

// Unix against a real listener on this OS: it connects, and a path with
// nothing behind it fails promptly with the OS's own error, not a timeout.
func TestUnixRealSocket(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s")
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Skipf("no AF_UNIX here: %v", err)
	}
	defer l.Close()
	c, err := Unix(path, time.Second)
	if err != nil {
		t.Fatalf("Unix: %v", err)
	}
	c.Close()
	_, err = Unix(filepath.Join(t.TempDir(), "absent"), time.Second)
	if err == nil || errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("dial of a missing socket: err = %v, want the OS's refusal", err)
	}
}
