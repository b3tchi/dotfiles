package tui

import (
	"math/rand"
	"testing"

	"agent-monitor/internal/source"
)

// TestToggleFocus_DefaultFocusAndFirstTab keeps the two clauses of sp031's
// TestToggleFocus_TabSwitchesBetweenPanes that sp032 T4 does NOT change: the
// model starts on the roster, and the first tab reaches the message pane.
// Its third clause — "a second tab returns to the roster" — asserted the
// two-stop cycle criterion 1 deliberately replaces, and now lives, extended,
// in TestTab_CyclesThreePanes.
func TestToggleFocus_DefaultFocusAndFirstTab(t *testing.T) {
	m := NewModel()
	if m.Focus != PaneRoster {
		t.Fatalf("expected default focus PaneRoster, got %v", m.Focus)
	}
	m.HandleKey(Key{Special: KeyTab})
	if m.Focus != PaneMessages {
		t.Fatalf("expected focus PaneMessages after tab, got %v", m.Focus)
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

// ---------------------------------------------------------------------------
// sp032 T3's mouse entry points, at the tui level.
//
// These are deliberately package-`tui` tests rather than more package-`main`
// ones, because the two levels catch different mutations. main's tests own
// the DISPATCH (which screen row is which pane, which button reaches which
// entry point, with which delta) — nothing here can see a swapped
// hitRoster/hitMessages arm or a wheel notch of 1 instead of 3. These own the
// CONTRACT of the entry points themselves (cursor = scroll + offset, clamped;
// focus moves on every press; scroll moves without a cursor or focus) — and
// they pin it against any caller, so the contract survives T4/T5/T6 growing
// new callers that main's mouse tests never exercise.
// ---------------------------------------------------------------------------

// TestClickPane_DataRowSelectsScrollPlusOffset pins the arithmetic: the
// offset a hit test reports is relative to what is ON SCREEN, so the row
// selected is the pane's current scroll plus that offset — never the offset
// alone (which would select the wrong row in any scrolled pane) and never
// scroll+offset+1 (an off-by-one against the first visible row).
func TestClickPane_DataRowSelectsScrollPlusOffset(t *testing.T) {
	cases := []struct {
		name   string
		pane   Pane
		scroll int
		offset int
		want   int
	}{
		{"roster unscrolled, first visible row", PaneRoster, 0, 0, 0},
		{"roster unscrolled, fourth visible row", PaneRoster, 0, 3, 3},
		{"roster scrolled, first visible row", PaneRoster, 7, 0, 7},
		{"roster scrolled, fourth visible row", PaneRoster, 7, 3, 10},
		{"messages unscrolled, first visible row", PaneMessages, 0, 0, 0},
		{"messages scrolled, second visible row", PaneMessages, 12, 1, 13},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := NewModel()
			m.SetRosterViewport(5)
			m.SetMessagesViewport(5)
			m.SetRosterLen(40)
			m.SetMessagesLen(40)
			m.ScrollRoster(tc.scroll)
			m.ScrollMessages(tc.scroll)

			m.ClickPane(tc.pane, true, tc.offset)

			got := m.RosterCursor
			if tc.pane == PaneMessages {
				got = m.MessagesCursor
			}
			if got != tc.want {
				t.Errorf("cursor = %d, want %d (scroll %d + offset %d)", got, tc.want, tc.scroll, tc.offset)
			}
			if m.Focus != tc.pane {
				t.Errorf("Focus = %v, want %v — a press always focuses the pane it landed in", m.Focus, tc.pane)
			}
		})
	}
}

// TestClickPane_NonDataPressFocusesWithoutMovingTheCursor is the header /
// column-header / placeholder case: isData false means "this row is not a
// selection", so focus moves and nothing else does.
func TestClickPane_NonDataPressFocusesWithoutMovingTheCursor(t *testing.T) {
	m := NewModel()
	m.SetRosterViewport(5)
	m.SetMessagesViewport(5)
	m.SetRosterLen(40)
	m.SetMessagesLen(40)
	m.ScrollMessages(9)
	m.MessagesCursor = 4
	m.RosterCursor = 2
	m.Focus = PaneRoster

	before := *m
	m.ClickPane(PaneMessages, false, 3)

	want := before
	want.Focus = PaneMessages
	if *m != want {
		t.Errorf("a non-data press moved more than focus:\n got %+v\nwant %+v", *m, want)
	}
}

// TestClickPane_OffsetPastTheListClampsIntoRange is criterion 5 at this
// level: an offset that names a row beyond the list (a stale layout, a pane
// whose data shrank between the draw and the event) can never escape
// [0, len-1].
func TestClickPane_OffsetPastTheListClampsIntoRange(t *testing.T) {
	m := NewModel()
	m.SetRosterViewport(5)
	m.SetRosterLen(4)
	m.ClickPane(PaneRoster, true, 99)
	if m.RosterCursor != 3 {
		t.Errorf("RosterCursor = %d, want 3 (last row of a 4-row list)", m.RosterCursor)
	}

	empty := NewModel()
	empty.SetMessagesViewport(5)
	empty.SetMessagesLen(0)
	empty.ClickPane(PaneMessages, true, 2)
	if empty.MessagesCursor != 0 {
		t.Errorf("MessagesCursor = %d, want 0 for an empty list", empty.MessagesCursor)
	}
}

// TestScrollPane_MovesOnlyThatPanesScroll pins the wheel entry point's
// contract: it routes to the named pane's T1 scroll and touches nothing else
// — not the other pane, not either cursor, not focus.
func TestScrollPane_MovesOnlyThatPanesScroll(t *testing.T) {
	for _, tc := range []struct {
		name string
		pane Pane
	}{{"roster", PaneRoster}, {"messages", PaneMessages}} {
		t.Run(tc.name, func(t *testing.T) {
			m := NewModel()
			m.SetRosterViewport(5)
			m.SetMessagesViewport(5)
			m.SetRosterLen(40)
			m.SetMessagesLen(40)
			m.RosterCursor = 6
			m.MessagesCursor = 8
			m.Focus = PaneRoster

			before := *m
			want := before
			switch tc.pane {
			case PaneRoster:
				want.RosterScroll = before.RosterScroll + 4
			case PaneMessages:
				want.MessagesScroll = before.MessagesScroll + 4
			}

			m.ScrollPane(tc.pane, 4)

			if *m != want {
				t.Errorf("ScrollPane(%v, 4) changed more than that pane's scroll:\n got %+v\nwant %+v", tc.pane, *m, want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// sp032 T4: the detail pane becomes a peer.
// ---------------------------------------------------------------------------

// TestTab_CyclesThreePanes is criterion 1 at the model level (the dispatch
// half — that a real tea.KeyMsg reaches this — is
// TestUpdate_TabCyclesThreePanes in cmd/). It REPLACES the two-stop
// assertion TestToggleFocus_TabSwitchesBetweenPanes used to make: the detail
// pane is a focus stop now, so "tab twice returns to roster" is exactly the
// behaviour this task changes.
func TestTab_CyclesThreePanes(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(3)
	want := []Pane{PaneMessages, PaneDetail, PaneRoster, PaneMessages, PaneDetail, PaneRoster}
	for i, w := range want {
		m.HandleKey(Key{Special: KeyTab})
		if m.Focus != w {
			t.Fatalf("tab #%d: Focus = %v, want %v", i+1, m.Focus, w)
		}
	}
}

// TestTab_SkipsTheDetailPaneWhileItIsHidden is criterion 5's other half:
// `d` hides the pane, and a hidden pane is not a focus stop — tab must not
// park focus somewhere the operator cannot see.
func TestTab_SkipsTheDetailPaneWhileItIsHidden(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(3)
	m.DetailVisible = false
	for i, w := range []Pane{PaneMessages, PaneRoster, PaneMessages, PaneRoster} {
		m.HandleKey(Key{Special: KeyTab})
		if m.Focus != w {
			t.Fatalf("tab #%d with detail hidden: Focus = %v, want %v", i+1, m.Focus, w)
		}
	}
}

// TestDetail_HidingWhileFocusedMovesFocus is criterion 5: hiding the pane
// while it holds focus must move focus to messages, never leave focus on a
// pane that is not on screen. The `d`-while-zoomed edge case rides the same
// branch: unzoom AND hide, never a hidden-but-zoomed state.
func TestDetail_HidingWhileFocusedMovesFocus(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(3)
	m.Focus = PaneDetail
	m.DetailZoom = true

	m.HandleKey(Key{Rune: 'd'})
	if m.DetailVisible {
		t.Errorf("DetailVisible = true after `d`, want false")
	}
	if m.Focus != PaneMessages {
		t.Errorf("Focus = %v after hiding the focused detail pane, want PaneMessages", m.Focus)
	}
	if m.DetailZoom {
		t.Errorf("DetailZoom = true after hiding the pane, want false (hidden-but-zoomed is not a state)")
	}

	// Showing it again must not steal focus back — `d` is a visibility
	// toggle, not a focus command.
	m.HandleKey(Key{Rune: 'd'})
	if !m.DetailVisible {
		t.Errorf("DetailVisible = false after the second `d`, want true")
	}
	if m.Focus != PaneMessages {
		t.Errorf("Focus = %v after re-showing the pane, want it left on PaneMessages", m.Focus)
	}
}

// TestDetail_HidingWhileRosterFocusedLeavesFocusAlone is the negative half
// of the criterion: the focus move is conditional on the detail pane HOLDING
// focus, not something `d` does unconditionally.
func TestDetail_HidingWhileRosterFocusedLeavesFocusAlone(t *testing.T) {
	m := NewModel()
	m.Focus = PaneRoster
	m.HandleKey(Key{Rune: 'd'})
	if m.Focus != PaneRoster {
		t.Fatalf("Focus = %v after `d` with the roster focused, want PaneRoster", m.Focus)
	}
}

// TestZoom_RefusedWithNoSelection is criterion 5's last clause: `enter` and
// `o` zoom a MESSAGE, and with an empty (or fully filtered) log there is no
// message to zoom — the keys must be refused rather than producing a
// full-screen "(no message selected)".
func TestZoom_RefusedWithNoSelection(t *testing.T) {
	for _, k := range []Key{{Special: KeyEnter}, {Rune: 'o'}, {Rune: 'O'}} {
		m := NewModel()
		m.SetMessagesLen(0)
		m.HandleKey(k)
		if m.DetailZoom {
			t.Errorf("key %+v zoomed with an empty log, want the zoom refused", k)
		}
		if m.Focus != PaneRoster {
			t.Errorf("key %+v moved focus to %v on a refused zoom, want PaneRoster", k, m.Focus)
		}
	}
}

// TestZoom_EnterAndOZoomAndEscRestores is criterion 4's model half: both
// keys zoom (and take focus, since the zoomed pane is the only one on
// screen) and `esc` restores.
func TestZoom_EnterAndOZoomAndEscRestores(t *testing.T) {
	for _, k := range []Key{{Special: KeyEnter}, {Rune: 'o'}, {Rune: 'O'}} {
		m := NewModel()
		m.SetMessagesLen(5)
		m.HandleKey(k)
		if !m.DetailZoom {
			t.Fatalf("key %+v did not zoom", k)
		}
		if m.Focus != PaneDetail {
			t.Errorf("key %+v zoomed but left focus on %v, want PaneDetail", k, m.Focus)
		}
		if !m.DetailVisible {
			t.Errorf("key %+v zoomed a hidden pane, want the zoom to show it", k)
		}
		m.HandleKey(Key{Special: KeyEsc})
		if m.DetailZoom {
			t.Errorf("esc did not leave zoom after %+v", k)
		}
	}
}

// TestEsc_CancelsFilterDraft is the deliberate addition the edge_cases call
// out: `esc` was not decoded at all before this task, and it now abandons an
// open `/` draft WITHOUT committing it — the previously committed filter
// (if any) survives untouched, and esc does not also unzoom in the same
// keystroke.
func TestEsc_CancelsFilterDraft(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(5)
	m.HandleKey(Key{Rune: '/'})
	m.HandleKey(Key{Rune: 'a'})
	m.HandleKey(Key{Special: KeyEnter}) // commit "a"
	if m.Filter != (Filter{Set: true, Query: "a"}) {
		t.Fatalf("setup: Filter = %+v, want the committed \"a\"", m.Filter)
	}

	m.DetailZoom = true
	m.HandleKey(Key{Rune: '/'})
	m.HandleKey(Key{Rune: 'z'})
	m.HandleKey(Key{Special: KeyEsc})

	if m.Editing {
		t.Errorf("Editing = true after esc, want the draft closed")
	}
	if m.Filter != (Filter{Set: true, Query: "a"}) {
		t.Errorf("Filter = %+v after esc, want the previously committed \"a\" untouched", m.Filter)
	}
	if !m.DetailZoom {
		t.Errorf("esc cancelling a draft also left zoom; one keystroke must do one thing")
	}

	// The abandoned draft must not resurface: reopening and committing an
	// empty draft yields an empty query, not "z".
	m.HandleKey(Key{Rune: '/'})
	m.HandleKey(Key{Special: KeyEnter})
	if m.Filter != (Filter{Set: true, Query: ""}) {
		t.Errorf("Filter = %+v, want the abandoned draft gone", m.Filter)
	}
}

// TestDetail_ScrollKeysMoveOnlyTheDetailPane is criterion 3's key surface at
// the model level: with the detail pane focused, jk/arrows and PgUp/PgDn
// move DetailScroll and touch neither of the other two panes' cursors or
// scrolls. Paging on roster and messages is Task 5's, deliberately not here.
func TestDetail_ScrollKeysMoveOnlyTheDetailPane(t *testing.T) {
	newFocused := func() *Model {
		m := NewModel()
		m.SetRosterLen(100)
		m.SetRosterViewport(10)
		m.SetMessagesLen(100)
		m.SetMessagesViewport(10)
		m.SetDetailLen(100)
		m.SetDetailViewport(10)
		m.Focus = PaneDetail
		return m
	}

	cases := []struct {
		name string
		key  Key
		want int
	}{
		{"j", Key{Rune: 'j'}, 1},
		{"down", Key{Special: KeyDown}, 1},
		{"pgdn", Key{Special: KeyPgDn}, 10},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := newFocused()
			m.HandleKey(c.key)
			if m.DetailScroll != c.want {
				t.Errorf("DetailScroll = %d, want %d", m.DetailScroll, c.want)
			}
			if m.RosterCursor != 0 || m.RosterScroll != 0 {
				t.Errorf("roster moved: cursor=%d scroll=%d, want 0/0", m.RosterCursor, m.RosterScroll)
			}
			if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
				t.Errorf("messages moved: cursor=%d scroll=%d, want 0/0", m.MessagesCursor, m.MessagesScroll)
			}
		})
	}

	// And back up from a scrolled position.
	for _, c := range []struct {
		name string
		key  Key
		want int
	}{
		{"k", Key{Rune: 'k'}, 49},
		{"up", Key{Special: KeyUp}, 49},
		{"pgup", Key{Special: KeyPgUp}, 40},
	} {
		t.Run(c.name, func(t *testing.T) {
			m := newFocused()
			m.ScrollDetail(50)
			m.HandleKey(c.key)
			if m.DetailScroll != c.want {
				t.Errorf("DetailScroll = %d, want %d", m.DetailScroll, c.want)
			}
		})
	}
}

// TestPaging_DoesNotReachRosterOrMessages is the Task 5 boundary stated as a
// test: PgUp/PgDn are decoded here for the DETAIL pane only. If a later task
// widens them it will delete this test on purpose; until then a paging key
// that quietly moved the roster would be scope creep nobody asked for.
func TestPaging_DoesNotReachRosterOrMessages(t *testing.T) {
	for _, focus := range []Pane{PaneRoster, PaneMessages} {
		for _, k := range []Key{{Special: KeyPgDn}, {Special: KeyPgUp}} {
			m := NewModel()
			m.SetRosterLen(100)
			m.SetRosterViewport(10)
			m.SetMessagesLen(100)
			m.SetMessagesViewport(10)
			// Park both panes mid-list so BOTH directions have room to
			// move. Asserting from scroll 0 would make the PgUp case
			// vacuous — a clamp at 0 is indistinguishable from a key that
			// was never decoded.
			m.ScrollRoster(30)
			m.ScrollMessages(30)
			m.Focus = focus

			// One key at a time: a PgDn/PgUp PAIR round-trips, so a model
			// that paged both panes would end up back where it started and
			// a before/after compare across the pair would see nothing.
			before := *m
			m.HandleKey(k)
			if *m != before {
				t.Errorf("focus %v, key %+v: paging changed model state\n got %+v\nwant %+v", focus, k, *m, before)
			}
		}
	}
}

// TestDetail_ScrollNeverLeavesTheBody is the "body shorter than the
// viewport: no phantom scroll" edge case plus its mirror at the bottom.
func TestDetail_ScrollNeverLeavesTheBody(t *testing.T) {
	m := NewModel()
	m.SetDetailViewport(20)
	m.SetDetailLen(5) // shorter than the window
	m.ScrollDetail(10)
	if m.DetailScroll != 0 {
		t.Errorf("DetailScroll = %d for a 5-line body in a 20-row window, want 0", m.DetailScroll)
	}

	m.SetDetailLen(50)
	m.ScrollDetail(1000)
	if want := 30; m.DetailScroll != want {
		t.Errorf("DetailScroll = %d, want the last full page %d", m.DetailScroll, want)
	}
	m.ScrollDetail(-1000)
	if m.DetailScroll != 0 {
		t.Errorf("DetailScroll = %d after scrolling far up, want 0", m.DetailScroll)
	}

	// A body that shrinks under a scrolled view clamps in the same pass, so
	// a caller slicing body[DetailScroll:] cannot panic.
	m.ScrollDetail(30)
	m.SetDetailLen(10)
	if m.DetailScroll > 10 {
		t.Errorf("DetailScroll = %d past a 10-line body, want it clamped", m.DetailScroll)
	}
}

// TestDetail_SelectionChangeResetsScrollToTop is criterion 3's second half
// at the model level: the same selection key across any number of re-renders
// keeps the scroll, and a different one puts the reader at the top of the
// new message rather than 40 lines into it.
func TestDetail_SelectionChangeResetsScrollToTop(t *testing.T) {
	m := NewModel()
	m.SetDetailViewport(10)
	m.SetDetailLen(100)
	m.SetDetailSelection("msg-a")
	m.ScrollDetail(40)

	for i := 0; i < 5; i++ { // five sampler ticks over the same message
		m.SetDetailSelection("msg-a")
		m.SetDetailLen(100)
	}
	if m.DetailScroll != 40 {
		t.Fatalf("DetailScroll = %d after re-renders of the same message, want 40", m.DetailScroll)
	}

	m.SetDetailSelection("msg-b")
	if m.DetailScroll != 0 {
		t.Fatalf("DetailScroll = %d after the selection changed, want 0", m.DetailScroll)
	}
}

// TestScrollPane_DetailIsAScrollTarget is the wheel's model-level entry:
// T3's ScrollPane gained a third case, and it must move the detail pane's
// scroll and nothing else.
func TestScrollPane_DetailIsAScrollTarget(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(100)
	m.SetRosterViewport(10)
	m.SetMessagesLen(100)
	m.SetMessagesViewport(10)
	m.SetDetailLen(100)
	m.SetDetailViewport(10)

	m.ScrollPane(PaneDetail, 3)
	if m.DetailScroll != 3 {
		t.Errorf("DetailScroll = %d, want 3", m.DetailScroll)
	}
	if m.RosterScroll != 0 || m.MessagesScroll != 0 {
		t.Errorf("ScrollPane(PaneDetail) moved another pane: roster=%d messages=%d", m.RosterScroll, m.MessagesScroll)
	}
	if m.Focus != PaneRoster {
		t.Errorf("ScrollPane(PaneDetail) changed focus to %v, want it untouched", m.Focus)
	}
}

// TestTab_WhileZoomedIsANoOp is the other half of cycleFocus' guard: the
// zoom layout renders the detail pane ALONE, so a tab that moved focus to
// the roster would focus a pane that is not on screen — the same illegal
// state criterion 5 forbids for a hidden pane.
func TestTab_WhileZoomedIsANoOp(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(3)
	m.HandleKey(Key{Special: KeyEnter}) // zoom
	if !m.DetailZoom || m.Focus != PaneDetail {
		t.Fatalf("setup: DetailZoom=%v Focus=%v, want zoomed on PaneDetail", m.DetailZoom, m.Focus)
	}
	m.HandleKey(Key{Special: KeyTab})
	if m.Focus != PaneDetail {
		t.Errorf("Focus = %v after tab while zoomed, want PaneDetail", m.Focus)
	}
	m.HandleKey(Key{Special: KeyEsc})
	m.HandleKey(Key{Special: KeyTab})
	if m.Focus != PaneRoster {
		t.Errorf("Focus = %v after tab once un-zoomed, want the cycle to resume at PaneRoster", m.Focus)
	}
}
