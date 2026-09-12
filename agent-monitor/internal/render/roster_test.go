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
		{Project: "dotfiles", Runtime: "claude", Role: "", State: "", Status: "idle", Bucket: "idle", Name: "dotfiles-ad"},
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
	for _, want := range []string{"UID/NAME", "RUNTIME", "ROLE", "STATE", "ACTIVITY", "AGE"} {
		if !strings.Contains(colHeader, want) {
			t.Errorf("column header %q missing %q", colHeader, want)
		}
	}
	// Declared left-to-right order.
	prevIdx := -1
	for _, want := range []string{"UID/NAME", "RUNTIME", "ROLE", "STATE", "ACTIVITY", "AGE"} {
		idx := strings.Index(colHeader, want)
		if idx <= prevIdx {
			t.Fatalf("column %q out of order in header %q", want, colHeader)
		}
		prevIdx = idx
	}

	// Row content, including the sample-level age repeated per row.
	blockedLine := lines[2]
	for _, want := range []string{"peer-3", "pi", "peer", "waiting_human", "idle", "1m"} {
		if !strings.Contains(blockedLine, want) {
			t.Errorf("row line %q missing %q", blockedLine, want)
		}
	}
}

func TestRender_GoldenAt40_DropsColumnsInDeclaredOrder(t *testing.T) {
	at := time.Date(2026, 9, 12, 12, 0, 0, 0, time.UTC)
	now := at.Add(90 * time.Second)
	sample := &source.Sample{Rows: sampleRows(), At: at}

	lines := Render(sample, false, now, 40)
	assertMaxLineWidth(t, lines, 40)

	colHeader := lines[1]
	// Declared drop order is age, then activity, then state (right to left);
	// at width 40 only uid/name, runtime and role fit (see fitColumns table
	// test below for the exact boundary), so none of the dropped headers may
	// appear, and the kept ones must still be present.
	for _, dropped := range []string{"AGE", "ACTIVITY", "STATE"} {
		if strings.Contains(colHeader, dropped) {
			t.Errorf("column header %q at width 40 still contains dropped column %q", colHeader, dropped)
		}
	}
	for _, kept := range []string{"UID/NAME", "RUNTIME", "ROLE"} {
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
	all := []column{colUIDName, colRuntime, colRole, colState, colActivity, colAge}
	if got := fitColumns(80); !colsEqual(got, all) {
		t.Fatalf("fitColumns(80) = %v, want all columns %v", got, all)
	}

	// Width 40 keeps exactly uid/name, runtime, role per the fixed widths
	// declared in columnWidth (14+1+7+1+7 = 30 <= 40; adding state's 13 would
	// make 44 > 40).
	want40 := []column{colUIDName, colRuntime, colRole}
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
