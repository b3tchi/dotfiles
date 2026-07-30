// health.go implements `--health` (sp021 Task 13, bd dotfiles-ylmp.12): is
// this display's daemon SERVING, not merely alive? Ported from hotkeyd.py's
// health() (hotkeyd.py:1790-1890), honouring [[adr0017]]'s evidence table
// exactly -- see that ADR for the full reasoning; the short version is in
// each verdict's own doc below.
//
// Every verdict is checked by exactly ONE probe, in the order that makes
// the answer actionable (heartbeat -> display -> keyboard -> grab report),
// and the whole function is pure over an injected healthProbes -- no lock
// file, no X connection, no grab attempt happens inside health() itself,
// which is what lets health_test.go prove all six exit codes with
// fabricated states and zero Xvfb.
package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"hotkeyd/internal/proc"
	"hotkeyd/internal/x11"
)

// adr0017's --health exit codes. 0 keeps the shell idiom (`if hotkeyd
// --health`). Named exactly as hotkeyd.py's HEALTH_* constants so an
// operator reading either daemon's exit code gets the same answer.
const (
	HealthOK                 = 0
	HealthNotServing         = 6
	HealthDisplayUnreachable = 7
	HealthKeyboardGrabbed    = 8
	HealthDegraded           = 9
	HealthUnknown            = 10
)

// heartbeatStaleAfter is how old a lock's mtime may get before its daemon
// is considered to have stopped beating. Ported from hotkeyd.py's
// HEARTBEAT_STALE_S (5.0s) -- measured 4x the worst observed heartbeat gap
// under load (i3 IPC round trips included); re-measure before lowering it.
const heartbeatStaleAfter = 5 * time.Second

// displayProbeTimeout bounds how long the display-reachability probe waits
// for the server to answer -- a HUNG X server never closes the connection,
// so an unguarded read would block forever. Ported from hotkeyd.py's
// PROBE_TIMEOUT_S.
const displayProbeTimeout = 3 * time.Second

// grabProbeAttempts/grabProbeDelay: how many times the exclusive-grab probe
// asks before condemning, and how long it waits between asks. Ported from
// hotkeyd.py's GRAB_PROBE_ATTEMPTS/GRAB_PROBE_DELAY_S. Sized so the
// daemon's own passive grab, briefly promoted to an implicit ACTIVE grab
// while a chord is HELD, cannot survive three asks 300ms apart -- a
// locker's grab does.
const (
	grabProbeAttempts = 3
	grabProbeDelay    = 300 * time.Millisecond
)

// resolveDisplay applies the three-tier default every subcommand in this
// package shares: an explicit value (a --display flag or state-tail's
// positional arg) wins, then $DISPLAY, then ":0" -- matching hotkeyd.py's
// `display or os.environ.get("DISPLAY", ":0")` used throughout hotkeyd.py's
// health/lock/socket path helpers.
func resolveDisplay(display string) string {
	if display == "" {
		display = os.Getenv("DISPLAY")
	}
	if display == "" {
		display = ":0"
	}
	return display
}

// healthProbes is health's I/O seam set -- every place health() reaches
// outside itself (the lock file's mtime, the heartbeat marker, a live X
// display, an active keyboard grab, the grab-report sidecar). Overridable
// in tests to fabricate every adr0017 verdict without a real lock file,
// display, or grab attempt; defaultHealthProbes wires the real ones.
type healthProbes struct {
	statMTime    func(path string) (time.Time, error)
	hasHeartbeat func(path string) bool
	probeDisplay func(display string) (why string, unreachable bool)
	probeGrab    func(display string) (why string, grabbed bool)
	grabReport   func(display string) (*proc.GrabReport, bool)
}

// defaultHealthProbes wires healthProbes to the real filesystem, a real
// (bounded) X connection attempt, and proc.CurrentGrabReport -- the
// pid-valid reader (adr0017: "9 reads missing[] from a pid-valid grab
// report only"), never the raw proc.ReadGrabReport.
func defaultHealthProbes() healthProbes {
	return healthProbes{
		statMTime: func(path string) (time.Time, error) {
			fi, err := os.Stat(path)
			if err != nil {
				return time.Time{}, err
			}
			return fi.ModTime(), nil
		},
		hasHeartbeat: proc.HasHeartbeat,
		probeDisplay: probeDisplay,
		probeGrab:    probeKeyboardGrab,
		grabReport: func(display string) (*proc.GrabReport, bool) {
			return proc.CurrentGrabReport(display)
		},
	}
}

// runHealth is --health's production entry point.
func runHealth(display string) (int, string) {
	return health(display, defaultHealthProbes())
}

// health answers "is this display's daemon SERVING?" against p. Every
// branch below is one row of adr0017's evidence table, checked in the
// order that makes the answer actionable and named in each verdict's
// message -- a bare non-zero exit during an outage must not end the
// investigation.
func health(display string, p healthProbes) (int, string) {
	disp := resolveDisplay(display)
	lockPath := proc.LockPath(disp)

	// 1. THE HEARTBEAT -- has this display's run loop turned recently.
	// The one probe `pgrep` cannot answer: a frozen daemon still holds
	// its flock and matches every process pattern while serving nothing.
	mtime, err := p.statMTime(lockPath)
	if err != nil {
		return HealthNotServing, fmt.Sprintf(
			"hotkeyd: %s — NOT SERVING: no daemon has run here (no lock at %s)", disp, lockPath)
	}
	age := time.Since(mtime)
	if age > heartbeatStaleAfter {
		// ABSENCE IS NOT STALENESS (adr0017). A daemon of an older build
		// never touches its lock after creating it, so this age is its
		// UPTIME, not a missed beat -- the marker is what tells the two
		// apart. Without it the only true statement is "cannot
		// determine", which is verdict 10, never 6.
		if !p.hasHeartbeat(lockPath) {
			return HealthUnknown, fmt.Sprintf(
				"hotkeyd: %s — UNDETERMINED: this daemon does not beat, so its %.0fs-old "+
					"lock is its start time and not a missed heartbeat — it predates heartbeat "+
					"support (cannot determine whether it is serving). Restart it "+
					"(`hotkeyd.sh restart %s`) for a definite answer",
				disp, age.Seconds(), disp)
		}
		return HealthNotServing, fmt.Sprintf(
			"hotkeyd: %s — NOT SERVING: last heartbeat %.0fs ago (> %.0fs); the run loop has "+
				"stopped turning", disp, age.Seconds(), heartbeatStaleAfter.Seconds())
	}

	// 2. THE DISPLAY -- can a fresh client reach it at all. This is the
	// CALLER's own evidence about the display, never the daemon's: a
	// caller with no X authority (an ssh/tmux session) must not read as
	// a dead server (adr0017's boundary between 6 and 7).
	if why, unreachable := p.probeDisplay(disp); unreachable {
		return HealthDisplayUnreachable, fmt.Sprintf(
			"hotkeyd: %s — NOT SERVING: the display %s is unreachable — %s", disp, disp, why)
	}

	// 3. THE KEYBOARD ITSELF. Everything above can be true while not one
	// chord fires: an exclusive grab bypasses every PASSIVE grab on the
	// display, the daemon's and i3's alike. The cure is on the OTHER
	// client, so this must not read like the daemon's own failure and
	// must not point at a restart.
	if why, grabbed := p.probeGrab(disp); grabbed {
		return HealthKeyboardGrabbed, fmt.Sprintf(
			"hotkeyd: %s — NOT SERVING: %s. Every chord on %s is bypassed until it releases — "+
				"restarting the daemon cannot fix this. Usual holder: a LOCKED SCREEN (a "+
				"screensaver or locker grabs the keyboard by design), or a modal that took the "+
				"keyboard and never gave it back. X names no holder, so this is the whole answer "+
				"the protocol can give", disp, why, disp)
	}

	// 4. THE GRAB SET ITSELF, LAST on purpose: a stale heartbeat, an
	// unreachable display, and a foreign grab each EXPLAIN missing
	// grabs, and reporting the consequence over the cause sends the
	// operator to the wrong problem. ABSENCE IS NOT DAMAGE: a daemon
	// that has never published a report reads as OK, not degraded.
	if report, ok := p.grabReport(disp); ok && len(report.Missing) > 0 {
		n := len(report.Missing)
		shown := report.Missing
		suffix := ""
		if n > 6 {
			shown = report.Missing[:6]
			suffix = "…"
		}
		return HealthDegraded, fmt.Sprintf(
			"hotkeyd: %s — DEGRADED: %d of %d chords grabbed; missing: %s%s. The daemon is alive "+
				"and these binds are dead — `hotkeyd.sh restart %s` re-resolves them against the "+
				"current keymap", disp, report.Active, report.Wanted, strings.Join(shown, ", "), suffix, disp)
	}

	report, ok := p.grabReport(disp)
	suffix := ")"
	if ok {
		suffix = fmt.Sprintf(", %d chords grabbed)", report.Active)
	}
	return HealthOK, fmt.Sprintf(
		"hotkeyd: %s — serving (heartbeat %.1fs ago, display reachable, keyboard not grabbed "+
			"elsewhere%s", disp, age.Seconds(), suffix)
}

// -- real probes (production wiring for defaultHealthProbes) ---------------

// probeDisplay reports whether a fresh client can open disp right now, and
// if not, why. Bounded by displayProbeTimeout via a deadline on the raw
// connection -- a HUNG (as opposed to dead) X server never closes the
// socket, so an unbounded read would block forever. Ported from
// hotkeyd.py's probe_display, using internal/x11's connection-setup
// primitives directly (dial + auth + setup parse) rather than the full
// x11.Open/*Conn (which starts a read loop this short probe does not need
// and, more importantly, offers no way to bound with a deadline).
func probeDisplay(disp string) (why string, unreachable bool) {
	host, num, _, err := x11.ParseDisplay(disp)
	if err != nil {
		return err.Error(), true
	}
	if host != "" && host != "unix" {
		return fmt.Sprintf("remote displays are not supported (host=%q)", host), true
	}

	nc, err := x11.DialLocal(num)
	if err != nil {
		return err.Error(), true
	}
	defer nc.Close()

	if err := nc.SetDeadline(time.Now().Add(displayProbeTimeout)); err != nil {
		return err.Error(), true
	}

	authName, authData := probeCookie(num)
	req := x11.BuildSetupRequest(authName, authData)
	if _, err := nc.Write(req); err != nil {
		return err.Error(), true
	}
	if _, err := x11.ParseSetupResponse(nc); err != nil {
		return err.Error(), true
	}
	return "", false
}

// probeCookie resolves the same Xauthority cookie main.go's real daemon
// startup would use, best-effort: any failure to locate one is non-fatal
// here exactly as in x11.Open's own lookupCookie -- the server itself
// reports "Authorization required" via ParseSetupResponse if one was
// actually needed, which probeDisplay already surfaces as unreachable.
func probeCookie(displayNum int) (name string, data []byte) {
	path, err := x11.DefaultXauthorityPath()
	if err != nil {
		return "", nil
	}
	entries, err := x11.ReadXauthorityFile(path)
	if err != nil {
		return "", nil
	}
	hostname, err := os.Hostname()
	if err != nil {
		return "", nil
	}
	name, data, _, err = x11.FindCookie(entries, hostname, displayNum)
	if err != nil {
		return "", nil
	}
	return name, data
}

// probeKeyboardGrab reports whether some OTHER client currently holds an
// exclusive keyboard grab on disp. Ported from hotkeyd.py's
// probe_keyboard_grab: retries grabProbeAttempts times, grabProbeDelay
// apart, because the daemon's own passive grab briefly looks identical to
// a foreign grab while a chord is physically held -- a real keystroke
// cannot survive three asks 300ms apart, a locker's grab survives all of
// them. Silent (grabbed=false) when it cannot ask at all: a probe failure
// here must not be misread as the display-unreachable probe's job.
func probeKeyboardGrab(disp string) (why string, grabbed bool) {
	for i := 0; i < grabProbeAttempts; i++ {
		stillGrabbed, ok := grabAttempt(disp)
		if !ok || !stillGrabbed {
			return "", false
		}
		if i+1 < grabProbeAttempts {
			time.Sleep(grabProbeDelay)
		}
	}
	return fmt.Sprintf("another client holds an exclusive keyboard grab (%d probes, %.1fs apart, all AlreadyGrabbed)",
		grabProbeAttempts, grabProbeDelay.Seconds()), true
}

// grabAttempt opens a FRESH connection and tries to take the keyboard for
// itself, releasing immediately on success -- holding it would itself be
// the outage this probe must not cause. ok=false means the question could
// not be asked this round (connection failure, a non-terminal GrabStatus);
// the caller treats that the same as "not grabbed", matching hotkeyd.py's
// "silent when it cannot ask at all".
func grabAttempt(disp string) (stillGrabbed bool, ok bool) {
	conn, info, err := x11.Open(disp)
	if err != nil {
		return false, false
	}
	defer conn.Close()
	if len(info.Screens) == 0 {
		return false, false
	}
	root := info.Screens[0].Root

	status, err := conn.GrabKeyboard(root)
	if err != nil {
		return false, false
	}
	switch status {
	case x11.GrabStatusSuccess:
		_ = conn.UngrabKeyboard(0)
		return false, true
	case x11.GrabStatusAlreadyGrabbed:
		return true, true
	default:
		return false, false
	}
}
