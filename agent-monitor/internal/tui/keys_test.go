package tui

import (
	"sync"
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

func TestDecoder_ArrowsAndControls(t *testing.T) {
	cases := []struct {
		name  string
		bytes []byte
		want  Key
	}{
		{"up", []byte{0x1b, '[', 'A'}, Key{Special: KeyUp}},
		{"down", []byte{0x1b, '[', 'B'}, Key{Special: KeyDown}},
		{"right", []byte{0x1b, '[', 'C'}, Key{Special: KeyRight}},
		{"left", []byte{0x1b, '[', 'D'}, Key{Special: KeyLeft}},
		{"enter-cr", []byte{'\r'}, Key{Special: KeyEnter}},
		{"enter-lf", []byte{'\n'}, Key{Special: KeyEnter}},
		{"backspace-del", []byte{0x7f}, Key{Special: KeyBackspace}},
		{"tab", []byte{'\t'}, Key{Special: KeyTab}},
		{"rune", []byte{'q'}, Key{Rune: 'q'}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := &Decoder{}
			var got Key
			var ok bool
			for _, b := range c.bytes {
				got, ok = d.Feed(b)
			}
			if !ok {
				t.Fatalf("expected a decoded key after feeding %v", c.bytes)
			}
			if got != c.want {
				t.Fatalf("got %+v, want %+v", got, c.want)
			}
		})
	}
}

func TestDecoder_BareEscThenRuneDropsEscAndDecodesTheRune(t *testing.T) {
	d := &Decoder{}
	if _, ok := d.Feed(0x1b); ok {
		t.Fatalf("a lone ESC byte must not resolve to a key until the next byte disambiguates it")
	}
	got, ok := d.Feed('q')
	if !ok {
		t.Fatalf("expected the follow-up byte to decode")
	}
	if got != (Key{Rune: 'q'}) {
		t.Fatalf("expected the buffered ESC dropped and 'q' decoded plainly, got %+v", got)
	}
}

func TestRestorer_RunsExactlyOnceAcrossMultipleDirectCalls(t *testing.T) {
	calls := 0
	r := NewRestorer(func() { calls++ })
	r.Restore()
	r.Restore()
	r.Restore()
	if calls != 1 {
		t.Fatalf("expected restore to run exactly once, ran %d times", calls)
	}
}

func TestRestorer_GuardRestoresOnNormalReturn(t *testing.T) {
	calls := 0
	r := NewRestorer(func() { calls++ })
	r.Guard(func() {})
	if calls != 1 {
		t.Fatalf("expected 1 restore after a normal return, got %d", calls)
	}
}

// TestRestorer_GuardRestoresExactlyOnceOnPanic is the pinned proof for "a
// panic in a render path must still restore the terminal": Guard's deferred
// Restore must fire during the panicking goroutine's own unwind, exactly
// once, before the recover below lets the test continue.
func TestRestorer_GuardRestoresExactlyOnceOnPanic(t *testing.T) {
	calls := 0
	r := NewRestorer(func() { calls++ })
	func() {
		defer func() { _ = recover() }()
		r.Guard(func() { panic("simulated render panic") })
	}()
	if calls != 1 {
		t.Fatalf("expected restore to run exactly once after a panic, got %d", calls)
	}
}

// TestRestorer_ConcurrentNormalAndPanickingGoroutines_RestoresExactlyOnce
// simulates agent-monitor's actual shape: a normal exit path (e.g. `q` on
// the main goroutine) racing a panic in a background sampler's render
// callback. Whichever gets there first, the underlying restore callback
// must run exactly once — never zero, never twice.
func TestRestorer_ConcurrentNormalAndPanickingGoroutines_RestoresExactlyOnce(t *testing.T) {
	var mu sync.Mutex
	calls := 0
	r := NewRestorer(func() {
		mu.Lock()
		calls++
		mu.Unlock()
	})

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		r.Guard(func() {})
	}()
	go func() {
		defer wg.Done()
		defer func() { _ = recover() }()
		r.Guard(func() { panic("boom") })
	}()
	wg.Wait()

	mu.Lock()
	defer mu.Unlock()
	if calls != 1 {
		t.Fatalf("expected exactly one restore across both goroutines, got %d", calls)
	}
}
