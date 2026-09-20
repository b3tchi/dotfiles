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

// TestFilter_FilterDraftExposesTypedText is dotfiles-jw73's accessor, the
// filter draft's ComposeDraft equivalent: m.draft is otherwise package-
// private, and the render layer (cmd/) needs to read back what the operator
// is typing before Enter commits it.
func TestFilter_FilterDraftExposesTypedText(t *testing.T) {
	m := NewModel()
	m.HandleKey(Key{Rune: '/'})

	if got := m.FilterDraft(); got != "" {
		t.Fatalf("got FilterDraft() %q on a freshly opened draft, want empty", got)
	}
	for _, r := range "cla" {
		m.HandleKey(Key{Rune: r})
	}
	if got := m.FilterDraft(); got != "cla" {
		t.Fatalf("got FilterDraft() %q, want %q", got, "cla")
	}

	m.HandleKey(Key{Special: KeyEnter})
	if got := m.FilterDraft(); got != "" {
		t.Fatalf("got FilterDraft() %q after commit, want the draft cleared", got)
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

// dotfiles-1xfo's exact reproduction: a message addressed TO peer-3 (not
// FROM it) must survive the filter — the bug was that ten messages sent to a
// worker vanished under its own name filter.
func TestFilterMessages_MatchesRecipient(t *testing.T) {
	m := NewModel()
	m.HandleKey(Key{Rune: '/'})
	for _, r := range "peer-3" {
		m.HandleKey(Key{Rune: r})
	}
	m.HandleKey(Key{Special: KeyEnter})

	msgs := []source.Message{
		{From: "peer-1", To: []string{"peer-2"}},
		{From: "peer-1", To: []string{"peer-3"}},
	}
	got := m.FilterMessages(msgs)
	if len(got) != 1 || len(got[0].To) != 1 || got[0].To[0] != "peer-3" {
		t.Fatalf("expected only the message addressed to peer-3 to survive, got %+v", got)
	}
}

func TestFilterMessages_MatchesSecondRecipient(t *testing.T) {
	m := NewModel()
	m.HandleKey(Key{Rune: '/'})
	for _, r := range "peer-3" {
		m.HandleKey(Key{Rune: r})
	}
	m.HandleKey(Key{Special: KeyEnter})

	msgs := []source.Message{
		{From: "peer-1", To: []string{"peer-2", "peer-4"}},
		{From: "peer-1", To: []string{"peer-2", "peer-3"}},
	}
	got := m.FilterMessages(msgs)
	if len(got) != 1 || len(got[0].To) != 2 || got[0].To[1] != "peer-3" {
		t.Fatalf("expected only the message with peer-3 as second recipient to survive, got %+v", got)
	}
}

func TestFilterMessages_RowMatchingBothAppearsOnce(t *testing.T) {
	m := NewModel()
	m.HandleKey(Key{Rune: '/'})
	for _, r := range "peer-3" {
		m.HandleKey(Key{Rune: r})
	}
	m.HandleKey(Key{Special: KeyEnter})

	msgs := []source.Message{
		{From: "peer-3", To: []string{"peer-3"}},
	}
	got := m.FilterMessages(msgs)
	if len(got) != 1 {
		t.Fatalf("expected the row matching on both From and To to appear exactly once, got %d: %+v", len(got), got)
	}
}

func TestFilterMessages_EmptyQueryUnchanged(t *testing.T) {
	m := NewModel()
	m.HandleKey(Key{Rune: '/'})
	m.HandleKey(Key{Special: KeyEnter})

	msgs := []source.Message{
		{From: "peer-1", To: []string{"peer-2"}},
		{From: "peer-3", To: nil},
	}
	got := m.FilterMessages(msgs)
	if len(got) != len(msgs) {
		t.Fatalf("expected an empty query to return every row unchanged, got %d want %d", len(got), len(msgs))
	}
	for i := range msgs {
		if got[i].From != msgs[i].From {
			t.Fatalf("row %d changed under empty query: got %+v want %+v", i, got[i], msgs[i])
		}
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
			// Lengths BEFORE viewports, which is the order renderFrame
			// itself produces (it filters — and so calls Set*Len — before
			// it reports this frame's viewports). It matters since sp032
			// T6: an empty pane is live, so a viewport reported first would
			// make the fixture's own first sample tail-follow to the bottom
			// and start this test somewhere other than the top of the list.
			m.SetRosterLen(40)
			m.SetMessagesLen(40)
			m.SetRosterViewport(5)
			m.SetMessagesViewport(5)
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
			// Lengths BEFORE viewports, which is the order renderFrame
			// itself produces (it filters — and so calls Set*Len — before
			// it reports this frame's viewports). It matters since sp032
			// T6: an empty pane is live, so a viewport reported first would
			// make the fixture's own first sample tail-follow to the bottom
			// and start this test somewhere other than the top of the list.
			m.SetRosterLen(40)
			m.SetMessagesLen(40)
			m.SetRosterViewport(5)
			m.SetMessagesViewport(5)
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

// TestPaging_DoesNotCrossPanes is sp032 T4's TestPaging_DoesNotReachRosterOrMessages,
// rewritten by T5 rather than deleted. T4 decoded PgUp/PgDn for the DETAIL
// pane alone and pinned that boundary by asserting the keys changed NOTHING
// when the roster or messages had focus; T5's criterion 1 is precisely the
// change that invalidates that assertion, so the "reaches no other pane"
// claim is restated the way it survives: a paging key moves the FOCUSED pane
// and only the focused pane.
//
// Two properties of the original are kept deliberately, because both were
// found by mutation and both still matter:
//
//   - one key at a time, never a PgDn/PgUp PAIR — a pair round-trips, so a
//     model paging the wrong pane would land back where it started and a
//     before/after compare across the pair would see nothing;
//   - from a MID-LIST position, so a clamp at 0 is distinguishable from a key
//     that was never decoded at all.
func TestPaging_DoesNotCrossPanes(t *testing.T) {
	type snapshot struct{ roster, rosterScroll, messages, messagesScroll, detail int }
	snap := func(m *Model) snapshot {
		return snapshot{m.RosterCursor, m.RosterScroll, m.MessagesCursor, m.MessagesScroll, m.DetailScroll}
	}

	for _, focus := range []Pane{PaneRoster, PaneMessages, PaneDetail} {
		for _, k := range []Key{
			{Special: KeyPgDn}, {Special: KeyPgUp},
			{Special: KeyHome}, {Special: KeyEnd}, {Rune: 'G'},
		} {
			m := pagingModel()
			// Park every pane mid-list so BOTH directions have room to move
			// on all three.
			m.RosterCursor, m.RosterScroll = 40, 35
			m.MessagesCursor, m.MessagesScroll = 40, 35
			m.ScrollDetail(40)
			m.Focus = focus

			before := snap(m)
			m.HandleKey(k)
			after := snap(m)

			if before == after {
				t.Errorf("focus %v, key %+v: nothing moved at all", focus, k)
			}
			if focus != PaneRoster && (after.roster != before.roster || after.rosterScroll != before.rosterScroll) {
				t.Errorf("focus %v, key %+v: roster moved (cursor %d->%d, scroll %d->%d)",
					focus, k, before.roster, after.roster, before.rosterScroll, after.rosterScroll)
			}
			if focus != PaneMessages && (after.messages != before.messages || after.messagesScroll != before.messagesScroll) {
				t.Errorf("focus %v, key %+v: messages moved (cursor %d->%d, scroll %d->%d)",
					focus, k, before.messages, after.messages, before.messagesScroll, after.messagesScroll)
			}
			if focus != PaneDetail && after.detail != before.detail {
				t.Errorf("focus %v, key %+v: detail scroll moved %d->%d", focus, k, before.detail, after.detail)
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

// ---------------------------------------------------------------------------
// sp032 T5: paging keys on all three panes.
// ---------------------------------------------------------------------------

// pagingModel is a three-pane model with every pane long enough to page and
// a window of 10 rows on each, so viewport-1 is 9 and a landed cursor is a
// distinguishable number rather than a clamp.
func pagingModel() *Model {
	m := NewModel()
	m.SetRosterLen(100)
	m.SetRosterViewport(10)
	m.SetMessagesLen(100)
	m.SetMessagesViewport(10)
	m.SetDetailLen(100)
	m.SetDetailViewport(10)
	return m
}

// TestPaging_PgDnAdvancesByViewportMinusOne is criterion 1 per pane, one key
// at a time from a MID-LIST position, asserting the index the cursor lands
// on. Starting mid-list and never round-tripping a PgDn against a PgUp is
// deliberate: T4's first attempt at this boundary paged from 0 and compared
// across a PgDn/PgUp pair, which a mutation paging the wrong pane satisfied
// by cancelling itself out.
//
// The step is viewport-1 rather than viewport because a page that moved by a
// full window would leave no line in common between the old view and the new
// one; the overlapping row is what tells a reader where they landed.
func TestPaging_PgDnAdvancesByViewportMinusOne(t *testing.T) {
	t.Run("roster", func(t *testing.T) {
		m := pagingModel()
		m.Focus = PaneRoster
		m.RosterCursor = 40
		m.HandleKey(Key{Special: KeyPgDn})
		if m.RosterCursor != 49 {
			t.Errorf("RosterCursor = %d after PgDn from 40 with viewport 10, want 49", m.RosterCursor)
		}
		if m.MessagesCursor != 0 || m.DetailScroll != 0 {
			t.Errorf("PgDn on the roster moved another pane: messages=%d detail=%d", m.MessagesCursor, m.DetailScroll)
		}
	})

	t.Run("messages", func(t *testing.T) {
		m := pagingModel()
		m.Focus = PaneMessages
		m.MessagesCursor = 40
		m.HandleKey(Key{Special: KeyPgDn})
		if m.MessagesCursor != 49 {
			t.Errorf("MessagesCursor = %d after PgDn from 40 with viewport 10, want 49", m.MessagesCursor)
		}
		if m.RosterCursor != 0 || m.DetailScroll != 0 {
			t.Errorf("PgDn on the messages pane moved another pane: roster=%d detail=%d", m.RosterCursor, m.DetailScroll)
		}
	})

	t.Run("detail scrolls by the full viewport height", func(t *testing.T) {
		// The detail pane has no cursor and no overlapping-row affordance to
		// preserve — sp032's criterion 1 says a full height for it and
		// viewport-1 for the two list panes, and that difference is the
		// assertion here, not an oversight.
		m := pagingModel()
		m.Focus = PaneDetail
		m.ScrollDetail(40)
		m.HandleKey(Key{Special: KeyPgDn})
		if m.DetailScroll != 50 {
			t.Errorf("DetailScroll = %d after PgDn from 40 with viewport 10, want 50", m.DetailScroll)
		}
	})

	t.Run("pgup is the mirror", func(t *testing.T) {
		for _, c := range []struct {
			name  string
			focus Pane
			get   func(*Model) int
			set   func(*Model)
			want  int
		}{
			{"roster", PaneRoster, func(m *Model) int { return m.RosterCursor }, func(m *Model) { m.RosterCursor = 40 }, 31},
			{"messages", PaneMessages, func(m *Model) int { return m.MessagesCursor }, func(m *Model) { m.MessagesCursor = 40 }, 31},
			{"detail", PaneDetail, func(m *Model) int { return m.DetailScroll }, func(m *Model) { m.ScrollDetail(40) }, 30},
		} {
			t.Run(c.name, func(t *testing.T) {
				m := pagingModel()
				m.Focus = c.focus
				c.set(m)
				m.HandleKey(Key{Special: KeyPgUp})
				if got := c.get(m); got != c.want {
					t.Errorf("after PgUp from 40 with viewport 10, got %d, want %d", got, c.want)
				}
			})
		}
	})
}

// TestPaging_HomeAndEndSelectFirstAndLast is criterion 2. End is asserted at
// len-1 — the last ROW index — rather than at len, which is a slice bound and
// not a position any cursor may hold.
func TestPaging_HomeAndEndSelectFirstAndLast(t *testing.T) {
	t.Run("roster", func(t *testing.T) {
		m := pagingModel()
		m.Focus = PaneRoster
		m.RosterCursor = 40

		m.HandleKey(Key{Special: KeyEnd})
		if m.RosterCursor != 99 {
			t.Errorf("RosterCursor = %d after End over 100 rows, want 99", m.RosterCursor)
		}
		// The last row must be ON SCREEN, not merely selected: a cursor at
		// 99 with scroll still at 31 is a selection the reader cannot see.
		if m.RosterScroll != 90 {
			t.Errorf("RosterScroll = %d after End, want the last full page 90", m.RosterScroll)
		}

		m.HandleKey(Key{Special: KeyHome})
		if m.RosterCursor != 0 {
			t.Errorf("RosterCursor = %d after Home, want 0", m.RosterCursor)
		}
		if m.RosterScroll != 0 {
			t.Errorf("RosterScroll = %d after Home, want 0", m.RosterScroll)
		}
	})

	t.Run("messages", func(t *testing.T) {
		m := pagingModel()
		m.Focus = PaneMessages
		m.MessagesCursor = 40

		m.HandleKey(Key{Special: KeyEnd})
		if m.MessagesCursor != 99 || m.MessagesScroll != 90 {
			t.Errorf("after End: cursor=%d scroll=%d, want 99/90", m.MessagesCursor, m.MessagesScroll)
		}
		m.HandleKey(Key{Special: KeyHome})
		if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
			t.Errorf("after Home: cursor=%d scroll=%d, want 0/0", m.MessagesCursor, m.MessagesScroll)
		}
	})

	t.Run("detail goes to the ends of the body", func(t *testing.T) {
		m := pagingModel()
		m.Focus = PaneDetail
		m.ScrollDetail(40)

		m.HandleKey(Key{Special: KeyEnd})
		if m.DetailScroll != 90 {
			t.Errorf("DetailScroll = %d after End over a 100-line body in a 10-row window, want 90", m.DetailScroll)
		}
		m.HandleKey(Key{Special: KeyHome})
		if m.DetailScroll != 0 {
			t.Errorf("DetailScroll = %d after Home, want 0", m.DetailScroll)
		}
	})
}

// TestPaging_GIsEnd pins the vim spelling of End on every pane. It is
// asserted as "the same state End leaves behind" rather than as its own
// numbers, so the two spellings cannot drift apart later.
func TestPaging_GIsEnd(t *testing.T) {
	for _, focus := range []Pane{PaneRoster, PaneMessages, PaneDetail} {
		viaEnd := pagingModel()
		viaEnd.Focus = focus
		viaEnd.RosterCursor, viaEnd.MessagesCursor = 40, 40
		viaEnd.ScrollDetail(40)
		viaEnd.HandleKey(Key{Special: KeyEnd})

		viaG := pagingModel()
		viaG.Focus = focus
		viaG.RosterCursor, viaG.MessagesCursor = 40, 40
		viaG.ScrollDetail(40)
		viaG.HandleKey(Key{Rune: 'G'})

		if *viaG != *viaEnd {
			t.Errorf("focus %v: G left %+v, End left %+v", focus, *viaG, *viaEnd)
		}
	}

	// And it really moved — otherwise "G equals End" would also hold for a
	// G that did nothing against an End that did nothing.
	m := pagingModel()
	m.Focus = PaneMessages
	m.MessagesCursor = 40
	m.HandleKey(Key{Rune: 'G'})
	if m.MessagesCursor != 99 {
		t.Errorf("MessagesCursor = %d after G, want 99", m.MessagesCursor)
	}
}

// TestPaging_gIsHome is TestPaging_GIsEnd's twin for sp033 T6's new key:
// lowercase 'g' is Home's vim spelling, added so Home/g's live-return has
// the same two-key surface End/G has always had.
func TestPaging_gIsHome(t *testing.T) {
	for _, focus := range []Pane{PaneRoster, PaneMessages, PaneDetail} {
		viaHome := pagingModel()
		viaHome.Focus = focus
		viaHome.RosterCursor, viaHome.MessagesCursor = 40, 40
		viaHome.ScrollDetail(40)
		viaHome.HandleKey(Key{Special: KeyHome})

		viaG := pagingModel()
		viaG.Focus = focus
		viaG.RosterCursor, viaG.MessagesCursor = 40, 40
		viaG.ScrollDetail(40)
		viaG.HandleKey(Key{Rune: 'g'})

		if *viaG != *viaHome {
			t.Errorf("focus %v: g left %+v, Home left %+v", focus, *viaG, *viaHome)
		}
	}

	// And it really moved.
	m := pagingModel()
	m.Focus = PaneMessages
	m.MessagesCursor = 40
	m.HandleKey(Key{Rune: 'g'})
	if m.MessagesCursor != 0 {
		t.Errorf("MessagesCursor = %d after g, want 0", m.MessagesCursor)
	}
}

// TestPaging_ClampsAtBothEnds covers the empty, single-row and
// viewport-larger-than-the-list shapes for every key in the set. None of
// them may produce an index outside [0, len-1] or a scroll outside its own
// clamp, and on an empty list every one of them is a no-op.
func TestPaging_ClampsAtBothEnds(t *testing.T) {
	keys := []Key{
		{Special: KeyPgUp}, {Special: KeyPgDn},
		{Special: KeyHome}, {Special: KeyEnd}, {Rune: 'G'}, {Rune: 'g'},
	}

	t.Run("empty list is a no-op", func(t *testing.T) {
		for _, focus := range []Pane{PaneRoster, PaneMessages} {
			for _, k := range keys {
				m := NewModel()
				m.SetRosterLen(0)
				m.SetRosterViewport(10)
				m.SetMessagesLen(0)
				m.SetMessagesViewport(10)
				m.Focus = focus
				before := *m
				m.HandleKey(k)
				if *m != before {
					t.Errorf("focus %v key %+v on an empty list changed state:\n got %+v\nwant %+v", focus, k, *m, before)
				}
			}
		}
	})

	t.Run("single row", func(t *testing.T) {
		for _, k := range keys {
			m := NewModel()
			m.SetMessagesLen(1)
			m.SetMessagesViewport(10)
			m.Focus = PaneMessages
			m.HandleKey(k)
			if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
				t.Errorf("key %+v over a single row: cursor=%d scroll=%d, want 0/0", k, m.MessagesCursor, m.MessagesScroll)
			}
		}
	})

	t.Run("viewport larger than the list", func(t *testing.T) {
		for _, k := range keys {
			m := NewModel()
			m.SetRosterLen(4)
			m.SetRosterViewport(20)
			m.Focus = PaneRoster
			m.RosterCursor = 2
			m.HandleKey(k)
			if m.RosterCursor < 0 || m.RosterCursor > 3 {
				t.Errorf("key %+v left RosterCursor = %d, want it inside [0,3]", k, m.RosterCursor)
			}
			if m.RosterScroll != 0 {
				t.Errorf("key %+v left RosterScroll = %d over a list that fits, want 0", k, m.RosterScroll)
			}
		}
	})

	t.Run("repeated keys pin at the ends", func(t *testing.T) {
		m := pagingModel()
		m.Focus = PaneMessages
		for i := 0; i < 50; i++ {
			m.HandleKey(Key{Special: KeyPgDn})
		}
		if m.MessagesCursor != 99 || m.MessagesScroll != 90 {
			t.Errorf("after 50 PgDn: cursor=%d scroll=%d, want 99/90", m.MessagesCursor, m.MessagesScroll)
		}
		for i := 0; i < 50; i++ {
			m.HandleKey(Key{Special: KeyPgUp})
		}
		if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
			t.Errorf("after 50 PgUp: cursor=%d scroll=%d, want 0/0", m.MessagesCursor, m.MessagesScroll)
		}
	})

	t.Run("detail with a nil message", func(t *testing.T) {
		// Nothing selected: cmd/ reports a body of zero lines. Every key in
		// the set must leave the scroll at 0 rather than at a negative or a
		// phantom offset.
		for _, k := range keys {
			m := NewModel()
			m.SetDetailViewport(10)
			m.SetDetailLen(0)
			m.Focus = PaneDetail
			m.HandleKey(k)
			if m.DetailScroll != 0 {
				t.Errorf("key %+v over an empty detail body left DetailScroll = %d, want 0", k, m.DetailScroll)
			}
		}
	})
}

// TestPaging_WhileEditingIsSwallowed is criterion 3. PgUp/PgDn/Home/End are
// not runes, so the rune-into-the-draft rule says nothing about them: without
// an explicit branch a paging key typed during a `/` query would move a pane
// out from under the draft. G is in the table for the opposite reason — it IS
// a rune, so "swallowed" means it lands in the draft as text, and a G that
// jumped to the last row while a query was open would be the same defect
// wearing the other hat.
func TestPaging_WhileEditingIsSwallowed(t *testing.T) {
	cases := []struct {
		name string
		key  Key
	}{
		{"pgup", Key{Special: KeyPgUp}},
		{"pgdn", Key{Special: KeyPgDn}},
		{"home", Key{Special: KeyHome}},
		{"end", Key{Special: KeyEnd}},
		{"G", Key{Rune: 'G'}},
		{"g", Key{Rune: 'g'}},
	}
	for _, c := range cases {
		for _, focus := range []Pane{PaneRoster, PaneMessages, PaneDetail} {
			t.Run(c.name+"/"+map[Pane]string{PaneRoster: "roster", PaneMessages: "messages", PaneDetail: "detail"}[focus], func(t *testing.T) {
				m := pagingModel()
				m.Focus = focus
				m.RosterCursor, m.MessagesCursor = 40, 40
				m.ScrollDetail(40)
				m.RosterScroll, m.MessagesScroll = 31, 31

				m.HandleKey(Key{Rune: '/'}) // open the draft
				m.HandleKey(Key{Rune: 'a'})
				before := *m

				m.HandleKey(c.key)

				if m.RosterCursor != before.RosterCursor || m.RosterScroll != before.RosterScroll {
					t.Errorf("roster moved while editing: cursor %d->%d scroll %d->%d",
						before.RosterCursor, m.RosterCursor, before.RosterScroll, m.RosterScroll)
				}
				if m.MessagesCursor != before.MessagesCursor || m.MessagesScroll != before.MessagesScroll {
					t.Errorf("messages moved while editing: cursor %d->%d scroll %d->%d",
						before.MessagesCursor, m.MessagesCursor, before.MessagesScroll, m.MessagesScroll)
				}
				if m.DetailScroll != before.DetailScroll {
					t.Errorf("detail moved while editing: scroll %d->%d", before.DetailScroll, m.DetailScroll)
				}
				if !m.Editing {
					t.Errorf("Editing = false after %s, want the draft still open", c.name)
				}

				// Commit and read the draft back through the committed
				// filter: a rune belongs in the query, a special key does
				// not.
				m.HandleKey(Key{Special: KeyEnter})
				want := "a"
				if c.key.Rune != 0 {
					want = "a" + string(c.key.Rune)
				}
				if m.Filter.Query != want {
					t.Errorf("committed query = %q after %s, want %q", m.Filter.Query, c.name, want)
				}
			})
		}
	}
}

// TestPaging_OnDetailDoesNotMoveTheMessageCursor is criterion 4. The detail
// pane shows whatever the message cursor selects, so a paging key that moved
// that cursor would swap the message out from under the reader mid-page —
// the one failure mode that makes a scrollable detail pane worse than a
// truncated one.
func TestPaging_OnDetailDoesNotMoveTheMessageCursor(t *testing.T) {
	for _, k := range []Key{
		{Special: KeyPgUp}, {Special: KeyPgDn},
		{Special: KeyHome}, {Special: KeyEnd}, {Rune: 'G'},
	} {
		m := pagingModel()
		m.Focus = PaneDetail
		m.MessagesCursor = 40
		m.MessagesScroll = 31
		m.RosterCursor = 40
		m.RosterScroll = 31
		m.ScrollDetail(40)

		m.HandleKey(k)

		if m.MessagesCursor != 40 || m.MessagesScroll != 31 {
			t.Errorf("key %+v on the detail pane moved the message pane: cursor=%d scroll=%d, want 40/31",
				k, m.MessagesCursor, m.MessagesScroll)
		}
		if m.RosterCursor != 40 || m.RosterScroll != 31 {
			t.Errorf("key %+v on the detail pane moved the roster: cursor=%d scroll=%d, want 40/31",
				k, m.RosterCursor, m.RosterScroll)
		}
		if m.DetailScroll == 40 {
			t.Errorf("key %+v on the detail pane did not move the detail scroll at all", k)
		}
	}
}

// TestPaging_ViewportZeroDoesNotStepBackwards is the degenerate shape the
// step expression invites: viewport-1 is -1 when no viewport has been
// reported (the --once path, and any frame before the first render), and a
// PgDn that stepped -1 would page UP. The floor is one row, so paging still
// moves in the direction it names.
func TestPaging_ViewportZeroDoesNotStepBackwards(t *testing.T) {
	for _, c := range []struct {
		name  string
		focus Pane
		get   func(*Model) int
		set   func(*Model, int)
	}{
		{"roster", PaneRoster, func(m *Model) int { return m.RosterCursor }, func(m *Model, v int) { m.RosterCursor = v }},
		{"messages", PaneMessages, func(m *Model) int { return m.MessagesCursor }, func(m *Model, v int) { m.MessagesCursor = v }},
	} {
		t.Run(c.name, func(t *testing.T) {
			m := NewModel()
			m.SetRosterLen(100)
			m.SetMessagesLen(100)
			m.Focus = c.focus // viewport never set: still 0
			c.set(m, 40)

			m.HandleKey(Key{Special: KeyPgDn})
			if got := c.get(m); got != 41 {
				t.Errorf("PgDn with viewport 0 from 40 landed on %d, want 41", got)
			}
			m.HandleKey(Key{Special: KeyPgUp})
			if got := c.get(m); got != 40 {
				t.Errorf("PgUp with viewport 0 from 41 landed on %d, want 40", got)
			}
		})
	}

	t.Run("viewport one also steps forward", func(t *testing.T) {
		// viewport-1 is 0 here, which would make paging a silent no-op.
		m := NewModel()
		m.SetMessagesLen(100)
		m.SetMessagesViewport(1)
		m.Focus = PaneMessages
		m.MessagesCursor = 40
		m.HandleKey(Key{Special: KeyPgDn})
		if m.MessagesCursor != 41 {
			t.Errorf("PgDn with viewport 1 from 40 landed on %d, want 41", m.MessagesCursor)
		}
	})

	t.Run("detail viewport zero", func(t *testing.T) {
		m := NewModel()
		m.SetDetailLen(100)
		m.Focus = PaneDetail
		m.HandleKey(Key{Special: KeyPgDn})
		if m.DetailScroll < 0 {
			t.Errorf("DetailScroll = %d after PgDn with no viewport, want it non-negative", m.DetailScroll)
		}
	})
}

// --- sp033 T6: conditional head-follow with a pending count ---------------
//
// LIVE is derived, never stored: the message pane is live when its cursor is
// on ROW 0 and its scroll is at the TOP. sp032 pinned this at the tail; T6
// moves it to the head because the pane now renders newest-first (row 0 is
// the newest envelope) — every case below restates one of sp032's
// tail-follow invariants at the other end, per `## known limitations`. A
// live pane follows new arrivals landing at row 0, a scrolled-back one does
// not move AT ALL and reports how many messages it is behind.

// liveMessagePane is the shared setup: a message pane with a real window,
// some history, focused, and parked at the head (live).
func liveMessagePane(t *testing.T, length, viewport int) *Model {
	t.Helper()
	m := NewModel()
	m.Focus = PaneMessages
	m.SetMessagesViewport(viewport)
	m.SetMessagesLen(length)
	m.GoToFirst()
	if m.MessagesCursor != 0 {
		t.Fatalf("setup: cursor = %d, want 0 (row 0)", m.MessagesCursor)
	}
	if m.MessagesScroll != 0 {
		t.Fatalf("setup: scroll = %d, want 0 (the top)", m.MessagesScroll)
	}
	if m.PendingMessages != 0 {
		t.Fatalf("setup: PendingMessages = %d, want 0 on a live pane", m.PendingMessages)
	}
	return m
}

// TestOrder_NewestIsRowZero is criterion 1 at the state layer: a freshly
// sized pane (and, by extension, one just opened) sits with its cursor and
// its scroll both at row 0 — the position cmd/agent-monitor's
// orderedMessages puts the newest envelope at — and that position is what
// messagesLive derives LIVE from.
func TestOrder_NewestIsRowZero(t *testing.T) {
	m := NewModel()
	m.Focus = PaneMessages
	m.SetMessagesViewport(10)
	m.SetMessagesLen(20)
	if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
		t.Fatalf("cursor/scroll = %d/%d, want 0/0 — row 0 is the newest envelope", m.MessagesCursor, m.MessagesScroll)
	}
	if !m.messagesLive() {
		t.Errorf("a pane parked on row 0 with the scroll at the top must be live")
	}
}

// TestOrder_FollowsHeadWhileLive is criterion 2's first half, restating
// sp032's TestTail_FollowsWhileLive: a sample that grows the list leaves a
// live pane on row 0 — which IS following, since row 0 is always the newest
// row by construction and never moves the way the tail's maxIndex did.
func TestOrder_FollowsHeadWhileLive(t *testing.T) {
	m := liveMessagePane(t, 20, 10)

	m.SetMessagesLen(23)

	if m.MessagesCursor != 0 {
		t.Errorf("cursor = %d, want 0 (row 0 stays the newest)", m.MessagesCursor)
	}
	if m.MessagesScroll != 0 {
		t.Errorf("scroll = %d, want 0 (still at the top)", m.MessagesScroll)
	}
	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d, want 0 — a live pane is never behind", m.PendingMessages)
	}

	// And it keeps following, sample after sample.
	m.SetMessagesLen(24)
	if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
		t.Errorf("second append: cursor/scroll = %d/%d, want 0/0", m.MessagesCursor, m.MessagesScroll)
	}
}

// TestOrder_FrozenWhenScrolledBack restates sp032's TestTail_FrozenWhenScrolledBack:
// once the operator has scrolled away from row 0 AT ALL, several growing
// samples leave the cursor and the scroll byte-identical. Asserting
// "unchanged" rather than "still valid" is the point — a re-derive would
// also leave them in range.
func TestOrder_FrozenWhenScrolledBack(t *testing.T) {
	m := liveMessagePane(t, 20, 10)
	m.ScrollMessages(5) // scrolled toward the oldest: no longer live

	wantCursor, wantScroll := m.MessagesCursor, m.MessagesScroll
	if wantScroll != 5 {
		t.Fatalf("setup: scroll = %d, want 5 after a 5-row wheel down", wantScroll)
	}

	for i := 1; i <= 5; i++ {
		m.SetMessagesLen(20 + i*3)
		if m.MessagesCursor != wantCursor {
			t.Fatalf("sample %d moved the cursor: %d, want %d", i, m.MessagesCursor, wantCursor)
		}
		if m.MessagesScroll != wantScroll {
			t.Fatalf("sample %d moved the scroll: %d, want %d", i, m.MessagesScroll, wantScroll)
		}
	}
	if m.PendingMessages != 15 {
		t.Errorf("PendingMessages = %d, want 15 (5 samples of 3)", m.PendingMessages)
	}
}

// TestOrder_PendingCountIncrementsPerAppend restates
// sp032's TestTail_PendingCountIncrementsPerAppend: a sample that appends
// NOTHING leaves the count alone (unchanged, not reset), and the very first
// sample — with no previous length to diff against — lands on a live pane
// and therefore counts nothing.
func TestOrder_PendingCountIncrementsPerAppend(t *testing.T) {
	m := NewModel()
	m.Focus = PaneMessages
	m.SetMessagesViewport(5)

	m.SetMessagesLen(10) // the very first sample
	if m.PendingMessages != 0 {
		t.Fatalf("first sample counted %d pending, want 0", m.PendingMessages)
	}

	m.GoToLast() // jump to the oldest message: no longer live

	m.SetMessagesLen(12)
	if m.PendingMessages != 2 {
		t.Fatalf("after +2: PendingMessages = %d, want 2", m.PendingMessages)
	}
	m.SetMessagesLen(12) // a sample that appends nothing
	if m.PendingMessages != 2 {
		t.Fatalf("an empty sample changed the count: %d, want it still 2", m.PendingMessages)
	}
	m.SetMessagesLen(15)
	if m.PendingMessages != 5 {
		t.Fatalf("after a further +3: PendingMessages = %d, want 5 (accumulated, not replaced)", m.PendingMessages)
	}
}

// TestOrder_HomeReturnsToLiveAndZeroesCount is criterion 4's first half,
// driven through the real key surface for both spellings of Home — the new
// live-return key now that the pane renders newest-first (sp032 pinned this
// same behavior on End/G, at the tail).
func TestOrder_HomeReturnsToLiveAndZeroesCount(t *testing.T) {
	for _, tc := range []struct {
		name string
		key  Key
	}{
		{name: "Home", key: Key{Special: KeyHome}},
		{name: "g", key: Key{Rune: 'g'}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := liveMessagePane(t, 20, 10)
			m.ScrollMessages(5)
			m.SetMessagesLen(26)
			if m.PendingMessages != 6 {
				t.Fatalf("setup: PendingMessages = %d, want 6", m.PendingMessages)
			}

			m.HandleKey(tc.key)

			if m.MessagesCursor != 0 {
				t.Errorf("cursor = %d, want 0 (row 0)", m.MessagesCursor)
			}
			if m.MessagesScroll != 0 {
				t.Errorf("scroll = %d, want 0 (back at the top)", m.MessagesScroll)
			}
			if m.PendingMessages != 0 {
				t.Errorf("PendingMessages = %d, want 0 once the pane is live again", m.PendingMessages)
			}
			// And it is genuinely live again, not merely zeroed.
			m.SetMessagesLen(28)
			if m.MessagesCursor != 0 {
				t.Errorf("after returning to live the pane did not follow: cursor = %d, want 0", m.MessagesCursor)
			}
		})
	}
}

// TestOrder_EndReachesTheOldestAndStaysFrozen is criterion 4's second half:
// End (and its vim spelling G) is no longer the live key now that the pane
// renders newest-first — it reaches the OLDEST row, the far end from live,
// and must not clear whatever count the pane was already carrying.
func TestOrder_EndReachesTheOldestAndStaysFrozen(t *testing.T) {
	for _, tc := range []struct {
		name string
		key  Key
	}{
		{name: "End", key: Key{Special: KeyEnd}},
		{name: "G", key: Key{Rune: 'G'}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := liveMessagePane(t, 20, 10)
			m.ScrollMessages(5)
			m.SetMessagesLen(26)
			if m.PendingMessages != 6 {
				t.Fatalf("setup: PendingMessages = %d, want 6", m.PendingMessages)
			}

			m.HandleKey(tc.key)

			if m.MessagesCursor != 25 {
				t.Errorf("cursor = %d, want 25 (the oldest row)", m.MessagesCursor)
			}
			if m.PendingMessages != 6 {
				t.Errorf("PendingMessages = %d, want 6 — reaching the oldest row is not a return to live", m.PendingMessages)
			}
		})
	}
}

// TestOrder_ClickOnRowZeroReturnsToLive restates sp032's
// TestTail_ClickOnLastRowReturnsToLive: a click that lands on the list's
// row 0 is as much a return to live as Home is. A click on the first
// VISIBLE row of a scrolled-back pane is not, unless that row happens to be
// row 0 itself.
func TestOrder_ClickOnRowZeroReturnsToLive(t *testing.T) {
	m := liveMessagePane(t, 20, 10)
	m.ScrollMessages(5) // window now shows rows 5..14
	m.SetMessagesLen(24)
	if m.PendingMessages != 4 {
		t.Fatalf("setup: PendingMessages = %d, want 4", m.PendingMessages)
	}

	// The first row of the WINDOW (row 5 of 24) is not row 0 of the list, so
	// this must leave the pane frozen and the count intact.
	m.ClickPane(PaneMessages, true, 0)
	if m.PendingMessages != 4 {
		t.Fatalf("a click inside the window zeroed the count: %d, want 4", m.PendingMessages)
	}

	// Scroll to the top and click row 0: live again.
	m.ScrollMessages(-100)
	m.ClickPane(PaneMessages, true, 0)
	if m.MessagesCursor != 0 {
		t.Fatalf("cursor = %d, want 0 (the list's newest row)", m.MessagesCursor)
	}
	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d, want 0 after a click on row 0", m.PendingMessages)
	}
}

// TestOrder_FilterCommitResetsLiveness restates sp032's
// TestTail_FilterCommitResetsLiveness: a committed filter changes the
// list's IDENTITY, so a count of "messages appended since you scrolled
// back" is about a list that no longer exists.
func TestOrder_FilterCommitResetsLiveness(t *testing.T) {
	m := liveMessagePane(t, 20, 10)
	m.ScrollMessages(5)
	m.SetMessagesLen(27)
	if m.PendingMessages != 7 {
		t.Fatalf("setup: PendingMessages = %d, want 7", m.PendingMessages)
	}

	m.HandleKey(Key{Rune: '/'})
	m.HandleKey(Key{Rune: 'a'})
	m.HandleKey(Key{Special: KeyEnter})

	if m.PendingMessages != 0 {
		t.Fatalf("committing a filter left PendingMessages = %d, want 0", m.PendingMessages)
	}

	// The next sample re-evaluates liveness from scratch against the new
	// list rather than resuming the old count.
	m.SetMessagesLen(6)
	if m.PendingMessages != 0 {
		t.Errorf("the filtered sample resurrected a count: %d, want 0", m.PendingMessages)
	}
}

// TestOrder_ListShrinkDoesNotGoNegative is the pruned-bus edge case,
// restating sp032's TestTail_ListShrinkDoesNotGoNegative: a sample SMALLER
// than the last one must not subtract from the count.
func TestOrder_ListShrinkDoesNotGoNegative(t *testing.T) {
	m := liveMessagePane(t, 20, 10)
	m.GoToLast() // cursor on the oldest row: not live
	m.SetMessagesLen(26)
	if m.PendingMessages != 6 {
		t.Fatalf("setup: PendingMessages = %d, want 6", m.PendingMessages)
	}

	m.SetMessagesLen(3) // the bus was pruned hard
	if m.PendingMessages < 0 {
		t.Fatalf("PendingMessages went negative: %d", m.PendingMessages)
	}
	if m.PendingMessages != 6 {
		t.Errorf("a shrink changed the count: %d, want it still 6", m.PendingMessages)
	}

	// Shrinking all the way to empty leaves the pane at its (only) row, so
	// it is live again and the count is zero — not negative.
	m.SetMessagesLen(0)
	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d after the list emptied, want 0", m.PendingMessages)
	}
}

// TestOrder_NoViewportNeverFollowsOrCounts restates sp032's
// TestTail_NoViewportNeverFollowsOrCounts, the --once contract. That path
// reports no viewport at all (renderFrame's height==0 branch), and in that
// legacy regime scroll IS the cursor: nothing follows and nothing is
// counted without a window, at either end.
func TestOrder_NoViewportNeverFollowsOrCounts(t *testing.T) {
	m := NewModel()
	m.Focus = PaneMessages

	m.SetMessagesLen(40)
	if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
		t.Fatalf("cursor/scroll = %d/%d, want 0/0 — no window means no follow", m.MessagesCursor, m.MessagesScroll)
	}
	m.SetMessagesLen(60)
	if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
		t.Errorf("a growing sample moved a windowless pane: cursor/scroll = %d/%d", m.MessagesCursor, m.MessagesScroll)
	}
	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d, want 0 — nothing is frozen without a window", m.PendingMessages)
	}
}

// TestOrder_WheelBackToTheTopReturnsToLive restates sp032's
// TestTail_WheelBackToTheBottomReturnsToLive: LIVE is DERIVED, so ANY way
// back to row 0 thaws the pane — a wheel included — and not only the two
// keys criterion 4 lists.
//
// Reaching that state takes a prune: a wheel does not move the cursor, so
// while the list only GROWS a scrolled-back pane's cursor (pinned at row 0
// while frozen — see TestOrder_FrozenWhenScrolledBack) never falls further
// behind the way the tail's did; what moves is the SCROLL, and only a prune
// that shrinks the list back down closes the gap a partial wheel leaves.
func TestOrder_WheelBackToTheTopReturnsToLive(t *testing.T) {
	m := liveMessagePane(t, 20, 10)
	m.ScrollMessages(6) // frozen with the cursor still on row 0
	m.SetMessagesLen(28)
	if m.PendingMessages != 8 {
		t.Fatalf("setup: PendingMessages = %d, want 8", m.PendingMessages)
	}

	m.SetMessagesLen(20) // the bus pruned back
	if m.PendingMessages != 8 {
		t.Fatalf("setup: the prune changed the count: %d, want 8", m.PendingMessages)
	}
	if m.MessagesScroll != 6 {
		t.Fatalf("setup: scroll = %d, want 6 (still off the top)", m.MessagesScroll)
	}

	// Part way back is still frozen — the scroll is not at the top yet.
	m.ScrollMessages(-3)
	if m.PendingMessages != 8 {
		t.Fatalf("a partial wheel thawed the pane: PendingMessages = %d, want 8", m.PendingMessages)
	}

	m.ScrollMessages(-100)
	if m.MessagesScroll != 0 {
		t.Fatalf("scroll = %d, want 0 (the top)", m.MessagesScroll)
	}
	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d after wheeling back to the top, want 0", m.PendingMessages)
	}

	// And it follows again.
	m.SetMessagesLen(22)
	if m.MessagesCursor != 0 {
		t.Errorf("the pane did not resume following: cursor = %d, want 0", m.MessagesCursor)
	}
}

// TestOrder_CursorUpOntoRowZeroReturnsToLive is the same invariant through
// the other motion that can reach the head: k/up, restating sp032's
// TestTail_CursorDownOntoTheLastRowReturnsToLive. It also demonstrates the
// task's real (not merely cosmetic) simplification at this end: row 0 never
// moves as the list grows, so a frozen cursor's distance back to live is
// fixed at the moment it froze — unlike the tail, where every message that
// arrived while frozen pushed the target one row further away.
func TestOrder_CursorUpOntoRowZeroReturnsToLive(t *testing.T) {
	m := liveMessagePane(t, 20, 10)
	m.moveCursor(3) // cursor 3, frozen
	m.SetMessagesLen(22)
	if m.PendingMessages != 2 {
		t.Fatalf("setup: PendingMessages = %d, want 2", m.PendingMessages)
	}

	for i := 0; i < 5; i++ {
		m.HandleKey(Key{Rune: 'k'})
		if m.MessagesCursor != 0 && m.PendingMessages == 0 {
			t.Fatalf("step %d thawed the pane early at cursor %d: PendingMessages = %d",
				i, m.MessagesCursor, m.PendingMessages)
		}
	}
	if m.MessagesCursor != 0 {
		t.Fatalf("cursor = %d, want 0 (row 0)", m.MessagesCursor)
	}
	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d once the cursor reached row 0, want 0", m.PendingMessages)
	}
}

// TestOrder_ResizeIntoLivenessZeroesTheCount restates sp032's
// TestTail_ResizeIntoLivenessZeroesTheCount: a terminal resize is the last
// motion that can satisfy the live predicate without any input at all.
// SetMessagesViewport re-fits the scroll, and a window tall enough to show
// the whole list puts it at 0 — which IS the top. A pane whose cursor is
// already on row 0 is then live, and a `+N new` it kept carrying would be
// advertising messages that are on screen.
func TestOrder_ResizeIntoLivenessZeroesTheCount(t *testing.T) {
	m := liveMessagePane(t, 20, 10)
	m.ScrollMessages(6)
	m.SetMessagesLen(28)
	m.SetMessagesLen(20) // pruned back: the cursor is still row 0
	if m.PendingMessages != 8 {
		t.Fatalf("setup: PendingMessages = %d, want 8", m.PendingMessages)
	}
	if m.MessagesScroll != 6 {
		t.Fatalf("setup: scroll = %d, want 6 (off the top)", m.MessagesScroll)
	}

	m.SetMessagesViewport(20) // the terminal grew: the whole list fits

	if m.MessagesScroll != 0 {
		t.Fatalf("scroll = %d, want 0 — a list that fits its window has only one offset", m.MessagesScroll)
	}
	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d after the list came fully into view, want 0", m.PendingMessages)
	}
}

// TestRoster_OrderUnchanged is the guard sp033 T6's SRE table calls out by
// name: the order flip and the live-end inversion apply to the MESSAGE pane
// only. FilterRoster returns rows in the order it received them — no
// reorder applied — and GoToLast on the roster still means "the last row":
// there is no live/frozen distinction on that pane for T6 to have inverted.
func TestRoster_OrderUnchanged(t *testing.T) {
	rows := []source.Row{
		{UID: "1", Name: "alpha"},
		{UID: "2", Name: "beta"},
		{UID: "3", Name: "gamma"},
	}
	m := NewModel()
	got := m.FilterRoster(rows)
	if len(got) != len(rows) {
		t.Fatalf("FilterRoster changed the row count: got %d, want %d", len(got), len(rows))
	}
	for i, r := range got {
		if r.UID != rows[i].UID {
			t.Fatalf("FilterRoster reordered rows: got %v, want %v", got, rows)
		}
	}

	m.Focus = PaneRoster
	m.SetRosterViewport(2)
	m.SetRosterLen(len(rows))
	m.GoToLast()
	if m.RosterCursor != len(rows)-1 {
		t.Errorf("RosterCursor = %d after GoToLast, want %d (still the last row — no live end here)", m.RosterCursor, len(rows)-1)
	}
}

// --- sp032 T8 (renamed OpenMessagesAtTail -> OpenMessagesAtHead by sp033
// T6): the message pane opens live -------------------------------------
//
// dotfiles-utob: a session opened showing the wrong end and was not live
// until the operator pressed the live key once, because renderFrame filters
// (and so calls SetMessagesLen) BEFORE it reports this frame's viewports.
// The session's first length therefore lands in the windowless regime,
// where T6's liveness is disabled BY DESIGN — and that design is
// load-bearing, because --once renders in that same regime and must keep
// emitting the whole log from row 0.
//
// So the opening is a separate, explicit motion rather than a loosened
// gate: OpenMessagesAtHead parks the pane on its newest message, and
// REFUSES to do so for a pane with no window. cmd/ performs it once per
// interactive session; nothing performs it on the --once path, which never
// reports a viewport for it to consume in the first place.

// TestStartup_OpenMessagesAtHeadParksOnTheNewest is criteria 1 and 2 at the
// state layer, driven in renderFrame's real call order: the length arrives
// with no window, the viewport arrives second, and the opening follows it.
func TestStartup_OpenMessagesAtHeadParksOnTheNewest(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(20)
	m.SetMessagesViewport(5)
	if m.MessagesCursor != 0 {
		t.Fatalf("setup: cursor = %d, want 0 — the pane has not been opened yet", m.MessagesCursor)
	}

	if !m.OpenMessagesAtHead() {
		t.Fatalf("OpenMessagesAtHead refused a pane with a 5-row window")
	}

	if m.MessagesCursor != 0 {
		t.Errorf("cursor = %d, want 0 (the newest message)", m.MessagesCursor)
	}
	if m.MessagesScroll != 0 {
		t.Errorf("scroll = %d, want 0 (the top)", m.MessagesScroll)
	}
	if !m.messagesLive() {
		t.Errorf("a pane opened at its head is not live")
	}
	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d, want 0 — a pane that opens live is not also behind", m.PendingMessages)
	}
}

// TestStartup_OpenRefusedWithNoWindow is criterion 3 at the state layer: a
// windowless pane must never be touched, since --once renders in that same
// regime and must keep emitting the whole log from row 0.
func TestStartup_OpenRefusedWithNoWindow(t *testing.T) {
	m := NewModel()
	m.SetMessagesLen(20)

	if m.OpenMessagesAtHead() {
		t.Fatalf("OpenMessagesAtHead opened a pane with no window — that is the --once regime")
	}
	if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
		t.Errorf("cursor/scroll = %d/%d, want 0/0 — a windowless pane renders from row 0",
			m.MessagesCursor, m.MessagesScroll)
	}
	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d, want 0 with no window", m.PendingMessages)
	}

	// And a zero-row window is the same regime, not a smaller one: a
	// terminal too short for a single data row must leave the opening for
	// the resize that gives the pane a row.
	m.SetMessagesViewport(0)
	if m.OpenMessagesAtHead() {
		t.Fatalf("OpenMessagesAtHead opened a pane whose window is 0 rows")
	}
	if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
		t.Errorf("cursor/scroll = %d/%d after a 0-row window, want 0/0", m.MessagesCursor, m.MessagesScroll)
	}

	m.SetMessagesViewport(1)
	if !m.OpenMessagesAtHead() {
		t.Fatalf("OpenMessagesAtHead refused a pane with a 1-row window")
	}
	if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
		t.Errorf("cursor/scroll = %d/%d in a 1-row window, want 0/0 (the newest message, alone on screen)",
			m.MessagesCursor, m.MessagesScroll)
	}
}

// TestStartup_OpeningTouchesNothingButTheMessagePane is criterion 5 at the
// state layer: the roster has no newest row to be live on, so it opens
// where it always did. Asserted as a whole-model comparison, so the
// opening cannot quietly move the roster, the focus, the filter or the
// detail pane either. MessagesCursor/Scroll are seeded away from row 0
// first so the opening has visible work to do.
func TestStartup_OpeningTouchesNothingButTheMessagePane(t *testing.T) {
	m := NewModel()
	m.SetRosterLen(40)
	m.SetMessagesLen(20)
	m.SetRosterViewport(5)
	m.SetMessagesViewport(5)
	m.MessagesCursor, m.MessagesScroll = 5, 3

	before := *m
	want := before
	want.MessagesCursor = 0
	want.MessagesScroll = 0

	m.OpenMessagesAtHead()

	if *m != want {
		t.Errorf("the opening changed more than the message pane's position:\n got %+v\nwant %+v", *m, want)
	}
	if m.RosterCursor != 0 || m.RosterScroll != 0 {
		t.Errorf("the roster opened at %d/%d (cursor/scroll), want 0/0 — the first row", m.RosterCursor, m.RosterScroll)
	}
}

// TestStartup_EmptyAndSingleMessageLogs covers the two degenerate first
// samples. For both, the head IS index 0 (as the tail also was, at these
// lengths) — so the assertion that matters is the one after it: an opened
// pane is LIVE, and follows the next sample by staying at row 0 rather than
// advancing onto a moving tail.
func TestStartup_EmptyAndSingleMessageLogs(t *testing.T) {
	for _, n := range []int{0, 1} {
		m := NewModel()
		m.SetMessagesLen(n)
		m.SetMessagesViewport(5)
		if !m.OpenMessagesAtHead() {
			t.Fatalf("n=%d: OpenMessagesAtHead refused", n)
		}
		if m.MessagesCursor != 0 || m.MessagesScroll != 0 {
			t.Errorf("n=%d: cursor/scroll = %d/%d, want 0/0", n, m.MessagesCursor, m.MessagesScroll)
		}
		if m.PendingMessages != 0 {
			t.Errorf("n=%d: PendingMessages = %d, want 0", n, m.PendingMessages)
		}

		m.SetMessagesLen(n + 6) // the bus fills up
		if m.MessagesCursor != 0 {
			t.Errorf("n=%d: the opened pane did not follow the next sample: cursor = %d, want 0", n, m.MessagesCursor)
		}
		if m.PendingMessages != 0 {
			t.Errorf("n=%d: PendingMessages = %d after following, want 0", n, m.PendingMessages)
		}
	}
}

// TestStartup_OpeningClearsAPendingCountItInherits is the invariant "a live
// pane is never behind", applied to the one motion that had no
// clearPendingWhenLive before sp032 T8 existed.
func TestStartup_OpeningClearsAPendingCountItInherits(t *testing.T) {
	m := NewModel()
	m.SetMessagesViewport(5)
	m.SetMessagesLen(20)
	m.ScrollMessages(9)
	m.SetMessagesLen(24)
	if m.PendingMessages == 0 {
		t.Fatalf("setup: PendingMessages = 0, want a frozen pane carrying a count")
	}

	m.OpenMessagesAtHead()

	if m.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d after the pane was opened at its head, want 0", m.PendingMessages)
	}
}

// sp033 T8: the composer, as a mode on the pure model. OpenComposer takes
// the recipient address directly (the shape cmd/ will supply it in, once
// T9/T10 wire `r` up to it) rather than a message — Model holds no message
// data, the same reason SetDetailSelection takes an opaque identity string
// rather than a source.Message.

// TestComposer_OpensBoundToTheSelectedAddress is criterion 1: a successful
// open records ComposeTo from the address handed in, at open time.
func TestComposer_OpensBoundToTheSelectedAddress(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true

	ok, reason := m.OpenComposer("peer-3-address")
	if !ok {
		t.Fatalf("expected OpenComposer to succeed, got refused: %q", reason)
	}
	if !m.Composing {
		t.Fatalf("expected Composing true after a successful open")
	}
	if m.ComposeTo != "peer-3-address" {
		t.Fatalf("expected ComposeTo %q, got %q", "peer-3-address", m.ComposeTo)
	}
}

// TestComposer_NoMessageSelectedDoesNotOpen is criterion 6's first case: an
// empty address (cmd/'s spelling of "nothing is selected") refuses, and says
// why rather than opening silently or panicking.
func TestComposer_NoMessageSelectedDoesNotOpen(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true

	ok, reason := m.OpenComposer("")
	if ok {
		t.Fatalf("expected OpenComposer to refuse with no address")
	}
	if reason == "" {
		t.Fatalf("expected a reason for the refusal, got empty string")
	}
	if m.Composing {
		t.Fatalf("expected Composing to stay false on refusal")
	}
}

// TestComposer_NoIdentityDoesNotOpen is criterion 6's second case: an
// unregistered monitor (HasIdentity false, NewModel's default) has no FROM
// to reply as, so `r` must refuse even with a message selected.
func TestComposer_NoIdentityDoesNotOpen(t *testing.T) {
	m := NewModel()

	ok, reason := m.OpenComposer("peer-3-address")
	if ok {
		t.Fatalf("expected OpenComposer to refuse with no identity")
	}
	if reason == "" {
		t.Fatalf("expected a reason for the refusal, got empty string")
	}
	if m.Composing {
		t.Fatalf("expected Composing to stay false on refusal")
	}
}

// TestComposer_RunesAreTextNotCommands is criterion 2: q, d, / and G are
// text while composing, exactly as they are in a filter draft. Committing
// via ctrl+s and reading the yielded body is the only way to observe the
// draft from outside the package, matching how filter tests read
// m.Filter.Query rather than the unexported draft field.
func TestComposer_RunesAreTextNotCommands(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true
	m.OpenComposer("peer-3-address")

	for _, r := range "qd/G" {
		out := m.HandleKey(Key{Rune: r})
		if out.Quit || out.ForceRefresh {
			t.Fatalf("rune %q while composing must not quit or force-refresh, got %+v", r, out)
		}
	}
	if !m.Composing {
		t.Fatalf("typing q/d/G must not close the composer")
	}

	out := m.HandleKey(Key{Rune: 0x13}) // ctrl+s
	if out.Send == nil {
		t.Fatalf("expected a Send outcome from ctrl+s")
	}
	if out.Send.Body != "qd/G" {
		t.Fatalf("expected draft %q, got %q", "qd/G", out.Send.Body)
	}
}

// TestComposer_EnterInsertsNewline is criterion 2's second half: enter must
// not commit (that is ctrl+s's job), it inserts a newline into a multi-line
// draft.
func TestComposer_EnterInsertsNewline(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true
	m.OpenComposer("peer-3-address")

	for _, r := range "line1" {
		m.HandleKey(Key{Rune: r})
	}
	out := m.HandleKey(Key{Special: KeyEnter})
	if out.Send != nil {
		t.Fatalf("enter must not commit the draft, got Send %+v", out.Send)
	}
	if !m.Composing {
		t.Fatalf("enter must not close the composer")
	}
	for _, r := range "line2" {
		m.HandleKey(Key{Rune: r})
	}

	out = m.HandleKey(Key{Rune: 0x13}) // ctrl+s
	if out.Send == nil {
		t.Fatalf("expected a Send outcome from ctrl+s")
	}
	if want := "line1\nline2"; out.Send.Body != want {
		t.Fatalf("expected draft %q, got %q", want, out.Send.Body)
	}
}

// TestComposer_EscAbandonsDraft is criterion 3's first half: esc closes and
// drops the draft, yielding nothing.
func TestComposer_EscAbandonsDraft(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true
	m.OpenComposer("peer-3-address")
	for _, r := range "never sent" {
		m.HandleKey(Key{Rune: r})
	}

	out := m.HandleKey(Key{Special: KeyEsc})
	if out.Send != nil {
		t.Fatalf("esc must not yield a Send outcome, got %+v", out.Send)
	}
	if m.Composing {
		t.Fatalf("expected Composing false after esc")
	}
	if m.ComposeTo != "" {
		t.Fatalf("expected ComposeTo cleared after esc, got %q", m.ComposeTo)
	}

	// The abandoned draft must not resurface in the next reply.
	m.OpenComposer("peer-3-address")
	out = m.HandleKey(Key{Rune: 0x13})
	if out.Send != nil {
		t.Fatalf("expected the fresh composer to start with an empty draft, got Send %+v", out.Send)
	}
}

// TestComposer_CtrlSYieldsDraftAndCloses is criterion 3's second half: ctrl+s
// on a non-empty draft closes the composer and hands the caller a
// SendRequest carrying the address bound at open time and the full body.
func TestComposer_CtrlSYieldsDraftAndCloses(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true
	m.OpenComposer("peer-3-address")
	for _, r := range "hello" {
		m.HandleKey(Key{Rune: r})
	}

	out := m.HandleKey(Key{Rune: 0x13})
	if out.Send == nil {
		t.Fatalf("expected a Send outcome from ctrl+s")
	}
	if out.Send.To != "peer-3-address" {
		t.Fatalf("expected To %q, got %q", "peer-3-address", out.Send.To)
	}
	if out.Send.Body != "hello" {
		t.Fatalf("expected Body %q, got %q", "hello", out.Send.Body)
	}
	if m.Composing {
		t.Fatalf("expected Composing false after ctrl+s")
	}
	if m.ComposeTo != "" {
		t.Fatalf("expected ComposeTo cleared after ctrl+s, got %q", m.ComposeTo)
	}
}

// TestComposer_EmptyDraftIsANoOp is criterion 5: ctrl+s on an empty or
// whitespace-only draft neither yields a Send nor closes the composer, so
// nothing is dispatched and the operator's cursor stays where they left it.
func TestComposer_EmptyDraftIsANoOp(t *testing.T) {
	for _, draft := range []string{"", "   ", "\n\t "} {
		m := NewModel()
		m.HasIdentity = true
		m.OpenComposer("peer-3-address")
		for _, r := range draft {
			m.HandleKey(Key{Rune: r})
		}

		out := m.HandleKey(Key{Rune: 0x13})
		if out.Send != nil {
			t.Fatalf("draft %q: expected no Send outcome, got %+v", draft, out.Send)
		}
		if !m.Composing {
			t.Fatalf("draft %q: expected the composer to stay open", draft)
		}
	}
}

// TestComposer_RecipientSurvivesASampleThatMovesTheList is criterion 1's
// safety property exercised directly: once open, nothing that moves the
// message pane's cursor or grows its sample changes ComposeTo, because
// commitCompose never re-reads the selection — it reads the address
// OpenComposer captured. This is the case that fails any implementation
// that reads the selection at send time instead.
func TestComposer_RecipientSurvivesASampleThatMovesTheList(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true
	m.Focus = PaneMessages
	m.SetMessagesViewport(5)
	m.SetMessagesLen(3)
	m.MessagesCursor = 1 // the operator is replying to the row at index 1

	ok, _ := m.OpenComposer("original-recipient-address")
	if !ok {
		t.Fatalf("setup: OpenComposer refused")
	}

	// A sample arrives mid-draft and reorders/grows the list under the
	// cursor — exactly what a live bus does between keystrokes.
	m.SetMessagesLen(10)
	m.MessagesCursor = 7

	for _, r := range "reply text" {
		m.HandleKey(Key{Rune: r})
	}
	out := m.HandleKey(Key{Rune: 0x13})
	if out.Send == nil {
		t.Fatalf("expected a Send outcome")
	}
	if out.Send.To != "original-recipient-address" {
		t.Fatalf("expected the reply to stay addressed to %q despite the list moving, got %q",
			"original-recipient-address", out.Send.To)
	}
}

// TestComposer_PagingKeysSwallowed is criterion 4: PgUp/PgDn/Home/End are
// swallowed outright while composing — named explicitly rather than left to
// the default arm ([[sp032]] T5's rule) — so they neither move a pane out
// from under the open draft nor leak into it as text.
func TestComposer_PagingKeysSwallowed(t *testing.T) {
	for _, k := range []Key{
		{Special: KeyPgUp}, {Special: KeyPgDn}, {Special: KeyHome}, {Special: KeyEnd},
	} {
		m := NewModel()
		m.HasIdentity = true
		m.Focus = PaneMessages
		m.SetMessagesViewport(5)
		m.SetMessagesLen(10)
		m.MessagesCursor = 4
		m.OpenComposer("peer-3-address")
		beforeCursor := m.MessagesCursor
		beforeScroll := m.MessagesScroll

		out := m.HandleKey(k)
		if out.Quit || out.ForceRefresh || out.Send != nil {
			t.Fatalf("key %+v while composing must be swallowed, got Outcome %+v", k, out)
		}
		if !m.Composing {
			t.Fatalf("key %+v must not close the composer", k)
		}
		if m.MessagesCursor != beforeCursor || m.MessagesScroll != beforeScroll {
			t.Fatalf("key %+v must not move the message pane while composing: cursor %d->%d, scroll %d->%d",
				k, beforeCursor, m.MessagesCursor, beforeScroll, m.MessagesScroll)
		}

		out = m.HandleKey(Key{Rune: 0x13})
		if out.Send != nil {
			t.Fatalf("key %+v must not have written into the draft: ctrl+s on an untouched draft must stay a no-op, got Send %+v", k, out.Send)
		}
	}
}

// TestComposer_UnicodeAndWideRunes is the edge case named in ## edge_cases:
// the draft must accumulate and yield multi-byte runes exactly, the same
// guarantee the filter draft already has via []rune-based Backspace.
func TestComposer_UnicodeAndWideRunes(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true
	m.OpenComposer("peer-3-address")

	for _, r := range "héllo 世界 🎉" {
		m.HandleKey(Key{Rune: r})
	}
	m.HandleKey(Key{Special: KeyBackspace}) // drop the trailing emoji

	out := m.HandleKey(Key{Rune: 0x13})
	if out.Send == nil {
		t.Fatalf("expected a Send outcome")
	}
	if want := "héllo 世界 "; out.Send.Body != want {
		t.Fatalf("expected draft %q, got %q", want, out.Send.Body)
	}
}

// TestComposer_ReplyToOwnMessage is an edge case named in ## edge_cases: the
// composer has no concept of "your own message" — it only ever sees the
// address it was handed, so replying to your own from_address is
// unremarkable at this layer (any policy about it belongs elsewhere).
func TestComposer_ReplyToOwnMessage(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true

	ok, reason := m.OpenComposer("my-own-address")
	if !ok {
		t.Fatalf("expected OpenComposer to succeed, got refused: %q", reason)
	}
	if m.ComposeTo != "my-own-address" {
		t.Fatalf("expected ComposeTo %q, got %q", "my-own-address", m.ComposeTo)
	}
}

// --- sp033 T7: the for-you count -------------------------------------------

// TestForYou_CountAndPendingAreIndependent is the test plan's named case: on
// a frozen (not-live) pane, a sample that appends rows where only SOME are
// for-you must grow PendingMessages by the total and ForYouCount by the
// for-you subset — two different numbers from the same tick, neither
// derived from the other. A second, LIVE pane in the same test proves the
// same call zeroes both counters identically, so "independent" doesn't
// silently mean "the live case never got exercised".
func TestForYou_CountAndPendingAreIndependent(t *testing.T) {
	frozen := liveMessagePane(t, 20, 10)
	frozen.ScrollMessages(5) // no longer live
	frozen.SetMessagesLen(23)
	frozen.AddForYouArrivals(1) // of the 3 new rows, 1 was for-you

	if frozen.PendingMessages != 3 {
		t.Fatalf("PendingMessages = %d, want 3 (every new row)", frozen.PendingMessages)
	}
	if frozen.ForYouCount != 1 {
		t.Fatalf("ForYouCount = %d, want 1 (only the for-you subset)", frozen.ForYouCount)
	}

	// Accumulates across ticks independently, same as PendingMessages.
	frozen.SetMessagesLen(25)
	frozen.AddForYouArrivals(0) // neither of the 2 new rows was for-you
	if frozen.PendingMessages != 5 {
		t.Fatalf("PendingMessages = %d, want 5 (accumulated)", frozen.PendingMessages)
	}
	if frozen.ForYouCount != 1 {
		t.Fatalf("ForYouCount = %d, want 1 (unchanged — nothing new was for-you)", frozen.ForYouCount)
	}

	live := liveMessagePane(t, 20, 10)
	live.SetMessagesLen(23)
	live.AddForYouArrivals(2) // a live pane reads zero regardless of n
	if live.PendingMessages != 0 {
		t.Fatalf("live PendingMessages = %d, want 0", live.PendingMessages)
	}
	if live.ForYouCount != 0 {
		t.Fatalf("live ForYouCount = %d, want 0 — a live pane is never behind", live.ForYouCount)
	}
}

// TestForYou_ReturnToLiveZeroesTheCount restates
// TestOrder_HomeReturnsToLiveAndZeroesCount for ForYouCount: the same
// return-to-live that zeroes PendingMessages zeroes its twin, since both go
// through clearPendingWhenLive.
func TestForYou_ReturnToLiveZeroesTheCount(t *testing.T) {
	m := liveMessagePane(t, 20, 10)
	m.ScrollMessages(5)
	m.SetMessagesLen(26)
	m.AddForYouArrivals(2)
	if m.ForYouCount != 2 {
		t.Fatalf("setup: ForYouCount = %d, want 2", m.ForYouCount)
	}

	m.HandleKey(Key{Special: KeyHome})

	if m.ForYouCount != 0 {
		t.Errorf("ForYouCount = %d, want 0 once the pane is live again", m.ForYouCount)
	}
}

// TestForYou_FilterCommitResetsTheCount restates
// TestOrder_FilterCommitResetsLiveness for ForYouCount: committing a filter
// changes the message list's IDENTITY (sp032 T6 criterion 5), so a stale
// for-you count is exactly as wrong as a stale PendingMessages one — a
// filtered-out for-you row must not keep being counted (## edge_cases).
// This is a DIRECT ASSIGNMENT site in handleEditingKey's KeyEnter arm, not
// one that goes through clearPendingWhenLive, which is why it needs its own
// case rather than being covered by TestForYou_ReturnToLiveZeroesTheCount.
func TestForYou_FilterCommitResetsTheCount(t *testing.T) {
	m := liveMessagePane(t, 20, 10)
	m.ScrollMessages(5)
	m.SetMessagesLen(27)
	m.AddForYouArrivals(4)
	if m.ForYouCount != 4 {
		t.Fatalf("setup: ForYouCount = %d, want 4", m.ForYouCount)
	}

	m.HandleKey(Key{Rune: '/'})
	m.HandleKey(Key{Rune: 'a'})
	m.HandleKey(Key{Special: KeyEnter})

	if m.ForYouCount != 0 {
		t.Fatalf("committing a filter left ForYouCount = %d, want 0 (stale count survives filter change)", m.ForYouCount)
	}

	// The next sample re-evaluates from scratch against the new list rather
	// than resuming the old count.
	m.SetMessagesLen(6)
	m.AddForYouArrivals(0)
	if m.ForYouCount != 0 {
		t.Errorf("the filtered sample resurrected a count: %d, want 0", m.ForYouCount)
	}
}

// TestComposer_ComposeDraftExposesTypedText is sp033 T10: the composer's
// on-screen region (cmd/) needs to read back what the operator has typed,
// and composeDraft is otherwise unexported exactly like the filter's draft.
func TestComposer_ComposeDraftExposesTypedText(t *testing.T) {
	m := NewModel()
	m.HasIdentity = true
	m.OpenComposer("peer-3-address")

	if got := m.ComposeDraft(); got != "" {
		t.Fatalf("got ComposeDraft() %q on a freshly opened composer, want empty", got)
	}
	for _, r := range "hi" {
		m.HandleKey(Key{Rune: r})
	}
	if got := m.ComposeDraft(); got != "hi" {
		t.Fatalf("got ComposeDraft() %q, want %q", got, "hi")
	}
}
