package render

import (
	"encoding/json"
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
