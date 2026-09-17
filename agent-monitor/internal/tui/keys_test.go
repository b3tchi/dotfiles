package tui

import (
	"math/rand"
	"testing"

	"agent-monitor/internal/source"
)

func TestToggleFocus_TabSwitchesBetweenPanes(t *testing.T) {
	m := NewModel()
	if m.Focus != PaneRoster {
		t.Fatalf("expected default focus PaneRoster, got %v", m.Focus)
	}
	m.HandleKey(Key{Special: KeyTab})
	if m.Focus != PaneMessages {
		t.Fatalf("expected focus PaneMessages after tab, got %v", m.Focus)
	}
	m.HandleKey(Key{Special: KeyTab})
	if m.Focus != PaneRoster {
		t.Fatalf("expected focus back to PaneRoster after second tab, got %v", m.Focus)
	}
}

func TestScroll_ClampsAtBothEnds(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(3) // valid scroll range is [0, 2]
	for i := 0; i < 10; i++ {
		m.HandleKey(Key{Rune: 'j'})
	}
	if m.RosterScroll != 2 {
		t.Fatalf("expected scroll clamped at len-1=2, got %d", m.RosterScroll)
	}
	for i := 0; i < 10; i++ {
		m.HandleKey(Key{Rune: 'k'})
	}
	if m.RosterScroll != 0 {
		t.Fatalf("expected scroll clamped at 0, got %d", m.RosterScroll)
	}
}

func TestScroll_ZeroLengthNeverScrolls(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(0)
	m.HandleKey(Key{Rune: 'j'})
	if m.RosterScroll != 0 {
		t.Fatalf("an empty pane must never scroll past 0, got %d", m.RosterScroll)
	}
}

func TestScroll_ArrowsMatchJK(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(5)
	m.HandleKey(Key{Special: KeyDown})
	if m.RosterScroll != 1 {
		t.Fatalf("down arrow expected scroll 1, got %d", m.RosterScroll)
	}
	m.HandleKey(Key{Special: KeyUp})
	if m.RosterScroll != 0 {
		t.Fatalf("up arrow expected scroll 0, got %d", m.RosterScroll)
	}
}

func TestScroll_FocusedPaneOnly(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(5)
	m.SetMessagesLen(5)
	m.HandleKey(Key{Rune: 'j'}) // roster focused by default
	m.HandleKey(Key{Special: KeyTab})
	m.HandleKey(Key{Rune: 'j'})
	m.HandleKey(Key{Rune: 'j'})
	if m.RosterScroll != 1 {
		t.Fatalf("roster scroll must be untouched by messages-focused scrolling, got %d", m.RosterScroll)
	}
	if m.MessagesScroll != 2 {
		t.Fatalf("expected messages scroll 2, got %d", m.MessagesScroll)
	}
}

func TestSetLen_ShrinkingClampsAnAlreadyDeepScroll(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(10)
	for i := 0; i < 9; i++ {
		m.HandleKey(Key{Rune: 'j'})
	}
	if m.RosterScroll != 9 {
		t.Fatalf("setup: expected scroll 9, got %d", m.RosterScroll)
	}
	m.SetRosterLen(3) // a filter just shrank the row count
	if m.RosterScroll != 2 {
		t.Fatalf("expected scroll clamped to the new len-1=2, got %d", m.RosterScroll)
	}
}

func TestQuit_QAndCtrlC(t *testing.T) {
	for _, k := range []Key{{Rune: 'q'}, {Rune: 'Q'}, {Rune: 0x03}} {
		m := NewModel()
		out := m.HandleKey(k)
		if !out.Quit {
			t.Fatalf("expected Quit for key %+v", k)
		}
	}
}

func TestForceRefresh_R(t *testing.T) {
	for _, k := range []Key{{Rune: 'r'}, {Rune: 'R'}} {
		m := NewModel()
		out := m.HandleKey(k)
		if !out.ForceRefresh {
			t.Fatalf("expected ForceRefresh for key %+v", k)
		}
	}
}

// TestDetailVisible_DefaultsTrue pins sp031 T5's "present by default"
// success criterion.
func TestDetailVisible_DefaultsTrue(t *testing.T) {
	m := NewModel()
	if !m.DetailVisible {
		t.Fatalf("expected DetailVisible to default true")
	}
}

// TestDetailVisible_ToggleKeyFlipsIt asserts `d` (lower and upper case) is
// the toggle sp031 T5 requires, and that it never falls through to any
// other key's behaviour (quit, refresh, movement).
func TestDetailVisible_ToggleKeyFlipsIt(t *testing.T) {
	for _, k := range []Key{{Rune: 'd'}, {Rune: 'D'}} {
		m := NewModel()
		out := m.HandleKey(k)
		if out.Quit || out.ForceRefresh {
			t.Fatalf("key %+v must only toggle the detail pane, got Outcome %+v", k, out)
		}
		if m.DetailVisible {
			t.Fatalf("key %+v: expected DetailVisible false after first toggle", k)
		}
		m.HandleKey(k)
		if !m.DetailVisible {
			t.Fatalf("key %+v: expected DetailVisible true after second toggle", k)
		}
	}
}

// TestDetailVisible_ToggleDoesNotAffectSelection is the edge case: toggling
// the pane off while the cursor is in the message pane, then back on, must
// still select the same message — DetailVisible and MessagesCursor are
// independent fields, so this should hold trivially, but it is the
// behaviour a reviewer needs pinned rather than assumed.
func TestDetailVisible_ToggleDoesNotAffectSelection(t *testing.T) {
	m := NewModel()
	m.Focus = PaneMessages
	m.SetMessagesLen(5)
	m.HandleKey(Key{Rune: 'j'})
	m.HandleKey(Key{Rune: 'j'})
	if m.MessagesCursor != 2 {
		t.Fatalf("setup: expected cursor at 2, got %d", m.MessagesCursor)
	}

	m.HandleKey(Key{Rune: 'd'}) // off
	m.HandleKey(Key{Rune: 'd'}) // on

	if m.MessagesCursor != 2 {
		t.Fatalf("toggling detail pane must not move selection: got cursor %d, want 2", m.MessagesCursor)
	}
}

// TestFilter_EmptyCommittedFilterDiffersFromNoFilter pins the subtle
// success criterion: typing `/` then confirming with nothing typed must
// still flip Filter.Set, distinct from a Model that never entered filter
// mode at all — even though both render every row (an empty string is a
// substring of everything).
func TestFilter_EmptyCommittedFilterDiffersFromNoFilter(t *testing.T) {
	m := NewModel()
	if m.Filter.Set {
		t.Fatalf("a fresh model must start with no filter set")
	}

	m.HandleKey(Key{Rune: '/'})
	m.HandleKey(Key{Special: KeyEnter})

	if !m.Filter.Set {
		t.Fatalf("committing an empty filter must still be Set=true — distinct from never having filtered")
	}
	if m.Filter.Query != "" {
		t.Fatalf("expected empty query, got %q", m.Filter.Query)
	}

	rows := []source.Row{{Name: "peer-1"}, {Name: "peer-2"}}
	if got := len(m.FilterRoster(rows)); got != 2 {
		t.Fatalf("an empty committed filter should still show every row, got %d", got)
	}
}

func TestFilter_TypingBuildsQueryAndBackspaceEdits(t *testing.T) {
	m := NewModel()
	m.HandleKey(Key{Rune: '/'})
	for _, r := range "peer-2x" {
		m.HandleKey(Key{Rune: r})
	}
	m.HandleKey(Key{Special: KeyBackspace}) // drop the trailing 'x'
	m.HandleKey(Key{Special: KeyEnter})
	if m.Filter.Query != "peer-2" {
		t.Fatalf("expected committed query %q, got %q", "peer-2", m.Filter.Query)
	}
}

// TestFilter_QWhileEditingIsTextNotQuit guards the ordering in HandleKey:
// editing must be checked BEFORE the quit/refresh/tab/scroll switch, or
// typing a filter containing 'q', 'r', 'j' or 'k' would trigger those
// actions instead of being captured as text.
func TestFilter_QWhileEditingIsTextNotQuit(t *testing.T) {
	m := NewModel()
	m.HandleKey(Key{Rune: '/'})
	out := m.HandleKey(Key{Rune: 'q'})
	if out.Quit {
		t.Fatalf("'q' while editing a filter must not quit")
	}
	m.HandleKey(Key{Special: KeyEnter})
	if m.Filter.Query != "q" {
		t.Fatalf("expected 'q' captured into the filter text, got %q", m.Filter.Query)
	}
}

// TestFilter_DWhileEditingIsTextNotDetailToggle is
// TestFilter_QWhileEditingIsTextNotQuit's twin for the detail-pane toggle
// added by sp031 T5: 'd' joined the same switch that 'q'/'r'/'j'/'k' live
// in, so typing a filter containing 'd' must stay text and must not flip
// DetailVisible behind the user's back.
func TestFilter_DWhileEditingIsTextNotDetailToggle(t *testing.T) {
	m := NewModel()
	before := m.DetailVisible
	m.HandleKey(Key{Rune: '/'})
	m.HandleKey(Key{Rune: 'd'})
	if m.DetailVisible != before {
		t.Fatalf("'d' while editing a filter must not toggle the detail pane (was %v, now %v)", before, m.DetailVisible)
	}
	m.HandleKey(Key{Special: KeyEnter})
	if m.Filter.Query != "d" {
		t.Fatalf("expected 'd' captured into the filter text, got %q", m.Filter.Query)
	}
	if m.DetailVisible != before {
		t.Fatalf("committing the filter must not toggle the detail pane either (was %v, now %v)", before, m.DetailVisible)
	}
}

func TestFilterRoster_MatchesNameCaseInsensitive(t *testing.T) {
	m := NewModel()
	m.HandleKey(Key{Rune: '/'})
	for _, r := range "PEER" {
		m.HandleKey(Key{Rune: r})
	}
	m.HandleKey(Key{Special: KeyEnter})

	rows := []source.Row{{Name: "peer-2"}, {Name: "rev-1"}}
	got := m.FilterRoster(rows)
	if len(got) != 1 || got[0].Name != "peer-2" {
		t.Fatalf("expected only peer-2 to survive the filter, got %+v", got)
	}
}

func TestFilterMessages_MatchesFromField(t *testing.T) {
	m := NewModel()
	m.HandleKey(Key{Rune: '/'})
	for _, r := range "peer-3" {
		m.HandleKey(Key{Rune: r})
	}
	m.HandleKey(Key{Special: KeyEnter})

	msgs := []source.Message{{From: "peer-2"}, {From: "peer-3"}}
	got := m.FilterMessages(msgs)
	if len(got) != 1 || got[0].From != "peer-3" {
		t.Fatalf("expected only peer-3's message to survive, got %+v", got)
	}
}

func TestFilterRoster_UnsetFilterReturnsRowsUnchanged(t *testing.T) {
	m := NewModel()
	rows := []source.Row{{Name: "peer-1"}, {Name: "peer-2"}}
	got := m.FilterRoster(rows)
	if len(got) != 2 {
		t.Fatalf("expected an unset filter to pass every row through, got %d", len(got))
	}
}

// --- sp031 T3: --project stops being scaffold ---
//
// Model.Project is the --project flag's value, set once at startup (main.go
// wires *project into it before the first frame) and never touched by a
// keystroke — unlike Filter, it has no Editing state and no commit step.
// FilterRoster applies it as an EXACT match, case-insensitive: project names
// are slugs/identifiers (ft012/adr0024's tmux-pane attribution, or
// parse-pi-window's session-group read), not free text, so a substring match
// would let "dotfiles" silently swallow a hypothetical "dotfiles-extra"
// project too. Case-insensitivity is deliberate the other way: nothing in
// adr0024 or parse-pi-window guarantees a canonical case for the slug, and
// the interactive `/` filter already lower-cases its own match for the same
// reason (see FilterRoster's DisplayName comparison above).

func TestFilterRoster_ProjectRestrictsRosterToMatchingRows(t *testing.T) {
	m := NewModel()
	m.Project = "dotfiles"
	rows := []source.Row{
		{Project: "dotfiles", Name: "peer-1"},
		{Project: "copacks", Name: "peer-2"},
		{Project: "dotfiles", Name: "peer-3"},
	}
	got := m.FilterRoster(rows)
	if len(got) != 2 {
		t.Fatalf("expected 2 dotfiles rows to survive, got %d: %+v", len(got), got)
	}
	for _, r := range got {
		if r.Project != "dotfiles" {
			t.Fatalf("row %+v does not belong to project dotfiles", r)
		}
	}
	// and the count must differ from the unfiltered render (test_plan bullet 1).
	m.Project = ""
	unfiltered := m.FilterRoster(rows)
	if len(unfiltered) == len(got) {
		t.Fatalf("expected --project to actually shrink the roster: filtered=%d unfiltered=%d", len(got), len(unfiltered))
	}
}

func TestFilterRoster_ProjectIsCaseInsensitiveExactMatch(t *testing.T) {
	m := NewModel()
	m.Project = "DotFiles"
	rows := []source.Row{
		{Project: "dotfiles", Name: "peer-1"},
		{Project: "dotfiles-extra", Name: "peer-2"}, // must NOT match: exact, not substring
	}
	got := m.FilterRoster(rows)
	if len(got) != 1 || got[0].Name != "peer-1" {
		t.Fatalf("expected only the exact-match row to survive, got %+v", got)
	}
}

func TestFilterRoster_ProjectComposesWithInteractiveFilter(t *testing.T) {
	m := NewModel()
	m.Project = "dotfiles"
	m.HandleKey(Key{Rune: '/'})
	for _, r := range "peer-1" {
		m.HandleKey(Key{Rune: r})
	}
	m.HandleKey(Key{Special: KeyEnter})

	rows := []source.Row{
		{Project: "dotfiles", Name: "peer-1"},
		{Project: "dotfiles", Name: "peer-2"}, // right project, wrong name: filter excludes it
		{Project: "copacks", Name: "peer-1"},  // right name, wrong project: --project excludes it
	}
	got := m.FilterRoster(rows)
	if len(got) != 1 || got[0].Name != "peer-1" || got[0].Project != "dotfiles" {
		t.Fatalf("expected both --project and the / filter applied (intersection), got %+v", got)
	}
}

func TestFilterRoster_ProjectUnmatchedYieldsEmptyRoster(t *testing.T) {
	m := NewModel()
	m.Project = "nope"
	rows := []source.Row{{Project: "dotfiles", Name: "peer-1"}}
	got := m.FilterRoster(rows)
	if len(got) != 0 {
		t.Fatalf("expected an empty roster for an unmatched project, got %+v", got)
	}
}

func TestFilterRoster_EmptyProjectStringIsUnsetNotEmptyMatch(t *testing.T) {
	m := NewModel()
	m.Project = "" // explicit empty (--project ""), same zero value as never setting it
	rows := []source.Row{
		{Project: "dotfiles", Name: "peer-1"},
		{Project: "", Name: "peer-2"}, // a row with genuinely no project attribution
	}
	got := m.FilterRoster(rows)
	if len(got) != 2 {
		t.Fatalf("expected --project \"\" to be treated as unset (all rows pass), got %d: %+v", len(got), got)
	}
}

func TestFilterMessages_UnaffectedByProject(t *testing.T) {
	m := NewModel()
	m.Project = "dotfiles"
	msgs := []source.Message{{From: "peer-1"}, {From: "peer-2"}}
	got := m.FilterMessages(msgs)
	if len(got) != 2 {
		t.Fatalf("--project must not filter the message pane (bus is already repo-scoped), got %d", len(got))
	}
}

// --- sp031 T1: cursor in the model, viewport follows ---
//
// These tests pin the refactor where j/k and the arrows move a per-pane
// CURSOR (a selected row index) instead of moving RosterScroll/
// MessagesScroll directly. The scroll fields still exist and are still
// asserted by the tests above — but they are now DERIVED from the cursor
// plus a viewport height the caller reports via SetRosterViewport /
// SetMessagesViewport. When no viewport has been reported (the zero value),
// the derived scroll must equal the cursor exactly, which is what keeps
// every test above passing unmodified: none of them call the new setters.

func TestCursor_JKMovesCursorWithinBounds(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(5)
	if m.RosterCursor != 0 {
		t.Fatalf("expected initial cursor 0, got %d", m.RosterCursor)
	}
	m.HandleKey(Key{Rune: 'j'})
	m.HandleKey(Key{Rune: 'j'})
	if m.RosterCursor != 2 {
		t.Fatalf("expected cursor 2 after two 'j', got %d", m.RosterCursor)
	}
	m.HandleKey(Key{Rune: 'k'})
	if m.RosterCursor != 1 {
		t.Fatalf("expected cursor 1 after 'k', got %d", m.RosterCursor)
	}
}

// TestCursor_BoundaryNoOpsAtBothEnds pins the edge case: k at the top and j
// at the bottom must be no-ops, never wrap and never go out of range.
func TestCursor_BoundaryNoOpsAtBothEnds(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(3)
	m.HandleKey(Key{Rune: 'k'}) // already at top
	if m.RosterCursor != 0 {
		t.Fatalf("k at top must be a no-op, got cursor %d", m.RosterCursor)
	}
	for i := 0; i < 10; i++ {
		m.HandleKey(Key{Rune: 'j'})
	}
	if m.RosterCursor != 2 {
		t.Fatalf("expected cursor clamped at len-1=2, got %d", m.RosterCursor)
	}
	m.HandleKey(Key{Rune: 'j'}) // already at bottom
	if m.RosterCursor != 2 {
		t.Fatalf("j at bottom must be a no-op, got cursor %d", m.RosterCursor)
	}
}

// TestCursor_ScrollDerivedFromViewport is the core behavioural change: with
// a viewport reported, the scroll offset must keep the cursor inside
// [scroll, scroll+viewport-1] rather than tracking the cursor 1:1.
func TestCursor_ScrollDerivedFromViewport(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(10)
	m.SetRosterViewport(3) // only 3 rows visible at a time

	if m.RosterScroll != 0 {
		t.Fatalf("expected scroll 0 at cursor 0, got %d", m.RosterScroll)
	}

	// Move cursor to 2 — still inside the first window [0,2] — scroll must
	// not have moved yet.
	m.HandleKey(Key{Rune: 'j'})
	m.HandleKey(Key{Rune: 'j'})
	if m.RosterCursor != 2 || m.RosterScroll != 0 {
		t.Fatalf("expected cursor 2 scroll 0, got cursor %d scroll %d", m.RosterCursor, m.RosterScroll)
	}

	// One more step pushes the cursor to 3, outside [0,2] — scroll must
	// follow so the cursor is the new bottom of the window.
	m.HandleKey(Key{Rune: 'j'})
	if m.RosterCursor != 3 {
		t.Fatalf("expected cursor 3, got %d", m.RosterCursor)
	}
	if m.RosterScroll != 1 {
		t.Fatalf("expected scroll to follow to 1 (window [1,3]), got %d", m.RosterScroll)
	}

	// Walk to the end: cursor 9, scroll must land at maxScroll = len-viewport = 7.
	for i := 0; i < 10; i++ {
		m.HandleKey(Key{Rune: 'j'})
	}
	if m.RosterCursor != 9 {
		t.Fatalf("expected cursor clamped at 9, got %d", m.RosterCursor)
	}
	if m.RosterScroll != 7 {
		t.Fatalf("expected scroll clamped at len-viewport=7, got %d", m.RosterScroll)
	}
}

// TestCursor_ShortListNeverScrollsButCursorMovesFreely pins the edge case:
// when the list fits entirely within the viewport, scroll stays 0 while the
// cursor still moves across every row.
func TestCursor_ShortListNeverScrollsButCursorMovesFreely(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(2)
	m.SetRosterViewport(10)
	m.HandleKey(Key{Rune: 'j'})
	if m.RosterCursor != 1 {
		t.Fatalf("expected cursor 1, got %d", m.RosterCursor)
	}
	if m.RosterScroll != 0 {
		t.Fatalf("a list shorter than the viewport must never scroll, got %d", m.RosterScroll)
	}
}

// TestCursor_ZeroViewportNeverPanicsAndTracksCursor pins the edge case: a
// viewport of exactly 0 (unset, or a pathologically collapsed pane) must not
// divide by zero, and the scroll degrades to tracking the cursor directly —
// the same behaviour every pre-existing scroll test above relies on.
func TestCursor_ZeroViewportNeverPanicsAndTracksCursor(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(5)
	m.SetRosterViewport(0)
	m.HandleKey(Key{Rune: 'j'})
	m.HandleKey(Key{Rune: 'j'})
	if m.RosterCursor != 2 || m.RosterScroll != 2 {
		t.Fatalf("expected cursor 2 scroll 2 with zero viewport, got cursor %d scroll %d", m.RosterCursor, m.RosterScroll)
	}
}

// TestCursor_OneRowViewportNeverPanics pins the other half of the "zero or
// one row" edge case.
func TestCursor_OneRowViewportNeverPanics(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(5)
	m.SetRosterViewport(1)
	for i := 0; i < 4; i++ {
		m.HandleKey(Key{Rune: 'j'})
	}
	if m.RosterCursor != 4 {
		t.Fatalf("expected cursor 4, got %d", m.RosterCursor)
	}
	if m.RosterScroll != 4 {
		t.Fatalf("expected a 1-row viewport to keep scroll pinned to the cursor, got %d", m.RosterScroll)
	}
}

// TestCursor_EmptyListNeverPanics pins the edge case: an empty list is a
// valid no-op, never a negative index and never a panic.
func TestCursor_EmptyListNeverPanics(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(0)
	m.SetRosterViewport(5)
	m.HandleKey(Key{Rune: 'j'})
	m.HandleKey(Key{Rune: 'k'})
	if m.RosterCursor != 0 {
		t.Fatalf("expected cursor 0 on an empty list, got %d", m.RosterCursor)
	}
	if m.RosterScroll != 0 {
		t.Fatalf("expected scroll 0 on an empty list, got %d", m.RosterScroll)
	}
}

// TestCursor_ClampedInSamePassAsSetLen pins the success criterion that a
// filter shrinking the list clamps the cursor (and its derived scroll)
// immediately inside SetRosterLen — BEFORE any further keystroke, not
// lazily on the next one.
func TestCursor_ClampedInSamePassAsSetLen(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(10)
	m.SetRosterViewport(3)
	for i := 0; i < 8; i++ {
		m.HandleKey(Key{Rune: 'j'})
	}
	if m.RosterCursor != 8 {
		t.Fatalf("setup: expected cursor 8, got %d", m.RosterCursor)
	}

	m.SetRosterLen(3) // a filter just shrank the row count to 3 (valid indices 0-2)

	if m.RosterCursor != 2 {
		t.Fatalf("expected cursor clamped to new len-1=2 immediately, got %d", m.RosterCursor)
	}
	if m.RosterScroll != 0 {
		t.Fatalf("expected scroll clamped to 0 (list now fits in viewport), got %d", m.RosterScroll)
	}
}

// TestCursor_ViewportResizeBringsCursorBackIntoView pins the success
// criterion that a shrinking viewport (a resized terminal) recomputes
// scroll so the cursor is never left off-screen.
func TestCursor_ViewportResizeBringsCursorBackIntoView(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(20)
	m.SetRosterViewport(10)
	for i := 0; i < 9; i++ {
		m.HandleKey(Key{Rune: 'j'})
	}
	if m.RosterCursor != 9 {
		t.Fatalf("setup: expected cursor 9, got %d", m.RosterCursor)
	}
	if m.RosterScroll != 0 {
		t.Fatalf("setup: expected scroll 0 (cursor 9 still inside window [0,9]), got %d", m.RosterScroll)
	}

	m.SetRosterViewport(3) // terminal shrank

	if m.RosterCursor != 9 {
		t.Fatalf("resize must not move the cursor, got %d", m.RosterCursor)
	}
	if m.RosterScroll != 7 {
		t.Fatalf("expected scroll recomputed to 7 (window [7,9]) so cursor 9 is visible, got %d", m.RosterScroll)
	}
}

// TestCursor_MessagesPaneIndependentOfRoster is the cursor/viewport twin of
// TestScroll_FocusedPaneOnly: each pane's cursor, scroll and viewport are
// independent state.
func TestCursor_MessagesPaneIndependentOfRoster(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(5)
	m.SetMessagesLen(5)
	m.SetRosterViewport(2)
	m.SetMessagesViewport(2)

	m.HandleKey(Key{Rune: 'j'}) // roster focused by default
	m.HandleKey(Key{Special: KeyTab})
	m.HandleKey(Key{Rune: 'j'})
	m.HandleKey(Key{Rune: 'j'})

	if m.RosterCursor != 1 {
		t.Fatalf("roster cursor must be untouched by messages-focused movement, got %d", m.RosterCursor)
	}
	if m.MessagesCursor != 2 {
		t.Fatalf("expected messages cursor 2, got %d", m.MessagesCursor)
	}
	if m.MessagesScroll != 1 {
		t.Fatalf("expected messages scroll 1 (window [1,2]), got %d", m.MessagesScroll)
	}
}

// sp032 T2 deleted six cases here along with the symbols they covered:
// TestDecoder_ArrowsAndControls and
// TestDecoder_BareEscThenRuneDropsEscAndDecodesTheRune tested the
// byte-stream escape decoder bubbletea replaced, and the four restore-guard
// cases tested the restore-exactly-once wrapper whose cross-goroutine hazard
// stopped existing when rendering left the sampler goroutines. The behavior
// they pinned is now asserted where it lives: key translation in
// cmd/agent-monitor's TestUpdate_KeyMsgMapping_MatchesHandleKey, and the
// panic/signal restore in TestShell_PanicAndSignalRestoreLeftToBubbletea.

// TestScroll_WheelScrollSurvivesASampleTick is the behaviour change itself:
// a scroll set independently of the cursor must survive an arbitrary number
// of SetLen calls at an unchanged length. Against sp031's derive-on-SetLen
// model this fails on the first tick — the cursor at 0 dragged scroll back
// to 0.
func TestScroll_WheelScrollSurvivesASampleTick(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(20)
	m.SetMessagesViewport(5)

	m.ScrollMessages(3)
	if m.MessagesScroll != 3 {
		t.Fatalf("expected scroll 3 after ScrollMessages(3), got %d", m.MessagesScroll)
	}
	if m.MessagesCursor != 0 {
		t.Fatalf("ScrollMessages must not move the cursor, got %d", m.MessagesCursor)
	}

	for i := 0; i < 5; i++ {
		m.SetMessagesLen(20) // five sampler ticks, same row count
		if m.MessagesScroll != 3 {
			t.Fatalf("tick %d: expected scroll to survive at 3, got %d", i+1, m.MessagesScroll)
		}
	}
	if m.MessagesCursor != 0 {
		t.Fatalf("a sample tick must not move the cursor either, got %d", m.MessagesCursor)
	}
}

// TestScroll_CursorOffScreenIsAllowed pins the state sp031's model forbade
// by construction: the operator scrolled away from their selection, and
// nothing drags either one back.
func TestScroll_CursorOffScreenIsAllowed(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(20)
	m.SetRosterViewport(4)

	m.ScrollRoster(10)
	if m.RosterScroll != 10 || m.RosterCursor != 0 {
		t.Fatalf("expected scroll 10 cursor 0, got scroll %d cursor %d", m.RosterScroll, m.RosterCursor)
	}
	// cursor 0 is above the window [10,13] — deliberately off-screen.
	if m.RosterCursor >= m.RosterScroll {
		t.Fatalf("setup: cursor %d was expected above the window top %d", m.RosterCursor, m.RosterScroll)
	}

	m.SetRosterLen(20)     // a sample tick
	m.SetRosterViewport(4) // and the frame re-reporting the same viewport
	if m.RosterScroll != 10 || m.RosterCursor != 0 {
		t.Fatalf("an off-screen cursor must stay off-screen, got scroll %d cursor %d", m.RosterScroll, m.RosterCursor)
	}
}

// TestCursor_MoveOnlyScrollsWhenItMustEnsureVisibility asserts the exact
// shape of criterion 3: a cursor that is already inside [scroll,
// scroll+viewport-1] leaves scroll BYTE-IDENTICAL, and one that leaves the
// window moves scroll by the minimum needed — never re-centres, never jumps
// to the cursor when a one-row nudge suffices.
func TestCursor_MoveOnlyScrollsWhenItMustEnsureVisibility(t *testing.T) {
	const length, viewport = 20, 5 // window is [scroll, scroll+4]
	cases := []struct {
		name                   string
		cursor, scroll, delta  int
		wantCursor, wantScroll int
	}{
		{"down inside the window", 5, 5, 1, 6, 5},
		{"up inside the window", 7, 5, -1, 6, 5},
		{"two rows down, still inside", 7, 5, 2, 9, 5},
		{"at the top, up leaves the window", 5, 5, -1, 4, 4},
		{"at the bottom, down leaves the window", 9, 5, 1, 10, 6},
		{"cursor above a wheel-scrolled window", 0, 10, 1, 1, 1},
		{"cursor below a wheel-scrolled window", 19, 10, -1, 18, 14},
		{"cursor below, but the move lands it inside", 15, 12, -1, 14, 12},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := NewModel()
			m.SetRosterLen(length)
			m.SetRosterViewport(viewport)
			m.RosterCursor = c.cursor
			m.RosterScroll = c.scroll

			m.moveCursor(c.delta)

			if m.RosterCursor != c.wantCursor {
				t.Fatalf("cursor: want %d, got %d", c.wantCursor, m.RosterCursor)
			}
			if m.RosterScroll != c.wantScroll {
				t.Fatalf("scroll: want %d, got %d", c.wantScroll, m.RosterScroll)
			}
		})
	}
}

// TestScroll_ClampsWhenFilterShrinksTheList pins the slice-index hazard the
// spec names explicitly: a committed filter shrinks the list under a deeply
// scrolled view, and cmd/'s scrolledMessageSample then does msgs[scroll:].
// The clamp has to land in the same pass as the length change, so the slice
// below cannot panic.
func TestScroll_ClampsWhenFilterShrinksTheList(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(50)
	m.SetMessagesViewport(5)
	m.ScrollMessages(40)
	if m.MessagesScroll != 40 {
		t.Fatalf("setup: expected scroll 40, got %d", m.MessagesScroll)
	}

	m.SetMessagesLen(6) // the filter committed

	if m.MessagesScroll != 1 {
		t.Fatalf("expected scroll clamped to len-viewport=1, got %d", m.MessagesScroll)
	}
	if m.MessagesCursor != 0 {
		t.Fatalf("expected cursor still 0, got %d", m.MessagesCursor)
	}

	// The use site: the same slice cmd/agent-monitor's scrolledMessageSample
	// takes. A scroll left at 40 here is a panic, not a cosmetic bug.
	msgs := make([]source.Message, 6)
	view := msgs[m.MessagesScroll:]
	if len(view) != 5 {
		t.Fatalf("expected 5 rows in view after the clamp, got %d", len(view))
	}
}

// TestScroll_ViewportZeroKeepsLegacyOneToOneTracking pins the compatibility
// contract for every caller that sets *Len and never *Viewport — --once,
// and every pre-existing test above this block.
func TestScroll_ViewportZeroKeepsLegacyOneToOneTracking(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(5)
	m.HandleKey(Key{Rune: 'j'})
	m.HandleKey(Key{Rune: 'j'})
	if m.RosterCursor != 2 || m.RosterScroll != 2 {
		t.Fatalf("expected cursor 2 scroll 2, got cursor %d scroll %d", m.RosterCursor, m.RosterScroll)
	}
	m.SetRosterLen(5) // a tick must not disturb the 1:1 tracking
	if m.RosterScroll != 2 {
		t.Fatalf("expected scroll to stay pinned to the cursor at 2, got %d", m.RosterScroll)
	}
	m.SetRosterLen(2) // and a shrink re-pins it to the clamped cursor
	if m.RosterCursor != 1 || m.RosterScroll != 1 {
		t.Fatalf("expected cursor 1 scroll 1 after the shrink, got cursor %d scroll %d", m.RosterCursor, m.RosterScroll)
	}
}

// TestScroll_ViewportAtLeastAsLongAsTheListNeverScrolls pins the edge case
// that a wheel cannot scroll a pane whose content already fits.
func TestScroll_ViewportAtLeastAsLongAsTheListNeverScrolls(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(4)
	m.SetRosterViewport(10)
	m.ScrollRoster(7)
	if m.RosterScroll != 0 {
		t.Fatalf("a list that fits must never scroll, got %d", m.RosterScroll)
	}
	m.SetRosterViewport(4) // exactly as tall as the list
	m.ScrollRoster(3)
	if m.RosterScroll != 0 {
		t.Fatalf("viewport == len must never scroll, got %d", m.RosterScroll)
	}
}

// TestScroll_EmptyListNeverScrollsNegative pins the empty-list edge case for
// the scroll entry points (the cursor's own empty-list case is
// TestCursor_EmptyListNeverPanics).
func TestScroll_EmptyListNeverScrollsNegative(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(0)
	m.SetMessagesViewport(5)
	m.ScrollMessages(-3)
	m.ScrollMessages(9)
	if m.MessagesScroll != 0 {
		t.Fatalf("an empty pane must stay pinned at scroll 0, got %d", m.MessagesScroll)
	}
}

// TestScroll_ViewportChangeClampsToTheLastFullPage pins criterion 4: a
// viewport change can only ever leave scroll inside [0, len-viewport].
func TestScroll_ViewportChangeClampsToTheLastFullPage(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(20)
	m.SetRosterViewport(5)
	m.ScrollRoster(15)
	if m.RosterScroll != 15 {
		t.Fatalf("setup: expected scroll at the last page, got %d", m.RosterScroll)
	}

	m.SetRosterViewport(8) // the pane got taller: the last page starts earlier
	if m.RosterScroll != 12 {
		t.Fatalf("expected scroll clamped to len-viewport=12, got %d", m.RosterScroll)
	}

	m.SetRosterViewport(25) // taller than the whole list
	if m.RosterScroll != 0 {
		t.Fatalf("expected scroll 0 once the list fits, got %d", m.RosterScroll)
	}
}

// TestScroll_NeverExceedsMaxForViewport throws randomised deltas at both
// panes and asserts the invariant after every single one: scroll is always
// inside [0, max(0, len-viewport)], whatever the sequence.
func TestScroll_NeverExceedsMaxForViewport(t *testing.T) {
	rng := rand.New(rand.NewSource(20260917))
	for trial := 0; trial < 200; trial++ {
		length := rng.Intn(40)
		viewport := rng.Intn(12)
		m := NewModel()
		m.SetMessagesLen(length)
		m.SetMessagesViewport(viewport)

		for step := 0; step < 20; step++ {
			switch rng.Intn(4) {
			case 0:
				m.ScrollMessages(rng.Intn(21) - 10)
			case 1:
				m.SetMessagesLen(rng.Intn(40))
			case 2:
				m.SetMessagesViewport(rng.Intn(12))
			default:
				m.Focus = PaneMessages
				m.HandleKey(Key{Rune: []rune{'j', 'k'}[rng.Intn(2)]})
			}

			max := m.MessagesLen - m.MessagesViewport
			if max < 0 {
				max = 0
			}
			if m.MessagesScroll < 0 || m.MessagesScroll > max {
				t.Fatalf("trial %d step %d: scroll %d outside [0,%d] (len %d viewport %d)",
					trial, step, m.MessagesScroll, max, m.MessagesLen, m.MessagesViewport)
			}
			if m.MessagesLen > 0 && m.MessagesCursor >= m.MessagesLen {
				t.Fatalf("trial %d step %d: cursor %d past len %d", trial, step, m.MessagesCursor, m.MessagesLen)
			}
		}
	}
}
