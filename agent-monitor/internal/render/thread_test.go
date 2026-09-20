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
// untouched: same order, same contents, after the call.
func TestThreads_InputNotMutated(t *testing.T) {
	a := "aAAAAAAAAAAAAAAAAAAAAAAAAAA1"
	b := "aBBBBBBBBBBBBBBBBBBBBBBBBBB1"
	m1 := msg("2026-09-12T12:01:00Z", "a2", "bob", []string{"alice"}, b, []string{a})
	m2 := msg("2026-09-12T12:00:00Z", "a1", "alice", []string{"bob"}, a, []string{b})

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
