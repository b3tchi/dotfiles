package bind

import (
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// test helpers
// ---------------------------------------------------------------------------

func mustHaveProblemContaining(t *testing.T, problems []Problem, substr string) {
	t.Helper()
	for _, p := range problems {
		if strings.Contains(string(p), substr) {
			return
		}
	}
	t.Fatalf("expected a problem containing %q, got %d problems: %v", substr, len(problems), problems)
}

func mustBeEmpty(t *testing.T, problems []Problem) {
	t.Helper()
	if len(problems) != 0 {
		t.Fatalf("expected zero problems, got %d: %v", len(problems), problems)
	}
}

func mustHaveProblems(t *testing.T, problems []Problem) {
	t.Helper()
	if len(problems) == 0 {
		t.Fatalf("expected at least one problem, got zero")
	}
}

// noLayers is an empty layer table for tests that don't exercise layers.
func noLayers() map[string]Layer { return map[string]Layer{} }

// ---------------------------------------------------------------------------
// R01-R05: chord syntax errors, exercised via a bind chord (global scope)
// ---------------------------------------------------------------------------

func TestValidate_R01_EmptyChord(t *testing.T) {
	binds := []Bind{{Chord: "   ", Actions: []Action{Command("focus left")}}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "empty chord")
}

func TestValidate_R02_NoKeyAfterLastPlus(t *testing.T) {
	binds := []Bind{{Chord: "$mod+", Actions: []Action{Command("focus left")}}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "has no key after the last '+'")
}

func TestValidate_R03_BareKeycodeInsteadOfKeysym(t *testing.T) {
	binds := []Bind{{Chord: "$mod+105", Actions: []Action{Command("focus left")}}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "uses a keycode")
}

func TestValidate_R04_UnknownModifier(t *testing.T) {
	binds := []Bind{{Chord: "Xyzzy+q", Actions: []Action{Command("focus left")}}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "unknown modifier")
}

func TestValidate_R05_UnknownKeysym(t *testing.T) {
	binds := []Bind{{Chord: "$mod+Qwerty12345", Actions: []Action{Command("focus left")}}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "unknown keysym")
}

// ---------------------------------------------------------------------------
// R06: a layer/sublayer bind must be a bare keysym
// ---------------------------------------------------------------------------

func TestValidate_R06_LayerBindNotBare(t *testing.T) {
	layers := map[string]Layer{
		"nav": {
			Binds:    []Bind{{Chord: "$mod+h", Actions: []Action{Command("focus left")}}},
			ExitKeys: []string{"q"},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "must be BARE keysyms")
}

// ---------------------------------------------------------------------------
// R07a-e: RESERVED_CHORDS refuses the panic chord under every spelling
// ---------------------------------------------------------------------------

func TestValidate_R07a_ReservedPanicChord_ModTokenOnNativePass(t *testing.T) {
	binds := []Bind{{Chord: PanicChord, Actions: []Action{Command("noop")}}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "is the panic chord")
}

func TestValidate_R07b_ReservedPanicChord_ModTokenOnXrdpPass(t *testing.T) {
	binds := []Bind{{Chord: PanicChord, Actions: []Action{Command("noop")}}}
	p := Validate(binds, noLayers(), "Mod1")
	mustHaveProblemContaining(t, p, "is the panic chord")
}

func TestValidate_R07c_ReservedPanicChord_LiteralMod4(t *testing.T) {
	binds := []Bind{{Chord: "Mod4+Ctrl+Shift+r", Actions: []Action{Command("noop")}}}
	p := Validate(binds, noLayers(), "Mod1") // pass mod irrelevant: literal, not the token
	mustHaveProblemContaining(t, p, "is the panic chord")
}

func TestValidate_R07d_ReservedPanicChord_LiteralMod1(t *testing.T) {
	binds := []Bind{{Chord: "Mod1+Ctrl+Shift+r", Actions: []Action{Command("noop")}}}
	p := Validate(binds, noLayers(), "Mod4") // pass mod irrelevant: literal, not the token
	mustHaveProblemContaining(t, p, "is the panic chord")
}

func TestValidate_R07e_ReservedPanicChord_AliasFolded(t *testing.T) {
	binds := []Bind{{Chord: "Super+Control+Shift+r", Actions: []Action{Command("noop")}}}
	p := Validate(binds, noLayers(), "Mod1")
	mustHaveProblemContaining(t, p, "is the panic chord")
}

// ---------------------------------------------------------------------------
// R08a-e: duplicate detection, by scope
// ---------------------------------------------------------------------------

func TestValidate_R08a_DuplicateInGlobalTable(t *testing.T) {
	binds := []Bind{
		{Chord: "$mod+u", Actions: []Action{Command("a")}},
		{Chord: "Mod4+u", Actions: []Action{Command("b")}}, // same identity, literal spelling
	}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "duplicate binds double-fire")
}

func TestValidate_R08b_DuplicateWithinLayerOwnBinds(t *testing.T) {
	layers := map[string]Layer{
		"nav": {
			Binds: []Bind{
				{Chord: "h", Actions: []Action{Command("focus left")}},
				{Chord: "h", Actions: []Action{Command("focus right")}},
			},
			ExitKeys: []string{"q"},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "duplicate binds double-fire")
}

func TestValidate_R08c_DuplicateWithinOneSublayerOwnBinds(t *testing.T) {
	layers := map[string]Layer{
		"nav": {
			ExitKeys: []string{"q"},
			Mods: map[string]Mod{
				"move": {Modifier: "Ctrl", Binds: []Bind{
					{Chord: "h", Actions: []Action{Command("move left")}},
					{Chord: "h", Actions: []Action{Command("move right")}},
				}},
			},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "duplicate binds double-fire")
}

func TestValidate_R08d_DuplicateAcrossSublayerTables_SharedSeen(t *testing.T) {
	// Two DIFFERENTLY-LABELLED Mod sublayers whose Modifier resolves to the
	// SAME canonical modifier: the shared `seen` map that spans a layer's
	// own binds AND every one of its sublayer tables is what catches this.
	// Giving each sublayer scan a fresh map (deleting that sharing) would
	// let this table load.
	layers := map[string]Layer{
		"nav": {
			ExitKeys: []string{"q"},
			Mods: map[string]Mod{
				"move":    {Modifier: "Ctrl", Binds: []Bind{{Chord: "h", Actions: []Action{Command("move left")}}}},
				"control": {Modifier: "control", Binds: []Bind{{Chord: "h", Actions: []Action{Command("also move left")}}}},
			},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "duplicate binds double-fire")
}

func TestValidate_R08e_DuplicateSameDeviceScope(t *testing.T) {
	binds := []Bind{
		{Chord: "$mod+9", Actions: []Action{Command("a")}, Device: "AT Translated Set 2 keyboard"},
		{Chord: "$mod+9", Actions: []Action{Command("b")}, Device: "AT Translated Set 2 keyboard"},
	}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "duplicate binds double-fire")
}

// Positive companions to R08e, proving the NOT-a-duplicate guarantees
// ([[ft011]] api_surface, verbatim) rather than just the rejection side.

func TestValidate_Accept_DifferentDeviceScopeNotDuplicate(t *testing.T) {
	binds := []Bind{
		{Chord: "$mod+9", Actions: []Action{Command("a")}, Device: "AT Translated Set 2 keyboard"},
		{Chord: "$mod+9", Actions: []Action{Command("b")}, Device: "BlueZ"},
	}
	p := Validate(binds, noLayers(), "Mod4")
	mustBeEmpty(t, p)
}

func TestValidate_Accept_DifferentOnReleaseNotDuplicate(t *testing.T) {
	binds := []Bind{
		{Chord: "$mod+Print", Actions: []Action{Command("a")}, OnRelease: false},
		{Chord: "$mod+Print", Actions: []Action{Command("b")}, OnRelease: true},
	}
	p := Validate(binds, noLayers(), "Mod4")
	mustBeEmpty(t, p)
}

func TestValidate_Accept_DifferentDisplayQualifierNotDuplicate(t *testing.T) {
	// The us020 shape: an unqualified chord and a literal-different-mod
	// chord that resolves to the SAME identity only on the display the
	// qualified bind excludes itself from.
	binds := []Bind{
		{Chord: "$mod+Tab", Actions: []Action{Command("switch")}}, // unqualified: every display
		{Chord: "Mod1+Tab", Actions: []Action{Command("alt-tab-app-meaning")}, DisplayMod: "Mod4"},
	}
	// On the xrdp pass ($mod resolves to Mod1), $mod+Tab becomes Mod1+Tab —
	// SAME identity as the literal bind — but the literal bind is scoped to
	// Mod4 only, so it is not active on this pass and must not collide.
	p := Validate(binds, noLayers(), "Mod1")
	mustBeEmpty(t, p)
}

// ---------------------------------------------------------------------------
// R09-R11: action/command problems
// ---------------------------------------------------------------------------

func TestValidate_R09_EmptyActionTuple(t *testing.T) {
	binds := []Bind{{Chord: "$mod+q", Actions: nil}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "has an empty action tuple")
}

func TestValidate_R10_EmptyStringCommand(t *testing.T) {
	binds := []Bind{{Chord: "$mod+q", Actions: []Action{Command("   ")}}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "has an empty command")
}

func TestValidate_R11_EmptyRunCommand(t *testing.T) {
	binds := []Bind{{Chord: "$mod+q", Actions: []Action{Run{Cmd: "   "}}}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "has an empty run() command")
}

// ---------------------------------------------------------------------------
// R12: device scope shape
// ---------------------------------------------------------------------------

func TestValidate_R12_BlankDevice(t *testing.T) {
	binds := []Bind{{Chord: "$mod+q", Actions: []Action{Command("x")}, Device: "   "}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "blank device=")
}

// ---------------------------------------------------------------------------
// R13: EnterLayer target must exist
// ---------------------------------------------------------------------------

func TestValidate_R13_EnterLayerTargetMissing(t *testing.T) {
	binds := []Bind{{Chord: "$mod+o", Actions: []Action{EnterLayer{Layer: "ghost"}}}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "which does not exist")
}

// ---------------------------------------------------------------------------
// R14-R18: hold-layer declaration problems
// ---------------------------------------------------------------------------

func TestValidate_R14_OnHoldReleaseWithNoHoldModifier(t *testing.T) {
	layers := map[string]Layer{
		"switcher": {
			ExitKeys:      []string{"q"},
			OnHoldRelease: []Action{Command("confirm")},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "on_hold_release is declared with no hold modifier")
}

func TestValidate_R15_UnknownHoldModifier(t *testing.T) {
	layers := map[string]Layer{
		"switcher": {ExitKeys: []string{"q"}, Hold: "bogus"},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "unknown hold modifier")
}

func TestValidate_R16_HoldModifierResolvesToShift(t *testing.T) {
	layers := map[string]Layer{
		"switcher": {ExitKeys: []string{"q"}, Hold: "Shift"},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "resolves to Shift")
}

func TestValidate_R17_HoldReleaseEmptyStringCommand(t *testing.T) {
	layers := map[string]Layer{
		"switcher": {
			ExitKeys:      []string{"q"},
			Hold:          "Ctrl",
			OnHoldRelease: []Action{Command("   ")},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "on_hold_release has an empty command")
}

func TestValidate_R18_HoldReleaseEmptyRunCommand(t *testing.T) {
	layers := map[string]Layer{
		"switcher": {
			ExitKeys:      []string{"q"},
			Hold:          "Ctrl",
			OnHoldRelease: []Action{Run{Cmd: "   "}},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "on_hold_release has an empty run() command")
}

// ---------------------------------------------------------------------------
// R19: unknown Mod sublayer modifier
// ---------------------------------------------------------------------------

func TestValidate_R19_UnknownSublayerModifier(t *testing.T) {
	layers := map[string]Layer{
		"nav": {
			ExitKeys: []string{"q"},
			Mods: map[string]Mod{
				"move": {Modifier: "bogus", Binds: []Bind{{Chord: "h", Actions: []Action{Command("move left")}}}},
			},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "unknown modifier")
}

// ---------------------------------------------------------------------------
// R20: a layer with no exit keys could never be left
// ---------------------------------------------------------------------------

func TestValidate_R20_LayerHasNoExitKeys(t *testing.T) {
	layers := map[string]Layer{
		"nav": {Binds: []Bind{{Chord: "h", Actions: []Action{Command("focus left")}}}},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "has no exit_keys")
}

// ---------------------------------------------------------------------------
// R21-R25: exit key chord syntax errors (a separate code path from R01-R05)
// ---------------------------------------------------------------------------

func TestValidate_R21_ExitKeyEmpty(t *testing.T) {
	layers := map[string]Layer{"nav": {ExitKeys: []string{"   "}}}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "exit key: empty chord")
}

func TestValidate_R22_ExitKeyNoKeyAfterLastPlus(t *testing.T) {
	layers := map[string]Layer{"nav": {ExitKeys: []string{"Ctrl+"}}}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "exit key: chord")
	mustHaveProblemContaining(t, p, "has no key after the last '+'")
}

func TestValidate_R23_ExitKeyBareKeycode(t *testing.T) {
	layers := map[string]Layer{"nav": {ExitKeys: []string{"105"}}}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "exit key: chord")
	mustHaveProblemContaining(t, p, "uses a keycode")
}

func TestValidate_R24_ExitKeyUnknownModifier(t *testing.T) {
	layers := map[string]Layer{"nav": {ExitKeys: []string{"Xyzzy+q"}}}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "exit key: chord")
	mustHaveProblemContaining(t, p, "unknown modifier")
}

func TestValidate_R25_ExitKeyUnknownKeysym(t *testing.T) {
	layers := map[string]Layer{"nav": {ExitKeys: []string{"Qwerty12345"}}}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "exit key: chord")
	mustHaveProblemContaining(t, p, "unknown keysym")
}

// ---------------------------------------------------------------------------
// R26: exit key must be a bare keysym
// ---------------------------------------------------------------------------

func TestValidate_R26_ExitKeyCarriesModifiers(t *testing.T) {
	layers := map[string]Layer{"nav": {ExitKeys: []string{"Ctrl+q"}}}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "exit keys are BARE keysyms")
}

// ---------------------------------------------------------------------------
// R27: unknown display qualifier (new in this package — no binds.py site)
// ---------------------------------------------------------------------------

func TestValidate_R27_UnknownDisplayQualifier(t *testing.T) {
	binds := []Bind{{Chord: "$mod+q", Actions: []Action{Command("x")}, DisplayMod: "bogus"}}
	p := Validate(binds, noLayers(), "Mod4")
	mustHaveProblemContaining(t, p, "unknown display qualifier")
}

// Positive companion: an unqualified bind behaves exactly as today (us020
// AC5) — no problem, no special casing, on every pass.
func TestValidate_Accept_UnqualifiedBindBehavesAsToday(t *testing.T) {
	binds := []Bind{{Chord: "$mod+q", Actions: []Action{Command("x")}}}
	mustBeEmpty(t, Validate(binds, noLayers(), "Mod4"))
	mustBeEmpty(t, Validate(binds, noLayers(), "Mod1"))
}

// Edge case named explicitly in the task: display qualifier combined with
// device scope on one bind must validate cleanly.
func TestValidate_Accept_DisplayQualifierCombinedWithDeviceScope(t *testing.T) {
	binds := []Bind{{
		Chord:      "Mod1+w",
		Actions:    []Action{Command("noop")},
		Device:     "AT Translated Set 2 keyboard",
		DisplayMod: "Mod4",
	}}
	mustBeEmpty(t, Validate(binds, noLayers(), "Mod4"))
	mustBeEmpty(t, Validate(binds, noLayers(), "Mod1"))
}

// A display-qualified bind must not be able to dodge RESERVED_CHORDS by
// scoping itself to a display the caller isn't currently validating.
func TestValidate_DisplayQualifiedBindCannotEvadeReservedChords(t *testing.T) {
	binds := []Bind{{Chord: PanicChord, Actions: []Action{Command("steal it")}, DisplayMod: "Mod1"}}
	p := Validate(binds, noLayers(), "Mod4") // validating the OTHER display
	mustHaveProblemContaining(t, p, "is the panic chord")
}

// ---------------------------------------------------------------------------
// R28a-g: an External layer declares NOTHING but the flag — every
// behavioral field is refused by name, naming the layer AND the offending
// field (sp023 Task 1, bd dotfiles-1m4t.1, plan decision 1).
// ---------------------------------------------------------------------------

func TestValidate_R28a_ExternalLayerDeclaresBinds(t *testing.T) {
	layers := map[string]Layer{
		"screenshot-drag": {
			External: true,
			Binds:    []Bind{{Chord: "h", Actions: []Action{Command("focus left")}}},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, `layer "screenshot-drag"`)
	mustHaveProblemContaining(t, p, "Binds")
}

func TestValidate_R28b_ExternalLayerDeclaresMods(t *testing.T) {
	layers := map[string]Layer{
		"screenshot-drag": {
			External: true,
			Mods: map[string]Mod{
				"move": {Modifier: "Ctrl", Binds: []Bind{{Chord: "h", Actions: []Action{Command("move left")}}}},
			},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, `layer "screenshot-drag"`)
	mustHaveProblemContaining(t, p, "Mods")
}

func TestValidate_R28c_ExternalLayerDeclaresExitKeys(t *testing.T) {
	layers := map[string]Layer{
		"screenshot-drag": {External: true, ExitKeys: []string{"q"}},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, `layer "screenshot-drag"`)
	mustHaveProblemContaining(t, p, "ExitKeys")
}

func TestValidate_R28d_ExternalLayerDeclaresOneShot(t *testing.T) {
	layers := map[string]Layer{
		"screenshot-drag": {External: true, OneShot: true},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, `layer "screenshot-drag"`)
	mustHaveProblemContaining(t, p, "OneShot")
}

func TestValidate_R28e_ExternalLayerDeclaresHold(t *testing.T) {
	// Named explicitly in the task's edge_cases: an external hold layer
	// would contradict adr0016's ask-the-server lifetime, and the message
	// must name Hold specifically (not a generic "behavioral field").
	layers := map[string]Layer{
		"screenshot-drag": {External: true, Hold: "Ctrl"},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, `layer "screenshot-drag"`)
	mustHaveProblemContaining(t, p, "Hold")
}

func TestValidate_R28f_ExternalLayerDeclaresOnHoldRelease(t *testing.T) {
	layers := map[string]Layer{
		"screenshot-drag": {
			External:      true,
			OnHoldRelease: []Action{Command("confirm")},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, `layer "screenshot-drag"`)
	mustHaveProblemContaining(t, p, "OnHoldRelease")
}

func TestValidate_R28g_ExternalLayerDeclaresOnExit(t *testing.T) {
	layers := map[string]Layer{
		"screenshot-drag": {
			External: true,
			OnExit:   []Action{Command("cleanup")},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, `layer "screenshot-drag"`)
	mustHaveProblemContaining(t, p, "OnExit")
}

// ---------------------------------------------------------------------------
// R20 exemption: External layers never need ExitKeys — asserted in BOTH
// directions so the exemption cannot silently widen to all layers (the
// task's own mutation-check instruction).
// ---------------------------------------------------------------------------

func TestValidate_Accept_ExternalLayerBareIsExemptFromR20(t *testing.T) {
	layers := map[string]Layer{
		"screenshot-drag": {External: true},
	}
	mustBeEmpty(t, Validate(nil, layers, "Mod4"))
}

func TestValidate_R20_IdenticalShapeWithoutExternalStillTripsR20(t *testing.T) {
	// The mutation twin: same bare layer shape, minus the flag. If this
	// ever stops failing R20, the exemption silently widened to every
	// layer instead of staying scoped to External.
	layers := map[string]Layer{
		"screenshot-drag": {},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "has no exit_keys")
}

// ---------------------------------------------------------------------------
// R29: an EnterLayer action cannot target an External layer — external
// layers are set-layer-only, chord layers stay chord-only (plan decision 3,
// compile-time half).
// ---------------------------------------------------------------------------

func TestValidate_R29_EnterLayerTargetsExternalLayer(t *testing.T) {
	binds := []Bind{{Chord: "$mod+d", Actions: []Action{EnterLayer{Layer: "screenshot-drag"}}}}
	layers := map[string]Layer{
		"screenshot-drag": {External: true},
	}
	p := Validate(binds, layers, "Mod4")
	mustHaveProblemContaining(t, p, `enters layer "screenshot-drag"`)
	mustHaveProblemContaining(t, p, "External")
}

func TestValidate_EnterLayerTable_ExternalRefused_PersistentAccepted(t *testing.T) {
	cases := []struct {
		name       string
		layerName  string
		layer      Layer
		wantProb   bool
		wantSubstr string
	}{
		{
			name:       "external target refused",
			layerName:  "screenshot-drag",
			layer:      Layer{External: true},
			wantProb:   true,
			wantSubstr: "External",
		},
		{
			name:      "persistent target accepted",
			layerName: "nav",
			layer: Layer{
				Binds:    []Bind{{Chord: "h", Actions: []Action{Command("focus left")}}},
				ExitKeys: []string{"q"},
			},
			wantProb: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			binds := []Bind{{Chord: "$mod+d", Actions: []Action{EnterLayer{Layer: tc.layerName}}}}
			layers := map[string]Layer{tc.layerName: tc.layer}
			p := Validate(binds, layers, "Mod4")
			if tc.wantProb {
				mustHaveProblems(t, p)
				mustHaveProblemContaining(t, p, tc.wantSubstr)
			} else {
				mustBeEmpty(t, p)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// R30: a layer named "default" declaring External is refused — the clear
// verb ("set-layer default") must stay unambiguous.
// ---------------------------------------------------------------------------

func TestValidate_R30_DefaultNamedLayerDeclaresExternal(t *testing.T) {
	layers := map[string]Layer{
		"default": {External: true},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, `"default"`)
	mustHaveProblemContaining(t, p, "External")
}

// ---------------------------------------------------------------------------
// Edge case: an External layer that no bind references at all is VALID —
// reachability comes from the set-layer verb, not a chord.
// ---------------------------------------------------------------------------

func TestValidate_Accept_ExternalLayerWithNoReferencingBindIsValid(t *testing.T) {
	layers := map[string]Layer{
		"screenshot-drag": {External: true},
	}
	mustBeEmpty(t, Validate(nil, layers, "Mod4"))
}

// Rule messages must be identical under BOTH $mod resolutions — the
// validator runs per resolution in --check, and a resolution-dependent
// refusal message would leak which display produced it.
func TestValidate_NewExternalRules_SameMessageUnderBothModResolutions(t *testing.T) {
	binds := []Bind{{Chord: "$mod+d", Actions: []Action{EnterLayer{Layer: "screenshot-drag"}}}}
	layers := map[string]Layer{
		"screenshot-drag": {External: true, Hold: "Ctrl"},
		"default":         {External: true},
	}
	p4 := Validate(binds, layers, "Mod4")
	p1 := Validate(binds, layers, "Mod1")
	if len(p4) != len(p1) {
		t.Fatalf("problem count differs across resolutions: Mod4=%d Mod1=%d", len(p4), len(p1))
	}
	for i := range p4 {
		if p4[i] != p1[i] {
			t.Fatalf("problem %d differs across resolutions:\nMod4: %s\nMod1: %s", i, p4[i], p1[i])
		}
	}
}

// ---------------------------------------------------------------------------
// Edge case: chord referencing a layer that does not exist, from a LAYER's
// own binds (not just the global table) — EnterLayer target checking is
// shared code (scan), but this proves it fires from within a layer too.
// ---------------------------------------------------------------------------

func TestValidate_EnterLayerTargetMissing_FromWithinALayer(t *testing.T) {
	layers := map[string]Layer{
		"nav": {
			Binds:    []Bind{{Chord: "o", Actions: []Action{EnterLayer{Layer: "ghost"}}}},
			ExitKeys: []string{"q"},
		},
	}
	p := Validate(nil, layers, "Mod4")
	mustHaveProblemContaining(t, p, "which does not exist")
}

// ---------------------------------------------------------------------------
// Property-style test: the full shipped table shape validates clean, and
// every single-field mutation of it is rejected.
// ---------------------------------------------------------------------------

// goodShippedTable returns a fresh, valid table mirroring binds.py's real
// shape: global binds (plain command, run, device scope, display-qualified
// literal, on_release, layer verbs, a tuple action), a persistent layer with
// two Mod sublayers, a one-shot layer, and a hold layer with on_hold_release
// and on_exit. Returned fresh on every call so mutation tests never share
// state with each other or with the acceptance test.
func goodShippedTable() ([]Bind, map[string]Layer) {
	binds := []Bind{
		{Chord: "$mod+o", Actions: []Action{EnterLayer{Layer: "nav"}}},
		{Chord: "$mod+Return", Actions: []Action{Run{Cmd: "wm-launch-terminal st"}}},
		{Chord: "$mod+u", Actions: []Action{Command("border none")}},
		{Chord: "$mod+9", Actions: []Action{Run{Cmd: "blurlock"}}, Device: "AT Translated Set 2 keyboard"},
		{Chord: "Mod1+w", Actions: []Action{Command("noop")}, DisplayMod: "Mod4"},
		{Chord: "$mod+Print", Actions: []Action{Run{Cmd: "i3-scrot -w"}}, OnRelease: true},
		{Chord: "$mod+0", Actions: []Action{EnterLayer{Layer: "system"}}},
		{Chord: "$mod+r", Actions: []Action{EnterLayer{Layer: "resize"}}},
		{Chord: "$mod+Tab", Actions: []Action{Run{Cmd: "overlay switcher"}, EnterLayer{Layer: "switcher"}}},
	}

	layers := map[string]Layer{
		"nav": {
			Binds: []Bind{
				{Chord: "h", Actions: []Action{Command("focus left")}},
				{Chord: "l", Actions: []Action{Command("focus right")}},
			},
			Mods: map[string]Mod{
				"move":   {Modifier: "Ctrl", Binds: []Bind{{Chord: "h", Actions: []Action{Command("move left")}}}},
				"resize": {Modifier: "Mod1", Binds: []Bind{{Chord: "h", Actions: []Action{Command("resize shrink width 5px")}}}},
			},
			ExitKeys: []string{"q", "Escape", "Return"},
		},
		"resize": {
			Binds:    []Bind{{Chord: "h", Actions: []Action{Command("resize shrink width 5px")}}},
			ExitKeys: []string{"q", "Escape", "Return"},
		},
		"system": {
			Binds:    []Bind{{Chord: "l", Actions: []Action{Run{Cmd: "i3exit lock"}}}},
			ExitKeys: []string{"q", "Escape", "Return"},
			OneShot:  true,
		},
		"switcher": {
			Binds: []Bind{
				{Chord: "Tab", Actions: []Action{Run{Cmd: "overlay switcher"}}},
				{Chord: "Escape", Actions: []Action{Run{Cmd: "overlay cancel"}, ExitLayer{}}},
			},
			Hold:          "$mod",
			OnHoldRelease: []Action{Run{Cmd: "overlay confirm"}},
			ExitKeys:      []string{"q"},
			OnExit:        []Action{Run{Cmd: "overlay cancel"}},
		},
	}

	return binds, layers
}

func TestValidate_AcceptsShippedTableShape(t *testing.T) {
	binds, layers := goodShippedTable()
	mustBeEmpty(t, Validate(binds, layers, "Mod4"))

	binds, layers = goodShippedTable() // fresh copy: Validate must not mutate its input
	mustBeEmpty(t, Validate(binds, layers, "Mod1"))
}

func TestValidate_RejectsEachSingleFieldMutation(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer)
		mod     string
		wantSub string
	}{
		{
			name: "duplicate global chord",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				binds = append(binds, Bind{Chord: "Mod4+u", Actions: []Action{Command("dup")}})
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "duplicate binds double-fire",
		},
		{
			name: "empty command on a global bind",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				binds[2].Actions = []Action{Command("   ")}
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "has an empty command",
		},
		{
			name: "empty run() command",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				binds[1].Actions = []Action{Run{Cmd: "   "}}
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "has an empty run() command",
		},
		{
			name: "empty action tuple",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				binds[2].Actions = nil
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "has an empty action tuple",
		},
		{
			name: "blank device",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				binds[3].Device = "   "
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "blank device=",
		},
		{
			name: "unknown display qualifier",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				binds[4].DisplayMod = "bogus"
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "unknown display qualifier",
		},
		{
			name: "EnterLayer target missing",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				binds[0].Actions = []Action{EnterLayer{Layer: "ghost"}}
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "which does not exist",
		},
		{
			name: "reserved panic chord",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				binds[2].Chord = PanicChord
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "is the panic chord",
		},
		{
			name: "layer loses its exit keys",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				l := layers["resize"]
				l.ExitKeys = nil
				layers["resize"] = l
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "has no exit_keys",
		},
		{
			name: "exit key carries a modifier",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				l := layers["nav"]
				l.ExitKeys = []string{"Ctrl+q", "Escape", "Return"}
				layers["nav"] = l
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "exit keys are BARE keysyms",
		},
		{
			name: "on_hold_release with no hold modifier",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				l := layers["switcher"]
				l.Hold = ""
				layers["switcher"] = l
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "on_hold_release is declared with no hold modifier",
		},
		{
			name: "unknown hold modifier",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				l := layers["switcher"]
				l.Hold = "bogus"
				layers["switcher"] = l
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "unknown hold modifier",
		},
		{
			name: "hold modifier resolves to Shift",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				l := layers["switcher"]
				l.Hold = "Shift"
				layers["switcher"] = l
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "resolves to Shift",
		},
		{
			name: "unknown sublayer modifier",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				l := layers["nav"]
				sub := l.Mods["move"]
				sub.Modifier = "bogus"
				l.Mods["move"] = sub
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "unknown modifier",
		},
		{
			name: "layer bind loses its bareness",
			mutate: func(binds []Bind, layers map[string]Layer) ([]Bind, map[string]Layer) {
				l := layers["nav"]
				l.Binds[0].Chord = "$mod+h"
				return binds, layers
			},
			mod:     "Mod4",
			wantSub: "must be BARE keysyms",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			binds, layers := goodShippedTable()
			binds, layers = tc.mutate(binds, layers)
			mod := tc.mod
			if mod == "" {
				mod = "Mod4"
			}
			p := Validate(binds, layers, mod)
			mustHaveProblems(t, p)
			mustHaveProblemContaining(t, p, tc.wantSub)
		})
	}
}
