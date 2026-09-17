package main

import (
	"bytes"
	"fmt"
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
	if err := runOnce(&buf, ""); err != nil {
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
	if err := runOnce(&buf, ""); err == nil {
		t.Fatalf("expected an error when agent-census/pi-worker are not on PATH")
	}
}

// mixedProjectStub is a captured mixed-project agent-census payload: two
// projects, one row each, so a --project filter has something to actually
// shrink (test_plan bullet 1).
const mixedProjectStub = `[` +
	`{"project":"dotfiles","runtime":"claude","uid":"u1","name":"peer-dotfiles","status":"idle","bucket":"idle"},` +
	`{"project":"copacks","runtime":"claude","uid":"u2","name":"peer-copacks","status":"idle","bucket":"idle"}` +
	`]`

// TestRunOnce_ProjectFlag_RestrictsRosterToMatchingProject is sp031 T3's
// core success criterion exercised through the --once one-shot path
// (test_plan bullet 4: "--once --project asserts the flag reaches the
// one-shot path") — runOnce(w, project) is the exact function main() calls
// with *project when --once is set, so driving it directly here proves the
// flag's value actually reaches that code path, not just tui.Model in
// isolation.
func TestRunOnce_ProjectFlag_RestrictsRosterToMatchingProject(t *testing.T) {
	dir := t.TempDir()
	writeStub(t, dir, "agent-census", "#!/bin/sh\necho '"+mixedProjectStub+"'\n")
	writeStub(t, dir, "pi-worker", "#!/bin/sh\necho '[]'\n")

	oldPath := os.Getenv("PATH")
	if err := os.Setenv("PATH", dir+string(os.PathListSeparator)+oldPath); err != nil {
		t.Fatalf("setenv PATH: %v", err)
	}
	defer os.Setenv("PATH", oldPath)

	var unfiltered bytes.Buffer
	if err := runOnce(&unfiltered, ""); err != nil {
		t.Fatalf("runOnce (unfiltered): %v", err)
	}
	if !strings.Contains(unfiltered.String(), "peer-copacks") {
		t.Fatalf("sanity check failed: unfiltered render should contain peer-copacks, got %q", unfiltered.String())
	}

	var filtered bytes.Buffer
	if err := runOnce(&filtered, "dotfiles"); err != nil {
		t.Fatalf("runOnce (--project dotfiles): %v", err)
	}
	out := filtered.String()
	if !strings.Contains(out, "peer-dotfiles") {
		t.Fatalf("expected the matching project's row in output, got %q", out)
	}
	if strings.Contains(out, "peer-copacks") {
		t.Fatalf("expected --project dotfiles to exclude the copacks row, got %q", out)
	}
}

// TestRunOnce_UnmatchedProject_EmptyRosterExitZero is the edge case: a
// --project value with no matching rows is an ANSWER (empty roster, header
// intact), not an error — ft012's contract for a project with no agents.
func TestRunOnce_UnmatchedProject_EmptyRosterExitZero(t *testing.T) {
	dir := t.TempDir()
	writeStub(t, dir, "agent-census", "#!/bin/sh\necho '"+mixedProjectStub+"'\n")
	writeStub(t, dir, "pi-worker", "#!/bin/sh\necho '[]'\n")

	oldPath := os.Getenv("PATH")
	if err := os.Setenv("PATH", dir+string(os.PathListSeparator)+oldPath); err != nil {
		t.Fatalf("setenv PATH: %v", err)
	}
	defer os.Setenv("PATH", oldPath)

	var buf bytes.Buffer
	if err := runOnce(&buf, "no-such-project"); err != nil {
		t.Fatalf("expected exit 0 (nil error) for an unmatched --project, got %v", err)
	}
	out := buf.String()
	if strings.Contains(out, "peer-dotfiles") || strings.Contains(out, "peer-copacks") {
		t.Fatalf("expected an empty roster for an unmatched project, got %q", out)
	}
	if !strings.Contains(out, "agents") {
		t.Fatalf("expected the roster header intact even when empty, got %q", out)
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
	return source.Message{At: "2026-01-01T00:00:00Z", ID: "m1", From: from, To: []string{"bob"}, Kind: "message", Content: []byte(content)}
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

// TestRenderFrame_ProjectFiltersRosterButNotMessages is the load-bearing
// test_plan bullet: "Message pane asserts UNCHANGED row count under
// --project" — the one that would fail if someone "helpfully" filtered both
// panes. model.Project restricts the roster (mixed-project sample: 2 rows,
// one per project) but the message pane's sender is unrelated to either
// project and must still render regardless.
func TestRenderFrame_ProjectFiltersRosterButNotMessages(t *testing.T) {
	roster := &source.Sample{Rows: []source.Row{
		{Project: "dotfiles", UID: "u1", Name: "peer-dotfiles"},
		{Project: "copacks", UID: "u2", Name: "peer-copacks"},
	}}
	msgs := &source.MessageSample{Messages: []source.Message{
		sampleMessage("alice", `"first"`),
		sampleMessage("bob", `"second"`),
	}}

	unfiltered := tui.NewModel()
	unfilteredLines := renderFrame(unfiltered, roster, false, msgs, false, time.Now(), 80, 40)

	filtered := tui.NewModel()
	filtered.Project = "dotfiles"
	filteredLines := renderFrame(filtered, roster, false, msgs, false, time.Now(), 80, 40)

	// Roster: --project must actually shrink it.
	if !containsSubstring(unfilteredLines, "peer-copacks") {
		t.Fatalf("sanity check failed: unfiltered roster should contain peer-copacks, got %v", unfilteredLines)
	}
	if containsSubstring(filteredLines, "peer-copacks") {
		t.Fatalf("expected --project dotfiles to drop the copacks roster row, got %v", filteredLines)
	}
	if !containsSubstring(filteredLines, "peer-dotfiles") {
		t.Fatalf("expected the matching roster row to survive, got %v", filteredLines)
	}

	// Messages: row count (and content) must be IDENTICAL whether or not
	// --project is set.
	unfilteredMsgCount := countOccurrences(unfilteredLines, "alice") + countOccurrences(unfilteredLines, "bob")
	filteredMsgCount := countOccurrences(filteredLines, "alice") + countOccurrences(filteredLines, "bob")
	if unfilteredMsgCount == 0 {
		t.Fatalf("sanity check failed: expected message senders in output, got %v", unfilteredLines)
	}
	if filteredMsgCount != unfilteredMsgCount {
		t.Fatalf("--project must not filter the message pane: unfiltered=%d filtered=%d", unfilteredMsgCount, filteredMsgCount)
	}
}

func countOccurrences(lines []string, sub string) int {
	n := 0
	for _, l := range lines {
		if strings.Contains(l, sub) {
			n++
		}
	}
	return n
}

// TestRenderFrame_ProjectComposesWithCommittedFilter proves --project and the
// interactive `/` filter both apply together rather than one replacing the
// other (test_plan bullet 2).
func TestRenderFrame_ProjectComposesWithCommittedFilter(t *testing.T) {
	roster := &source.Sample{Rows: []source.Row{
		{Project: "dotfiles", UID: "u1", Name: "peer-one"},
		{Project: "dotfiles", UID: "u2", Name: "peer-two"},
		{Project: "copacks", UID: "u3", Name: "peer-one"},
	}}

	model := tui.NewModel()
	model.Project = "dotfiles"
	model.HandleKey(tui.Key{Rune: '/'})
	for _, r := range "peer-one" {
		model.HandleKey(tui.Key{Rune: r})
	}
	model.HandleKey(tui.Key{Special: tui.KeyEnter})

	lines := renderFrame(model, roster, false, nil, false, time.Now(), 80, 40)
	if !containsSubstring(lines, "peer-one") {
		t.Fatalf("expected the row matching both --project and the filter, got %v", lines)
	}
	if containsSubstring(lines, "peer-two") {
		t.Fatalf("expected the / filter to still exclude peer-two even though its project matches, got %v", lines)
	}
	// copacks' peer-one matches the NAME filter but not --project: if only
	// the filter (not --project) were applied, "peer-one" would appear
	// twice (once per project). Exactly one occurrence proves both
	// predicates narrowed the result, not just the filter alone.
	if got := countOccurrences(lines, "peer-one"); got != 1 {
		t.Fatalf("expected exactly 1 peer-one row (dotfiles only, --project excludes the copacks one), got %d in %v", got, lines)
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

// logRowHasSender reports whether the MESSAGE PANE (not the detail pane)
// contains a row for sender. "→" only ever appears in the detail pane's
// `from → to` header, so excluding it separates "this sender has a visible
// log row" from "the detail pane happens to describe this sender" — the
// exact distinction the resize bug turned on.
func logRowHasSender(lines []string, sender string) bool {
	for _, l := range lines {
		if strings.Contains(l, sender) && !strings.Contains(l, "→") {
			return true
		}
	}
	return false
}

// TestRenderFrame_ResizeKeepsCursorRowVisibleInSameFrame is sp031 T1's
// binding criterion — "scroll is computed from cursor plus viewport, so a
// resized terminal cannot leave the cursor off-screen" — seen from T5, its
// first real caller. The frame that OBSERVES a resize must already honour
// it: a frame that renders the cursor's row only on the NEXT draw has
// dropped the row, not delayed it.
//
// Every other fitPanes/renderFrame test drives one fixed height per
// scenario, so none of them exercises the ordering this pins: the pane
// budgets a frame slices against must be derived from THIS frame's height,
// not from the viewport the previous frame left behind.
func TestRenderFrame_ResizeKeepsCursorRowVisibleInSameFrame(t *testing.T) {
	model := tui.NewModel()
	model.Focus = tui.PaneMessages
	var msgs []source.Message
	for i := 0; i < 40; i++ {
		msgs = append(msgs, sampleMessage(fmt.Sprintf("sender%02d", i), `"x"`))
	}
	sample := &source.MessageSample{Messages: msgs}

	// Settle on a tall terminal (a real session always draws before reading
	// a key), then walk the cursor deep into the list.
	renderFrame(model, nil, false, sample, false, time.Now(), 120, 40)
	for i := 0; i < 30; i++ {
		model.HandleKey(tui.Key{Rune: 'j'})
	}
	lines := renderFrame(model, nil, false, sample, false, time.Now(), 120, 40)
	if !logRowHasSender(lines, "sender30") {
		t.Fatalf("height 40: expected the cursor's row visible before the resize, got %v", lines)
	}

	// A single draw at a much shorter height. sender30 must be in THIS
	// frame's message pane.
	lines = renderFrame(model, nil, false, sample, false, time.Now(), 120, 8)
	if !logRowHasSender(lines, "sender30") {
		t.Fatalf("height 8: the cursor's row is absent from the message pane in the frame that observed the resize, got %v", lines)
	}
}

// TestRenderFrame_ScrolledPaneSurvivesAFilterThatShrinksIt is sp032 T1's
// clamp seen at the use site: scrolledMessageSample does msgs[scroll:], so a
// scroll offset left pointing past a list a committed filter just shrank is
// a panic, not a cosmetic bug. The model clamps scroll in the same pass as
// the length (filterMessageRows -> SetMessagesLen), so the frame that
// observes the filter already slices in range.
func TestRenderFrame_ScrolledPaneSurvivesAFilterThatShrinksIt(t *testing.T) {
	model := tui.NewModel()
	model.Focus = tui.PaneMessages
	var msgs []source.Message
	for i := 0; i < 40; i++ {
		msgs = append(msgs, sampleMessage(fmt.Sprintf("sender%02d", i), `"x"`))
	}
	sample := &source.MessageSample{Messages: msgs}

	// Settle a frame so the pane reports a real viewport, then scroll deep
	// with the cursor left behind at row 0 — the post-wheel state T3 and T6
	// produce, which sp031's model could not represent at all.
	renderFrame(model, nil, false, sample, false, time.Now(), 120, 40)
	model.ScrollMessages(30)
	if model.MessagesScroll == 0 {
		t.Fatalf("setup: expected a non-zero scroll, got %d", model.MessagesScroll)
	}
	if model.MessagesCursor != 0 {
		t.Fatalf("setup: the wheel must not have moved the cursor, got %d", model.MessagesCursor)
	}

	// A committed filter cuts the list to a single row. This frame must not
	// panic slicing it.
	model.Filter = tui.Filter{Set: true, Query: "sender07"}
	lines := renderFrame(model, nil, false, sample, false, time.Now(), 120, 40)

	if model.MessagesScroll != 0 {
		t.Fatalf("expected scroll clamped to 0 for a 1-row list, got %d", model.MessagesScroll)
	}
	if !logRowHasSender(lines, "sender07") {
		t.Fatalf("expected the surviving row to render, got %v", lines)
	}
}

// --- dotfiles-uyih: the cursor and the focused pane must be VISIBLE -------
//
// sp031 shipped a cursor that moves, a scroll that follows it and a detail
// pane that tracks it, and no way to see any of it: nothing in render/ ever
// received the cursor or the focus, so `tab` was indistinguishable from a
// dead key and `j`/`k` only showed an effect when the list was long enough
// to scroll. These tests pin the affordances that make it observable.
//
// The styling deliberately lives in cmd/ rather than render/: reverse video
// costs zero display cells, so every "no line exceeds the width" invariant
// sp031 T2 and T5 re-asserted stays true against render/'s own output, which
// stays free of escapes.

// selectionStyle is the reverse-video pair the frame uses to mark both the
// focused pane's header and the selected row.
const testStyleOn, testStyleOff = "\x1b[7m", "\x1b[27m"

func styledLines(lines []string) []string {
	var out []string
	for _, l := range lines {
		if strings.Contains(l, testStyleOn) {
			out = append(out, l)
		}
	}
	return out
}

func TestRenderFrame_FocusedPaneHeaderIsMarked(t *testing.T) {
	model := tui.NewModel() // focus starts on the roster
	roster := &source.Sample{Rows: []source.Row{{UID: "u1", Name: "u1"}}}
	msgs := &source.MessageSample{Messages: []source.Message{sampleMessage("alice", `"x"`)}}

	lines := renderFrame(model, roster, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, testStyleOn+"agents") {
		t.Fatalf("roster has focus, so its header must be marked; got %v", lines)
	}
	if containsSubstring(lines, testStyleOn+"messages") {
		t.Fatalf("messages pane does NOT have focus; its header must not be marked; got %v", lines)
	}

	model.HandleKey(tui.Key{Special: tui.KeyTab})
	lines = renderFrame(model, roster, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, testStyleOn+"messages") {
		t.Fatalf("after tab the messages pane has focus and must be marked; got %v", lines)
	}
	if containsSubstring(lines, testStyleOn+"agents") {
		t.Fatalf("after tab the roster no longer has focus; got %v", lines)
	}
}

func TestRenderFrame_SelectedRowIsMarked(t *testing.T) {
	model := tui.NewModel()
	model.Focus = tui.PaneMessages
	msgs := &source.MessageSample{Messages: []source.Message{
		sampleMessage("alice", `"first"`),
		sampleMessage("carol", `"second"`),
	}}

	lines := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	marked := styledLines(lines)
	if !anyContains(marked, "alice") {
		t.Fatalf("cursor at 0: alice's LOG ROW must be marked, got marked=%v all=%v", marked, lines)
	}
	if anyContains(marked, "carol") {
		t.Fatalf("cursor at 0: carol's row must not be marked, got marked=%v", marked)
	}

	model.HandleKey(tui.Key{Rune: 'j'})
	lines = renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	marked = styledLines(lines)
	if !anyContains(marked, "carol") {
		t.Fatalf("cursor at 1: carol's row must be marked, got marked=%v all=%v", marked, lines)
	}
}

// An empty list has nothing to select. The placeholder must never be marked
// as though it were a row — the same honesty adr0017 asks of a verdict.
func TestRenderFrame_EmptyListHasNoSelectionMark(t *testing.T) {
	model := tui.NewModel()
	model.Focus = tui.PaneMessages
	msgs := &source.MessageSample{Messages: nil}

	lines := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	for _, l := range styledLines(lines) {
		if strings.Contains(l, "(no messages)") {
			t.Fatalf("the empty-list placeholder must not be marked as a selected row: %q", l)
		}
	}
}

func anyContains(lines []string, sub string) bool {
	for _, l := range lines {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}
