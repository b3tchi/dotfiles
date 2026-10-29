// Package kwin is hotkeyd's client for the kwi3keys KWin plugin's grab
// server (sp011 Task 8/9). The plugin is a translator only: hotkeyd sends
// the set of (keysym, mods) chords it wants swallowed, and the plugin
// reports presses/releases of exactly those chords over one NDJSON unix
// socket ($XDG_RUNTIME_DIR/kwi3keys-<wayland socket>.sock). Protocol:
//
//	-> {"grab":[{"keysym":u32,"mods":u32},...]}   replaces the whole set
//	<- {"hello":1,"kwin":"6.8.1"}                 on connect
//	<- {"error":"busy"} then close                a second client
//	<- {"ev":"press"|"release","keysym","mods","device"}   grabbed chords
//	<- {"mods":u32}                               every modifier change
//
// mods use X11's values (Shift 1, Control 4, Alt 8, Super 64). The plugin
// clears the set when the client disconnects, so a reconnect must re-send.
package kwin

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// SocketName is the plugin's socket file under $XDG_RUNTIME_DIR for the
// KWin serving the Wayland socket display: one per KWin, so two KWins of one
// user (the RDP session, the phone's own screen) never share a grab server.
// An empty display is Wayland's default, wayland-0.
func SocketName(display string) string {
	if display == "" {
		display = "wayland-0"
	}
	return "kwi3keys-" + filepath.Base(display) + ".sock"
}

// SocketPath is where the plugin of the KWin this process is a client of
// listens: hotkeyd runs inside that KWin, so $WAYLAND_DISPLAY names it.
func SocketPath() string {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		dir = "/tmp"
	}
	return filepath.Join(dir, SocketName(os.Getenv("WAYLAND_DISPLAY")))
}

// Event is one decoded plugin message that is not hello. Kind is "press",
// "release" or "mods" (a bare modifier-state change, Keysym/Device unset).
// The client itself also emits "lost" (the connection dropped) and "up"
// (it reconnected and the set was re-sent), in order with the key events, so
// a consumer can drop any state that depended on grabs the plugin cleared.
type Event struct {
	Kind   string
	Keysym uint32
	Mods   uint32
	Device string
	// NoRelease marks a press whose source never reports its release
	// (the win32 key source's WM_HOTKEY): see layer.Event.NoRelease. The
	// KWin plugin's events never set it.
	NoRelease bool
}

type wireChord struct {
	Keysym uint32 `json:"keysym"`
	Mods   uint32 `json:"mods"`
}

type wireIn struct {
	Hello  *int    `json:"hello"`
	Kwin   string  `json:"kwin"`
	Error  string  `json:"error"`
	Ev     string  `json:"ev"`
	Keysym uint32  `json:"keysym"`
	Mods   *uint32 `json:"mods"`
	Device string  `json:"device"`
}

// decodeLine turns one plugin line into an Event. ok is false for hello
// lines; an error means malformed/unknown content.
func decodeLine(line []byte) (ev Event, hello bool, err error) {
	var w wireIn
	if err = json.Unmarshal(line, &w); err != nil {
		return Event{}, false, err
	}
	switch {
	case w.Hello != nil:
		return Event{}, true, nil
	case w.Error != "":
		return Event{}, false, fmt.Errorf("plugin error %q", w.Error)
	case w.Ev == "press" || w.Ev == "release":
		var m uint32
		if w.Mods != nil {
			m = *w.Mods
		}
		return Event{Kind: w.Ev, Keysym: w.Keysym, Mods: m, Device: w.Device}, false, nil
	case w.Ev == "" && w.Mods != nil:
		return Event{Kind: "mods", Mods: *w.Mods}, false, nil
	}
	return Event{}, false, errors.New("unrecognised message")
}

// reconnectBackoff is the first retry delay (doubles up to 2s).
var reconnectBackoff = 100 * time.Millisecond

// Client is a self-reconnecting connection to the grab server.
type Client struct {
	path    string
	log     func(string)
	events  chan Event
	backoff time.Duration // first retry delay; doubles to maxBackoff
	max     time.Duration

	mu     sync.Mutex
	conn   net.Conn
	set    []wireChord
	sent   []wireChord // what the live connection was last given; nil when down
	closed bool
	done   chan struct{}
}

// Dial connects once and waits for the hello. It fails fast: the error
// names the socket path, so hotkeyd can exit non-zero instead of running
// deaf. On success a goroutine keeps the connection alive (reconnecting
// with backoff and re-sending the current set) until Close.
func Dial(path string, log func(string)) (*Client, error) {
	if log == nil {
		log = func(s string) { fmt.Fprintln(os.Stderr, "hotkeyd: "+s) }
	}
	c := &Client{
		path: path, log: log, events: make(chan Event, 64),
		backoff: reconnectBackoff, max: 2 * time.Second,
		done: make(chan struct{}),
	}
	conn, br, err := c.connect()
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	c.conn = conn // set before returning so an immediate SetGrabs is sent
	c.mu.Unlock()
	go c.run(conn, br)
	return c, nil
}

// connect dials and consumes the hello (or the busy refusal).
func (c *Client) connect() (net.Conn, *bufio.Reader, error) {
	conn, err := net.DialTimeout("unix", c.path, 2*time.Second)
	if err != nil {
		return nil, nil, fmt.Errorf("kwi3keys grab server at %s: %w (is the kwi3keys KWin plugin loaded?)", c.path, err)
	}
	br := bufio.NewReaderSize(conn, 1<<16)
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	line, err := br.ReadBytes('\n')
	conn.SetReadDeadline(time.Time{})
	if err != nil {
		conn.Close()
		return nil, nil, fmt.Errorf("kwi3keys grab server at %s: no hello: %w", c.path, err)
	}
	_, hello, derr := decodeLine(line)
	if derr != nil || !hello {
		conn.Close()
		if derr == nil {
			derr = errors.New("first message was not hello")
		}
		return nil, nil, fmt.Errorf("kwi3keys grab server at %s: %w", c.path, derr)
	}
	return conn, br, nil
}

// Events delivers decoded press/release/mods events. It is closed after
// Close.
func (c *Client) Events() <-chan Event { return c.events }

// SetGrabs replaces the grab set and sends it if connected. The set is
// remembered and re-sent after every reconnect. Returns whether it was
// written to a live connection.
func (c *Client) SetGrabs(chords []wireChord) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.set = append([]wireChord(nil), chords...)
	return c.sendLocked()
}

func (c *Client) sendLocked() bool {
	if c.conn == nil {
		c.sent = nil
		return false
	}
	set := c.set
	if set == nil {
		set = []wireChord{}
	}
	b, _ := json.Marshal(map[string]any{"grab": set})
	if _, err := c.conn.Write(append(b, '\n')); err != nil {
		c.sent = nil
		return false
	}
	c.sent = append([]wireChord{}, set...)
	return true
}

// lastSent is what the live connection was last given (nil while disconnected).
func (c *Client) lastSent() []wireChord {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.sent
}

// Connected reports whether a live connection currently exists.
func (c *Client) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn != nil
}

// Close stops reconnecting and drops the connection.
func (c *Client) Close() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	close(c.done)
	if c.conn != nil {
		c.conn.Close()
	}
	c.mu.Unlock()
}

func (c *Client) run(conn net.Conn, br *bufio.Reader) {
	defer close(c.events)
	delay := c.backoff
	for first := true; ; first = false {
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			conn.Close()
			return
		}
		c.conn = conn
		if !first {
			c.sendLocked() // re-send the current set on every reconnect
		}
		c.mu.Unlock()
		delay = c.backoff

		c.readLoop(br)

		c.mu.Lock()
		c.conn = nil
		c.sent = nil
		c.mu.Unlock()
		conn.Close()
		c.emit(Event{Kind: "lost"})

		for {
			select {
			case <-c.done:
				return
			case <-time.After(delay):
			}
			nc, nbr, err := c.connect()
			if err == nil {
				conn, br = nc, nbr
				c.log("kwi3keys reconnected")
				c.emit(Event{Kind: "up"})
				break
			}
			if delay *= 2; delay > c.max {
				delay = c.max
			}
		}
	}
}

// emit delivers a client-originated event, giving up if the client closes.
func (c *Client) emit(ev Event) {
	select {
	case c.events <- ev:
	case <-c.done:
	}
}

func (c *Client) readLoop(br *bufio.Reader) {
	for {
		line, err := br.ReadBytes('\n')
		if len(line) > 0 {
			ev, hello, derr := decodeLine(line)
			switch {
			case derr != nil:
				c.log(fmt.Sprintf("kwi3keys: skipping malformed line %q: %v", string(line), derr))
			case hello:
			default:
				select {
				case c.events <- ev:
				case <-c.done:
					return
				}
			}
		}
		if err != nil {
			return
		}
	}
}
