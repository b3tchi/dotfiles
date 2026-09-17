// Package tui owns agent-monitor's key-driven state — extracted from
// cmd/agent-monitor/main.go's T8/T9 PROVISIONAL inline switch, per sp030
// Task 10. It holds Model: focus, the committed filter, and each pane's
// cursor and scroll offset — the state a keystroke can change — plus the
// Key/SpecialKey vocabulary HandleKey acts on.
//
// sp032 T2 removed the other two things this package used to hold. The
// byte-stream escape decoder went because bubbletea decodes keys, and the
// restore-exactly-once guard went with the hazard it existed for: rendering
// no longer happens on a sampler's goroutine, so there is no cross-goroutine
// panic that would leave the terminal in raw mode, and bubbletea restores
// the terminal for the cases that remain. Both were DELETED rather than left
// unused — a dead raw-mode path is the thing a later "restore this" commit
// resurrects.
//
// This package reads no source data itself (source.Row / source.Message are
// only referenced as the shape FilterRoster/FilterMessages filter), and it
// renders nothing — filtering here is a pure slice-in/slice-out transform;
// cmd/agent-monitor/main.go is what threads its result into render.Render /
// render.RenderLog.
package tui

import (
	"strings"

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
// is open, and each pane's own cursor and scroll offset.
//
// Selection lives in the *Cursor fields — the row j/k and the arrows move.
// *Scroll is FIRST-CLASS STATE alongside it (sp032 T1), not a function of
// it: ScrollRoster/ScrollMessages move it on their own (the wheel in T3, the
// frozen tail in T6), SetRosterLen/SetMessagesLen and
// SetRosterViewport/SetMessagesViewport only CLAMP it into range, and cursor
// motion nudges it by the MINIMUM needed to bring the cursor back inside
// [scroll, scroll+viewport-1]. A cursor already on screen leaves scroll
// untouched, and a cursor deliberately scrolled off screen STAYS off screen
// — that state is legal now, where sp031's derive-from-cursor model made it
// unrepresentable.
//
// sp031 re-derived scroll from the cursor on every SetLen, i.e. every
// two-second sampler tick. That is what T1 replaces: any scroll a wheel sets
// would otherwise be undone within two seconds by a tick that changed
// nothing.
//
// *Viewport is how many rows of the pane are visible on screen this frame,
// reported by the caller via SetRosterViewport/SetMessagesViewport —
// without it (the zero value) there is no window to keep the cursor inside,
// so scroll simply tracks the cursor 1:1, which is what keeps every caller
// that only ever set *Len (never *Viewport) — --once above all — working
// exactly as before this refactor.
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
// before scrolling — see main.go's filterRosterRows), clamps RosterCursor
// into [0, len-1] (or 0 when len is 0) and RosterScroll into [0, maxTop] IN
// THE SAME PASS — so a filter that shrinks the row count can never leave
// either one pointing past the new end, even before the next keystroke.
//
// sp032 T1: the scroll is CLAMPED here, not re-derived from the cursor. It
// has to be, because main.go calls this on every sampler tick (every two
// seconds): a re-derive would drag the scroll back onto the cursor within
// two seconds of any wheel event, which is the whole premise T3's wheel and
// T6's frozen tail rest on. The one exception is the legacy viewport <= 0
// regime, where scroll IS the cursor by definition — see scrollAfterClamp.
func (m *Model) SetRosterLen(n int) {
	m.RosterLen = n
	m.RosterCursor = clamp(m.RosterCursor, 0, maxIndex(n))
	m.RosterScroll = scrollAfterClamp(m.RosterScroll, m.RosterCursor, m.RosterLen, m.RosterViewport)
}

// SetMessagesLen is SetRosterLen's twin for the message pane.
func (m *Model) SetMessagesLen(n int) {
	m.MessagesLen = n
	m.MessagesCursor = clamp(m.MessagesCursor, 0, maxIndex(n))
	m.MessagesScroll = scrollAfterClamp(m.MessagesScroll, m.MessagesCursor, m.MessagesLen, m.MessagesViewport)
}

// SetRosterViewport records how many rows of the roster pane are visible
// this frame (0 if the caller does not track it) and re-fits RosterScroll to
// the new height: always clamped to the new [0, maxTop] so a resize cannot
// leave scroll past the last page, and additionally moved the minimum needed
// to keep the cursor on screen IF THE CURSOR WAS ON SCREEN BEFORE (see
// scrollAfterViewport for why that condition and not an unconditional
// re-derive).
func (m *Model) SetRosterViewport(n int) {
	m.RosterScroll = scrollAfterViewport(m.RosterScroll, m.RosterCursor, m.RosterLen, m.RosterViewport, n)
	m.RosterViewport = n
}

// SetMessagesViewport is SetRosterViewport's twin for the message pane.
func (m *Model) SetMessagesViewport(n int) {
	m.MessagesScroll = scrollAfterViewport(m.MessagesScroll, m.MessagesCursor, m.MessagesLen, m.MessagesViewport, n)
	m.MessagesViewport = n
}

// ScrollRoster moves the roster pane's scroll offset by delta WITHOUT
// moving its cursor (sp032 T1) — the entry point the wheel (T3) and the
// tail-follow (T6) use. Clamped to [0, maxTop], so it can never point past
// the last row that still shows content.
func (m *Model) ScrollRoster(delta int) {
	m.RosterScroll = clamp(m.RosterScroll+delta, 0, maxTop(m.RosterLen, m.RosterViewport))
}

// ScrollMessages is ScrollRoster's twin for the message pane.
func (m *Model) ScrollMessages(delta int) {
	m.MessagesScroll = clamp(m.MessagesScroll+delta, 0, maxTop(m.MessagesLen, m.MessagesViewport))
}

// maxTop is the largest valid scroll offset: the top row of the last page.
//
// viewport <= 0 is the legacy regime (see deriveScroll): there is no window,
// so scroll behaves exactly like a cursor and its bound is the cursor's —
// the last row index. The literal [0, max(0, len-viewport)] of the success
// criterion would admit len itself there, which is a slice bound rather than
// a row, and nothing in that regime scrolls independently anyway (the next
// SetLen re-pins scroll to the cursor).
func maxTop(length, viewport int) int {
	if viewport <= 0 {
		return maxIndex(length)
	}
	if length <= viewport {
		return 0
	}
	return length - viewport
}

func maxIndex(n int) int {
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
	top := maxTop(length, viewport)
	if top == 0 {
		// The whole list fits inside the viewport — nothing to scroll.
		return 0
	}
	scroll := prevScroll
	if cursor < scroll {
		scroll = cursor
	} else if cursor > scroll+viewport-1 {
		scroll = cursor - viewport + 1
	}
	return clamp(scroll, 0, top)
}

// visible reports whether cursor sits inside the window a scroll offset of
// scroll shows. In the legacy viewport <= 0 regime there is no window, and
// scroll == cursor is the only state that regime ever produces, so that is
// what "visible" means there.
func visible(cursor, scroll, viewport int) bool {
	if viewport <= 0 {
		return scroll == cursor
	}
	return cursor >= scroll && cursor <= scroll+viewport-1
}

// scrollAfterClamp is what SetRosterLen/SetMessagesLen apply once the length
// (and the cursor) have been clamped: the scroll keeps whatever value the
// operator put it at, reduced only as far as the new bounds require.
//
// viewport <= 0 is the compatibility contract for every caller that sets
// *Len and never *Viewport (--once, and every pre-sp032 test): there is no
// window to hold anything inside, and the old model's `scroll` field WAS the
// cursor in every observable way, so scroll keeps tracking it 1:1.
func scrollAfterClamp(prevScroll, cursor, length, viewport int) int {
	if viewport <= 0 {
		return cursor
	}
	return clamp(prevScroll, 0, maxTop(length, viewport))
}

// scrollAfterViewport re-fits a scroll offset to a pane that just changed
// height. It always clamps to the new [0, maxTop] (criterion 4: a resize
// cannot leave scroll past the last full page), and it ensures the cursor is
// still visible ONLY IF the cursor was visible under the OLD height.
//
// The condition is the load-bearing part. main.go re-reports a viewport on
// every frame, and the reported value changes whenever a pane's row count
// changes — i.e. on ordinary sampler ticks, not just on SIGWINCH. An
// unconditional re-derive here would therefore undo a wheel scroll within
// two seconds, exactly as a re-derive inside SetLen would. Gating on "was it
// visible before" keeps sp031's resize guarantee (a reader whose selection
// was on screen keeps it on screen across a resize —
// TestCursor_ViewportResizeBringsCursorBackIntoView,
// TestRenderFrame_ResizeKeepsCursorRowVisibleInSameFrame) while leaving a
// deliberately off-screen cursor (post-wheel, sp032 T3/T6) off-screen.
func scrollAfterViewport(prevScroll, cursor, length, oldViewport, newViewport int) int {
	if visible(cursor, prevScroll, oldViewport) {
		return deriveScroll(prevScroll, cursor, length, newViewport)
	}
	if newViewport <= 0 {
		return cursor
	}
	return clamp(prevScroll, 0, maxTop(length, newViewport))
}

// moveCursor shifts the focused pane's cursor by delta, clamped to the
// pane's current bounds, then recomputes that pane's derived scroll so the
// new cursor position stays visible. An empty list (len 0) clamps the
// cursor to 0 and is a valid no-op, never a negative index.
func (m *Model) moveCursor(delta int) {
	switch m.Focus {
	case PaneRoster:
		m.RosterCursor = clamp(m.RosterCursor+delta, 0, maxIndex(m.RosterLen))
		m.RosterScroll = deriveScroll(m.RosterScroll, m.RosterCursor, m.RosterLen, m.RosterViewport)
	case PaneMessages:
		m.MessagesCursor = clamp(m.MessagesCursor+delta, 0, maxIndex(m.MessagesLen))
		m.MessagesScroll = deriveScroll(m.MessagesScroll, m.MessagesCursor, m.MessagesLen, m.MessagesViewport)
	}
}

// ClickPane is sp032 T3's left-press entry point: main.go's hit test has
// already converted a screen (x, y) into (pane, isData, offset), and this is
// the only place that turns THAT into model state. It focuses pane
// unconditionally — including a header, column-header or placeholder press
// (isData false) — and, only when isData is true, selects the row at that
// pane's CURRENT scroll plus offset, clamped exactly like every other cursor
// write in this file so a stale or out-of-range offset can never escape
// [0, len-1].
//
// It deliberately does not check m.Editing. Every keyboard entry point
// swallows runes into an open filter draft, but a mouse press is not a rune:
// sp032 T3's edge case is that a click while Editing still moves focus and
// selection, and the draft text is untouched either way since ClickPane
// never reads or writes m.draft.
func (m *Model) ClickPane(pane Pane, isData bool, offset int) {
	m.Focus = pane
	if !isData {
		return
	}
	switch pane {
	case PaneRoster:
		m.RosterCursor = clamp(m.RosterScroll+offset, 0, maxIndex(m.RosterLen))
	case PaneMessages:
		m.MessagesCursor = clamp(m.MessagesScroll+offset, 0, maxIndex(m.MessagesLen))
	}
}

// ScrollPane is sp032 T3's wheel entry point: it dispatches to Task 1's
// ScrollRoster/ScrollMessages, which move scroll WITHOUT moving the cursor
// and WITHOUT touching focus — so a wheel over an unfocused pane scrolls it
// in place, exactly as the success criterion asks, through the one scroll
// path T1 already built rather than a second one invented here.
func (m *Model) ScrollPane(pane Pane, delta int) {
	switch pane {
	case PaneRoster:
		m.ScrollRoster(delta)
	case PaneMessages:
		m.ScrollMessages(delta)
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

// SpecialKey names a non-printable key HandleKey acts on. main.go's
// translateKey is what maps a bubbletea key event onto these.
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

// Key is one keypress: either a printable Rune, or a Special key. The zero
// value Key{} — Rune 0, Special SpecialNone — is a no-op for HandleKey, and
// is what an event with no mapping in this surface (a bare Esc, a function
// key) amounts to: swallowed, rather than misreported as some other key.
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
