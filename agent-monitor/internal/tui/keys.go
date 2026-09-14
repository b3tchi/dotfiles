// Package tui owns agent-monitor's key handling — extracted from
// cmd/agent-monitor/main.go's T8/T9 PROVISIONAL inline switch, per sp030
// Task 10. It holds three things:
//
//   - Model: focus, the committed filter, and each pane's scroll offset —
//     the state a keystroke can change.
//   - Decoder: turns a raw byte stream (stdin in raw mode) into Key events,
//     assembling multi-byte arrow-key escape sequences so callers never see
//     a bare ESC byte misread as text.
//   - Restorer: the "restore the terminal exactly once, on every exit path
//     including a panic" guard main.go wraps every goroutine that renders
//     in — see its doc comment for why a single top-level `defer` in main()
//     is not sufficient by itself.
//
// This package reads no source data itself (source.Row / source.Message are
// only referenced as the shape FilterRoster/FilterMessages filter), and it
// renders nothing — filtering here is a pure slice-in/slice-out transform;
// cmd/agent-monitor/main.go is what threads its result into render.Render /
// render.RenderLog.
package tui

import (
	"strings"
	"sync"

	"agent-monitor/internal/source"
)

// Pane identifies which of the two panes has focus — the one `tab` moves
// between and arrows/jk scroll.
type Pane int

const (
	PaneRoster Pane = iota
	PaneMessages
)

// Filter is the committed (Enter-confirmed) filter query. Set distinguishes
// "the user pressed `/`, typed nothing, and confirmed" from "the user never
// pressed `/` at all" — both leave Query == "" (an empty string is a
// substring of everything, so both render every row), but they are
// different STATES, not the same one rendered two ways. See
// TestFilter_EmptyCommittedFilterDiffersFromNoFilter.
type Filter struct {
	Set   bool
	Query string
}

// Model is agent-monitor's key-driven state: which pane has focus, the
// committed filter (if any), an in-progress filter draft while `/` editing
// is open, and each pane's own cursor plus the scroll offset DERIVED from
// it.
//
// Selection lives in the *Cursor fields — the row j/k and the arrows
// actually move. *Scroll is no longer moved directly; it is recomputed
// every time the cursor, the list length or the viewport changes, so it
// always keeps the cursor inside [scroll, scroll+viewport-1]. *Viewport is
// how many rows of the pane are visible on screen this frame, reported by
// the caller via SetRosterViewport/SetMessagesViewport — without it (the
// zero value) there is no window to keep the cursor inside, so scroll
// simply tracks the cursor 1:1, which is what keeps every caller that only
// ever set *Len (never *Viewport) working exactly as before this refactor.
type Model struct {
	Focus  Pane
	Filter Filter

	// Project is the --project flag's value (sp031 T3): main.go sets it once
	// at startup and no keystroke ever touches it — unlike Filter, there is
	// no Editing/commit step here, since it is a CLI argument, not something
	// typed interactively. Empty means unset (that includes an explicit
	// `--project ""`: flag.String gives both the same zero value, so no
	// special-casing is needed to tell them apart). It restricts only the
	// roster (FilterRoster) — FilterMessages never reads it, because the bus
	// is already scoped by repository, so every message in view is in scope
	// regardless of which project a roster row belongs to.
	Project string

	// Editing is true from `/` until Enter commits (or the model is fed
	// another `/`, restarting the draft). Every rune key belongs to the
	// draft while Editing is true — including 'q' and 'r', which would
	// otherwise quit or force-refresh; a filter query typed on a keyboard
	// must never accidentally trigger those (see
	// TestFilter_QWhileEditingIsTextNotQuit).
	Editing bool
	draft   string

	RosterCursor   int
	RosterScroll   int
	RosterLen      int
	RosterViewport int

	MessagesCursor   int
	MessagesScroll   int
	MessagesLen      int
	MessagesViewport int

	// DetailVisible is the detail pane's on/off state (sp031 T5): present by
	// default, toggled by `d`. It is independent of MessagesCursor — hiding
	// the pane never touches selection, so toggling it off and back on shows
	// the same message (see TestDetailVisible_ToggleDoesNotAffectSelection).
	DetailVisible bool
}

// NewModel builds a Model with no filter set, roster focused, both panes
// empty (length 0, scroll 0) until the first sample sets a real length, and
// the detail pane visible (sp031 T5: present by default).
func NewModel() *Model {
	return &Model{Focus: PaneRoster, DetailVisible: true}
}

// SetRosterLen records the roster's current row count (after filtering,
// before scrolling — see main.go's filteredCensusSample), clamps
// RosterCursor into [0, len-1] (or 0 when len is 0) IN THE SAME PASS, and
// recomputes RosterScroll from the clamped cursor — so a filter that
// shrinks the row count can never leave the cursor (or its derived scroll)
// pointing past the new end, even before the next keystroke.
func (m *Model) SetRosterLen(n int) {
	m.RosterLen = n
	m.RosterCursor = clamp(m.RosterCursor, 0, maxScroll(n))
	m.RosterScroll = deriveScroll(m.RosterScroll, m.RosterCursor, m.RosterLen, m.RosterViewport)
}

// SetMessagesLen is SetRosterLen's twin for the message pane.
func (m *Model) SetMessagesLen(n int) {
	m.MessagesLen = n
	m.MessagesCursor = clamp(m.MessagesCursor, 0, maxScroll(n))
	m.MessagesScroll = deriveScroll(m.MessagesScroll, m.MessagesCursor, m.MessagesLen, m.MessagesViewport)
}

// SetRosterViewport records how many rows of the roster pane are visible
// this frame (0 if the caller does not track it) and recomputes
// RosterScroll so a terminal resize can never leave the cursor off-screen.
func (m *Model) SetRosterViewport(n int) {
	m.RosterViewport = n
	m.RosterScroll = deriveScroll(m.RosterScroll, m.RosterCursor, m.RosterLen, m.RosterViewport)
}

// SetMessagesViewport is SetRosterViewport's twin for the message pane.
func (m *Model) SetMessagesViewport(n int) {
	m.MessagesViewport = n
	m.MessagesScroll = deriveScroll(m.MessagesScroll, m.MessagesCursor, m.MessagesLen, m.MessagesViewport)
}

func maxScroll(n int) int {
	if n <= 0 {
		return 0
	}
	return n - 1
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// deriveScroll computes the scroll offset that keeps cursor visible inside
// a viewport of the given height over a list of the given length, using
// the previous scroll as the starting point so the window moves the
// minimum amount needed rather than re-centering on every keystroke.
//
// viewport <= 0 means the caller has never reported a real viewport height
// (or the pane has pathologically collapsed to nothing) — there is no
// window to keep the cursor inside, so scroll degrades to tracking the
// cursor directly. This is deliberate, not just a safe default: it is what
// keeps every caller written before this refactor (none of which call
// SetRosterViewport/SetMessagesViewport) working exactly as before, since
// the old `scroll` field WAS the cursor in every observable way.
func deriveScroll(prevScroll, cursor, length, viewport int) int {
	if viewport <= 0 {
		return cursor
	}
	maxTop := length - viewport
	if maxTop <= 0 {
		// The whole list fits inside the viewport — nothing to scroll.
		return 0
	}
	scroll := prevScroll
	if cursor < scroll {
		scroll = cursor
	} else if cursor > scroll+viewport-1 {
		scroll = cursor - viewport + 1
	}
	return clamp(scroll, 0, maxTop)
}

// moveCursor shifts the focused pane's cursor by delta, clamped to the
// pane's current bounds, then recomputes that pane's derived scroll so the
// new cursor position stays visible. An empty list (len 0) clamps the
// cursor to 0 and is a valid no-op, never a negative index.
func (m *Model) moveCursor(delta int) {
	switch m.Focus {
	case PaneRoster:
		m.RosterCursor = clamp(m.RosterCursor+delta, 0, maxScroll(m.RosterLen))
		m.RosterScroll = deriveScroll(m.RosterScroll, m.RosterCursor, m.RosterLen, m.RosterViewport)
	case PaneMessages:
		m.MessagesCursor = clamp(m.MessagesCursor+delta, 0, maxScroll(m.MessagesLen))
		m.MessagesScroll = deriveScroll(m.MessagesScroll, m.MessagesCursor, m.MessagesLen, m.MessagesViewport)
	}
}

func (m *Model) toggleFocus() {
	if m.Focus == PaneRoster {
		m.Focus = PaneMessages
	} else {
		m.Focus = PaneRoster
	}
}

// FilterRoster applies --project (m.Project) and the committed interactive
// filter (m.Filter) to rows, in that order, and BOTH apply when both are
// set — sp031 T3's composition rule, not a replacement of one by the other.
//
// m.Project matches source.Row.Project EXACTLY, case-insensitively: a
// project name is a slug/identifier (ft012/adr0024's tmux-pane attribution
// for claude rows, parse-pi-window's session-group read for pi rows), not
// free text, so a substring match would let "dotfiles" silently also catch a
// hypothetical "dotfiles-extra" project. Case-insensitivity is deliberate
// the other way: nothing guarantees a canonical case for that slug, and it
// keeps --project consistent with the interactive filter below, which
// already lower-cases its own match. Project == "" (unset, including an
// explicit --project "") is a no-op — it never means "rows with no
// project".
//
// The interactive filter still matches uid/name (source.DisplayName), the
// same column that identifies a row on screen, as a case-insensitive
// substring. An unset filter (Filter.Set == false) leaves that stage a
// no-op too.
func (m *Model) FilterRoster(rows []source.Row) []source.Row {
	out := rows
	if m.Project != "" {
		p := strings.ToLower(m.Project)
		filtered := make([]source.Row, 0, len(out))
		for _, r := range out {
			if strings.ToLower(r.Project) == p {
				filtered = append(filtered, r)
			}
		}
		out = filtered
	}
	if !m.Filter.Set {
		return out
	}
	q := strings.ToLower(m.Filter.Query)
	filtered := make([]source.Row, 0, len(out))
	for _, r := range out {
		if strings.Contains(strings.ToLower(source.DisplayName(r)), q) {
			filtered = append(filtered, r)
		}
	}
	return filtered
}

// FilterMessages applies the committed filter to messages on the field the
// message pane declares as its own: From, the sender identity — the message
// pane's analogue of the roster's uid/name, and cheap to match without
// invoking render's width-parameterised subject derivation. An unset filter
// returns messages unchanged.
func (m *Model) FilterMessages(msgs []source.Message) []source.Message {
	if !m.Filter.Set {
		return msgs
	}
	q := strings.ToLower(m.Filter.Query)
	out := make([]source.Message, 0, len(msgs))
	for _, msg := range msgs {
		if strings.Contains(strings.ToLower(msg.From), q) {
			out = append(out, msg)
		}
	}
	return out
}

// SpecialKey names a non-printable key HandleKey and Decoder both act on.
type SpecialKey int

const (
	SpecialNone SpecialKey = iota
	KeyUp
	KeyDown
	KeyLeft
	KeyRight
	KeyEnter
	KeyBackspace
	KeyTab
)

// Key is one decoded keypress: either a printable Rune, or a Special key.
// Zero value is Key{} — Rune 0, Special SpecialNone — which Decoder never
// produces on its own (an unrecognised CSI final byte decodes to this,
// deliberately swallowed rather than misreported as some other key).
type Key struct {
	Rune    rune
	Special SpecialKey
}

// Outcome is what one HandleKey call asks its caller to do. Both fields are
// false for the overwhelming majority of keys (scrolling, focus, filter
// editing) — those mutate Model directly and need nothing further from the
// caller.
type Outcome struct {
	Quit         bool
	ForceRefresh bool
}

// HandleKey drives ft016's key surface: `q`/Ctrl-C quit, `r` forces a
// refresh, `tab` moves focus, `/` opens filter editing, arrows/jk move the
// focused pane's cursor (the view follows — see moveCursor/deriveScroll),
// `d` toggles the detail pane (sp031 T5). While Editing is true, every key
// belongs to the filter draft instead (Enter commits, Backspace edits, any
// other rune appends) — see the Editing field doc for why this must come
// first.
func (m *Model) HandleKey(k Key) Outcome {
	if m.Editing {
		return m.handleEditingKey(k)
	}

	switch {
	case k.Rune == 'q' || k.Rune == 'Q' || k.Rune == 0x03:
		return Outcome{Quit: true}
	case k.Rune == 'r' || k.Rune == 'R':
		return Outcome{ForceRefresh: true}
	case k.Rune == 'd' || k.Rune == 'D':
		m.DetailVisible = !m.DetailVisible
	case k.Special == KeyTab:
		m.toggleFocus()
	case k.Rune == '/':
		m.Editing = true
		m.draft = ""
	case k.Special == KeyUp || k.Rune == 'k':
		m.moveCursor(-1)
	case k.Special == KeyDown || k.Rune == 'j':
		m.moveCursor(1)
	}
	return Outcome{}
}

func (m *Model) handleEditingKey(k Key) Outcome {
	switch k.Special {
	case KeyEnter:
		m.Filter = Filter{Set: true, Query: m.draft}
		m.Editing = false
		m.draft = ""
	case KeyBackspace:
		if r := []rune(m.draft); len(r) > 0 {
			m.draft = string(r[:len(r)-1])
		}
	default:
		if k.Rune != 0 {
			m.draft += string(k.Rune)
		}
	}
	return Outcome{}
}

// Decoder turns a raw byte stream into Key events, buffering the 3-byte CSI
// arrow sequences (ESC '[' A/B/C/D) so a caller reading stdin one byte at a
// time never sees a bare ESC byte misread as printable text or as a stray
// '[' + letter. ft016's key surface has no bare-Esc action, so a lone ESC
// not followed by '[' is not surfaced as its own key at all: the buffered
// ESC is simply dropped and the next byte is decoded fresh (see Feed's
// second case) — simpler than inventing a KeyEsc nothing in this surface
// consumes.
type Decoder struct {
	pending []byte
}

// Feed pushes one raw byte. It returns (Key{}, false) while an escape
// sequence is still being assembled, and (key, true) once a complete key is
// decided — including for every ordinary byte, which decodes immediately.
func (d *Decoder) Feed(b byte) (Key, bool) {
	switch len(d.pending) {
	case 0:
		if b == 0x1b {
			d.pending = append(d.pending, b)
			return Key{}, false
		}
		return decodeByte(b), true
	case 1: // buffered: ESC
		if b == '[' {
			d.pending = append(d.pending, b)
			return Key{}, false
		}
		// Not an arrow sequence after all — ft016 has no bare-Esc action, so
		// the buffered ESC is dropped silently and b decodes on its own.
		d.pending = d.pending[:0]
		return decodeByte(b), true
	default: // buffered: ESC '['
		d.pending = d.pending[:0]
		switch b {
		case 'A':
			return Key{Special: KeyUp}, true
		case 'B':
			return Key{Special: KeyDown}, true
		case 'C':
			return Key{Special: KeyRight}, true
		case 'D':
			return Key{Special: KeyLeft}, true
		default:
			return Key{}, true // unrecognised CSI final byte: swallow as a no-op
		}
	}
}

func decodeByte(b byte) Key {
	switch b {
	case '\r', '\n':
		return Key{Special: KeyEnter}
	case 0x7f, 0x08:
		return Key{Special: KeyBackspace}
	case '\t':
		return Key{Special: KeyTab}
	default:
		return Key{Rune: rune(b)}
	}
}

// Restorer wraps a terminal-restore callback so it fires AT MOST ONCE no
// matter how many exit paths race to call it: a normal quit, a signal, or a
// panic in a goroutine whose own unwind never reaches main()'s deferred
// restore at all.
//
// The hazard this exists for is NOT "a panic skips defers" — Go always runs
// a panicking goroutine's OWN deferred calls during unwind, so a panic on
// the SAME goroutine that registered `defer restore()` already restores the
// terminal today. The actual gap is cross-goroutine: agent-monitor's render
// callback (`draw`, wired through source.RunLoop's and
// source.RunMessagesLoop's onTick) runs on a BACKGROUND sampler goroutine,
// and Go does not run any OTHER goroutine's deferred calls before a panic
// takes the whole process down — main()'s top-level `defer restore()` would
// simply never fire, leaving the terminal in raw mode / the alternate
// screen forever. The fix is for every goroutine that might panic to
// register its OWN deferred restore against the SAME Restorer; sync.Once
// then guarantees the underlying callback still runs exactly once, however
// many of those goroutines' defers end up racing to call it.
type Restorer struct {
	once sync.Once
	fn   func()
}

// NewRestorer wraps fn so Restore (directly, or via Guard) runs it at most
// once.
func NewRestorer(fn func()) *Restorer {
	return &Restorer{fn: fn}
}

// Restore runs the wrapped callback exactly once, ever, across however many
// times it (or Guard, from however many goroutines) calls it.
func (r *Restorer) Restore() {
	r.once.Do(r.fn)
}

// Guard runs fn with Restore deferred in the CALLING goroutine — the piece
// a single top-level defer in main() cannot provide for a goroutine it did
// not itself register a defer in. Callers wrap every goroutine that renders
// (the main select loop, and each background sampler's onTick-driven draw)
// in Guard against the SAME Restorer, so a panic on any one of them still
// restores the terminal before that goroutine's crash takes the process
// down, and a normal return from any of them restores it too — whichever
// happens first, exactly once.
func (r *Restorer) Guard(fn func()) {
	defer r.Restore()
	fn()
}
