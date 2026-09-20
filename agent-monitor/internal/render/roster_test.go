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

// dotfiles-a1tq: the AGE column is the AGENT's age now, not a copy of the
// sample's capture age in every row. The census carries a per-row `started`
// stamp for both runtimes, so the roster can answer "how long has THIS one
// been blocked" — which is the question the column was added for, and the one
// a uniform capture age cannot answer. The header keeps reporting sample
// freshness; the two ages mean different things and are shown in different
// places.
func TestRender_AgeColumnIsPerRowWhenTheCensusSaysWhenEachStarted(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	now := at.Add(30 * time.Second)
	rows := []source.Row{
		{Project: "dotfiles", Runtime: "pi", Role: "peer", State: "waiting_human", Bucket: "blocked", Name: "peer-3",
			Started: "2026-09-12T09:00:00.000000Z"}, // 3h before `now`
		{Project: "dotfiles", Runtime: "claude", State: "", Status: "busy", Bucket: "working", Name: "dotfiles-ad",
			Started: "2026-09-12T11:58:00.000000Z"}, // 2m30s before `now`
	}
	lines := Render(&source.Sample{Rows: rows, At: at}, false, now, 100)

	if !strings.Contains(lines[0], "updated 30s ago") {
		t.Fatalf("the header must still report the SAMPLE's freshness, got %q", lines[0])
	}
	if !strings.HasSuffix(strings.TrimRight(lines[2], " "), "3h") {
		t.Errorf("row 1 age = %q, want the agent's own 3h", lines[2])
	}
	if !strings.HasSuffix(strings.TrimRight(lines[3], " "), "2m") {
		t.Errorf("row 2 age = %q, want the agent's own 2m", lines[3])
	}
}

// A row the census could not stamp falls back to the sample's capture age,
// which is the honest bound this renderer always had — never blank, and never
// a fabricated agent age.
func TestRender_AgeFallsBackToTheSampleAgeWhenARowHasNoStamp(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	now := at.Add(90 * time.Second)
	rows := []source.Row{{Project: "dotfiles", Runtime: "pi", Bucket: "other", Name: "peer-9"}}
	lines := Render(&source.Sample{Rows: rows, At: at}, false, now, 100)
	if !strings.HasSuffix(strings.TrimRight(lines[2], " "), "1m") {
		t.Errorf("row age = %q, want the sample's own 1m", lines[2])
	}
}

// An unparseable stamp is the same case as an absent one: the sample age, not
// a guess and not a negative duration.
func TestRender_AgeIgnoresAnUnparseableStamp(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	now := at.Add(90 * time.Second)
	rows := []source.Row{{Project: "dotfiles", Runtime: "pi", Bucket: "other", Name: "peer-9", Started: "yesterday-ish"}}
	lines := Render(&source.Sample{Rows: rows, At: at}, false, now, 100)
	if !strings.HasSuffix(strings.TrimRight(lines[2], " "), "1m") {
		t.Errorf("row age = %q, want the sample's own 1m", lines[2])
	}
}

// --- dotfiles-jw73 rejection #1: FilterRoster is the SAME committed filter
// as the message pane's — tui.Model has one Filter, not two (keys.go:838)
// — so a reduced roster was exactly as silent as a reduced message list
// was before this task's first pass, and needs the identical indicator. ---

// TestRender_CommittedFilterShownInHeader is requirement 2 for the roster:
// a non-empty committed query renders in the roster's own header line.
func TestRender_CommittedFilterShownInHeader(t *testing.T) {
	at := time.Now()
	sample := &source.Sample{Rows: sampleRows(), At: at}

	got := Render(sample, false, at, 100, RosterSignals{FilterQuery: "peer-2"})[0]
	if !strings.Contains(got, "filter: peer-2") {
		t.Fatalf("header = %q, want it to carry the committed filter", got)
	}
}

// TestRender_EmptyQueryKeysOnContentNotSet is the same Set-vs-content
// distinction the message pane's header enforces: LogSignals carries no
// Set bool, only the query string, so an empty FilterQuery must never add
// a segment.
func TestRender_EmptyQueryKeysOnContentNotSet(t *testing.T) {
	at := time.Now()
	sample := &source.Sample{Rows: sampleRows(), At: at}
	base := Render(sample, false, at, 100)[0]

	if got := Render(sample, false, at, 100, RosterSignals{FilterQuery: ""})[0]; got != base {
		t.Errorf("empty FilterQuery changed the header: %q, want %q", got, base)
	}
}

// TestRender_EditingShowsDraftWithCursor is requirement 1 for the roster:
// the roster is filtered by the SAME draft the message pane echoes, so it
// needs the same echo — including the trailing cursor on an empty draft.
func TestRender_EditingShowsDraftWithCursor(t *testing.T) {
	at := time.Now()
	sample := &source.Sample{Rows: sampleRows(), At: at}

	got := Render(sample, false, at, 100, RosterSignals{FilterEditing: true, FilterDraft: "pe"})[0]
	if !strings.Contains(got, "editing filter: pe"+filterCursor) {
		t.Fatalf("header = %q, want the draft echoed with a trailing cursor", got)
	}
}

// TestRender_ByteIdenticalWhenFilterInactive is the regression anchor: every
// existing 4-arg call (and any zero-value RosterSignals) renders the exact
// byte-identical header as before this task.
func TestRender_ByteIdenticalWhenFilterInactive(t *testing.T) {
	at := time.Now()
	sample := &source.Sample{Rows: sampleRows(), At: at}

	omitted := Render(sample, false, at, 100)
	explicit := Render(sample, false, at, 100, RosterSignals{})
	if omitted[0] != explicit[0] {
		t.Fatalf("4-arg and explicit-zero calls differ: %q vs %q", omitted[0], explicit[0])
	}
	if strings.Contains(omitted[0], "filter") {
		t.Fatalf("an inactive filter leaked a segment into the header: %q", omitted[0])
	}
}

// TestRender_FilterQueryWiderThanTerminalNeverOverflows mirrors the message
// pane's overflow fix: the roster's own header must never exceed width
// either, and keeps the tail.
func TestRender_FilterQueryWiderThanTerminalNeverOverflows(t *testing.T) {
	at := time.Now()
	sample := &source.Sample{Rows: sampleRows(), At: at}

	long := strings.Repeat("x", 60) + "-tail-end"
	header := Render(sample, false, at, 40, RosterSignals{FilterQuery: long})[0]
	if got := displayWidth(header); got > 40 {
		t.Fatalf("header is %d cells wide at width 40: %q", got, header)
	}
	if !strings.Contains(header, "tail-end") {
		t.Fatalf("header dropped the tail the operator typed last: %q", header)
	}
}

// --- dotfiles-br55 / dotfiles-qm4h Task 1: pad neutralises every grid cell -

// TestPad_NeutralisesBeforeMeasuring is the test_plan's named ordering test.
// "\x1b[31mAB" contains a live ESC (0x1b) whose OWN accounting is free —
// runeWidth reports 0 for r < 0x20 — while the rest of the escape sequence's
// bytes ("[31m") are ordinary printable runes that DO cost width, because
// pad has no ANSI parser and cannot tell a CSI payload from real text. That
// asymmetry is exactly what lets a neutralise-AFTER-measure/truncate
// implementation slip an ESC byte past truncateCells: measuring and
// truncating the RAW string first hands truncateCells the ESC as a
// zero-cost passenger it carries along into the truncated result, and only
// neutralising the FINAL string afterwards would have caught it — a bug
// this pad already does not have, but a wrong "measure first" ordering
// would reproduce. Correct behaviour: neutralize(s) first gives "[31mAB"
// (6 cells), which truncateCells then cuts to "[31…" at width 4 — exactly
// width cells, with no ESC anywhere in the result.
func TestPad_NeutralisesBeforeMeasuring(t *testing.T) {
	got := pad("\x1b[31mAB", 4)
	if w := displayWidth(got); w != 4 {
		t.Fatalf("pad(%q, 4) = %q, display width %d, want exactly 4", "\x1b[31mAB", got, w)
	}
	if strings.ContainsRune(got, 0x1b) {
		t.Fatalf("pad(%q, 4) = %q, still carries an ESC (0x1b) byte", "\x1b[31mAB", got)
	}
}

// hasStrippedControlByte mirrors neutralize's own predicate (subject.go) so
// a grid-level test can assert "nothing neutralize would have removed
// survived rendering" without hardcoding just the ESC byte dotfiles-br55
// happened to reproduce with. Rejection #1 gap 2: a test that only ever
// tries 0x1b proves nothing about DEL (0x7f) or the C1 range (0x80-0x9f),
// which runeWidth (unlike neutralize) does NOT treat as zero-width — see
// TestPad_DELAndC1DivergeFromRawWidth below for why that distinction is the
// one a neutralise-after-measure pad cannot survive. Shared by this file
// and log_test.go; both are package render.
func hasStrippedControlByte(s string) bool {
	for _, r := range s {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
			return true
		}
	}
	return false
}

// TestPad_DELAndC1DivergeFromRawWidth is rejection #1 gap 1:
// TestPad_NeutralisesBeforeMeasuring above uses ESC alone, and ESC's
// runeWidth is 0 whether or not it has been neutralised yet — raw width and
// neutralised width are IDENTICAL for pure C0, so that test cannot tell a
// correct pad from a neutralise-after-measure one; both land on the same
// number by accident. DEL (0x7f) and the C1 range (0x80-0x9f) break that
// accident: neutralize strips all three classes, but runeWidth only
// special-cases r < 0x20 — DEL and C1 fall through to the default case and
// count as width 1. A pad that measures the RAW string first therefore
// computes a width that INCLUDES these bytes, pads to fill that budget, and
// only then loses them for free when neutralize finally runs — landing
// SHORT of the declared width by exactly the number of DEL/C1 bytes
// removed. Every fixture here stays inside pad's PADDING branch (raw width
// well under 12), which is where the rejection's differential dump found
// the divergence; neutralising FIRST is the only order where "how much do I
// pad" and "what actually reaches the terminal" agree.
func TestPad_DELAndC1DivergeFromRawWidth(t *testing.T) {
	cases := []string{
		"w\x7fa",             // DEL
		"w\u009da",           // C1 (0x9d)
		"w\u0085a",           // C1 (0x85)
		"a\x7f\u009b\u009da", // DEL + two C1 bytes in one cell
	}
	for _, s := range cases {
		got := pad(s, 12)
		if w := displayWidth(got); w != 12 {
			t.Errorf("pad(%q, 12) = %q, display width %d, want exactly 12", s, got, w)
		}
		if hasStrippedControlByte(got) {
			t.Errorf("pad(%q, 12) = %q, still carries a byte neutralize should have stripped", s, got)
		}
	}
}

// TestPad_TabIsNeutralised pins a genuine, intended behaviour change rather
// than a silent regression: TAB (0x09) is C0, so runeWidth reports it as
// zero-width exactly like ESC — but a terminal actually expands a raw TAB
// to the next 8-cell stop, the same accounting lie ESC tells. Before this
// task pad never neutralised at all, so "tabs\tnope" rendered with a live
// TAB byte that happened to measure the same either way (TAB, like ESC, is
// zero-width on BOTH sides of neutralize — see the doc above). This is the
// one benign fixture in a full pad differential that changes byte-for-byte
// after this fix, and it is fixed correctly: the TAB is gone, not replaced
// with a guess, and the rest of the padding is unaffected.
func TestPad_TabIsNeutralised(t *testing.T) {
	got := pad("tabs\tnope", 12)
	want := "tabsnope    "
	if got != want {
		t.Fatalf("pad(%q, 12) = %q, want %q", "tabs\tnope", got, want)
	}
}

// TestPad_EscapesOnlyCellPadsToWidthNeverNegative is the test_plan's
// "escapes-only" edge case: a cell that is NOTHING but control bytes must
// collapse to empty and then pad out to width — never truncate a
// zero-length string to a negative width, and never leave any of those
// bytes in the output.
func TestPad_EscapesOnlyCellPadsToWidthNeverNegative(t *testing.T) {
	// ESC, BEL, ESC: every byte here is a C0 control character (< 0x20),
	// unlike a full CSI sequence such as "\x1b[31m" whose "[31m" payload is
	// ordinary printable text that neutralize leaves alone. This cell has
	// nothing left once neutralised.
	got := pad("\x1b\x07\x1b", 5)
	if got != "     " {
		t.Fatalf("pad of an escapes-only cell = %q, want 5 spaces", got)
	}
}

// TestPad_BenignOutputUnchanged is the test_plan's byte-identity table:
// neutralize removes nothing from text that carries no C0/DEL/C1 bytes, so
// every one of these representative cells must render exactly as pad
// produced it before this task touched the function.
func TestPad_BenignOutputUnchanged(t *testing.T) {
	cases := []struct {
		s     string
		width int
		want  string
	}{
		{"hello", 8, "hello   "},
		{"", 4, "    "},
		{"exact", 5, "exact"},
		{"toolongvalue", 6, "toolo…"},
		{"工程项目服务平台", 9, "工程项目…"},
	}
	for _, c := range cases {
		if got := pad(c.s, c.width); got != c.want {
			t.Errorf("pad(%q, %d) = %q, want %q", c.s, c.width, got, c.want)
		}
	}
}

// TestRender_HostileRosterCellIsNeutralised is the test_plan's roster-grid
// case: a census row is untrusted input exactly like a message envelope
// (both are worker-supplied), so a hostile byte in ANY roster column — not
// just the ones dotfiles-br55 named on the message pane — must not reach
// the terminal. Rejection #1 gap 2: every column here mixes ESC with DEL
// (0x7f), a C1 byte (0x9d) and a bare TAB (0x09), not just 0x1b, so this
// grid is proven clean of every class neutralize strips, end to end.
func TestRender_HostileRosterCellIsNeutralised(t *testing.T) {
	at := time.Now()
	rows := []source.Row{
		{
			Project: "w\x1b[31m\x7fa", Runtime: "j\x1b[0m\u009dx", Role: "peer",
			State: "running", Status: "idle", Bucket: "idle",
			Name: "peer-\x1b[2J\x7f\u0085\thostile",
		},
	}
	sample := &source.Sample{Rows: rows, At: at}
	lines := Render(sample, false, at, 100)
	for i, l := range lines {
		if hasStrippedControlByte(l) {
			t.Errorf("line %d still carries a byte neutralize should have stripped: %q", i, l)
		}
	}
}
