package render

import (
	"strings"
	"testing"
)

func TestDeriveSubject_Message_FirstLineOfContent(t *testing.T) {
	got := DeriveSubject("inbox", []byte(`"ping-verify"`), 40)
	if got != "ping-verify" {
		t.Fatalf("got %q, want %q", got, "ping-verify")
	}
}

func TestDeriveSubject_Message_MultilineContent_TakesFirstLineOnly(t *testing.T) {
	got := DeriveSubject("inbox", []byte(`"line one\nline two\nline three"`), 40)
	if got != "line one" {
		t.Fatalf("got %q, want %q", got, "line one")
	}
}

func TestDeriveSubject_Result_StatusEmDashSummary(t *testing.T) {
	content := []byte(`{"status":"complete","summary":"delivered","window":"x@y","session":"s1"}`)
	got := DeriveSubject("result", content, 60)
	want := "complete — delivered"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestDeriveSubject_Result_MissingStatusOrSummary_FallsBackToRawFirstLine(t *testing.T) {
	// A result envelope that (for whatever reason) lacks the expected fields
	// still must not blank the subject column: fall back to the same raw
	// first-line treatment "anything else" gets.
	content := []byte(`{"window":"x@y"}`)
	got := DeriveSubject("result", content, 60)
	if got == "" {
		t.Fatalf("got empty subject, want raw fallback")
	}
	if !strings.Contains(got, "window") {
		t.Fatalf("got %q, want it to contain the raw content", got)
	}
}

func TestDeriveSubject_Error_RawFirstLineOfContent(t *testing.T) {
	content := []byte(`{"code":"protocol_error","detail":"agent settled without calling the typed result tool"}`)
	got := DeriveSubject("error", content, 200)
	want := `{"code":"protocol_error","detail":"agent settled without calling the typed result tool"}`
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestDeriveSubject_Identity_RawFirstLineOfContent(t *testing.T) {
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
	got := DeriveSubject("inbox", content, 15)
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
	got := DeriveSubject("inbox", content, 80)
	if strings.ContainsRune(got, 0x1b) {
		t.Fatalf("got %q, want no raw ESC byte reaching the render", got)
	}
	if strings.Contains(got, "\x1b[") {
		t.Fatalf("got %q, want the CSI introducer removed", got)
	}
}

func TestDeriveSubject_ControlCharacters_Neutralised(t *testing.T) {
	content := []byte(`"a\u0007b\u0000c"`) // BEL, NUL embedded mid-content
	got := DeriveSubject("inbox", content, 80)
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
	got := DeriveSubject("inbox", content, 80)
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
	got := DeriveSubject("inbox", content, 5)

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
	got := DeriveSubject("inbox", content, 5)
	if w := displayWidth(got); w > 5 {
		t.Fatalf("subject %q is %d cells wide, want <= 5", got, w)
	}
}

func TestDeriveSubject_FitsExactlyNoTruncation(t *testing.T) {
	got := DeriveSubject("inbox", []byte(`"hi"`), 2)
	if got != "hi" {
		t.Fatalf("got %q, want %q (no ellipsis when it already fits)", got, "hi")
	}
}

func TestDeriveSubject_EmptyContent(t *testing.T) {
	got := DeriveSubject("inbox", []byte(`""`), 10)
	if got != "" {
		t.Fatalf("got %q, want empty", got)
	}
}
