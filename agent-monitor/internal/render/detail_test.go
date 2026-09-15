package render

import (
	"encoding/json"
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
