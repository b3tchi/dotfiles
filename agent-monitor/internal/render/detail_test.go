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
// dotfiles-9oa4) with the given content. FromAddress/ToAddresses are left
// at their zero value — the pre-sp033-T1 shape — so every existing test
// built with this helper stays proof that an addressless envelope renders
// no address line.
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

// detailMsgAddr is detailMsg plus the sp033 T1 address fields, for sp035
// Task 3's fixtures — a resolved party's address, per adr0034, is never
// re-derived from its label, so tests exercise the address fields directly
// rather than deriving them from from/to.
func detailMsgAddr(kind, from string, to []string, fromAddr string, toAddrs []string, content string) *source.Message {
	msg := detailMsg(kind, from, to, content)
	msg.FromAddress = fromAddr
	msg.ToAddresses = toAddrs
	return msg
}

// addrPrefix11 is the shared first-eleven-characters prefix used across the
// address fixtures below — same-millisecond ULIDs per adr0034's minting
// scheme carry an identical leading timestamp segment, so any fixture that
// only varies its tail would pass under a head-truncating implementation.
// Sharing this prefix and varying only the tail is what makes
// TestRenderDetail_ShowsFullAddresses fail on a head-truncating renderer.
const addrPrefix11 = "a01M2TB0H5X"

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

// --- sp035 Task 3: detail pane carries the participants' addresses --------

// TestRenderDetail_ShowsFullAddresses is the test_plan's head-truncation
// trap: fromAddr and toAddr share their first eleven characters (the
// millisecond-timestamp segment two same-millisecond ULIDs share per
// adr0034), so an implementation that renders only a head slice of the
// address renders the two identically and this assertion catches it.
func TestRenderDetail_ShowsFullAddresses(t *testing.T) {
	fromAddr := addrPrefix11 + strings.Repeat("A", 16)
	toAddr := addrPrefix11 + strings.Repeat("B", 16)
	if len(fromAddr) != 27 || len(toAddr) != 27 {
		t.Fatalf("setup: fixture addresses must be 27 chars, got %d and %d", len(fromAddr), len(toAddr))
	}
	msg := detailMsgAddr("message", "claude-main", []string{"jan"}, fromAddr, []string{toAddr}, `"ping"`)
	lines := RenderDetail(msg, 80, 20)
	// Joined with "" rather than "\n": cell-aware wrapping (wrapCells) may
	// split an address across two display lines with no separator inserted
	// (subject.go's precedent, TestRenderDetail_CJKBody_WrapsOnCellBoundary),
	// so a "\n" join would falsely break a wrapped address's Contains check.
	joined := strings.Join(lines[1:], "")
	if !strings.Contains(joined, fromAddr) {
		t.Fatalf("output %q, want the full from-address %q present", joined, fromAddr)
	}
	if !strings.Contains(joined, toAddr) {
		t.Fatalf("output %q, want the full to-address %q present", joined, toAddr)
	}
}

// TestRenderDetail_SameLabelsDifferentAddressesDiffer is the live
// claude-main <> jan case: two envelopes carry identical From/To LABELS
// (adr0034 mints a fresh address per registration, so a re-registered
// session wears an old label) but different addresses. The rendered detail
// output must differ — the user-visible property this task exists for. No
// cosmetic implementation (e.g. one that renders addresses but ignores
// their actual value) satisfies this by accident.
func TestRenderDetail_SameLabelsDifferentAddressesDiffer(t *testing.T) {
	fromAddrA := addrPrefix11 + strings.Repeat("1", 16)
	toAddrA := addrPrefix11 + strings.Repeat("2", 16)
	fromAddrB := addrPrefix11 + strings.Repeat("3", 16)
	toAddrB := addrPrefix11 + strings.Repeat("4", 16)

	msgA := detailMsgAddr("message", "claude-main", []string{"jan"}, fromAddrA, []string{toAddrA}, `"hello"`)
	msgB := detailMsgAddr("message", "claude-main", []string{"jan"}, fromAddrB, []string{toAddrB}, `"hello"`)

	linesA := RenderDetail(msgA, 80, 20)
	linesB := RenderDetail(msgB, 80, 20)

	if linesA[0] != linesB[0] {
		t.Fatalf("headers differ (%q vs %q), want identical labels producing identical headers — setup invariant broken", linesA[0], linesB[0])
	}
	if strings.Join(linesA, "\n") == strings.Join(linesB, "\n") {
		t.Fatalf("rendered output identical for two envelopes with different addresses, want them to differ:\n%q", linesA)
	}
}

// TestRenderDetail_AddresslessEnvelopeRendersNoAddressLine is a pre-sp033-T1
// payload: FromAddress/ToAddresses decode to their zero value. The header
// must stay intact and no address line — empty or dash-filled — may appear.
func TestRenderDetail_AddresslessEnvelopeRendersNoAddressLine(t *testing.T) {
	msg := detailMsg("message", "peer-1", []string{"peer-2"}, "hello")
	lines := RenderDetail(msg, 80, 20)
	if len(lines) != 2 {
		t.Fatalf("got %d lines %q, want exactly header + one body line (no address line)", len(lines), lines)
	}
	for _, want := range []string{"peer-1", "peer-2", "→"} {
		if !strings.Contains(lines[0], want) {
			t.Errorf("header %q missing %q", lines[0], want)
		}
	}
	if lines[1] != "hello" {
		t.Fatalf("body line = %q, want %q (no address line inserted before it)", lines[1], "hello")
	}
}

// TestRenderDetail_AddressLineNeutralisedAndWidthBounded embeds a real raw
// C0 byte (ESC) inside an otherwise address-shaped string, matching
// subject_test.go's precedent for proving neutralize actually strips it
// rather than merely not encountering it. Checked at 20/40/80 cells, per
// the test_plan.
func TestRenderDetail_AddressLineNeutralisedAndWidthBounded(t *testing.T) {
	hostile := addrPrefix11 + "\x1bHOSTILE00000"
	msg := detailMsgAddr("message", "peer-1", []string{"peer-2"}, hostile, []string{addrPrefix11 + strings.Repeat("9", 16)}, `"ping"`)
	for _, width := range []int{20, 40, 80} {
		lines := RenderDetail(msg, width, 20)
		for _, l := range lines {
			if strings.ContainsRune(l, 0x1b) {
				t.Fatalf("width=%d: line %q contains raw ESC byte, want it neutralised", width, l)
			}
			if w := displayWidth(l); w > width {
				t.Fatalf("width=%d: line %q is %d cells wide, want <= %d", width, l, w, width)
			}
		}
	}
}

// TestRenderDetail_MultiRecipientShowsEveryAddress asserts every recipient
// address renders, never only the first — the same rule toCell already
// enforces for labels (log.go), now proven for the raw address fields too.
func TestRenderDetail_MultiRecipientShowsEveryAddress(t *testing.T) {
	addr1 := addrPrefix11 + strings.Repeat("1", 16)
	addr2 := addrPrefix11 + strings.Repeat("2", 16)
	addr3 := addrPrefix11 + strings.Repeat("3", 16)
	fromAddr := addrPrefix11 + strings.Repeat("F", 16)
	msg := detailMsgAddr("message", "peer-1", []string{"peer-2", "peer-3", "peer-4"}, fromAddr, []string{addr1, addr2, addr3}, `"fan-out"`)
	lines := RenderDetail(msg, 80, 20)
	// "" join for the same reason as TestRenderDetail_ShowsFullAddresses: a
	// long joined address list wraps at 80 cells, and the wrap point can
	// land inside one of the addresses.
	joined := strings.Join(lines[1:], "")
	for _, want := range []string{addr1, addr2, addr3} {
		if !strings.Contains(joined, want) {
			t.Fatalf("output %q, want recipient address %q present", joined, want)
		}
	}
}

// TestRenderDetail_FromAddressOnly_NoDanglingArrow is the edge_cases entry:
// FromAddress set, ToAddresses empty, renders the from-address alone, paired
// with the From label on its own line — never a dangling "→" and never a
// manufactured line for the side that has no addresses at all.
func TestRenderDetail_FromAddressOnly_NoDanglingArrow(t *testing.T) {
	fromAddr := addrPrefix11 + strings.Repeat("5", 16)
	msg := detailMsgAddr("message", "peer-1", []string{"peer-2"}, fromAddr, nil, "hello")
	lines := RenderDetail(msg, 80, 20)
	if len(lines) != 3 {
		t.Fatalf("got %d lines %q, want header + one address line (from only) + one body line", len(lines), lines)
	}
	if !strings.Contains(lines[1], "peer-1") || !strings.Contains(lines[1], fromAddr) {
		t.Fatalf("address line = %q, want it to pair the from label %q with the from-address %q", lines[1], "peer-1", fromAddr)
	}
	if strings.Contains(lines[1], "→") {
		t.Fatalf("address line = %q, want no dangling arrow", lines[1])
	}
	if strings.Contains(lines[1], "peer-2") {
		t.Fatalf("address line = %q, want no manufactured line for the addressless recipient", lines[1])
	}
	if lines[2] != "hello" {
		t.Fatalf("body line = %q, want %q", lines[2], "hello")
	}
}

// fortyKeyJSONContent is the same 40-key object TestRenderDetail_HeightZero_
// NoClampNoIndicator and TestRenderDetail_HeightPositive_TruncationUnchanged
// use: 42 body lines (opening brace, 40 keys, closing brace) once indented,
// long enough that a small height budget must actually clamp.
func fortyKeyJSONContent() string {
	var b strings.Builder
	b.WriteString("{")
	for i := 0; i < 40; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `"k%02d":"v%02d"`, i, i)
	}
	b.WriteString("}")
	return b.String()
}

// --- sp036 T4: one party per line, addresses paired inline -----------------

// TestRenderDetail_OnePartyPerLine is the task's primary success criterion:
// a two-party envelope produces exactly one line per party — a From line and
// a To line — each containing that party's own label AND its own address,
// and NEITHER other party's address (the position-matching defect this task
// replaces).
func TestRenderDetail_OnePartyPerLine(t *testing.T) {
	fromAddr := addrPrefix11 + strings.Repeat("1", 16)
	toAddr := addrPrefix11 + strings.Repeat("2", 16)
	msg := detailMsgAddr("message", "peer-1", []string{"peer-2"}, fromAddr, []string{toAddr}, `"ping"`)
	lines := RenderDetail(msg, 80, 20)
	if len(lines) < 3 {
		t.Fatalf("got %d lines %q, want header + From line + To line + body", len(lines), lines)
	}
	fromLine, toLine := lines[1], lines[2]
	if !strings.Contains(fromLine, "peer-1") || !strings.Contains(fromLine, fromAddr) {
		t.Fatalf("from line %q, want it to contain label %q and its own address %q", fromLine, "peer-1", fromAddr)
	}
	if strings.Contains(fromLine, toAddr) {
		t.Fatalf("from line %q, want it NOT to contain the to-address %q (no position-matching)", fromLine, toAddr)
	}
	if !strings.Contains(toLine, "peer-2") || !strings.Contains(toLine, toAddr) {
		t.Fatalf("to line %q, want it to contain label %q and its own address %q", toLine, "peer-2", toAddr)
	}
	if strings.Contains(toLine, fromAddr) {
		t.Fatalf("to line %q, want it NOT to contain the from-address %q (no position-matching)", toLine, fromAddr)
	}
}

// TestRenderDetail_MappingSurvivesMultiRecipient is the test_plan's named
// defence against off-by-one pairing: three recipients whose addresses share
// their first eleven characters (the millisecond-timestamp segment
// same-millisecond ULIDs share, adr0034). Each recipient's line must carry
// ITS OWN address and none of the other two — an off-by-one or
// head-truncating implementation fails this.
func TestRenderDetail_MappingSurvivesMultiRecipient(t *testing.T) {
	addr1 := addrPrefix11 + strings.Repeat("1", 16)
	addr2 := addrPrefix11 + strings.Repeat("2", 16)
	addr3 := addrPrefix11 + strings.Repeat("3", 16)
	msg := detailMsgAddr("message", "peer-1", []string{"r1", "r2", "r3"}, "", []string{addr1, addr2, addr3}, `"fan-out"`)
	lines := RenderDetail(msg, 80, 20)
	if len(lines) < 4 {
		t.Fatalf("got %d lines %q, want header + 3 recipient lines + body", len(lines), lines)
	}
	want := map[string]string{"r1": addr1, "r2": addr2, "r3": addr3}
	for i, label := range []string{"r1", "r2", "r3"} {
		line := lines[1+i]
		if !strings.Contains(line, label) {
			t.Fatalf("line %d = %q, want it to contain label %q", i, line, label)
		}
		if !strings.Contains(line, want[label]) {
			t.Fatalf("line %d = %q, want it to contain %q's own address %q", i, line, label, want[label])
		}
		for other, otherAddr := range want {
			if other != label && strings.Contains(line, otherAddr) {
				t.Fatalf("line %d = %q, want it NOT to contain %q's address %q", i, line, other, otherAddr)
			}
		}
	}
}

// TestRenderDetail_LengthMismatchRendersLabelAlone is the safety edge case:
// a malformed envelope where To is longer than ToAddresses. The recipient
// beyond ToAddresses' length must render its label alone, never paired with
// another recipient's address, and must not crash.
func TestRenderDetail_LengthMismatchRendersLabelAlone(t *testing.T) {
	addr1 := addrPrefix11 + strings.Repeat("1", 16)
	msg := detailMsgAddr("message", "peer-1", []string{"r1", "r2"}, "", []string{addr1}, `"fan-out"`)
	lines := RenderDetail(msg, 80, 20)
	if len(lines) < 3 {
		t.Fatalf("got %d lines %q, want header + 2 recipient lines + body", len(lines), lines)
	}
	r1Line, r2Line := lines[1], lines[2]
	if !strings.Contains(r1Line, "r1") || !strings.Contains(r1Line, addr1) {
		t.Fatalf("r1 line %q, want label r1 paired with its own address %q", r1Line, addr1)
	}
	if !strings.Contains(r2Line, "r2") {
		t.Fatalf("r2 line %q, want label r2 present", r2Line)
	}
	if strings.Contains(r2Line, addr1) {
		t.Fatalf("r2 line %q, want it NOT paired with r1's address %q (length mismatch must not misassign)", r2Line, addr1)
	}
}

// TestRenderDetail_StillFullyRecoverableAtWidth20And12 is carried from
// sp035 T3's audit (there: TestRenderDetail_NarrowWidth_AddressFullyRecoverable)
// and re-asserted against the new one-line-per-party layout: at widths
// narrower than the address itself, the full 27-character address must
// still be recoverable by concatenating the rendered lines — wrapped, never
// truncated away.
func TestRenderDetail_StillFullyRecoverableAtWidth20And12(t *testing.T) {
	addr := addrPrefix11 + strings.Repeat("Z", 16)
	if len(addr) != 27 {
		t.Fatalf("setup: fixture address must be 27 chars, got %d", len(addr))
	}
	msg := detailMsgAddr("message", "peer-1", []string{"peer-2"}, addr, nil, "hi")
	for _, width := range []int{20, 12} {
		lines := RenderDetail(msg, width, 20)
		for _, l := range lines {
			if w := displayWidth(l); w > width {
				t.Fatalf("width=%d: line %q is %d cells wide, want <= %d", width, l, w, width)
			}
		}
		joined := strings.Join(lines[1:], "")
		if !strings.Contains(joined, addr) {
			t.Fatalf("width=%d: joined %q, want the full 27-character address recoverable (wrapped, not truncated away)", width, joined)
		}
	}
}

// TestRenderDetail_AddressLinesStillCountAgainstHeightBudget is carried from
// sp035 T3's audit (there: TestRenderDetail_AddressLineCountsAgainstHeightBudget)
// and re-asserted against the new layout, where a single-recipient envelope
// now spends TWO lines on addresses (one From line, one To line) rather than
// one combined line. The addressed pane must still obey the height budget
// exactly (never height+N lines), and its truncation indicator must report
// exactly wantExtraLines more hidden lines than the addressless pane's —
// the lines the address section itself spent, not lines silently dropped
// from the body underneath it.
//
// This catches a clamp-then-splice bug that TestRenderDetail_
// HeightPositive_TruncationUnchanged structurally cannot: that test's
// fixture carries no addresses, so a clamp that only ever sees the
// header+body and appends the address lines afterward passes it clean while
// overrunning the real budget.
func TestRenderDetail_AddressLinesStillCountAgainstHeightBudget(t *testing.T) {
	content := fortyKeyJSONContent()
	fromAddr := addrPrefix11 + strings.Repeat("A", 16)
	toAddr := addrPrefix11 + strings.Repeat("B", 16)

	addressed := detailMsgAddr("message", "peer-1", []string{"peer-2"}, fromAddr, []string{toAddr}, content)
	addressless := detailMsg("message", "peer-1", []string{"peer-2"}, content)

	fullAddressed := RenderDetail(addressed, 80, 0)
	fullAddressless := RenderDetail(addressless, 80, 0)
	const wantExtraLines = 2 // one line for From, one line for the single To
	if len(fullAddressed) != len(fullAddressless)+wantExtraLines {
		t.Fatalf("setup: unclamped addressed=%d lines, addressless=%d lines, want exactly %d more (one line per party)", len(fullAddressed), len(fullAddressless), wantExtraLines)
	}

	const height = 5
	gotAddressed := RenderDetail(addressed, 80, height)
	gotAddressless := RenderDetail(addressless, 80, height)

	if len(gotAddressed) != height {
		t.Fatalf("got %d lines, want exactly height=%d (the address lines must count against the budget, not extend it)", len(gotAddressed), height)
	}
	if len(gotAddressless) != height {
		t.Fatalf("setup: addressless got %d lines, want height=%d", len(gotAddressless), height)
	}

	remainingAddressed := len(fullAddressed) - (height - 1)
	remainingAddressless := len(fullAddressless) - (height - 1)
	if remainingAddressed != remainingAddressless+wantExtraLines {
		t.Fatalf("addressed hides %d lines, addressless hides %d, want exactly %d more hidden for the addressed pane", remainingAddressed, remainingAddressless, wantExtraLines)
	}

	wantIndicator := truncateCells(neutralize(fmt.Sprintf(truncationIndicatorFmt, remainingAddressed)), 80)
	if got := gotAddressed[len(gotAddressed)-1]; got != wantIndicator {
		t.Fatalf("indicator = %q, want %q (more hidden than the addressless pane's %q)", got, wantIndicator, gotAddressless[len(gotAddressless)-1])
	}
}
