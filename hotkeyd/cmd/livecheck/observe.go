package main

// observe.go is the out-of-process observer's toolkit: the three channels a
// separately-running Go daemon exposes to anything that is not inside it.
//
//	the state socket  — one JSON line per layer / held-modifier CHANGE
//	                    (internal/layer's StatePublisher wire format)
//	stderr            — the transition log, which carries the fields the
//	                    state socket deliberately does not: the keycode, the
//	                    modifier mask and the SOURCE DEVICE of whatever
//	                    caused the change
//	the grab report   — $XDG_RUNTIME_DIR/hotkeyd-<n>.grabs, the daemon's own
//	                    {wanted, active, missing[]} bookkeeping
//
// live_check.py reads all three off objects it constructed itself. This tool
// cannot: the daemon is another process with a compiled-in table. Everything
// here exists to make the same claims answerable from outside, which is also
// what makes them stronger — a field that is right in the daemon's own
// memory but absent on the wire is a real defect that an in-process check
// cannot see.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// -- the state socket -------------------------------------------------------

// State is one decoded state line. Mod is "" where the wire says null.
type State struct {
	Layer string
	Mod   string
}

func (s State) String() string {
	mod := "none"
	if s.Mod != "" {
		mod = s.Mod
	}
	return fmt.Sprintf("{layer=%s mod=%s}", s.Layer, mod)
}

type wireState struct {
	Layer *string `json:"layer"`
	Mod   *string `json:"mod"`
}

func parseStateLine(line string) (State, error) {
	var w wireState
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &w); err != nil {
		return State{}, fmt.Errorf("livecheck: state line %q: %w", line, err)
	}
	if w.Layer == nil {
		return State{}, fmt.Errorf("livecheck: state line %q has no layer field", line)
	}
	st := State{Layer: *w.Layer}
	if w.Mod != nil {
		st.Mod = *w.Mod
	}
	return st, nil
}

// StateWatcher tails a daemon's state socket, keeping every state it
// published in order.
type StateWatcher struct {
	conn net.Conn

	mu     sync.Mutex
	states []State
	err    error
}

// WatchState connects to path and starts recording. It uses a plain socket
// read rather than shelling out to `hotkeyd state-tail` on purpose: the
// state-tail subcommand is itself under test elsewhere, and an observer
// that depends on the thing it observes cannot report on it.
func WatchState(path string) (*StateWatcher, error) {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return nil, fmt.Errorf("livecheck: state socket %s: %w", path, err)
	}
	w := &StateWatcher{conn: conn}
	go func() {
		sc := bufio.NewScanner(conn)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" {
				continue
			}
			st, err := parseStateLine(line)
			w.mu.Lock()
			if err != nil {
				w.err = err
			} else {
				w.states = append(w.states, st)
			}
			w.mu.Unlock()
		}
	}()
	return w, nil
}

// States returns every state published since the last Reset, in order.
func (w *StateWatcher) States() []State {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make([]State, len(w.states))
	copy(out, w.states)
	return out
}

// Current is the most recent published state, if any.
func (w *StateWatcher) Current() (State, bool) {
	st := w.States()
	if len(st) == 0 {
		return State{}, false
	}
	return st[len(st)-1], true
}

// Await waits until a state satisfying pred has been published, or timeout
// elapses. Returns the matching state and whether it arrived.
//
// Polling a recorded list rather than blocking on a channel is deliberate:
// every claim here is about what the daemon DID publish, and a scenario that
// times out must still be able to print the whole sequence it saw.
func (w *StateWatcher) Await(pred func(State) bool, timeout time.Duration) (State, bool) {
	deadline := time.Now().Add(timeout)
	for {
		for _, st := range w.States() {
			if pred(st) {
				return st, true
			}
		}
		if time.Now().After(deadline) {
			return State{}, false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (w *StateWatcher) Reset() {
	w.mu.Lock()
	w.states = nil
	w.mu.Unlock()
}

func (w *StateWatcher) Close() {
	if w.conn != nil {
		w.conn.Close()
	}
}

// -- the daemon's stderr ----------------------------------------------------

// logSink is an io.Writer that keeps whole lines. Used as the daemon
// subprocess's Stderr.
type logSink struct {
	mu      sync.Mutex
	partial string
	lines   []string
}

func (s *logSink) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.partial += string(p)
	for {
		i := strings.IndexByte(s.partial, '\n')
		if i < 0 {
			break
		}
		s.lines = append(s.lines, strings.TrimRight(s.partial[:i], "\r"))
		s.partial = s.partial[i+1:]
	}
	return len(p), nil
}

func (s *logSink) Lines() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, len(s.lines))
	copy(out, s.lines)
	return out
}

func (s *logSink) Reset() {
	s.mu.Lock()
	s.lines = nil
	s.mu.Unlock()
}

// Await waits for a line matching pred, returning it and whether it arrived.
func (s *logSink) Await(pred func(string) bool, timeout time.Duration) (string, bool) {
	deadline := time.Now().Add(timeout)
	for {
		for _, l := range s.Lines() {
			if pred(l) {
				return l, true
			}
		}
		if time.Now().After(deadline) {
			return "", false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// -- the transition log -----------------------------------------------------

// Transition is one parsed `transition ...` line. Fields the daemon printed
// as the literal `none` come back EMPTY, never as the string "none": "none"
// is what a daemon that logged from engine state alone writes, and a parser
// that carried it through as a value would make the discriminating fields
// unfalsifiable.
type Transition struct {
	Raw         string
	From, To    string
	ModFrom     string
	ModTo       string
	Trigger     string
	Keycode     string
	Mask        uint64
	MaskPresent bool
	SourceID    string
	Device      string
}

var (
	reTransLayer = regexp.MustCompile(`\blayer=([^\s]+)->([^\s]+)`)
	reTransMod   = regexp.MustCompile(`\bmod=([^\s]+)->([^\s]+)`)
	reTransField = regexp.MustCompile(`\b(trigger|keycode|sourceid)=([^\s]+)`)
	reTransMask  = regexp.MustCompile(`\bmask=(none|0x[0-9a-fA-F]+)`)
	// PARITY: the two engines quote this field differently. Go's
	// formatTransition uses %q (double quotes); hotkeyd.py's
	// format_transition uses Python's !r, which emits SINGLE quotes for a
	// string with no apostrophe in it. Both spellings are accepted here so
	// this tool can grade either daemon — the divergence itself is a finding
	// for the parity gate, not something to hide by only parsing one.
	reTransDevice = regexp.MustCompile(`\bdevice=(none|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')`)
)

// unquoteEitherEngine strips the quoting off a transition-log field,
// accepting Go's %q and Python's !r. Single-quoted values are converted to
// the Go form before unquoting so escape handling stays the stdlib's.
func unquoteEitherEngine(q string) string {
	if len(q) >= 2 && q[0] == '\'' && q[len(q)-1] == '\'' {
		inner := strings.ReplaceAll(q[1:len(q)-1], `\'`, `'`)
		q = strconv.Quote(inner)
	}
	if s, err := strconv.Unquote(q); err == nil {
		return s
	}
	return q
}

func noneToEmpty(s string) string {
	if s == "none" {
		return ""
	}
	return s
}

func parseTransition(line string) (Transition, bool) {
	if !strings.Contains(line, "transition ") {
		return Transition{}, false
	}
	m := reTransLayer.FindStringSubmatch(line)
	if m == nil {
		return Transition{}, false
	}
	tr := Transition{Raw: line, From: m[1], To: m[2]}
	if m := reTransMod.FindStringSubmatch(line); m != nil {
		tr.ModFrom, tr.ModTo = noneToEmpty(m[1]), noneToEmpty(m[2])
	}
	for _, f := range reTransField.FindAllStringSubmatch(line, -1) {
		switch f[1] {
		case "trigger":
			tr.Trigger = noneToEmpty(f[2])
		case "keycode":
			tr.Keycode = noneToEmpty(f[2])
		case "sourceid":
			tr.SourceID = noneToEmpty(f[2])
		}
	}
	if m := reTransMask.FindStringSubmatch(line); m != nil && m[1] != "none" {
		if v, err := strconv.ParseUint(strings.TrimPrefix(m[1], "0x"), 16, 32); err == nil {
			tr.Mask, tr.MaskPresent = v, true
		}
	}
	if m := reTransDevice.FindStringSubmatch(line); m != nil && m[1] != "none" {
		tr.Device = unquoteEitherEngine(m[1])
	}
	return tr, true
}

// transitions extracts every transition line from a log slice.
func transitions(lines []string) []Transition {
	var out []Transition
	for _, l := range lines {
		if tr, ok := parseTransition(l); ok {
			out = append(out, tr)
		}
	}
	return out
}

var reGrabSummary = regexp.MustCompile(`(\d+) chords grabbed on \S+ via XI2 \(\$mod=(\w+)\)`)

// parseGrabSummary reads the daemon's own startup line, which is the only
// place it announces how many chords it obtained and which modifier it
// resolved $mod to on this display.
func parseGrabSummary(line string) (count int, mod string, ok bool) {
	m := reGrabSummary.FindStringSubmatch(line)
	if m == nil {
		return 0, "", false
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		return 0, "", false
	}
	return n, m[2], true
}
