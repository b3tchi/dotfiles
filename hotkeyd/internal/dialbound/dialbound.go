// Package dialbound puts a hard time limit on a connect.
//
// kwi3-hoex.22: hotkeyd's control client (controlCall: `--health`'s status
// request and `recover`'s stop request) and the kwi3rpc client dialled with
// a plain net.Dial and only then set a deadline, so the connect itself had
// no limit. net.DialTimeout alone does not close that gap on every OS: on
// Windows, Go connects every socket that is not TCP (AF_UNIX included) with
// a plain blocking connect() and never consults the dial's deadline
// (net/fd_windows.go, canUseConnectEx). Bound therefore waits for the
// connect on a goroutine of its own and gives up when the time is up,
// whatever the connect is doing.
//
// Measured on this box (go1.27, 2026-10-26) neither OS actually blocks on
// the obvious trigger, a listener whose backlog is full: Linux answers
// EAGAIN at once and Windows WSAENOBUFS at once. The bound is the guarantee
// that a budget built on top of a connect (recover's 12 s, --health's 3 s)
// holds whatever the connect does, not the fix for an observed hang.
package dialbound

import (
	"fmt"
	"net"
	"os"
	"time"
)

// Bound runs dial and returns its result if it arrives within timeout. If
// it does not, Bound returns an error wrapping os.ErrDeadlineExceeded at
// once and leaves the connect running; a connection it delivers later is
// closed, never returned. timeout <= 0 means no bound: dial is simply
// called.
func Bound(timeout time.Duration, dial func() (net.Conn, error)) (net.Conn, error) {
	if timeout <= 0 {
		return dial()
	}
	type result struct {
		conn net.Conn
		err  error
	}
	// Unbuffered: a send succeeds only while Bound is still waiting, so
	// once it has given up the connect's result can only take the
	// abandoned branch, which closes it.
	done := make(chan result)
	abandoned := make(chan struct{})
	go func() {
		c, err := dial()
		select {
		case done <- result{c, err}:
		case <-abandoned:
			if c != nil {
				c.Close()
			}
		}
	}()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case r := <-done:
		return r.conn, r.err
	case <-timer.C:
		close(abandoned)
		return nil, fmt.Errorf("connect did not complete within %s: %w", timeout, os.ErrDeadlineExceeded)
	}
}

// Unix dials the AF_UNIX stream socket at path, returning within timeout
// (timeout <= 0: no bound).
func Unix(path string, timeout time.Duration) (net.Conn, error) {
	return Bound(timeout, func() (net.Conn, error) {
		return net.DialTimeout("unix", path, timeout)
	})
}
