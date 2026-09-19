package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"agent-monitor/internal/render"
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
//
// sp032 T7 pairs this with a SUITE-level counterpart in
// tests/agent-monitor/run-tests.nu, which builds the real binary and greps
// the bytes `agent-monitor --once` writes into an actual pipe for 0x1b.
// The two altitudes are deliberate and neither replaces the other: this one
// covers the runOnce seam every frame-shaping test already drives, while the
// suite case covers everything main() does AROUND that seam. dotfiles-r9ty is
// the precedent — a unit assertion stayed green while the shipped terminal
// path was broken — so an ESC written to os.Stdout outside runOnce is exactly
// the class of defect only the suite case can see.
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

	// sp033 T6: the pane renders newest-first, so row 0 is carol — the LAST
	// message in the sample's ascending wire order, not the first.
	//
	// "→" only appears in the detail header (`from → to`), so checking for
	// it distinguishes "the detail pane selected this sender" from "this
	// sender merely appears as a log row", which would be true either way.
	lines, _ := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, "carol →") {
		t.Fatalf("expected the newest message (cursor at row 0) in the detail pane, got %v", lines)
	}

	model.HandleKey(tui.Key{Rune: 'j'})
	lines, _ = renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, "alice →") {
		t.Fatalf("expected the older message (cursor at row 1) after moving down, got %v", lines)
	}
}

// TestRenderFrame_EmptyMessageList_DetailShowsPlaceholder is the edge case:
// an empty log must not make the detail region disappear, so the layout
// does not jump as messages arrive.
func TestRenderFrame_EmptyMessageList_DetailShowsPlaceholder(t *testing.T) {
	model := tui.NewModel()
	msgs := &source.MessageSample{Messages: nil}

	lines, _ := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
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
	// sp033 T6: row 0 is carol (the newest), so 'j' selects alice.
	model.HandleKey(tui.Key{Rune: 'j'}) // select alice

	model.HandleKey(tui.Key{Rune: 'd'}) // off
	lines, _ := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	// "→" only ever appears in the detail header (detailHeaderLine's
	// `from → to`); the message pane's own SUBJECT column never contains it,
	// so its absence is a precise "no detail region" check, distinct from
	// "alice" which legitimately still appears as a log row.
	if containsSubstring(lines, "→") {
		t.Fatalf("expected no detail region while toggled off, got %v", lines)
	}

	model.HandleKey(tui.Key{Rune: 'd'}) // on
	lines, _ = renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, "alice →") {
		t.Fatalf("expected alice still selected after toggling back on, got %v", lines)
	}
}

// TestRenderFrame_TooShortForThreePanes_HidesDetailButKeepsHeaders is the
// edge case: a terminal too short for three panes hides detail, and the two
// remaining panes still each keep their header.
func TestRenderFrame_TooShortForThreePanes_HidesDetailButKeepsHeaders(t *testing.T) {
	model := tui.NewModel()
	roster := &source.Sample{Rows: []source.Row{{UID: "u1", Name: "u1"}}}
	msgs := &source.MessageSample{Messages: []source.Message{sampleMessage("alice", `"x"`)}}

	lines, _ := renderFrame(model, roster, false, msgs, false, time.Now(), 80, 5)
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

	lines, _ := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 0)
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
	unfilteredLines, _ := renderFrame(unfiltered, roster, false, msgs, false, time.Now(), 80, 40)

	filtered := tui.NewModel()
	filtered.Project = "dotfiles"
	filteredLines, _ := renderFrame(filtered, roster, false, msgs, false, time.Now(), 80, 40)

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

	lines, _ := renderFrame(model, roster, false, nil, false, time.Now(), 80, 40)
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
	// a key), then walk the cursor deep into the list. sp033 T6: row 0 is
	// sender39 (the newest, last in the ascending sample), so 30 steps down
	// lands on sender09.
	renderFrame(model, nil, false, sample, false, time.Now(), 120, 40)
	for i := 0; i < 30; i++ {
		model.HandleKey(tui.Key{Rune: 'j'})
	}
	lines, _ := renderFrame(model, nil, false, sample, false, time.Now(), 120, 40)
	if !logRowHasSender(lines, "sender09") {
		t.Fatalf("height 40: expected the cursor's row visible before the resize, got %v", lines)
	}

	// A single draw at a much shorter height. sender09 must be in THIS
	// frame's message pane.
	lines, _ = renderFrame(model, nil, false, sample, false, time.Now(), 120, 8)
	if !logRowHasSender(lines, "sender09") {
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
	lines, _ := renderFrame(model, nil, false, sample, false, time.Now(), 120, 40)

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

	lines, _ := renderFrame(model, roster, false, msgs, false, time.Now(), 80, 40)
	if !containsSubstring(lines, testStyleOn+"agents") {
		t.Fatalf("roster has focus, so its header must be marked; got %v", lines)
	}
	if containsSubstring(lines, testStyleOn+"messages") {
		t.Fatalf("messages pane does NOT have focus; its header must not be marked; got %v", lines)
	}

	model.HandleKey(tui.Key{Special: tui.KeyTab})
	lines, _ = renderFrame(model, roster, false, msgs, false, time.Now(), 80, 40)
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

	// sp033 T6: row 0 is carol (the newest, last in the ascending sample).
	lines, _ := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	marked := styledLines(lines)
	if !anyContains(marked, "carol") {
		t.Fatalf("cursor at 0: carol's LOG ROW must be marked, got marked=%v all=%v", marked, lines)
	}
	if anyContains(marked, "alice") {
		t.Fatalf("cursor at 0: alice's row must not be marked, got marked=%v", marked)
	}

	model.HandleKey(tui.Key{Rune: 'j'})
	lines, _ = renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
	marked = styledLines(lines)
	if !anyContains(marked, "alice") {
		t.Fatalf("cursor at 1: alice's row must be marked, got marked=%v all=%v", marked, lines)
	}
}

// An empty list has nothing to select. The placeholder must never be marked
// as though it were a row — the same honesty adr0017 asks of a verdict.
func TestRenderFrame_EmptyListHasNoSelectionMark(t *testing.T) {
	model := tui.NewModel()
	model.Focus = tui.PaneMessages
	msgs := &source.MessageSample{Messages: nil}

	lines, _ := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 40)
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

// newWiredShell builds a shell over REAL monitors fed by stub agent-census /
// pi-worker binaries and sized by a WindowSizeMsg — the same harness
// TestMouse_ClickThroughShellUpdate_SelectsRowAndFocusesSameFrame stands up,
// parameterised so a test can ask for enough rows that a pane can actually
// scroll. It is what lets a mouse test send a real tea.MouseMsg through
// shell.Update instead of calling a Model method directly: the dispatch in
// handleMouse (which button reaches which pane, with which delta) is only
// under test when the event itself is the input.
func newWiredShell(t *testing.T, rosterRows, msgRows, width, height int) *shell {
	t.Helper()
	return newWiredShellIn(t, t.TempDir(), rosterRows, msgRows, width, height)
}

// newWiredShellIn is newWiredShell with the stub directory handed in, so a
// test that needs the message sample to GROW (sp032 T6's tail-follow) can
// rewrite the pi-worker stub in that directory and re-Tick the monitor —
// driving a real second sample through the real sampler rather than poking
// a length onto the model.
func newWiredShellIn(t *testing.T, dir string, rosterRows, msgRows, width, height int) *shell {
	t.Helper()

	rows := make([]source.Row, rosterRows)
	for i := range rows {
		rows[i] = source.Row{
			UID:    fmt.Sprintf("agent%02d", i),
			Name:   fmt.Sprintf("agent%02d", i),
			Bucket: "idle",
		}
	}
	rosterJSON, err := json.Marshal(rows)
	if err != nil {
		t.Fatalf("marshal roster: %v", err)
	}

	writeStub(t, dir, "agent-census", "#!/bin/sh\ncat <<'JSON'\n"+string(rosterJSON)+"\nJSON\n")
	writeMessageStub(t, dir, msgRows)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	ctx := context.Background()
	census := source.NewMonitor(source.NewSampler(filepath.Join(dir, "stamp")))
	census.Refresh(ctx)
	msgs := source.NewMessagesMonitor(source.NewMessagesSampler())
	msgs.Tick(ctx)

	model := tui.NewModel()
	s := newShell(ctx, model, census, msgs)
	s.now = func() time.Time { return time.Date(2026, 9, 17, 10, 0, 5, 0, time.UTC) }
	s.Update(tea.WindowSizeMsg{Width: width, Height: height})
	return s
}

// writeMessageStub (re)writes the pi-worker stub so the next poll returns
// msgRows messages. Called once by newWiredShellIn and again by a tail test
// that wants the bus to have grown between two samples.
func writeMessageStub(t *testing.T, dir string, msgRows int) {
	t.Helper()
	type wireMessage struct {
		At      string   `json:"at"`
		From    string   `json:"from"`
		To      []string `json:"to"`
		Content string   `json:"content"`
	}
	wire := make([]wireMessage, msgRows)
	for i := range wire {
		wire[i] = wireMessage{
			At:      fmt.Sprintf("2026-09-17T10:%02d:00Z", i%60),
			From:    fmt.Sprintf("sender%02d", i),
			To:      []string{"bob"},
			Content: fmt.Sprintf("message %02d", i),
		}
	}
	msgJSON, err := json.Marshal(wire)
	if err != nil {
		t.Fatalf("marshal messages: %v", err)
	}
	writeStub(t, dir, "pi-worker", "#!/bin/sh\ncat <<'JSON'\n"+string(msgJSON)+"\nJSON\n")
}

// settleLayout renders one frame off s's current state and returns the
// layout for it. Rendering also settles the panes' viewports on the model,
// so a snapshot taken AFTER this call is comparable field-for-field against
// the model handleMouse leaves behind (handleMouse re-derives the same
// geometry from the same width/height/now before dispatching).
func settleLayout(s *shell) frameLayout {
	_, layout := renderFrame(s.model, s.census.Last(), s.census.Stale(),
		s.msgs.Last(), s.msgs.Stale(), s.now(), s.width, s.height)
	return layout
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
	wantLines, _ := renderFrame(tui.NewModel(), census.Last(), census.Stale(), msgs.Last(), msgs.Stale(), now, 100, 30)
	want := strings.Join(wantLines, "\n")

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

// ---------------------------------------------------------------------------
// sp032 T3: pane geometry and the mouse.
//
// Most of these tests drive renderFrame -> hitTest -> Model.ClickPane/
// ScrollPane directly, the same way sp031/sp032's existing renderFrame tests
// hand-build a sample rather than exec a real agent-census/pi-worker: it
// proves the arithmetic (hitTest's coordinate conversion, ClickPane/
// ScrollPane's model writes) without a subprocess. One test
// (TestMouse_ClickThroughShellUpdate_SelectsRowAndFocusesSameFrame) goes
// through the real shell.Update dispatch with stub binaries, the way
// TestView_EqualsRenderFrameOutput does, to prove main.go's tea.MouseMsg case
// actually calls hitTest/ClickPane rather than merely that they would work if
// called.
// ---------------------------------------------------------------------------

// wideRoster/wideMessages build samples long enough to overflow any budget
// this suite exercises, so a given height forces a real clamp rather than
// leaving a pane's natural length untouched.
func wideRoster(n int) *source.Sample {
	rows := make([]source.Row, n)
	for i := range rows {
		rows[i] = source.Row{UID: fmt.Sprintf("agent%02d", i), Name: fmt.Sprintf("agent%02d", i)}
	}
	return &source.Sample{Rows: rows}
}

func wideMessages(n int) *source.MessageSample {
	msgs := make([]source.Message, n)
	for i := range msgs {
		msgs[i] = sampleMessage(fmt.Sprintf("sender%02d", i), `"x"`)
	}
	return &source.MessageSample{Messages: msgs}
}

// TestLayout_MatchesPaneBudgets is success criterion 1: renderFrame's second
// return value names each visible pane's first row, header height and
// data-row count, and every one of those numbers must equal what
// paneBudgets already allocated — never a second arithmetic on height.
func TestLayout_MatchesPaneBudgets(t *testing.T) {
	roster := wideRoster(100)
	msgs := wideMessages(100)

	// wantSplit mirrors the CONTRACT paneRegion implements (header rows vs
	// data rows for an ordinary, non-empty, non-degenerate pane) so the test
	// does not simply call paneRegion to check paneRegion. The degenerate
	// (renderedLen < headerLines) case is exercised at the smallest heights.
	wantSplit := func(renderedLen int) (headerRows, dataRows int) {
		if renderedLen < headerLines {
			return renderedLen, 0
		}
		return headerLines, renderedLen - headerLines
	}

	for _, height := range []int{5, 6, 7, 8, 10, 16, 24, 32, 40, 64, 80} {
		for _, detailVisible := range []bool{false, true} {
			t.Run(fmt.Sprintf("h=%d/detail=%v", height, detailVisible), func(t *testing.T) {
				model := tui.NewModel()
				model.DetailVisible = detailVisible

				lines, layout := renderFrame(model, roster, false, msgs, false, time.Now(), 80, height)

				rosterLines := paneLines(true, 100)
				logLines := paneLines(true, 100)
				rosterBudget, logBudget, detailBudget, detailShown := paneBudgets(rosterLines, logLines, height, detailVisible, false)

				wantRosterLen := min(rosterLines, rosterBudget)
				wantLogLen := min(logLines, logBudget)

				if layout.detailShown != detailShown {
					t.Fatalf("detailShown = %v, want %v", layout.detailShown, detailShown)
				}

				if layout.roster.firstRow != 0 {
					t.Errorf("roster.firstRow = %d, want 0", layout.roster.firstRow)
				}
				wantRosterHeader, wantRosterData := wantSplit(wantRosterLen)
				if layout.roster.headerRows != wantRosterHeader {
					t.Errorf("roster.headerRows = %d, want %d", layout.roster.headerRows, wantRosterHeader)
				}
				if layout.roster.dataRows != wantRosterData {
					t.Errorf("roster.dataRows = %d, want %d", layout.roster.dataRows, wantRosterData)
				}
				if layout.roster.totalRows != wantRosterLen {
					t.Errorf("roster.totalRows = %d, want %d", layout.roster.totalRows, wantRosterLen)
				}

				wantMsgFirst := wantRosterLen + 1
				if layout.messages.firstRow != wantMsgFirst {
					t.Errorf("messages.firstRow = %d, want %d", layout.messages.firstRow, wantMsgFirst)
				}
				wantMsgHeader, wantMsgData := wantSplit(wantLogLen)
				if layout.messages.headerRows != wantMsgHeader {
					t.Errorf("messages.headerRows = %d, want %d", layout.messages.headerRows, wantMsgHeader)
				}
				if layout.messages.dataRows != wantMsgData {
					t.Errorf("messages.dataRows = %d, want %d", layout.messages.dataRows, wantMsgData)
				}
				if layout.messages.totalRows != wantLogLen {
					t.Errorf("messages.totalRows = %d, want %d", layout.messages.totalRows, wantLogLen)
				}

				wantTotal := wantMsgFirst + wantLogLen
				if detailShown {
					// RenderDetail's own output length is the ground truth
					// here, not detailBudget: a short message (the fixture
					// below is two lines) renders fewer lines than its
					// budget, with no padding to fill it — exactly the bug
					// this assertion exists to catch.
					wantDetailLines := render.RenderDetail(selectedMessage(model, msgs), 80, detailBudget)
					wantDetailLen := len(wantDetailLines)

					wantDetailFirst := wantMsgFirst + wantLogLen + 1
					if layout.detail.firstRow != wantDetailFirst {
						t.Errorf("detail.firstRow = %d, want %d", layout.detail.firstRow, wantDetailFirst)
					}
					wantDetailHeader := min(1, wantDetailLen)
					if layout.detail.headerRows != wantDetailHeader {
						t.Errorf("detail.headerRows = %d, want %d", layout.detail.headerRows, wantDetailHeader)
					}
					if want := wantDetailLen - wantDetailHeader; layout.detail.dataRows != want {
						t.Errorf("detail.dataRows = %d, want %d", layout.detail.dataRows, want)
					}
					if layout.detail.totalRows != wantDetailLen {
						t.Errorf("detail.totalRows = %d, want %d", layout.detail.totalRows, wantDetailLen)
					}
					wantTotal += 1 + wantDetailLen
				}
				if len(lines) != wantTotal {
					t.Errorf("len(lines) = %d, want %d (layout must describe the ACTUAL returned frame)", len(lines), wantTotal)
				}
			})
		}
	}
}

// TestMouse_ClickOnDataRowSelectsThatRow is success criterion 2's data-row
// half, over pane x row offset x scroll offset, so a click at a scrolled
// offset is proven rather than assumed (a click at scroll 0 cannot
// distinguish "selects the clicked row" from "selects the absolute row
// index").
func TestMouse_ClickOnDataRowSelectsThatRow(t *testing.T) {
	cases := []struct {
		name  string
		focus tui.Pane
	}{
		{"roster", tui.PaneRoster},
		{"messages", tui.PaneMessages},
	}

	for _, tc := range cases {
		for _, scroll := range []int{0, 3, 10} {
			for _, offset := range []int{0, 2, 5} {
				t.Run(fmt.Sprintf("%s/scroll=%d/offset=%d", tc.name, scroll, offset), func(t *testing.T) {
					model := tui.NewModel()
					model.DetailVisible = false
					roster := wideRoster(50)
					msgs := wideMessages(50)

					// Settle a frame once so the pane reports a real
					// viewport (sp032 T1's own tests use this same
					// draw-then-act sequencing), THEN scroll.
					renderFrame(model, roster, false, msgs, false, time.Now(), 80, 24)
					if tc.focus == tui.PaneRoster {
						model.ScrollRoster(scroll)
					} else {
						model.ScrollMessages(scroll)
					}

					_, layout := renderFrame(model, roster, false, msgs, false, time.Now(), 80, 24)

					pane := layout.roster
					wantHit := hitRoster
					if tc.focus == tui.PaneMessages {
						pane = layout.messages
						wantHit = hitMessages
					}
					if offset >= pane.dataRows {
						t.Fatalf("test setup: offset %d exceeds this pane's %d visible data rows", offset, pane.dataRows)
					}
					y := pane.firstRow + pane.headerRows + offset

					gotHit, isData, gotOffset := hitTest(layout, y)
					if gotHit != wantHit || !isData || gotOffset != offset {
						t.Fatalf("hitTest(y=%d) = (%v, isData=%v, offset=%d), want (%v, true, %d)",
							y, gotHit, isData, gotOffset, wantHit, offset)
					}

					startFocus := tui.PaneMessages
					if tc.focus == tui.PaneMessages {
						startFocus = tui.PaneRoster
					}
					model.Focus = startFocus
					model.ClickPane(tc.focus, isData, gotOffset)

					if model.Focus != tc.focus {
						t.Errorf("Focus = %v, want %v", model.Focus, tc.focus)
					}
					wantCursor := scroll + offset
					gotCursor := model.RosterCursor
					if tc.focus == tui.PaneMessages {
						gotCursor = model.MessagesCursor
					}
					if gotCursor != wantCursor {
						t.Errorf("cursor = %d, want scroll(%d)+offset(%d) = %d", gotCursor, scroll, offset, wantCursor)
					}
				})
			}
		}
	}
}

// TestMouse_ClickOnHeaderFocusesWithoutSelecting is success criterion 2's
// header half: both the status header line and the column-header line focus
// the pane and leave its cursor exactly where it was.
func TestMouse_ClickOnHeaderFocusesWithoutSelecting(t *testing.T) {
	model := tui.NewModel()
	model.DetailVisible = false
	roster := wideRoster(20)
	msgs := wideMessages(20)

	_, layout := renderFrame(model, roster, false, msgs, false, time.Now(), 80, 24)

	model.Focus = tui.PaneMessages
	for i := 0; i < 4; i++ {
		model.HandleKey(tui.Key{Rune: 'j'})
	}
	if model.MessagesCursor != 4 {
		t.Fatalf("test setup: MessagesCursor = %d, want 4", model.MessagesCursor)
	}

	for _, y := range []int{layout.messages.firstRow, layout.messages.firstRow + 1} {
		model.Focus = tui.PaneRoster // so the click has focus to change

		target, isData, _ := hitTest(layout, y)
		if target != hitMessages || isData {
			t.Fatalf("hitTest(y=%d) = (%v, isData=%v), want (hitMessages, false)", y, target, isData)
		}

		model.ClickPane(tui.PaneMessages, isData, 0)
		if model.Focus != tui.PaneMessages {
			t.Errorf("y=%d: Focus = %v, want PaneMessages", y, model.Focus)
		}
		if model.MessagesCursor != 4 {
			t.Errorf("y=%d: MessagesCursor = %d, want unchanged 4", y, model.MessagesCursor)
		}
	}
}

// TestMouse_ClickOnPlaceholderDoesNotSelect is the edge case: a click on the
// "(no messages)" line focuses the pane but never selects the placeholder as
// though it were a row.
func TestMouse_ClickOnPlaceholderDoesNotSelect(t *testing.T) {
	model := tui.NewModel()
	model.Focus = tui.PaneRoster
	model.DetailVisible = false
	msgs := &source.MessageSample{Messages: []source.Message{}}

	_, layout := renderFrame(model, nil, false, msgs, false, time.Now(), 80, 24)

	y := layout.messages.firstRow + layout.messages.headerRows // the "(no messages)" line
	target, isData, _ := hitTest(layout, y)
	if target != hitMessages || isData {
		t.Fatalf("hitTest(placeholder) = (%v, isData=%v), want (hitMessages, false)", target, isData)
	}

	model.ClickPane(tui.PaneMessages, isData, 0)
	if model.Focus != tui.PaneMessages {
		t.Errorf("Focus = %v, want PaneMessages", model.Focus)
	}
	if model.MessagesCursor != 0 {
		t.Errorf("MessagesCursor = %d, want 0 (nothing to select)", model.MessagesCursor)
	}
}

// TestMouse_WheelScrollsPaneUnderPointerWithoutChangingFocus is success
// criterion 3: the wheel moves the scroll of the pane UNDER THE POINTER,
// even when that pane does not have focus, and touches nothing else — not
// focus, not either pane's cursor, not the other pane's scroll.
// TestMouse_WheelScrollsPaneUnderPointerWithoutChangingFocus is success
// criterion 3, driven as a REAL tea.MouseMsg through shell.Update rather
// than by calling Model.ScrollPane directly. That distinction is the whole
// test: ScrollPane(PaneMessages, 3) asserted against MessagesScroll == 3
// asserts back the literal it was handed, and would still pass if
// handleMouse scrolled the wrong pane, used the wrong delta, or dropped the
// wheel entirely. Sending the wheel event is what puts handleMouse's
// button -> pane -> delta dispatch under test.
//
// Both panes are covered, and in each case FOCUS IS ON THE OTHER ONE, so a
// dispatch that scrolled "the focused pane" instead of "the pane under the
// pointer" fails here.
func TestMouse_WheelScrollsPaneUnderPointerWithoutChangingFocus(t *testing.T) {
	cases := []struct {
		name       string
		focus      tui.Pane
		wantTarget hitTarget
		rowIn      func(frameLayout) paneLayout
		scrollOf   func(*tui.Model) int
		otherName  string
	}{
		{
			name:       "messages pane under pointer, roster focused",
			focus:      tui.PaneRoster,
			wantTarget: hitMessages,
			rowIn:      func(l frameLayout) paneLayout { return l.messages },
			scrollOf:   func(m *tui.Model) int { return m.MessagesScroll },
			otherName:  "RosterScroll",
		},
		{
			name:       "roster pane under pointer, messages focused",
			focus:      tui.PaneMessages,
			wantTarget: hitRoster,
			rowIn:      func(l frameLayout) paneLayout { return l.roster },
			scrollOf:   func(m *tui.Model) int { return m.RosterScroll },
			otherName:  "MessagesScroll",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newWiredShell(t, 60, 60, 100, 30)
			s.model.DetailVisible = false
			s.model.Focus = tc.focus

			layout := settleLayout(s)
			pane := tc.rowIn(layout)
			y := pane.firstRow + pane.headerRows + 2
			if target, isData, _ := hitTest(layout, y); target != tc.wantTarget || !isData {
				t.Fatalf("test setup: hitTest(y=%d) = (%v, isData=%v), want (%v, true)", y, target, isData, tc.wantTarget)
			}

			// want is every field the wheel must leave alone. Only the pane
			// under the pointer's scroll is allowed to differ, and only by
			// exactly 3 — so a swapped dispatch, a changed delta, a moved
			// cursor, a moved focus or a dropped event all fail.
			before := *s.model
			want := before
			switch tc.wantTarget {
			case hitMessages:
				want.MessagesScroll = before.MessagesScroll + 3
			case hitRoster:
				want.RosterScroll = before.RosterScroll + 3
			}

			s.Update(tea.MouseMsg{X: 5, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonWheelDown})

			if got := tc.scrollOf(s.model); got != tc.scrollOf(&want) {
				t.Errorf("scroll of the pane under the pointer = %d, want %d (a wheel notch is exactly 3 lines)", got, tc.scrollOf(&want))
			}
			if s.model.Focus != before.Focus {
				t.Errorf("Focus changed: got %v, want %v", s.model.Focus, before.Focus)
			}
			if s.model.RosterCursor != before.RosterCursor {
				t.Errorf("RosterCursor changed: got %d, want %d", s.model.RosterCursor, before.RosterCursor)
			}
			if s.model.MessagesCursor != before.MessagesCursor {
				t.Errorf("MessagesCursor changed: got %d, want %d", s.model.MessagesCursor, before.MessagesCursor)
			}
			if *s.model != want {
				t.Fatalf("WheelDown changed more (or less) than %s by 3:\n got %+v\nwant %+v\n(the pane NOT under the pointer must not move; %s in particular)",
					tc.otherName, *s.model, want, tc.otherName)
			}

			// And back: a WheelUp at the same coordinate returns the same
			// pane to where it started, leaving everything else as it was.
			s.Update(tea.MouseMsg{X: 5, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonWheelUp})
			if *s.model != before {
				t.Fatalf("WheelUp did not undo WheelDown:\n got %+v\nwant %+v", *s.model, before)
			}
		})
	}
}

// TestMouse_PressOnSeparatorChangesNothing is criterion 2's third clause and
// the "click on the blank separator" edge case: the rows BETWEEN panes
// belong to no pane (hitTest reports hitNone), and no button pressed there
// may move focus, a cursor or a scroll. Every button is tried, because
// hitNone reaches a different arm of handleMouse's switch for each one.
func TestMouse_PressOnSeparatorChangesNothing(t *testing.T) {
	s := newWiredShell(t, 20, 20, 100, 30)
	s.model.DetailVisible = true
	// dotfiles-zgdi: Focus must be set to something OTHER than the
	// PaneRoster zero value, or "nothing changed" is indistinguishable from
	// "a separator press focused the roster" — the struct compare below
	// would pass either way.
	s.model.Focus = tui.PaneMessages

	layout := settleLayout(s)
	if !layout.detailShown {
		t.Fatalf("test setup: expected the detail pane shown at height 30")
	}

	seps := map[string]int{
		"roster/messages": layout.roster.firstRow + layout.roster.totalRows,
		"messages/detail": layout.messages.firstRow + layout.messages.totalRows,
	}
	for name, y := range seps {
		if target, _, _ := hitTest(layout, y); target != hitNone {
			t.Fatalf("test setup: hitTest(%s separator, y=%d) = %v, want hitNone", name, y, target)
		}
	}

	want := *s.model
	buttons := []struct {
		name string
		btn  tea.MouseButton
	}{
		{"left", tea.MouseButtonLeft},
		{"wheel-down", tea.MouseButtonWheelDown},
		{"wheel-up", tea.MouseButtonWheelUp},
	}
	for name, y := range seps {
		for _, b := range buttons {
			s.Update(tea.MouseMsg{X: 4, Y: y, Action: tea.MouseActionPress, Button: b.btn})
			if *s.model != want {
				t.Fatalf("%s press on the %s separator (y=%d) changed model state:\n got %+v\nwant %+v",
					b.name, name, y, *s.model, want)
			}
		}
	}
}

// TestMouse_WheelOverDetailAndEmptyPaneIsSafe covers two of the edge cases
// explicitly: a wheel over the (visible) detail pane must not panic or
// fabricate a scroll authority — sp032 T3 gives the detail pane no cursor and
// no scroll (T4's job) — and a wheel over a pane showing only the
// placeholder must leave its scroll at 0, not go negative.
func TestMouse_WheelOverDetailAndEmptyPaneIsSafe(t *testing.T) {
	model := tui.NewModel()
	model.DetailVisible = true
	roster := wideRoster(3)
	msgs := &source.MessageSample{Messages: []source.Message{}}

	_, layout := renderFrame(model, roster, false, msgs, false, time.Now(), 80, 24)
	if !layout.detailShown {
		t.Fatalf("test setup: expected detail shown at height 24")
	}

	if target, _, _ := hitTest(layout, layout.detail.firstRow); target != hitDetail {
		t.Fatalf("test setup: hitTest(detail) = %v, want hitDetail", target)
	}
	// Asserting the target alone is the safety property here: a detail-pane
	// coordinate must never be mapped onto PaneRoster/PaneMessages. sp032
	// T4 gave hitDetail its own handleMouse cases (focus on a press, scroll
	// on a wheel); what they do is asserted by
	// TestDetail_WheelScrollsTheDetailPane and
	// TestDetail_LeftClickFocusesTheDetailPane.

	my := layout.messages.firstRow + layout.messages.headerRows
	target, isData, _ := hitTest(layout, my)
	if target != hitMessages || isData {
		t.Fatalf("hitTest(placeholder) = (%v, isData=%v), want (hitMessages, false)", target, isData)
	}
	model.ScrollPane(tui.PaneMessages, -3)
	if model.MessagesScroll != 0 {
		t.Errorf("MessagesScroll = %d, want 0 for an empty list", model.MessagesScroll)
	}
	model.ScrollPane(tui.PaneMessages, 3)
	if model.MessagesScroll != 0 {
		t.Errorf("MessagesScroll = %d, want 0 for an empty list", model.MessagesScroll)
	}
}

// TestMouse_ClickWhileEditingMovesSelectionWithoutCancellingDraft is the edge
// case: unlike every keyboard entry point (which swallows runes into an open
// filter draft — HandleKey checks Editing first), a mouse press is not a
// rune. ClickPane must move focus and selection even while Editing is true,
// and the draft itself (observable only via the eventual committed Filter)
// must survive untouched.
func TestMouse_ClickWhileEditingMovesSelectionWithoutCancellingDraft(t *testing.T) {
	model := tui.NewModel()
	model.DetailVisible = false
	roster := wideRoster(20)
	msgs := wideMessages(20)

	_, layout := renderFrame(model, roster, false, msgs, false, time.Now(), 80, 24)

	model.Focus = tui.PaneRoster
	model.HandleKey(tui.Key{Rune: '/'})
	for _, r := range "hello" {
		model.HandleKey(tui.Key{Rune: r})
	}
	if !model.Editing {
		t.Fatalf("test setup: expected Editing true after `/hello`")
	}

	y := layout.messages.firstRow + layout.messages.headerRows + 2
	target, isData, offset := hitTest(layout, y)
	if target != hitMessages || !isData {
		t.Fatalf("test setup: hitTest(y=%d) = (%v, isData=%v), want (hitMessages, true)", y, target, isData)
	}
	model.ClickPane(tui.PaneMessages, isData, offset)

	if model.Focus != tui.PaneMessages {
		t.Errorf("Focus = %v, want PaneMessages: a click while Editing must still move focus", model.Focus)
	}
	if model.MessagesCursor != offset {
		t.Errorf("MessagesCursor = %d, want %d: a click while Editing must still select", model.MessagesCursor, offset)
	}
	if !model.Editing {
		t.Errorf("Editing = false, want true: the draft must not be cancelled by a click")
	}

	// Commit the draft now and confirm it was never touched by the click.
	model.HandleKey(tui.Key{Special: tui.KeyEnter})
	if model.Filter.Query != "hello" {
		t.Errorf("Filter.Query = %q, want %q: the click must not have edited the draft", model.Filter.Query, "hello")
	}
}

// TestMouse_ClickAtTopRowAndBeyondWidthIsSafe is the y==0 and
// x-beyond-rendered-width edge cases: y==0 is the very first line of the
// frame (the roster's own status header) and must focus, not panic or
// underflow; x is not part of hitTest's contract at all (see its doc), so an
// arbitrarily large x must not change the result.
func TestMouse_ClickAtTopRowAndBeyondWidthIsSafe(t *testing.T) {
	model := tui.NewModel()
	model.DetailVisible = false
	model.Focus = tui.PaneMessages
	roster := wideRoster(20)
	msgs := wideMessages(20)

	_, layout := renderFrame(model, roster, false, msgs, false, time.Now(), 80, 24)

	for _, x := range []int{0, 79, 1000, -5} {
		target, isData, _ := hitTest(layout, 0)
		if target != hitRoster || isData {
			t.Fatalf("x=%d: hitTest(y=0) = (%v, isData=%v), want (hitRoster, false)", x, target, isData)
		}
	}

	model.ClickPane(tui.PaneRoster, false, 0)
	if model.Focus != tui.PaneRoster {
		t.Errorf("Focus = %v, want PaneRoster after a y==0 press", model.Focus)
	}
}

// TestMouse_MotionEventsIgnored is the edge case that cell-motion reporting
// sends during a drag: shell.handleMouse must return before doing anything
// else, so a motion event over a pane's DATA rows must neither focus it nor
// select a row nor scroll it.
//
// The button table matters. A motion carrying Left is also rejected by the
// inner `Action != MouseActionPress` check inside the left-button arm, so a
// Left-only test passes even with the outer motion guard deleted. The WHEEL
// arms check no Action at all — the outer guard is the only thing between a
// drag report and a scroll — so the wheel rows are what actually hold that
// guard in place.
func TestMouse_MotionEventsIgnored(t *testing.T) {
	s := newWiredShell(t, 40, 40, 100, 30)
	s.model.Focus = tui.PaneRoster

	layout := settleLayout(s)
	y := layout.messages.firstRow + layout.messages.headerRows + 2
	if target, isData, _ := hitTest(layout, y); target != hitMessages || !isData {
		t.Fatalf("test setup: hitTest(y=%d) = (%v, isData=%v), want (hitMessages, true)", y, target, isData)
	}

	want := *s.model
	for _, b := range []struct {
		name string
		btn  tea.MouseButton
	}{
		{"left", tea.MouseButtonLeft},
		{"wheel-down", tea.MouseButtonWheelDown},
		{"wheel-up", tea.MouseButtonWheelUp},
	} {
		s.Update(tea.MouseMsg{X: 5, Y: y, Action: tea.MouseActionMotion, Button: b.btn})
		if *s.model != want {
			t.Errorf("a %s motion event over a data row changed model state:\n got %+v\nwant %+v",
				b.name, *s.model, want)
		}
	}
}

// wantMaxTop restates ScrollRoster/ScrollMessages's documented clamp bound
// (keys.go's maxTop) so this test can check against the CONTRACT without
// reaching into tui's unexported helper.
func wantMaxTop(length, viewport int) int {
	if viewport <= 0 {
		if length <= 0 {
			return 0
		}
		return length - 1
	}
	if length <= viewport {
		return 0
	}
	return length - viewport
}

// TestMouse_NeverProducesOutOfRangeCursorOrScroll is success criterion 5: for
// randomised (x, y) over randomised heights and row counts, no click or wheel
// may leave a cursor outside [0, len-1] or a scroll outside its clamp. x is
// generated (and ignored, per hitTest's doc) so the property is checked
// exactly as the task states it.
func TestMouse_NeverProducesOutOfRangeCursorOrScroll(t *testing.T) {
	rng := rand.New(rand.NewSource(1))

	for i := 0; i < 500; i++ {
		height := rng.Intn(80) + 1
		rosterRows := rng.Intn(60)
		msgRows := rng.Intn(60)
		detailVisible := rng.Intn(2) == 0

		model := tui.NewModel()
		model.DetailVisible = detailVisible
		roster := wideRoster(rosterRows)
		msgs := wideMessages(msgRows)

		_, layout := renderFrame(model, roster, false, msgs, false, time.Now(), 80, height)

		y := rng.Intn(height+20) - 10

		target, isData, offset := hitTest(layout, y)
		// hitNone (a separator row, or a y off the frame entirely) and
		// hitDetail are not "nothing to do" — they are an assertion that
		// nothing happens. Without this the switch below would fall through
		// silently and the property would be vacuously true for them.
		beforeClick := *model
		switch target {
		case hitRoster:
			model.ClickPane(tui.PaneRoster, isData, offset)
		case hitMessages:
			model.ClickPane(tui.PaneMessages, isData, offset)
		default:
			if *model != beforeClick {
				t.Fatalf("iter %d: a %v press at y=%d changed model state:\n got %+v\nwant %+v",
					i, target, y, *model, beforeClick)
			}
		}

		if model.RosterCursor < 0 || model.RosterCursor > maxIndexFor(model.RosterLen) {
			t.Fatalf("iter %d: RosterCursor %d out of [0,%d)", i, model.RosterCursor, model.RosterLen)
		}
		if model.MessagesCursor < 0 || model.MessagesCursor > maxIndexFor(model.MessagesLen) {
			t.Fatalf("iter %d: MessagesCursor %d out of [0,%d)", i, model.MessagesCursor, model.MessagesLen)
		}

		delta := rng.Intn(7) - 3
		beforeScroll := *model
		switch target {
		case hitRoster:
			model.ScrollPane(tui.PaneRoster, delta)
		case hitMessages:
			model.ScrollPane(tui.PaneMessages, delta)
		default:
			if *model != beforeScroll {
				t.Fatalf("iter %d: a %v wheel at y=%d changed model state:\n got %+v\nwant %+v",
					i, target, y, *model, beforeScroll)
			}
		}

		if model.RosterScroll < 0 || model.RosterScroll > wantMaxTop(model.RosterLen, model.RosterViewport) {
			t.Fatalf("iter %d: RosterScroll %d out of clamp [0,%d]", i, model.RosterScroll, wantMaxTop(model.RosterLen, model.RosterViewport))
		}
		if model.MessagesScroll < 0 || model.MessagesScroll > wantMaxTop(model.MessagesLen, model.MessagesViewport) {
			t.Fatalf("iter %d: MessagesScroll %d out of clamp [0,%d]", i, model.MessagesScroll, wantMaxTop(model.MessagesLen, model.MessagesViewport))
		}
	}
}

func maxIndexFor(n int) int {
	if n <= 0 {
		return 0
	}
	return n - 1
}

// TestMouse_ClickThroughShellUpdate_SelectsRowAndFocusesSameFrame is the
// end-to-end proof that main.go's tea.MouseMsg case is wired to hitTest and
// Model.ClickPane — every other sp032 T3 test above drives that pair
// directly, which proves the arithmetic but not that Update ever reaches it.
// It also proves criterion 4: clicking a message row updates the detail pane
// in the SAME frame, since View() re-derives selectedMessage from whatever
// Update just set.
func TestMouse_ClickThroughShellUpdate_SelectsRowAndFocusesSameFrame(t *testing.T) {
	dir := t.TempDir()
	writeStub(t, dir, "agent-census", "#!/bin/sh\necho '[]'\n")
	writeStub(t, dir, "pi-worker", "#!/bin/sh\necho '[{\"from\":\"alice\",\"to\":[\"bob\"],\"content\":\"first message\",\"at\":\"2026-09-17T10:00:00Z\"},{\"from\":\"carol\",\"to\":[\"bob\"],\"content\":\"second message\",\"at\":\"2026-09-17T10:00:01Z\"}]'\n")

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

	model := tui.NewModel()
	model.Focus = tui.PaneRoster
	model.DetailVisible = true
	s := newShell(ctx, model, census, msgs)
	s.now = func() time.Time { return time.Date(2026, 9, 17, 10, 0, 5, 0, time.UTC) }

	s.Update(tea.WindowSizeMsg{Width: 100, Height: 30})

	_, layout := renderFrame(s.model, census.Last(), census.Stale(), msgs.Last(), msgs.Stale(), s.now(), s.width, s.height)
	y := layout.messages.firstRow + layout.messages.headerRows + 1 // carol, the second message row

	s.Update(tea.MouseMsg{X: 5, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonLeft})

	if s.model.Focus != tui.PaneMessages {
		t.Fatalf("Focus = %v, want PaneMessages after clicking a message row", s.model.Focus)
	}
	if s.model.MessagesCursor != 1 {
		t.Fatalf("MessagesCursor = %d, want 1 (the clicked row)", s.model.MessagesCursor)
	}

	view := s.View()
	if !strings.Contains(view, "carol →") {
		t.Fatalf("expected the detail pane to show carol's message in the SAME frame, got:\n%s", view)
	}
	if strings.Contains(view, "alice →") {
		t.Fatalf("expected alice's message no longer selected, got:\n%s", view)
	}
}

// ---------------------------------------------------------------------------
// sp032 T4: the detail pane becomes a peer.
// ---------------------------------------------------------------------------

// newDetailShell is newWiredShell with message bodies long enough that the
// detail pane actually has somewhere to scroll: each envelope's content is a
// JSON object of bodyKeys keys, which json.Indent renders as one line per
// key plus the braces. Senders differ per message so a selection change is
// observable in the detail header, and the ids are distinct so the
// scroll-reset rule has something real to key on.
func newDetailShell(t *testing.T, msgCount, bodyKeys, width, height int) *shell {
	t.Helper()
	dir := t.TempDir()

	rows := make([]source.Row, 8)
	for i := range rows {
		rows[i] = source.Row{UID: fmt.Sprintf("agent%02d", i), Name: fmt.Sprintf("agent%02d", i), Bucket: "idle"}
	}
	rosterJSON, err := json.Marshal(rows)
	if err != nil {
		t.Fatalf("marshal roster: %v", err)
	}

	var msgs strings.Builder
	msgs.WriteString("[")
	for i := 0; i < msgCount; i++ {
		if i > 0 {
			msgs.WriteString(",")
		}
		fmt.Fprintf(&msgs, `{"at":"2026-09-17T10:%02d:00Z","id":"msg%02d","from":"sender%02d","to":["bob"],"kind":"message","content":{`, i%60, i, i)
		for k := 0; k < bodyKeys; k++ {
			if k > 0 {
				msgs.WriteString(",")
			}
			fmt.Fprintf(&msgs, `"k%03d":"m%02d-v%03d"`, k, i, k)
		}
		msgs.WriteString("}}")
	}
	msgs.WriteString("]")

	writeStub(t, dir, "agent-census", "#!/bin/sh\ncat <<'JSON'\n"+string(rosterJSON)+"\nJSON\n")
	writeStub(t, dir, "pi-worker", "#!/bin/sh\ncat <<'JSON'\n"+msgs.String()+"\nJSON\n")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	ctx := context.Background()
	census := source.NewMonitor(source.NewSampler(filepath.Join(dir, "stamp")))
	census.Refresh(ctx)
	mm := source.NewMessagesMonitor(source.NewMessagesSampler())
	mm.Tick(ctx)

	s := newShell(ctx, tui.NewModel(), census, mm)
	s.now = func() time.Time { return time.Date(2026, 9, 17, 10, 0, 5, 0, time.UTC) }
	s.Update(tea.WindowSizeMsg{Width: width, Height: height})
	// A real session always draws once before bubbletea delivers a key
	// (runInteractive's forced first reads, then View), and that first draw
	// is what establishes MessagesLen — which the zoom refusal reads. Draw
	// here too, so a key test is not accidentally testing a pre-first-frame
	// model no operator can ever be looking at.
	settleLayout(s)
	return s
}

// detailPaneLines renders one frame off s's current state and returns the
// detail pane's own rows, split into its header line and its body rows, as
// they actually appear on screen. Reading the FRAME (rather than the model's
// scroll field) is what makes the scroll assertions below about what the
// operator sees.
func detailPaneLines(t *testing.T, s *shell) (header string, body []string) {
	t.Helper()
	lines, layout := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
	if !layout.detailShown {
		t.Fatalf("detail pane is not shown in this frame: %q", lines)
	}
	d := layout.detail
	if d.totalRows == 0 {
		t.Fatalf("detail pane occupies no rows: %q", lines)
	}
	return lines[d.firstRow], lines[d.firstRow+d.headerRows : d.firstRow+d.totalRows]
}

func focusDetail(t *testing.T, s *shell) {
	t.Helper()
	for i := 0; i < 2; i++ {
		s.Update(key(tea.KeyTab))
	}
	if s.model.Focus != tui.PaneDetail {
		t.Fatalf("setup: Focus = %v after two tabs, want PaneDetail", s.model.Focus)
	}
}

// TestUpdate_TabCyclesThreePanes is criterion 1 driven through the REAL
// path: a tea.KeyMsg into shell.Update, not a Model method call. The detail
// pane is a focus stop only if the key actually reaches it.
func TestUpdate_TabCyclesThreePanes(t *testing.T) {
	s := newDetailShell(t, 3, 30, 100, 40)
	want := []tui.Pane{tui.PaneMessages, tui.PaneDetail, tui.PaneRoster, tui.PaneMessages, tui.PaneDetail, tui.PaneRoster}
	for i, w := range want {
		s.Update(key(tea.KeyTab))
		if s.model.Focus != w {
			t.Fatalf("tab #%d: Focus = %v, want %v", i+1, s.model.Focus, w)
		}
	}
}

// TestDetail_ScrollSurvivesRerenderOfSameMessage is criterion 3's 2-second
// tick case, asserted on the RENDERED FRAME. A naive pane that rebuilt its
// scroll state on each render would snap back to the top here, and the
// message pane's own sample ticks every two seconds, so "each render" is
// "every two seconds" in a real session.
func TestDetail_ScrollSurvivesRerenderOfSameMessage(t *testing.T) {
	s := newDetailShell(t, 3, 60, 100, 40)
	focusDetail(t, s)

	_, top := detailPaneLines(t, s)
	for i := 0; i < 5; i++ {
		s.Update(runeKey('j'))
	}
	_, scrolled := detailPaneLines(t, s)
	if scrolled[0] == top[0] {
		t.Fatalf("setup: five `j` presses did not move the detail body off %q", top[0])
	}

	for i := 0; i < 5; i++ {
		s.Update(messagesTickMsg{})
		s.Update(rosterTickMsg{})
		_, again := detailPaneLines(t, s)
		if again[0] != scrolled[0] {
			t.Fatalf("tick #%d: detail body starts at %q, want the scrolled %q", i+1, again[0], scrolled[0])
		}
	}
}

// TestDetail_SelectionChangeResetsScrollToTop is criterion 3's other half:
// moving the message selection must put the reader at the TOP of the new
// message, never 5 lines into a body they have not seen the start of.
func TestDetail_SelectionChangeResetsScrollToTop(t *testing.T) {
	s := newDetailShell(t, 3, 60, 100, 40)
	focusDetail(t, s)

	_, top := detailPaneLines(t, s)
	for i := 0; i < 5; i++ {
		s.Update(runeKey('j'))
	}
	if _, scrolled := detailPaneLines(t, s); scrolled[0] == top[0] {
		t.Fatalf("setup: the detail body did not scroll")
	}

	// tab → roster → messages, then `j` to select the next message.
	s.Update(key(tea.KeyTab))
	s.Update(key(tea.KeyTab))
	if s.model.Focus != tui.PaneMessages {
		t.Fatalf("setup: Focus = %v, want PaneMessages", s.model.Focus)
	}
	s.Update(runeKey('j'))

	header, body := detailPaneLines(t, s)
	if !strings.Contains(header, "sender01") {
		t.Fatalf("detail header %q, want the newly selected sender01", header)
	}
	if body[0] != top[0] {
		t.Errorf("detail body starts at %q after a selection change, want the top line %q", body[0], top[0])
	}
}

// TestZoom_HidesOtherPanesAndRestoresScrollOnExit is criterion 4, end to
// end: `enter` gives the detail pane the whole frame (one header row plus
// height-1 viewport rows) with a zoom indicator on the header and neither
// other pane rendered, and `esc` puts the three-pane layout back WITH the
// scroll position the reader had.
func TestZoom_HidesOtherPanesAndRestoresScrollOnExit(t *testing.T) {
	s := newDetailShell(t, 3, 80, 100, 40)
	focusDetail(t, s)
	for i := 0; i < 5; i++ {
		s.Update(runeKey('j'))
	}
	_, scrolled := detailPaneLines(t, s)

	s.Update(key(tea.KeyEnter))
	if !s.model.DetailZoom {
		t.Fatalf("enter did not zoom")
	}
	lines, layout := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)

	for _, l := range lines {
		if strings.Contains(l, "agent0") {
			t.Fatalf("zoomed frame still renders a roster row: %q", l)
		}
		// sp033 T6: this shell never triggers the explicit head-opening (only
		// settleLayout, not View()), so the cursor sits at its raw zero value
		// — which is now row 0 of the REORDERED list, i.e. sender02, the
		// newest of the three ascending messages. sender00/sender01 must
		// appear nowhere in a zoomed frame: not as log rows (the log is
		// hidden) and not as the detail selection (sender02 is selected).
		if strings.Contains(l, "sender00") || strings.Contains(l, "sender01") {
			t.Fatalf("zoomed frame still renders the message log: %q", l)
		}
	}
	if len(lines) != s.height {
		t.Errorf("zoomed frame is %d lines, want the full height %d", len(lines), s.height)
	}
	if layout.detail.firstRow != 0 {
		t.Errorf("zoomed detail pane starts at row %d, want 0", layout.detail.firstRow)
	}
	if layout.detail.dataRows != s.height-1 {
		t.Errorf("zoomed viewport is %d rows, want height-1 = %d", layout.detail.dataRows, s.height-1)
	}
	if !strings.Contains(lines[0], zoomIndicator) {
		t.Errorf("zoomed header %q, want a %q indicator", lines[0], zoomIndicator)
	}
	if lines[1] != scrolled[0] {
		t.Errorf("zoomed body starts at %q, want the scroll carried in at %q", lines[1], scrolled[0])
	}

	s.Update(key(tea.KeyEsc))
	if s.model.DetailZoom {
		t.Fatalf("esc did not leave zoom")
	}
	back, backLayout := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
	if !containsSubstring(back, "agent00") {
		t.Errorf("esc did not restore the roster pane: %q", back)
	}
	if !backLayout.detailShown {
		t.Fatalf("esc left the detail pane hidden")
	}
	_, body := detailPaneLines(t, s)
	if body[0] != scrolled[0] {
		t.Errorf("after esc the detail body starts at %q, want the previous scroll %q", body[0], scrolled[0])
	}
	if strings.Contains(back[backLayout.detail.firstRow], zoomIndicator) {
		t.Errorf("the zoom indicator survived esc: %q", back[backLayout.detail.firstRow])
	}
}

// TestZoom_RefusedWithNoSelection is criterion 5's last clause through the
// real key path: an empty log has no message to zoom, so the three-pane
// frame must survive both zoom keys untouched.
func TestZoom_RefusedWithNoSelection(t *testing.T) {
	s := newDetailShell(t, 0, 0, 100, 40)
	before, _ := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)

	for _, k := range []tea.KeyMsg{key(tea.KeyEnter), runeKey('o'), runeKey('O')} {
		s.Update(k)
		if s.model.DetailZoom {
			t.Fatalf("key %v zoomed with an empty log", k)
		}
		after, _ := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
		if !reflect.DeepEqual(before, after) {
			t.Fatalf("key %v changed the frame on a refused zoom:\n got %q\nwant %q", k, after, before)
		}
	}
}

// TestDetail_HidingWhileFocusedMovesFocus is criterion 5 through the real
// key path, including the `d`-while-zoomed edge case: the pane goes away,
// the zoom goes with it, and focus lands on the message pane rather than on
// something that is no longer drawn.
func TestDetail_HidingWhileFocusedMovesFocus(t *testing.T) {
	s := newDetailShell(t, 3, 40, 100, 40)
	focusDetail(t, s)
	s.Update(key(tea.KeyEnter)) // zoom, so `d` has both states to undo
	if !s.model.DetailZoom {
		t.Fatalf("setup: not zoomed")
	}

	s.Update(runeKey('d'))
	if s.model.DetailVisible {
		t.Errorf("DetailVisible = true after `d`, want false")
	}
	if s.model.DetailZoom {
		t.Errorf("DetailZoom = true after `d`, want false (hidden-but-zoomed is not a state)")
	}
	if s.model.Focus != tui.PaneMessages {
		t.Errorf("Focus = %v after hiding the focused detail pane, want PaneMessages", s.model.Focus)
	}

	lines, layout := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
	if layout.detailShown {
		t.Errorf("layout still reports the detail pane shown after `d`")
	}
	if containsSubstring(lines, "→") {
		t.Errorf("the detail pane is still rendered after `d`: %q", lines)
	}
	if !containsSubstring(lines, "agent00") {
		t.Errorf("hiding the detail pane also lost the roster: %q", lines)
	}
}

// TestEsc_CancelsFilterDraft is the deliberate addition in the edge_cases,
// driven through shell.Update because "esc is decoded at all" is exactly the
// dispatch question: translateKey had no case for it before this task.
func TestEsc_CancelsFilterDraft(t *testing.T) {
	s := newDetailShell(t, 3, 20, 100, 40)

	s.Update(runeKey('/'))
	s.Update(runeKey('s'))
	s.Update(runeKey('0'))
	s.Update(runeKey('1'))
	s.Update(key(tea.KeyEnter))
	if got := s.model.Filter; got != (tui.Filter{Set: true, Query: "s01"}) {
		t.Fatalf("setup: Filter = %+v, want the committed s01", got)
	}
	committed, _ := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)

	s.Update(runeKey('/'))
	s.Update(runeKey('z'))
	s.Update(key(tea.KeyEsc))
	if s.model.Editing {
		t.Errorf("Editing = true after esc, want the draft closed")
	}
	if got := s.model.Filter; got != (tui.Filter{Set: true, Query: "s01"}) {
		t.Errorf("Filter = %+v after esc, want the committed s01 untouched", got)
	}
	after, _ := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
	if !reflect.DeepEqual(committed, after) {
		t.Errorf("esc on a draft changed the frame:\n got %q\nwant %q", after, committed)
	}
}

// TestDetail_WheelScrollsTheDetailPane is criterion 3's wheel clause through
// a real tea.MouseMsg: T3 routed a wheel over the detail pane to nothing at
// all, and this is the event that must now reach it.
func TestDetail_WheelScrollsTheDetailPane(t *testing.T) {
	s := newDetailShell(t, 3, 60, 100, 40)
	layout := settleLayout(s)
	if !layout.detailShown {
		t.Fatalf("setup: detail pane not shown")
	}
	_, top := detailPaneLines(t, s)

	y := layout.detail.firstRow + layout.detail.headerRows
	if target, _, _ := hitTest(layout, y); target != hitDetail {
		t.Fatalf("setup: hitTest(y=%d) = %v, want hitDetail", y, target)
	}

	s.Update(tea.MouseMsg{X: 4, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonWheelDown})
	_, down := detailPaneLines(t, s)
	if down[0] == top[0] {
		t.Fatalf("wheel-down over the detail pane did not scroll it (still %q)", top[0])
	}
	if s.model.Focus != tui.PaneRoster {
		t.Errorf("the wheel changed focus to %v, want it left on PaneRoster", s.model.Focus)
	}
	if s.model.RosterScroll != 0 || s.model.MessagesScroll != 0 {
		t.Errorf("a wheel over the detail pane moved another pane: roster=%d messages=%d",
			s.model.RosterScroll, s.model.MessagesScroll)
	}

	s.Update(tea.MouseMsg{X: 4, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonWheelUp})
	if _, up := detailPaneLines(t, s); up[0] != top[0] {
		t.Errorf("wheel-up did not return to %q, got %q", top[0], up[0])
	}
}

// TestDetail_LeftClickFocusesTheDetailPane: the pane is a focus stop now, so
// a press on it must focus it — T3 deliberately left this inert.
func TestDetail_LeftClickFocusesTheDetailPane(t *testing.T) {
	s := newDetailShell(t, 3, 60, 100, 40)
	layout := settleLayout(s)
	y := layout.detail.firstRow + layout.detail.headerRows
	beforeCursor := s.model.MessagesCursor

	s.Update(tea.MouseMsg{X: 2, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonLeft})
	if s.model.Focus != tui.PaneDetail {
		t.Errorf("Focus = %v after a press on the detail pane, want PaneDetail", s.model.Focus)
	}
	if s.model.MessagesCursor != beforeCursor {
		t.Errorf("a press on the detail pane moved the message cursor to %d, want %d",
			s.model.MessagesCursor, beforeCursor)
	}
}

// TestZoom_TerminalTooShortStillFits is the edge case: a terminal with no
// room for the zoom layout must still produce a frame that fits, and must
// not panic.
func TestZoom_TerminalTooShortStillFits(t *testing.T) {
	for _, h := range []int{1, 2, 3, 4} {
		s := newDetailShell(t, 3, 40, 40, 40)
		s.Update(tea.WindowSizeMsg{Width: 40, Height: h})
		s.model.Focus = tui.PaneDetail
		s.Update(key(tea.KeyEnter))
		if !s.model.DetailZoom {
			t.Fatalf("height %d: enter did not zoom", h)
		}
		lines, _ := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
		if len(lines) > h {
			t.Errorf("height %d: zoomed frame is %d lines, want at most %d", h, len(lines), h)
		}
	}
}

// TestDetail_WideSingleLinePayloadWrapsAndScrolls is the edge case: a
// payload that is one physical line thousands of cells wide must wrap to the
// pane width (wrapCells) and be reachable by scrolling, not run off the
// right edge.
func TestDetail_WideSingleLinePayloadWrapsAndScrolls(t *testing.T) {
	model := tui.NewModel()
	model.Focus = tui.PaneDetail
	wide := strings.Repeat("abcdefghij", 400) // 4000 cells on one physical line
	msgs := &source.MessageSample{Messages: []source.Message{sampleMessage("alice", `"`+wide+`"`)}}

	const width = 40
	lines, layout := renderFrame(model, wideRoster(3), false, msgs, false, time.Now(), width, 40)
	if !layout.detailShown {
		t.Fatalf("setup: detail pane not shown")
	}
	for _, l := range lines {
		if len([]rune(strings.ReplaceAll(strings.ReplaceAll(l, styleOn, ""), styleOff, ""))) > width {
			t.Fatalf("line %q exceeds width %d", l, width)
		}
	}
	first := lines[layout.detail.firstRow+layout.detail.headerRows]

	model.ScrollDetail(3)
	lines2, layout2 := renderFrame(model, wideRoster(3), false, msgs, false, time.Now(), width, 40)
	if got := lines2[layout2.detail.firstRow+layout2.detail.headerRows]; got == first {
		t.Fatalf("scrolling a 4000-cell single-line payload showed the same first row %q", got)
	}
}

// ---------------------------------------------------------------------------
// sp032 T5: paging keys on all three panes.
// ---------------------------------------------------------------------------

// TestUpdate_PagingKeysReachTheFocusedPane is T5 criterion 1 and 2 driven
// through the REAL dispatch path — a tea.KeyMsg into shell.Update over wired
// monitors — rather than by calling a tui.Model method and asserting the
// value just passed in. Home and End were not decoded at all before this
// task: a model that pages correctly behind a translateKey that drops the
// event is a feature no operator can reach, and only an event-level test
// says so.
//
// The pane is 60 rows deep in a 30-row terminal, so the roster viewport is a
// real number well under the row count and a page is a distinguishable jump
// rather than a clamp to the end.
func TestUpdate_PagingKeysReachTheFocusedPane(t *testing.T) {
	t.Run("pgdn advances the roster by its viewport minus one", func(t *testing.T) {
		s := newWiredShell(t, 60, 60, 100, 30)
		settleLayout(s)
		vp := s.model.RosterViewport
		if vp < 3 {
			t.Fatalf("setup: roster viewport = %d, want a pageable pane", vp)
		}
		s.Update(key(tea.KeyPgDown))
		if want := vp - 1; s.model.RosterCursor != want {
			t.Errorf("RosterCursor = %d after PgDn with viewport %d, want %d", s.model.RosterCursor, vp, want)
		}
	})

	t.Run("end then home walk the roster to its ends", func(t *testing.T) {
		s := newWiredShell(t, 60, 60, 100, 30)
		settleLayout(s)
		last := s.model.RosterLen - 1
		if last <= 0 {
			t.Fatalf("setup: RosterLen = %d", s.model.RosterLen)
		}

		s.Update(key(tea.KeyEnd))
		if s.model.RosterCursor != last {
			t.Errorf("RosterCursor = %d after End, want the last row %d", s.model.RosterCursor, last)
		}
		s.Update(key(tea.KeyHome))
		if s.model.RosterCursor != 0 {
			t.Errorf("RosterCursor = %d after Home, want 0", s.model.RosterCursor)
		}
	})

	t.Run("G is End through the real path", func(t *testing.T) {
		s := newWiredShell(t, 60, 60, 100, 30)
		settleLayout(s)
		last := s.model.RosterLen - 1
		s.Update(runeKey('G'))
		if s.model.RosterCursor != last {
			t.Errorf("RosterCursor = %d after G, want %d", s.model.RosterCursor, last)
		}
	})

	t.Run("the message pane pages once it has focus", func(t *testing.T) {
		s := newWiredShell(t, 60, 60, 100, 30)
		settleLayout(s)
		s.Update(key(tea.KeyTab))
		if s.model.Focus != tui.PaneMessages {
			t.Fatalf("setup: Focus = %v after one tab, want PaneMessages", s.model.Focus)
		}
		settleLayout(s)
		vp := s.model.MessagesViewport
		if vp < 3 {
			t.Fatalf("setup: messages viewport = %d, want a pageable pane", vp)
		}
		s.Update(key(tea.KeyPgDown))
		if want := vp - 1; s.model.MessagesCursor != want {
			t.Errorf("MessagesCursor = %d after PgDn with viewport %d, want %d", s.model.MessagesCursor, vp, want)
		}
		if s.model.RosterCursor != 0 {
			t.Errorf("PgDn on the message pane moved the roster to %d", s.model.RosterCursor)
		}
	})

	t.Run("home and end on a focused detail pane leave the message cursor alone", func(t *testing.T) {
		// Criterion 4 at the event level: the detail pane renders whatever
		// the message cursor selects, so End reaching that cursor would
		// change the message on screen while the reader is paging its body.
		s := newDetailShell(t, 6, 60, 100, 40)
		s.Update(key(tea.KeyTab)) // messages
		s.Update(key(tea.KeyPgDown))
		settleLayout(s)
		selected := s.model.MessagesCursor
		if selected == 0 {
			t.Fatalf("setup: MessagesCursor still 0 after PgDn on the message pane")
		}
		s.Update(key(tea.KeyTab)) // messages -> detail
		if s.model.Focus != tui.PaneDetail {
			t.Fatalf("setup: Focus = %v after a second tab, want PaneDetail", s.model.Focus)
		}
		settleLayout(s)

		headerBefore, _ := detailPaneLines(t, s)
		for _, k := range []tea.KeyMsg{key(tea.KeyEnd), key(tea.KeyHome), key(tea.KeyPgDown), runeKey('G')} {
			s.Update(k)
			if s.model.MessagesCursor != selected {
				t.Fatalf("key %v on the detail pane moved MessagesCursor %d -> %d", k, selected, s.model.MessagesCursor)
			}
		}
		if header, _ := detailPaneLines(t, s); header != headerBefore {
			t.Errorf("the detail header changed under the reader: %q -> %q", headerBefore, header)
		}
	})

	t.Run("end reaches the bottom of a focused detail body", func(t *testing.T) {
		s := newDetailShell(t, 3, 120, 100, 40)
		focusDetail(t, s)
		settleLayout(s)
		if s.model.DetailLen <= s.model.DetailViewport {
			t.Fatalf("setup: body %d lines in a %d-row window, want a scrollable body",
				s.model.DetailLen, s.model.DetailViewport)
		}
		s.Update(key(tea.KeyEnd))
		if want := s.model.DetailLen - s.model.DetailViewport; s.model.DetailScroll != want {
			t.Errorf("DetailScroll = %d after End, want the last full page %d", s.model.DetailScroll, want)
		}
		s.Update(key(tea.KeyHome))
		if s.model.DetailScroll != 0 {
			t.Errorf("DetailScroll = %d after Home, want 0", s.model.DetailScroll)
		}
	})

	t.Run("paging keys are swallowed by an open filter draft", func(t *testing.T) {
		s := newWiredShell(t, 60, 60, 100, 30)
		settleLayout(s)
		s.Update(runeKey('/'))
		before := s.model.RosterCursor
		for _, k := range []tea.KeyMsg{key(tea.KeyEnd), key(tea.KeyPgDown), key(tea.KeyHome), key(tea.KeyPgUp), runeKey('G')} {
			s.Update(k)
			if s.model.RosterCursor != before {
				t.Fatalf("key %v moved RosterCursor %d -> %d while a draft was open", k, before, s.model.RosterCursor)
			}
		}
		s.Update(key(tea.KeyEnter))
		if s.model.Filter.Query != "G" {
			t.Errorf("committed query = %q, want %q — only the rune belongs to the draft", s.model.Filter.Query, "G")
		}
	})
}

// ---------------------------------------------------------------------------
// sp033 T6: conditional head-follow, through the real shell (inverts sp032
// T6's tail-follow wiring tests to the other end — see keys_test.go for the
// state-layer restatement of the underlying invariants).
//
// tui's own tests own the derivation (what LIVE means, what the count does).
// These own the WIRING: that a real second sample from a real sampler
// reaches the model, that the count reaches render.RenderLog's header, and
// that a real mouse press on row 0 thaws the pane. A pending count that
// stayed inside tui.Model and never reached a header would leave every tui
// test green.
// ---------------------------------------------------------------------------

// messageHeaderLine is the message pane's header row in a rendered frame.
func messageHeaderLine(t *testing.T, s *shell) string {
	t.Helper()
	lines, layout := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
	if layout.messages.headerRows == 0 {
		t.Fatalf("the message pane rendered no header: %v", lines)
	}
	return lines[layout.messages.firstRow]
}

// headShell stands up a wired shell parked LIVE on the message pane (row 0,
// scroll at the top), and returns a grow function that publishes a larger
// sample through the real sampler.
func headShell(t *testing.T, msgRows, width, height int) (*shell, func(int)) {
	t.Helper()
	dir := t.TempDir()
	s := newWiredShellIn(t, dir, 5, msgRows, width, height)
	settleLayout(s) // this frame's viewports reach the model

	s.Update(key(tea.KeyTab)) // focus the message pane
	s.Update(runeKey('g'))    // and park it live at the head
	if s.model.MessagesCursor != 0 || s.model.MessagesScroll != 0 {
		t.Fatalf("setup: cursor/scroll = %d/%d, want 0/0 (row 0)", s.model.MessagesCursor, s.model.MessagesScroll)
	}

	return s, func(n int) {
		t.Helper()
		writeMessageStub(t, dir, n)
		if !s.msgs.Tick(s.ctx) {
			t.Fatalf("the messages sampler did not deliver a new sample of %d", n)
		}
		settleLayout(s) // the sample reaches the model the way a frame does
	}
}

// TestOrder_ShellFollowsLiveAndFreezesScrolledBack is criteria 1 and 2 end to
// end: a real growing sample leaves a live pane on row 0 (which IS
// following, since row 0 never moves), and moves NOTHING once a real wheel
// event has scrolled it away.
func TestOrder_ShellFollowsLiveAndFreezesScrolledBack(t *testing.T) {
	s, grow := headShell(t, 20, 100, 30)

	grow(24)
	if s.model.MessagesCursor != 0 {
		t.Errorf("a live pane did not stay on row 0: cursor = %d, want 0", s.model.MessagesCursor)
	}
	if s.model.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d on a live pane, want 0", s.model.PendingMessages)
	}

	// A real wheel event over the message pane freezes it. WheelDown, since
	// row 0 (live) now sits at the TOP of the pane.
	layout := settleLayout(s)
	y := layout.messages.firstRow + layout.messages.headerRows + 1
	if target, _, _ := hitTest(layout, y); target != hitMessages {
		t.Fatalf("test setup: hitTest(y=%d) = %v, want hitMessages", y, target)
	}
	s.Update(tea.MouseMsg{X: 5, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonWheelDown})

	frozenCursor, frozenScroll := s.model.MessagesCursor, s.model.MessagesScroll
	grow(27)
	grow(30)
	if s.model.MessagesCursor != frozenCursor || s.model.MessagesScroll != frozenScroll {
		t.Errorf("a frozen pane moved: cursor/scroll = %d/%d, want %d/%d",
			s.model.MessagesCursor, s.model.MessagesScroll, frozenCursor, frozenScroll)
	}
	if s.model.PendingMessages != 6 {
		t.Errorf("PendingMessages = %d, want 6", s.model.PendingMessages)
	}
}

// TestOrder_PendingCountReachesTheLogHeader is criterion 3's wiring: the
// count main.go holds is the one RenderLog renders. Asserted on the frame
// the shell actually draws, so a main.go that never passed it fails here
// even with every render and tui test green.
func TestOrder_PendingCountReachesTheLogHeader(t *testing.T) {
	s, grow := headShell(t, 20, 100, 30)

	if h := messageHeaderLine(t, s); strings.Contains(h, "new") {
		t.Fatalf("a live pane advertised pending messages: %q", h)
	}

	layout := settleLayout(s)
	y := layout.messages.firstRow + layout.messages.headerRows + 1
	s.Update(tea.MouseMsg{X: 5, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonWheelDown})
	grow(25)

	if s.model.PendingMessages != 5 {
		t.Fatalf("setup: PendingMessages = %d, want 5", s.model.PendingMessages)
	}
	if h := messageHeaderLine(t, s); !strings.Contains(h, "+5 new") {
		t.Errorf("the log header does not carry the pending count: %q", h)
	}
}

// TestOrder_ClickOnRowZeroThroughShellUpdateZeroesCount is criterion 4's
// mouse half, driven as a real tea.MouseMsg so the hit test, the dispatch
// and the model entry point are all under test.
//
// It moves the CURSOR (not the scroll) away from row 0 first: unlike the
// tail, row 0 never moves as the list grows, so a pane frozen only by
// scroll would become live again from a wheel alone, proving nothing about
// the click. Moving the cursor is what makes the click's re-selection of
// row 0 the thing under test.
func TestOrder_ClickOnRowZeroThroughShellUpdateZeroesCount(t *testing.T) {
	s, grow := headShell(t, 20, 100, 30)

	s.Update(key(tea.KeyDown)) // cursor to row 1: not live
	grow(25)
	if s.model.PendingMessages != 5 {
		t.Fatalf("setup: PendingMessages = %d, want 5", s.model.PendingMessages)
	}

	// The pane's first data row is row 0 of the list (scroll never moved).
	layout := settleLayout(s)
	first := layout.messages.firstRow + layout.messages.headerRows
	if target, isData, _ := hitTest(layout, first); target != hitMessages || !isData {
		t.Fatalf("test setup: hitTest(y=%d) = (%v, isData=%v), want (hitMessages, true)", first, target, isData)
	}
	s.Update(tea.MouseMsg{X: 5, Y: first, Action: tea.MouseActionPress, Button: tea.MouseButtonLeft})

	if s.model.MessagesCursor != 0 {
		t.Fatalf("the click did not land on row 0: cursor = %d, want 0", s.model.MessagesCursor)
	}
	if s.model.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d after a click on row 0, want 0", s.model.PendingMessages)
	}
	if h := messageHeaderLine(t, s); strings.Contains(h, "new") {
		t.Errorf("the header still advertises pending messages: %q", h)
	}
}

// TestOrder_ZoomedDetailStillFollowsAndCounts is the "messages arriving
// while the detail pane is zoomed" edge case. renderFrame returns EARLY
// while zoomed, before it re-reports the message pane's viewport — so the
// head-follow logic must keep working off the viewport the last three-pane
// frame left behind rather than silently entering the windowless regime.
func TestOrder_ZoomedDetailStillFollowsAndCounts(t *testing.T) {
	s, grow := headShell(t, 20, 100, 30)
	s.Update(key(tea.KeyEnter)) // zoom the detail pane
	if !s.model.DetailZoom {
		t.Fatalf("test setup: the detail pane did not zoom")
	}

	grow(23)
	if s.model.MessagesCursor != 0 {
		t.Errorf("a live pane stopped following while zoomed: cursor = %d, want 0", s.model.MessagesCursor)
	}

	// Now freeze the log (a real wheel event, which needs the three-pane
	// layout to have a message region to point at) and zoom again: the
	// count must keep accruing behind the zoomed pane.
	s.Update(key(tea.KeyEsc))
	layout := settleLayout(s)
	y := layout.messages.firstRow + layout.messages.headerRows + 1
	s.Update(tea.MouseMsg{X: 5, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonWheelDown})
	s.Update(key(tea.KeyEnter))
	if !s.model.DetailZoom {
		t.Fatalf("test setup: the detail pane did not re-zoom")
	}

	frozenCursor, frozenScroll := s.model.MessagesCursor, s.model.MessagesScroll
	grow(26)
	if s.model.MessagesCursor != frozenCursor || s.model.MessagesScroll != frozenScroll {
		t.Errorf("a frozen pane moved behind the zoom: cursor/scroll = %d/%d, want %d/%d",
			s.model.MessagesCursor, s.model.MessagesScroll, frozenCursor, frozenScroll)
	}
	if s.model.PendingMessages != 3 {
		t.Errorf("PendingMessages = %d while zoomed, want 3", s.model.PendingMessages)
	}
}

// TestTail_OncePathNeverCountsOrFollows is the --once contract: that path
// renders at height 0 and never reports a viewport, so the frame a pipe
// receives must contain every message (not just the newest) and no `+N new`
// segment — whatever the bus did between samples.
func TestTail_OncePathNeverCountsOrFollows(t *testing.T) {
	dir := t.TempDir()
	s := newWiredShellIn(t, dir, 5, 20, 100, 0)

	for _, n := range []int{20, 25, 30} {
		writeMessageStub(t, dir, n)
		if !s.msgs.Tick(s.ctx) {
			t.Fatalf("the messages sampler did not deliver a sample of %d", n)
		}
		lines, _ := renderFrame(s.model, s.census.Last(), s.census.Stale(),
			s.msgs.Last(), s.msgs.Stale(), s.now(), s.width, 0)

		if s.model.PendingMessages != 0 {
			t.Fatalf("n=%d: --once counted %d pending messages", n, s.model.PendingMessages)
		}
		joined := strings.Join(lines, "\n")
		if strings.Contains(joined, " new") {
			t.Fatalf("n=%d: --once emitted a pending segment:\n%s", n, joined)
		}
		if !strings.Contains(joined, "message 00") {
			t.Fatalf("n=%d: --once lost the oldest message — the tail followed a pane with no window:\n%s", n, joined)
		}
	}
}

// ---------------------------------------------------------------------------
// sp032 T8 (moved from the tail to the head by sp033 T6): the message pane
// opens live, through the real shell.
//
// tui's own tests own what the opening DOES; these own that an interactive
// session performs it — on the first frame, without the operator pressing
// anything. Every test below sends no key at all, so none of them can pass
// because some keystroke happened to reach GoToFirst.
// ---------------------------------------------------------------------------

// firstFrame renders the frame a session actually opens with — s.View(), the
// method bubbletea calls — and hands back its lines and layout. The two are
// cross-checked against View's own string, so an assertion made on the
// decomposed frame is an assertion about the bytes the operator sees.
func firstFrame(t *testing.T, s *shell) ([]string, frameLayout) {
	t.Helper()
	view := s.View()
	lines, layout := renderFrame(s.model, s.census.Last(), s.census.Stale(),
		s.msgs.Last(), s.msgs.Stale(), s.now(), s.width, s.height)
	if got := strings.Join(lines, "\n"); got != view {
		t.Fatalf("the decomposed frame is not the one View returned:\n got %q\nwant %q", got, view)
	}
	return lines, layout
}

// TestStartup_MessagePaneOpensLiveAtTheHead is criterion 1 end to end: a
// wired shell over a real sampler, sized by a real WindowSizeMsg, opens with
// the cursor on the NEWEST message (row 0) and the scroll at the top — and
// the frame it returns shows that message first, not the oldest one.
func TestStartup_MessagePaneOpensLiveAtTheHead(t *testing.T) {
	s := newWiredShellIn(t, t.TempDir(), 5, 20, 100, 30)

	lines, layout := firstFrame(t, s)

	if s.model.MessagesLen != 20 {
		t.Fatalf("setup: MessagesLen = %d, want 20", s.model.MessagesLen)
	}
	if layout.messages.dataRows >= 20 {
		t.Fatalf("setup: the message pane shows %d of 20 rows — this test needs a pane that cannot show them all", layout.messages.dataRows)
	}
	if s.model.MessagesCursor != 0 {
		t.Errorf("MessagesCursor = %d, want 0 (the newest message) with no key ever pressed", s.model.MessagesCursor)
	}
	if s.model.MessagesScroll != 0 {
		t.Errorf("MessagesScroll = %d, want 0 (the top)", s.model.MessagesScroll)
	}

	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "message 19") {
		t.Errorf("the newest message is not on the first frame:\n%s", joined)
	}
	if strings.Contains(joined, "message 00") {
		t.Errorf("the first frame already reaches the oldest message:\n%s", joined)
	}

	// The selection mark is on the pane's FIRST data row, which is what
	// makes this the head rather than merely a scrolled pane.
	first := layout.messages.firstRow + layout.messages.headerRows
	if !strings.Contains(lines[first], styleOn) {
		t.Errorf("the first data row is not marked as the selection: %q", lines[first])
	}
	if !strings.Contains(lines[first], "message 19") {
		t.Errorf("the marked row is not the newest message: %q", lines[first])
	}
}

// TestStartup_PendingCountIsZeroOnTheFirstFrame is criterion 2, and it is
// dotfiles-utob's visible symptom: a freshly opened monitor accrued `+N new`
// from its first frame onward, because the pane it opened was never live. So
// the assertion is made twice — on the opening frame, and again once the bus
// has actually grown under it, which is the sample that used to produce the
// count.
func TestStartup_PendingCountIsZeroOnTheFirstFrame(t *testing.T) {
	dir := t.TempDir()
	s := newWiredShellIn(t, dir, 5, 20, 100, 30)

	firstFrame(t, s)

	if s.model.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d on the first frame, want 0", s.model.PendingMessages)
	}
	if h := messageHeaderLine(t, s); strings.Contains(h, "new") {
		t.Errorf("a freshly opened monitor advertises pending messages: %q", h)
	}

	writeMessageStub(t, dir, 25)
	if !s.msgs.Tick(s.ctx) {
		t.Fatalf("the messages sampler did not deliver a sample of 25")
	}
	firstFrame(t, s)

	if s.model.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d after the bus grew under an untouched session, want 0 — the pane opened live and follows", s.model.PendingMessages)
	}
	if h := messageHeaderLine(t, s); strings.Contains(h, "new") {
		t.Errorf("the log header advertises pending messages nobody scrolled away from: %q", h)
	}
	if s.model.MessagesCursor != 0 {
		t.Errorf("MessagesCursor = %d, want 0 (row 0 stays the newest of the grown sample)", s.model.MessagesCursor)
	}
}

// TestStartup_RosterOpensAtTheFirstRow is criterion 5. The asymmetry is
// deliberate: a census has no newest row to be live on, so the roster opens
// on row one exactly as it always did.
func TestStartup_RosterOpensAtTheFirstRow(t *testing.T) {
	s := newWiredShellIn(t, t.TempDir(), 40, 20, 100, 30)

	lines, layout := firstFrame(t, s)

	if layout.roster.dataRows >= 40 {
		t.Fatalf("setup: the roster shows %d of 40 rows — this test needs a pane that cannot show them all", layout.roster.dataRows)
	}
	if s.model.RosterCursor != 0 || s.model.RosterScroll != 0 {
		t.Errorf("the roster opened at %d/%d (cursor/scroll), want 0/0", s.model.RosterCursor, s.model.RosterScroll)
	}
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "agent00") {
		t.Errorf("the first roster row is not on the first frame:\n%s", joined)
	}
	if strings.Contains(joined, "agent39") {
		t.Errorf("the roster opened at its tail:\n%s", joined)
	}
}

// TestStartup_EmptyAndSingleMessageLogs drives the two degenerate first
// samples through the real sampler, and then GROWS the bus: for these two
// lengths the head IS index 0 (as it always is), so the following sample is
// what tells an opened, following pane from one merely parked there.
func TestStartup_EmptyAndSingleMessageLogs(t *testing.T) {
	for _, n := range []int{0, 1} {
		t.Run(fmt.Sprintf("%d messages", n), func(t *testing.T) {
			dir := t.TempDir()
			s := newWiredShellIn(t, dir, 5, n, 100, 30)

			firstFrame(t, s)

			if s.model.MessagesLen != n {
				t.Fatalf("setup: MessagesLen = %d, want %d", s.model.MessagesLen, n)
			}
			if s.model.MessagesCursor != 0 || s.model.MessagesScroll != 0 {
				t.Errorf("cursor/scroll = %d/%d, want 0/0", s.model.MessagesCursor, s.model.MessagesScroll)
			}
			if s.model.PendingMessages != 0 {
				t.Errorf("PendingMessages = %d, want 0", s.model.PendingMessages)
			}

			writeMessageStub(t, dir, n+12)
			if !s.msgs.Tick(s.ctx) {
				t.Fatalf("the messages sampler did not deliver a sample of %d", n+12)
			}
			firstFrame(t, s)

			if s.model.MessagesCursor != 0 {
				t.Errorf("the opened pane did not follow the next sample: cursor = %d, want 0", s.model.MessagesCursor)
			}
			if s.model.PendingMessages != 0 {
				t.Errorf("PendingMessages = %d after following, want 0", s.model.PendingMessages)
			}
		})
	}
}

// TestStartup_FirstSampleAfterTheFirstWindowSize is the other message
// ordering: the window arrives before any sample exists. The pane then opens
// EMPTY, and an empty pane is live, so the first real sample is followed
// rather than counted as `+N` the operator has already missed.
func TestStartup_FirstSampleAfterTheFirstWindowSize(t *testing.T) {
	dir := t.TempDir()
	writeStub(t, dir, "agent-census", "#!/bin/sh\necho '[]'\n")
	writeMessageStub(t, dir, 20)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	ctx := context.Background()
	census := source.NewMonitor(source.NewSampler(filepath.Join(dir, "stamp")))
	msgs := source.NewMessagesMonitor(source.NewMessagesSampler())

	s := newShell(ctx, tui.NewModel(), census, msgs)
	s.now = func() time.Time { return time.Date(2026, 9, 17, 10, 0, 5, 0, time.UTC) }
	s.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	firstFrame(t, s) // a frame with no sample at all yet

	census.Refresh(ctx)
	if !msgs.Tick(ctx) {
		t.Fatalf("the messages sampler did not deliver its first sample")
	}
	lines, _ := firstFrame(t, s)

	if s.model.MessagesCursor != 0 {
		t.Errorf("MessagesCursor = %d, want 0 — the first sample must arrive followed", s.model.MessagesCursor)
	}
	if s.model.PendingMessages != 0 {
		t.Errorf("PendingMessages = %d, want 0 on the frame the first sample arrives in", s.model.PendingMessages)
	}
	if joined := strings.Join(lines, "\n"); !strings.Contains(joined, "message 19") {
		t.Errorf("the newest message is not on screen:\n%s", joined)
	}
}

// TestStartup_ProjectFilterEmptiesTheRosterButNotTheLog is the --project
// edge case: the flag composes onto the ROSTER only (sp031 T3), so a value
// matching no agent must still leave the message pane opening at its head.
func TestStartup_ProjectFilterEmptiesTheRosterButNotTheLog(t *testing.T) {
	s := newWiredShellIn(t, t.TempDir(), 5, 20, 100, 30)
	s.model.Project = "no-such-project" // main.go sets this once, before the program runs

	lines, _ := firstFrame(t, s)

	if s.model.RosterLen != 0 {
		t.Fatalf("setup: RosterLen = %d, want 0 for an unmatched --project", s.model.RosterLen)
	}
	if s.model.MessagesCursor != 0 {
		t.Errorf("MessagesCursor = %d, want 0 — an empty roster must not hold the log shut", s.model.MessagesCursor)
	}
	if s.model.MessagesScroll != 0 {
		t.Errorf("MessagesScroll = %d, want 0", s.model.MessagesScroll)
	}
	if joined := strings.Join(lines, "\n"); !strings.Contains(joined, "message 19") {
		t.Errorf("the newest message is not on screen:\n%s", joined)
	}
}

// TestStartup_LaterFramesDoNotReOpenTheHead is the other half of "opens":
// the opening happens ONCE. Every subsequent frame — and a session draws one
// per event — must leave a reader who scrolled back exactly where they are,
// pending count included.
func TestStartup_LaterFramesDoNotReOpenTheHead(t *testing.T) {
	dir := t.TempDir()
	s := newWiredShellIn(t, dir, 5, 20, 100, 30)
	firstFrame(t, s)

	// A real wheel event over the message pane scrolls it away from the head.
	_, layout := firstFrame(t, s)
	y := layout.messages.firstRow + layout.messages.headerRows + 1
	if target, _, _ := hitTest(layout, y); target != hitMessages {
		t.Fatalf("test setup: hitTest(y=%d) = %v, want hitMessages", y, target)
	}
	s.Update(tea.MouseMsg{X: 5, Y: y, Action: tea.MouseActionPress, Button: tea.MouseButtonWheelDown})

	writeMessageStub(t, dir, 26)
	if !s.msgs.Tick(s.ctx) {
		t.Fatalf("the messages sampler did not deliver a sample of 26")
	}
	firstFrame(t, s)

	wantCursor, wantScroll, wantPending := s.model.MessagesCursor, s.model.MessagesScroll, s.model.PendingMessages
	if wantPending != 6 {
		t.Fatalf("setup: PendingMessages = %d, want 6", wantPending)
	}

	for i := 1; i <= 3; i++ {
		firstFrame(t, s)
		if s.model.MessagesCursor != wantCursor || s.model.MessagesScroll != wantScroll {
			t.Fatalf("frame %d re-opened the pane: cursor/scroll = %d/%d, want %d/%d",
				i, s.model.MessagesCursor, s.model.MessagesScroll, wantCursor, wantScroll)
		}
		if s.model.PendingMessages != wantPending {
			t.Fatalf("frame %d cleared the pending count: %d, want %d", i, s.model.PendingMessages, wantPending)
		}
	}

	// A resize is not a second opening either.
	s.Update(tea.WindowSizeMsg{Width: 100, Height: 34})
	firstFrame(t, s)
	if s.model.MessagesCursor != wantCursor {
		t.Errorf("a resize re-opened the pane: cursor = %d, want %d", s.model.MessagesCursor, wantCursor)
	}
	if s.model.PendingMessages != wantPending {
		t.Errorf("a resize cleared the pending count: %d, want %d", s.model.PendingMessages, wantPending)
	}
}

// TestStartup_TooShortForADataRowOpensOnTheNextResize is the short-terminal
// edge case: a message pane with no room for a data row is in the same
// windowless regime --once renders in, so the opening WAITS rather than
// being spent on a pane that cannot show its result. The one-row window is
// the other half — the smallest pane that can be opened at all.
func TestStartup_TooShortForADataRowOpensOnTheNextResize(t *testing.T) {
	s := newWiredShellIn(t, t.TempDir(), 5, 20, 100, 5)

	firstFrame(t, s)
	if s.model.MessagesViewport != 0 {
		t.Fatalf("setup: a 5-row terminal gave the message pane %d data rows, want 0", s.model.MessagesViewport)
	}
	if s.model.MessagesCursor != 0 || s.model.MessagesScroll != 0 {
		t.Errorf("a pane with no data row was opened anyway: cursor/scroll = %d/%d, want 0/0",
			s.model.MessagesCursor, s.model.MessagesScroll)
	}

	// One row: the newest message, alone on screen.
	s.Update(tea.WindowSizeMsg{Width: 100, Height: 6})
	lines, layout := firstFrame(t, s)
	if s.model.MessagesViewport != 1 {
		t.Fatalf("setup: a 6-row terminal gave the message pane %d data rows, want 1", s.model.MessagesViewport)
	}
	if s.model.MessagesCursor != 0 || s.model.MessagesScroll != 0 {
		t.Errorf("cursor/scroll = %d/%d in a 1-row window, want 0/0", s.model.MessagesCursor, s.model.MessagesScroll)
	}
	row := lines[layout.messages.firstRow+layout.messages.headerRows]
	if !strings.Contains(row, "message 19") {
		t.Errorf("the single visible row is not the newest message: %q", row)
	}

	s.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	_, _ = firstFrame(t, s)
	if s.model.MessagesCursor != 0 {
		t.Errorf("MessagesCursor = %d, want 0 once the terminal had room to show it", s.model.MessagesCursor)
	}
	if s.model.MessagesScroll != 0 {
		t.Errorf("MessagesScroll = %d, want 0", s.model.MessagesScroll)
	}
}

// TestRunOnce_StillRendersNewestFirst is criterion 1's regression anchor for
// the --once path: it reports no viewport and is never opened, but it still
// goes through the same reorder (cmd/agent-monitor's orderedMessages) as the
// interactive path, so the WHOLE log renders newest-first there too — sp033
// T6 criterion 1 names both paths explicitly. A fix that special-cased
// --once back to the old order would pass every other test and fail only
// here.
func TestRunOnce_StillRendersNewestFirst(t *testing.T) {
	dir := t.TempDir()
	writeStub(t, dir, "agent-census", "#!/bin/sh\necho '[]'\n")
	writeMessageStub(t, dir, 40)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var buf bytes.Buffer
	if err := runOnce(&buf, ""); err != nil {
		t.Fatalf("runOnce: %v", err)
	}
	out := buf.String()

	oldest := strings.Index(out, "message 00")
	newest := strings.Index(out, "message 39")
	if oldest < 0 {
		t.Fatalf("--once lost the oldest message:\n%s", out)
	}
	if newest < 0 {
		t.Fatalf("--once lost the newest message:\n%s", out)
	}
	if newest > oldest {
		t.Errorf("--once rendered the oldest message before the newest: %d > %d", newest, oldest)
	}
	for i := 0; i < 40; i++ {
		if want := fmt.Sprintf("message %02d", i); !strings.Contains(out, want) {
			t.Fatalf("--once dropped %q — a windowless pane must still emit every message:\n%s", want, out)
		}
	}
	if strings.Contains(out, " new") {
		t.Errorf("--once emitted a pending segment:\n%s", out)
	}
	if strings.ContainsRune(out, 0x1b) {
		t.Errorf("--once emitted an ESC byte: %q", out)
	}
}
