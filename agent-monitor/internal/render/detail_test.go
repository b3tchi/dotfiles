package render

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"agent-monitor/internal/source"
)

// detailMsg builds a source.Message for one of the four wire kinds
// (inbox/result/error/identity — ft014's data_model as corrected by
// dotfiles-9oa4) with the given content.
func detailMsg(kind string, from string, to []string, content string) *source.Message {
	return &source.Message{
		At:      "2026-09-12T12:01:00.000000Z",
		ID:      "a1",
		From:    from,
		To:      to,
		Kind:    kind,
		Content: json.RawMessage(content),
	}
}

// Table over the four envelope kinds: header shape (from -> to, time, kind)
// and body path (pretty-vs-raw) must both hold regardless of which kind the
// envelope carries — the detail pane does not special-case by kind the way
// DeriveSubject's "state" branch does.
func TestRenderDetail_HeaderAndBody_AllFourKinds(t *testing.T) {
	cases := []struct {
		kind           string
		content        string
		wantBodySubstr string
	}{
		{"message", `"ping-verify"`, "ping-verify"},
		{"state", `{"status":"complete","summary":"delivered"}`, `"status": "complete"`},
		{"state", `{"status":"protocol_error","detail":"no result tool"}`, `"status": "protocol_error"`},
		{"unknown-kind", `{"run":"r1","uid":"peer-1"}`, `"run": "r1"`},
	}
	for _, c := range cases {
		t.Run(c.kind, func(t *testing.T) {
			msg := detailMsg(c.kind, "peer-1", []string{"peer-2"}, c.content)
			lines := RenderDetail(msg, 80, 20)
			if len(lines) < 2 {
				t.Fatalf("got %d lines, want header + body: %v", len(lines), lines)
			}
			header := lines[0]
			for _, want := range []string{"peer-1", "peer-2", "→", "12:01:00", c.kind} {
				if !strings.Contains(header, want) {
					t.Errorf("header %q missing %q", header, want)
				}
			}
			body := strings.Join(lines[1:], "\n")
			if !strings.Contains(body, c.wantBodySubstr) {
				t.Errorf("body %q, want it to contain %q", body, c.wantBodySubstr)
			}
		})
	}
}

func TestRenderDetail_JSONBody_Indented(t *testing.T) {
	msg := detailMsg("state", "peer-1", []string{"peer-2"}, `{"status":"complete","summary":"delivered"}`)
	lines := RenderDetail(msg, 80, 20)
	body := strings.Join(lines[1:], "\n")
	if !strings.Contains(body, "\"status\": \"complete\"") {
		t.Fatalf("body %q, want indented JSON (key: value spacing)", body)
	}
	// Indentation produces more than one body line for a multi-field object.
	if len(lines) < 4 {
		t.Fatalf("got %d lines, want header plus multiple indented body lines: %v", len(lines), lines)
	}
}

func TestRenderDetail_NonJSONBody_RawPassthrough(t *testing.T) {
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, "not json at all")
	lines := RenderDetail(msg, 80, 20)
	body := strings.Join(lines[1:], "\n")
	if !strings.Contains(body, "not json at all") {
		t.Fatalf("body %q, want raw passthrough of non-JSON content", body)
	}
}

func TestRenderDetail_MalformedJSONBody_RawFallback_NoError(t *testing.T) {
	// Looks like it should be JSON (starts with '{') but is truncated /
	// invalid. Must fall back to raw, never error, never blank.
	msg := detailMsg("state", "peer-1", []string{"peer-2"}, `{"status":"protocol_error","detail":`)
	lines := RenderDetail(msg, 80, 20)
	body := strings.Join(lines[1:], "\n")
	if !strings.Contains(body, `"status":"protocol_error"`) {
		t.Fatalf("body %q, want raw fallback of the malformed JSON text", body)
	}
}

func TestRenderDetail_ANSIEscapes_Neutralised(t *testing.T) {
	// A literal raw ESC byte (not a \x1b escape sequence) is embedded
	// directly in this string literal, matching subject_test.go's
	// TestDeriveSubject_ANSIEscapes_Neutralised precedent — the byte must be
	// real for the assertion to prove neutralize actually strips it.
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, `"[31mRED[0m ping"`)
	lines := RenderDetail(msg, 80, 20)
	for _, l := range lines {
		if strings.ContainsRune(l, 0x1b) {
			t.Fatalf("line %q contains raw ESC byte, want it neutralised", l)
		}
		if strings.Contains(l, "\x1b[") {
			t.Fatalf("line %q contains a raw CSI introducer", l)
		}
	}
}

// C1 control codes are the 8-bit single-byte form of the same control
// functions; asserted separately per subject_test.go's precedent because
// dropping ESC alone does not close this hole. A real U+009D byte (the
// 8-bit OSC introducer) is embedded inside a JSON string value, matching
// the task's edge_cases case exactly.
func TestRenderDetail_C1ControlCode_Neutralised(t *testing.T) {
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, `{"note":"ab"}`)
	lines := RenderDetail(msg, 80, 20)
	for _, l := range lines {
		for _, r := range l {
			if r >= 0x80 && r <= 0x9f {
				t.Fatalf("line %q contains raw C1 control rune %U, want it neutralised", l, r)
			}
		}
	}
}

func TestRenderDetail_CJKBody_WrapsOnCellBoundary_NoLineExceedsWidth(t *testing.T) {
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, `"日本語テスト日本語テスト日本語テスト"`)
	width := 10
	lines := RenderDetail(msg, width, 20)
	for _, l := range lines {
		if w := displayWidth(l); w > width {
			t.Fatalf("line %q is %d cells wide, want <= %d", l, w, width)
		}
	}
	// The CJK body itself must appear, split across more than one body line
	// since it is far wider than the 10-cell budget.
	body := strings.Join(lines[1:], "")
	if !strings.Contains(body, "日本語") {
		t.Fatalf("body lines %v, want the CJK content preserved across wraps", lines)
	}
}

func TestRenderDetail_OverLongBody_TruncationIndicatorPresent(t *testing.T) {
	// One 64 KiB line — the envelope cap — must not be rendered in full, and
	// the cut must be visibly marked, bounded by a small height.
	huge := strings.Repeat("x", 64*1024)
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, `"`+huge+`"`)
	height := 5
	lines := RenderDetail(msg, 40, height)
	if len(lines) > height {
		t.Fatalf("got %d lines, want at most height=%d", len(lines), height)
	}
	last := lines[len(lines)-1]
	if !strings.Contains(last, "…") {
		t.Fatalf("last line %q, want a visible truncation indicator", last)
	}
}

func TestRenderDetail_DeepNestedJSON_IndentationRespectsWidth(t *testing.T) {
	nested := `{"a":{"b":{"c":{"d":{"e":{"f":"deep value here"}}}}}}`
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, nested)
	width := 20
	lines := RenderDetail(msg, width, 40)
	for _, l := range lines {
		if w := displayWidth(l); w > width {
			t.Fatalf("line %q is %d cells wide, want <= %d (deep indentation must not overrun the width budget)", l, w, width)
		}
	}
}

func TestRenderDetail_MultiRecipient_ListsAll(t *testing.T) {
	msg := detailMsg("message", "peer-1", []string{"peer-2", "peer-3"}, `"fan-out"`)
	lines := RenderDetail(msg, 80, 20)
	if !strings.Contains(lines[0], "peer-2,peer-3") {
		t.Fatalf("header %q, want both recipients listed like the log's TO column", lines[0])
	}
}

func TestRenderDetail_NilMessage_PlaceholderNotPanic(t *testing.T) {
	lines := RenderDetail(nil, 80, 20)
	if len(lines) == 0 {
		t.Fatalf("got no lines, want a placeholder line")
	}
	if strings.TrimSpace(lines[0]) == "" {
		t.Fatalf("got blank placeholder line, want visible text")
	}
}

func TestRenderDetail_Bounded_NoLineExceedsWidth_AnyBody(t *testing.T) {
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, `"a fairly long line of plain text that should wrap across several rows of the pane"`)
	width := 12
	lines := RenderDetail(msg, width, 30)
	for _, l := range lines {
		if w := displayWidth(l); w > width {
			t.Fatalf("line %q is %d cells wide, want <= %d", l, w, width)
		}
	}
}

// TestRenderDetail_HeightZero_NoClampNoIndicator is sp032 T4 criterion 2's
// first half: height <= 0 means "do not clamp" — the same spelling
// paneBudgets/buildFrame already use — so the caller gets the WHOLE body and
// no truncation indicator. This is what feeds the detail viewport: a body
// pre-clamped to the pane budget could not be scrolled, because the rows
// past the budget would never have been rendered at all.
func TestRenderDetail_HeightZero_NoClampNoIndicator(t *testing.T) {
	// 40 physical body lines: one per object key, produced by json.Indent,
	// plus the opening and closing braces.
	var b strings.Builder
	b.WriteString("{")
	for i := 0; i < 40; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `"k%02d":"v%02d"`, i, i)
	}
	b.WriteString("}")
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, b.String())

	for _, height := range []int{0, -1, -7} {
		lines := RenderDetail(msg, 80, height)
		if len(lines) != 43 { // header + "{" + 40 keys + "}"
			t.Fatalf("height=%d: got %d lines, want the unclamped 43", height, len(lines))
		}
		if !strings.Contains(lines[len(lines)-1], "}") {
			t.Errorf("height=%d: last line %q, want the body's real last line", height, lines[len(lines)-1])
		}
		for _, l := range lines {
			if strings.Contains(l, "…") || strings.Contains(l, "not shown") {
				t.Fatalf("height=%d: line %q carries a truncation indicator, want none", height, l)
			}
		}
	}

	// The nil-message placeholder takes the same path: one line, no
	// indicator, never the nil slice clampToHeight used to return here.
	if got := RenderDetail(nil, 80, 0); len(got) != 1 || strings.Contains(got[0], "…") {
		t.Fatalf("RenderDetail(nil, 80, 0) = %q, want exactly the placeholder line", got)
	}
}

// TestRenderDetail_HeightPositive_TruncationUnchanged is criterion 2's
// second half, pinned BYTE-FOR-BYTE rather than by "contains an ellipsis":
// extending the height <= 0 convention must not move the positive-height
// clamp by a single character. The expectation is written out literally so a
// change to the indicator's wording, its count, or the number of body lines
// kept fails here instead of being absorbed by a Contains check.
func TestRenderDetail_HeightPositive_TruncationUnchanged(t *testing.T) {
	var b strings.Builder
	b.WriteString("{")
	for i := 0; i < 40; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `"k%02d":"v%02d"`, i, i)
	}
	b.WriteString("}")
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, b.String())

	full := RenderDetail(msg, 80, 0)
	if len(full) != 43 {
		t.Fatalf("setup: unclamped render is %d lines, want 43", len(full))
	}

	const height = 5
	got := RenderDetail(msg, 80, height)
	want := []string{full[0], full[1], full[2], full[3], "… (39 more line(s) not shown)"}
	if len(got) != len(want) {
		t.Fatalf("got %d lines, want %d: %q", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("line %d = %q, want %q", i, got[i], want[i])
		}
	}
}
