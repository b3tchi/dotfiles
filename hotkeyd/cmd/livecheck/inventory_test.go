package main

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// The inventory in doc.go is this task's deliverable, and an inventory that
// can silently fall out of date with its subject is worth nothing. These
// tests re-derive the figures from live_check.py itself on every run, so a
// new python assertion, a deleted one, or a renumbered file breaks the build
// instead of quietly leaving a hole.

const pythonLiveCheck = "../../live_check.py"

// pyAssertionLines re-derives the python assertion call sites from source:
// every indented `check(` or `judged(` call, minus the two calls INSIDE the
// judged() helper's own body (which are its implementation, not assertions).
func pyAssertionLines(t *testing.T) []int {
	t.Helper()
	src, err := os.ReadFile(pythonLiveCheck)
	if err != nil {
		t.Fatalf("cannot read %s -- the inventory is about this file, so a missing "+
			"source is a hard failure, not a skip: %v", pythonLiveCheck, err)
	}
	lines := strings.Split(string(src), "\n")

	// Locate judged()'s body so its internal check() calls are excluded
	// structurally rather than by hardcoded line number.
	defStart, defEnd := -1, -1
	for i, l := range lines {
		if strings.HasPrefix(l, "def judged(") {
			defStart = i + 1
			continue
		}
		if defStart > 0 && defEnd < 0 && l != "" && !strings.HasPrefix(l, " ") && !strings.HasPrefix(l, "\t") {
			defEnd = i + 1
		}
	}
	if defStart < 0 || defEnd < 0 {
		t.Fatalf("could not locate judged()'s body in %s (start=%d end=%d)", pythonLiveCheck, defStart, defEnd)
	}

	call := regexp.MustCompile(`^\s+(check|judged)\(`)
	var out []int
	for i, l := range lines {
		n := i + 1
		if n >= defStart && n < defEnd {
			continue
		}
		if call.MatchString(l) {
			out = append(out, n)
		}
	}
	return out
}

var inventoryEntry = regexp.MustCompile(`^//\tpy:(\d+)\t(GO|PYTHON-ONLY)\t(.+)$`)

type invEntry struct {
	line   int
	kind   string
	reason string
}

func readInventory(t *testing.T) []invEntry {
	t.Helper()
	src, err := os.ReadFile("doc.go")
	if err != nil {
		t.Fatalf("reading doc.go: %v", err)
	}
	var out []invEntry
	for _, l := range strings.Split(string(src), "\n") {
		m := inventoryEntry.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		n, _ := strconv.Atoi(m[1])
		out = append(out, invEntry{line: n, kind: m[2], reason: strings.TrimSpace(m[3])})
	}
	return out
}

// THE CORE GUARANTEE: every assertion in live_check.py is inventoried, and
// nothing is inventoried that is not an assertion.
func TestInventory_AccountsForEveryPythonAssertionExactlyOnce(t *testing.T) {
	want := pyAssertionLines(t)
	inv := readInventory(t)

	seen := map[int]int{}
	for _, e := range inv {
		seen[e.line]++
	}

	var missing, dup []int
	for _, n := range want {
		switch seen[n] {
		case 0:
			missing = append(missing, n)
		case 1:
		default:
			dup = append(dup, n)
		}
	}
	wantSet := map[int]bool{}
	for _, n := range want {
		wantSet[n] = true
	}
	var invented []int
	for _, e := range inv {
		if !wantSet[e.line] {
			invented = append(invented, e.line)
		}
	}
	sort.Ints(missing)
	sort.Ints(dup)
	sort.Ints(invented)

	if len(missing) > 0 {
		t.Errorf("live_check.py assertions with NO inventory entry (a silent drop is a rejection): %v", missing)
	}
	if len(dup) > 0 {
		t.Errorf("inventory lists these python lines more than once: %v", dup)
	}
	if len(invented) > 0 {
		t.Errorf("inventory names python lines that are not assertion call sites: %v", invented)
	}
	if len(inv) != len(want) {
		t.Errorf("inventory has %d entries for %d assertion sites", len(inv), len(want))
	}
}

// A python-only entry without a stated reason is exactly the silent drop the
// success criterion forbids, dressed up as a table row.
func TestInventory_EveryPythonOnlyEntryStatesAReason(t *testing.T) {
	for _, e := range readInventory(t) {
		if e.kind != "PYTHON-ONLY" {
			continue
		}
		if len(e.reason) < 60 {
			t.Errorf("py:%d is marked PYTHON-ONLY with a %d-character reason (%q); state WHY it cannot be re-expressed",
				e.line, len(e.reason), e.reason)
		}
	}
}

func TestInventory_EveryGoEntryNamesWhatItChecks(t *testing.T) {
	for _, e := range readInventory(t) {
		if e.kind == "GO" && len(e.reason) < 15 {
			t.Errorf("py:%d is marked GO with nothing useful said about it: %q", e.line, e.reason)
		}
	}
}

// The figures quoted in the package doc are re-derived here, so a stale
// number in prose fails the build. sp021's numeric literals have been
// unreliable more than once; these are measured, not remembered.
func TestInventory_DocFiguresMatchTheSource(t *testing.T) {
	src, err := os.ReadFile(pythonLiveCheck)
	if err != nil {
		t.Fatalf("reading %s: %v", pythonLiveCheck, err)
	}
	// A trailing newline makes the final Split element empty; the file's
	// line count is what `wc -l` reports.
	lineCount := strings.Count(string(src), "\n")
	sites := len(pyAssertionLines(t))

	doc, err := os.ReadFile("doc.go")
	if err != nil {
		t.Fatalf("reading doc.go: %v", err)
	}
	text := string(doc)
	for _, claim := range []string{
		fmt.Sprintf("%d lines", lineCount),
		fmt.Sprintf("%d assertion call sites", sites),
	} {
		if !strings.Contains(text, claim) {
			t.Errorf("the package doc does not state %q -- re-derive the figure rather than carrying one over", claim)
		}
	}

	inv := readInventory(t)
	var goCount, pyCount int
	for _, e := range inv {
		if e.kind == "GO" {
			goCount++
		} else {
			pyCount++
		}
	}
	for _, claim := range []string{
		fmt.Sprintf("%d re-expressed in Go", goCount),
		fmt.Sprintf("%d python-only", pyCount),
	} {
		if !strings.Contains(text, claim) {
			t.Errorf("the package doc does not state %q (counted from the table itself)", claim)
		}
	}
}

// Runtime line count: py:148 runs twice, py:700 and py:702 three times each,
// and exactly one arm of the py:900/902 pair executes. 87 sites therefore
// emit 91 lines, which is what a live python run actually printed for this
// task. Encoded so the arithmetic in the doc cannot rot.
func TestInventory_RuntimeLineCountArithmetic(t *testing.T) {
	sites := len(pyAssertionLines(t))
	runtime := sites + 1 /*py:148 loops over 2 lock keys*/ + 2 /*py:700 over 3 chords*/ + 2 /*py:702 over 3 chords*/ - 1 /*only one arm of py:900/902 runs*/
	if runtime != 91 {
		t.Errorf("runtime line count derives to %d from %d sites; the doc says 91 -- re-measure against a live python run", runtime, sites)
	}
	doc, err := os.ReadFile("doc.go")
	if err != nil {
		t.Fatalf("reading doc.go: %v", err)
	}
	if !strings.Contains(string(doc), fmt.Sprintf("emits %d PASS/FAIL lines", runtime)) {
		t.Errorf("the package doc does not state the derived runtime line count (%d)", runtime)
	}
}
