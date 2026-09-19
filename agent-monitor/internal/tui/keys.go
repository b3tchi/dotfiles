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

// Pane identifies which pane has focus — the one `tab` moves between and
// arrows/jk scroll.
//
// sp032 T4 added the third stop. The detail pane had geometry (T3's
// frameLayout) but was inert: no focus, no scroll, so a message longer than
// the pane's cap was unreadable inside the tool that exists to show it. It
// is a peer now, with its own scroll offset and a zoom.
type Pane int

const (
	PaneRoster Pane = iota
	PaneMessages
	PaneDetail
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
// frozen end in T6/sp033 T6), SetRosterLen/SetMessagesLen and
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

	// HasIdentity records whether the monitor resolved an operator identity
	// at startup (sp033 T4's source.ResolveIdentity). Like Project, cmd/
	// sets this once — there is no per-keystroke path to it. OpenComposer
	// refuses without it: a reply needs a FROM the send path (T9) can use,
	// and absent an identity there is none to offer.
	HasIdentity bool

	// Editing is true from `/` until Enter commits (or the model is fed
	// another `/`, restarting the draft). Every rune key belongs to the
	// draft while Editing is true — including 'q' and 'r', which would
	// otherwise quit or force-refresh; a filter query typed on a keyboard
	// must never accidentally trigger those (see
	// TestFilter_QWhileEditingIsTextNotQuit).
	Editing bool
	draft   string

	// Composing is sp033 T8's reply mode: true from a successful
	// OpenComposer until Esc abandons or ctrl+s yields the draft. It follows
	// Editing's idiom exactly — every rune belongs to the draft while it is
	// true — with one difference from a filter draft: ComposeTo is bound
	// ONCE, at open time, and never re-read. A message arriving mid-draft
	// can reorder the list under the cursor; reading the selection again at
	// send time would let that reorder redirect the reply (criterion 1,
	// TestComposer_RecipientSurvivesASampleThatMovesTheList).
	Composing    bool
	ComposeTo    string
	composeDraft string

	RosterCursor   int
	RosterScroll   int
	RosterLen      int
	RosterViewport int

	MessagesCursor   int
	MessagesScroll   int
	MessagesLen      int
	MessagesViewport int

	// PendingMessages is how many messages have arrived since the message
	// pane stopped being LIVE (sp032 T6, inverted for the head by sp033 T6)
	// — the `+N new` the log header carries while the pane is frozen on
	// purpose. It is zero whenever the pane is live, which is the invariant
	// every mutator below restores rather than a value anyone has to
	// remember to clear.
	//
	// It is a plain int, and Model stays a comparable struct: several
	// fixtures compare whole models with `*m != want`.
	PendingMessages int

	// ForYouCount is PendingMessages' twin for sp033 T7: of the rows
	// PendingMessages counted (arrived while the message pane was not live),
	// how many carry the operator's own address in ToAddresses — an address
	// comparison, never a label one (## plan's binding rule). It renders as
	// the header's `N for you` segment, kept deliberately separate from
	// PendingMessages' `+N new` — the two count different things, and
	// collapsing them loses the signal on exactly the busy bus that
	// motivated this feature (## plan anti-patterns).
	//
	// Model holds no source.Message here to compare against, so it cannot
	// derive this itself the way messagesLive derives liveness: main.go
	// (which reads the identity and this tick's messages) counts the
	// for-you rows among what's newly arrived and hands the result to
	// AddForYouArrivals. It is zero whenever the pane is live, exactly like
	// PendingMessages, and for the same reason PendingMessages stays a
	// plain int: several fixtures compare whole models with `*m != want`.
	ForYouCount int

	// DetailScroll, DetailLen and DetailViewport are the detail pane's
	// scroll state (sp032 T4), the same shape the other two panes use — and
	// deliberately so: the pane's body is displayed through a
	// bubbles/viewport, but the OFFSET AUTHORITY is here, exactly as
	// sp032's ## solution requires of every pane. A viewport that owned its
	// own YOffset would be a second authority over a pane whose content is
	// re-rendered on every two-second sampler tick, which is the failure
	// the spec's anti-pattern names.
	//
	// The detail pane has no cursor: nothing inside a message body is
	// selectable, so there is nothing for the scroll to "keep visible" and
	// no deriveScroll/legacy-viewport regime to honour. DetailLen is the
	// BODY's line count (the header line is chrome above the scrolled
	// region, always on screen), and DetailViewport is how many body rows
	// the pane shows this frame.
	DetailScroll   int
	DetailLen      int
	DetailViewport int

	// DetailVisible is the detail pane's on/off state (sp031 T5): present by
	// default, toggled by `d`. It is independent of MessagesCursor — hiding
	// the pane never touches selection, so toggling it off and back on shows
	// the same message (see TestDetailVisible_ToggleDoesNotAffectSelection).
	DetailVisible bool

	// DetailZoom is sp032 T4's full-screen mode: `enter`/`o` sets it, `esc`
	// clears it, and while it is set cmd/ renders the detail pane ALONE.
	// Two illegal states are excluded by construction rather than by
	// convention: a zoom is refused when no message is selected (there is
	// nothing to zoom), and `d` clears it on the way to hiding the pane, so
	// "hidden but zoomed" never exists.
	DetailZoom bool

	// detailSelection identifies the message the detail pane is currently
	// showing, as cmd/ describes it (see SetDetailSelection). It exists only
	// to answer "is this the same message as last frame?", which is what
	// separates a scroll that must SURVIVE a re-render from one that must
	// RESET.
	detailSelection string
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
// T6's frozen end (tail for the roster, head for messages since sp033 T6)
// rest on. The one exception is the legacy viewport <= 0
// regime, where scroll IS the cursor by definition — see scrollAfterClamp.
func (m *Model) SetRosterLen(n int) {
	m.RosterLen = n
	m.RosterCursor = clamp(m.RosterCursor, 0, maxIndex(n))
	m.RosterScroll = scrollAfterClamp(m.RosterScroll, m.RosterCursor, m.RosterLen, m.RosterViewport)
}

// SetMessagesLen is SetRosterLen's twin for the message pane, and it is
// additionally where sp032 T6's CONDITIONAL TAIL-FOLLOW lives — inverted for
// the HEAD by sp033 T6, since the pane now renders newest-first (row 0 is
// the newest envelope): main.go calls this on every sampler tick, so this is
// the one place a growing sample becomes visible to the model.
//
// Live (messagesLive) means the reader is parked on the newest message —
// row 0 with the scroll at the top — and the pane then STAYS at row 0 as new
// arrivals land there (row 0 is always the newest row by construction, so
// "following" costs nothing here the way re-deriving maxIndex/maxTop did at
// the tail). Not live means the reader scrolled back deliberately, and then
// NOTHING moves — the appended messages are COUNTED into PendingMessages
// instead, which is what the header's `+N new` reports until Home/g (or a
// click on row 0) returns the pane to live.
//
// Both halves are a rule rather than a default: unconditional follow would
// yank a reader off the message they are reading every two seconds, and
// never following would stop the live view being live (sp032 ## solution,
// which names both as anti-patterns, restated here for the other end).
//
// A SHRINKING sample (the bus was pruned) adds nothing — the count can never
// go negative — and a sample that appends nothing leaves it exactly where it
// was rather than resetting it. Not-live cursor/scroll stay BYTE-IDENTICAL
// across a growing sample (sp033 T6 criterion 3) — restated verbatim from
// sp032 rather than adjusted for the index shift a head-prepend causes,
// which is the cost `## known limitations` names for this task.
func (m *Model) SetMessagesLen(n int) {
	live := m.messagesLive()
	grown := n - m.MessagesLen
	m.MessagesLen = n

	if live {
		m.MessagesCursor = 0
		m.MessagesScroll = 0
		m.PendingMessages = 0
		m.ForYouCount = 0
		return
	}

	// The windowless regime counts nothing: see messagesLive for why --once
	// must never see either half of this feature.
	if grown > 0 && m.MessagesViewport > 0 {
		m.PendingMessages += grown
	}
	m.MessagesCursor = clamp(m.MessagesCursor, 0, maxIndex(n))
	m.MessagesScroll = scrollAfterClamp(m.MessagesScroll, m.MessagesCursor, m.MessagesLen, m.MessagesViewport)
	// A shrink can put the cursor back on row 0 — the pane is live again by
	// derivation, so the count it was carrying is stale.
	m.clearPendingWhenLive()
}

// messagesLive derives sp033 T6's LIVE state for the message pane: the
// cursor is on ROW 0 (the newest envelope) and the scroll is at the TOP. It
// is derived on every read rather than stored, so no keystroke, wheel event
// or sample can leave a "live" flag disagreeing with where the pane actually
// is.
//
// A pane with no reported viewport is never live, and that is a correctness
// requirement rather than a convenience. viewport <= 0 is T1's legacy regime
// where scroll IS the cursor (scrollAfterClamp), and it is what --once
// reports (renderFrame's height == 0 path never calls SetMessagesViewport).
// --once always renders the whole log from row 0 regardless of liveness, so
// disabling the concept there changes nothing it emits while keeping the
// invariant simple: PendingMessages stays 0 without a window to be "behind"
// in.
//
// An EMPTY pane is live (cursor and scroll are both 0 by construction): a
// pane with nothing in it is trivially at its own end, which is what makes
// the very first sample follow instead of arriving already `+N` behind.
func (m *Model) messagesLive() bool {
	if m.MessagesViewport <= 0 {
		return false
	}
	return m.MessagesCursor == 0 && m.MessagesScroll == 0
}

// clearPendingWhenLive restores the invariant "a live pane is never behind".
// Every mutator that can move the message pane's cursor or scroll ends with
// it, so returning to row 0 zeroes the count no matter WHICH way the reader
// got there — Home/g, a click on row 0, k onto it, a wheel, a page, a resize
// — rather than only through the keys criterion 4 happens to name.
func (m *Model) clearPendingWhenLive() {
	if m.messagesLive() {
		m.PendingMessages = 0
		m.ForYouCount = 0
	}
}

// AddForYouArrivals is ForYouCount's accumulation step, twinning
// SetMessagesLen's `m.PendingMessages += grown`. main.go calls it once per
// tick, right after SetMessagesLen, with however many of THIS tick's newly
// arrived rows carry the identity's address in ToAddresses (cmd/agent-
// monitor's countNewForYou is the one place that comparison happens — Model
// holds no source.Message to compare against here).
//
// It re-derives messagesLive() itself rather than trusting the caller to
// skip the call on a live pane: a tick where nothing for-you arrived still
// calls this with n == 0, and a live pane must read zero regardless of what
// n is, exactly like clearPendingWhenLive restores for PendingMessages. The
// windowless regime (MessagesViewport <= 0) counts nothing, for the same
// reason SetMessagesLen's grown-count gate exists: --once must never see
// this feature either.
func (m *Model) AddForYouArrivals(n int) {
	if m.messagesLive() {
		m.ForYouCount = 0
		return
	}
	if n > 0 && m.MessagesViewport > 0 {
		m.ForYouCount += n
	}
}

// OpenMessagesAtHead is sp032 T8's OPENING (renamed by sp033 T6, which moved
// LIVE from the tail to the head): it parks the message pane on its newest
// message — row 0, scroll at the top — which by messagesLive's derivation
// makes the pane LIVE — so the session's first sample is followed from then
// on, and clearPendingWhenLive zeroes any count the pane had picked up
// before it was opened.
//
// It exists as its own motion rather than as a rule inside SetMessagesLen or
// SetMessagesViewport because of dotfiles-utob's actual cause: renderFrame
// filters (and so sets the length) BEFORE it reports a viewport, so the
// session's first length always lands in the windowless regime, where T6
// disables liveness on purpose. An explicit motion, performed once per
// INTERACTIVE session by cmd/ and never on the --once path, sidesteps that
// regime rather than loosening its gate.
//
// It REFUSES a pane with no window and reports so, for the same reason
// messagesLive does: viewport <= 0 is the regime --once renders in, and a
// caller that gets false is expected to try again when the pane has a row to
// show the result in (a terminal too short for a data row is the live case
// — see cmd/agent-monitor's openMessagesAtHeadOnce).
//
// An empty log and a one-message log both open at index 0, which is where
// they already were; what the opening buys there is LIVENESS, so the first
// real sample arrives followed rather than counted.
func (m *Model) OpenMessagesAtHead() bool {
	if m.MessagesViewport <= 0 {
		return false
	}
	m.MessagesCursor = 0
	m.MessagesScroll = 0
	m.clearPendingWhenLive()
	return true
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
	m.clearPendingWhenLive()
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
	m.clearPendingWhenLive()
}

// SetDetailLen records how many BODY lines the currently selected message
// renders to (sp032 T4), clamping the scroll into the new range in the same
// pass so a shorter message can never leave the offset past its end — the
// slice-index guarantee the viewport's SetYOffset relies on.
func (m *Model) SetDetailLen(n int) {
	m.DetailLen = n
	m.DetailScroll = clamp(m.DetailScroll, 0, detailMaxTop(m.DetailLen, m.DetailViewport))
}

// SetDetailViewport records how many body rows the detail pane shows this
// frame and re-clamps the scroll, so a shrunk terminal (or a zoom exit)
// cannot leave the offset past the last full page.
func (m *Model) SetDetailViewport(n int) {
	m.DetailViewport = n
	m.DetailScroll = clamp(m.DetailScroll, 0, detailMaxTop(m.DetailLen, n))
}

// ScrollDetail moves the detail body's scroll offset by delta, clamped so a
// body shorter than the window never scrolls at all (no phantom scroll) and
// a long one stops on its last full page.
func (m *Model) ScrollDetail(delta int) {
	m.DetailScroll = clamp(m.DetailScroll+delta, 0, detailMaxTop(m.DetailLen, m.DetailViewport))
}

// SetDetailSelection tells the model WHICH message the detail pane is
// showing, as an opaque identity string cmd/ derives from the envelope. The
// scroll offset is kept when the identity is unchanged — which is what makes
// a position survive the two-second re-render of the same message — and
// reset to the top when it changes, so moving the selection never drops the
// reader into the middle of a message they have not seen the start of.
//
// An identity rather than the cursor INDEX, because the message list grows:
// a new arrival can leave the cursor on index 0 while index 0 is still the
// same envelope, and a filter can leave the index alone while the message
// under it changes.
func (m *Model) SetDetailSelection(key string) {
	if key == m.detailSelection {
		return
	}
	m.detailSelection = key
	m.DetailScroll = 0
}

// detailMaxTop is maxTop without the legacy viewport<=0 cursor-tracking
// regime: the detail pane has no cursor, so "no window reported" simply
// means nothing is scrollable yet.
func detailMaxTop(length, viewport int) int {
	if viewport <= 0 || length <= viewport {
		return 0
	}
	return length - viewport
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
	case PaneDetail:
		// The detail pane has no cursor — jk/arrows scroll its body
		// directly (sp032 T4 criterion 3).
		m.ScrollDetail(delta)
	case PaneRoster:
		m.RosterCursor = clamp(m.RosterCursor+delta, 0, maxIndex(m.RosterLen))
		m.RosterScroll = deriveScroll(m.RosterScroll, m.RosterCursor, m.RosterLen, m.RosterViewport)
	case PaneMessages:
		m.MessagesCursor = clamp(m.MessagesCursor+delta, 0, maxIndex(m.MessagesLen))
		m.MessagesScroll = deriveScroll(m.MessagesScroll, m.MessagesCursor, m.MessagesLen, m.MessagesViewport)
		m.clearPendingWhenLive()
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
		m.clearPendingWhenLive()
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
	case PaneDetail:
		m.ScrollDetail(delta)
	}
}

// cycleFocus is `tab`: roster → messages → detail → roster (sp032 T4
// criterion 1). Two stops are skipped rather than visited, both for the same
// reason — focus must never land on something that is not on screen:
//
//   - a HIDDEN detail pane (`d` off) is not a stop, so the cycle degrades to
//     the two-stop one sp031 shipped;
//   - while ZOOMED the other two panes are not rendered at all, so tab has
//     nowhere to go and does nothing. (`esc` is how one leaves zoom.)
func (m *Model) cycleFocus() {
	if m.DetailZoom {
		return
	}
	switch m.Focus {
	case PaneRoster:
		m.Focus = PaneMessages
	case PaneMessages:
		if m.DetailVisible {
			m.Focus = PaneDetail
		} else {
			m.Focus = PaneRoster
		}
	default:
		m.Focus = PaneRoster
	}
}

// zoomDetail is `enter`/`o`: the detail pane takes the whole frame so a
// two-hundred-line result envelope can actually be read.
//
// It is REFUSED when no message is selected (criterion 5). MessagesLen is
// the post-filter row count cmd/ reports every frame and the cursor is
// clamped into it in the same pass, so "there is a message under the cursor"
// and "MessagesLen > 0" are the same statement — an empty bus and a filter
// that matched nothing both land here, and neither gets a full screen of
// "(no message selected)".
func (m *Model) zoomDetail() {
	if m.MessagesLen <= 0 {
		return
	}
	m.DetailVisible = true
	m.DetailZoom = true
	m.Focus = PaneDetail
}

// hideDetail is `d`'s off direction. It clears the zoom and moves focus off
// the pane, which is what keeps "hidden but focused" and "hidden but zoomed"
// from being representable (criterion 5 + its edge case). Focus goes to
// messages specifically: the detail pane shows the message pane's selection,
// so that is where the operator was looking.
func (m *Model) hideDetail() {
	m.DetailVisible = false
	m.DetailZoom = false
	if m.Focus == PaneDetail {
		m.Focus = PaneMessages
	}
}

// detailPage is how far PgUp/PgDn move the detail body: one full window, or
// a single line before any viewport has been reported.
//
// A FULL window here, against listPage's window-minus-one for the two list
// panes, is sp032 T5 criterion 1 as written and not an inconsistency. The
// list panes keep one overlapping row because a reader re-finds their place
// by the row they were already looking at, and that row carries a selection
// the cursor must land relative to. The detail pane has no cursor and no
// selectable row, so there is nothing to land relative to and a full window
// is simply the page.
func (m *Model) detailPage() int {
	if m.DetailViewport > 0 {
		return m.DetailViewport
	}
	return 1
}

// listPage is how far PgUp/PgDn move a LIST pane's cursor: one window minus
// the overlapping row, floored at one row.
//
// The floor is the whole reason this is a function. viewport-1 is -1 when no
// viewport has been reported (the --once path, and every frame before the
// first render) and 0 for a pane collapsed to a single row; a raw viewport-1
// would make PgDn page UP in the first case and do nothing at all in the
// second. Paging always moves at least one row in the direction it names.
func listPage(viewport int) int {
	step := viewport - 1
	if step < 1 {
		return 1
	}
	return step
}

// PageUp and PageDown are PgUp/PgDn on whichever pane has focus (sp032 T5
// criterion 1). They go through moveCursor for the two list panes, so the
// clamp and the minimum-move scroll adjustment are Task 1's single
// implementation rather than a second one written here, and through
// ScrollDetail for the third, which is the offset authority sp032's
// ## solution names for that pane.
//
// Nothing here reads or writes MessagesCursor when the detail pane has focus
// (criterion 4): the pane shows whatever that cursor selects, so a page that
// nudged it would swap the message out from under a reader mid-body.
func (m *Model) PageUp() {
	if m.Focus == PaneDetail {
		m.ScrollDetail(-m.detailPage())
		return
	}
	m.moveCursor(-listPage(m.focusedViewport()))
}

// PageDown is PageUp's mirror.
func (m *Model) PageDown() {
	if m.Focus == PaneDetail {
		m.ScrollDetail(m.detailPage())
		return
	}
	m.moveCursor(listPage(m.focusedViewport()))
}

// GoToFirst is Home (and its vim spelling g): row 0 of the focused list
// pane, or the top of the focused detail body. It is a no-op on an empty
// list — row 0 is where an empty pane's cursor already sits.
//
// sp033 T6 additionally makes this return the message pane to LIVE: row 0
// with the scroll at the top IS the live predicate (messagesLive) for that
// pane now that the log renders newest-first, so jumpTo's
// clearPendingWhenLive zeroes the `+N new` count as a consequence of where
// the cursor went rather than as a special case keyed on which key was
// pressed. sp032 pinned this same behavior on GoToLast, at the tail; T6
// moves it here because it is the destination that changed, not the rule.
func (m *Model) GoToFirst() {
	m.jumpTo(0)
}

// GoToLast is End (and its vim spelling G): the LAST ROW INDEX, len-1, not
// len — len is a slice bound and not a position a cursor may hold. On the
// detail pane it is the last full page of the body.
//
// On the message pane this now lands on the OLDEST envelope (sp033 T6: the
// log renders newest-first, so the last row is the far end from live) and
// deliberately does NOT clear PendingMessages — jumpTo's
// clearPendingWhenLive is still called unconditionally, but messagesLive is
// false here for any list longer than one row, so it is a no-op rather than
// a special case carved out for this key.
func (m *Model) GoToLast() {
	m.jumpTo(maxInt)
}

// maxInt is the "as far as this pane goes" sentinel jumpTo clamps down from,
// so GoToLast needs no per-pane length arithmetic of its own.
const maxInt = int(^uint(0) >> 1)

// jumpTo moves the focused pane to an absolute position, clamped into that
// pane's own bounds, and re-fits the scroll the same way a cursor keystroke
// does — so the row Home/End selects is on screen, not merely selected.
func (m *Model) jumpTo(idx int) {
	switch m.Focus {
	case PaneDetail:
		m.DetailScroll = clamp(idx, 0, detailMaxTop(m.DetailLen, m.DetailViewport))
	case PaneRoster:
		m.RosterCursor = clamp(idx, 0, maxIndex(m.RosterLen))
		m.RosterScroll = deriveScroll(m.RosterScroll, m.RosterCursor, m.RosterLen, m.RosterViewport)
	case PaneMessages:
		m.MessagesCursor = clamp(idx, 0, maxIndex(m.MessagesLen))
		m.MessagesScroll = deriveScroll(m.MessagesScroll, m.MessagesCursor, m.MessagesLen, m.MessagesViewport)
		m.clearPendingWhenLive()
	}
}

// focusedViewport is the focused LIST pane's window height. The detail pane
// never reaches here — both callers branch on it first — because its page is
// a full window rather than a window minus one.
func (m *Model) focusedViewport() int {
	if m.Focus == PaneMessages {
		return m.MessagesViewport
	}
	return m.RosterViewport
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

// FilterMessages applies the committed filter to messages on From, the
// sender identity, OR any entry of To, the recipient list — matching
// FilterRoster's case-insensitive substring rule. A row matching on both
// fields still appears once (dotfiles-1xfo: filtering by a worker's label
// must surface every message that mentions it, sent or received). An unset
// filter returns messages unchanged.
func (m *Model) FilterMessages(msgs []source.Message) []source.Message {
	if !m.Filter.Set {
		return msgs
	}
	q := strings.ToLower(m.Filter.Query)
	out := make([]source.Message, 0, len(msgs))
	for _, msg := range msgs {
		if strings.Contains(strings.ToLower(msg.From), q) {
			out = append(out, msg)
			continue
		}
		for _, to := range msg.To {
			if strings.Contains(strings.ToLower(to), q) {
				out = append(out, msg)
				break
			}
		}
	}
	return out
}

// OpenComposer is sp033 T8's opening: `r` on a focused message, mapped by
// cmd/ onto this call with the SELECTED message's from_address (empty when
// nothing is selected) — the same shape as SetDetailSelection, which is the
// existing precedent for cmd/ pushing an address-shaped fact into Model
// rather than Model re-deriving it from a message list it does not hold.
//
// toAddress is bound into ComposeTo immediately and never re-read: that is
// criterion 1's safety property, and it is what makes "reply went to the
// wrong worker because the list moved" unrepresentable rather than merely
// unlikely.
//
// It refuses in two cases, criterion 6, each with its own reason so a caller
// can say why rather than silently doing nothing:
//   - toAddress == "": nothing was selected to reply to.
//   - !m.HasIdentity: there is no resolved FROM the reply could be sent as.
//
// It also refuses while a filter draft is open or a composer is already
// open, since either would collide with the mode this call is about to
// enter.
func (m *Model) OpenComposer(toAddress string) (bool, string) {
	if toAddress == "" {
		return false, "no message selected"
	}
	if !m.HasIdentity {
		return false, "not registered: no identity to reply from"
	}
	if m.Editing {
		return false, "a filter is being edited"
	}
	if m.Composing {
		return false, "a reply is already being composed"
	}
	m.Composing = true
	m.ComposeTo = toAddress
	m.composeDraft = ""
	return true, ""
}

// SendRequest is what ctrl+s yields from the composer (criterion 3): the
// address OpenComposer bound at open time and the draft's final text. T9
// dispatches it as a tea.Cmd; nothing here interprets or sends it — the
// composer's job ends at handing it over.
type SendRequest struct {
	To   string
	Body string
}

// handleComposingKey is the reply draft's key surface, handleEditingKey's
// twin (sp033 T8): every rune belongs to the draft (criterion 2, including
// 'q', 'd', '/' and 'G' — exactly the filter draft's rule), the paging keys
// are swallowed explicitly rather than left to the default arm (criterion 4,
// [[sp032]] T5's rule restated for this mode), and Enter INSERTS a newline
// rather than committing — the one point where this diverges from
// handleEditingKey, since a reply is multi-line and Enter is not its commit
// key.
func (m *Model) handleComposingKey(k Key) Outcome {
	switch k.Special {
	case KeyPgUp, KeyPgDn, KeyHome, KeyEnd:
		// See handleEditingKey's identical arm: a paging key must not move a
		// pane out from under an open draft, and must not edit the draft
		// either.
	case KeyEsc:
		m.Composing = false
		m.ComposeTo = ""
		m.composeDraft = ""
	case KeyEnter:
		m.composeDraft += "\n"
	case KeyBackspace:
		if r := []rune(m.composeDraft); len(r) > 0 {
			m.composeDraft = string(r[:len(r)-1])
		}
	default:
		if k.Rune == 0x13 { // ctrl+s
			return m.commitCompose()
		}
		if k.Rune != 0 {
			m.composeDraft += string(k.Rune)
		}
	}
	return Outcome{}
}

// commitCompose is ctrl+s: criterion 5 makes an empty or whitespace-only
// draft a no-op that leaves the composer open rather than yielding an empty
// SendRequest — trimming only decides THAT, never mutates the draft itself,
// so a draft of pure whitespace the operator meant to keep typing into is
// not silently cleared.
func (m *Model) commitCompose() Outcome {
	if strings.TrimSpace(m.composeDraft) == "" {
		return Outcome{}
	}
	req := &SendRequest{To: m.ComposeTo, Body: m.composeDraft}
	m.Composing = false
	m.ComposeTo = ""
	m.composeDraft = ""
	return Outcome{Send: req}
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
	// KeyEsc and KeyPgUp/KeyPgDn arrive with sp032 T4. Esc was previously
	// not decoded AT ALL (a bare ESC byte reached sp031's byte-stream escape
	// decoder and was swallowed); it now leaves the detail zoom and abandons an open filter
	// draft.
	KeyEsc
	KeyPgUp
	KeyPgDn
	// KeyHome and KeyEnd arrive with sp032 T5, which is also what widens
	// KeyPgUp/KeyPgDn past the detail pane they were decoded for.
	KeyHome
	KeyEnd
)

// Key is one keypress: either a printable Rune, or a Special key. The zero
// value Key{} — Rune 0, Special SpecialNone — is a no-op for HandleKey, and
// is what an event with no mapping in this surface (a bare Esc, a function
// key) amounts to: swallowed, rather than misreported as some other key.
type Key struct {
	Rune    rune
	Special SpecialKey
}

// Outcome is what one HandleKey call asks its caller to do. All fields are
// zero for the overwhelming majority of keys (scrolling, focus, filter
// editing) — those mutate Model directly and need nothing further from the
// caller.
type Outcome struct {
	Quit         bool
	ForceRefresh bool

	// Send is set by ctrl+s on a non-empty composer draft (sp033 T8
	// criterion 3): the caller (T9) dispatches it as a tea.Cmd. Nil for
	// every other key, including a whitespace-only ctrl+s (criterion 5).
	Send *SendRequest
}

// HandleKey drives ft016's key surface: `q`/Ctrl-C quit, `r` forces a
// refresh, `tab` moves focus, `/` opens filter editing, arrows/jk move the
// focused pane's cursor (the view follows — see moveCursor/deriveScroll),
// `d` toggles the detail pane (sp031 T5), and PgUp/PgDn/Home/End/G page the
// focused pane (sp032 T5). While Editing is true, every key belongs to the
// filter draft instead (Enter commits, Backspace edits, any other rune
// appends, and the paging keys are swallowed outright) — see the Editing
// field doc for why this must come first. While Composing is true (sp033
// T8), every key belongs to the reply draft instead, checked second so a
// filter can never be open at the same time as a composer.
func (m *Model) HandleKey(k Key) Outcome {
	if m.Editing {
		return m.handleEditingKey(k)
	}
	if m.Composing {
		return m.handleComposingKey(k)
	}

	switch {
	case k.Rune == 'q' || k.Rune == 'Q' || k.Rune == 0x03:
		return Outcome{Quit: true}
	case k.Rune == 'r' || k.Rune == 'R':
		return Outcome{ForceRefresh: true}
	case k.Rune == 'd' || k.Rune == 'D':
		if m.DetailVisible {
			m.hideDetail()
		} else {
			m.DetailVisible = true
		}
	case k.Special == KeyTab:
		m.cycleFocus()
	case k.Special == KeyEnter || k.Rune == 'o' || k.Rune == 'O':
		m.zoomDetail()
	case k.Special == KeyEsc:
		m.DetailZoom = false
	case k.Special == KeyPgUp:
		m.PageUp()
	case k.Special == KeyPgDn:
		m.PageDown()
	case k.Special == KeyHome || k.Rune == 'g':
		// 'g' is sp033 T6's new vim spelling of Home, added to match 'G'
		// already spelling End (sp032 T5) — and to give Home/g's live-return
		// (see GoToFirst) the same two-key surface End/G has always had.
		m.GoToFirst()
	case k.Special == KeyEnd || k.Rune == 'G':
		m.GoToLast()
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

// handleEditingKey is the filter draft's key surface. sp032 T4 adds KeyEsc:
// it ABANDONS the draft — Editing closes, the draft text is dropped, and the
// previously committed Filter is left exactly as it was, which is what makes
// esc different from Enter on an empty draft (that COMMITS an empty query, a
// distinct state — see the Filter doc). It deliberately does not also leave
// the detail zoom in the same keystroke.
func (m *Model) handleEditingKey(k Key) Outcome {
	switch k.Special {
	case KeyPgUp, KeyPgDn, KeyHome, KeyEnd:
		// sp032 T5 criterion 3, spelled out rather than left to the default
		// arm. These are not runes, so the "every rune belongs to the draft"
		// rule says nothing about them, and without this arm a reader would
		// have to reason about whether falling through to default happens to
		// be inert today. Naming them keeps the swallow a decision: a paging
		// key must not move a pane out from under an open filter draft, and
		// it must not edit the draft either.
	case KeyEsc:
		m.Editing = false
		m.draft = ""
	case KeyEnter:
		m.Filter = Filter{Set: true, Query: m.draft}
		m.Editing = false
		m.draft = ""
		// sp032 T6 criterion 5: the committed filter changes the message
		// list's IDENTITY, so "N messages appended since you scrolled back"
		// is a count about a list that no longer exists. Liveness itself is
		// re-derived by the next SetMessagesLen against the filtered
		// length; only the stale count has to be dropped here.
		m.PendingMessages = 0
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
