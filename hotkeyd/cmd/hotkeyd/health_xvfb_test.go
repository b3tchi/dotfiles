package main

// health_xvfb_test.go is verdict 8's PRODUCTION probe path coverage --
// gap flagged by review: every committed health_test.go case drives
// health() against a FABRICATED healthProbes, which proves health()'s own
// branching but never actually exercises probeDisplay/probeKeyboardGrab/
// grabAttempt against a real X server. That path is the entire
// justification for internal/x11/grabkeyboard.go's existence (the
// deviation from this task's stated files_touched), so it needs its own
// evidence, not just an inference from the fabricated-probe tests.
//
// Mirrors internal/x11/xvfb_integration_test.go's own safe-house pattern:
// a PRIVATE display spun up by this test (never the ambient $DISPLAY --
// see profile.md's ban on touching real hardware in a unit test), skipped
// outright when Xvfb is not on PATH. Xvfb cannot be assumed present in
// every CI sandbox, so these are t.Skip, not t.Fatal, on a missing binary
// -- the fabricated-probe tests in health_test.go remain the tests that
// MUST run everywhere.
import (
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/proc"
	"hotkeyd/internal/x11"
)

// requireXvfbBinary skips the test if Xvfb is not on PATH.
func requireXvfbBinary(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("Xvfb"); err != nil {
		t.Skipf("Xvfb not available on PATH: %s", err)
	}
}

// pickPrivateXvfbDisplay returns a display number this test owns
// exclusively -- a high, randomised number well outside any display a
// real session on this machine would plausibly use (native :0, xrdp :10,
// this repo's own Xvfb integration suites use 200-2200), so a concurrent
// test run never collides with either a real session or another test's
// Xvfb instance.
func pickPrivateXvfbDisplay(t *testing.T) int {
	t.Helper()
	for attempt := 0; attempt < 50; attempt++ {
		n := 6000 + rand.Intn(2000)
		if _, err := os.Stat(x11.SocketPath(n)); err != nil {
			return n
		}
	}
	t.Fatal("could not find a free private display number")
	return 0
}

// startPrivateXvfb launches a private, unauthenticated Xvfb on dispNum and
// waits for its socket to appear, returning a cleanup func. Unauthenticated
// (no -auth) is deliberate and safe here: this display is private to the
// test (a random high number nothing else references) and torn down
// immediately after, unlike a real session's :0/:10.
func startPrivateXvfb(t *testing.T, dispNum int) (cleanup func()) {
	t.Helper()
	requireXvfbBinary(t)

	sockPath := x11.SocketPath(dispNum)
	cmd := exec.Command("Xvfb", fmt.Sprintf(":%d", dispNum), "-nolisten", "tcp", "-screen", "0", "320x240x24")
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting private Xvfb: %s", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(sockPath); err == nil {
			return func() {
				cmd.Process.Kill()
				cmd.Wait()
				os.Remove(sockPath)
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	cmd.Process.Kill()
	cmd.Wait()
	t.Fatalf("private Xvfb did not create its socket in time: %s", stderr.String())
	return nil
}

// TestProbeDisplay_Xvfb_LiveServerIsReachable proves probeDisplay's real
// dial+auth+setup path (not the fabricated healthProbes.probeDisplay seam)
// correctly reports a live, private Xvfb display as reachable.
func TestProbeDisplay_Xvfb_LiveServerIsReachable(t *testing.T) {
	n := pickPrivateXvfbDisplay(t)
	cleanup := startPrivateXvfb(t, n)
	defer cleanup()
	disp := fmt.Sprintf(":%d", n)

	why, unreachable := probeDisplay(disp)
	if unreachable {
		t.Fatalf("probeDisplay(%s) against a live private Xvfb reported unreachable: %s", disp, why)
	}
}

// TestProbeDisplay_DeadServer_ReportsUnreachable proves the real probe
// correctly reports a display NOTHING is listening on as unreachable --
// needs no Xvfb (no server at all is the point), so it is not gated on
// requireXvfbBinary.
func TestProbeDisplay_DeadServer_ReportsUnreachable(t *testing.T) {
	// A display number this test does not start any server on.
	n := pickPrivateXvfbDisplay(t)
	disp := fmt.Sprintf(":%d", n)

	why, unreachable := probeDisplay(disp)
	if !unreachable {
		t.Fatalf("probeDisplay(%s) against a dead display reported reachable", disp)
	}
	if why == "" {
		t.Error("probeDisplay reported unreachable with no reason text")
	}
}

// TestProbeKeyboardGrab_Xvfb_FreeThenExternallyHeld is verdict 8's core
// proof: probeKeyboardGrab (and beneath it, grabAttempt -- the function
// that actually calls the new internal/x11 GrabKeyboard/UngrabKeyboard
// requests) must report the keyboard free on an untouched private Xvfb,
// then correctly detect an EXCLUSIVE grab this test itself takes from a
// second, independent connection -- exactly the hwds.30 locked-screen
// shape adr0017 exists to catch.
//
// This is the test that directly kills a mutant flipping the
// GrabStatusAlreadyGrabbed case in grabAttempt (health.go) to read as
// "keyboard free": with the mutant, the second assertion below fails
// (grabbed comes back false against a keyboard this test is provably
// holding).
func TestProbeKeyboardGrab_Xvfb_FreeThenExternallyHeld(t *testing.T) {
	n := pickPrivateXvfbDisplay(t)
	cleanup := startPrivateXvfb(t, n)
	defer cleanup()
	disp := fmt.Sprintf(":%d", n)

	why, grabbed := probeKeyboardGrab(disp)
	if grabbed {
		t.Fatalf("probeKeyboardGrab reported grabbed on an untouched Xvfb: %s", why)
	}

	// Hold an exclusive grab ourselves, as a locked screen would, from a
	// SEPARATE connection (mirrors a different client owning it).
	conn, info, err := x11.Open(disp)
	if err != nil {
		t.Fatalf("x11.Open: %s", err)
	}
	defer conn.Close()
	if len(info.Screens) == 0 {
		t.Fatal("Xvfb setup reply has no screens")
	}
	root := info.Screens[0].Root
	status, err := conn.GrabKeyboard(root)
	if err != nil {
		t.Fatalf("GrabKeyboard: %s", err)
	}
	if status != x11.GrabStatusSuccess {
		t.Fatalf("GrabKeyboard status = %d, want GrabStatusSuccess (%d)", status, x11.GrabStatusSuccess)
	}

	why, grabbed = probeKeyboardGrab(disp)
	if !grabbed {
		t.Fatal("probeKeyboardGrab did NOT detect the externally-held exclusive grab -- verdict 8 would silently read as free")
	}
	if !strings.Contains(why, "AlreadyGrabbed") {
		t.Errorf("probeKeyboardGrab's reason does not name AlreadyGrabbed: %q", why)
	}
}

// TestRunHealth_Xvfb_OK_WithNoGrabHeld is runHealth() end-to-end (real
// lock file + real Xvfb, wired through defaultHealthProbes -- not a
// fabricated healthProbes) reaching verdict 0.
func TestRunHealth_Xvfb_OK_WithNoGrabHeld(t *testing.T) {
	n := pickPrivateXvfbDisplay(t)
	cleanup := startPrivateXvfb(t, n)
	defer cleanup()
	disp := fmt.Sprintf(":%d", n)

	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	lock, err := proc.AcquireLock(proc.LockPath(disp))
	if err != nil {
		t.Fatalf("AcquireLock: %s", err)
	}
	defer lock.Release()

	code, msg := runHealth(disp)
	if code != HealthOK {
		t.Fatalf("runHealth against a live, ungrabbed private Xvfb = %d, want %d: %s", code, HealthOK, msg)
	}
}

// TestRunHealth_Xvfb_KeyboardGrabbed is runHealth() end-to-end reaching
// verdict 8 through the REAL probe chain (defaultHealthProbes ->
// probeKeyboardGrab -> grabAttempt -> the new internal/x11 GrabKeyboard
// request), the single strongest piece of evidence that the
// files_touched deviation actually does what it was added for.
func TestRunHealth_Xvfb_KeyboardGrabbed(t *testing.T) {
	n := pickPrivateXvfbDisplay(t)
	cleanup := startPrivateXvfb(t, n)
	defer cleanup()
	disp := fmt.Sprintf(":%d", n)

	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	lock, err := proc.AcquireLock(proc.LockPath(disp))
	if err != nil {
		t.Fatalf("AcquireLock: %s", err)
	}
	defer lock.Release()

	conn, info, err := x11.Open(disp)
	if err != nil {
		t.Fatalf("x11.Open: %s", err)
	}
	defer conn.Close()
	if _, err := conn.GrabKeyboard(info.Screens[0].Root); err != nil {
		t.Fatalf("GrabKeyboard: %s", err)
	}

	code, msg := runHealth(disp)
	if code != HealthKeyboardGrabbed {
		t.Fatalf("runHealth with an externally-held exclusive grab = %d, want %d (HealthKeyboardGrabbed): %s", code, HealthKeyboardGrabbed, msg)
	}
}
