package main

import (
	"fmt"
	"io"
)

// Reporter is livecheck's verdict accounting: one line per claim, in the
// PASS/FAIL vocabulary test-hotkeyd.sh's stage 6 already greps for, plus a
// third verdict python's live_check.py does not have — SKIP.
//
// # Why SKIP exists here and not in live_check.py
//
// live_check.py's judged() prints FAIL when the precondition a claim needs
// did not materialise, on the argument that a green line for an untested
// claim is worse than a red one. That argument is right about what must
// NEVER happen (PASS) and imprecise about what should happen instead: FAIL
// conflates "this daemon is broken" with "this run could not ask the
// question", and an operator reading a red line cannot tell which. sp021
// Task 14 asks for SKIP, so the Go suite keeps the hard part of the
// discipline (no phenomenon, no pass) and separates the two red-ish cases.
//
// The cost of a third verdict is that a run which skips everything exits 0.
// Summary() is the counterweight: the skip count is ALWAYS printed, and
// test-hotkeyd.sh's stage 6 surfaces every SKIP line in its own colour, so
// "we did not test this" is loud rather than absent.
type Reporter struct {
	w       io.Writer
	Passed  int
	Failed  int
	Skipped int
}

func NewReporter(w io.Writer) *Reporter { return &Reporter{w: w} }

func (r *Reporter) emit(verdict, what, detail string) {
	if detail != "" {
		fmt.Fprintf(r.w, "%s %s — %s\n", verdict, what, detail)
		return
	}
	fmt.Fprintf(r.w, "%s %s\n", verdict, what)
}

// Check grades an unconditional claim.
func (r *Reporter) Check(ok bool, what, detail string) bool {
	if ok {
		r.Passed++
		r.emit("PASS", what, detail)
	} else {
		r.Failed++
		r.emit("FAIL", what, detail)
	}
	return ok
}

// Judged grades a claim that can only be judged if the phenomenon it is
// about actually occurred on THIS run ([[im009]]: claims are gated on
// preconditions read off the same run).
//
// THE FAILURE THIS PREVENTS, restated from live_check.py's judged(): a live
// timing check whose subject never materialised passes for free. "A held key
// fires ONCE despite the real auto-repeat stream" is satisfied trivially by a
// run where no repeat stream arrived — it would go green against a daemon
// with NO coalescing at all. Splitting the precondition into its own separate
// line does not close it: two independent lines mean a run with no repeat
// stream prints one FAIL and one PASS, and the PASS is a green line for a
// claim that was never tested. Coupling them here makes vacuity impossible.
func (r *Reporter) Judged(precondition, ok bool, what, detail, missing string) bool {
	if !precondition {
		if missing == "" {
			missing = "precondition did not hold on this run"
		}
		r.Skip(what, "CANNOT JUDGE — "+missing)
		return false
	}
	return r.Check(ok, what, detail)
}

// Skip records that a claim was not asked on this run, and why. Never
// counts as a pass.
func (r *Reporter) Skip(what, why string) {
	r.Skipped++
	r.emit("SKIP", what, why)
}

// Summary prints the always-visible tally. The skip count is not optional:
// a run that skipped everything must not read as a clean run.
func (r *Reporter) Summary() {
	fmt.Fprintf(r.w, "livecheck: %d pass, %d fail, %d skip\n", r.Passed, r.Failed, r.Skipped)
}

// ExitCode is 0 only when nothing FAILED. Skips do not fail the run — they
// are reported, counted and surfaced by the caller.
func (r *Reporter) ExitCode() int {
	if r.Failed > 0 {
		return 1
	}
	return 0
}
