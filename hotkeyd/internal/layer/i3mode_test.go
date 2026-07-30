package layer

// python: test_layers.py lines 444-598 ("i3-mode arbitration" and
// "two modifiers at once").

import "testing"

func TestLayerEntryIsRefusedWhileI3IsInAMode(t *testing.T) {
	var logged []string
	e, pub, _ := buildEngine(engineOpts{log: func(m string) { logged = append(logged, m) }})
	e.SetI3Mode("resize")
	e.Handle(press("o", "Mod4"))
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("entered a layer whose keys i3's mode already owns: %+v", got)
	}
	if len(pub.lines) != 0 {
		t.Fatalf("published a layer it never actually took: %+v", pub.lines)
	}
	found := false
	for _, m := range logged {
		if contains(m, "resize") {
			found = true
		}
	}
	if !found {
		t.Fatalf("refusal must name the i3 mode; logged: %v", logged)
	}
}

func TestLayerEntryStillWorksWhileI3IsInTheDefaultMode(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.SetI3Mode("default")
	e.Handle(press("o", "Mod4"))
	if got := e.State(); got != (State{Layer: "nav"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "nav"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestI3EnteringAModeLeavesAnActiveLayerPublishingDefaultOnce(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	pub.lines = nil
	e.SetI3Mode("resize")
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "default"}) {
		t.Fatalf("expected exactly one default line, got %+v", pub.lines)
	}
}

func TestI3ForcingALayerExitLogsItWithNoTriggeringKey(t *testing.T) {
	var lines []string
	e, _, _ := buildEngine(engineOpts{log: func(m string) { lines = append(lines, m) }})
	e.Handle(xev(Press, "o", []string{"Mod4"}, 32, 0x40, "", 0))
	lines = nil
	e.SetI3Mode("resize")
	tr := transitions(lines)
	if len(tr) != 1 {
		t.Fatalf("lines: %v", lines)
	}
	if !contains(tr[0], "layer=nav->default") {
		t.Fatalf("line: %q", tr[0])
	}
	if !contains(tr[0], "trigger=none") {
		t.Fatalf("no key caused this; the log must not imply one: %q", tr[0])
	}
	if !contains(tr[0], "resize") {
		t.Fatalf("the note must name the i3 mode: %q", tr[0])
	}
}

func TestI3ModeTakeoverClearsAHeldSublayerToo(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	if got := e.State(); got != (State{Layer: "nav", Mod: "move"}) {
		t.Fatalf("state = %+v", got)
	}
	pub.lines = nil
	e.SetI3Mode("$mode_system")
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "default"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestALayerExitRacingAnI3ModeEntryPublishesOneDefaultLine(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	pub.lines = nil
	e.Handle(press("q"))  // user exits
	e.SetI3Mode("resize") // i3's event arrives just after
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "default"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestRepeatedModeEventsForTheSameModePublishNothingExtra(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.SetI3Mode("resize")
	e.SetI3Mode("resize")
	e.SetI3Mode("resize")
	if len(pub.lines) != 0 {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestLeavingTheI3ModeMakesTheLayerEnterableAgain(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.SetI3Mode("resize")
	e.Handle(press("o", "Mod4"))
	e.Handle(release("o", "Mod4"))
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
	e.SetI3Mode("default")
	e.Handle(press("o", "Mod4"))
	if e.State().Layer != "nav" {
		t.Fatalf("state = %+v", e.State())
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "nav"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestAnEmptyModeNameIsReadAsDefault(t *testing.T) {
	for _, name := range []string{"", "default"} {
		t.Run("name="+name, func(t *testing.T) {
			e, _, _ := defaultEngine()
			e.SetI3Mode(name)
			e.Handle(press("o", "Mod4"))
			if e.State().Layer != "nav" {
				t.Fatalf("%q blocked layer entry", name)
			}
		})
	}
}

func TestTheTwoOwnersNeverOverlapAcrossTheTransitionMatrix(t *testing.T) {
	e, _, _ := defaultEngine()
	type step struct{ kind, arg string }
	script := []step{
		{"i3", "resize"}, {"key", "o"}, {"i3", "default"}, {"key", "o"},
		{"i3", "$mode_system"}, {"i3", "default"}, {"key", "o"},
		{"key", "q"}, {"i3", "screenshot"}, {"key", "o"}, {"i3", "default"},
	}
	for _, s := range script {
		if s.kind == "i3" {
			e.SetI3Mode(s.arg)
		} else if s.arg == "o" {
			e.Handle(press(s.arg, "Mod4"))
		} else {
			e.Handle(press(s.arg))
		}
		both := e.I3Mode() != "default" && e.State().Layer != "default"
		if both {
			t.Fatalf("two active owners after %s %q: i3=%q daemon=%q",
				s.kind, s.arg, e.I3Mode(), e.State().Layer)
		}
	}
}

// -- two modifiers at once — deterministic precedence ---------------------

func TestTwoModifiersHeldResolveByDeclarationOrderDeterministically(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	e.Handle(press("Alt_L"))
	if e.State().Mod != "move" {
		t.Fatalf("mod = %q", e.State().Mod)
	}
	actionsEqual(t, e.Handle(press("h")), cmd("move left"))
}

func TestTwoModifiersReversePressOrderResolvesTheSameWay(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Alt_L"))
	e.Handle(press("Control_L"))
	if e.State().Mod != "move" {
		t.Fatalf("precedence depended on press order: mod = %q", e.State().Mod)
	}
}

func TestReleasingTheWinningModifierFallsBackToTheOther(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	e.Handle(press("Alt_L"))
	e.Handle(release("Control_L"))
	if e.State().Mod != "resize" {
		t.Fatalf("mod = %q", e.State().Mod)
	}
	actionsEqual(t, e.Handle(press("h")), cmd("resize shrink width 5 px or 5 ppt"))
}

// -- the 120 ms release fall-back (xrdp Shift synthesis) -------------------

func TestModifierWithAMissedReleaseClearsAfterTheGuardWindow(t *testing.T) {
	e, pub, clock := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	if e.State().Mod != "move" {
		t.Fatalf("mod = %q", e.State().Mod)
	}
	clock.Advance(200)
	e.Handle(press("h")) // unrelated event, mods no longer report Ctrl
	if e.State().Mod != "" {
		t.Fatalf("mod = %q, want none", e.State().Mod)
	}
	if last := pub.lines[len(pub.lines)-1]; last != (State{Layer: "nav"}) {
		t.Fatalf("last published: %+v", last)
	}
}

func TestModifierIsNotClearedInsideTheGuardWindow(t *testing.T) {
	e, _, clock := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	clock.Advance(50)
	e.Handle(press("h"))
	if e.State().Mod != "move" {
		t.Fatalf("mod = %q", e.State().Mod)
	}
	actionsEqual(t, e.Handle(press("j")), cmd("move down"))
}

func TestAnEventThatStillReportsTheModifierRefreshesTheGuard(t *testing.T) {
	e, _, clock := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	for i := 0; i < 5; i++ {
		clock.Advance(100)
		e.Handle(press("h", "Ctrl")) // still held per event state
	}
	if e.State().Mod != "move" {
		t.Fatalf("mod = %q", e.State().Mod)
	}
}

func TestExplicitReleaseBeatsTheGuardImmediately(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	e.Handle(release("Control_L"))
	if e.State().Mod != "" {
		t.Fatalf("mod = %q", e.State().Mod)
	}
}

// -- xrdp synthetic Shift churn mid-hold (task edge_cases, simulated
// event script) -------------------------------------------------------
//
// Not a literal python test (test_layers.py's guard-window tests above
// cover the general mechanism against nav's Ctrl sublayer). This scripts
// the SPECIFIC scenario the task names: "one press, two releases" —
// xrdp drops Shift to send a character mid-hold, so a genuinely-held Ctrl
// sees a burst of unrelated Shift release/press/release around a typed
// character while Ctrl itself is never mentioned. The Ctrl belief must
// survive the burst (Ctrl is corroborated on every event whose mods still
// carry it, and the burst events do carry it here — an accurate
// reproduction of "held modifiers ride along on unrelated key events").

func TestXRDPShiftChurnMidHoldDoesNotDropAnUnrelatedSublayer(t *testing.T) {
	e, _, clock := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	if e.State().Mod != "move" {
		t.Fatalf("mod = %q", e.State().Mod)
	}
	// xrdp's burst for one typed character: release Shift (spurious
	// leading, dotfiles-hwds.24 shape), press 'a', release 'a' — all
	// within the guard window, all still reporting Ctrl held per-event.
	clock.Advance(1)
	e.Handle(release("Shift_L", "Ctrl"))
	clock.Advance(1)
	e.Handle(press("a", "Ctrl"))
	clock.Advance(1)
	e.Handle(release("a", "Ctrl"))
	if e.State().Mod != "move" {
		t.Fatalf("Shift churn dropped the sublayer: mod = %q", e.State().Mod)
	}
}
