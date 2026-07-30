// Package i3 is a zero-dependency, stdlib-only client for the i3 IPC
// protocol (https://i3wm.org/docs/ipc.html), ported from hotkeyd.py's
// I3Client class. See adr0018 for why this repo owns its own protocol
// clients instead of importing one.
package i3

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

// Magic is the fixed 6-byte prefix i3 puts on every IPC message, request or
// reply.
const Magic = "i3-ipc"

// headerLen is Magic (6 bytes) + payload length (uint32 LE) + message type
// (uint32 LE).
const headerLen = len(Magic) + 4 + 4

// Message types (requests), per the i3-ipc protocol.
const (
	MsgRunCommand      uint32 = 0
	MsgGetWorkspaces   uint32 = 1
	MsgSubscribe       uint32 = 2
	MsgGetOutputs      uint32 = 3
	MsgGetTree         uint32 = 4
	MsgGetMarks        uint32 = 5
	MsgGetBarConfig    uint32 = 6
	MsgGetVersion      uint32 = 7
	MsgGetBindingModes uint32 = 8
	MsgGetConfig       uint32 = 9
	MsgSendTick        uint32 = 10
	MsgSync            uint32 = 11
	MsgGetBindingState uint32 = 12
)

// EventMask is set on a message type's high bit when i3 sends an unsolicited
// event rather than a reply to a request. i3 can interleave an event between
// a request and its reply on the same connection, so every read has to test
// this bit -- a client that treats the next message as its reply is one
// message behind for the rest of the session (i3 IPC docs; mirrors
// hotkeyd.py's `_read_message`).
const EventMask uint32 = 0x80000000

// EventMode is the "mode" change event kind (with EventMask already
// stripped) -- the only i3 event hotkeyd subscribes to today.
const EventMode uint32 = 2

// ErrClosed reports that the i3 IPC connection ended (EOF, whether clean or
// mid-frame) rather than a decode error against a well-formed stream. Named
// distinctly from a bare io.EOF/io.ErrUnexpectedEOF so callers can match it
// without knowing which of the two the OS happened to hand back -- adr0014's
// "fail fast with a named error" for the i3-restart path.
var ErrClosed = errors.New("i3 ipc: connection closed")

// frame is one decoded i3-ipc message: its type (with EventMask still set
// for events) and raw payload bytes.
type frame struct {
	mtype   uint32
	payload []byte
}

// writeFrame writes one i3-ipc message: Magic + LE length + LE type +
// payload, in one Write call.
func writeFrame(w io.Writer, mtype uint32, payload []byte) error {
	buf := make([]byte, headerLen+len(payload))
	copy(buf, Magic)
	binary.LittleEndian.PutUint32(buf[6:10], uint32(len(payload)))
	binary.LittleEndian.PutUint32(buf[10:14], mtype)
	copy(buf[14:], payload)
	_, err := w.Write(buf)
	return err
}

// readFrame reads one complete i3-ipc message from r. It verifies the magic
// prefix and reads exactly `length` payload bytes regardless of how many
// underlying Read calls that takes -- io.ReadFull, not a single Read, is
// what makes a header or payload split across several TCP-style short reads
// (or, over a Unix socket, an event landing between two writes) come out
// whole rather than truncated.
func readFrame(r io.Reader) (frame, error) {
	hdr := make([]byte, headerLen)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return frame{}, wrapEOF(err)
	}
	if string(hdr[:len(Magic)]) != Magic {
		return frame{}, fmt.Errorf("i3 ipc: bad magic %q", hdr[:len(Magic)])
	}

	length := binary.LittleEndian.Uint32(hdr[6:10])
	mtype := binary.LittleEndian.Uint32(hdr[10:14])

	var payload []byte
	if length > 0 {
		payload = make([]byte, length)
		if _, err := io.ReadFull(r, payload); err != nil {
			return frame{}, wrapEOF(err)
		}
	}
	return frame{mtype: mtype, payload: payload}, nil
}

// wrapEOF collapses io.EOF and io.ErrUnexpectedEOF -- the two shapes
// io.ReadFull can hand back for "the peer is gone", whether that happened
// before any byte arrived or partway through a header/payload -- into the
// single named ErrClosed. Any other error (e.g. a real I/O failure) passes
// through unchanged.
func wrapEOF(err error) error {
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return ErrClosed
	}
	return err
}

// DiscoverSocket resolves i3's IPC socket path: `$I3SOCK` if set, else
// `i3 --get-socketpath`.
//
// NOTE on a deliberate divergence from hotkeyd.py: hotkeyd.py's
// `i3_socket_path` does NOT read $I3SOCK. i3 exports that variable into the
// environment of every process it execs, so a per-display daemon started
// for :10 by :0's i3 would inherit :0's socket and dispatch every command to
// the wrong window manager. hotkeyd.py instead resolves the socket off its
// OWN X connection's `I3_SOCKET_PATH` root-window property (which i3
// rewrites on every restart), falling back to `i3 --get-socketpath` with
// I3SOCK scrubbed from the subprocess environment. This package has no X
// connection to read that property from -- that lives in internal/x11, a
// separate package -- so DiscoverSocket implements the literal socket
// discovery this task's design specifies ($I3SOCK, then the CLI) as a
// simple, test-friendly default. cmd/hotkeyd (Task 12, daemon assembly) is
// expected to inject hotkeyd.py's cross-display-safe resolver via
// NewClient's pathFn parameter instead of this function when wiring the
// real daemon, exactly as hotkeyd.py's I3Client takes a path_getter
// callable rather than hardcoding discovery.
func DiscoverSocket() (string, error) {
	if p := os.Getenv("I3SOCK"); p != "" {
		return p, nil
	}
	out, err := exec.Command("i3", "--get-socketpath").Output()
	if err != nil {
		return "", fmt.Errorf("i3 ipc: i3 --get-socketpath: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}
