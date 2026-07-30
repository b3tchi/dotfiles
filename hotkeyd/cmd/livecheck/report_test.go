package main

import (
	"strings"
	"testing"
)

func lines(s string) []string {
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

func TestReporter_CheckPrintsPassAndFail(t *testing.T) {
	var sb strings.Builder
	r := NewReporter(&sb)
	r.Check(true, "a true claim", "detail")
	r.Check(false, "a false claim", "")

	got := lines(sb.String())
	want := []string{
		"PASS a true claim — detail",
		"FAIL a false claim",
	}
	if len(got) != len(want) {
		t.Fatalf("got %d lines %q, want %d", len(got), got, len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("line %d: got %q, want %q", i, got[i], want[i])
		}
	}
	if r.Passed != 1 || r.Failed != 1 || r.Skipped != 0 {
		t.Errorf("counters: pass=%d fail=%d skip=%d, want 1/1/0", r.Passed, r.Failed, r.Skipped)
	}
}

// THE im009 DISCIPLINE, encoded: a claim whose precondition did not hold on
// THIS run is never PASS. The python suite's judged() spends its whole doc
// comment on why (a live timing check whose subject never materialised passes
// for free); sp021 Task 14 asks for SKIP rather than python's FAIL, so the
// distinction a reader needs — "we did not test this" vs "this is broken" —
// survives into the Go output.
func TestReporter_JudgedSkipsWhenPreconditionMissing(t *testing.T) {
	for _, ok := range []bool{true, false} {
		var sb strings.Builder
		r := NewReporter(&sb)
		r.Judged(false, ok, "a claim nobody could judge", "d", "no phenomenon this run")

		got := lines(sb.String())
		if len(got) != 1 {
			t.Fatalf("ok=%v: got %d lines %q, want 1", ok, len(got), got)
		}
		if !strings.HasPrefix(got[0], "SKIP ") {
			t.Errorf("ok=%v: got %q, want a SKIP line", ok, got[0])
		}
		if strings.HasPrefix(got[0], "PASS") {
			t.Errorf("ok=%v: a skipped precondition printed PASS: %q", ok, got[0])
		}
		if !strings.Contains(got[0], "no phenomenon this run") {
			t.Errorf("ok=%v: SKIP line does not say WHY: %q", ok, got[0])
		}
		if r.Passed != 0 || r.Failed != 0 || r.Skipped != 1 {
			t.Errorf("ok=%v: counters pass=%d fail=%d skip=%d, want 0/0/1", ok, r.Passed, r.Failed, r.Skipped)
		}
	}
}

func TestReporter_JudgedGradesWhenPreconditionHolds(t *testing.T) {
	for _, tc := range []struct {
		ok     bool
		prefix string
	}{{true, "PASS "}, {false, "FAIL "}} {
		var sb strings.Builder
		r := NewReporter(&sb)
		r.Judged(true, tc.ok, "a judgable claim", "", "unused")
		got := lines(sb.String())
		if len(got) != 1 || !strings.HasPrefix(got[0], tc.prefix) {
			t.Errorf("ok=%v: got %q, want prefix %q", tc.ok, got, tc.prefix)
		}
	}
}

// A bare Skip is the same gate applied to a whole scenario: the rig lacked
// something (no xdotool, no i3), so nothing downstream may report PASS.
func TestReporter_SkipCountsAndNeverPasses(t *testing.T) {
	var sb strings.Builder
	r := NewReporter(&sb)
	r.Skip("a scenario the rig cannot run", "xdotool missing")
	got := lines(sb.String())
	if len(got) != 1 || !strings.HasPrefix(got[0], "SKIP ") {
		t.Fatalf("got %q, want one SKIP line", got)
	}
	if !strings.Contains(got[0], "xdotool missing") {
		t.Errorf("SKIP line does not carry the reason: %q", got[0])
	}
	if r.Skipped != 1 || r.Passed != 0 {
		t.Errorf("counters pass=%d skip=%d, want 0/1", r.Passed, r.Skipped)
	}
}

func TestReporter_ExitCodeIsZeroOnlyWithNoFailures(t *testing.T) {
	var sb strings.Builder
	r := NewReporter(&sb)
	r.Check(true, "fine", "")
	r.Skip("unrun", "reason")
	if code := r.ExitCode(); code != 0 {
		t.Errorf("pass+skip only: exit %d, want 0", code)
	}
	r.Check(false, "broken", "")
	if code := r.ExitCode(); code == 0 {
		t.Errorf("with a FAIL: exit %d, want non-zero", code)
	}
}

// The summary must always name the skip count, so a run that silently
// skipped everything cannot read as a clean run.
func TestReporter_SummaryNamesSkips(t *testing.T) {
	var sb strings.Builder
	r := NewReporter(&sb)
	r.Check(true, "x", "")
	r.Skip("y", "z")
	r.Summary()
	last := lines(sb.String())
	got := last[len(last)-1]
	if !strings.Contains(got, "1 skip") || !strings.Contains(got, "1 pass") || !strings.Contains(got, "0 fail") {
		t.Errorf("summary %q does not carry pass/fail/skip counts", got)
	}
}
