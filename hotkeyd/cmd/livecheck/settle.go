package main

// settle.go answers one question the whole daemon phase rests on: HAS THE
// GRAB SET FOR THE LAYER THIS RUN JUST ENTERED ACTUALLY LANDED?
//
// # Why the obvious answer is unsound
//
// Both daemons publish the layer's new state BEFORE the layer's grabs are
// installed (the engine publishes inside Handle; the daemon calls
// resyncGrabs afterwards), and both install the grab set ONE CHORD AT A
// TIME. A probe fired the instant the state socket says "nav" therefore
// samples a half-installed grab set, in the table's own order — so the exit
// keys near the end of the set read as ungrabbed while the ones near the
// front read as grabbed.
//
// This was NOT theory: the first run of this suite against hotkeyd.py
// reported Shift+Escape and Shift+Return "not obtained" while Shift+q was,
// and it looked exactly like a parity divergence. A direct measurement
// (daemon in nav, rival grab from a third client) showed BOTH engines hold
// all three. The Go daemon simply finishes its 106-chord sync sooner than
// python does, so only the python arm ever lost the race.
//
// The first fix waited for the grab report to STOP CHANGING. That is
// unsound, and the fact that refutes it is the same fact this file relies
// on. Both engines write the report only AFTER a complete sync plus an X
// round trip (hotkeyd.py's sync_binds: _apply -> d.sync() -> _publish;
// daemon.go's resyncGrabs: SyncBinds -> publishGrabReport). So WHILE A SYNC
// IS IN FLIGHT the report on disk is the STALE PREVIOUS one — and a stale
// report is perfectly stable. "Two identical consecutive samples" cannot
// tell "the sync finished and went quiet" from "the sync has not written
// yet". Measured: with the new report landing at 800 ms, that signal
// returned after 121 ms with the pre-transition report still on disk. It
// was merely SLOWER, not correct (see settle_test.go, which keeps the
// probe).
//
// # The signal this uses instead
//
// Invert it. A publication of the report is PROOF that a sync completed,
// because the write is the last thing a sync does. So the question becomes
// "has the report been published AGAIN since before the input that triggers
// the resync?" — which is answerable from outside without the daemon's
// cooperation, and answerable identically on either engine.
//
// A caller therefore takes a baseline BEFORE injecting, and asks for the
// settle AFTER:
//
//	w := watchGrabs(display)
//	_ = in.Tap("super+o")
//	...
//	landed, why := w.settled(grabSettleTimeout)
//
// What is compared is the report's PUBLICATION IDENTITY (inode, mtime,
// size, bytes), not its contents: both engines publish by writing a fresh
// temp file and renaming it over the target, so every publication is a new
// inode even when the numbers are identical. Content comparison alone would
// miss a resync whose new grab set happens to match the old one's counts —
// and would be back to inferring liveness from a value that a stalled
// daemon also produces.
//
// # Why not stamp the report instead
//
// The strictly better signal is a DECLARED one: the daemon writing which
// layer/generation the report describes, so a reader can positively
// identify the sync it is looking at. That was rejected here for one
// reason: hotkeyd.py would have to write the same stamp or this suite stops
// working against the python engine, and running BOTH engines through one
// suite is what turned the original race into a visible bug rather than a
// shipped green run. A signal that only works against the Go daemon would
// have cost more than it bought. The publication-identity signal needs no
// daemon change at all and is exactly as sound on both.

import (
	"encoding/json"
	"fmt"
	"os"
	"syscall"
	"time"

	"hotkeyd/internal/proc"
)

const (
	// grabSettleTimeout bounds the wait for one layer's grab set. The Go
	// daemon's 106-chord sync lands in tens of milliseconds; python's takes
	// several hundred. Five seconds is "the daemon is not going to answer",
	// not "give it a moment".
	grabSettleTimeout = 5 * time.Second
	// grabQuiet is how long the report must hold still AFTER it advanced
	// before the grab set is called settled — a resync that publishes more
	// than once must not be sampled between its writes.
	grabQuiet = 250 * time.Millisecond
	grabPoll  = 20 * time.Millisecond
)

// reportStamp is a grab report's PUBLICATION identity. Two stamps that
// differ mean the file was written again; two that match mean it was not.
// The bytes are part of it so a rewrite in place (no rename) is caught too,
// and the inode is part of it so a rename-over with identical bytes is
// caught as well — neither alone covers both engines' write paths.
type reportStamp struct {
	present bool
	ino     uint64
	mtime   int64
	size    int64
	body    string
}

func stampGrabReport(display string) reportStamp {
	path := proc.GrabReportPath(display)
	fi, err := os.Stat(path)
	if err != nil {
		return reportStamp{}
	}
	st := reportStamp{present: true, mtime: fi.ModTime().UnixNano(), size: fi.Size()}
	if sys, ok := fi.Sys().(*syscall.Stat_t); ok {
		st.ino = sys.Ino
	}
	if b, err := os.ReadFile(path); err == nil {
		st.body = string(b)
	}
	return st
}

// grabWatch is a baseline of the grab report taken BEFORE the input whose
// resync it will wait for.
type grabWatch struct {
	display string
	base    reportStamp
}

// watchGrabs snapshots the report as it stands now. Call it before the
// injection, never after: the baseline is the whole point, and a baseline
// taken afterwards may already be the new report.
func watchGrabs(display string) *grabWatch {
	return &grabWatch{display: display, base: stampGrabReport(display)}
}

// baselineSet is the grab set the report DESCRIBED before the input this
// watch covers — the parsed form of the baseline. ok is false when there
// was no readable report then.
//
// # What settled() does NOT answer (dotfiles-ylmp.18)
//
// settled() answers a LATENCY question: has the report been published again
// since the baseline? That is sound, and it is all it claims. It is NOT an
// IDENTIFICATION: it does not show that the publication which landed is the
// one describing the layer the input entered.
//
// Both daemons publish the report from the single run loop, so a resync
// triggered BEFORE the baseline that has not written yet lands AFTER it,
// arrives as a fresh inode, and satisfies settled() while still describing
// the PREVIOUS layer. Measured, not theorised: with a 500 ms delay at the
// head of the Go daemon's publishGrabReport — well inside the sync envelope
// this file's header documents for the python engine, so a SLOWER daemon,
// not a broken one — the switcher section graded the DEFAULT layer's
// 70-chord report under the switcher's name in a fully green 80/0/0 run,
// while the switcher's own 87 chords were demonstrably grabbed.
//
// The cure is to compare CONTENT against what this run already saw before
// the transition, which is what this accessor is for: a report whose grab
// set the run had already read BEFORE entering the layer cannot be evidence
// about the layer it entered. Note that the baseline alone does not close
// it — under lag the baseline is itself a stale report from two transitions
// back (nav's, in the run above) and differs from the graded one. Every
// pre-transition reading has to be ruled out; see notAPriorReport.
//
// # Why not just stamp the report
//
// Same answer as this file's header: hotkeyd.py would have to write the
// same stamp or this suite stops grading the python engine, and running
// both engines through one suite is what made this race visible at all.
func (w *grabWatch) baselineSet() (proc.GrabReport, bool) {
	if !w.base.present {
		return proc.GrabReport{}, false
	}
	var r proc.GrabReport
	if err := json.Unmarshal([]byte(w.base.body), &r); err != nil {
		return proc.GrabReport{}, false
	}
	return r, true
}

// sameGrabSet reports whether two readings describe the SAME grab set —
// counts and refusals, deliberately not the pid stamp or the publication.
//
// This is the exact opposite of the question settled() asks, and both are
// needed: for LATENCY the write is the whole signal (an identical-content
// republish still proves a sync completed), while for IDENTIFICATION only
// the content can say which layer a report is about. Comparing publications
// here would make every late-landing stale report look new, which is
// dotfiles-ylmp.18. The pid is excluded because it is the same daemon
// either way — proc.CurrentGrabReport has already refused a report whose
// pid does not match the display's lock (adr0017).
func sameGrabSet(a, b proc.GrabReport) bool {
	if a.Wanted != b.Wanted || a.Active != b.Active || len(a.Missing) != len(b.Missing) {
		return false
	}
	for i := range a.Missing {
		if a.Missing[i] != b.Missing[i] {
			return false
		}
	}
	return true
}

// settled waits for the grab report to be published again (proof that a
// sync completed after the baseline) and then to go quiet.
//
// Returns false — with the reason — when no new publication arrived inside
// timeout, when the report never stopped moving, or when the report that
// did settle belongs to a different daemon than the one holding the
// display's lock (adr0017). Callers MUST treat false as a failed
// precondition and SKIP the claims that depend on the grab set: a claim
// graded against a grab set that was never observed to land is exactly the
// vacuity [[im009]] forbids.
func (w *grabWatch) settled(timeout time.Duration) (bool, string) {
	deadline := time.Now().Add(timeout)
	advanced := false
	last := w.base
	var quietSince time.Time

	for {
		cur := stampGrabReport(w.display)
		switch {
		case !advanced:
			if cur.present && cur != w.base {
				advanced, last, quietSince = true, cur, time.Now()
			}
		case cur != last:
			last, quietSince = cur, time.Now()
		case time.Since(quietSince) >= grabQuiet:
			report, ok := proc.CurrentGrabReport(w.display)
			if !ok {
				return false, "the settled grab report is not the live daemon's — its pid does not match the display's lock (adr0017)"
			}
			return true, describeReport(report, true)
		}

		if time.Now().After(deadline) {
			if !advanced {
				return false, fmt.Sprintf(
					"no NEW grab report was published within %s — the sidecar still holds the report from BEFORE this input (%s), "+
						"so nothing proves the layer's grab set was ever installed",
					timeout, describeStamp(w.base))
			}
			return false, fmt.Sprintf("the grab report was still changing after %s (last: %s)", timeout, describeStamp(last))
		}
		time.Sleep(grabPoll)
	}
}

func describeStamp(s reportStamp) string {
	if !s.present {
		return "no report at all"
	}
	return s.body
}
