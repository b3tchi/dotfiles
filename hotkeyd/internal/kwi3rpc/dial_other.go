//go:build !windows

package kwi3rpc

import "net"

// dial connects to kwi3's rpc socket at path: on every platform but
// Windows that is always an AF_UNIX stream socket, exactly as it was before
// sp012 Task 2 split the dialer per OS.
func dial(path string) (net.Conn, error) {
	return net.Dial("unix", path)
}
