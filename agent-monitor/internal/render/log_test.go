package render

import (
	"encoding/json"
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

func TestRenderLog_NewestLast(t *testing.T) {
	at := time.Now()
	sample := &source.MessageSample{Messages: sampleMessages(), At: at}
	lines := RenderLog(sample, false, at, 100)
	// Row order mirrors sample order (ascending id/time): the last data row
	// is the fan-out (newer) message.
	last := lines[len(lines)-1]
	if !strings.Contains(last, "fan-out") {
		t.Fatalf("last row = %q, want the newer (fan-out) message last", last)
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
