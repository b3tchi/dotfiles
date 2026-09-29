package kwi3rpc

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// RPCError is a JSON-RPC 2.0 error object kwi3 sent back for one Call -
// core/rpc.js's own error codes (-32601 unknown method, -32602 bad params,
// -32001 "no such window/workspace", -32000 a Logic throw, ...). Distinct
// from a transport error (Call's other error return, e.g. the socket is
// gone) so the daemon can log the two differently if it ever wants to.
type RPCError struct {
	Code    int
	Message string
}

func (e *RPCError) Error() string {
	return fmt.Sprintf("kwi3rpc: %d %s", e.Code, e.Message)
}

// ErrUnreachable marks a Call that failed because kwi3's socket could not
// be dialled at all. The Client logs the transition to "down" exactly once
// (and the one back up), so a caller should NOT log each such failure
// again - that is how "$KWI3SOCK set but dead: log once" holds across any
// number of dropped chords. Test with errors.Is.
var ErrUnreachable = errors.New("kwi3 unreachable")

type request struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int64       `json:"id"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

type response struct {
	ID     int64             `json:"id"`
	Result json.RawMessage   `json:"result"`
	Error  *responseErrorObj `json:"error"`
}

type responseErrorObj struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Option configures a Client at construction (New).
type Option func(*Client)

// WithLog overrides the client's log function (default: nothing - the
// daemon wires a real one in production; tests that care use this to
// capture what would otherwise go to daemonLog).
func WithLog(fn func(string)) Option {
	return func(c *Client) { c.log = fn }
}

// WithCallTimeout bounds each Call (write and reply together) to d; zero,
// the default, waits as long as kwi3 takes, which is what chord dispatch
// has always done. A Call that times out drops the connection like any
// other read failure - the late reply must never pair with a later request
// - and is not retried. kwi3-55l.25: the mode reporter uses it so a kwi3
// that has stopped answering costs one timeout per mode change, never a
// goroutine parked for ever holding the Client's lock.
func WithCallTimeout(d time.Duration) Option {
	return func(c *Client) { c.timeout = d }
}

// Client is a client for kwi3's rpc socket ($KWI3SOCK, ft010): one
// long-lived NDJSON connection, dialed lazily on the first Call and
// re-dialed on demand after any transport failure - never eagerly, and
// never queued or retried within the SAME Call (sp004 Task 16's edge
// cases: a chord during an outage is dropped, not queued; the next chord
// is what triggers the next reconnect attempt).
//
// Not safe for concurrent use from multiple goroutines issuing overlapping
// Calls - hotkeyd's own dispatch is single-threaded (one X event loop), and
// this package targets that caller; Call still takes its own lock so two
// calls from different goroutines cannot corrupt one connection's request/
// reply pairing, but they will simply serialise rather than run in
// parallel.
type Client struct {
	addr string
	dial func(network, address string) (net.Conn, error)
	log  func(string)
	// timeout bounds one Call; 0 means none (WithCallTimeout).
	timeout time.Duration

	mu     sync.Mutex
	conn   net.Conn
	reader *bufio.Reader
	nextID int64
	down   bool // true while addr is unreachable - logged once on the way down and once on the way back up, never per-Call
}

// New constructs a Client for kwi3's rpc socket at addr (a unix socket
// path - the same $KWI3SOCK value the daemon reads). It does not dial yet;
// the first Call does.
func New(addr string, opts ...Option) *Client {
	c := &Client{
		addr: addr,
		dial: net.Dial,
		log:  func(string) {},
	}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

// Close drops the underlying connection, if any. Safe to call more than
// once and on a Client that never successfully connected.
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closeLocked()
}

func (c *Client) closeLocked() error {
	if c.conn == nil {
		return nil
	}
	err := c.conn.Close()
	c.conn = nil
	c.reader = nil
	return err
}

func (c *Client) ensureConnectedLocked() error {
	if c.conn != nil {
		return nil
	}
	conn, err := c.dial("unix", c.addr)
	if err != nil {
		if !c.down {
			c.down = true
			c.log(fmt.Sprintf("kwi3rpc: cannot reach %s: %s (chords are dropped until it reconnects; logged once, not per chord)", c.addr, err))
		}
		return fmt.Errorf("kwi3rpc: dial %s: %w: %w", c.addr, ErrUnreachable, err)
	}
	c.conn = conn
	c.reader = bufio.NewReader(conn)
	if c.down {
		c.down = false
		c.log(fmt.Sprintf("kwi3rpc: reconnected to %s", c.addr))
	}
	return nil
}

// writeLocked writes one already-framed request line to c.conn, retrying
// ONCE on a freshly dialled connection if the write itself fails.
//
// This retry is safe specifically because a write failure means the
// request was never delivered anywhere - never partially, never twice.
// That is true on this transport (a unix domain SOCK_STREAM) in a way it
// would NOT be on plain TCP: measured empirically (see kwi3-5a8's task
// notes for the experiment), a write against a connection whose peer has
// already closed fails immediately with EPIPE/ECONNRESET on Linux rather
// than succeeding into a local send buffer first and only surfacing the
// failure on a later write or on read - 0/200 trials of "close the peer,
// then write with no delay" produced a silent success. So "the write
// failed" is a trustworthy "definitely not sent" signal here, and this is
// exactly the kwi3-5a8 bug: after kwi3 restarts, the Client's cached
// connection is already dead, the first chord's write fails against it,
// and without this retry the chord was dropped even though kwi3 was
// already back up and ready to accept a fresh connection.
//
// A failure on the SECOND (post-redial) write is returned as-is - two
// failures in a row means the fresh dial itself is not helping (e.g. kwi3
// is still down), so there is nothing more to retry.
//
// This must never be reached for a READ failure - see Call, which treats
// read failures as terminal (no retry), because kwi3 may already have run
// the command before the connection died.
func (c *Client) writeLocked(line []byte) error {
	if _, err := c.conn.Write(line); err != nil {
		c.closeLocked()
		if dialErr := c.ensureConnectedLocked(); dialErr != nil {
			return dialErr
		}
		if c.timeout > 0 {
			c.conn.SetDeadline(time.Now().Add(c.timeout))
		}
		if _, err2 := c.conn.Write(line); err2 != nil {
			c.closeLocked()
			return fmt.Errorf("kwi3rpc: write to %s: %w (retry on a fresh connection also failed: %s)", c.addr, err, err2)
		}
	}
	return nil
}

// Call sends one JSON-RPC 2.0 request and waits for its matching reply.
// params may be nil (a method that takes none, e.g. window.close with no
// id). The returned error is either a transport failure (dial refused,
// write/read failed, a malformed or mismatched reply - the connection is
// dropped in every one of these cases so the NEXT Call redials fresh) or
// an *RPCError (the connection is untouched - kwi3 answered, just with an
// error object, exactly as core/rpc.js's own throw guard promises: "the
// connection stays open after every one of these").
//
// A WRITE failure gets one transparent retry on a freshly dialled
// connection (see writeLocked) - kwi3-5a8: without it, the first chord
// issued after kwi3 restarts wrote to the connection Call had cached from
// before the restart, failed, and was dropped even though kwi3 was already
// back up. A READ failure is never retried: kwi3 may already have run the
// command before dying, and resending it would risk running it twice.
func (c *Client) Call(method string, params interface{}) (json.RawMessage, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.ensureConnectedLocked(); err != nil {
		return nil, err
	}

	id := atomic.AddInt64(&c.nextID, 1)
	req := request{JSONRPC: "2.0", ID: id, Method: method, Params: params}
	line, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("kwi3rpc: encode request: %w", err)
	}
	line = append(line, '\n')

	if c.timeout > 0 {
		// Set on whichever connection is current; writeLocked's one redial
		// sets its own below, so a retried write is bounded too.
		c.conn.SetDeadline(time.Now().Add(c.timeout))
	}
	if err := c.writeLocked(line); err != nil {
		return nil, err
	}

	raw, err := c.reader.ReadBytes('\n')
	if err != nil {
		c.closeLocked()
		return nil, fmt.Errorf("kwi3rpc: read from %s: %w", c.addr, err)
	}

	if c.timeout > 0 {
		c.conn.SetDeadline(time.Time{})
	}

	var resp response
	if err := json.Unmarshal(raw, &resp); err != nil {
		c.closeLocked()
		return nil, fmt.Errorf("kwi3rpc: decode reply: %w", err)
	}
	if resp.ID != id {
		// A reply for the wrong request means this connection's framing is
		// no longer trustworthy - drop it rather than risk pairing a FUTURE
		// request with a STALE reply.
		c.closeLocked()
		return nil, fmt.Errorf("kwi3rpc: reply id %d does not match request id %d", resp.ID, id)
	}
	if resp.Error != nil {
		return nil, &RPCError{Code: resp.Error.Code, Message: resp.Error.Message}
	}
	return resp.Result, nil
}

// Dispatch translates cmd (one of hotkeyd's own i3-command-string actions)
// via Translate and runs the resulting call(s) against this connection.
//
// A multi-statement cmd ("split h;exec notify-send 'tile side'") runs
// every statement even if an earlier one failed - the same "keep going"
// rule core/i3ipc.js's ipcRunCommand follows for its own semicolon-
// separated statements - and Dispatch returns the FIRST error seen, from
// Translate itself (an unsupported verb - nothing is sent anywhere) or
// from any one Call (a transport failure or an *RPCError).
func (c *Client) Dispatch(cmd string) error {
	calls, err := Translate(cmd)
	if err != nil {
		return err
	}
	var firstErr error
	for _, call := range calls {
		var callErr error
		if call.Method == methodWorkspaceNeighbour {
			callErr = c.dispatchNeighbour(call.Params)
		} else {
			_, callErr = c.Call(call.Method, call.Params)
		}
		if callErr != nil && firstErr == nil {
			firstErr = callErr
		}
	}
	return firstErr
}

// dispatchNeighbour resolves "workspace next"/"prev" locally: a
// workspace.list to find the currently focused workspace's num and the
// dense run's length, then a workspace.focus{num} at the wrapped
// neighbour position - the exact arithmetic core/i3ipc.js's own
// ipcNeighbourWorkspace uses ("(cur - 1 + step) % count + count) % count +
// 1"), so a kwi3-rpc "next" lands on the same workspace a kwi3-i3 "next"
// would.
func (c *Client) dispatchNeighbour(params interface{}) error {
	m, ok := params.(map[string]interface{})
	if !ok {
		return errors.New("kwi3rpc: internal error - workspace.neighbour params malformed")
	}
	stepF, ok := m["step"].(int)
	if !ok {
		return errors.New("kwi3rpc: internal error - workspace.neighbour step malformed")
	}
	raw, err := c.Call("workspace.list", nil)
	if err != nil {
		return err
	}
	var list []struct {
		Num     int  `json:"num"`
		Focused bool `json:"focused"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		return fmt.Errorf("kwi3rpc: decode workspace.list result: %w", err)
	}
	count := len(list)
	if count == 0 {
		return errors.New("kwi3rpc: workspace.list returned no workspaces")
	}
	cur := 1
	for _, w := range list {
		if w.Focused {
			cur = w.Num
			break
		}
	}
	target := ((cur-1+stepF)%count+count)%count + 1
	_, err = c.Call("workspace.focus", map[string]interface{}{"num": target})
	return err
}
