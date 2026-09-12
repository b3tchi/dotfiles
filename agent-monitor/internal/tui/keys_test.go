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
