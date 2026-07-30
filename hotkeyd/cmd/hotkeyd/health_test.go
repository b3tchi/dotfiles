package main

// health_test.go is the verdict matrix test_plan calls for: one test per
// exit code, driven against health()'s injected healthProbes so every
// adr0017 branch is provable with a fabricated lock/report/probe state and
// zero Xvfb, zero real i3, zero real X server -- matching this package's
// existing seam-and-fake convention (daemon_test.go, grabs_test.go).

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/proc"
)

// writeFakeLock writes a lock file byte-identical in shape to what
// proc.AcquireLock produces -- pid on line 1, LockMarker on line 2 only
// when heartbeat is true (a build that predates the heartbeat never writes
// it).
func writeFakeLock(path string, pid int, heartbeat bool) error {
	content := fmt.Sprintf("%d\n", pid)
	if heartbeat {
		content += proc.LockMarker + "\n"
	}
	return os.WriteFile(path, []byte(content), 0o644)
}

// fixedProbes builds a healthProbes where every probe defaults to "all
// clear" (fresh heartbeat, display reachable, keyboard free, no grab
// report) -- each test overrides exactly the one seam it needs to reach
// its target verdict, so a passing test proves THAT branch, not an
// accidental combination.
func fixedProbes(now time.Time) healthProbes {
	return healthProbes{
		statMTime:    func(string) (time.Time, error) { return now, nil },
		hasHeartbeat: func(string) bool { return true },
		probeDisplay: func(string) (string, bool) { return "", false },
		probeGrab:    func(string) (string, bool) { return "", false },
		grabReport:   func(string) (*proc.GrabReport, bool) { return nil, false },
	}
}

// TestHealth_Verdict0_OK_NoGrabReport is the clean-bill case: fresh
// heartbeat, display answers, keyboard free, and no grab report at all
// (a daemon that predates the grab-report feature) -- adr0017: "ABSENCE IS
// NOT DAMAGE".
func TestHealth_Verdict0_OK_NoGrabReport(t *testing.T) {
	now := time.Now()
	code, msg := health(":0", fixedProbes(now))
	if code != HealthOK {
		t.Fatalf("code = %d, want HealthOK (%d): %s", code, HealthOK, msg)
	}
	if !strings.Contains(msg, "serving") {
		t.Errorf("message does not say serving: %q", msg)
	}
}

// TestHealth_Verdict0_OK_GrabReportFullyGrabbed proves a present-but-clean
// grab report (missing empty) still reads as OK, and its active count
// reaches the message.
func TestHealth_Verdict0_OK_GrabReportFullyGrabbed(t *testing.T) {
	now := time.Now()
	p := fixedProbes(now)
	p.grabReport = func(string) (*proc.GrabReport, bool) {
		return &proc.GrabReport{PID: 1, Wanted: 5, Active: 5, Missing: nil}, true
	}
	code, msg := health(":0", p)
	if code != HealthOK {
		t.Fatalf("code = %d, want HealthOK (%d): %s", code, HealthOK, msg)
	}
	if !strings.Contains(msg, "5") {
		t.Errorf("message does not name the active grab count: %q", msg)
	}
}

// TestHealth_Verdict6_NoLockAtAll: no daemon has ever run here -- the
// statMTime seam reports the lock file missing.
func TestHealth_Verdict6_NoLockAtAll(t *testing.T) {
	p := fixedProbes(time.Now())
	p.statMTime = func(string) (time.Time, error) { return time.Time{}, errors.New("no such file") }
	code, msg := health(":0", p)
	if code != HealthNotServing {
		t.Fatalf("code = %d, want HealthNotServing (%d): %s", code, HealthNotServing, msg)
	}
	if !strings.Contains(msg, "no daemon has run here") {
		t.Errorf("message does not name the probe that failed (no lock): %q", msg)
	}
}

// TestHealth_Verdict6_HeartbeatStopped is adr0017's ONLY reapable verdict:
// a build that DOES beat, whose lock is stale beyond the threshold -- the
// run loop's own evidence about itself.
func TestHealth_Verdict6_HeartbeatStopped(t *testing.T) {
	stale := time.Now().Add(-(heartbeatStaleAfter + time.Second))
	p := fixedProbes(stale)
	p.statMTime = func(string) (time.Time, error) { return stale, nil }
	p.hasHeartbeat = func(string) bool { return true }
	code, msg := health(":0", p)
	if code != HealthNotServing {
		t.Fatalf("code = %d, want HealthNotServing (%d): %s", code, HealthNotServing, msg)
	}
	if !strings.Contains(msg, "stopped turning") {
		t.Errorf("message does not name the probe that failed (heartbeat): %q", msg)
	}
}

// TestHealth_Verdict7_DeadXServer is the exact edge case the design names:
// a dead/unreachable display must read as 7, NOT 6 -- the CALLER's
// evidence about the display, never conflated with the daemon's own
// heartbeat evidence about itself.
func TestHealth_Verdict7_DeadXServer(t *testing.T) {
	p := fixedProbes(time.Now())
	p.probeDisplay = func(string) (string, bool) { return "connection refused", true }
	code, msg := health(":0", p)
	if code != HealthDisplayUnreachable {
		t.Fatalf("code = %d, want HealthDisplayUnreachable (%d): %s", code, HealthDisplayUnreachable, msg)
	}
	if !strings.Contains(msg, "connection refused") {
		t.Errorf("message does not name the probe that failed (display): %q", msg)
	}
	if strings.Contains(msg, "hotkeyd.sh restart") {
		t.Errorf("verdict 7 must print NO restart ADVICE (a hotkeyd.sh restart command) -- the cure is not here: %q", msg)
	}
}

// TestHealth_Verdict8_KeyboardGrabbedElsewhere: a locked screen holds an
// exclusive grab -- every passive grab (daemon's and i3's alike) is
// bypassed. Must print no restart advice: the cure is on the OTHER
// client.
func TestHealth_Verdict8_KeyboardGrabbedElsewhere(t *testing.T) {
	p := fixedProbes(time.Now())
	p.probeGrab = func(string) (string, bool) {
		return "another client holds an exclusive keyboard grab (3 probes, 0.3s apart, all AlreadyGrabbed)", true
	}
	code, msg := health(":0", p)
	if code != HealthKeyboardGrabbed {
		t.Fatalf("code = %d, want HealthKeyboardGrabbed (%d): %s", code, HealthKeyboardGrabbed, msg)
	}
	if !strings.Contains(msg, "AlreadyGrabbed") {
		t.Errorf("message does not name the probe that failed (grab): %q", msg)
	}
	if strings.Contains(msg, "hotkeyd.sh restart") {
		t.Errorf("verdict 8 must print NO restart ADVICE (a hotkeyd.sh restart command) -- the cure is on the other client: %q", msg)
	}
}

// TestHealth_ProbePrecedence_GrabBeforeGrabReport pins adr0017's ordering
// exactly: the exclusive-grab probe (8) is checked BEFORE the grab-report
// probe (9), deliberately -- "LAST on purpose" in health.go's own doc,
// because a foreign grab EXPLAINS missing chords and reporting the
// consequence (degraded) over the cause (grabbed) sends the operator to
// the wrong problem. Setting BOTH probeGrab=grabbed AND a non-empty
// missing[] at once is the only way to prove the ordering -- either
// verdict alone is individually correct in isolation, so a mutant that
// swapped the two checks would still pass every OTHER verdict test.
func TestHealth_ProbePrecedence_GrabBeforeGrabReport(t *testing.T) {
	p := fixedProbes(time.Now())
	p.probeGrab = func(string) (string, bool) {
		return "another client holds an exclusive keyboard grab (3 probes, 0.3s apart, all AlreadyGrabbed)", true
	}
	p.grabReport = func(string) (*proc.GrabReport, bool) {
		return &proc.GrabReport{PID: 99, Wanted: 10, Active: 0, Missing: []string{"$mod+q", "$mod+w"}}, true
	}
	code, msg := health(":0", p)
	if code != HealthKeyboardGrabbed {
		t.Fatalf("code = %d, want HealthKeyboardGrabbed (%d) -- the grab probe must win over a simultaneous degraded grab report: %s", code, HealthKeyboardGrabbed, msg)
	}
	if strings.Contains(msg, "DEGRADED") {
		t.Errorf("message reads as the DEGRADED verdict despite an exclusive grab also being present -- wrong probe order: %q", msg)
	}
}

// TestHealth_Verdict9_DegradedGrabReport: the daemon is alive, but its own
// last-published grab report names chords the table wants that are not
// currently held -- the cure IS a restart here (unlike 7/8), so the
// message should point at it.
func TestHealth_Verdict9_DegradedGrabReport(t *testing.T) {
	p := fixedProbes(time.Now())
	p.grabReport = func(string) (*proc.GrabReport, bool) {
		return &proc.GrabReport{PID: 99, Wanted: 10, Active: 8, Missing: []string{"$mod+q", "$mod+w"}}, true
	}
	code, msg := health(":0", p)
	if code != HealthDegraded {
		t.Fatalf("code = %d, want HealthDegraded (%d): %s", code, HealthDegraded, msg)
	}
	if !strings.Contains(msg, "$mod+q") || !strings.Contains(msg, "$mod+w") {
		t.Errorf("message does not name the missing chords: %q", msg)
	}
	if !strings.Contains(strings.ToLower(msg), "restart") {
		t.Errorf("verdict 9's cure IS a restart -- message should say so: %q", msg)
	}
}

// TestHealth_Verdict9_ReadsMissingFromPidValidReportOnly: a grab report
// whose pid does not match the live lock's pid is evidence about a
// DIFFERENT daemon and must be ignored -- adr0017's pid-mismatch
// protection. health() itself does not do the pid check (that lives in
// proc.CurrentGrabReport, exercised by TestDefaultHealthProbes_UsesPidValidGrabReport
// below); this test proves health() correctly falls through to OK when its
// grabReport seam reports "no report" exactly as a pid-mismatch would.
func TestHealth_Verdict9_ReadsMissingFromPidValidReportOnly(t *testing.T) {
	p := fixedProbes(time.Now())
	p.grabReport = func(string) (*proc.GrabReport, bool) { return nil, false } // mismatched pid -> "no evidence"
	code, _ := health(":0", p)
	if code != HealthOK {
		t.Fatalf("code = %d, want HealthOK (%d) when the grab report is not pid-valid", code, HealthOK)
	}
}

// TestHealth_Verdict10_PredatesHeartbeat: a stale lock with NO heartbeat
// marker is a daemon from before the heartbeat shipped -- its age is
// uptime, not a missed beat, and this must be distinct from verdict 6
// (adr0017: "I cannot tell" is its own verdict, never folded into "it is
// dead").
func TestHealth_Verdict10_PredatesHeartbeat(t *testing.T) {
	stale := time.Now().Add(-(heartbeatStaleAfter + time.Second))
	p := fixedProbes(stale)
	p.statMTime = func(string) (time.Time, error) { return stale, nil }
	p.hasHeartbeat = func(string) bool { return false }
	code, msg := health(":0", p)
	if code != HealthUnknown {
		t.Fatalf("code = %d, want HealthUnknown (%d): %s", code, HealthUnknown, msg)
	}
	if !strings.Contains(msg, "predates heartbeat") {
		t.Errorf("message does not name the probe that failed (no heartbeat marker): %q", msg)
	}
}

// TestHealth_EachVerdict_NamesItsOwnCode is a table-driven cross-check that
// every one of adr0017's six codes is reachable and DISTINCT -- a mutant
// that folded two verdicts onto the same exit code (the exact bug adr0017
// exists to prevent) fails this test even if every individual verdict test
// above still passes in isolation.
//
// "NoLock" is deliberately NOT one of these cases: it shares code 6 with
// "HeartbeatStopped" ON PURPOSE (both are HealthNotServing in
// hotkeyd.py's health() too -- "no daemon has ever run" and "its run loop
// stopped turning" are both simply "not serving"). That overlap is proven
// correct by TestHealth_Verdict6_NoLockAtAll above; folding it into THIS
// cross-check would make the test fail on correct behaviour.
func TestHealth_EachVerdict_NamesItsOwnCode(t *testing.T) {
	stale := time.Now().Add(-(heartbeatStaleAfter + time.Second))
	cases := []struct {
		name string
		p    func() healthProbes
		want int
	}{
		{"OK", func() healthProbes { return fixedProbes(time.Now()) }, HealthOK},
		{"HeartbeatStopped", func() healthProbes {
			p := fixedProbes(stale)
			p.statMTime = func(string) (time.Time, error) { return stale, nil }
			return p
		}, HealthNotServing},
		{"DisplayUnreachable", func() healthProbes {
			p := fixedProbes(time.Now())
			p.probeDisplay = func(string) (string, bool) { return "x", true }
			return p
		}, HealthDisplayUnreachable},
		{"KeyboardGrabbed", func() healthProbes {
			p := fixedProbes(time.Now())
			p.probeGrab = func(string) (string, bool) { return "x", true }
			return p
		}, HealthKeyboardGrabbed},
		{"Degraded", func() healthProbes {
			p := fixedProbes(time.Now())
			p.grabReport = func(string) (*proc.GrabReport, bool) {
				return &proc.GrabReport{Missing: []string{"x"}}, true
			}
			return p
		}, HealthDegraded},
		{"Unknown", func() healthProbes {
			p := fixedProbes(stale)
			p.statMTime = func(string) (time.Time, error) { return stale, nil }
			p.hasHeartbeat = func(string) bool { return false }
			return p
		}, HealthUnknown},
	}
	seen := map[int]string{}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			code, msg := health(":0", c.p())
			if code != c.want {
				t.Fatalf("code = %d, want %d: %s", code, c.want, msg)
			}
			if prev, ok := seen[code]; ok && prev != c.name {
				t.Fatalf("verdict code %d shared between %q and %q -- adr0017 requires distinct codes", code, prev, c.name)
			}
			seen[code] = c.name
		})
	}
}

// TestDefaultHealthProbes_UsesPidValidGrabReport pins the wiring success
// criterion "9 reads missing[] from a pid-valid grab report only": the
// production probe set must go through proc.CurrentGrabReport (which does
// the pid check), never the raw proc.ReadGrabReport.
func TestDefaultHealthProbes_UsesPidValidGrabReport(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	display := ":77"

	// A grab report on disk stamped with a pid that does NOT match the
	// lock file's pid -- evidence about a different, dead process.
	proc.WriteGrabReport(display, 5, 3, []string{"$mod+q"})

	lockPath := proc.LockPath(display)
	if err := writeFakeLock(lockPath, 999999, true); err != nil {
		t.Fatalf("seeding lock file: %s", err)
	}

	p := defaultHealthProbes()
	report, ok := p.grabReport(display)
	if ok {
		t.Fatalf("pid-mismatched report was NOT ignored: %+v", report)
	}
}

// TestResolveDisplay_FlagBeatsEnvBeatsDefault pins the three-tier default
// chain every subcommand in this package shares: an explicit value wins,
// then $DISPLAY, then ":0".
func TestResolveDisplay_FlagBeatsEnvBeatsDefault(t *testing.T) {
	t.Run("explicit value wins", func(t *testing.T) {
		t.Setenv("DISPLAY", ":9")
		if got := resolveDisplay(":5"); got != ":5" {
			t.Errorf("resolveDisplay(%q) = %q, want %q", ":5", got, ":5")
		}
	})
	t.Run("falls back to $DISPLAY", func(t *testing.T) {
		t.Setenv("DISPLAY", ":9")
		if got := resolveDisplay(""); got != ":9" {
			t.Errorf("resolveDisplay(\"\") = %q, want %q", got, ":9")
		}
	})
	t.Run("falls back to :0", func(t *testing.T) {
		t.Setenv("DISPLAY", "")
		if got := resolveDisplay(""); got != ":0" {
			t.Errorf("resolveDisplay(\"\") = %q, want %q", got, ":0")
		}
	})
}
