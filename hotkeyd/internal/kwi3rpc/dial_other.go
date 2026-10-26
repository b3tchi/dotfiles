//go:build !windows

package kwi3rpc

import (
	"net"
	"time"
)

// dial connects to kwi3's rpc socket at path: on every platform but
// Windows that is always an AF_UNIX stream socket, exactly as it was before
// sp012 Task 2 split the dialer per OS. timeout 0 is no timeout; the
// Client bounds the dial itself either way (kwi3-hoex.22).
func dial(path string, timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout("unix", path, timeout)
}
