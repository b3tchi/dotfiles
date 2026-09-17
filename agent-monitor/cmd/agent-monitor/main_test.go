package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"agent-monitor/internal/source"
	"agent-monitor/internal/tui"

	tea "github.com/charmbracelet/bubbletea"
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

// sp032 T2 deleted TestFrameBytes_UsesCRLF and
// TestFrameBytes_EmptyFrameStillClears along with the frame writer they
// covered. dotfiles-r9ty's CRLF rule was a workaround for the hand-rolled
// loop writing frames onto a tty IT had put in raw mode, with ONLCR off; the
// home+clear prefix was that same loop's repaint. bubbletea owns both now, so
// the workaround disappears WITH its cause rather than being carried forward
// as a superstition — and TestView_EqualsRenderFrameOutput asserts the
// replacement property directly: View() is renderFrame's lines joined with
// "\n" and contains no CR at all.

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

// ---------------------------------------------------------------------------
// sp032 T2: the bubbletea shell.
//
// altScreenEnter/altScreenExit used to be constants in main.go, written by
// the hand-rolled enterInteractiveMode. Since bubbletea owns the alternate
// screen, main.go must not contain that literal at all (asserted by
// TestShell_NoRawModeOrAltScreenSymbolsRemain), so the two sequences live
// here — as what the --once contract forbids in its output, which is the
// only reason this module ever needed to spell them. The TestRunOnce body
// above is unchanged and still reads them by these names.
// ---------------------------------------------------------------------------

const (
	altScreenEnter = "\x1b[?1049h"
	altScreenExit  = "\x1b[?1049l"
)

// startupBits applies opts to a bare tea.Program and reads back the private
// bitfield bubbletea records its startup options in. Reading an unexported
// int field through reflect is legal (only Interface()/Set() are barred), and
// comparing two BITFIELDS built the same way — rather than hardcoding 1<<0
// and 1<<1 — is what keeps this test honest if bubbletea ever renumbers them.
func startupBits(t *testing.T, opts ...tea.ProgramOption) int64 {
	t.Helper()
	p := &tea.Program{}
	for _, o := range opts {
		o(p)
	}
	f := reflect.ValueOf(p).Elem().FieldByName("startupOptions")
	if !f.IsValid() {
		t.Fatalf("bubbletea's Program no longer has a startupOptions field; this test needs rewriting")
	}
	return f.Int()
}

// TestShell_ProgramOptionsIncludeAltScreenAndMouseCellMotion is success
// criterion 1's option half: the program agent-monitor builds must ask for
// the alternate screen (what enterInteractiveMode used to write by hand) and
// for cell-motion mouse reporting (which nothing consumes yet — T3 does —
// but which must be on from this task so the events exist to consume).
func TestShell_ProgramOptionsIncludeAltScreenAndMouseCellMotion(t *testing.T) {
	got := startupBits(t, programOptions()...)

	alt := startupBits(t, tea.WithAltScreen())
	if got&alt != alt {
		t.Errorf("programOptions() does not enable the alternate screen (bits %b, want %b set)", got, alt)
	}
	mouse := startupBits(t, tea.WithMouseCellMotion())
	if got&mouse != mouse {
		t.Errorf("programOptions() does not enable cell-motion mouse reporting (bits %b, want %b set)", got, mouse)
	}
}

// TestShell_PanicAndSignalRestoreLeftToBubbletea is the edge case tui.Restorer
// used to cover. Its Guard existed because a panic on a SAMPLER goroutine —
// which used to render — would take the process down without running main()'s
// deferred restore. Nothing renders on those goroutines any more (they only
// p.Send), so the remaining case is a panic anywhere under the program, and
// bubbletea restores the terminal for it only while its panic catcher and its
// signal handler are left ON. Opting out of either would silently reintroduce
// the exact hazard Restorer was deleted for, so it is asserted rather than
// assumed.
func TestShell_PanicAndSignalRestoreLeftToBubbletea(t *testing.T) {
	got := startupBits(t, programOptions()...)

	if off := startupBits(t, tea.WithoutCatchPanics()); got&off != 0 {
		t.Errorf("programOptions() disables bubbletea's panic catcher; the terminal would stay in raw mode on a panic")
	}
	if off := startupBits(t, tea.WithoutSignalHandler()); got&off != 0 {
		t.Errorf("programOptions() disables bubbletea's signal handler; SIGINT/SIGTERM would not restore the terminal")
	}
}

// TestShell_NoRawModeOrAltScreenSymbolsRemain is success criteria 1 and 2's
// deletion half, using the same walk-every-non-test-.go-file technique as
// source's TestSourceScan_NoForbiddenPathAccess. Each listed symbol is one
// the hand-rolled loop owned and bubbletea now owns; a dead raw-mode path
// left behind is the single most likely thing a later "restore this" commit
// resurrects, so the scan fails on the IDENTIFIER, not merely on its use.
func TestShell_NoRawModeOrAltScreenSymbolsRemain(t *testing.T) {
	root := agentMonitorRoot(t)
	forbidden := []string{
		"Decoder",
		"Restorer",
		"readKeys",
		"enterInteractiveMode",
		"writeFrame",
		"frameBytes",
		"term.MakeRaw",
		"term.Restore",
		altScreenEnter,
		altScreenExit,
	}

	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, f := range forbidden {
			if strings.Contains(string(data), f) {
				t.Errorf("%s still mentions %q; bubbletea owns raw mode and the alternate screen since sp032 T2", path, f)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", root, err)
	}
}

// agentMonitorRoot walks up from the test's working directory to the
// directory holding go.mod — the module root, i.e. everything the scan above
// must cover.
func agentMonitorRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("no go.mod found above %s", dir)
		}
		dir = parent
	}
}

// newTestShell builds a shell over two monitors that have never sampled —
// enough for every key-mapping assertion, none of which renders.
func newTestShell(t *testing.T) *shell {
	t.Helper()
	model := tui.NewModel()
	s := newShell(context.Background(), model,
		source.NewMonitor(source.NewSampler(filepath.Join(t.TempDir(), "stamp"))),
		source.NewMessagesMonitor(source.NewMessagesSampler()))
	s.now = func() time.Time { return time.Unix(0, 0) }
	return s
}

// quits reports whether the command Update returned is bubbletea's quit.
func quits(cmd tea.Cmd) bool {
	if cmd == nil {
		return false
	}
	_, ok := cmd().(tea.QuitMsg)
	return ok
}

func key(t tea.KeyType) tea.KeyMsg { return tea.KeyMsg{Type: t} }

func runeKey(r rune) tea.KeyMsg { return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}} }

// TestUpdate_KeyMsgMapping_MatchesHandleKey is success criterion 5: every key
// ft016 documents reaches the SAME tui.Model method it reached through
// tui.Decoder, and the table asserts the resulting model state rather than
// that some branch was taken. A mapping that silently dropped a key would
// leave the state assertion unsatisfied, not merely untested.
func TestUpdate_KeyMsgMapping_MatchesHandleKey(t *testing.T) {
	cases := []struct {
		name     string
		msg      tea.KeyMsg
		wantQuit bool
		check    func(t *testing.T, m *tui.Model)
	}{
		{name: "q quits", msg: runeKey('q'), wantQuit: true},
		{name: "Q quits", msg: runeKey('Q'), wantQuit: true},
		{name: "ctrl+c quits", msg: key(tea.KeyCtrlC), wantQuit: true},
		{name: "tab moves focus", msg: key(tea.KeyTab), check: func(t *testing.T, m *tui.Model) {
			if m.Focus != tui.PaneMessages {
				t.Errorf("Focus = %v, want PaneMessages", m.Focus)
			}
		}},
		{name: "slash opens the filter draft", msg: runeKey('/'), check: func(t *testing.T, m *tui.Model) {
			if !m.Editing {
				t.Errorf("Editing = false, want true after `/`")
			}
		}},
		{name: "d hides the detail pane", msg: runeKey('d'), check: func(t *testing.T, m *tui.Model) {
			if m.DetailVisible {
				t.Errorf("DetailVisible = true, want false after `d`")
			}
		}},
		{name: "D hides the detail pane", msg: runeKey('D'), check: func(t *testing.T, m *tui.Model) {
			if m.DetailVisible {
				t.Errorf("DetailVisible = true, want false after `D`")
			}
		}},
		{name: "j moves the cursor down", msg: runeKey('j'), check: func(t *testing.T, m *tui.Model) {
			if m.RosterCursor != 1 {
				t.Errorf("RosterCursor = %d, want 1", m.RosterCursor)
			}
		}},
		{name: "down arrow moves the cursor down", msg: key(tea.KeyDown), check: func(t *testing.T, m *tui.Model) {
			if m.RosterCursor != 1 {
				t.Errorf("RosterCursor = %d, want 1", m.RosterCursor)
			}
		}},
		{name: "k at the top is a no-op", msg: runeKey('k'), check: func(t *testing.T, m *tui.Model) {
			if m.RosterCursor != 0 {
				t.Errorf("RosterCursor = %d, want 0", m.RosterCursor)
			}
		}},
		{name: "up arrow at the top is a no-op", msg: key(tea.KeyUp), check: func(t *testing.T, m *tui.Model) {
			if m.RosterCursor != 0 {
				t.Errorf("RosterCursor = %d, want 0", m.RosterCursor)
			}
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestShell(t)
			s.model.SetRosterLen(5)
			s.model.SetMessagesLen(5)

			_, cmd := s.Update(tc.msg)

			if got := quits(cmd); got != tc.wantQuit {
				t.Fatalf("quit = %v, want %v", got, tc.wantQuit)
			}
			if tc.check != nil {
				tc.check(t, s.model)
			}
		})
	}
}

// TestUpdate_RunesWhileEditingBelongToTheDraft is the edge case that the key
// surface's own letters must not fire while a `/` draft is open: `q` must not
// quit, `r` must not refresh, `d` must not toggle. The committed filter is
// the observable — the draft itself is unexported, exactly as tui intends.
func TestUpdate_RunesWhileEditingBelongToTheDraft(t *testing.T) {
	s := newTestShell(t)

	if _, cmd := s.Update(runeKey('/')); quits(cmd) {
		t.Fatalf("`/` must not quit")
	}
	for _, r := range []rune{'q', 'r', 'd'} {
		if _, cmd := s.Update(runeKey(r)); quits(cmd) {
			t.Fatalf("%q quit the program while a filter draft was open", r)
		}
	}
	if !s.model.DetailVisible {
		t.Errorf("`d` toggled the detail pane while editing; it belongs to the draft")
	}
	s.Update(key(tea.KeyEnter))

	if !s.model.Filter.Set || s.model.Filter.Query != "qrd" {
		t.Errorf("committed filter = %+v, want Set=true Query=%q", s.model.Filter, "qrd")
	}
}

// TestUpdate_CtrlCWhileEditingIsDraftTextNotQuit pins today's behavior
// deliberately rather than letting the port decide it: the byte-stream model
// fed 0x03 to HandleKey, which while Editing appended it to the draft instead
// of quitting. It is a strange affordance, and it is not this task's to
// change — a port that silently turned it into a quit would be a behavior
// change dressed as a refactor.
func TestUpdate_CtrlCWhileEditingIsDraftTextNotQuit(t *testing.T) {
	s := newTestShell(t)
	s.Update(runeKey('/'))

	_, cmd := s.Update(key(tea.KeyCtrlC))
	if quits(cmd) {
		t.Fatalf("ctrl+c quit while a filter draft was open; it used to be swallowed into the draft")
	}
	if !s.model.Editing {
		t.Fatalf("ctrl+c closed the filter draft")
	}

	s.Update(key(tea.KeyEnter))
	if !s.model.Filter.Set || s.model.Filter.Query != "\x03" {
		t.Errorf("committed filter = %+v, want Set=true Query=%q", s.model.Filter, "\x03")
	}
}

// TestUpdate_SpaceWhileEditingIsDraftText covers bubbletea's one key that
// carries its rune under a non-KeyRunes type: a space arrives as KeySpace,
// and a mapping that only looked at KeyRunes would drop every space out of a
// typed filter query.
func TestUpdate_SpaceWhileEditingIsDraftText(t *testing.T) {
	s := newTestShell(t)
	s.Update(runeKey('/'))
	s.Update(runeKey('a'))
	s.Update(tea.KeyMsg{Type: tea.KeySpace, Runes: []rune{' '}})
	s.Update(runeKey('b'))
	s.Update(key(tea.KeyEnter))

	if s.model.Filter.Query != "a b" {
		t.Errorf("committed filter query = %q, want %q", s.model.Filter.Query, "a b")
	}
}

// TestUpdate_BackspaceEditsTheDraft pins the remaining editing key through
// the mapping.
func TestUpdate_BackspaceEditsTheDraft(t *testing.T) {
	s := newTestShell(t)
	s.Update(runeKey('/'))
	s.Update(runeKey('a'))
	s.Update(runeKey('b'))
	s.Update(key(tea.KeyBackspace))
	s.Update(key(tea.KeyEnter))

	if s.model.Filter.Query != "a" {
		t.Errorf("committed filter query = %q, want %q", s.model.Filter.Query, "a")
	}
}

// TestUpdate_RKeyForcesARefresh is success criterion 5's `r`: the key still
// reaches the monitors, not just the model. The stub counts its own
// invocations on disk, so the assertion is "the census was actually re-read",
// not "some branch was taken".
func TestUpdate_RKeyForcesARefresh(t *testing.T) {
	dir := t.TempDir()
	counter := filepath.Join(dir, "calls")
	writeStub(t, dir, "agent-census", "#!/bin/sh\necho x >> "+counter+"\necho '[]'\n")
	writeStub(t, dir, "pi-worker", "#!/bin/sh\necho '[]'\n")

	oldPath := os.Getenv("PATH")
	if err := os.Setenv("PATH", dir+string(os.PathListSeparator)+oldPath); err != nil {
		t.Fatalf("setenv PATH: %v", err)
	}
	defer os.Setenv("PATH", oldPath)

	s := newTestShell(t)
	before := countLines(t, counter)

	if _, cmd := s.Update(runeKey('r')); quits(cmd) {
		t.Fatalf("`r` must not quit")
	}

	if after := countLines(t, counter); after <= before {
		t.Errorf("agent-census invocations: %d before, %d after `r`; want a forced refresh", before, after)
	}
}

func countLines(t *testing.T, path string) int {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	return strings.Count(string(data), "\n")
}

// TestUpdate_TickMsgRedrawsWithoutMovingAnyCursor is success criterion 3's
// observable consequence: a sampler tick is now a message, and a message that
// says "new data arrived" must not move a cursor, a scroll offset or the
// focus. sp032 T1 made the scroll first-class precisely so a tick cannot drag
// it; this asserts the shell does not undo that at the message layer.
func TestUpdate_TickMsgRedrawsWithoutMovingAnyCursor(t *testing.T) {
	for _, msg := range []tea.Msg{rosterTickMsg{}, messagesTickMsg{}} {
		s := newTestShell(t)
		s.model.SetRosterViewport(3)
		s.model.SetMessagesViewport(3)
		s.model.SetRosterLen(20)
		s.model.SetMessagesLen(20)
		s.model.ScrollRoster(5)
		s.model.ScrollMessages(7)
		s.model.Focus = tui.PaneMessages

		want := *s.model
		_, cmd := s.Update(msg)

		if quits(cmd) {
			t.Fatalf("%T quit the program", msg)
		}
		if *s.model != want {
			t.Errorf("%T changed model state:\n got %+v\nwant %+v", msg, *s.model, want)
		}
	}
}

// TestUpdate_WindowSizeMsgSuppliesWidthAndHeight is success criterion 4's
// input half: term.GetSize is gone from the interactive path, so the frame's
// geometry can only come from the message. The edge case of it arriving
// BEFORE the first sample is covered here too — View must render the
// "waiting" panes rather than panic on a nil sample.
func TestUpdate_WindowSizeMsgSuppliesWidthAndHeight(t *testing.T) {
	s := newTestShell(t)

	s.Update(tea.WindowSizeMsg{Width: 100, Height: 40})

	if s.width != 100 || s.height != 40 {
		t.Fatalf("shell geometry = %dx%d, want 100x40", s.width, s.height)
	}
	if got := s.View(); got == "" {
		t.Fatalf("View() is empty before the first sample; want the waiting panes")
	}
}

// TestView_EqualsRenderFrameOutput is success criterion 4's output half: the
// shell's View is renderFrame's lines joined with "\n" and nothing else — no
// CRLF workaround (bubbletea owns the output mapping now, so the cause of
// dotfiles-r9ty is gone with it), no cursor-home/clear prefix, no styling the
// renderers did not produce. A lipgloss byte leaking into the frame would
// fail here.
func TestView_EqualsRenderFrameOutput(t *testing.T) {
	dir := t.TempDir()
	writeStub(t, dir, "agent-census", "#!/bin/sh\necho '"+mixedProjectStub+"'\n")
	writeStub(t, dir, "pi-worker", "#!/bin/sh\necho '[{\"from\":\"peer-dotfiles\",\"to\":[\"lead\"],\"content\":\"hello\",\"at\":\"2026-09-17T10:00:00Z\"}]'\n")

	oldPath := os.Getenv("PATH")
	if err := os.Setenv("PATH", dir+string(os.PathListSeparator)+oldPath); err != nil {
		t.Fatalf("setenv PATH: %v", err)
	}
	defer os.Setenv("PATH", oldPath)

	ctx := context.Background()
	census := source.NewMonitor(source.NewSampler(filepath.Join(dir, "stamp")))
	census.Refresh(ctx)
	msgs := source.NewMessagesMonitor(source.NewMessagesSampler())
	msgs.Tick(ctx)

	now := time.Date(2026, 9, 17, 10, 0, 5, 0, time.UTC)

	s := newShell(ctx, tui.NewModel(), census, msgs)
	s.now = func() time.Time { return now }
	s.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	got := s.View()

	// An independent model at the same starting state, so the comparison is
	// "same model, same samples, same string" rather than a second pass over
	// state the first render already mutated.
	want := strings.Join(renderFrame(tui.NewModel(), census.Last(), census.Stale(), msgs.Last(), msgs.Stale(), now, 100, 30), "\n")

	if got != want {
		t.Errorf("View() differs from renderFrame's joined lines:\n got %q\nwant %q", got, want)
	}
	if strings.Contains(got, "\r") {
		t.Errorf("View() contains a CR; bubbletea owns the output mapping, so the CRLF workaround must be gone: %q", got)
	}
}

// TestInteractiveExitError_InterruptIsACleanExit is the SIGINT/SIGTERM edge
// case. bubbletea reports a SIGINT as tea.ErrInterrupted, but the pre-port
// loop simply returned on a signal and the process exited 0; a port that let
// that error reach os.Exit(1) would turn every ctrl+c into a failure exit
// code. SIGTERM already arrives as a plain quit (nil error) and is pinned
// here as the other half of the contract.
func TestInteractiveExitError_InterruptIsACleanExit(t *testing.T) {
	if err := interactiveExitError(tea.ErrInterrupted); err != nil {
		t.Errorf("interactiveExitError(ErrInterrupted) = %v, want nil (exit 0)", err)
	}
	if err := interactiveExitError(nil); err != nil {
		t.Errorf("interactiveExitError(nil) = %v, want nil", err)
	}
	real := errors.New("tty exploded")
	if err := interactiveExitError(real); !errors.Is(err, real) {
		t.Errorf("interactiveExitError(%v) = %v, want it passed through", real, err)
	}
}
