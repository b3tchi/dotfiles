package main

import (
	"reflect"
	"strings"
	"testing"
)

// TestDisplayGuardRefusesLiveSessions is the safety instrument's own test.
// A guard that silently permits is worse than no guard, so the refusal is
// asserted directly rather than inferred from a run that happened not to
// crash.
func TestDisplayGuardRefusesLiveSessions(t *testing.T) {
	noEnv := func(string) string { return "" }
	for _, bad := range []string{"", "   ", ":0", ":1", ":10", ":10.0", ":40", ":52", ":59", "host:0", "60"} {
		if got, err := resolveTargetDisplay(bad, noEnv); err == nil {
			t.Errorf("display guard accepted %q (as %q); it must refuse anything below :%d", bad, got, lowestPrivateDisplay)
		}
	}
	for _, ok := range []string{":60", ":61", ":99", ":200"} {
		got, err := resolveTargetDisplay(ok, noEnv)
		if err != nil || got != ok {
			t.Errorf("display guard rejected legal rig %q: %v", ok, err)
		}
	}
}

func TestDisplayGuardOptOutIsNamedAndExplicit(t *testing.T) {
	env := func(k string) string {
		if k == unsafeDisplayEnv {
			return "1"
		}
		return ""
	}
	if _, err := resolveTargetDisplay(":10", env); err != nil {
		t.Fatalf("the named opt-out did not admit :10: %v", err)
	}
	// The opt-out must not admit an EMPTY display: "no display" is not a
	// display somebody meant to name.
	if _, err := resolveTargetDisplay("", env); err == nil {
		t.Fatal("the opt-out admitted an empty display; it must still be named explicitly")
	}
}

func TestSelfTestDisplayGuardPasses(t *testing.T) {
	if code := selfTestDisplayGuard(); code != 0 {
		t.Fatalf("the startup safety self-test failed with %d", code)
	}
}

func TestXdoChord(t *testing.T) {
	cases := []struct{ chord, mod, want string }{
		{"$mod+o", "Mod4", "super+o"},
		{"$mod+o", "Mod1", "alt+o"},
		{"$mod+Ctrl+1", "Mod4", "super+ctrl+1"},
		{"$mod+Shift+minus", "Mod4", "super+shift+minus"},
		{"Print", "Mod4", "Print"},
		{"$mod+Shift+Print", "Mod4", "super+shift+Print"},
		{"Ctrl+h", "Mod4", "ctrl+h"},
		{"Mod1+Left", "Mod4", "alt+Left"},
		{"ISO_Left_Tab", "Mod4", "ISO_Left_Tab"},
	}
	for _, c := range cases {
		got, err := XdoChord(c.chord, c.mod)
		if err != nil {
			t.Errorf("XdoChord(%q,%q): %v", c.chord, c.mod, err)
			continue
		}
		if got != c.want {
			t.Errorf("XdoChord(%q,%q) = %q, want %q", c.chord, c.mod, got, c.want)
		}
	}
	if _, err := XdoChord("Bogus+h", "Mod4"); err == nil {
		t.Error("XdoChord accepted an unknown modifier")
	}
}

func TestXdoChordWithoutDropsTheHoldModifier(t *testing.T) {
	got, err := XdoChordWithout("$mod+Tab", "Mod4", "$mod")
	if err != nil || got != "Tab" {
		t.Fatalf("XdoChordWithout($mod+Tab, $mod) = %q, %v; want \"Tab\"", got, err)
	}
	got, err = XdoChordWithout("$mod+Shift+Tab", "Mod4", "$mod")
	if err != nil || got != "shift+Tab" {
		t.Fatalf("XdoChordWithout = %q, %v; want \"shift+Tab\"", got, err)
	}
}

// TestTransitionParsingIsEngineNeutral is dotfiles-n0r4's trap, encoded.
// The two engines quote device= differently (python's !r gives single quotes,
// Go's %q gives double) and spell absence differently (None vs none). A
// harness that compared raw lines would report a divergence on EVERY
// transition. These two lines describe the same event and must compare equal.
func TestTransitionParsingIsEngineNeutral(t *testing.T) {
	goLine := `hotkeyd: transition layer=default->nav mod=none->none trigger=press:o keycode=32 mask=0x40 mods=Mod4 sourceid=5 device="Virtual core XTEST keyboard" held=Mod4 i3_mode=default`
	pyLine := `hotkeyd: transition layer=default->nav mod=none->none trigger=press:o keycode=32 mask=0x0040 mods=Mod4 sourceid=5 device='Virtual core XTEST keyboard' held=Mod4 i3_mode=default`

	tg, ok := parseTransition(goLine)
	if !ok {
		t.Fatal("the Go transition line did not parse")
	}
	tp, ok := parseTransition(pyLine)
	if !ok {
		t.Fatal("the python transition line did not parse")
	}
	if tg.Canon() != tp.Canon() {
		t.Fatalf("engine-neutral folding failed:\n  go: %s\n  py: %s", tg.Canon(), tp.Canon())
	}
	if !strings.Contains(tg.Canon(), "device=Virtual core XTEST keyboard") {
		t.Fatalf("device name was lost in folding: %s", tg.Canon())
	}
}

func TestTransitionFoldsAbsentFields(t *testing.T) {
	a, _ := parseTransition(`transition layer=nav->default mod=none->none trigger=none held=none i3_mode=None`)
	b, _ := parseTransition(`transition layer=nav->default mod=None->None trigger=none held=none i3_mode=none`)
	if a.Canon() != b.Canon() {
		t.Fatalf("none/None were not folded:\n  a: %s\n  b: %s", a.Canon(), b.Canon())
	}
}

// TestTransitionRealDifferenceStillShows guards against the folding above
// being so aggressive that it hides a genuine divergence.
func TestTransitionRealDifferenceStillShows(t *testing.T) {
	a, _ := parseTransition(`transition layer=default->nav mod=none->move trigger=press:h`)
	b, _ := parseTransition(`transition layer=default->nav mod=none->resize trigger=press:h`)
	if a.Canon() == b.Canon() {
		t.Fatal("two different sublayer outcomes folded to the same string")
	}
}

func TestSplitQuotedKeepsQuotedSpaces(t *testing.T) {
	got := splitQuoted(`a=1 b='two words' c="three  words" d=4`)
	want := []string{"a=1", "b='two words'", `c="three  words"`, "d=4"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("splitQuoted = %#v, want %#v", got, want)
	}
}

func TestParseGrabSummaryReadsBothEngines(t *testing.T) {
	for _, l := range []string{
		"hotkeyd: 70 chords grabbed on :61 via XI2 ($mod=Mod4)",
		"hotkeyd: 106 chords grabbed on :10 via XI2 ($mod=Mod1)",
	} {
		n, mod, ok := parseGrabSummary(l)
		if !ok || n == 0 || mod == "" {
			t.Fatalf("parseGrabSummary(%q) = %d,%q,%v", l, n, mod, ok)
		}
	}
	if _, _, ok := parseGrabSummary("hotkeyd: started"); ok {
		t.Fatal("parseGrabSummary matched a line that is not a grab summary")
	}
}

// TestRunTargetsAreDerivedFromTheTable checks the sandbox stub set is
// computed, not transcribed: a Run action naming a bare command must produce
// a stub on the sandbox PATH, and one naming ~/... must produce a stub at
// that path. A missed target means the daemon spawns the operator's real
// script.
func TestRunTargetsAreDerivedFromTheTable(t *testing.T) {
	d := &Dump{
		Binds: []DumpBind{
			{Chord: "$mod+d", Actions: []string{"run:~/.dotfiles/quickshell/qs-overlay.sh launcher"}},
			{Chord: "$mod+9", Actions: []string{"run:blurlock"}},
			{Chord: "$mod+u", Actions: []string{"cmd:border none"}},
		},
		Layers: map[string]DumpLayer{
			"system": {
				Binds: []DumpBind{{Chord: "l", Actions: []string{"run:i3exit lock"}}},
			},
			"switcher": {
				OnHoldRelease: []string{"run:~/.dotfiles/quickshell/qs-overlay.sh switcher-confirm"},
				OnExit:        []string{"run:~/.dotfiles/quickshell/qs-overlay.sh switcher-cancel"},
				Mods: map[string]DumpMod{
					"x": {Modifier: "Ctrl", Binds: []DumpBind{{Chord: "h", Actions: []string{"run:i3-scrot"}}}},
				},
			},
		},
	}
	got := d.RunTargets()
	want := []string{
		".dotfiles/quickshell/qs-overlay.sh",
		".local/bin/blurlock",
		".local/bin/i3-scrot",
		".local/bin/i3exit",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("RunTargets = %#v, want %#v", got, want)
	}
}

func TestRunTargetsFlagsUninterceptablePaths(t *testing.T) {
	d := &Dump{
		Binds:  []DumpBind{{Chord: "$mod+x", Actions: []string{"run:/usr/bin/something-real --wipe"}}},
		Layers: map[string]DumpLayer{},
	}
	got := d.RunTargets()
	if len(got) != 1 || !strings.HasPrefix(got[0], "ABS:") {
		t.Fatalf("an absolute Run target must be flagged so the run refuses; got %#v", got)
	}
}

// TestBuildPlanCoversTheWholeTable is the anti-stale-list check: the plan's
// size and content are a function of the dump, so a chord added to the table
// appears in the plan without anyone editing this harness.
func TestBuildPlanCoversTheWholeTable(t *testing.T) {
	d := &Dump{
		Binds: []DumpBind{
			{Chord: "$mod+o", Actions: []string{"enter:nav"}},
			{Chord: "$mod+u", Actions: []string{"cmd:border none"}},
		},
		Layers: map[string]DumpLayer{
			"nav": {
				Binds: []DumpBind{{Chord: "h", Actions: []string{"cmd:focus left"}}},
				Mods: map[string]DumpMod{
					"move":   {Modifier: "Ctrl", Binds: []DumpBind{{Chord: "h", Actions: []string{"cmd:move left"}}}},
					"resize": {Modifier: "Mod1", Binds: []DumpBind{{Chord: "h", Actions: []string{"cmd:resize shrink width"}}}},
				},
				ExitKeys: []string{"q", "Escape"},
			},
		},
	}
	plan, err := BuildPlan(d, "Mod4")
	if err != nil {
		t.Fatal(err)
	}
	ids := map[string]bool{}
	for _, tr := range plan {
		ids[tr.ID] = true
	}
	for _, want := range []string{
		"default|$mod+o", "default|$mod+u",
		"layer:nav|h",
		"layer:nav/move|Ctrl+h", "layer:nav/resize|Mod1+h",
		"layer:nav|exit:q", "layer:nav|exit:Escape",
		"precedence:nav|Ctrl+Mod1+h",
		"negative|$mod+F12",
	} {
		if !ids[want] {
			t.Errorf("plan is missing trial %q; ids=%v", want, keysOf(ids))
		}
	}
}

func TestBuildPlanRefusesALayerWithNoEntryChord(t *testing.T) {
	d := &Dump{
		Binds:  []DumpBind{{Chord: "$mod+u", Actions: []string{"cmd:border none"}}},
		Layers: map[string]DumpLayer{"nav": {Binds: []DumpBind{{Chord: "h"}}}},
	}
	if _, err := BuildPlan(d, "Mod4"); err == nil {
		t.Fatal("BuildPlan accepted a layer the table gives no way to enter")
	}
}

func keysOf(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// TestDiffTreatsRunActionsAsAMultisetButI3AsASequence encodes the measured
// fact that a Run action's position in the stub log is the kernel's
// scheduling order, not the engine's dispatch order (two detached /bin/sh
// processes race to append), while i3 commands go down one socket in order.
func TestDiffTreatsRunActionsAsAMultisetButI3AsASequence(t *testing.T) {
	plan := []Trial{{ID: "x", Group: "g", Chord: "c"}}
	mk := func(runs, i3 []string) *ArmResult {
		return &ArmResult{Trials: map[string]*TrialResult{
			"x": {ID: "x", Outcome: "dispatched", Runs: runs, I3: i3},
		}}
	}
	// Same two Run actions, opposite order: NOT a divergence.
	if d := Diff(plan, mk([]string{"a", "b"}, nil), mk([]string{"b", "a"}, nil)); len(d) != 0 {
		t.Fatalf("run-action order was reported as a divergence: %+v", d)
	}
	// A genuinely different Run action set IS a divergence.
	if d := Diff(plan, mk([]string{"a", "b"}, nil), mk([]string{"a", "c"}, nil)); len(d) == 0 {
		t.Fatal("a real Run-action difference was swallowed by the multiset comparison")
	}
	// i3 command order IS the engine's, so a reorder there IS a divergence.
	if d := Diff(plan, mk(nil, []string{"a", "b"}), mk(nil, []string{"b", "a"})); len(d) == 0 {
		t.Fatal("i3 command order was not compared as a sequence")
	}
}

// TestSilenceAuditNeedsEveryChannel: a null capture is only "the daemon was
// silent" when every channel was demonstrably alive at that moment.
func TestSilenceAuditNeedsEveryChannel(t *testing.T) {
	full := SilenceAudit{true, true, true, true, true}
	if !full.allGood() {
		t.Fatal("a fully-alive audit did not read as good")
	}
	for i := 0; i < 5; i++ {
		a := full
		switch i {
		case 0:
			a.InjectionReachedX = false
		case 1:
			a.ProxyAlive = false
		case 2:
			a.ActionLogReadable = false
		case 3:
			a.StateTailAlive = false
		case 4:
			a.DaemonAlive = false
		}
		if a.allGood() {
			t.Errorf("audit %d passed with a dead channel: %s", i, a)
		}
	}
}
