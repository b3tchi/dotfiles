package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
)

// i3 IPC message types this tool names. The full set lives in
// internal/i3/ipc.go, which keeps them unexported — the proxy only needs to
// tell a RUN_COMMAND from everything else.
const (
	i3TypeRunCommand uint32 = 0
	i3TypeSubscribe  uint32 = 2
)

const i3Magic = "i3-ipc"

// scanFrames reads i3 IPC frames from r until EOF, handing each (type,
// payload) to onFrame. It never buffers a partial frame across calls: the
// header fixes the payload length, so a short read inside a frame is an
// error rather than a silent desync.
func scanFrames(r io.Reader, onFrame func(mtype uint32, payload []byte)) error {
	header := make([]byte, len(i3Magic)+8)
	for {
		if _, err := io.ReadFull(r, header); err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		if string(header[:len(i3Magic)]) != i3Magic {
			return fmt.Errorf("i3 proxy: bad frame magic %q", header[:len(i3Magic)])
		}
		length := binary.LittleEndian.Uint32(header[len(i3Magic):])
		mtype := binary.LittleEndian.Uint32(header[len(i3Magic)+4:])
		payload := make([]byte, length)
		if _, err := io.ReadFull(r, payload); err != nil {
			return fmt.Errorf("i3 proxy: truncated payload (%d bytes announced): %w", length, err)
		}
		onFrame(mtype, payload)
	}
}

// I3Proxy is a recording man-in-the-middle on the i3 IPC socket: the REAL
// daemon connects here (via $HOTKEYD_I3SOCK, the operator/test override
// main.go's i3SocketResolver documents), every frame is relayed verbatim to
// the REAL i3, and every RUN_COMMAND payload is recorded on the way past.
//
// # Why a proxy rather than a fake i3
//
// live_check.py can hand the daemon a RecordingI3 object because it
// constructs the daemon in-process. The Go daemon is a separate binary with
// a compiled-in table (the dwm model), so the only seam is the socket path.
// A pure fake would answer the daemon but leave real i3 out of the loop, and
// sp021 Task 14 asks specifically for the REAL i3: the proxy keeps i3 doing
// the work — its replies, its errors, its event stream — while making the
// dispatched commands observable, which is the one thing an out-of-process
// observer otherwise cannot see.
type I3Proxy struct {
	path     string
	upstream string
	ln       net.Listener

	mu   sync.Mutex
	cmds []string
}

// StartI3Proxy binds path and relays to upstream (the real i3's socket).
func StartI3Proxy(path, upstream string) (*I3Proxy, error) {
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("i3 proxy: listen %s: %w", path, err)
	}
	p := &I3Proxy{path: path, upstream: upstream, ln: ln}
	go p.acceptLoop()
	return p, nil
}

func (p *I3Proxy) acceptLoop() {
	for {
		client, err := p.ln.Accept()
		if err != nil {
			return
		}
		go p.serve(client)
	}
}

func (p *I3Proxy) serve(client net.Conn) {
	defer client.Close()
	server, err := net.Dial("unix", p.upstream)
	if err != nil {
		return
	}
	defer server.Close()

	// server -> client: verbatim, so i3's replies and its subscribed event
	// stream reach the daemon unchanged.
	go func() { _, _ = io.Copy(client, server) }()

	// client -> server: verbatim via a TeeReader, with the tee decoded for
	// RUN_COMMAND payloads. Recording happens on the copy, never on the
	// forwarded bytes, so a decode problem can never corrupt what i3 sees.
	pr, pw := io.Pipe()
	go func() {
		_ = scanFrames(pr, func(mtype uint32, payload []byte) {
			if mtype != i3TypeRunCommand {
				return
			}
			p.mu.Lock()
			p.cmds = append(p.cmds, string(payload))
			p.mu.Unlock()
		})
		_, _ = io.Copy(io.Discard, pr)
	}()
	_, _ = io.Copy(server, io.TeeReader(client, pw))
	pw.Close()
}

// Commands returns every RUN_COMMAND payload seen since the last Reset.
func (p *I3Proxy) Commands() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]string, len(p.cmds))
	copy(out, p.cmds)
	return out
}

// Reset clears the recorded commands, so a scenario grades only its own
// dispatches.
func (p *I3Proxy) Reset() {
	p.mu.Lock()
	p.cmds = nil
	p.mu.Unlock()
}

func (p *I3Proxy) Close() {
	p.ln.Close()
	_ = os.Remove(p.path)
}
