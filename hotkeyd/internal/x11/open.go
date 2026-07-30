package x11

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
)

// Open connects to the local X server named by an X11 $DISPLAY string,
// authenticates via Xauthority, completes the connection-setup handshake,
// and starts the read loop. It returns a live Conn (ready for requests
// once ylmp.3 lands) and the server's SetupInfo.
//
// Remote (TCP) displays are out of scope: hotkeyd only ever runs against
// local sessions (native :0, WSL, proot-Arch), matching poc015.
func Open(display string) (*Conn, *SetupInfo, error) {
	host, num, _, err := ParseDisplay(display)
	if err != nil {
		return nil, nil, err
	}
	if host != "" && host != "unix" {
		return nil, nil, fmt.Errorf("x11: remote displays are not supported (host=%q in %q)", host, display)
	}

	nc, err := DialLocal(num)
	if err != nil {
		return nil, nil, err
	}

	authName, authData, warning := lookupCookie(num)
	if warning != "" {
		fmt.Fprintln(os.Stderr, warning)
	}

	req := BuildSetupRequest(authName, authData)
	if _, err := nc.Write(req); err != nil {
		nc.Close()
		return nil, nil, fmt.Errorf("x11: writing setup request: %w", err)
	}

	info, err := ParseSetupResponse(nc)
	if err != nil {
		nc.Close()
		return nil, nil, err
	}

	c := &Conn{
		r:      nc,
		w:      nc,
		closer: nc,
		seq:    NewSequencer(nc),
		Events: make(chan Event, 64),
		done:   make(chan struct{}),
	}
	go c.readLoop()

	return c, info, nil
}

// lookupCookie resolves the MIT-MAGIC-COOKIE-1 (name, data) pair for the
// given local display number from the default Xauthority file. Any
// failure to locate a cookie is non-fatal here -- Open still attempts the
// handshake with an empty cookie, and the server itself will report
// "Authorization required" if one was actually needed (see
// ErrSetupFailed), which is the same distinguishable failure poc015
// measured on withheld-cookie Xvfb rigs.
func lookupCookie(displayNum int) (name string, data []byte, warning string) {
	path, err := DefaultXauthorityPath()
	if err != nil {
		return "", nil, ""
	}
	entries, err := ReadXauthorityFile(path)
	if err != nil {
		return "", nil, ""
	}
	hostname, err := os.Hostname()
	if err != nil {
		return "", nil, ""
	}
	name, data, warning, err = FindCookie(entries, hostname, displayNum)
	if err != nil {
		return "", nil, ""
	}
	return name, data, warning
}

// Close shuts down the connection and stops the read loop.
func (c *Conn) Close() error {
	if c.closer == nil {
		return nil
	}
	return c.closer.Close()
}

// Wait blocks until the read loop exits (connection closed or errored)
// and returns the error that ended it, if any.
func (c *Conn) Wait() error {
	<-c.done
	if c.readErr != nil && !errors.Is(c.readErr, net.ErrClosed) && !errors.Is(c.readErr, io.EOF) {
		return c.readErr
	}
	return nil
}
