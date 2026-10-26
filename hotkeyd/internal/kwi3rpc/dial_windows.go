//go:build windows

package kwi3rpc

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// pipePrefix is the namespace every Windows named pipe lives in. The Win32
// host serves \\.\pipe\kwi3-<user>-<desktop> (kwi3 i3kwin/adapters/win32,
// the X11 host's ipcserver.cpp shared under Q_OS_WIN); $KWI3SOCK names it.
const pipePrefix = `\\.\pipe\`

// pipeBusyWait bounds how long a dial waits for a busy pipe (every
// instance mid-connect, ERROR_PIPE_BUSY) to free an instance before it
// fails - kwi3-msg's own 2 s. A variable only so a test could shorten it;
// none does.
var pipeBusyWait = 2 * time.Second

const (
	errorFileNotFound     syscall.Errno = 2   // ERROR_FILE_NOT_FOUND
	errorBrokenPipe       syscall.Errno = 109 // ERROR_BROKEN_PIPE
	errorPipeBusy         syscall.Errno = 231 // ERROR_PIPE_BUSY
	errorPipeNotConnected syscall.Errno = 233 // ERROR_PIPE_NOT_CONNECTED
)

var procWaitNamedPipeW = syscall.NewLazyDLL("kernel32.dll").NewProc("WaitNamedPipeW")

// isPipePath reports whether path names a named pipe rather than a
// filesystem path. Windows matches the prefix case-insensitively.
func isPipePath(path string) bool {
	return len(path) >= len(pipePrefix) && strings.EqualFold(path[:len(pipePrefix)], pipePrefix)
}

// dial connects to kwi3's rpc endpoint. A \\.\pipe\ name is opened as a
// named pipe; anything else is a filesystem path and is dialled as AF_UNIX,
// exactly as on Linux (Windows 10+ has AF_UNIX stream sockets).
func dial(path string) (net.Conn, error) {
	if !isPipePath(path) {
		return net.Dial("unix", path)
	}
	return dialPipe(path)
}

// dialPipe opens the client end of the named pipe at path.
//
// A pipe that does not exist fails at once (CreateFile answers
// ERROR_FILE_NOT_FOUND without waiting), with the pipe named; the Client's
// reconnect-on-next-Call is what retries it. A pipe whose every instance is
// busy (ERROR_PIPE_BUSY: the server has not yet put up its next listening
// instance) is waited on with WaitNamedPipe for at most pipeBusyWait in
// total, then fails, also named - kwi3-msg's connect_pipe. Once the pipe has
// been seen busy, a moment with no instance at all (the server recycling
// its only one) is part of that same wait, not a "does not exist". Nothing
// here retries past pipeBusyWait.
//
// The handle is opened FILE_FLAG_OVERLAPPED and handed to os.NewFile, which
// (Go 1.25+) associates it with the runtime's I/O completion port: reads and
// writes park a goroutine rather than an OS thread, SetDeadline works -
// WithCallTimeout needs it - and Close unblocks a read in flight.
func dialPipe(path string) (net.Conn, error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, fmt.Errorf("pipe %s: %w", path, err)
	}
	deadline := time.Now().Add(pipeBusyWait)
	sawBusy := false
	for {
		h, err := syscall.CreateFile(name,
			syscall.GENERIC_READ|syscall.GENERIC_WRITE,
			0, nil, syscall.OPEN_EXISTING,
			syscall.FILE_FLAG_OVERLAPPED, 0)
		if err == nil {
			return &pipeConn{File: os.NewFile(uintptr(h), path), addr: pipeAddr(path)}, nil
		}
		left := time.Until(deadline)
		switch {
		case errors.Is(err, errorFileNotFound) && sawBusy && left > 0:
			time.Sleep(min(10*time.Millisecond, left))
		case errors.Is(err, errorFileNotFound):
			return nil, fmt.Errorf("pipe %s does not exist: %w", path, err)
		case errors.Is(err, errorPipeBusy):
			sawBusy = true
			if left <= 0 {
				return nil, fmt.Errorf("pipe %s: every instance stayed busy for %s: %w", path, pipeBusyWait, err)
			}
			// Returns once an instance is free, the wait ran out, or the
			// pipe went away; the next CreateFile tells which, so the
			// result itself is not read.
			procWaitNamedPipeW.Call(uintptr(unsafe.Pointer(name)), uintptr(max(1, left/time.Millisecond)))
		default:
			return nil, fmt.Errorf("pipe %s: %w", path, err)
		}
	}
}

// pipeConn is a named pipe's client end as a net.Conn: *os.File already has
// Write, Close and the three deadline setters; only the addresses are
// missing, and Read is wrapped so a host that hung up reads as io.EOF.
type pipeConn struct {
	*os.File
	addr pipeAddr
}

// Read reports the server's end going away as io.EOF, the way a closed unix
// socket does: ERROR_BROKEN_PIPE (the server closed its handle; Go already
// maps this one) and ERROR_PIPE_NOT_CONNECTED (it DisconnectNamedPipe'd
// first) are the same event to a client.
func (c *pipeConn) Read(p []byte) (int, error) {
	n, err := c.File.Read(p)
	if err != nil && (errors.Is(err, errorBrokenPipe) || errors.Is(err, errorPipeNotConnected)) {
		err = io.EOF
	}
	return n, err
}

func (c *pipeConn) LocalAddr() net.Addr  { return c.addr }
func (c *pipeConn) RemoteAddr() net.Addr { return c.addr }

type pipeAddr string

func (a pipeAddr) Network() string { return "pipe" }
func (a pipeAddr) String() string  { return string(a) }
