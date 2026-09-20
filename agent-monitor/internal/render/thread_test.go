package render

import (
	"encoding/json"
	"reflect"
	"testing"

	"agent-monitor/internal/source"
)

func msg(at, id, from string, to []string, fromAddr string, toAddrs []string) source.Message {
	return source.Message{
		At:          at,
		ID:          id,
		From:        from,
		To:          to,
		Kind:        "message",
		Content:     json.RawMessage(`"x"`),
		FromAddress: fromAddr,
		ToAddresses: toAddrs,
	}
}

// TestThreads_LabelCollisionDoesNotMerge is the adr0034 regression: two
// envelopes render identical From/To labels but carry different addresses,
// so they must land in two threads, not one. Any label-keyed implementation
// fails this.
func TestThreads_LabelCollisionDoesNotMerge(t *testing.T) {
	m1 := msg("2026-09-12T12:00:00Z", "a1", "operator", []string{"agent"}, "aFROMADDR000000000000000001", []string{"aTOADDR0000000000000000001"})
	m2 := msg("2026-09-12T12:01:00Z", "a2", "operator", []string{"agent"}, "aFROMADDR000000000000000002", []string{"aTOADDR0000000000000000002"})

	threads := Threads([]source.Message{m1, m2})

	if len(threads) != 2 {
		t.Fatalf("got %d threads, want 2: %+v", len(threads), threads)
	}
	if threads[0].Key == threads[1].Key {
		t.Fatalf("threads share key %q despite different addresses", threads[0].Key)
	}
}

// TestThreads_DirectionDoesNotSplit asserts a<->b and b<->a share one key --
// the sort over the composite is the whole point.
func TestThreads_DirectionDoesNotSplit(t *testing.T) {
	a := "aAAAAAAAAAAAAAAAAAAAAAAAAAA1"
	b := "aBBBBBBBBBBBBBBBBBBBBBBBBBB1"
	m1 := msg("2026-09-12T12:00:00Z", "a1", "alice", []string{"bob"}, a, []string{b})
	m2 := msg("2026-09-12T12:01:00Z", "a2", "bob", []string{"alice"}, b, []string{a})

	threads := Threads([]source.Message{m1, m2})

	if len(threads) != 1 {
		t.Fatalf("got %d threads, want 1: %+v", len(threads), threads)
	}
	if threads[0].Count != 2 {
		t.Fatalf("got count %d, want 2", threads[0].Count)
	}
}

// TestThreads_MultiRecipientIsItsOwnThread asserts {a->b}, {a->c} and
// {a->b,c} form three distinct threads -- a broadcast never folds into
// either of its 2-party sub-conversations.
func TestThreads_MultiRecipientIsItsOwnThread(t *testing.T) {
	a := "aAAAAAAAAAAAAAAAAAAAAAAAAAA1"
	b := "aBBBBBBBBBBBBBBBBBBBBBBBBBB1"
	c := "aCCCCCCCCCCCCCCCCCCCCCCCCCC1"

	toB := msg("2026-09-12T12:00:00Z", "a1", "alice", []string{"bob"}, a, []string{b})
	toC := msg("2026-09-12T12:01:00Z", "a2", "alice", []string{"carol"}, a, []string{c})
	toBoth := msg("2026-09-12T12:02:00Z", "a3", "alice", []string{"bob", "carol"}, a, []string{b, c})

	threads := Threads([]source.Message{toB, toC, toBoth})

	if len(threads) != 3 {
		t.Fatalf("got %d threads, want 3: %+v", len(threads), threads)
	}
	keys := map[string]bool{}
	for _, th := range threads {
		if keys[th.Key] {
			t.Fatalf("duplicate key %q", th.Key)
		}
		keys[th.Key] = true
	}
}

// TestThreads_OrderIsNewestFirstAndTotal shuffles the input and asserts the
// exact thread order, each thread's own internal order, and that repeated
// derivations over the same input are byte-identical.
func TestThreads_OrderIsNewestFirstAndTotal(t *testing.T) {
	a := "aAAAAAAAAAAAAAAAAAAAAAAAAAA1"
	b := "aBBBBBBBBBBBBBBBBBBBBBBBBBB1"
	c := "aCCCCCCCCCCCCCCCCCCCCCCCCCC1"

	// Thread AB: two messages. Thread AC: one message, newer than both AB
	// messages.
	ab1 := msg("2026-09-12T12:00:00Z", "a1", "alice", []string{"bob"}, a, []string{b})
	ab2 := msg("2026-09-12T12:01:00Z", "a2", "bob", []string{"alice"}, b, []string{a})
	ac1 := msg("2026-09-12T12:02:00Z", "a3", "alice", []string{"carol"}, a, []string{c})

	shuffled := []source.Message{ab2, ac1, ab1}

	threads1 := Threads(shuffled)
	threads2 := Threads(shuffled)

	if !reflect.DeepEqual(threads1, threads2) {
		t.Fatalf("Threads is not deterministic:\n%+v\n%+v", threads1, threads2)
	}

	if len(threads1) != 2 {
		t.Fatalf("got %d threads, want 2: %+v", len(threads1), threads1)
	}
	// AC thread (newest member ac1) must sort before AB thread.
	if threads1[0].Messages[0].ID != "a3" {
		t.Fatalf("thread order wrong: first thread's newest = %q, want a3", threads1[0].Messages[0].ID)
	}
	// AB thread's own messages must be newest-first: ab2 (a2) then ab1 (a1).
	ab := threads1[1]
	if len(ab.Messages) != 2 || ab.Messages[0].ID != "a2" || ab.Messages[1].ID != "a1" {
		t.Fatalf("AB thread internal order wrong: %+v", ab.Messages)
	}
}

// TestThreads_ParticipantLabelsFallBackToElidedAddress asserts that when a
// message's To and ToAddresses slices differ in length, no positional
// pairing is trusted for that message -- addresses with no other source of
// a label render through shortAddress, never a wrong label.
func TestThreads_ParticipantLabelsFallBackToElidedAddress(t *testing.T) {
	a := "aAAAAAAAAAAAAAAAAAAAAAAAAAA1"
	b := "aBBBBBBBBBBBBBBBBBBBBBBBBBB1"
	c := "aCCCCCCCCCCCCCCCCCCCCCCCCCC1"

	// To has 1 label but ToAddresses has 2 -- mismatched lengths.
	m := msg("2026-09-12T12:00:00Z", "a1", "alice", []string{"bob"}, a, []string{b, c})

	threads := Threads([]source.Message{m})
	if len(threads) != 1 {
		t.Fatalf("got %d threads, want 1", len(threads))
	}
	th := threads[0]

	wantFrom := "alice"
	wantB := shortAddress(b)
	wantC := shortAddress(c)

	got := map[string]bool{}
	for _, p := range th.Participants {
		got[p] = true
	}
	if !got[wantFrom] {
		t.Errorf("participants %v missing resolved From label %q", th.Participants, wantFrom)
	}
	if !got[wantB] {
		t.Errorf("participants %v missing elided address %q for b", th.Participants, wantB)
	}
	if !got[wantC] {
		t.Errorf("participants %v missing elided address %q for c", th.Participants, wantC)
	}
	if got["bob"] {
		t.Errorf("participants %v must not contain the mismatched label %q", th.Participants, "bob")
	}
}

// TestThreads_InputNotMutated asserts Threads leaves the caller's slice
// untouched: same order, same contents, after the call. The fixture is
// deliberately OLDEST-first (m1 older than m2) -- Threads' own output order
// is newest-first, so an in-place newest-first sort of the caller's slice
// would flip this fixture and get caught, where a newest-first fixture
// would let that exact mutation hide behind a no-op sort.
func TestThreads_InputNotMutated(t *testing.T) {
	a := "aAAAAAAAAAAAAAAAAAAAAAAAAAA1"
	b := "aBBBBBBBBBBBBBBBBBBBBBBBBBB1"
	m1 := msg("2026-09-12T12:00:00Z", "a1", "alice", []string{"bob"}, a, []string{b})
	m2 := msg("2026-09-12T12:01:00Z", "a2", "bob", []string{"alice"}, b, []string{a})

	input := []source.Message{m1, m2}
	want := []source.Message{m1, m2}

	_ = Threads(input)

	if !reflect.DeepEqual(input, want) {
		t.Fatalf("Threads mutated its input:\ngot  %+v\nwant %+v", input, want)
	}
}

// TestThreads_EmptyInputReturnsEmptyNonNilSlice is the empty-bus edge case:
// no envelopes yields an empty, non-nil slice, matching ParseMessages' own
// empty-bus contract.
func TestThreads_EmptyInputReturnsEmptyNonNilSlice(t *testing.T) {
	threads := Threads([]source.Message{})
	if threads == nil {
		t.Fatal("Threads(nil-ish empty input) returned nil, want empty non-nil slice")
	}
	if len(threads) != 0 {
		t.Fatalf("got %d threads, want 0", len(threads))
	}
}

// TestThreads_PreAddressPayloadFormsItsOwnThread covers a pre-sp033-T1
// envelope: empty FromAddress and empty ToAddresses key on the empty
// composite and form their own thread rather than being dropped.
func TestThreads_PreAddressPayloadFormsItsOwnThread(t *testing.T) {
	m1 := msg("2026-09-12T12:00:00Z", "a1", "old-agent", []string{"old-peer"}, "", nil)
	m2 := msg("2026-09-12T12:01:00Z", "a2", "old-peer", []string{"old-agent"}, "", nil)

	threads := Threads([]source.Message{m1, m2})
	if len(threads) != 1 {
		t.Fatalf("got %d threads, want 1: %+v", len(threads), threads)
	}
	if threads[0].Key != "" {
		t.Fatalf("got key %q, want empty composite", threads[0].Key)
	}
	if threads[0].Count != 2 {
		t.Fatalf("got count %d, want 2", threads[0].Count)
	}
}

// TestThreads_SelfAddressedYieldsOneParticipantKey asserts from == to
// dedupes to a single-address key rather than a duplicated composite.
func TestThreads_SelfAddressedYieldsOneParticipantKey(t *testing.T) {
	a := "aAAAAAAAAAAAAAAAAAAAAAAAAAA1"
	m := msg("2026-09-12T12:00:00Z", "a1", "alice", []string{"alice"}, a, []string{a})

	threads := Threads([]source.Message{m})
	if len(threads) != 1 {
		t.Fatalf("got %d threads, want 1", len(threads))
	}
	if threads[0].Key != a {
		t.Fatalf("got key %q, want %q (single address, not duplicated)", threads[0].Key, a)
	}
}

// TestThreads_TiesOnAtResolveByIDDescending pins the total-order tiebreak:
// two messages sharing At order by ID descending.
func TestThreads_TiesOnAtResolveByIDDescending(t *testing.T) {
	a := "aAAAAAAAAAAAAAAAAAAAAAAAAAA1"
	b := "aBBBBBBBBBBBBBBBBBBBBBBBBBB1"
	m1 := msg("2026-09-12T12:00:00Z", "a1", "alice", []string{"bob"}, a, []string{b})
	m2 := msg("2026-09-12T12:00:00Z", "a2", "bob", []string{"alice"}, b, []string{a})

	threads := Threads([]source.Message{m1, m2})
	if len(threads) != 1 {
		t.Fatalf("got %d threads, want 1", len(threads))
	}
	if threads[0].Messages[0].ID != "a2" {
		t.Fatalf("got newest ID %q, want a2 (ID descending on At tie)", threads[0].Messages[0].ID)
	}
}

// --- ThreadRows (sp034 Task 2) ---
//
// These fixtures build Thread values directly rather than deriving them via
// Threads(), so a ThreadRows regression can never hide behind a Threads()
// change -- the two functions are tested independently, matching Task 1/2's
// split.

// noneExpanded is the "nothing expanded" predicate every collapsed-list test
// uses.
func noneExpanded(string) bool { return false }

// TestThreadRows_CollapsedIsOneRowPerThread: n threads, nothing expanded,
// exactly n rows, each a thread row carrying its OWN newest member (not the
// first member of some other thread -- a wrong implementation that reused
// one message across rows would fail this).
func TestThreadRows_CollapsedIsOneRowPerThread(t *testing.T) {
	t1 := Thread{
		Key:      "k1",
		Messages: []source.Message{msg("2026-09-12T12:02:00Z", "n1", "alice", nil, "a", nil)},
		Count:    1,
	}
	t2 := Thread{
		Key: "k2",
		Messages: []source.Message{
			msg("2026-09-12T12:01:00Z", "n2", "bob", nil, "b", nil),
			msg("2026-09-12T12:00:00Z", "n3", "bob", nil, "b", nil),
		},
		Count: 2,
	}
	t3 := Thread{
		Key:      "k3",
		Messages: []source.Message{msg("2026-09-12T12:03:00Z", "n4", "carol", nil, "c", nil)},
		Count:    1,
	}

	rows := ThreadRows([]Thread{t1, t2, t3}, noneExpanded)

	if len(rows) != 3 {
		t.Fatalf("got %d rows, want 3: %+v", len(rows), rows)
	}
	wantNewest := []string{"n1", "n2", "n4"}
	for i, row := range rows {
		if row.Kind != KindThread {
			t.Errorf("row %d: kind = %v, want KindThread", i, row.Kind)
		}
		if row.Message.ID != wantNewest[i] {
			t.Errorf("row %d: message ID = %q, want %q (own newest member)", i, row.Message.ID, wantNewest[i])
		}
		if row.Expanded {
			t.Errorf("row %d: Expanded = true, want false (nothing expanded)", i)
		}
	}
	if rows[1].Count != 2 {
		t.Errorf("row 1 (t2): Count = %d, want 2", rows[1].Count)
	}
	wantExpandable := []bool{false, true, false}
	for i, row := range rows {
		if row.Expandable != wantExpandable[i] {
			t.Errorf("row %d: Expandable = %v, want %v", i, row.Expandable, wantExpandable[i])
		}
	}
}

// TestThreadRows_ExpandedInsertsChildrenInOrder asserts the exact row
// SEQUENCE for a two-thread fixture with only the first expanded: thread,
// child, thread. The fold starts at the SECOND-newest member (sp035), so
// th1's two messages (c1 newest, c2 older) yield exactly one child (c2) --
// a wrong insertion point, or a fold that repeats the newest member as its
// own first child, fails this, where a count-only assertion would not.
func TestThreadRows_ExpandedInsertsChildrenInOrder(t *testing.T) {
	c1 := msg("2026-09-12T12:05:00Z", "c1", "alice", nil, "a", nil)
	c2 := msg("2026-09-12T12:04:00Z", "c2", "bob", nil, "b", nil)
	th1 := Thread{Key: "k1", Messages: []source.Message{c1, c2}, Count: 2}

	d1 := msg("2026-09-12T12:03:00Z", "d1", "carol", nil, "c", nil)
	th2 := Thread{Key: "k2", Messages: []source.Message{d1}, Count: 1}

	expanded := func(key string) bool { return key == "k1" }

	rows := ThreadRows([]Thread{th1, th2}, expanded)

	want := []LogRow{
		{Kind: KindThread, Key: "k1", Message: c1, Count: 2, Expanded: true, Expandable: true},
		{Kind: KindMessage, Key: "k1", Message: c2, Count: 2, Expanded: true, Expandable: true},
		{Kind: KindThread, Key: "k2", Message: d1, Count: 1, Expanded: false, Expandable: false},
	}
	if !reflect.DeepEqual(rows, want) {
		t.Fatalf("row sequence mismatch:\ngot  %+v\nwant %+v", rows, want)
	}
}

// TestThreadRows_NilPredicateCollapses asserts a nil expanded predicate is
// treated as "nothing expanded" rather than panicking -- calling it directly
// would panic on a nil func value if ThreadRows did not guard it.
func TestThreadRows_NilPredicateCollapses(t *testing.T) {
	th := Thread{
		Key:      "k1",
		Messages: []source.Message{msg("2026-09-12T12:00:00Z", "n1", "alice", nil, "a", nil)},
		Count:    1,
	}

	rows := ThreadRows([]Thread{th}, nil)

	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1 (collapsed): %+v", len(rows), rows)
	}
	if rows[0].Kind != KindThread || rows[0].Expanded {
		t.Fatalf("got %+v, want a single collapsed thread row", rows[0])
	}
}

// TestThreadRows_UnknownExpandedKeyIsIgnored: expanded reports true only for
// a key that names no thread in the input. No thread must expand -- a
// phantom key must never produce a phantom row.
func TestThreadRows_UnknownExpandedKeyIsIgnored(t *testing.T) {
	th1 := Thread{
		Key:      "k1",
		Messages: []source.Message{msg("2026-09-12T12:01:00Z", "n1", "alice", nil, "a", nil)},
		Count:    1,
	}
	th2 := Thread{
		Key:      "k2",
		Messages: []source.Message{msg("2026-09-12T12:00:00Z", "n2", "bob", nil, "b", nil)},
		Count:    1,
	}

	expanded := func(key string) bool { return key == "phantom" }

	rows := ThreadRows([]Thread{th1, th2}, expanded)

	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2 (both collapsed): %+v", len(rows), rows)
	}
	for i, row := range rows {
		if row.Expanded {
			t.Errorf("row %d expanded via unknown key match: %+v", i, row)
		}
	}
}

// TestThreadRows_Deterministic: two calls with the same arguments produce a
// byte-identical (reflect.DeepEqual) slice.
func TestThreadRows_Deterministic(t *testing.T) {
	th := Thread{
		Key: "k1",
		Messages: []source.Message{
			msg("2026-09-12T12:01:00Z", "n1", "alice", nil, "a", nil),
			msg("2026-09-12T12:00:00Z", "n2", "bob", nil, "b", nil),
		},
		Count: 2,
	}
	expanded := func(key string) bool { return key == "k1" }

	rows1 := ThreadRows([]Thread{th}, expanded)
	rows2 := ThreadRows([]Thread{th}, expanded)

	if !reflect.DeepEqual(rows1, rows2) {
		t.Fatalf("ThreadRows is not deterministic:\n%+v\n%+v", rows1, rows2)
	}
}

// TestThreadRows_ZeroThreadsReturnsEmptyNonNilSlice is the empty-bus edge
// case, matching Threads' own empty-input contract.
func TestThreadRows_ZeroThreadsReturnsEmptyNonNilSlice(t *testing.T) {
	rows := ThreadRows([]Thread{}, noneExpanded)
	if rows == nil {
		t.Fatal("ThreadRows(no threads) returned nil, want empty non-nil slice")
	}
	if len(rows) != 0 {
		t.Fatalf("got %d rows, want 0", len(rows))
	}
}

// TestThreadRows_OneMessageThreadIsNotExpandable is the REWRITE of sp034
// Task 2's TestThreadRows_OneMessageThreadExpandedIsNotNoOp, inverted by
// [[sp035]]: that test pinned a one-message thread gaining a child row when
// expanded (count read 1, row list still grew 1 -> 2). Under sp035 the fold
// starts at the SECOND-newest member, which the thread row already shows as
// its own summary -- so a one-message thread has nothing left to fold out
// at all and becomes NOT EXPANDABLE. expanded(key) returning true for it
// must produce zero child rows; the predicate cannot override
// expandability. The prior test is rewritten, not deleted, so the inversion
// has a dated record (## plan anti-pattern).
func TestThreadRows_OneMessageThreadIsNotExpandable(t *testing.T) {
	m := msg("2026-09-12T12:00:00Z", "n1", "alice", nil, "a", nil)
	th := Thread{Key: "k1", Messages: []source.Message{m}, Count: 1}

	collapsed := ThreadRows([]Thread{th}, noneExpanded)
	expanded := ThreadRows([]Thread{th}, func(string) bool { return true })

	if len(collapsed) != 1 {
		t.Fatalf("collapsed: got %d rows, want 1", len(collapsed))
	}
	if collapsed[0].Expandable {
		t.Fatalf("collapsed[0].Expandable = true, want false for a one-message thread: %+v", collapsed[0])
	}

	if len(expanded) != 1 {
		t.Fatalf("expanded: got %d rows, want 1 (thread row only, zero children): %+v", len(expanded), expanded)
	}
	if expanded[0].Expanded {
		t.Fatalf("expanded[0].Expanded = true, want false -- a Count == 1 thread cannot open even with its key expanded: %+v", expanded[0])
	}
	if expanded[0].Expandable {
		t.Fatalf("expanded[0].Expandable = true, want false: %+v", expanded[0])
	}
	if expanded[0].Count != 1 {
		t.Fatalf("count column must read 1: %+v", expanded[0])
	}
}

// TestThreadRows_ExpandedOmitsTheNewestMember is the sp035 regression this
// task exists for: sp034's fold rendered the newest member of an expanded
// thread TWICE -- once as the thread row's own summary (TIME/SUBJECT come
// from Messages[0]) and again as the first child, because children were the
// thread's full membership. The fold now starts at the SECOND-newest
// member, so a three-message thread expanded yields exactly two children
// (Messages[1:]) and the newest message's id appears exactly once across
// every rendered row -- the assertion that fails on the pre-sp035 code.
func TestThreadRows_ExpandedOmitsTheNewestMember(t *testing.T) {
	newest := msg("2026-09-12T12:02:00Z", "n1", "alice", nil, "a", nil)
	middle := msg("2026-09-12T12:01:00Z", "n2", "bob", nil, "b", nil)
	oldest := msg("2026-09-12T12:00:00Z", "n3", "carol", nil, "c", nil)
	th := Thread{Key: "k1", Messages: []source.Message{newest, middle, oldest}, Count: 3}

	rows := ThreadRows([]Thread{th}, func(string) bool { return true })

	want := []LogRow{
		{Kind: KindThread, Key: "k1", Message: newest, Count: 3, Expanded: true, Expandable: true},
		{Kind: KindMessage, Key: "k1", Message: middle, Count: 3, Expanded: true, Expandable: true},
		{Kind: KindMessage, Key: "k1", Message: oldest, Count: 3, Expanded: true, Expandable: true},
	}
	if !reflect.DeepEqual(rows, want) {
		t.Fatalf("row sequence mismatch:\ngot  %+v\nwant %+v", rows, want)
	}

	seen := 0
	for _, row := range rows {
		if row.Message.ID == newest.ID {
			seen++
		}
	}
	if seen != 1 {
		t.Fatalf("newest message id %q appeared %d times across rendered rows, want exactly 1: %+v", newest.ID, seen, rows)
	}
}

// TestThreadRows_ExpandableIsCarriedOnChildRows asserts every child row
// carries Expandable true alongside Count -- Task 2's shell and glyph code
// read Expandable off whichever row the cursor currently sits on, not just
// the thread row.
func TestThreadRows_ExpandableIsCarriedOnChildRows(t *testing.T) {
	newest := msg("2026-09-12T12:02:00Z", "n1", "alice", nil, "a", nil)
	middle := msg("2026-09-12T12:01:00Z", "n2", "bob", nil, "b", nil)
	oldest := msg("2026-09-12T12:00:00Z", "n3", "carol", nil, "c", nil)
	th := Thread{Key: "k1", Messages: []source.Message{newest, middle, oldest}, Count: 3}

	rows := ThreadRows([]Thread{th}, func(string) bool { return true })

	if len(rows) != 3 {
		t.Fatalf("got %d rows, want 3: %+v", len(rows), rows)
	}
	for i, row := range rows {
		if !row.Expandable {
			t.Errorf("row %d (%+v): Expandable = false, want true", i, row)
		}
	}
}

// TestThreadRows_CountStaysTheConversationTotal asserts Count reads the
// thread's total member count on every row, never len(children) -- an
// expanded thread of 3 renders one summary row and only 2 children, but
// Count must read 3 on all three rows. Two numbers that agree only when
// collapsed is exactly the bug sp035 exists to prevent.
func TestThreadRows_CountStaysTheConversationTotal(t *testing.T) {
	newest := msg("2026-09-12T12:02:00Z", "n1", "alice", nil, "a", nil)
	middle := msg("2026-09-12T12:01:00Z", "n2", "bob", nil, "b", nil)
	oldest := msg("2026-09-12T12:00:00Z", "n3", "carol", nil, "c", nil)
	th := Thread{Key: "k1", Messages: []source.Message{newest, middle, oldest}, Count: 3}

	rows := ThreadRows([]Thread{th}, func(string) bool { return true })

	if len(rows) != 3 {
		t.Fatalf("got %d rows, want 3 (1 thread + 2 children): %+v", len(rows), rows)
	}
	for i, row := range rows {
		if row.Count != 3 {
			t.Errorf("row %d: Count = %d, want 3", i, row.Count)
		}
	}
}

// TestThreadRows_CollapsedUnchanged pins collapsed output against the
// pre-sp035 expectation: same thread rows, same Count, same order, same
// Message (the newest) on each thread row -- the fold-from-second-newest
// change touches only the expanded path, and Expandable is the only new
// information a collapsed row carries.
func TestThreadRows_CollapsedUnchanged(t *testing.T) {
	t1 := Thread{
		Key:      "k1",
		Messages: []source.Message{msg("2026-09-12T12:02:00Z", "n1", "alice", nil, "a", nil)},
		Count:    1,
	}
	t2 := Thread{
		Key: "k2",
		Messages: []source.Message{
			msg("2026-09-12T12:01:00Z", "n2", "bob", nil, "b", nil),
			msg("2026-09-12T12:00:00Z", "n3", "bob", nil, "b", nil),
		},
		Count: 2,
	}

	rows := ThreadRows([]Thread{t1, t2}, noneExpanded)

	want := []LogRow{
		{Kind: KindThread, Key: "k1", Message: t1.Messages[0], Count: 1, Expanded: false, Expandable: false},
		{Kind: KindThread, Key: "k2", Message: t2.Messages[0], Count: 2, Expanded: false, Expandable: true},
	}
	if !reflect.DeepEqual(rows, want) {
		t.Fatalf("collapsed row mismatch:\ngot  %+v\nwant %+v", rows, want)
	}
}
