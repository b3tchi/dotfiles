package render

import (
	"strings"
	"testing"
)

func TestDeriveSubject_Message_FirstLineOfContent(t *testing.T) {
	got := DeriveSubject("message", []byte(`"ping-verify"`), 40)
	if got != "ping-verify" {
		t.Fatalf("got %q, want %q", got, "ping-verify")
	}
}

func TestDeriveSubject_Message_MultilineContent_TakesFirstLineOnly(t *testing.T) {
	got := DeriveSubject("message", []byte(`"line one\nline two\nline three"`), 40)
	if got != "line one" {
		t.Fatalf("got %q, want %q", got, "line one")
	}
}

func TestDeriveSubject_State_StatusEmDashSummary(t *testing.T) {
	content := []byte(`{"status":"complete","summary":"delivered","window":"x@y","session":"s1"}`)
	got := DeriveSubject("state", content, 60)
	want := "complete — delivered"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestDeriveSubject_State_MissingStatusOrSummary_FallsBackToRawFirstLine(t *testing.T) {
	// A state envelope that (for whatever reason) lacks the expected fields
	// still must not blank the subject column: fall back to the same raw
	// first-line treatment "anything else" gets.
	content := []byte(`{"window":"x@y"}`)
	got := DeriveSubject("state", content, 60)
	if got == "" {
		t.Fatalf("got empty subject, want raw fallback")
	}
	if !strings.Contains(got, "window") {
		t.Fatalf("got %q, want it to contain the raw content", got)
	}
}

// dotfiles-oj4c: what used to be an "error" envelope is a state whose status
// is `protocol_error`, so it now gets the SAME status-derived subject a
// completion does — the widening this port was for. It used to fall through to
// the raw JSON blob, because "error" was not the one kind the branch keyed on.
//
// dotfiles-k77t: that port also dropped the only text such an envelope has.
// A protocol_error carries {status, detail} and no summary, so the column read
// "protocol_error — " and WHY the worker was reported never reached the
// operator — strictly less than the raw blob it replaced. The tail is the
// summary when there is one and the detail otherwise.
func TestDeriveSubject_State_ProtocolError_CarriesItsDetailAsTheTail(t *testing.T) {
	content := []byte(`{"status":"protocol_error","detail":"agent settled without calling the typed result tool"}`)
	got := DeriveSubject("state", content, 200)
	want := "protocol_error — agent settled without calling the typed result tool"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// Summary stays the tail when an envelope carries both: `detail` is the
// fallback for the envelopes that have no summary, not a replacement for the
// field every reported result writes.
func TestDeriveSubject_State_SummaryWinsOverDetail(t *testing.T) {
	content := []byte(`{"status":"failed","summary":"tests red","detail":"exit 1"}`)
	got := DeriveSubject("state", content, 200)
	want := "failed — tests red"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// A status with neither is still rendered with its empty tail rather than
// falling through to the raw blob — the shape dotfiles-oj4c's design note
// accepted for a blocked worker ("waiting_human — ") and this change does not
// revisit.
func TestDeriveSubject_State_NeitherSummaryNorDetail_KeepsTheEmptyTail(t *testing.T) {
	content := []byte(`{"status":"waiting_human"}`)
	got := DeriveSubject("state", content, 200)
	want := "waiting_human — "
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// A blocked worker's question is its summary (dotfiles-oj4c's design note), so
// it reads in the log exactly like any other reported state. This is the other
// half of the widening: `blocked` never reached this branch either.
func TestDeriveSubject_State_Blocked_GetsTheStatusDerivation(t *testing.T) {
	content := []byte(`{"status":"blocked","summary":"which workspace should I use?"}`)
	got := DeriveSubject("state", content, 200)
	want := "blocked — which workspace should I use?"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// A kind outside the vocabulary is not special-cased into anything: it gets
// the raw first line, which is the honest rendering for content this code has
// no contract for.
func TestDeriveSubject_UnknownKind_RawFirstLineOfContent(t *testing.T) {
	content := []byte(`{"run":"r1","uid":"peer-1"}`)
	got := DeriveSubject("identity", content, 200)
	want := `{"run":"r1","uid":"peer-1"}`
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// The JSON-blob edge case: content that is itself a JSON object rather than
// plain text. The task's edge_cases are explicit that the outcome is "the
// first line is the blob, truncated — ugly and correct" and that this case
// is asserted so nobody "fixes" it by parsing.
func TestDeriveSubject_JSONBlobContent_TruncatedRawNotParsed(t *testing.T) {
	content := []byte(`{"foo":"bar","baz":1,"nested":{"a":1}}`)
	got := DeriveSubject("message", content, 15)
	// Never longer than the declared width in display cells.
	if w := displayWidth(got); w > 15 {
		t.Fatalf("subject %q is %d cells wide, want <= 15", got, w)
	}
	// Truncated with an explicit ellipsis, not silently cut.
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("got %q, want a truncated-with-ellipsis raw blob", got)
	}
	// It must be a prefix of the raw blob text, not a parsed/pretty version.
	if !strings.HasPrefix(`{"foo":"bar","baz":1,"nested":{"a":1}}`, strings.TrimSuffix(got, "…")) {
		t.Fatalf("got %q, want a raw prefix of the blob", got)
	}
}

// The security-shaped case: content carrying raw ANSI/control bytes must
// never reach the terminal unneutralised — a message payload must not be
// able to reposition the cursor, clear the display, or repaint the roster
// pane above it.
func TestDeriveSubject_ANSIEscapes_Neutralised(t *testing.T) {
	content := []byte(`"[31mRED[0m ping"`)
	got := DeriveSubject("message", content, 80)
	if strings.ContainsRune(got, 0x1b) {
		t.Fatalf("got %q, want no raw ESC byte reaching the render", got)
	}
	if strings.Contains(got, "\x1b[") {
		t.Fatalf("got %q, want the CSI introducer removed", got)
	}
}

func TestDeriveSubject_ControlCharacters_Neutralised(t *testing.T) {
	content := []byte(`"a\u0007b\u0000c"`) // BEL, NUL embedded mid-content
	got := DeriveSubject("message", content, 80)
	for _, r := range got {
		if r < 0x20 {
			t.Fatalf("got %q, contains raw control rune %U", got, r)
		}
	}
}

// C1 control codes (U+0080-U+009F) are the 8-bit single-byte forms of the
// same control functions C0/ESC sequences introduce in 7-bit form -- U+009D
// is the 8-bit OSC (Operating System Command) introducer, honoured by some
// terminal emulators exactly like the 7-bit ESC ] form. Neutralising ESC
// alone defuses the 7-bit form; this asserts the 8-bit form is stripped too.
func TestDeriveSubject_C1ControlCode_Neutralised(t *testing.T) {
	content := []byte(`"a\u009db"`)
	got := DeriveSubject("message", content, 80)
	for _, r := range got {
		if r >= 0x80 && r <= 0x9f {
			t.Fatalf("got %q, contains raw C1 control rune %U", got, r)
		}
	}
}

// Wide (CJK) characters: truncation must count display cells, not bytes or
// runes, and must never split a wide character across the cut.
func TestDeriveSubject_CJK_TruncatesOnCellBoundary(t *testing.T) {
	content := []byte(`"日本語テストabc"`) // each of the first four runes is 2 cells wide
	got := DeriveSubject("message", content, 5)

	if w := displayWidth(got); w > 5 {
		t.Fatalf("subject %q is %d cells wide, want <= 5", got, w)
	}
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("got %q, want truncation with an explicit ellipsis", got)
	}
	body := strings.TrimSuffix(got, "…")
	// The body must be exactly the first two wide runes (4 cells) plus the
	// 1-cell ellipsis = 5, landing on a whole-rune boundary, never a partial
	// character.
	if body != "日本" {
		t.Fatalf("got body %q, want %q (cut on a cell boundary)", body, "日本")
	}
}

func TestDeriveSubject_Emoji_CountsAsWide(t *testing.T) {
	content := []byte(`"😀😀😀 hello"`)
	got := DeriveSubject("message", content, 5)
	if w := displayWidth(got); w > 5 {
		t.Fatalf("subject %q is %d cells wide, want <= 5", got, w)
	}
}

func TestDeriveSubject_FitsExactlyNoTruncation(t *testing.T) {
	got := DeriveSubject("message", []byte(`"hi"`), 2)
	if got != "hi" {
		t.Fatalf("got %q, want %q (no ellipsis when it already fits)", got, "hi")
	}
}

func TestDeriveSubject_EmptyContent(t *testing.T) {
	got := DeriveSubject("message", []byte(`""`), 10)
	if got != "" {
		t.Fatalf("got %q, want empty", got)
	}
}

// TestTruncateHeadCells_KeepsTheTailNotTheHead is dotfiles-jw73 rejection
// #1's fix: truncateCells (above) drops from the back and keeps the head,
// which is right for a subject line but wrong for a filter draft — an
// operator types at the END, so the characters worth keeping under a
// squeeze are the ones nearest the cursor, not the ones typed first.
// truncateHeadCells is that mirror: drop from the FRONT, keep the tail, put
// the ellipsis first.
func TestTruncateHeadCells_KeepsTheTailNotTheHead(t *testing.T) {
	got := truncateHeadCells("claude-main-worker-7", 10)
	if got != "…-worker-7" {
		t.Fatalf("got %q, want the tail kept with a leading ellipsis", got)
	}
	if w := displayWidth(got); w > 10 {
		t.Fatalf("got %q, %d cells wide, want <= 10", got, w)
	}
}

func TestTruncateHeadCells_FitsExactlyNoTruncation(t *testing.T) {
	if got := truncateHeadCells("hi", 5); got != "hi" {
		t.Fatalf("got %q, want %q (no ellipsis when it already fits)", got, "hi")
	}
}

func TestTruncateHeadCells_WidthOneIsJustTheEllipsis(t *testing.T) {
	if got := truncateHeadCells("overflowing", 1); got != "…" {
		t.Fatalf("got %q, want just the ellipsis at width 1", got)
	}
}

func TestTruncateHeadCells_ZeroOrNegativeWidthIsEmpty(t *testing.T) {
	for _, w := range []int{0, -1} {
		if got := truncateHeadCells("anything", w); got != "" {
			t.Fatalf("width=%d: got %q, want empty", w, got)
		}
	}
}

func TestTruncateHeadCells_CJK_TruncatesOnCellBoundary(t *testing.T) {
	got := truncateHeadCells("filter日本語query", 8)
	if w := displayWidth(got); w > 8 {
		t.Fatalf("got %q, %d cells wide, want <= 8", got, w)
	}
	if !strings.HasSuffix(got, "query") {
		t.Fatalf("got %q, want the tail (%q) kept", got, "query")
	}
}
