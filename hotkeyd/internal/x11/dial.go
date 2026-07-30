package x11

import (
	"fmt"
	"net"
)

// SocketPath returns the well-known Unix domain socket path X servers bind
// for a given local display number.
func SocketPath(display int) string {
	return fmt.Sprintf("/tmp/.X11-unix/X%d", display)
}

// ErrNoServer means neither the filesystem-namespace nor the
// abstract-namespace Unix socket for a display could be reached at all --
// distinct from an authentication refusal, which happens only after a
// successful connect (see ErrAuthRefused in setup.go).
type ErrNoServer struct {
	Path        string
	NormalErr   error
	AbstractErr error
}

func (e *ErrNoServer) Error() string {
	return fmt.Sprintf("x11: no X server listening at %s (normal: %v; abstract: %v)",
		e.Path, e.NormalErr, e.AbstractErr)
}

func (e *ErrNoServer) Unwrap() []error {
	return []error{e.NormalErr, e.AbstractErr}
}

// dialUnixWithAbstractFallback dials the Unix domain socket at path. If that
// fails, it retries in Linux's abstract namespace ("\0"+path, spelled "@"+path
// for Go's net package) -- some containers and WSL configurations bind only
// the abstract socket (poc015 gotcha 11).
func dialUnixWithAbstractFallback(path string) (net.Conn, error) {
	c, err := net.Dial("unix", path)
	if err == nil {
		return c, nil
	}
	normalErr := err

	c, err = net.Dial("unix", "@"+path)
	if err == nil {
		return c, nil
	}

	return nil, &ErrNoServer{Path: path, NormalErr: normalErr, AbstractErr: err}
}

// DialLocal dials the local X server for the given display number, trying
// the standard filesystem-namespace socket first and falling back to the
// abstract namespace.
func DialLocal(display int) (net.Conn, error) {
	return dialUnixWithAbstractFallback(SocketPath(display))
}
