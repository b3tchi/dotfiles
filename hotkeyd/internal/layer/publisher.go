package layer

// python: hotkeyd/layers.py's StatePublisher, socket_path, ChannelUnavailable,
// ChannelBusy (sp021 Task 7 / bd dotfiles-ylmp.6's package doc named this
// "deferred to sp021 Task 8 (bd dotfiles-ylmp.7)"). This file is that task.
//
// # Deliberate divergence from Python: accept-time replay always answers
//
// Python's StatePublisher seeds `_current: dict | None = None` and only
// ever sets it from `publish()`, which the engine calls on CHANGE only
// (LayerEngine._publish is publish-on-change). Between daemon startup and
// the first layer change, `poll()`'s replay-on-connect branch
// (`if self._current is not None`) is false, so a client that connects to
// a perfectly healthy, freshly started daemon is accepted and sent
// NOTHING. bd dotfiles-4uiu records this as an open bug: it is exactly
// what a hung daemon looks like from a probing client, and ft009's bars
// are promised the opposite ("a bar that starts late must never be
// blank").
//
// This port closes that gap structurally rather than patching Python's
// guard: NewStatePublisher takes the engine's ACTUAL starting state as a
// required argument and seeds `current` with it, never nil/absent. A
// caller wires this from Engine.State() — itself always valid immediately
// after NewEngine, with no event required — so "current state" is never an
// undefined question. See NewStatePublisher's doc.
//
// # Accept-time replay is structural, not a later poll
//
// Python's replay-on-connect happens inside `poll()`, called from the
// daemon's own loop sometime after `accept()` returns — there is a window,
// however small, between a connection being accepted and the loop getting
// around to replaying to it. This port collapses that window to zero: the
// accept loop itself performs the replay write, UNDER THE SAME MUTEX
// Publish uses to update `current` and fan out, before the connection is
// even added to the client set. A Publish that lands in the gap therefore
// either happens entirely before accept (and is what gets replayed) or
// entirely after (and is queued as an ordinary post-replay line) — never
// interleaved with the replay write itself.
//
// # Non-blocking fan-out (adr0012: bars are read-only, mutation never
// flows back)
//
// Every write to a client uses a short, bounded write deadline
// (writeTimeout) rather than Python's `conn.setblocking(False)` +
// BlockingIOError — Go's net package has no equivalent of a deadline of
// exactly "now" that still attempts the syscall: internal/poll checks the
// deadline BEFORE issuing the write, so an already-past deadline fails
// every write unconditionally, even ones that would have completed
// instantly (measured: SetWriteDeadline(time.Now()) makes 100% of writes
// fail with i/o timeout, never touching the socket). writeTimeout gives
// the syscall a small window to complete when the client's kernel receive
// buffer has room — the common case, resolved in microseconds — and bounds
// the wait to that same small window when it would otherwise block, which
// is what "wedged" means here. A write failure of any kind (timeout,
// EPIPE, ECONNRESET, ...) drops that one client immediately; it never
// aborts the fan-out to the others, and after the first dropped write no
// further Publish call touches that connection again — so a wedged
// client costs Publish at most one writeTimeout, not one per call. The
// publisher never calls Read on a client connection at all — a
// garbage-writing client has nothing to corrupt or act on, since mutation
// never flows back through this socket (adr0012).
import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"hotkeyd/internal/proc"
)

// writeTimeout bounds how long a single write to one client may take
// before it is treated as wedged and the client is dropped. Small enough
// that even a full fan-out to several stalled clients in one Publish call
// stays well under any latency a keystroke's dispatch path would notice;
// see the file-level doc's "Non-blocking fan-out" section for why this
// replaces Python's true non-blocking send.
const writeTimeout = 20 * time.Millisecond

// SocketPath returns the per-display state-socket path for display, e.g.
// "$XDG_RUNTIME_DIR/hotkeyd-10.sock". Shares proc.NormalizeDisplay with
// proc.LockPath / proc.GrabReportPath (Task 10) — the "one helper, one
// test" rule this task's success criterion names — so ":10.0" and ":10"
// resolve to the identical socket, matching hotkeyd.py's socket_path.
func SocketPath(display string) string {
	return filepath.Join(proc.RuntimeDir(), fmt.Sprintf("hotkeyd-%s.sock", proc.NormalizeDisplay(display)))
}

// ErrChannelUnavailable means the socket's directory does not exist —
// mirrors layers.py's ChannelUnavailable. Per adr0014 this is fail-fast: a
// publisher cannot re-establish its own vanished precondition from the
// inside, so NewStatePublisher returns this NAMED error (edge case:
// "$XDG_RUNTIME_DIR vanishes under the daemon -> publish fails named,
// daemon survives") rather than panicking, so the caller can choose to run
// without a state feed — grabs are the job; the feed is best-effort.
type ErrChannelUnavailable struct {
	Path string
	Err  error
}

func (e *ErrChannelUnavailable) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("layer: state socket unavailable at %s: %v", e.Path, e.Err)
	}
	return fmt.Sprintf("layer: state socket unavailable: no such directory: %s", e.Path)
}

func (e *ErrChannelUnavailable) Unwrap() error { return e.Err }

// wireState is the frozen wire encoding: one JSON object per line, fields
// "layer" (string) and "mod" (string or null) — [[ft009]]'s Bar.qml and
// qs-focus-border.py parse exactly this shape unchanged. Mod is a pointer
// so the empty-string "no sublayer" in-memory value (State.Mod == "")
// encodes as JSON null rather than "" — Bar.qml's `s.mod ? String(s.mod) :
// ""` and qs-focus-border.py's `.get('mod')` both treat null and absence
// the same way, but null is what hotkeyd.py's StatePublisher._send
// actually emits (json.dumps({"mod": None, ...})) and the golden test
// pins that.
type wireState struct {
	Layer string  `json:"layer"`
	Mod   *string `json:"mod"`
}

// encodeStateLine renders st as one newline-terminated JSON line, in the
// exact compact form hotkeyd.py's `json.dumps(state, separators=(",",
// ":"))` produces (no spaces after ':' or ','; encoding/json's default
// Marshal already omits both, and struct field order fixes "layer" before
// "mod" to match Python's insertion-ordered dict).
func encodeStateLine(st State) []byte {
	var mod *string
	if st.Mod != "" {
		m := st.Mod
		mod = &m
	}
	// json.Marshal on this fixed, always-valid struct cannot fail.
	data, _ := json.Marshal(wireState{Layer: st.Layer, Mod: mod})
	return append(data, '\n')
}

// StatePublisher is a unix-socket fan-out for layer/held-modifier state —
// the Go port of layers.py's StatePublisher, restructured around Go's
// concurrency primitives (a dedicated accept goroutine + a mutex guarding
// `current` and the client set) rather than Python's single-threaded
// selectors.DefaultSelector poll loop. See the package-doc-adjacent
// comment above this file's import block for the two deliberate
// divergences (accept-time replay always answers; replay happens inside
// accept, not a later poll).
//
// Implements the Publisher interface (engine.go) via Publish, so an Engine
// can be constructed with Config{Publisher: statePublisher}.
type StatePublisher struct {
	path string
	ln   *net.UnixListener

	mu      sync.Mutex
	current State
	clients map[*net.UnixConn]struct{}
	closed  bool

	acceptDone chan struct{}
}

// NewStatePublisher binds the unix socket at path and starts accepting
// connections in the background. initial is the state a fresh client must
// see as its very first line if it connects before any Publish call — the
// caller supplies the engine's actual starting state (Engine.State(),
// always valid with no event required), which is what makes
// accept-time replay always answer rather than replicating bd
// dotfiles-4uiu's "nothing until the first change" gap.
//
// Edge case "socket path already exists from a SIGKILLed predecessor":
// unconditionally unlinked and rebound. Unlike Python's ChannelBusy
// probe-before-unlink, this does not re-derive liveness by connecting to
// the stale path first — the caller is required to already hold this
// display's single-instance lock (proc.AcquireLock) before constructing a
// publisher, which is a stronger guarantee than a connect probe: no other
// hotkeyd process for this display can be running, so any file at path is
// necessarily stale. Documented here because it is the one place this
// port's contract is narrower than Python's (no ErrChannelBusy).
func NewStatePublisher(path string, initial State) (*StatePublisher, error) {
	dir := filepath.Dir(path)
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return nil, &ErrChannelUnavailable{Path: dir, Err: err}
	}

	// Stale-socket reap: see the doc above on why no probe is needed.
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return nil, &ErrChannelUnavailable{Path: path, Err: err}
	}

	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
			return nil, &ErrChannelUnavailable{Path: path, Err: err}
		}
		return nil, err
	}

	p := &StatePublisher{
		path:       path,
		ln:         ln,
		current:    initial,
		clients:    map[*net.UnixConn]struct{}{},
		acceptDone: make(chan struct{}),
	}
	go p.acceptLoop()
	return p, nil
}

// ClientCount is the number of live subscribers. Exposed so tests can
// assert a dead client is actually reaped rather than merely tolerated —
// swallowing a write error without dropping the connection leaks a fd per
// dead bar for the life of the session.
func (p *StatePublisher) ClientCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.clients)
}

// acceptLoop accepts connections until the listener is closed. Each fresh
// connection is replayed the current state and registered for future
// Publish calls under ONE lock acquisition — see the file-level doc's
// "Accept-time replay is structural" section for why that ordering
// guarantee matters.
func (p *StatePublisher) acceptLoop() {
	defer close(p.acceptDone)
	for {
		conn, err := p.ln.AcceptUnix()
		if err != nil {
			return // listener closed (Close()); nothing left to accept
		}

		p.mu.Lock()
		if p.closed {
			p.mu.Unlock()
			_ = conn.Close()
			return
		}
		// REPLAY AT ACCEPT TIME: this is the first line the client will
		// ever read, written before the connection is registered for any
		// subsequent Publish — so a Publish racing this accept cannot be
		// seen before the replay it raced.
		if err := p.writeLocked(conn, p.current); err != nil {
			p.mu.Unlock()
			_ = conn.Close() // dead on arrival; nothing to register
			continue
		}
		p.clients[conn] = struct{}{}
		p.mu.Unlock()
	}
}

// Publish broadcasts st to every connected client and remembers it as the
// state a NEW client will be replayed at accept time. Implements the
// Publisher interface (engine.go): Engine.publish calls this on every
// state change, from the daemon's event-handling path, so it must never
// block on a slow or dead reader — see writeLocked.
func (p *StatePublisher) Publish(st State) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return
	}
	p.current = st
	for conn := range p.clients {
		if err := p.writeLocked(conn, st); err != nil {
			delete(p.clients, conn)
			_ = conn.Close()
		}
	}
}

// writeLocked sends st to conn without ever blocking the caller: the
// deadline is set to "now", so the write syscall is attempted once and,
// if it cannot complete immediately (the client's receive buffer is
// full — a wedged or dead-slow reader), fails right away instead of
// waiting — the same guarantee Python's non-blocking socket.send()
// makes, translated to Go's deadline-based API. Must be called with p.mu
// held: it is used both from acceptLoop (replay) and Publish (fan-out),
// and both need the write to be atomic with respect to client-set
// mutation.
func (p *StatePublisher) writeLocked(conn *net.UnixConn, st State) error {
	line := encodeStateLine(st)
	if err := conn.SetWriteDeadline(time.Now().Add(writeTimeout)); err != nil {
		return err
	}
	_, err := conn.Write(line)
	return err
}

// Close stops accepting connections, drops every client, and removes the
// socket file — matching layers.py's StatePublisher.close.
func (p *StatePublisher) Close() error {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return nil
	}
	p.closed = true
	for conn := range p.clients {
		_ = conn.Close()
		delete(p.clients, conn)
	}
	err := p.ln.Close()
	p.mu.Unlock()

	<-p.acceptDone // acceptLoop observes the listener close and returns
	if rmErr := os.Remove(p.path); rmErr != nil && !os.IsNotExist(rmErr) && err == nil {
		err = rmErr
	}
	return err
}
