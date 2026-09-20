package render

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"agent-monitor/internal/source"
)

func sampleMessages() []source.Message {
	return []source.Message{
		{At: "2026-09-12T12:00:00.000000Z", ID: "a1", From: "r2", To: []string{"brainstorm-1"}, Kind: "message", Content: json.RawMessage(`"Say the single word: delivered"`)},
		{At: "2026-09-12T12:01:00.000000Z", ID: "a2", From: "smoke-operator", To: []string{"peer-1", "peer-2"}, Kind: "message", Content: json.RawMessage(`"fan-out"`)},
	}
}

func TestRenderLog_HeaderAndColumns(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	lines := RenderLog(sample, false, now, 100)
	if len(lines) != 2+len(sampleMessages()) {
		t.Fatalf("got %d lines, want %d: %v", len(lines), 2+len(sampleMessages()), lines)
	}
	if lines[0] != "messages — updated 30s ago" {
		t.Fatalf("header = %q", lines[0])
	}
	for _, want := range []string{"TIME", "FROM", "TO", "SUBJECT"} {
		if !strings.Contains(lines[1], want) {
			t.Errorf("column header %q missing %q", lines[1], want)
		}
	}
}

// TestRenderLog_RowsDescendByID is sp033 T6 criterion 1 restated at this
// package's boundary: RenderLog itself does not sort (it never has), so
// handed a sample already in the pane's newest-first display order — the
// shape cmd/agent-monitor's orderedMessages now produces — it must print
// row 0 as the FIRST data line rather than re-deriving an oldest-first
// order of its own.
func TestRenderLog_RowsDescendByID(t *testing.T) {
	at := time.Now()
	descending := []source.Message{sampleMessages()[1], sampleMessages()[0]} // fan-out (newer) first
	sample := &source.MessageSample{Messages: descending, At: at}
	lines := RenderLog(sample, false, at, 100)

	firstData := lines[2] // header + column-header precede the data rows
	lastData := lines[len(lines)-1]
	if !strings.Contains(firstData, "fan-out") {
		t.Fatalf("first data row = %q, want the newer (fan-out) message first", firstData)
	}
	if !strings.Contains(lastData, "delivered") {
		t.Fatalf("last data row = %q, want the older (delivered) message last", lastData)
	}
}

func TestRenderLog_MultiRecipient_ListsAll(t *testing.T) {
	at := time.Now()
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}
	lines := RenderLog(sample, false, at, 200)
	found := false
	for _, l := range lines {
		if strings.Contains(l, "peer-1,peer-2") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected a row listing both recipients, got %v", lines)
	}
}

func TestRenderLog_StaleHeader(t *testing.T) {
	at := time.Now().Add(-time.Minute)
	sample := &source.MessageSample{Messages: nil, At: at}
	lines := RenderLog(sample, true, time.Now(), 80)
	if !strings.HasPrefix(lines[0], "messages — STALE") {
		t.Fatalf("header = %q, want STALE prefix", lines[0])
	}
}

func TestRenderLog_Empty(t *testing.T) {
	at := time.Now()
	sample := &source.MessageSample{Messages: []source.Message{}, At: at}
	lines := RenderLog(sample, false, at, 80)
	found := false
	for _, l := range lines {
		if strings.Contains(l, "no messages") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected an explicit empty-log line, got %v", lines)
	}
}

func TestRenderLog_NilSample(t *testing.T) {
	lines := RenderLog(nil, false, time.Now(), 80)
	if len(lines) != 1 || !strings.Contains(lines[0], "waiting for first sample") {
		t.Fatalf("got %v", lines)
	}
}

// Never wrap mid-row / never exceed width, mirroring roster_test.go's guard.
func TestRenderLog_NeverExceedsWidth(t *testing.T) {
	at := time.Now()
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}
	for _, width := range []int{20, 40, 80} {
		lines := RenderLog(sample, false, at, width)
		for i, l := range lines {
			if n := len([]rune(l)); n > width+minSubjectWidth {
				// SUBJECT is floored at minSubjectWidth even when that
				// overruns a pathologically narrow terminal (documented
				// trade-off in subjectWidth); anything past that floor
				// would be a real bug.
				t.Fatalf("width=%d line %d unexpectedly long (%d runes): %q", width, i, n, l)
			}
		}
	}
}

// dotfiles-1d1f: `from`/`to` are minted addresses on the wire and
// `pi-worker messages` resolves them to labels. A cell holding an ADDRESS is
// therefore one the registry could not resolve, and the raw address is the
// only honest thing to show — never a blank cell, never a nearest-match name
// ([[adr0017]]).
func addressMessages() []source.Message {
	return []source.Message{
		// Two addresses minted in the same millisecond: identical for their
		// first 11 characters, different only in the random tail.
		{
			At: "2026-09-12T12:00:00.000000Z", ID: "a1",
			From: "a01M2M36Y5KJJ0YARD1BAJ6X8AY",
			To:   []string{"a01M2M36Y5KJJ0YARD1BQQQQQQQ"},
			Kind: "message", Content: json.RawMessage(`"unresolved"`),
		},
	}
}

func TestRenderLog_AnUnresolvedAddressIsShownNotBlanked(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	sample := &source.MessageSample{Messages: addressMessages(), At: at}
	lines := RenderLog(sample, false, at, 100)
	row := lines[len(lines)-1]

	// The distinguishing tail of each address reaches the row.
	if !strings.Contains(row, "J6X8AY") {
		t.Errorf("FROM cell lost the sender's address tail: %q", row)
	}
	if !strings.Contains(row, "QQQQQQ") {
		t.Errorf("TO cell lost the recipient's address tail: %q", row)
	}
	// And it is not rendered as "no value".
	if strings.Contains(row, emptyCell+" ") && !strings.Contains(row, "J6X8AY") {
		t.Errorf("an unresolved address must never render as the empty cell: %q", row)
	}
}

func TestShortAddress_ElidesOnlyAddresses(t *testing.T) {
	if got := shortAddress("impl-1"); got != "impl-1" {
		t.Errorf("a label must pass through unchanged, got %q", got)
	}
	if got := shortAddress("r2"); got != "r2" {
		t.Errorf("a run label must pass through unchanged, got %q", got)
	}
	if got := shortAddress(""); got != "" {
		t.Errorf("an empty cell must stay empty, got %q", got)
	}
	// Two same-millisecond addresses must not render identically — the whole
	// reason the TAIL is kept rather than the head.
	a := shortAddress("a01M2M36Y5KJJ0YARD1BAJ6X8AY")
	b := shortAddress("a01M2M36Y5KJJ0YARD1BQQQQQQQ")
	if a == b {
		t.Errorf("two distinct addresses rendered identically as %q", a)
	}
	if a != "…J6X8AY" {
		t.Errorf("shortAddress = %q, want the marked tail", a)
	}
}

func TestRenderDetail_KeepsTheFullAddress(t *testing.T) {
	// The detail pane is the view an operator copies an address out of, so it
	// must not elide. The log elides; these are deliberately different.
	msg := addressMessages()[0]
	lines := RenderDetail(&msg, 200, 10)
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "a01M2M36Y5KJJ0YARD1BAJ6X8AY") {
		t.Errorf("detail pane must carry the full sender address: %q", joined)
	}
	if !strings.Contains(joined, "a01M2M36Y5KJJ0YARD1BQQQQQQQ") {
		t.Errorf("detail pane must carry the full recipient address: %q", joined)
	}
}

// --- sp032 T6: the `+N new` header segment --------------------------------

// TestRenderLog_HeaderByteIdenticalWhenNoPending is the regression anchor
// for every log-header assertion above it. The pending count is an OPTIONAL
// trailing argument precisely so the four-argument call every existing
// caller and every existing test makes keeps compiling AND keeps rendering
// the same bytes; this asserts the second half of that, which the compiler
// cannot.
func TestRenderLog_HeaderByteIdenticalWhenNoPending(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	for _, stale := range []bool{false, true} {
		for _, width := range []int{8, 20, 26, 40, 100} {
			omitted := RenderLog(sample, stale, now, width)
			explicit := RenderLog(sample, stale, now, width, LogSignals{})
			if omitted[0] != explicit[0] {
				t.Fatalf("stale=%v width=%d: header differs between the 4-arg and the explicit-zero call:\n %q\n %q",
					stale, width, omitted[0], explicit[0])
			}
			if strings.Contains(omitted[0], "new") {
				t.Fatalf("stale=%v width=%d: a zero count leaked a segment into the header: %q", stale, width, omitted[0])
			}
		}
	}

	// And the exact bytes, so the header is pinned rather than merely
	// self-consistent.
	if got := RenderLog(sample, false, now, 100, LogSignals{})[0]; got != "messages — updated 30s ago" {
		t.Fatalf("header = %q, want today's header unchanged", got)
	}
	if got := RenderLog(sample, true, now, 100, LogSignals{})[0]; got != "messages — STALE (last good sample 30s old)" {
		t.Fatalf("stale header = %q, want today's stale header unchanged", got)
	}
}

// TestRenderLog_HeaderCarriesPendingCount is criterion 3's positive half: a
// frozen pane says so, and says by how much. Plain TEXT in the header line —
// render/ emits no escapes and nothing here styles anything.
func TestRenderLog_HeaderCarriesPendingCount(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	if got := RenderLog(sample, false, now, 100, LogSignals{Pending: 7})[0]; got != "messages — updated 30s ago  +7 new" {
		t.Errorf("header = %q, want the base header with a ` +7 new` segment", got)
	}
	if got := RenderLog(sample, true, now, 100, LogSignals{Pending: 12})[0]; got != "messages — STALE (last good sample 30s old)  +12 new" {
		t.Errorf("stale header = %q, want the stale header with a ` +12 new` segment", got)
	}
	// The count is the number, not a fixed word: 1 and 137 must both reach
	// the header verbatim.
	for _, n := range []int{1, 137} {
		want := "+" + strconv.Itoa(n) + " new"
		if got := RenderLog(sample, false, now, 100, LogSignals{Pending: n})[0]; !strings.Contains(got, want) {
			t.Errorf("header = %q, want it to contain %q", got, want)
		}
	}
}

// TestRenderLog_PendingSegmentKeepsTheWidthBudget is the edge case where the
// count is wide enough to matter: the header is one of the two free-text
// lines this renderer emits, and a segment that pushed it past the terminal
// width would wrap — the one thing every other line in this package is
// engineered not to do. The COUNT is what survives the squeeze, because it
// is the whole signal; the prose in front of it is what gets elided.
func TestRenderLog_PendingSegmentKeepsTheWidthBudget(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	for _, width := range []int{12, 20, 26, 40} {
		for _, n := range []int{9, 4321, 987654} {
			header := RenderLog(sample, false, now, width, LogSignals{Pending: n})[0]
			if got := displayWidth(header); got > width {
				t.Errorf("width=%d n=%d: header is %d cells wide: %q", width, n, got, header)
			}
			if want := "+" + strconv.Itoa(n) + " new"; !strings.Contains(header, want) {
				t.Errorf("width=%d n=%d: the count was squeezed out of %q", width, n, header)
			}
		}
	}
}

// TestRenderLog_NegativeAndZeroPendingRenderNothing pins the boundary: only
// a POSITIVE count is news. A zero (a live pane) and a negative (which the
// model cannot produce, but which this renderer must not turn into `+-3
// new`) both leave the header alone.
func TestRenderLog_NegativeAndZeroPendingRenderNothing(t *testing.T) {
	at := time.Now()
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}
	base := RenderLog(sample, false, at, 100)[0]
	for _, n := range []int{0, -1, -99} {
		if got := RenderLog(sample, false, at, 100, LogSignals{Pending: n})[0]; got != base {
			t.Errorf("pending=%d changed the header: %q, want %q", n, got, base)
		}
	}
}

// --- sp033 T7: the for-you count and the row marker ------------------------

// forYouMessages builds a fixture where exactly one message is addressed to
// identityAddr (via ToAddresses, never the rendered To label), one is FROM
// identityAddr (never marked — edge case: your own sent mail is not for
// you), and one is addressed to an unrelated address.
const identityAddr = "a01M2M36Y5KJJ0YARD1BIDENTITY"

func forYouMessages() []source.Message {
	return []source.Message{
		{
			At: "2026-09-12T12:00:00.000000Z", ID: "a1",
			From: "worker-a", To: []string{"jan"}, Kind: "message",
			Content: json.RawMessage(`"addressed to you"`), ToAddresses: []string{identityAddr},
		},
		{
			At: "2026-09-12T12:01:00.000000Z", ID: "a2",
			From: "jan", To: []string{"worker-b"}, Kind: "message",
			Content: json.RawMessage(`"sent by you"`), FromAddress: identityAddr, ToAddresses: []string{"a01M2M36Y5KJJ0YARD1BWORKERB"},
		},
		{
			At: "2026-09-12T12:02:00.000000Z", ID: "a3",
			From: "worker-c", To: []string{"worker-d"}, Kind: "message",
			Content: json.RawMessage(`"not yours"`), ToAddresses: []string{"a01M2M36Y5KJJ0YARD1BWORKERD"},
		},
	}
}

// TestForYou_MarksRowsAddressedToTheIdentityAddress is criterion 1/4: a row
// whose ToAddresses contains the identity's address carries the marker;
// rows that don't, don't.
func TestForYou_MarksRowsAddressedToTheIdentityAddress(t *testing.T) {
	at := time.Now()
	sample := &source.MessageSample{Messages: forYouMessages(), At: at}
	lines := RenderLog(sample, false, at, 100, LogSignals{Identity: identityAddr})

	dataLines := lines[2:]
	if !strings.HasPrefix(dataLines[0], markCell) {
		t.Errorf("row addressed to the identity missing its marker: %q", dataLines[0])
	}
	if strings.HasPrefix(dataLines[1], markCell) {
		t.Errorf("row FROM the identity (not to it) wrongly marked: %q", dataLines[1])
	}
	if strings.HasPrefix(dataLines[2], markCell) {
		t.Errorf("row addressed to someone else wrongly marked: %q", dataLines[2])
	}
}

// TestForYou_DoesNotMarkYourOwnSentMessages restates the middle row of
// TestForYou_MarksRowsAddressedToTheIdentityAddress as its own named case,
// exactly as the test plan lists it: a message with your address in
// FromAddress and NOT in ToAddresses is never marked, no matter that you
// wrote it.
func TestForYou_DoesNotMarkYourOwnSentMessages(t *testing.T) {
	at := time.Now()
	msg := forYouMessages()[1]
	if msg.FromAddress != identityAddr {
		t.Fatalf("fixture drift: message 1 is no longer FROM the identity")
	}
	sample := &source.MessageSample{Messages: []source.Message{msg}, At: at}
	lines := RenderLog(sample, false, at, 100, LogSignals{Identity: identityAddr})
	if strings.HasPrefix(lines[2], markCell) {
		t.Errorf("a message you sent was marked for-you: %q", lines[2])
	}
}

// TestForYou_PreviousRegistrationAddressIsNotYou is criterion 1's edge case:
// an address a message was addressed to under a PREVIOUS registration is not
// the CURRENT identity's address (adr0034 never reuses one), so a message to
// the old address must not be marked just because it happens to be present
// in this sample.
func TestForYou_PreviousRegistrationAddressIsNotYou(t *testing.T) {
	at := time.Now()
	oldAddr := "a01M2M36Y5KJJ0YARD1BOLDADDR1"
	currentAddr := "a01M2M36Y5KJJ0YARD1BNEWADDR2"
	msg := source.Message{
		At: at.Format(time.RFC3339Nano), ID: "a1",
		From: "worker-a", To: []string{"jan"}, Kind: "message",
		Content: json.RawMessage(`"addressed to the old you"`), ToAddresses: []string{oldAddr},
	}
	sample := &source.MessageSample{Messages: []source.Message{msg}, At: at}
	lines := RenderLog(sample, false, at, 100, LogSignals{Identity: currentAddr})
	if strings.HasPrefix(lines[2], markCell) {
		t.Errorf("a message to a released address was marked for-you: %q", lines[2])
	}
}

// TestForYou_NoIdentityRendersNothingExtra is criterion 5: absent an
// identity, RenderLog must not add the marker column, must not add the `N
// for you` segment even if ForYou is (incorrectly) nonzero, and the header
// must be byte-identical to a call with no LogSignals at all.
func TestForYou_NoIdentityRendersNothingExtra(t *testing.T) {
	at := time.Now()
	sample := &source.MessageSample{Messages: forYouMessages(), At: at}

	withoutSignals := RenderLog(sample, false, at, 100)
	withZeroSignals := RenderLog(sample, false, at, 100, LogSignals{ForYou: 3})
	for i := range withoutSignals {
		if withoutSignals[i] != withZeroSignals[i] {
			t.Fatalf("line %d differs with no identity but ForYou set: %q vs %q", i, withoutSignals[i], withZeroSignals[i])
		}
	}
	if strings.Contains(withZeroSignals[0], "for you") {
		t.Errorf("header carried a for-you segment with no identity: %q", withZeroSignals[0])
	}
}

// TestRenderLog_HeaderByteIdenticalWhenBothCountsZero is sp033 T7 criterion
// 3's negative half: with an identity resolved but both counts at zero, the
// header must still read exactly as T6 left it — the marker column may
// appear on rows (criterion 4 is independent of the count), but the header
// LINE itself carries neither segment.
func TestRenderLog_HeaderByteIdenticalWhenBothCountsZero(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	want := RenderLog(sample, false, now, 100)[0]
	got := RenderLog(sample, false, now, 100, LogSignals{Identity: identityAddr})[0]
	if got != want {
		t.Fatalf("header with an identity but both counts zero = %q, want %q", got, want)
	}
}

// TestRenderLog_HeaderCarriesBothSegmentsDistinctly is criterion 3's
// positive half: pending and for-you can both be present, and the header
// must say both rather than folding them into one number.
func TestRenderLog_HeaderCarriesBothSegmentsDistinctly(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	got := RenderLog(sample, false, now, 100, LogSignals{Pending: 7, ForYou: 3, Identity: identityAddr})[0]
	if !strings.Contains(got, "+7 new") {
		t.Errorf("header = %q, missing the pending segment", got)
	}
	if !strings.Contains(got, "3 for you") {
		t.Errorf("header = %q, missing the for-you segment", got)
	}
}

// TestForYou_SegmentKeepsTheWidthBudgetAlongsidePending is the named edge
// case "the count's width against the header's budget, with +N new also
// present": at a width that can fit both segments (with the prose elided
// first, exactly as withCountSegments' single-segment case already does),
// the header must carry both and never exceed width.
func TestForYou_SegmentKeepsTheWidthBudgetAlongsidePending(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	// "  +42 new, 7 for you" is 20 cells; every width below fits it exactly
	// or with room to spare for (elided) prose.
	for _, width := range []int{20, 26, 32, 40} {
		header := RenderLog(sample, false, now, width, LogSignals{Pending: 42, ForYou: 7, Identity: identityAddr})[0]
		if got := displayWidth(header); got > width {
			t.Errorf("width=%d: header is %d cells wide: %q", width, got, header)
		}
		if !strings.Contains(header, "+42 new") {
			t.Errorf("width=%d: pending segment squeezed out of %q", width, header)
		}
		if !strings.Contains(header, "7 for you") {
			t.Errorf("width=%d: for-you segment squeezed out of %q", width, header)
		}
	}
}

// --- dotfiles-jw73: the filter/draft become visible in the header ---------

// TestFilterHeader_CommittedQueryShown is requirement 2: a non-empty
// committed query renders in the header, so a reduced view is never silent.
func TestFilterHeader_CommittedQueryShown(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	got := RenderLog(sample, false, now, 100, LogSignals{FilterQuery: "claude-main"})[0]
	if got != "messages — updated 30s ago  filter: claude-main" {
		t.Fatalf("header = %q, want the base header with a filter segment", got)
	}
}

// TestFilterHeader_EmptyQueryKeysOnContentNotSet is the bug's central claim:
// a committed empty query (Filter{Set: true, Query: ""}) matches everything
// and must render exactly as if no filter had ever been committed — the
// caller has nothing but the query string to signal that with (LogSignals
// carries no Set bool), so an empty FilterQuery must never itself add a
// segment.
func TestFilterHeader_EmptyQueryKeysOnContentNotSet(t *testing.T) {
	at := time.Now()
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}
	base := RenderLog(sample, false, at, 100)[0]

	if got := RenderLog(sample, false, at, 100, LogSignals{FilterQuery: ""})[0]; got != base {
		t.Errorf("empty FilterQuery changed the header: %q, want %q", got, base)
	}
}

// TestFilterHeader_EditingShowsDraftWithCursor is requirement 1: while
// Editing, the draft as typed so far is echoed — including a trailing
// cursor marker on an EMPTY draft, mirroring composerBodyLines' "an empty
// draft still shows where typing lands" (cmd/agent-monitor/main.go).
func TestFilterHeader_EditingShowsDraftWithCursor(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	got := RenderLog(sample, false, now, 100, LogSignals{FilterEditing: true, FilterDraft: ""})[0]
	if got != "messages — updated 30s ago  editing filter: ▏" {
		t.Fatalf("header = %q, want an empty draft still to show the cursor", got)
	}

	got = RenderLog(sample, false, now, 100, LogSignals{FilterEditing: true, FilterDraft: "cla"})[0]
	if got != "messages — updated 30s ago  editing filter: cla▏" {
		t.Fatalf("header = %q, want the typed draft echoed with a trailing cursor", got)
	}
}

// TestFilterHeader_EditingWinsOverAStaleCommittedQuery is the composer-shape
// choice (requirement 5): while Editing, the header shows the DRAFT, not the
// previously committed query that is still in effect until Enter recommits
// — exactly like the composer's region never shows anything but the current
// draft.
func TestFilterHeader_EditingWinsOverAStaleCommittedQuery(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	got := RenderLog(sample, false, now, 100, LogSignals{FilterQuery: "old", FilterEditing: true, FilterDraft: "new"})[0]
	if got != "messages — updated 30s ago  editing filter: new▏" {
		t.Fatalf("header = %q, want only the draft while editing", got)
	}
}

// TestFilterHeader_ByteIdenticalWhenInactive is the regression anchor
// (requirement 4): a caller that never sets FilterQuery/FilterEditing (every
// pre-dotfiles-jw73 call, and any other zero-value LogSignals) gets the
// exact byte-identical header as before this task.
func TestFilterHeader_ByteIdenticalWhenInactive(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	for _, width := range []int{8, 20, 26, 40, 100} {
		omitted := RenderLog(sample, false, now, width)
		explicit := RenderLog(sample, false, now, width, LogSignals{})
		withOtherSignals := RenderLog(sample, false, now, width, LogSignals{Pending: 3, ForYou: 1, Identity: identityAddr})[0]
		if omitted[0] != explicit[0] {
			t.Fatalf("width=%d: 4-arg and explicit-zero calls differ: %q vs %q", width, omitted[0], explicit[0])
		}
		if strings.Contains(omitted[0], "filter") {
			t.Fatalf("width=%d: an inactive filter leaked a segment into the header: %q", width, omitted[0])
		}
		if strings.Contains(withOtherSignals, "filter") {
			t.Fatalf("width=%d: an inactive filter leaked a segment alongside other signals: %q", width, withOtherSignals)
		}
	}
}

// TestFilterHeader_QueryWiderThanTerminalNeverOverflows is dotfiles-jw73
// rejection #1's reproduction: a 70-character committed query at width 40
// must not blow the header past width — withCountSegments' overflow branch
// returns an overlong segment verbatim, so the query itself has to be
// cell-truncated before it ever reaches that function. The TAIL survives
// (the operator typed it last), not the head.
func TestFilterHeader_QueryWiderThanTerminalNeverOverflows(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	long := strings.Repeat("x", 60) + "-tail-end"
	header := RenderLog(sample, false, now, 40, LogSignals{FilterQuery: long})[0]
	if got := displayWidth(header); got > 40 {
		t.Fatalf("header is %d cells wide at width 40: %q", got, header)
	}
	if !strings.Contains(header, "tail-end") {
		t.Fatalf("header dropped the tail the operator typed last: %q", header)
	}
}

// TestFilterHeader_DraftWiderThanTerminalNeverOverflows is the editing-mode
// twin: a draft wider than the terminal must not overflow either, and the
// text kept is the tail nearest the cursor.
func TestFilterHeader_DraftWiderThanTerminalNeverOverflows(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	long := strings.Repeat("y", 60) + "-cursor-here"
	header := RenderLog(sample, false, now, 40, LogSignals{FilterEditing: true, FilterDraft: long})[0]
	if got := displayWidth(header); got > 40 {
		t.Fatalf("header is %d cells wide at width 40: %q", got, header)
	}
	if !strings.Contains(header, "cursor-here") {
		t.Fatalf("header dropped the text nearest the cursor: %q", header)
	}
	if !strings.HasSuffix(header, filterCursor) {
		t.Fatalf("header = %q, want it to still end with the cursor marker", header)
	}
}

// TestFilterHeader_SegmentKeepsTheWidthBudget mirrors
// TestRenderLog_PendingSegmentKeepsTheWidthBudget: the filter segment is
// subject to the same width-fit rule as every other header segment.
func TestFilterHeader_SegmentKeepsTheWidthBudget(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	// "  filter: claude-main, +4 new" is 30 cells; every width below fits it
	// exactly or with room to spare for (elided) prose.
	for _, width := range []int{30, 40, 50, 60} {
		header := RenderLog(sample, false, now, width, LogSignals{FilterQuery: "claude-main", Pending: 4})[0]
		if got := displayWidth(header); got > width {
			t.Errorf("width=%d: header is %d cells wide: %q", width, got, header)
		}
		if !strings.Contains(header, "filter: claude-main") {
			t.Errorf("width=%d: filter segment squeezed out of %q", width, header)
		}
	}
}

// dotfiles-jw73 rejection #2. The filter segment and the count segments were
// each bounded correctly in isolation and overflowed together: the filter was
// budgeted against the full render width, then `+N new` / `N for you` were
// appended on top of an already-full line. The reviewer's repro produced a
// 79-cell header against a 60-cell budget, and every narrower width was worse.
//
// This is the combination the earlier width test missed — it used a short
// filter and a single count at widths with enough slack for the base to
// absorb, so the sum never exceeded the budget.
func TestRenderLog_FilterAndBothCountsNeverExceedWidth(t *testing.T) {
	sample := &source.MessageSample{Messages: sampleMessages(), At: time.Now()}
	long := "a-very-long-filter-draft-that-nobody-would-type-but-tail-marker-XYZ"

	for _, editing := range []bool{true, false} {
		for _, width := range []int{15, 20, 25, 30, 40, 60, 80} {
			sig := LogSignals{Pending: 9, ForYou: 3, Identity: identityAddr}
			if editing {
				sig.FilterEditing = true
				sig.FilterDraft = long
			} else {
				sig.FilterQuery = long
			}
			for _, line := range RenderLog(sample, false, time.Now(), width, sig) {
				if got := displayWidth(line); got > width {
					t.Errorf("editing=%v width=%d: line is %d cells, over budget: %q",
						editing, width, got, line)
				}
			}
		}
	}
}

// The counts are short and fixed; the filter is the variable-length part, so
// the filter is what shrinks. Both counts must survive a draft long enough to
// have consumed the whole line under the old budgeting — losing the doorbell
// count to a long filter would trade one invisible signal for another.
func TestRenderLog_CountsSurviveALongFilter(t *testing.T) {
	header := RenderLog(&source.MessageSample{Messages: sampleMessages(), At: time.Now()}, false, time.Now(), 80, LogSignals{
		FilterEditing: true,
		FilterDraft:   strings.Repeat("x", 200),
		Pending:       9,
		ForYou:        3,
		Identity:      identityAddr,
	})[0]

	for _, want := range []string{"+9 new", "3 for you"} {
		if !strings.Contains(header, want) {
			t.Errorf("header lost %q to a long filter: %q", want, header)
		}
	}
	if displayWidth(header) > 80 {
		t.Errorf("header is %d cells, over 80: %q", displayWidth(header), header)
	}
}

// --- sp034 Task 3: thread and child rows on one column grid ----------------

// threadFixture builds a THREE-message thread ("worker-a" <-> the identity
// address) under sp035's fold-from-second-newest contract: the thread row
// shows the newest member ("a3") and NEVER repeats it as a child (that
// repetition was the very defect sp035 removes — see sp035's ## problem).
// The children are Messages[1:] in newest-first order: "a2" (the middle
// member, also the operator's own reply, NOT addressed to the identity)
// then "a1" (the oldest member, addressed to the identity). "a1" being
// addressed to the identity while it is NOT the newest member is what
// TestRenderLog_ForYouMarksThreadWhenAnyMemberIsForMe needs: a mark computed
// from row.Message (the newest member) alone would miss it.
//
// Returns the thread and its rows in ThreadRows' own order: rows[0] is the
// thread row (newest, "a3"), rows[1] the middle child ("a2"), rows[2] the
// oldest child, also the for-you message ("a1").
func threadFixture() (Thread, []LogRow) {
	older := source.Message{
		At: "2026-09-12T12:00:00.000000Z", ID: "a1",
		From: "worker-a", To: []string{"jan"}, Kind: "message",
		Content:     json.RawMessage(`"distinctive-older-subject"`),
		FromAddress: "a01M2M36Y5KJJ0YARD1BWORKERA",
		ToAddresses: []string{identityAddr},
	}
	middle := source.Message{
		At: "2026-09-12T12:05:00.000000Z", ID: "a2",
		From: "jan", To: []string{"worker-a"}, Kind: "message",
		Content:     json.RawMessage(`"distinctive-middle-subject"`),
		FromAddress: identityAddr,
		ToAddresses: []string{"a01M2M36Y5KJJ0YARD1BWORKERA"},
	}
	newest := source.Message{
		At: "2026-09-12T12:10:00.000000Z", ID: "a3",
		From: "jan", To: []string{"worker-a"}, Kind: "message",
		Content:     json.RawMessage(`"distinctive-newest-subject"`),
		FromAddress: identityAddr,
		ToAddresses: []string{"a01M2M36Y5KJJ0YARD1BWORKERA"},
	}
	// dotfiles-qm4h.2: Threads() no longer sorts -- it is fed pre-ordered
	// input, newest-first, matching what orderedMessages
	// (cmd/agent-monitor/main.go) actually hands it. This fixture used to
	// feed oldest-first and rely on Threads' internal At-sort to fix the
	// order; that internal sort is gone (dotfiles-i1sw), so the input order
	// here must already be newest-first.
	threads := Threads([]source.Message{newest, middle, older})
	if len(threads) != 1 {
		panic(fmt.Sprintf("fixture drift: want one thread, got %d", len(threads)))
	}
	th := threads[0]
	rows := ThreadRows(threads, func(string) bool { return true })
	if len(rows) != 3 || rows[0].Kind != KindThread || rows[1].Kind != KindMessage || rows[2].Kind != KindMessage {
		panic(fmt.Sprintf("fixture drift: unexpected row shape %+v", rows))
	}
	if rows[1].Message.ID != "a2" || rows[2].Message.ID != "a1" {
		panic(fmt.Sprintf("fixture drift: unexpected child order %+v", rows))
	}
	return th, rows
}

// TestRenderLog_ThreadRowGridMatchesChildGrid is the test_plan's named case:
// SUBJECT must start at the same column INDEX on a thread row and a child
// row, computed from the rendered strings rather than a hardcoded literal —
// a hardcoded index would pass even if the two rows silently used different
// column sets.
func TestRenderLog_ThreadRowGridMatchesChildGrid(t *testing.T) {
	th, rows := threadFixture()
	threadRow, childRow := rows[0], rows[1]

	threadLine := RenderThreadRow(threadRow, th, 80, "")
	childLine := RenderThreadRow(childRow, th, 80, "")

	idxThread := strings.Index(threadLine, "distinctive-newest-subject")
	idxChild := strings.Index(childLine, "distinctive-middle-subject")
	if idxThread < 0 {
		t.Fatalf("thread row lost its SUBJECT: %q", threadLine)
	}
	if idxChild < 0 {
		t.Fatalf("child row lost its SUBJECT: %q", childLine)
	}
	if idxThread != idxChild {
		t.Fatalf("SUBJECT starts at different columns: thread=%d child=%d\nthread: %q\nchild:  %q",
			idxThread, idxChild, threadLine, childLine)
	}
}

// TestRenderLog_ChildRowOmitsRecipient is the test_plan's named case: a
// child row's message has a distinctive recipient, and that recipient's
// label/address must appear nowhere in the rendered line — the recipient is
// implicit in the thread's own participant pair (## plan).
func TestRenderLog_ChildRowOmitsRecipient(t *testing.T) {
	th, rows := threadFixture()
	line := RenderThreadRow(rows[1], th, 80, "")

	if strings.Contains(line, "worker-a") {
		t.Errorf("child row rendered its recipient label: %q", line)
	}
	if strings.Contains(line, "WORKERA") {
		t.Errorf("child row rendered its recipient's raw address: %q", line)
	}
}

// TestRenderLog_GlyphReflectsExpansion is criterion 1: ">" collapsed, "v"
// expanded, on a thread row.
func TestRenderLog_GlyphReflectsExpansion(t *testing.T) {
	_, rows := threadFixture()
	threadRow := rows[0]

	collapsed := threadRow
	collapsed.Expanded = false
	if got := threadGlyphCell(collapsed); got != ">" {
		t.Errorf("collapsed glyph = %q, want %q", got, ">")
	}

	expanded := threadRow
	expanded.Expanded = true
	if got := threadGlyphCell(expanded); got != "v" {
		t.Errorf("expanded glyph = %q, want %q", got, "v")
	}

	if got := threadGlyphCell(LogRow{Kind: KindMessage}); got != "" {
		t.Errorf("child row glyph = %q, want blank", got)
	}
}

// TestRenderThreadRow_OneMessageThreadHasNoGlyph is sp035 Task 2's own named
// test_plan case: a thread whose Count is 1 — Expandable false, derived once
// by ThreadRows and never recomputed here — renders a BLANK glyph cell, not
// ">" or "v", AND the grid does not shift: SUBJECT starts at the same
// computed column index it does on an expandable thread row at the same
// width.
func TestRenderThreadRow_OneMessageThreadHasNoGlyph(t *testing.T) {
	solo := source.Message{
		At: "2026-09-12T12:00:00.000000Z", ID: "b1",
		From: "worker-c", To: []string{"jan"}, Kind: "message",
		Content:     json.RawMessage(`"solo-thread-subject"`),
		FromAddress: "a01M2M36Y5KJJ0YARD1BWORKERC",
		ToAddresses: []string{identityAddr},
	}
	threads := Threads([]source.Message{solo})
	if len(threads) != 1 {
		t.Fatalf("fixture drift: want one thread, got %d", len(threads))
	}
	rows := ThreadRows(threads, func(string) bool { return true })
	if len(rows) != 1 || rows[0].Kind != KindThread {
		t.Fatalf("fixture drift: want exactly one thread row, got %+v", rows)
	}
	oneMsgRow := rows[0]
	if oneMsgRow.Expandable {
		t.Fatalf("fixture drift: one-message thread reports Expandable true")
	}

	expandableTh, expandableRows := threadFixture()
	expandableRow := expandableRows[0]
	if !expandableRow.Expandable {
		t.Fatalf("fixture drift: threadFixture's thread row is not Expandable")
	}

	if got := threadGlyphCell(oneMsgRow); got != "" {
		t.Errorf("non-expandable thread glyph = %q, want blank", got)
	}
	if got := threadGlyphCell(expandableRow); got == "" {
		t.Fatalf("fixture drift: expandable thread row's own glyph is blank")
	}

	oneMsgLine := RenderThreadRow(oneMsgRow, threads[0], 80, "")
	expandableLine := RenderThreadRow(expandableRow, expandableTh, 80, "")

	idxOneMsg := strings.Index(oneMsgLine, "solo-thread-subject")
	idxExpandable := strings.Index(expandableLine, "distinctive-newest-subject")
	if idxOneMsg < 0 {
		t.Fatalf("one-message thread row lost its SUBJECT: %q", oneMsgLine)
	}
	if idxExpandable < 0 {
		t.Fatalf("expandable thread row lost its SUBJECT: %q", expandableLine)
	}
	if idxOneMsg != idxExpandable {
		t.Fatalf("SUBJECT starts at different columns: one-message=%d expandable=%d\none-message: %q\nexpandable:  %q",
			idxOneMsg, idxExpandable, oneMsgLine, expandableLine)
	}
}

// TestRenderLog_ForYouMarksThreadWhenAnyMemberIsForMe is the test_plan's
// named case: the thread's only for-you message is NOT the newest member,
// so a thread row whose mark were computed from row.Message alone (the
// newest) would wrongly render unmarked.
func TestRenderLog_ForYouMarksThreadWhenAnyMemberIsForMe(t *testing.T) {
	th, rows := threadFixture()
	threadRow, middleChildRow, olderChildRow := rows[0], rows[1], rows[2]

	threadLine := RenderThreadRow(threadRow, th, 80, identityAddr)
	if !strings.HasPrefix(threadLine, markCell) {
		t.Errorf("thread row with a buried for-you member missing its mark: %q", threadLine)
	}

	// The middle member is also the operator's own sent message — never
	// for-you — so its own child row must NOT carry the mark, even though
	// the thread row (aggregating every member, including the newest — which
	// under sp035's fold is never itself a child row) does.
	middleChildLine := RenderThreadRow(middleChildRow, th, 80, identityAddr)
	if strings.HasPrefix(middleChildLine, markCell) {
		t.Errorf("child row for the operator's own sent message wrongly marked: %q", middleChildLine)
	}

	// The older child row IS the for-you message and must carry its own mark.
	olderChildLine := RenderThreadRow(olderChildRow, th, 80, identityAddr)
	if !strings.HasPrefix(olderChildLine, markCell) {
		t.Errorf("child row for the for-you message missing its mark: %q", olderChildLine)
	}
}

// TestRenderLog_NarrowWidthDropsParticipantsKeepsGlyphAndSubject is the
// test_plan's named case: at 24/32/40 cells no rendered line exceeds width,
// and the glyph and SUBJECT survive even once PARTICIPANTS has dropped.
func TestRenderLog_NarrowWidthDropsParticipantsKeepsGlyphAndSubject(t *testing.T) {
	th, rows := threadFixture()
	threadRow, childRow := rows[0], rows[1]

	for _, width := range []int{24, 32, 40} {
		for _, row := range []LogRow{threadRow, childRow} {
			line := RenderThreadRow(row, th, width, identityAddr)
			if got := displayWidth(line); got > width {
				t.Errorf("width=%d kind=%v: line is %d cells wide: %q", width, row.Kind, got, line)
			}
		}

		// The glyph survives even at the narrowest width tested — a
		// collapsed list whose expansion state is invisible cannot be
		// navigated.
		collapsed := threadRow
		collapsed.Expanded = false
		line := RenderThreadRow(collapsed, th, width, identityAddr)
		if !strings.Contains(line, ">") {
			t.Errorf("width=%d: collapsed glyph dropped: %q", width, line)
		}
	}

	// At the narrowest tested width, PARTICIPANTS has actually dropped —
	// otherwise this test would not be exercising the drop path at all.
	cols := fitThreadColumns(24, true)
	for _, c := range cols {
		if c == threadColParticipants {
			t.Fatalf("fixture drift: PARTICIPANTS still fits at width 24: %v", cols)
		}
	}
}

// TestRenderLog_ThreadRowNeutralisesControlBytes is the test_plan's named
// case: an envelope carrying \x1b[2J renders with no 0x1b byte, on both row
// kinds — this pane renders other agents' bytes.
func TestRenderLog_ThreadRowNeutralisesControlBytes(t *testing.T) {
	hostile := source.Message{
		At: "2026-09-12T12:00:00.000000Z", ID: "a1",
		From: "worker-a", To: []string{"jan"}, Kind: "message",
		Content:     json.RawMessage(`"\u001b[2Jclear the screen"`),
		FromAddress: "a01M2M36Y5KJJ0YARD1BWORKERA",
		ToAddresses: []string{identityAddr},
	}
	threads := Threads([]source.Message{hostile})
	rows := ThreadRows(threads, func(string) bool { return true })

	for _, row := range rows {
		line := RenderThreadRow(row, threads[0], 80, identityAddr)
		if strings.ContainsRune(line, 0x1b) {
			t.Errorf("kind=%v: rendered line still carries an ESC byte: %q", row.Kind, line)
		}
	}
}

// TestRenderLog_FlatOutputUnchanged pins RenderLog's flat output to the
// exact bytes it rendered before Task 3 touched this file — the golden
// frame the test_plan names. It is the byte-identity half of criterion 5;
// TestRenderLog_HeaderAndColumns etc. above it stay untouched as the
// existing-assertion half.
func TestRenderLog_FlatOutputUnchanged(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 1, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}

	want := []string{
		"messages — updated 30s ago",
		"TIME     FROM         TO               SUBJECT              ",
		"12:00:00 r2           brainstorm-1     Say the single word:…",
		"12:01:00 smoke-opera… peer-1,peer-2    fan-out              ",
	}
	got := RenderLog(sample, false, now, 60)
	if len(got) != len(want) {
		t.Fatalf("got %d lines, want %d:\n%q\nwant:\n%q", len(got), len(want), got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("line %d = %q, want %q", i, got[i], want[i])
		}
	}
}

// truncateHeadCells keeps the TAIL, which is where the operator is typing.
// A draft truncated from the other end would show them the beginning of a
// query they have stopped looking at and hide the characters they just
// pressed.
func TestRenderLog_LongDraftKeepsTheTypedTail(t *testing.T) {
	header := RenderLog(&source.MessageSample{Messages: sampleMessages(), At: time.Now()}, false, time.Now(), 60, LogSignals{
		FilterEditing: true,
		FilterDraft:   "prefix-nobody-is-looking-at-anymore-but-tail-marker-XYZ",
		Pending:       9,
		ForYou:        3,
		Identity:      identityAddr,
	})[0]

	if !strings.Contains(header, "XYZ") {
		t.Errorf("the tail the operator just typed is missing: %q", header)
	}
}

// --- sp034 Task 6: the thread grid's own column header + assembler --------

// threadFixtureThreadsByKey adapts threadFixture's single thread into the
// map[string]Thread RenderThreadLog takes.
func threadFixtureThreadsByKey(th Thread) map[string]Thread {
	return map[string]Thread{th.Key: th}
}

// TestRenderThreadLog_HeaderColumnsMatchRowGrid is threadColumnHeaderLine's
// own version of TestRenderLog_ThreadRowGridMatchesChildGrid: the header row
// RenderThreadLog prints must lay SUBJECT out at the SAME column index as the
// data rows beneath it, computed from the rendered strings rather than a
// hardcoded literal — Task 3 shipped a speculative ThreadColumnHeaderLine and
// deleted it, unused, before anything could pin this; this is that pin.
func TestRenderThreadLog_HeaderColumnsMatchRowGrid(t *testing.T) {
	th, rows := threadFixture()
	lines := RenderThreadLog(rows, threadFixtureThreadsByKey(th), true, time.Now(), false, time.Now(), 80)
	if len(lines) != 2+len(rows) {
		t.Fatalf("got %d lines, want %d (2 header + %d rows): %q", len(lines), 2+len(rows), len(rows), lines)
	}
	header := lines[1]
	dataLine := lines[2]

	idxHeader := strings.Index(header, "SUBJECT")
	idxData := strings.Index(dataLine, "distinctive-newest-subject")
	if idxHeader < 0 {
		t.Fatalf("column header lost SUBJECT: %q", header)
	}
	if idxData < 0 {
		t.Fatalf("thread row lost its SUBJECT: %q", dataLine)
	}
	if idxHeader != idxData {
		t.Fatalf("SUBJECT starts at different columns: header=%d row=%d\nheader: %q\nrow:    %q",
			idxHeader, idxData, header, dataLine)
	}
}

// TestRenderThreadLog_NoSampleRendersWaiting is RenderLog's nil-sample case
// restated for the row-list caller, which carries no *source.MessageSample
// of its own to be nil — haveSample is how it says the same thing.
func TestRenderThreadLog_NoSampleRendersWaiting(t *testing.T) {
	lines := RenderThreadLog(nil, nil, false, time.Time{}, false, time.Now(), 80)
	if len(lines) != 1 || lines[0] != "messages — waiting for first sample" {
		t.Fatalf("got %v, want the waiting-for-first-sample line", lines)
	}
}

// TestRenderThreadLog_EmptyRowsRendersNoMessages is RenderLog's empty-sample
// case restated: a sample that exists but flattens to zero rows (a filter
// matching nothing, or a genuinely empty bus) renders the placeholder, not an
// empty pane.
func TestRenderThreadLog_EmptyRowsRendersNoMessages(t *testing.T) {
	lines := RenderThreadLog(nil, nil, true, time.Now(), false, time.Now(), 80)
	if len(lines) != 3 || lines[2] != "(no messages)" {
		t.Fatalf("got %v, want a 2-line header plus \"(no messages)\"", lines)
	}
}

// TestRenderThreadLog_RendersRowsInGivenOrder asserts RenderThreadLog
// establishes no order of its own (## plan's "do not derive a second
// order"): the three rows come out in exactly the sequence they were given —
// thread, middle child, older child — matching threadFixture's own row
// order. Row 1 carrying the MIDDLE member's own subject (not the newest's,
// repeated) is the fix sp035 exists for: a fold that duplicated the newest
// member as its own first child would show "distinctive-newest-subject"
// here too.
func TestRenderThreadLog_RendersRowsInGivenOrder(t *testing.T) {
	th, rows := threadFixture()
	lines := RenderThreadLog(rows, threadFixtureThreadsByKey(th), true, time.Now(), false, time.Now(), 80)

	data := lines[2:]
	if len(data) != 3 {
		t.Fatalf("got %d data rows, want 3: %q", len(data), data)
	}
	if !strings.Contains(data[0], "3") { // the thread row's own N cell (conversation total)
		t.Errorf("row 0 is not the thread's summary row: %q", data[0])
	}
	if !strings.Contains(data[1], "distinctive-middle-subject") {
		t.Errorf("row 1 is not the middle child: %q", data[1])
	}
	if !strings.Contains(data[2], "distinctive-older-subject") {
		t.Errorf("row 2 is not the older child: %q", data[2])
	}
}

// TestRenderThreadLog_HeaderCarriesPendingForYouAndIdentity is the
// threaded-header twin of RenderLog's own Pending/ForYou/Identity coverage —
// logHeaderLine is shared code, but this pins that RenderThreadLog actually
// reaches it with the signals it was given, not a zero LogSignals{}.
func TestRenderThreadLog_HeaderCarriesPendingForYouAndIdentity(t *testing.T) {
	th, rows := threadFixture()
	header := RenderThreadLog(rows, threadFixtureThreadsByKey(th), true, time.Now(), false, time.Now(), 100, LogSignals{
		Pending:  7,
		ForYou:   2,
		Identity: identityAddr,
	})[0]

	for _, want := range []string{"+7 new", "2 for you"} {
		if !strings.Contains(header, want) {
			t.Errorf("threaded header lost %q: %q", want, header)
		}
	}
}

// --- dotfiles-br55 / dotfiles-qm4h Task 1: pad neutralises every grid cell -

// TestRenderLog_HostileLabelIsNeutralisedInFlatGrid is the dotfiles-br55
// fixture verbatim: a message whose From/To carry a live ESC. Before this
// task, msgCellFor's From/To path (orDash(shortAddress(m.From)) /
// toCellShort(m.To)) reached the terminal with no neutralize() anywhere —
// only SUBJECT, via DeriveSubject, was ever cleaned. Every rendered line
// must now be free of the raw ESC byte, not just the SUBJECT column's.
func TestRenderLog_HostileLabelIsNeutralisedInFlatGrid(t *testing.T) {
	hostile := source.Message{
		At: "2026-09-12T12:00:00.000000Z", ID: "a1",
		From: "w\x1b[31ma", To: []string{"j\x1b[0mx"}, Kind: "message",
		Content: json.RawMessage(`"harmless content"`),
	}
	sample := &source.MessageSample{Messages: []source.Message{hostile}, At: time.Now()}
	lines := RenderLog(sample, false, time.Now(), 100)

	for i, l := range lines {
		if strings.ContainsRune(l, 0x1b) {
			t.Errorf("line %d still carries an ESC byte: %q", i, l)
		}
	}
	if !strings.Contains(lines[len(lines)-1], "harmless content") {
		t.Fatalf("row should still render its SUBJECT, not just lose the hostile label: %q", lines[len(lines)-1])
	}
}

// TestRenderThreadLog_HostileLabelIsNeutralisedInParticipantsAndChildRow is
// the thread-grid twin of the flat-grid test above, and the other two cells
// dotfiles-br55 named: the thread row's PARTICIPANTS (thread.Participants,
// sp034 Task 1's participantLabels, carried verbatim into
// threadParticipantsCell) and a child row's indented FROM
// (threadParticipantIndent + orDash(shortAddress(row.Message.From))).
// Both messages share the SAME hostile From/To pair so the label survives
// participantLabels' first-message-wins race regardless of which message it
// picks, and both hit the SAME cells br55 proved leaky on branch dec4f10a.
func TestRenderThreadLog_HostileLabelIsNeutralisedInParticipantsAndChildRow(t *testing.T) {
	older := source.Message{
		At: "2026-09-12T12:00:00.000000Z", ID: "a1",
		From: "w\x1b[31ma", To: []string{"j\x1b[0mx"}, Kind: "message",
		Content:     json.RawMessage(`"harmless-older"`),
		FromAddress: "a01M2M36Y5KJJ0YARD1BWORKERA",
		ToAddresses: []string{identityAddr},
	}
	newer := source.Message{
		At: "2026-09-12T12:05:00.000000Z", ID: "a2",
		From: "w\x1b[31ma", To: []string{"j\x1b[0mx"}, Kind: "message",
		Content:     json.RawMessage(`"harmless-newer"`),
		FromAddress: "a01M2M36Y5KJJ0YARD1BWORKERA",
		ToAddresses: []string{identityAddr},
	}
	threads := Threads([]source.Message{older, newer})
	if len(threads) != 1 {
		t.Fatalf("fixture drift: want one thread, got %d", len(threads))
	}
	th := threads[0]
	if !strings.ContainsRune(strings.Join(th.Participants, ""), 0x1b) {
		t.Fatalf("fixture drift: Participants lost the hostile label before rendering: %+v", th.Participants)
	}
	rows := ThreadRows(threads, func(string) bool { return true })
	if len(rows) != 2 || rows[0].Kind != KindThread || rows[1].Kind != KindMessage {
		t.Fatalf("fixture drift: want thread row + one child row, got %+v", rows)
	}

	threadLine := RenderThreadRow(rows[0], th, 80, "")
	if strings.ContainsRune(threadLine, 0x1b) {
		t.Errorf("thread row (PARTICIPANTS) still carries an ESC byte: %q", threadLine)
	}
	childLine := RenderThreadRow(rows[1], th, 80, "")
	if strings.ContainsRune(childLine, 0x1b) {
		t.Errorf("child row (indented FROM) still carries an ESC byte: %q", childLine)
	}
}
