package i3

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

// pollReadTimeout is the deadline pollReadableLocked arms before Peek(1),
// standing in for select(..., timeout=0)'s "is anything queued right now".
// It must be a small POSITIVE duration, never exactly time.Now() or a past
// value: measured on this platform, internal/poll short-circuits a read
// whose deadline has ALREADY expired by the time the syscall would run,
// returning a timeout WITHOUT ever attempting the read -- so already-
// buffered data is missed every time, deterministically, not as a race.
// Arming a hair in the future gives the runtime's poller a real (if tiny)
// window to observe and return already-available data immediately, while
// keeping the bound on an idle socket negligible against the daemon's
// per-iteration run-loop budget.
const pollReadTimeout = 2 * time.Millisecond

// reconnectBackoff bounds how often PollEvents will attempt to re-dial a
// lost connection: adr0014's "no unbounded inline retry", ported verbatim
// from hotkeyd.py's I3_RECONNECT_BACKOFF_S = 5.0 -- poll_events() runs on
// every iteration of the daemon's run loop, so without this floor a lost i3
// turns into a tight reconnect loop instead of a rate-bounded one.
const reconnectBackoff = 5 * time.Second

// EventHandler receives an i3 event dispatched during PollEvents. kind is
// the message type with EventMask already stripped (e.g. EventMode); data
// is the event's JSON payload decoded to a generic map, or nil if the
// payload was empty or failed to decode.
type EventHandler func(kind uint32, data map[string]any)

// Client is the single interface the daemon depends on for i3 IPC.
//
// Every capability hotkeyd.py's Daemon reached for via
// getattr(self.i3, "method", None) -- subscribe (wire_i3_mode), poll_events
// (pump_i3), fileno (i3_fileno), binding_state (sync_i3_mode) -- is a
// mandatory method here instead of an optional one reached through
// reflection. A test double built for the daemon (Task 12) must implement
// every method below or it fails to compile: the class of defect sp021's
// problem statement names ("wire_i3_mode, pump_i3, i3_fileno and
// sync_i3_mode all reach through getattr so test stubs may omit
// methods... an optional-wiring seam that degrades identically in
// production") cannot recur here, because there is no getattr -- there is
// only this interface.
//
// # Behaviour matrix: i3 death vs daemon life
//
// Extracted from hotkeyd.py's I3Client (hotkeyd/hotkeyd.py:837-1007) and
// its Daemon-level callers (wire_i3_mode/pump_i3/sync_i3_mode/i3_fileno,
// hotkeyd.py:1354-1396), then replicated method-for-method below:
//
//   - Command() transport failure (i3 unreachable, or the connection dies
//     mid-request/mid-reply): the connection is closed and the WHOLE
//     request is retried exactly once against a fresh connection
//     (hotkeyd.py's `for attempt in (1, 2)`). If the retry also fails, the
//     failure is a returned/named error -- never a panic, never silently
//     swallowed -- but it is NOT fatal to the daemon: a lost i3 must not
//     take the keyboard layer down with it (hotkeyd.py's docstring, verbatim
//     intent).
//   - Subscribe() transport failure: closed and returned as an error, with
//     NO retry (unlike Command, hotkeyd.py's `subscribe()` does not loop).
//     The wanted event set is remembered regardless of outcome, so the next
//     successful connect (by any path) re-subscribes automatically.
//   - BindingState() transport failure: closed and returned as an error.
//     hotkeyd.py falls back to a layer-engine default (`L.DEFAULT_I3_MODE`)
//     at this point; that default is a layer/daemon-level concept this
//     package does not own, so here the fallback decision is pushed to the
//     caller (Task 12's daemon), which already has the layer engine.
//   - PollEvents() while idle (i3 dies with nothing in flight): the call
//     that OBSERVES the dead socket (EOF, via a non-blocking readability
//     check) closes it and returns the named error; it does not itself
//     attempt to reconnect within that same call. reconnectBackoff
//     (retryAt) is armed only inside PollEvents' entry-time "not
//     connected" branch, which this observing call never reaches (it
//     entered with a live conn) -- so retryAt is NOT armed by the death
//     itself. This is a faithful port of hotkeyd.py's poll_events(), whose
//     `_retry_at` has the identical gap (touched only inside `if
//     self._sock is None:`). The consequence, true of both languages: the
//     VERY NEXT PollEvents call, seeing conn/sock nil with a subscription
//     still wanted, attempts ONE reconnect completely ungated -- adr0014's
//     backoff bounds attempts starting from THAT one, not from the death
//     that preceded it. A failed reconnect attempt (this ungated one, or
//     any later one) arms retryAt to now+reconnectBackoff regardless of
//     outcome, so only a run of CONSECUTIVE failures is rate-limited, and
//     never inline within one call. With NO subscription wanted, PollEvents
//     never dials at all -- "nothing to keep alive" (hotkeyd.py: `if not
//     self._subs: return False`).
//   - i3 restarts and comes back: the reconnect succeeds, immediately
//     re-sending SUBSCRIBE for every remembered event (hotkeyd.py's
//     `_connect()` does this as part of connecting). PollEvents' next call
//     reports reconnected=true -- exactly once, via a generation counter
//     bumped on every successful connect from ANY method (Command,
//     Subscribe, BindingState, or PollEvents itself) and compared against
//     what PollEvents last reported. That signal is the caller's cue to
//     re-read BindingState(), because a restarted i3 has reset its own mode
//     -- believing a remembered mode across a restart would refuse layer
//     entries it should now allow (hotkeyd.py's `pump_i3` comment, ported
//     verbatim as the reason this signal exists).
//   - A mode event arriving between Subscribe and the first Command: i3's
//     own message-type high bit (EventMask) is what makes this safe, not
//     call ordering. Every read -- inside Command's reply wait, inside
//     Subscribe's ack wait, inside PollEvents' drain -- tests that bit and
//     dispatches an event without ever mistaking it for the reply/ack a
//     caller is waiting on (mirrors hotkeyd.py's `_read_message`, which
//     every other method funnels through). A caller that starts waiting on
//     a reply is never "one message behind" the way the i3 IPC docs warn a
//     naive reader can be.
type Client interface {
	// Command runs cmd over the persistent connection (RUN_COMMAND). ok is
	// i3's own aggregate success: false if ANY command in a semicolon-
	// separated cmd string failed. i3Err carries i3's own error text for
	// every failing command (joined "; "), surfaced rather than swallowed.
	// err is a transport/protocol failure only -- i3 reachable but refusing
	// the command is NEVER an err, only ok=false.
	Command(cmd string) (ok bool, i3Err string, err error)

	// GetConfig returns i3's raw config text (GET_CONFIG), used by the
	// ownership check (Task 13) to determine which chords i3 itself binds.
	GetConfig() (string, error)

	// Subscribe adds events to the persistent subscription (idempotent --
	// an event already subscribed is not re-sent) and connects now if not
	// already connected.
	Subscribe(events ...string) error

	// BindingState returns the mode i3 is in right now (GET_BINDING_STATE).
	// Needed because i3 never sends a `mode` event for a mode it was
	// already in before Subscribe was called -- a daemon started (or
	// restarted) mid-mode would otherwise believe it owns the keyboard.
	BindingState() (string, error)

	// PollEvents does one non-blocking pass: drains whatever i3 has queued
	// on the connection, dispatching events to the handler passed to
	// NewClient, and -- rate-bounded per reconnectBackoff -- reconnects if
	// the connection is down and a subscription is wanted. reconnected
	// reports whether the connection was (re-)established since the LAST
	// PollEvents call, by any method's connect (see the Client behaviour
	// matrix above).
	PollEvents() (reconnected bool, err error)

	// Fileno exposes the underlying connection's file descriptor for the
	// daemon's select/poll-based run loop. ok is false when not connected.
	Fileno() (fd int, ok bool)

	Close() error
}

// client is the sole Client implementation: one persistent connection, its
// wanted subscription set, and the reconnect-generation bookkeeping that
// backs PollEvents' `reconnected` signal.
type client struct {
	pathFn  func() (string, error)
	onEvent EventHandler
	now     func() time.Time
	backoff time.Duration

	mu      sync.Mutex
	conn    net.Conn
	br      *bufio.Reader
	fd      int
	fdOK    bool
	subs    []string
	subSeen map[string]bool
	gen     int
	seenGen int
	retryAt time.Time
}

// NewClient constructs a Client. pathFn resolves the i3 IPC socket path on
// every (re)connect -- pass DiscoverSocket for the literal $I3SOCK-then-CLI
// resolution, or a display-pinned resolver mirroring hotkeyd.py's
// cross-display-safe path (see DiscoverSocket's doc comment). onEvent may
// be nil if the caller has not subscribed to anything yet.
func NewClient(pathFn func() (string, error), onEvent EventHandler) Client {
	return &client{
		pathFn:  pathFn,
		onEvent: onEvent,
		now:     time.Now,
		backoff: reconnectBackoff,
		subSeen: map[string]bool{},
	}
}

func (c *client) Command(cmd string) (bool, string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if c.conn == nil {
			if err := c.connectLocked(); err != nil {
				lastErr = err
				c.closeLocked()
				continue
			}
		}
		if err := c.sendLocked(MsgRunCommand, []byte(cmd)); err != nil {
			lastErr = err
			c.closeLocked()
			continue
		}
		payload, err := c.recvReplyLocked()
		if err != nil {
			lastErr = err
			c.closeLocked()
			continue
		}
		return parseCommandReply(payload)
	}
	return false, "", fmt.Errorf("i3 ipc: RUN_COMMAND failed after retry: %w", lastErr)
}

func (c *client) GetConfig() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		if err := c.connectLocked(); err != nil {
			return "", err
		}
	}
	if err := c.sendLocked(MsgGetConfig, nil); err != nil {
		c.closeLocked()
		return "", err
	}
	payload, err := c.recvReplyLocked()
	if err != nil {
		c.closeLocked()
		return "", err
	}
	// INCLUDED CONFIGS ARE PART OF THE ANSWER (dotfiles-ylmp.15). GET_CONFIG's
	// `config` field carries ONLY the top-level file; every file i3 pulled in
	// through an `include` glob comes back separately in `included_configs`.
	//
	// In this repo that is not a corner case, it is where the binds live: the
	// i3 config is a common base plus a `~/.i3/config.d/*.conf` glob carrying
	// the per-platform overlay AND `zz-fallback-binds.conf`, the panic
	// fallback. A reader that takes `config` alone therefore cannot see the
	// fallback at all — which made `check --ownership` answer "no chord is
	// owned by BOTH" for a session where i3 had just been handed the daemon's
	// entire chord set by a panic. That is the one verdict it exists to give
	// and it was structurally unable to give it. (test-panic.sh's getconfig.py
	// documents the same i3 behaviour and reads both halves; this is the Go
	// side catching up.)
	//
	// `variable_replaced_contents` is preferred over `raw_contents` for the
	// same reason ownership compares resolved chords: `bindsym $mod+h` and
	// `bindsym Mod4+h` are the same bind, and only the replaced form says so.
	var data struct {
		Config   string `json:"config"`
		Included []struct {
			Path     string `json:"path"`
			Replaced string `json:"variable_replaced_contents"`
			Raw      string `json:"raw_contents"`
		} `json:"included_configs"`
	}
	if err := json.Unmarshal(payload, &data); err != nil {
		return "", fmt.Errorf("i3 ipc: decoding GET_CONFIG reply: %w", err)
	}
	var b strings.Builder
	b.WriteString(data.Config)
	for _, inc := range data.Included {
		text := inc.Replaced
		if text == "" {
			text = inc.Raw
		}
		if text == "" {
			continue
		}
		b.WriteString("\n# --- included: ")
		b.WriteString(inc.Path)
		b.WriteString("\n")
		b.WriteString(text)
	}
	return b.String(), nil
}

func (c *client) Subscribe(events ...string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	for _, e := range events {
		if !c.subSeen[e] {
			c.subs = append(c.subs, e)
			c.subSeen[e] = true
		}
	}

	if c.conn == nil {
		// connectLocked re-subscribes to the full wanted set as part of
		// connecting (mirrors hotkeyd.py's _connect()), so there is
		// nothing further to send here.
		if err := c.connectLocked(); err != nil {
			return err
		}
		// This connect is the caller's own request, not news to report
		// back to it via a later PollEvents call.
		c.seenGen = c.gen
		return nil
	}

	if err := c.sendLocked(MsgSubscribe, subsPayload(c.subs)); err != nil {
		c.closeLocked()
		return err
	}
	if _, err := c.recvReplyLocked(); err != nil {
		c.closeLocked()
		return err
	}
	return nil
}

func (c *client) BindingState() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		if err := c.connectLocked(); err != nil {
			return "", err
		}
	}
	if err := c.sendLocked(MsgGetBindingState, nil); err != nil {
		c.closeLocked()
		return "", err
	}
	payload, err := c.recvReplyLocked()
	if err != nil {
		c.closeLocked()
		return "", err
	}
	var data struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(payload, &data); err != nil {
		return "", fmt.Errorf("i3 ipc: decoding GET_BINDING_STATE reply: %w", err)
	}
	return data.Name, nil
}

func (c *client) PollEvents() (bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		if len(c.subs) == 0 {
			return false, nil // nothing to keep alive
		}
		now := c.now()
		if now.Before(c.retryAt) {
			return false, nil // adr0014: rate-bounded, not a tight loop
		}
		c.retryAt = now.Add(c.backoff)
		if err := c.connectLocked(); err != nil {
			return false, err
		}
	}

	fresh := c.gen != c.seenGen
	c.seenGen = c.gen

	for c.conn != nil {
		ready, err := c.pollReadableLocked()
		if err != nil {
			c.closeLocked()
			return fresh, err
		}
		if !ready {
			break
		}
		if _, _, isEvent, err := c.recvMessageLocked(); err != nil {
			c.closeLocked()
			return fresh, err
		} else if !isEvent {
			// A reply arrived with nobody waiting on it -- cannot happen
			// under this Client's intended single-goroutine-per-connection
			// use (a caller never calls PollEvents concurrently with a
			// Command/Subscribe/BindingState still waiting on its own
			// reply), so this is a defensive no-op rather than a state
			// this package tries to recover from.
			continue
		}
	}
	return fresh, nil
}

func (c *client) Fileno() (int, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == nil || !c.fdOK {
		return 0, false
	}
	return c.fd, true
}

func (c *client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closeLocked()
}

// -- internals, all assuming c.mu is already held --------------------------

func (c *client) connectLocked() error {
	path, err := c.pathFn()
	if err != nil {
		return fmt.Errorf("i3 ipc: resolving socket path: %w", err)
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		return fmt.Errorf("i3 ipc: dial %s: %w", path, err)
	}
	c.conn = conn
	c.br = bufio.NewReader(conn)
	c.fd, c.fdOK = fdOf(conn)
	c.gen++

	if len(c.subs) > 0 {
		if err := c.sendLocked(MsgSubscribe, subsPayload(c.subs)); err != nil {
			c.closeLocked()
			return err
		}
		if _, err := c.recvReplyLocked(); err != nil {
			c.closeLocked()
			return err
		}
	}
	return nil
}

func (c *client) sendLocked(mtype uint32, payload []byte) error {
	if err := writeFrame(c.conn, mtype, payload); err != nil {
		return fmt.Errorf("i3 ipc: writing request: %w", err)
	}
	return nil
}

// recvMessageLocked reads exactly one frame. If it is an event (EventMask
// set), it is dispatched to onEvent and isEvent is true; otherwise it is a
// reply and isEvent is false.
func (c *client) recvMessageLocked() (mtype uint32, payload []byte, isEvent bool, err error) {
	f, err := readFrame(c.br)
	if err != nil {
		return 0, nil, false, err
	}
	if f.mtype&EventMask != 0 {
		kind := f.mtype &^ EventMask
		if c.onEvent != nil {
			var data map[string]any
			if len(f.payload) > 0 {
				_ = json.Unmarshal(f.payload, &data) // malformed payload: dispatch with nil data rather than dropping the event
			}
			c.onEvent(kind, data)
		}
		return kind, f.payload, true, nil
	}
	return f.mtype, f.payload, false, nil
}

// recvReplyLocked reads messages until it gets a non-event one (a reply),
// dispatching any events it passes along the way -- mirrors hotkeyd.py's
// `_recv_reply` loop over `_read_message`.
func (c *client) recvReplyLocked() ([]byte, error) {
	for {
		_, payload, isEvent, err := c.recvMessageLocked()
		if err != nil {
			return nil, err
		}
		if !isEvent {
			return payload, nil
		}
	}
}

// pollReadableLocked reports whether at least one byte is already buffered
// on the connection, without blocking -- the stdlib-only equivalent of
// hotkeyd.py's `select.select([sock], [], [], 0)`. A read deadline in the
// past turns the underlying Read into an immediate "would block" check;
// Peek leaves any peeked byte in the buffer for the actual readFrame call
// that follows, so nothing is lost or double-consumed.
func (c *client) pollReadableLocked() (bool, error) {
	// Deliberately time.Now().Add(pollReadTimeout), NOT c.now(): this
	// deadline drives a real socket read, not the (test-injectable)
	// reconnect-backoff clock. Using the injected clock here would make an
	// already-elapsed test-only "now" a real, possibly-arbitrary OS
	// deadline. See pollReadTimeout's doc comment for why this must be a
	// small POSITIVE offset rather than time.Now() itself.
	if err := c.conn.SetReadDeadline(time.Now().Add(pollReadTimeout)); err != nil {
		return false, fmt.Errorf("i3 ipc: setting read deadline: %w", err)
	}
	_, err := c.br.Peek(1)
	if clrErr := c.conn.SetReadDeadline(time.Time{}); clrErr != nil && err == nil {
		return false, fmt.Errorf("i3 ipc: clearing read deadline: %w", clrErr)
	}
	if err == nil {
		return true, nil
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return false, nil
	}
	return false, wrapEOF(err)
}

func (c *client) closeLocked() error {
	if c.conn == nil {
		return nil
	}
	err := c.conn.Close()
	c.conn = nil
	c.br = nil
	c.fdOK = false
	return err
}

// fdOf extracts the raw file descriptor from a Unix domain socket
// connection, stdlib-only (no golang.org/x/sys/unix -- adr0021's
// zero-dependency invariant). Returns ok=false for any connection type
// this package did not itself create as a Unix socket.
func fdOf(conn net.Conn) (int, bool) {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, false
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return 0, false
	}
	var fd int
	if ctrlErr := raw.Control(func(f uintptr) { fd = int(f) }); ctrlErr != nil {
		return 0, false
	}
	return fd, true
}

func subsPayload(subs []string) []byte {
	b, _ := json.Marshal(subs) // subs is always []string; Marshal cannot fail here
	return b
}

// parseCommandReply decodes a RUN_COMMAND reply -- a JSON array with one
// {"success":bool,"error":string} object per semicolon-separated command in
// the request. ok is true only if every command succeeded; i3Err joins the
// error text of every command that did not, so a failure is surfaced
// verbatim rather than swallowed into a bare false.
func parseCommandReply(payload []byte) (bool, string, error) {
	var results []struct {
		Success bool   `json:"success"`
		Error   string `json:"error"`
	}
	if err := json.Unmarshal(payload, &results); err != nil {
		return false, "", fmt.Errorf("i3 ipc: decoding RUN_COMMAND reply: %w", err)
	}

	ok := true
	var errs []string
	for _, r := range results {
		if !r.Success {
			ok = false
			if r.Error != "" {
				errs = append(errs, r.Error)
			}
		}
	}
	return ok, strings.Join(errs, "; "), nil
}
