package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/proc"
)

// stageDaemon makes a runtime dir that looks like a live daemon's: a lock
// file claiming THIS process's pid (so proc.CurrentGrabReport's adr0017 pid
// check passes) and, optionally, an already-published grab report.
func stageDaemon(t *testing.T, display string, wanted, active int) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	if err := os.WriteFile(proc.LockPath(display), []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644); err != nil {
		t.Fatalf("staging lock: %v", err)
	}
	if wanted >= 0 {
		proc.WriteGrabReport(display, wanted, active, nil)
	}
	if _, err := os.Stat(filepath.Dir(proc.GrabReportPath(display))); err != nil {
		t.Fatalf("staging runtime dir: %v", err)
	}
}

// THE REVIEWER'S PROBE, kept as a test.
//
// Both engines write the grab report only AFTER a complete sync, so while a
// sync is in flight the report on disk is the STALE PREVIOUS one — and a
// stale report is perfectly stable. A settle signal that returns on "two
// identical consecutive samples" therefore cannot tell "the sync finished
// and went quiet" from "the sync has not written yet". Measured against the
// first implementation, this returned after 121 ms with the pre-transition
// report still on disk, which made the fix for the python-arm parity finding
// merely SLOWER rather than sound.
func TestGrabWatch_WaitsForTheNewReport_NotForTheStaleOneToGoQuiet(t *testing.T) {
	const display = ":91"
	stageDaemon(t, display, 20, 20)

	w := watchGrabs(display)
	go func() {
		time.Sleep(800 * time.Millisecond)
		proc.WriteGrabReport(display, 106, 106, nil)
	}()

	start := time.Now()
	ok, detail := w.settled(5 * time.Second)
	elapsed := time.Since(start)

	if !ok {
		t.Fatalf("settled() = false (%s); the new report landed at 800ms and should have been seen", detail)
	}
	if elapsed < 800*time.Millisecond {
		t.Fatalf("settled() returned after %v — before the new report was published at 800ms. "+
			"It settled on the STALE pre-transition report, which is the unsound signal this replaces (detail=%q)",
			elapsed, detail)
	}
	r, okr := proc.CurrentGrabReport(display)
	if !okr || r.Wanted != 106 {
		t.Fatalf("report at return = %v (ok=%v), want the post-transition wanted=106", r, okr)
	}
}

// The sneaky case, and the reason this keys on PUBLICATION rather than
// content: a resync whose new report is byte-identical to the old one is
// still a completed sync, and is the only proof available that the grabs
// this run is about are installed. Content comparison cannot see it at all.
func TestGrabWatch_SeesARepublishWithIdenticalContent(t *testing.T) {
	const display = ":92"
	stageDaemon(t, display, 42, 42)

	w := watchGrabs(display)
	go func() {
		time.Sleep(400 * time.Millisecond)
		proc.WriteGrabReport(display, 42, 42, nil) // same numbers, new publication
	}()

	start := time.Now()
	ok, detail := w.settled(5 * time.Second)
	elapsed := time.Since(start)
	if !ok {
		t.Fatalf("settled() = false (%s) for a republish with identical content", detail)
	}
	if elapsed < 400*time.Millisecond {
		t.Fatalf("settled() returned after %v, before the republish at 400ms — it cannot be observing publication", elapsed)
	}
}

// A sync that never lands must be reported, not swallowed. The old signal
// returned silently on timeout, so a caller could not tell "settled" from
// "gave up" and proceeded either way.
func TestGrabWatch_ReportsTimeoutWhenNothingIsPublished(t *testing.T) {
	const display = ":93"
	stageDaemon(t, display, 20, 20)

	w := watchGrabs(display)
	ok, detail := w.settled(600 * time.Millisecond)
	if ok {
		t.Fatalf("settled() = true with no new report published (detail=%q)", detail)
	}
	if detail == "" {
		t.Fatal("settled() timed out with an EMPTY reason; callers print this as the SKIP reason")
	}
}

// A sync that is still writing must not be mistaken for a finished one: the
// report has to go QUIET after it advances, or a resync that publishes more
// than once would be sampled between its writes. The burst below is spaced
// well inside grabQuiet, so only the LAST publication may end the wait.
func TestGrabWatch_WaitsForTheReportToGoQuietAfterItAdvances(t *testing.T) {
	const display = ":94"
	stageDaemon(t, display, 20, 20)

	w := watchGrabs(display)
	go func() {
		for _, n := range []int{40, 70, 106} {
			time.Sleep(100 * time.Millisecond)
			proc.WriteGrabReport(display, n, n, nil)
		}
	}()

	ok, detail := w.settled(6 * time.Second)
	if !ok {
		t.Fatalf("settled() = false (%s)", detail)
	}
	r, _ := proc.CurrentGrabReport(display)
	if r == nil || r.Wanted != 106 {
		t.Fatalf("settled on %v — returned before the last publication of the burst", r)
	}
}

// adr0017 continuity: a report whose pid does not match the lock's is
// evidence about a DIFFERENT daemon. Settling on it would hand a caller a
// green precondition read off a dead process's leftovers.
func TestGrabWatch_RefusesAReportFromAnotherDaemon(t *testing.T) {
	const display = ":95"
	stageDaemon(t, display, -1, 0)

	w := watchGrabs(display)
	// A report stamped with a pid that is not the lock's: written by hand,
	// because proc.WriteGrabReport always stamps the caller's own pid.
	go func() {
		time.Sleep(200 * time.Millisecond)
		_ = os.WriteFile(proc.GrabReportPath(display),
			[]byte(`{"pid":999999,"wanted":106,"active":106,"missing":[]}`), 0o644)
	}()

	ok, detail := w.settled(2 * time.Second)
	if ok {
		t.Fatalf("settled() = true on a report belonging to another daemon (detail=%q)", detail)
	}
}

// THE FOURTH-ROUND DEFECT (dotfiles-ylmp.18), kept as a test.
//
// settled() answers a LATENCY question — "was the report published again?"
// — and a caller that grades the report's CONTENT under a layer's name
// needs an IDENTIFICATION answer too. A resync triggered BEFORE the
// baseline that has not written yet lands afterwards, arrives as a fresh
// inode, and satisfies settled() while still describing the PREVIOUS
// layer. Staged here exactly as measured on the rig: the baseline is a nav
// report, the publication that lands is the pre-transition DEFAULT one, and
// settled() is (correctly) true throughout.
func TestGrabWatch_SettledDoesNotIdentifyWhichLayerTheReportDescribes(t *testing.T) {
	const display = ":97"
	stageDaemon(t, display, 106, 105) // nav's report, still on disk

	w := watchGrabs(display)
	go func() {
		// The DEFAULT layer's resync, triggered before the baseline and
		// still in flight when it was taken, finally writes.
		time.Sleep(200 * time.Millisecond)
		proc.WriteGrabReport(display, 70, 70, nil)
	}()

	ok, _ := w.settled(5 * time.Second)
	if !ok {
		t.Fatal("settled() = false; the in-flight publication did land, so the latency signal is right to say so")
	}
	got, okr := proc.CurrentGrabReport(display)
	if !okr || got.Wanted != 70 {
		t.Fatalf("report at return = %v (ok=%v); the staged in-flight publication is the 70-chord one", got, okr)
	}
	// The point: settled() being true says NOTHING about which layer this
	// describes, so the caller must be able to reach the pre-input set and
	// rule it out itself.
	base, haveBase := w.baselineSet()
	if !haveBase {
		t.Fatal("baselineSet() reported nothing; the pre-input report was staged and readable")
	}
	if base.Wanted != 106 || base.Active != 105 {
		t.Fatalf("baselineSet() = %+v, want the pre-input nav report (wanted=106 active=105)", base)
	}
}

func TestGrabWatch_BaselineSetReportsNothingWhenNoReportExistedYet(t *testing.T) {
	const display = ":98"
	stageDaemon(t, display, -1, 0)
	if got, ok := watchGrabs(display).baselineSet(); ok {
		t.Fatalf("baselineSet() = %+v, ok=true with no report on disk", got)
	}
}

// sameGrabSet compares EVIDENCE, not publications: settled() keys on the
// write (see this file's header, and the identical-content republish test
// above), and identification needs the exact opposite question asked.
func TestSameGrabSet_ComparesWhatTheReportSaysNotWhoWroteIt(t *testing.T) {
	base := proc.GrabReport{PID: 11, Wanted: 70, Active: 70, Missing: nil}
	for _, tc := range []struct {
		name string
		with proc.GrabReport
		want bool
	}{
		{"a republication of the same set by the same daemon", proc.GrabReport{PID: 11, Wanted: 70, Active: 70}, true},
		{"the same set republished under a different pid", proc.GrabReport{PID: 12, Wanted: 70, Active: 70}, true},
		{"a bigger set", proc.GrabReport{PID: 11, Wanted: 87, Active: 87}, false},
		{"the same counts but a refusal", proc.GrabReport{PID: 11, Wanted: 70, Active: 69, Missing: []string{"Meta_R"}}, false},
	} {
		if got := sameGrabSet(base, tc.with); got != tc.want {
			t.Errorf("%s: sameGrabSet = %v, want %v", tc.name, got, tc.want)
		}
	}
}

// THE GATE ITSELF. A report whose content this run had ALREADY SEEN before
// the transition is not evidence about the layer the transition entered,
// and the claim that grades it must SKIP naming which earlier reading it
// matched — not PASS on a real, correct report belonging to another layer.
func TestNotAPriorReport_RefusesAReportTheRunSawBeforeTheTransition(t *testing.T) {
	deflt := proc.GrabReport{PID: 7, Wanted: 70, Active: 70}
	nav := proc.GrabReport{PID: 7, Wanted: 106, Active: 105, Missing: []string{"Meta_R"}}

	graded := proc.GrabReport{PID: 7, Wanted: 70, Active: 70} // the DEFAULT set, republished late
	g := notAPriorReport(&graded, true,
		priorReport{"the DEFAULT layer's report", deflt, true},
		priorReport{"the report on disk before this section", nav, true},
	)
	if g.ok {
		t.Fatal("the gate held for a report identical to the pre-transition DEFAULT set — " +
			"this is dotfiles-ylmp.18's green run")
	}
	if !strings.Contains(g.why, "DEFAULT layer's report") {
		t.Errorf("the SKIP reason does not name WHICH earlier reading it matched: %q", g.why)
	}
}

func TestNotAPriorReport_HoldsForTheLayersOwnSet(t *testing.T) {
	deflt := proc.GrabReport{PID: 7, Wanted: 70, Active: 70}
	nav := proc.GrabReport{PID: 7, Wanted: 106, Active: 105}
	switcher := proc.GrabReport{PID: 7, Wanted: 87, Active: 87}

	g := notAPriorReport(&switcher, true,
		priorReport{"the DEFAULT layer's report", deflt, true},
		priorReport{"the report on disk before this section", nav, true},
	)
	if !g.ok {
		t.Fatalf("the gate refused the layer's OWN set — a healthy run would SKIP a real PASS (%s)", g.why)
	}
}

// A prior this run never managed to read cannot rule anything out, and must
// not be treated as an empty report that everything differs from OR as a
// match that skips everything.
func TestNotAPriorReport_IgnoresPriorsThisRunNeverRead(t *testing.T) {
	graded := proc.GrabReport{}
	g := notAPriorReport(&graded, true, priorReport{"a reading that failed", proc.GrabReport{}, false})
	if !g.ok {
		t.Fatalf("an unread prior blocked the gate: %s", g.why)
	}
}

// No report at all is the DAEMON's failure, not a precondition gap: the
// claim must stay judgeable so it FAILs, exactly as it did before this gate
// existed.
func TestNotAPriorReport_HoldsWhenThereIsNoReportAtAll(t *testing.T) {
	deflt := proc.GrabReport{PID: 7, Wanted: 70, Active: 70}
	if g := notAPriorReport(nil, false, priorReport{"the DEFAULT layer's report", deflt, true}); !g.ok {
		t.Fatalf("a missing report was turned into a SKIP: %s", g.why)
	}
}

// The first publication of a fresh daemon: there is no baseline report at
// all, so the FIRST report is itself the advance.
func TestGrabWatch_TreatsTheFirstEverReportAsTheAdvance(t *testing.T) {
	const display = ":96"
	stageDaemon(t, display, -1, 0)

	w := watchGrabs(display)
	go func() {
		time.Sleep(300 * time.Millisecond)
		proc.WriteGrabReport(display, 106, 106, nil)
	}()

	start := time.Now()
	ok, detail := w.settled(5 * time.Second)
	if !ok {
		t.Fatalf("settled() = false (%s) for a first-ever report", detail)
	}
	if time.Since(start) < 300*time.Millisecond {
		t.Fatal("settled() returned before the first report existed")
	}
}
