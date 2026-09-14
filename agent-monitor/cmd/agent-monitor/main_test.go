package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agent-monitor/internal/source"
	"agent-monitor/internal/tui"
)

// writeStub drops an executable shell script named `name` into dir, so a
// test can point PATH at dir and have source.Available()/MessagesAvailable()
// find a stand-in binary without ever touching the real agent-census or
// pi-worker.
func writeStub(t *testing.T, dir, name, script string) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatalf("write stub %s: %v", name, err)
	}
}

// TestRunOnce_NoRawModeNoAltScreen_ExitsCleanly is the test_plan's --once
// case: on a stub PATH it must write a frame to stdout and exit 0 (return a
// nil error here, since runOnce is the pre-os.Exit seam main() calls),
// emitting no terminal-mode escape sequence at all — no alternate-screen
// enter/exit, no raw-mode setup, no cursor-home/clear — so the output
// composes cleanly in a pipe.
func TestRunOnce_NoRawModeNoAltScreen_ExitsCleanly(t *testing.T) {
	dir := t.TempDir()
	writeStub(t, dir, "agent-census", "#!/bin/sh\necho '[]'\n")
	writeStub(t, dir, "pi-worker", "#!/bin/sh\necho '[]'\n")

	oldPath := os.Getenv("PATH")
	if err := os.Setenv("PATH", dir+string(os.PathListSeparator)+oldPath); err != nil {
		t.Fatalf("setenv PATH: %v", err)
	}
	defer os.Setenv("PATH", oldPath)

	var buf bytes.Buffer
	if err := runOnce(&buf); err != nil {
		t.Fatalf("runOnce: %v", err)
	}

	out := buf.String()
	if out == "" {
		t.Fatalf("expected a rendered frame, got empty output")
	}
	if strings.ContainsRune(out, 0x1b) {
		t.Fatalf("output contains an ESC byte; --once must emit no terminal-mode escape sequence: %q", out)
	}
	for _, forbidden := range []string{altScreenEnter, altScreenExit} {
		if strings.Contains(out, forbidden) {
			t.Fatalf("output contains an alternate-screen sequence %q", forbidden)
		}
	}
	if !strings.Contains(out, "agents") {
		t.Fatalf("expected the roster pane header in output, got %q", out)
	}
	if !strings.Contains(out, "messages") {
		t.Fatalf("expected the message pane header in output, got %q", out)
	}

	// sp031 T5: --once has no cursor and no height, so it must render
	// without the detail pane and without a second separator — exactly the
	// two stacked panes it rendered before this task, extending the T9
	// assertion this test pins.
	if strings.Contains(out, "no message selected") {
		t.Fatalf("--once must not render a detail pane, got %q", out)
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	blanks := 0
	for _, l := range lines {
		if l == "" {
			blanks++
		}
	}
	if blanks != 1 {
		t.Fatalf("--once must have exactly one blank separator (roster/messages), got %d in %q", blanks, out)
	}
}

func TestRunOnce_MissingBinary_ReturnsError(t *testing.T) {
	dir := t.TempDir() // empty: neither stub exists
	oldPath := os.Getenv("PATH")
	if err := os.Setenv("PATH", dir); err != nil {
		t.Fatalf("setenv PATH: %v", err)
	}
	defer os.Setenv("PATH", oldPath)

	var buf bytes.Buffer
	if err := runOnce(&buf); err == nil {
		t.Fatalf("expected an error when agent-census/pi-worker are not on PATH")
	}
}

// dotfiles-r9ty: the interactive frame must use CRLF line endings.
//
// The bug this pins was invisible to every other test in this module. The
// render packages are tested on the []string they return, and --once is
// asserted on bytes — both correct, and both blind to how those lines reach a
// terminal that is in RAW mode, where ONLCR is off and a bare \n drops a row
// without returning the carriage. The result was a frame that staircased off
// the right edge. Only running the real TUI showed it.
func TestFrameBytes_UsesCRLF(t *testing.T) {
	got := frameBytes([]string{"alpha", "beta"})

	if want := "\x1b[H\x1b[J"; !strings.HasPrefix(got, want) {
		t.Fatalf("frame does not start with home+clear: %q", got)
	}
	if want := "\x1b[H\x1b[Jalpha\r\nbeta\r\n"; got != want {
		t.Errorf("frame = %q, want %q", got, want)
	}

	// The property that actually matters, stated independently of the exact
	// frame above: no LF may appear without a CR immediately before it, or
	// the row below starts at the wrong column.
	for i, r := range got {
		if r == '\n' && (i == 0 || got[i-1] != '\r') {
			t.Errorf("bare LF at byte %d in %q — raw mode will not return the carriage", i, got)
		}
	}
}

func TestFrameBytes_EmptyFrameStillClears(t *testing.T) {
	// A frame with no lines must still home and clear, otherwise a transition
	// to an empty roster leaves the previous frame on screen.
	if got, want := frameBytes(nil), "\x1b[H\x1b[J"; got != want {
		t.Errorf("frameBytes(nil) = %q, want %q", got, want)
	}
}

// dotfiles-9x2m / sp031 T5: the frame must fit the terminal, or the terminal
// scrolls and carries the roster off the top where in-pane scrolling cannot
// reach it. detailVisible=false isolates the original two-way behaviour
// fitPanes has always had, now that a third region exists.
func TestFitPanes_TotalNeverExceedsHeight_TwoWay(t *testing.T) {
	long := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = "row"
		}
		return out
	}

	for _, h := range []int{3, 10, 24, 40} {
		roster, log, _, shown := fitPanes(long(100), long(100), h, false)
		if shown {
			t.Errorf("height %d: detail must stay hidden when detailVisible is false", h)
		}
		if total := len(roster) + 1 + len(log); total > h {
			t.Errorf("height %d: frame is %d lines (roster %d + blank + log %d), want <= %d",
				h, total, len(roster), len(log), h)
		}
		if len(roster) == 0 || len(log) == 0 {
			t.Errorf("height %d: a pane was trimmed out of existence (roster %d, log %d)",
				h, len(roster), len(log))
		}
	}
}

func TestFitPanes_ShortPaneYieldsItsSurplus(t *testing.T) {
	// Three agents and a busy bus: the roster should not hold half the screen
	// empty while messages are being trimmed. detail off, so this is exactly
	// the pre-T5 two-way case.
	roster, log, _, shown := fitPanes([]string{"hdr", "a", "b"}, make([]string, 100), 25, false)
	if shown {
		t.Fatalf("expected detail hidden with detailVisible=false")
	}
	if len(roster) != 3 {
		t.Errorf("short pane was trimmed: got %d lines, want 3", len(roster))
	}
	if want := 25 - 1 - 3; len(log) != want {
		t.Errorf("log got %d lines, want %d (all of the roster's surplus)", len(log), want)
	}
}

func TestFitPanes_TrimsFromBottomKeepingHeaders(t *testing.T) {
	roster := []string{"ROSTER HEADER", "r1", "r2", "r3", "r4", "r5"}
	log := []string{"LOG HEADER", "m1", "m2", "m3", "m4", "m5"}
	gotRoster, gotLog, _, _ := fitPanes(roster, log, 7, false)

	if gotRoster[0] != "ROSTER HEADER" {
		t.Errorf("roster lost its header: %q", gotRoster)
	}
	if gotLog[0] != "LOG HEADER" {
		t.Errorf("log lost its header: %q", gotLog)
	}
}

// TestFitPanes_ThreeWay_TotalNeverExceedsHeight is sp031 T5's central
// invariant, re-asserting dotfiles-m0km with a third region present: across
// a spread of heights, roster + blank + log + (blank + detail, when shown)
// must never exceed height, and roster/log must never be trimmed to
// nothing.
func TestFitPanes_ThreeWay_TotalNeverExceedsHeight(t *testing.T) {
	long := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = "row"
		}
		return out
	}

	for _, h := range []int{3, 10, 24, 40, 80} {
		roster, log, detailBudget, shown := fitPanes(long(100), long(100), h, true)
		total := len(roster) + 1 + len(log)
		if shown {
			total += 1 + detailBudget
		}
		if total > h {
			t.Errorf("height %d: frame is %d lines (roster %d, log %d, detail %d shown=%v), want <= %d",
				h, total, len(roster), len(log), detailBudget, shown, h)
		}
		if len(roster) == 0 || len(log) == 0 {
			t.Errorf("height %d: a pane was trimmed out of existence (roster %d, log %d)",
				h, len(roster), len(log))
		}
	}
}

// TestFitPanes_DetailCapNeverExceedsThirdOrEight is the cap success
// criterion: at no height may the detail budget grow past height/3 or 8,
// whichever is smaller — explicitly checked at height 80 so it cannot creep
// to half the screen.
func TestFitPanes_DetailCapNeverExceedsThirdOrEight(t *testing.T) {
	long := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = "row"
		}
		return out
	}

	for _, h := range []int{24, 40, 80} {
		_, _, detailBudget, shown := fitPanes(long(100), long(100), h, true)
		if !shown {
			t.Fatalf("height %d: expected detail shown", h)
		}
		if detailBudget > 8 {
			t.Errorf("height %d: detail budget %d exceeds the 8-row cap", h, detailBudget)
		}
		if detailBudget*3 > h {
			t.Errorf("height %d: detail budget %d exceeds a third of height", h, detailBudget)
		}
	}
	if _, _, detailBudget, _ := fitPanes(long(100), long(100), 80, true); detailBudget*2 > 80 {
		t.Errorf("height 80: detail budget %d must not reach half the screen", detailBudget)
	}
}

// TestFitPanes_DetailHidesBelowMinimumHeight is the edge case: a terminal
// too short for three useful panes hides detail rather than squeezing
// roster/log into uselessness, and the two remaining panes are unaffected
// (still non-empty, still keep the surplus-redistribution behaviour).
func TestFitPanes_DetailHidesBelowMinimumHeight(t *testing.T) {
	roster, log, detailBudget, shown := fitPanes([]string{"hdr", "a"}, []string{"hdr", "b"}, 3, true)
	if shown {
		t.Fatalf("height 3: expected detail hidden, got budget %d", detailBudget)
	}
	if len(roster) == 0 || len(log) == 0 {
		t.Errorf("height 3: roster/log must still render with detail hidden, got roster=%d log=%d", len(roster), len(log))
	}
}

// TestFitPanes_DetailVisibleFalseAlwaysHides pins the toggle's effect on the
// budget function directly: even at a generous height, detailVisible=false
// must yield shown=false and budget 0.
func TestFitPanes_DetailVisibleFalseAlwaysHides(t *testing.T) {
	_, _, detailBudget, shown := fitPanes([]string{"hdr"}, []string{"hdr"}, 80, false)
	if shown || detailBudget != 0 {
		t.Errorf("detailVisible=false: expected shown=false budget=0, got shown=%v budget=%d", shown, detailBudget)
	}
}

func sampleMessage(from string, content string) source.Message {
	return source.Message{At: "2026-01-01T00:00:00Z", ID: "m1", From: from, To: []string{"bob"}, Kind: "inbox", Content: []byte(content)}
}

// TestRenderFrame_DetailFollowsMessagesCursor is a success criterion: the
// detail pane renders the message under the message pane's cursor, and
// follows it as the cursor moves.
func TestRenderFrame_DetailFollowsMessagesCursor(t *testing.T) {
	model := tui.NewModel()
	model.Focus = tui.PaneMessages
	msgs := &source.MessageSample{Messages: []source.Message{
		sampleMessage("alice", `"first"`),
		sampleMessage("carol", `"second"`),
	}}

	// "→" only appears in the detail header (`from → to`), so checking for
	// it distinguishes "the detail pane selected this sender" from "this
	// sender merely appears as a log row", which would be true either way.
	lines := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, "alice →") {
		t.Fatalf("expected the first message (cursor at 0) in the detail pane, got %v", lines)
	}

	model.HandleKey(tui.Key{Rune: 'j'})
	lines = renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, "carol →") {
		t.Fatalf("expected the second message (cursor at 1) after moving down, got %v", lines)
	}
}

// TestRenderFrame_EmptyMessageList_DetailShowsPlaceholder is the edge case:
// an empty log must not make the detail region disappear, so the layout
// does not jump as messages arrive.
func TestRenderFrame_EmptyMessageList_DetailShowsPlaceholder(t *testing.T) {
	model := tui.NewModel()
	msgs := &source.MessageSample{Messages: nil}

	lines := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, "no message selected") {
		t.Fatalf("expected the detail placeholder with an empty message list, got %v", lines)
	}
}

// TestRenderFrame_ToggleOffAndOn_PreservesSelection is the edge case:
// toggling the detail pane off while the cursor is in the message pane, then
// back on, must still show the same message.
func TestRenderFrame_ToggleOffAndOn_PreservesSelection(t *testing.T) {
	model := tui.NewModel()
	model.Focus = tui.PaneMessages
	msgs := &source.MessageSample{Messages: []source.Message{
		sampleMessage("alice", `"first"`),
		sampleMessage("carol", `"second"`),
	}}
	// A real session always draws once (establishing MessagesLen, which
	// bounds the cursor) before any key is read — see runInteractive's
	// initial draw(). Mirror that ordering here.
	renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	model.HandleKey(tui.Key{Rune: 'j'}) // select carol

	model.HandleKey(tui.Key{Rune: 'd'}) // off
	lines := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	// "→" only ever appears in the detail header (detailHeaderLine's
	// `from → to`); the message pane's own SUBJECT column never contains it,
	// so its absence is a precise "no detail region" check, distinct from
	// "carol" which legitimately still appears as a log row.
	if containsSubstring(lines, "→") {
		t.Fatalf("expected no detail region while toggled off, got %v", lines)
	}

	model.HandleKey(tui.Key{Rune: 'd'}) // on
	lines = renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, "carol →") {
		t.Fatalf("expected carol still selected after toggling back on, got %v", lines)
	}
}

// TestRenderFrame_TooShortForThreePanes_HidesDetailButKeepsHeaders is the
// edge case: a terminal too short for three panes hides detail, and the two
// remaining panes still each keep their header.
func TestRenderFrame_TooShortForThreePanes_HidesDetailButKeepsHeaders(t *testing.T) {
	model := tui.NewModel()
	roster := &source.Sample{Rows: []source.Row{{UID: "u1", Name: "u1"}}}
	msgs := &source.MessageSample{Messages: []source.Message{sampleMessage("alice", `"x"`)}}

	lines := renderFrame(model, roster, false, msgs, false, time.Now(), 80, 5)
	if containsSubstring(lines, "no message selected") {
		t.Fatalf("height 5: expected detail hidden, got %v", lines)
	}
	if !containsSubstring(lines, "agents") {
		t.Errorf("height 5: roster must keep its header, got %v", lines)
	}
	if !containsSubstring(lines, "messages") {
		t.Errorf("height 5: log must keep its header, got %v", lines)
	}
}

// TestRenderFrame_OnceHeight_NoDetailNoToggle pins --once's contract at the
// renderFrame level directly (buildFrame's own test above covers it
// end-to-end): height<=0 means no cursor and no height, so no detail region
// regardless of DetailVisible.
func TestRenderFrame_OnceHeight_NoDetailNoToggle(t *testing.T) {
	model := tui.NewModel() // DetailVisible defaults true
	msgs := &source.MessageSample{Messages: []source.Message{sampleMessage("alice", `"x"`)}}

	lines := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 0)
	if containsSubstring(lines, "no message selected") || containsSubstring(lines, "alice →") {
		t.Fatalf("height 0 (--once) must never render a detail pane, got %v", lines)
	}
}

func containsSubstring(lines []string, sub string) bool {
	for _, l := range lines {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}
