package main

// check_test.go covers `--check` (validate the compiled table headless,
// dwm model) and Dispatch's flag/subcommand routing (sp021 Task 13, bd
// dotfiles-ylmp.12).

import (
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/bind"
)

// captureStderr redirects os.Stderr to a pipe for the duration of f,
// returning f's result and everything written to stderr. Needed because
// runStateTailCmd/runHealth print straight to os.Stderr/os.Stdout rather
// than an injected writer (Dispatch's own signature is `[]string -> int`,
// matching main()'s os.Exit(Dispatch(...)) contract) -- this is the seam
// that lets a Dispatch-level test distinguish WHICH handler actually ran
// by its message text, not just its exit code (two different code paths
// can legitimately produce the same exit code for different reasons).
func captureStderr(t *testing.T, f func() int) (code int, stderr string) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %s", err)
	}
	orig := os.Stderr
	os.Stderr = w
	defer func() { os.Stderr = orig }()

	done := make(chan string, 1)
	go func() {
		buf, _ := io.ReadAll(r)
		done <- string(buf)
	}()

	code = f()
	w.Close()
	stderr = <-done
	return
}

// TestValidateAllResolutions_ValidTable_NoProblems proves --check validates
// under EVERY $mod resolution this repo runs on (us020 AC2's headless
// requirement), not just one -- a table valid under Mod4 but broken under
// Mod1 must still be refused.
func TestValidateAllResolutions_ValidTable_NoProblems(t *testing.T) {
	binds := []bind.Bind{{Chord: "$mod+a", Actions: []bind.Action{bind.Command("focus left")}}}
	if got := validateAllResolutions(binds, nil); len(got) != 0 {
		t.Fatalf("unexpected problems on a valid table: %v", got)
	}
}

// TestValidateAllResolutions_FaultyTable_NamesTheChord mirrors the design's
// "prints conflicts by name" requirement: a duplicate chord must appear in
// the problem text, not just increment a count.
func TestValidateAllResolutions_FaultyTable_NamesTheChord(t *testing.T) {
	binds := []bind.Bind{
		{Chord: "$mod+a", Actions: []bind.Action{bind.Command("focus left")}},
		{Chord: "$mod+a", Actions: []bind.Action{bind.Command("focus right")}},
	}
	problems := validateAllResolutions(binds, nil)
	if len(problems) == 0 {
		t.Fatal("want at least one problem for a duplicate chord, got none")
	}
	found := false
	for _, p := range problems {
		if strings.Contains(p, `"$mod+a"`) {
			found = true
		}
	}
	if !found {
		t.Errorf("no problem names the offending chord $mod+a: %v", problems)
	}
}

// TestValidateAllResolutions_ProblemOnlyUnderOneResolution proves the
// per-resolution loop actually runs BOTH passes: a table that only
// collides under one specific $mod resolution must still be caught, which
// a validator called just once (under the default) would miss.
func TestValidateAllResolutions_ProblemOnlyUnderOneResolution(t *testing.T) {
	// Mod1+a and $mod+a collide only when $mod resolves to Mod1.
	binds := []bind.Bind{
		{Chord: "Mod1+a", Actions: []bind.Action{bind.Command("focus left")}},
		{Chord: "$mod+a", Actions: []bind.Action{bind.Command("focus right")}},
	}
	problems := validateAllResolutions(binds, nil)
	if len(problems) == 0 {
		t.Fatal("want a problem under the Mod1 resolution, got none")
	}
}

// TestRunCheck_ShippedTable_OK proves --check accepts the real compiled
// table this binary ships (config.go's Binds/Layers) -- the same
// invariant config_test.go's TestValidatorOverRealTable_BothModResolutions
// pins at the bind.Validate layer; this proves it end-to-end through
// runCheck()'s own aggregation.
func TestRunCheck_ShippedTable_OK(t *testing.T) {
	if code := runCheck(); code != 0 {
		t.Fatalf("runCheck() on the shipped table = %d, want 0", code)
	}
}

// TestUsageText_NoBindsFlag_PointsAtGoBuild pins the design's dwm-model
// requirement verbatim: no --binds flag exists, and --help says so,
// pointing at `go build` as the replacement.
func TestUsageText_NoBindsFlag_PointsAtGoBuild(t *testing.T) {
	text := usageText()
	if !strings.Contains(text, "go build") {
		t.Errorf("usage text does not point at `go build`: %q", text)
	}
	if !strings.Contains(text, "--binds") {
		t.Errorf("usage text does not explain the ABSENCE of --binds: %q", text)
	}
	if strings.Contains(text, "--check ") && strings.Contains(text, "--binds") &&
		!strings.Contains(text, "no --binds") && !strings.Contains(text, "There is no --binds") {
		t.Errorf("usage text mentions --binds without saying it does not exist: %q", text)
	}
}

// TestDispatch_UnknownFlag_ReturnsTwo matches flag.ContinueOnError's
// contract elsewhere in this package (main.go's run()): an unparseable
// argv is exit 2, never a panic.
func TestDispatch_UnknownFlag_ReturnsTwo(t *testing.T) {
	if code := Dispatch([]string{"--this-flag-does-not-exist"}); code != 2 {
		t.Errorf("Dispatch with an unknown flag = %d, want 2", code)
	}
}

// TestDispatch_Help_ReturnsZero proves -h/--help is handled (prints usage,
// exits 0) rather than falling through to flag.ContinueOnError's default
// "flag provided but not defined" treatment.
func TestDispatch_Help_ReturnsZero(t *testing.T) {
	if code := Dispatch([]string{"--help"}); code != 0 {
		t.Errorf("Dispatch([--help]) = %d, want 0", code)
	}
}

// TestDispatch_Check_MatchesRunCheck proves --check is actually routed to
// runCheck() and not silently falling through to the daemon-start path
// (which would hang or fail very differently against this test's
// environment).
func TestDispatch_Check_MatchesRunCheck(t *testing.T) {
	if got, want := Dispatch([]string{"--check"}), runCheck(); got != want {
		t.Errorf("Dispatch([--check]) = %d, want %d (runCheck())", got, want)
	}
}

// TestDispatch_CheckSubcommand_NoOwnership_MatchesRunCheck proves the
// `check` subcommand with no --ownership flag behaves exactly like
// top-level --check (same underlying table validation).
func TestDispatch_CheckSubcommand_NoOwnership_MatchesRunCheck(t *testing.T) {
	if got, want := Dispatch([]string{"check"}), runCheck(); got != want {
		t.Errorf("Dispatch([check]) = %d, want %d (runCheck())", got, want)
	}
}

// TestDispatch_CheckSubcommand_UnknownFlag_ReturnsTwo proves the `check`
// subcommand owns its OWN flag set (registers --ownership) rather than
// silently accepting anything.
func TestDispatch_CheckSubcommand_UnknownFlag_ReturnsTwo(t *testing.T) {
	if code := Dispatch([]string{"check", "--this-flag-does-not-exist"}); code != 2 {
		t.Errorf("Dispatch([check, --bogus]) = %d, want 2", code)
	}
}

// TestDispatch_Health_RoutesToRunHealth proves --health is actually wired
// through Dispatch to runHealth(), not silently falling through to the
// daemon-start path (run()), which would behave completely differently (a
// real X connection attempt, potentially blocking) against argv=[--health].
// An isolated XDG_RUNTIME_DIR with no lock file guarantees a fast,
// deterministic verdict (6, "no daemon has run here") reachable with zero
// real X/i3 I/O, so this stays a fast unit test while still proving the
// routing line is load-bearing.
func TestDispatch_Health_RoutesToRunHealth(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	start := time.Now()
	code := Dispatch([]string{"--health", "--display", ":250"})
	elapsed := time.Since(start)

	if code != HealthNotServing {
		t.Fatalf("Dispatch([--health, --display, :250]) = %d, want %d (HealthNotServing, no lock present)", code, HealthNotServing)
	}
	if elapsed > 2*time.Second {
		t.Errorf("Dispatch([--health, ...]) took %s -- looks like it fell through to the daemon-start path instead of runHealth()", elapsed)
	}
}

// TestDispatch_StateTail_RoutesToStateTailCmd proves the "state-tail"
// leading argv token is actually routed to runStateTailCmd, not silently
// falling through to flag parsing.
//
// Exit code and elapsed time ALONE do not prove this: Go's flag package
// treats a leading non-flag argument ("state-tail") as the end of parsing
// and returns no error, so a Dispatch with the routing case DELETED falls
// through to `default: return run(argv)` with argv=["state-tail", ":251"]
// -- run()'s own FlagSet does the identical "stop at first non-flag arg,
// no error" thing, so it proceeds to x11.Open(defaultDisplay), which ALSO
// fails fast and returns 1 in a display-less test sandbox. That coincidence
// is exactly what let this mutant survive a code+elapsed-only check
// (confirmed by hand: deleting the routing case produced the same exit
// code 1, and only hung this test when the test happened to run somewhere
// with a live ambient $DISPLAY). The message text is what actually
// differs and is what this test pins: only runStateTailCmd's failure path
// says "state-tail: cannot connect to"; the daemon-start path's failure
// message (daemonLog, main.go) says "hotkeyd: cannot open display".
func TestDispatch_StateTail_RoutesToStateTailCmd(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	// Pin the ambient display to a DEAD one. The correct code path never
	// reads $DISPLAY at all (":251" is passed explicitly), so this cannot
	// weaken the assertions -- it bounds the FALLTHROUGH path instead. Two
	// reasons it must be here: (a) safety -- with the routing case deleted,
	// Dispatch reaches run() with display="" and would otherwise open the
	// DEVELOPER'S LIVE $DISPLAY and start a real daemon taking real grabs
	// on their session; (b) determinism -- on such a machine the mutant
	// HANGS (a started daemon never returns) instead of failing, so the
	// kill below only reads as a clean assertion failure once the ambient
	// display is guaranteed dead. :4242 is outside every display range this
	// repo's Xvfb helpers allocate from (200-2199, 6000-7999).
	t.Setenv("DISPLAY", ":4242")

	start := time.Now()
	code, stderr := captureStderr(t, func() int {
		return Dispatch([]string{"state-tail", ":251"})
	})
	elapsed := time.Since(start)

	if code != 1 {
		t.Fatalf("Dispatch([state-tail, :251]) = %d, want 1 (no socket present)", code)
	}
	if !strings.Contains(stderr, "state-tail: cannot connect to") {
		t.Fatalf("stderr does not carry state-tail's own failure message (looks like it fell through to the daemon-start path instead of runStateTailCmd()): %q", stderr)
	}
	if strings.Contains(stderr, "hotkeyd: cannot open display") {
		t.Fatalf("stderr carries the DAEMON-START failure message -- state-tail routing was bypassed: %q", stderr)
	}
	if elapsed > 2*time.Second {
		t.Errorf("Dispatch([state-tail, ...]) took %s -- looks like it fell through to the daemon-start path instead of runStateTailCmd()", elapsed)
	}
}
