package render

import (
	"strings"
	"testing"
	"time"

	"agent-monitor/internal/source"
)

func sampleRows() []source.Row {
	return []source.Row{
		{Project: "dotfiles", Runtime: "pi", Role: "peer", State: "waiting_human", Status: "idle", Bucket: "blocked", Name: "peer-3"},
		{Project: "dotfiles", Runtime: "pi", Role: "peer", State: "running", Status: "streaming", Bucket: "working", Name: "peer-2"},
		{Project: "copacks", Runtime: "claude", Role: "", State: "", Status: "idle", Bucket: "idle", Name: "dotfiles-ad"},
	}
}

func assertMaxLineWidth(t *testing.T, lines []string, width int) {
	t.Helper()
	for i, l := range lines {
		if n := len([]rune(l)); n > width {
			t.Fatalf("line %d exceeds width %d (got %d runes): %q", i, width, n, l)
		}
	}
}

func TestRender_GoldenAt80_AllColumnsPresent(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	now := at.Add(90 * time.Second) // -> "1m"
	sample := &source.Sample{Rows: sampleRows(), At: at}

	lines := Render(sample, false, now, 80)
	assertMaxLineWidth(t, lines, 80)

	if len(lines) != 2+len(sampleRows()) { // header + column header + one per row
		t.Fatalf("got %d lines, want %d: %v", len(lines), 2+len(sampleRows()), lines)
	}
	if lines[0] != "agents — updated 1m ago" {
		t.Fatalf("header line = %q", lines[0])
	}
	colHeader := lines[1]
	for _, want := range []string{"UID/NAME", "RUNTIME", "PROJECT", "ROLE", "STATE", "ACTIVITY", "AGE"} {
		if !strings.Contains(colHeader, want) {
			t.Errorf("column header %q missing %q", colHeader, want)
		}
	}
	// Declared left-to-right order.
	prevIdx := -1
	for _, want := range []string{"UID/NAME", "RUNTIME", "PROJECT", "ROLE", "STATE", "ACTIVITY", "AGE"} {
		idx := strings.Index(colHeader, want)
		if idx <= prevIdx {
			t.Fatalf("column %q out of order in header %q", want, colHeader)
		}
		prevIdx = idx
	}

	// Row content, including the sample-level age repeated per row. The pi
	// row's PROJECT ("dotfiles") and the claude row's PROJECT ("copacks")
	// prove both runtimes populate the column from the census row itself.
	blockedLine := lines[2]
	for _, want := range []string{"peer-3", "dotfiles", "pi", "peer", "waiting_human", "idle", "1m"} {
		if !strings.Contains(blockedLine, want) {
			t.Errorf("row line %q missing %q", blockedLine, want)
		}
	}
	claudeLine := lines[len(lines)-1]
	if !strings.Contains(claudeLine, "copacks") {
		t.Errorf("claude row line %q missing PROJECT value %q", claudeLine, "copacks")
	}
}

func TestRender_GoldenAt40_DropsColumnsInDeclaredOrder(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	now := at.Add(90 * time.Second)
	sample := &source.Sample{Rows: sampleRows(), At: at}

	lines := Render(sample, false, now, 40)
	assertMaxLineWidth(t, lines, 40)

	colHeader := lines[1]
	// Declared drop order is age, then activity, then state, then role (right
	// to left); at width 40 uid/name, project, runtime and role fit (see
	// fitColumns table test below for the exact boundary), so none of the
	// dropped headers may appear, and the kept ones must still be present.
	// PROJECT surviving here -- ahead of role/state/activity/age -- is the
	// drop-priority this column adds, not an accident of the width chosen.
	for _, dropped := range []string{"AGE", "ACTIVITY", "STATE"} {
		if strings.Contains(colHeader, dropped) {
			t.Errorf("column header %q at width 40 still contains dropped column %q", colHeader, dropped)
		}
	}
	for _, kept := range []string{"UID/NAME", "RUNTIME", "PROJECT", "ROLE"} {
		if !strings.Contains(colHeader, kept) {
			t.Errorf("column header %q at width 40 missing %q", colHeader, kept)
		}
	}

	// A dropped column's VALUE must also be absent from row lines, not just
	// its header -- otherwise a value could leak into a kept cell's padding.
	blockedLine := lines[2]
	if strings.Contains(blockedLine, "waiting_human") {
		t.Errorf("row line %q leaks dropped STATE value at width 40", blockedLine)
	}
}

func TestFitColumns_DropsFromTheRight(t *testing.T) {
	all := []column{colUIDName, colRuntime, colProject, colRole, colState, colActivity, colAge}
	if got := fitColumns(80); !colsEqual(got, all) {
		t.Fatalf("fitColumns(80) = %v, want all columns %v", got, all)
	}

	// Width 40 keeps exactly uid/name, runtime, project, role per the fixed
	// widths declared in columnWidth (14+1+7+1+8+1+7 = 39 <= 40; adding
	// state's 13 would make 53 > 40).
	want40 := []column{colUIDName, colRuntime, colProject, colRole}
	if got := fitColumns(40); !colsEqual(got, want40) {
		t.Fatalf("fitColumns(40) = %v, want %v", got, want40)
	}

	// A terminal too narrow for even one full column still keeps exactly
	// one column (uid/name) rather than emptying the row.
	got := fitColumns(1)
	if len(got) != 1 || got[0] != colUIDName {
		t.Fatalf("fitColumns(1) = %v, want [colUIDName] alone", got)
	}
}

// TestFitColumns_ProjectOutranksRoleStateActivityAge pins PROJECT's
// drop-priority directly against fitColumns, independent of the width-40
// golden render above: at a width that fits uid/name, runtime and project
// but not role (31 = 14+1+7+1+8), PROJECT must still be present and ROLE,
// STATE, ACTIVITY and AGE must all be gone. That is the "more identifying
// than ROLE or AGE" ordering the success criteria calls for, pinned as its
// own assertion so a future column reorder cannot pass by accident.
func TestFitColumns_ProjectOutranksRoleStateActivityAge(t *testing.T) {
	want := []column{colUIDName, colRuntime, colProject}
	got := fitColumns(31)
	if !colsEqual(got, want) {
		t.Fatalf("fitColumns(31) = %v, want %v (project kept, role/state/activity/age dropped)", got, want)
	}
}

// TestFitColumns_ProjectDropsBetweenRuntimeAndItsOwnWidth pins the OTHER
// half of the drop-priority claim: PROJECT itself gets dropped, and RUNTIME
// survives past it. Cumulative declared widths (with separators) are
// uid=14, +runtime=22, +project=31, +role=39, +state=53, +activity=63,
// +age=69. So width 25 sits in the 22-30 band: wide enough for uid+runtime
// (22) but not for uid+runtime+project (31), which is exactly the boundary
// TestFitColumns_ProjectOutranksRoleStateActivityAge (at width 31, one past
// this band) does not exercise -- that test proves project survives past
// role/state/activity/age, not that project itself ever drops, nor that
// runtime outlasts it.
func TestFitColumns_ProjectDropsBetweenRuntimeAndItsOwnWidth(t *testing.T) {
	const width = 25
	want := []column{colUIDName, colRuntime}
	got := fitColumns(width)
	if !colsEqual(got, want) {
		t.Fatalf("fitColumns(%d) = %v, want %v (project dropped, runtime kept)", width, got, want)
	}

	at := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	now := at.Add(90 * time.Second)
	sample := &source.Sample{Rows: sampleRows(), At: at}
	lines := Render(sample, false, now, width)
	assertMaxLineWidth(t, lines, width)

	colHeader := lines[1]
	if strings.Contains(colHeader, "PROJECT") {
		t.Fatalf("column header %q at width %d still contains dropped column PROJECT", colHeader, width)
	}
	if !strings.Contains(colHeader, "RUNTIME") {
		t.Fatalf("column header %q at width %d missing kept column RUNTIME", colHeader, width)
	}

	// The dropped column's VALUE must also be absent from row lines, not
	// just its header -- checked via the claude row's project ("copacks"),
	// which (unlike "dotfiles") shares no substring with any kept column's
	// legitimate content: sampleRows' third row's own NAME is
	// "dotfiles-ad", so asserting "dotfiles" is absent would false-fail on
	// the kept UID/NAME cell rather than catching a real PROJECT leak.
	claudeLine := lines[len(lines)-1]
	if strings.Contains(claudeLine, "copacks") {
		t.Errorf("row line %q leaks dropped PROJECT value at width %d", claudeLine, width)
	}
}

func colsEqual(a, b []column) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestRender_NeverExceedsWidthEvenWhenNarrowerThanUIDColumn(t *testing.T) {
	at := time.Now()
	sample := &source.Sample{Rows: sampleRows(), At: at}
	lines := Render(sample, false, at, 5) // narrower than uid/name's own declared width (14)
	assertMaxLineWidth(t, lines, 5)
}

func TestRender_ZeroAgents_EmptyRosterNotAnError(t *testing.T) {
	at := time.Now()
	sample := &source.Sample{Rows: nil, At: at}
	lines := Render(sample, false, at, 80)

	found := false
	for _, l := range lines {
		if strings.Contains(l, "no agents") {
			found = true
		}
	}
	if !found {
		t.Fatalf("zero-agent render did not say so plainly: %v", lines)
	}
	// Header and column header are still present -- an empty roster is a
	// valid frame, not a blank/error screen.
	if len(lines) < 3 {
		t.Fatalf("zero-agent render missing header/column-header lines: %v", lines)
	}
}

func TestRender_StaleIndicatorDerivedFromSampleAge(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	now := at.Add(5 * time.Minute)
	sample := &source.Sample{Rows: nil, At: at}

	lines := Render(sample, true, now, 80)
	if !strings.Contains(lines[0], "STALE") {
		t.Fatalf("stale sample header does not say STALE: %q", lines[0])
	}
	if !strings.Contains(lines[0], "5m") {
		t.Fatalf("stale header does not carry the sample's own age: %q", lines[0])
	}
}

func TestRender_UnrecognisedBucketRendersVerbatim(t *testing.T) {
	at := time.Now()
	rows := []source.Row{
		{Project: "dotfiles", Runtime: "pi", Role: "peer", State: "future-state",
			Status: "idle", Bucket: "a-bucket-this-build-has-never-seen", Name: "peer-9"},
	}
	sample := &source.Sample{Rows: rows, At: at}

	lines := Render(sample, false, at, 80)
	last := lines[len(lines)-1]
	if !strings.Contains(last, "future-state") {
		t.Fatalf("unrecognised state not rendered verbatim: %q", last)
	}

	// The style layer must not guess or panic on a bucket it has no colour
	// for -- it degrades to the default (empty) style.
	if style := StyleFor("a-bucket-this-build-has-never-seen"); style != "" {
		t.Fatalf("StyleFor unrecognised bucket = %q, want empty (default style)", style)
	}
}

// TestCellFor_EmptyProjectRendersBlankNotUnknown pins the blank-not-guessed
// rule directly: a row with no project attribution (e.g. ft012's unknown
// attribution row, whose per-agent Project field is empty even though the
// aggregate count view groups it under the literal "unknown" key) must never
// render the word "unknown" here -- that would collide with adr0017's
// observational verdict, which owns that word for a different layer. It
// renders the same blank glyph every other column already uses for "no
// value", so a future "helpful" default cannot slip in unnoticed.
func TestCellFor_EmptyProjectRendersBlankNotUnknown(t *testing.T) {
	row := source.Row{Project: "", Runtime: "claude", Name: "dotfiles-ad"}
	got := cellFor(colProject, row, "1m")
	if got != emptyCell {
		t.Fatalf("cellFor(colProject, empty project) = %q, want the blank glyph %q", got, emptyCell)
	}
	if strings.Contains(got, "unknown") {
		t.Fatalf("cellFor(colProject, empty project) = %q, must never guess \"unknown\"", got)
	}
}

// TestRender_EmptyProjectRendersBlankInFullFrame is the same rule proven
// through the public Render path: the PROJECT cell for a row with no
// project is blank in the actual rendered line, not just at the cellFor
// unit.
func TestRender_EmptyProjectRendersBlankInFullFrame(t *testing.T) {
	at := time.Now()
	rows := []source.Row{
		{Project: "", Runtime: "claude", Name: "dotfiles-ad", Status: "idle", Bucket: "idle"},
	}
	sample := &source.Sample{Rows: rows, At: at}

	lines := Render(sample, false, at, 80)
	last := lines[len(lines)-1]
	if strings.Contains(last, "unknown") {
		t.Fatalf("row line %q must never render a guessed \"unknown\" project", last)
	}
}

// TestRender_CJKProjectName_TruncatesOnCellsNotRunes proves the PROJECT
// column truncates by display cell, not by rune count: a CJK project name
// wider than the declared column width must still fit within it, and the
// whole line must never exceed the terminal width when measured in cells
// (a rune-count check would under-count wide characters and miss an
// overflow). The width used here (69) is the exact sum of every declared
// column width plus separators -- the tightest width at which all columns
// still fit -- deliberately chosen so any per-column overflow (a
// rune-counting truncator letting the PROJECT cell run to 15 cells instead
// of its declared 8) blows the total budget and this test catches it. A
// looser width like 80 has slack that hides exactly that bug.
func TestRender_CJKProjectName_TruncatesOnCellsNotRunes(t *testing.T) {
	at := time.Now()
	rows := []source.Row{
		{Project: "工程项目服务平台名称", Runtime: "claude", Name: "dotfiles-ad", Status: "idle", Bucket: "idle"},
	}
	sample := &source.Sample{Rows: rows, At: at}

	lines := Render(sample, false, at, 69)
	assertMaxLineCellWidth(t, lines, 69)

	last := lines[len(lines)-1]
	if !strings.Contains(last, "…") {
		t.Fatalf("row line %q does not show truncation of the long CJK project name", last)
	}
}

// assertMaxLineCellWidth is assertMaxLineWidth's cell-aware counterpart: a
// rune count under-measures wide (CJK/emoji) characters, which would let a
// genuine overflow slip past a rune-only check.
func assertMaxLineCellWidth(t *testing.T, lines []string, width int) {
	t.Helper()
	for i, l := range lines {
		if n := displayWidth(l); n > width {
			t.Fatalf("line %d exceeds width %d (got %d display cells): %q", i, width, n, l)
		}
	}
}
