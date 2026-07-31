// control.go is the daemon side of sp023's external-trigger verb: a
// per-display unix socket ($XDG_RUNTIME_DIR/hotkeyd-<n>-ctl.sock, see
// proc.ControlPath) speaking ONE JSON request line and ONE JSON reply line,
// whose only effect is a call to layer.Engine.SetExternalLayer.
//
// # Why a second socket rather than reads on the state socket
//
// sp023 plan decision 2. [[adr0012]] frames hotkeyd's state channel on a
// singleton-daemon / read-only-consumers model — "mutation never flows back
// through this socket". That sentence stays LITERALLY true after this task:
// layer.StatePublisher still never calls Read on a client connection, and
// the external-trigger exception arrives as a NEW socket with its own
// listener, its own framing, and its own authority policy. A reviewer
// checking whether adr0012 was loosened only has to confirm publisher.go is
// untouched.
//
// # Concurrency contract — where SetExternalLayer may be called from
//
// Engine state is owned by the run loop's single goroutine. Nothing in this
// file ever touches the Engine. A connection is read, deadline-bounded and
// parsed in its OWN goroutine (so a hung, silent or garbage-writing client
// costs exactly one goroutine and one fd, never a stalled run loop), and the
// parsed name then crosses an UNBUFFERED channel into (*Daemon).Run's
// select, which performs the mutation and hands back a reply on the
// request's own buffered reply channel. The unbuffered handoff is what makes
// "delivered" and "answered" the same event: a command can never be sitting
// in a queue that the run loop has already stopped draining, which is why
// shutdown cannot strand a client (see Close and handleConn's done cases).
//
// # adr0014 at this surface
//
// A missing $XDG_RUNTIME_DIR is a precondition the listener cannot
// re-establish from the inside, so NewControlListener returns a NAMED
// *ErrControlUnavailable and does not retry. main.go's buildControl logs it
// and the daemon serves WITHOUT the control socket — the same best-effort
// policy buildPublisher applies to the state feed: grabs are the job, both
// sockets are conveniences.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/layer"
)

// maxControlRequestBytes bounds ONE request line. The only legal request is
// a small JSON object holding a layer name that must exist in the compiled
// table, so anything approaching this bound is already malformed; the point
// of the bound is that a client streaming megabytes without a newline is
// refused after a fixed read rather than buffered.
const maxControlRequestBytes = 4096

// controlReadTimeout bounds how long a connection may take to deliver its
// request line. Generous relative to a local write of a few dozen bytes,
// short enough that a wedged caller (a python overlay killed mid-write)
// releases its goroutine and fd promptly.
const controlReadTimeout = 2 * time.Second

// controlWriteTimeout bounds the reply write, so a client that connects,
// sends a request and then stops reading cannot pin the connection
// goroutine. Mirrors publisher.go's writeTimeout rationale, with more slack
// because there is exactly one write per connection and no fan-out.
const controlWriteTimeout = 500 * time.Millisecond

// controlRequest is the wire request. SetLayer is a POINTER so an absent
// "set_layer" key is distinguishable from an explicit empty string: the
// former is a malformed request answered by name, the latter is a clear.
// Anything else in the object is ignored — a forward-compatible client may
// send fields this build predates, and refusing them would make the socket
// harder to extend than the compiled table it fronts.
type controlRequest struct {
	SetLayer *string `json:"set_layer"`
}

// controlReply is the wire reply: {"ok":true} or {"ok":false,"error":"..."}.
// The error string always carries the offending layer name when there is one
// ([[us019]] AC4: refused BY NAME, never silently ignored) — see
// validateControlLayer and layer's ErrNoSuchLayer/ErrNotExternalLayer/
// ErrLayerActive, all of which wrap the name.
type controlReply struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// controlCmd is one accepted request crossing into Run's select. reply is
// buffered (capacity 1) so the run loop's send NEVER blocks, even if the
// requesting client has vanished in the meantime — the run loop must not be
// able to wait on a socket peer under any circumstance.
type controlCmd struct {
	layer string
	reply chan error
}

// ErrControlUnavailable means the control socket could not be bound because
// its directory is missing or unusable — the control-socket twin of
// layer.ErrChannelUnavailable, and adr0014's fail-fast shape: named, not
// retried, and survivable by the caller.
type ErrControlUnavailable struct {
	Path string
	Err  error
}

func (e *ErrControlUnavailable) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("control socket unavailable at %s: %v", e.Path, e.Err)
	}
	return fmt.Sprintf("control socket unavailable: no such directory: %s", e.Path)
}

func (e *ErrControlUnavailable) Unwrap() error { return e.Err }

// errControlShuttingDown answers a request that arrives (or is still in
// flight) while the daemon is tearing down. Named rather than a silent close
// so a caller can tell "the daemon is going away" from "your request was
// wrong" — the same distinction the CLI verb needs for its exit codes.
var errControlShuttingDown = errors.New("control: daemon is shutting down")

// ControlConfig is NewControlListener's dependency set. ReadTimeout is
// overridable only so tests can exercise the silent-client path without
// waiting out the production bound.
type ControlConfig struct {
	Path         string
	Log          func(string)
	ReadTimeout  time.Duration
	WriteTimeout time.Duration
}

// ControlListener owns the control socket: an accept loop, one goroutine per
// connection, and the channel those goroutines hand parsed requests to. It
// knows NOTHING about layers or the engine — see the file doc's concurrency
// contract.
type ControlListener struct {
	path         string
	ln           *net.UnixListener
	log          func(string)
	readTimeout  time.Duration
	writeTimeout time.Duration

	cmds chan controlCmd

	// done is closed by Close BEFORE waiting on the connection goroutines,
	// which is what unparks any of them sitting on the handoff to a run
	// loop that has already stopped draining.
	done       chan struct{}
	acceptDone chan struct{}
	wg         sync.WaitGroup

	closeOnce sync.Once
	closeErr  error
}

// NewControlListener binds the control socket at cfg.Path and starts
// accepting.
//
// Edge case "socket path already exists from a SIGKILLed predecessor": the
// stale file is unconditionally unlinked and rebound, WITHOUT a
// connect-probe first. The caller is required to already hold this display's
// single-instance lock (proc.AcquireLock) before constructing this, which is
// a stronger guarantee than a probe: no other hotkeyd for this display can
// be running, so any file at the path is necessarily stale. Identical
// reasoning (and identical wording) to layer.NewStatePublisher's — the two
// sockets share a lifecycle by design.
func NewControlListener(cfg ControlConfig) (*ControlListener, error) {
	dir := filepath.Dir(cfg.Path)
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return nil, &ErrControlUnavailable{Path: dir, Err: err}
	}
	if err := os.Remove(cfg.Path); err != nil && !os.IsNotExist(err) {
		return nil, &ErrControlUnavailable{Path: cfg.Path, Err: err}
	}

	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: cfg.Path, Net: "unix"})
	if err != nil {
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
			return nil, &ErrControlUnavailable{Path: cfg.Path, Err: err}
		}
		return nil, err
	}

	l := &ControlListener{
		path:         cfg.Path,
		ln:           ln,
		log:          cfg.Log,
		readTimeout:  cfg.ReadTimeout,
		writeTimeout: cfg.WriteTimeout,
		cmds:         make(chan controlCmd),
		done:         make(chan struct{}),
		acceptDone:   make(chan struct{}),
	}
	if l.log == nil {
		l.log = daemonLog
	}
	if l.readTimeout <= 0 {
		l.readTimeout = controlReadTimeout
	}
	if l.writeTimeout <= 0 {
		l.writeTimeout = controlWriteTimeout
	}
	go l.acceptLoop()
	return l, nil
}

// Commands is the channel (*Daemon).Run selects on. It is CLOSED by Close,
// which is what lets Run retire its own select case instead of spinning on a
// dead channel — see Run's control case.
func (l *ControlListener) Commands() <-chan controlCmd { return l.cmds }

// Path is the socket this listener bound, for startup logging.
func (l *ControlListener) Path() string { return l.path }

func (l *ControlListener) acceptLoop() {
	defer close(l.acceptDone)
	for {
		conn, err := l.ln.AcceptUnix()
		if err != nil {
			return // listener closed; nothing left to accept
		}
		l.wg.Add(1)
		go l.handleConn(conn)
	}
}

// handleConn is one connection's entire life, on its OWN goroutine: read one
// bounded line under a deadline, parse it, hand the name to the run loop,
// write one reply, close. Every exit path writes a reply — a malformed or
// refused request is never a silent drop.
func (l *ControlListener) handleConn(conn *net.UnixConn) {
	defer l.wg.Done()
	defer conn.Close()

	name, err := l.readRequest(conn)
	if err != nil {
		l.reply(conn, err)
		return
	}

	cmd := controlCmd{layer: name, reply: make(chan error, 1)}
	select {
	case l.cmds <- cmd:
	case <-l.done:
		// The run loop has stopped draining (shutdown). Nothing was
		// delivered, so nothing was applied — say so and let go.
		l.reply(conn, errControlShuttingDown)
		return
	}

	// Delivery and answering are the same event on an unbuffered channel
	// (see the file doc), so the reply is effectively already on its way.
	// The done case is a belt-and-braces guard that still prefers a real
	// reply if one landed in the same instant.
	select {
	case applyErr := <-cmd.reply:
		l.reply(conn, applyErr)
	case <-l.done:
		select {
		case applyErr := <-cmd.reply:
			l.reply(conn, applyErr)
		default:
			l.reply(conn, errControlShuttingDown)
		}
	}
}

// readRequest reads ONE length-bounded line under a read deadline and
// returns the requested layer name. The io.LimitReader is what bounds the
// read: without it a client streaming bytes with no newline would grow
// bufio's buffer until the deadline, which is a memory bound of
// "bandwidth x timeout" rather than a constant.
func (l *ControlListener) readRequest(conn *net.UnixConn) (string, error) {
	if err := conn.SetReadDeadline(time.Now().Add(l.readTimeout)); err != nil {
		return "", fmt.Errorf("control: cannot set a read deadline: %w", err)
	}

	r := bufio.NewReader(io.LimitReader(conn, maxControlRequestBytes+1))
	line, err := r.ReadString('\n')
	if err != nil {
		switch {
		case errors.Is(err, os.ErrDeadlineExceeded):
			return "", fmt.Errorf("control: read timed out after %s waiting for a request line", l.readTimeout)
		case errors.Is(err, io.EOF):
			// A client that wrote its request and closed without a
			// trailing newline is served, not punished — but only if the
			// bytes it did send are within the bound (checked next).
		default:
			return "", fmt.Errorf("control: read failed: %w", err)
		}
	}
	if len(line) > maxControlRequestBytes {
		return "", fmt.Errorf("control: request too large (limit %d bytes)", maxControlRequestBytes)
	}

	line = strings.TrimSpace(line)
	if line == "" {
		return "", errors.New(`control: empty request; want one line of {"set_layer":"<name>"}`)
	}

	var req controlRequest
	if err := json.Unmarshal([]byte(line), &req); err != nil {
		return "", fmt.Errorf("control: malformed request: %w", err)
	}
	if req.SetLayer == nil {
		return "", errors.New(`control: request has no "set_layer" field`)
	}
	return *req.SetLayer, nil
}

// reply writes the single reply line. Failures to write are logged, never
// propagated: the request has already been applied (or refused) by then, and
// a client that hung up mid-exchange is not a daemon fault.
func (l *ControlListener) reply(conn *net.UnixConn, applyErr error) {
	rep := controlReply{OK: applyErr == nil}
	if applyErr != nil {
		rep.Error = applyErr.Error()
		l.log(fmt.Sprintf("control: refused: %s", applyErr))
	}
	data, _ := json.Marshal(rep) // fixed, always-encodable struct
	data = append(data, '\n')

	if err := conn.SetWriteDeadline(time.Now().Add(l.writeTimeout)); err != nil {
		l.log(fmt.Sprintf("control: cannot set a write deadline: %s", err))
		return
	}
	if _, err := conn.Write(data); err != nil {
		l.log(fmt.Sprintf("control: reply write failed: %s", err))
	}
}

// Close stops accepting, releases every connection goroutine, closes
// Commands() and unlinks the socket file. Idempotent, and safe to call from
// the run loop's own goroutine during shutdown: the ordering below
// (listener, then done, then wait, then close the command channel) is what
// guarantees no goroutine is still holding a command the run loop will never
// answer, and that nothing sends on cmds after it is closed.
func (l *ControlListener) Close() error {
	l.closeOnce.Do(func() {
		err := l.ln.Close()
		close(l.done)
		<-l.acceptDone // accept loop observed the listener close
		l.wg.Wait()    // every connection goroutine has finished replying
		close(l.cmds)  // Run's select case retires
		if rmErr := os.Remove(l.path); rmErr != nil && !os.IsNotExist(rmErr) && err == nil {
			err = rmErr
		}
		l.closeErr = err
	})
	return l.closeErr
}

// validateControlLayer is the daemon-side authority gate: the COMPILED table
// decides, regardless of what the CLI believed it was sending (sp023 plan
// decision 3 at the socket boundary; [[us019]] AC4).
//
// Accepts exactly a name declared External in this build's table, or
// DefaultLayer (and "" as its synonym, the shape an empty JSON string
// produces) to clear. Everything else is refused with the offending name in
// the error, reusing internal/layer's sentinels so the reply text is
// identical whether the refusal came from here or from SetExternalLayer
// itself.
//
// This duplicates checks SetExternalLayer also makes, deliberately: it is
// what lets the run loop's control case state, as a local property, that
// only external-declared names and the clear ever REACH the engine — a
// property a reader can verify here without re-deriving the engine's
// internals, and one that survives any future engine refactor.
func validateControlLayer(layers map[string]bind.Layer, name string) error {
	if name == "" || name == layer.DefaultLayer {
		return nil
	}
	lay, ok := layers[name]
	if !ok {
		return fmt.Errorf("%w: %q", layer.ErrNoSuchLayer, name)
	}
	if !lay.External {
		return fmt.Errorf("%w: %q", layer.ErrNotExternalLayer, name)
	}
	return nil
}
