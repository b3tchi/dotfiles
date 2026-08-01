package layer

// sp023 Task 2 (bd dotfiles-1m4t.2): SetExternalLayer engine semantics —
// the RUNTIME half of the External declaration kind internal/bind's R28-R30
// landed at compile time (Task 1).
//
// No python ancestor: layers.py never had an external-trigger layer, so
// unlike this package's other test files there is no test_layers.py section
// to reconcile against. Scenario-named per sp023 Task 2's test_plan.

import (
	"errors"
	"testing"

	"hotkeyd/internal/bind"
)

// -- fixtures -------------------------------------------------------------

// externalLayers is the nav fixture PLUS the signal-only external layer, so
// every test here can exercise a chord layer and an external layer against
// the same engine — the refusal matrix is exactly about how those two kinds
// interact.
func externalLayers() map[string]bind.Layer {
	layers := navLayers()
	layers["screenshot-drag"] = bind.Layer{External: true}
	return layers
}

// externalBinds carries a GLOBAL bind beside the layer-entry chord. The
// global one ($mod+Return) is the no-shadow probe: it must keep dispatching
// while the external layer is active, because a signal-only layer costs
// pixels, never keys ([[us019]] AC5/AC6).
func externalBinds() []bind.Bind {
	return []bind.Bind{
		{Chord: "$mod+o", Actions: []bind.Action{bind.EnterLayer{Layer: "nav"}}},
		{Chord: "$mod+Return", Actions: []bind.Action{bind.Command("exec term")}},
	}
}

func externalEngine() (*Engine, *recorder, *fakeClock) {
	return buildEngine(engineOpts{binds: externalBinds(), layers: externalLayers()})
}

// externalHoldLayers is the hold (switcher) fixture plus the external layer:
// the mid-hold refusal case needs BOTH kinds in one table, and holdLayers'
// "sw" is the only hold layer this package fixtures.
func externalHoldLayers() map[string]bind.Layer {
	layers := holdLayers("$mod", "commit")
	layers["screenshot-drag"] = bind.Layer{External: true}
	return layers
}

// -- entry / clear ---------------------------------------------------------

func TestSetExternalLayerEntersTheDeclaredLayerAndPublishesIt(t *testing.T) {
	e, pub, _ := externalEngine()
	if err := e.SetExternalLayer("screenshot-drag"); err != nil {
		t.Fatalf("SetExternalLayer: %v", err)
	}
	if got := e.State(); got != (State{Layer: "screenshot-drag"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "screenshot-drag", Mod: ""}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestSetExternalLayerDefaultClearsAndPublishesDefault(t *testing.T) {
	e, pub, _ := externalEngine()
	mustSetExternal(t, e, "screenshot-drag")
	pub.lines = nil
	if err := e.SetExternalLayer(DefaultLayer); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "default", Mod: ""}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestClearWhenAlreadyInDefaultIsAnOkNoOpPublishingNothing(t *testing.T) {
	e, pub, _ := externalEngine()
	if err := e.SetExternalLayer(DefaultLayer); err != nil {
		t.Fatalf("clear on an idle engine must be ok: %v", err)
	}
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 0 {
		t.Fatalf("a no-op clear must publish nothing: %+v", pub.lines)
	}
}

func TestIdempotentReSetPublishesNothing(t *testing.T) {
	e, pub, _ := externalEngine()
	mustSetExternal(t, e, "screenshot-drag")
	pub.lines = nil
	if err := e.SetExternalLayer("screenshot-drag"); err != nil {
		t.Fatalf("re-set must be an ok no-op: %v", err)
	}
	if got := e.State(); got != (State{Layer: "screenshot-drag"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 0 {
		t.Fatalf("publish-on-change must swallow the repeat: %+v", pub.lines)
	}
}

// -- refusal matrix --------------------------------------------------------

func TestSetExternalLayerRefusesAnUndeclaredName(t *testing.T) {
	e, pub, _ := externalEngine()
	err := e.SetExternalLayer("no-such-layer")
	if err == nil {
		t.Fatal("an undeclared name must be refused, never silently entered")
	}
	if !errors.Is(err, ErrNoSuchLayer) {
		t.Fatalf("refusal must be a NAMED error: %v", err)
	}
	if !contains(err.Error(), "no-such-layer") {
		t.Fatalf("refusal must name the offending layer: %q", err)
	}
	assertUnchanged(t, e, pub, State{Layer: "default"})
}

func TestSetExternalLayerRefusesAChordLayersName(t *testing.T) {
	e, pub, _ := externalEngine()
	err := e.SetExternalLayer("nav")
	if err == nil {
		t.Fatal("a chord layer must stay chord-only — set-layer cannot enter it")
	}
	if !errors.Is(err, ErrNotExternalLayer) {
		t.Fatalf("refusal must be a NAMED error: %v", err)
	}
	if !contains(err.Error(), "nav") {
		t.Fatalf("refusal must name the offending layer: %q", err)
	}
	assertUnchanged(t, e, pub, State{Layer: "default"})
}

func TestSetExternalLayerRefusedWhileAChordLayerIsActive(t *testing.T) {
	// plan decision 3: an external process can never kick the user out of a
	// layer they are standing in.
	e, pub, _ := externalEngine()
	e.Handle(press("o", "Mod4"))
	if got := e.State(); got != (State{Layer: "nav"}) {
		t.Fatalf("fixture precondition: state = %+v", got)
	}
	pub.lines = nil
	err := e.SetExternalLayer("screenshot-drag")
	if err == nil {
		t.Fatal("entering an external layer over a chord layer must be refused")
	}
	if !errors.Is(err, ErrLayerActive) {
		t.Fatalf("refusal must be a NAMED error: %v", err)
	}
	if !contains(err.Error(), "nav") {
		t.Fatalf("refusal must name the layer standing in the way: %q", err)
	}
	assertUnchanged(t, e, pub, State{Layer: "nav"})
}

func TestClearIsAlsoRefusedWhileAChordLayerIsActive(t *testing.T) {
	// "ANY request while a chord-entered layer is active" — including the
	// clear, which would otherwise be a remote exit from the user's layer.
	e, pub, _ := externalEngine()
	e.Handle(press("o", "Mod4"))
	pub.lines = nil
	if err := e.SetExternalLayer(DefaultLayer); !errors.Is(err, ErrLayerActive) {
		t.Fatalf("clear must be refused too: %v", err)
	}
	assertUnchanged(t, e, pub, State{Layer: "nav"})
}

func TestSetExternalLayerRefusedWhileAHoldLayerIsActiveAndTheHoldLifecycleContinues(t *testing.T) {
	pub := &recorder{}
	e := NewEngine(tupleBinds(), externalHoldLayers(), Config{
		Publisher: pub, Clock: newFakeClock().Now, Mod: "Mod4",
	})
	e.Handle(press("Tab", "Mod4"))
	if got := e.State(); got != (State{Layer: "sw"}) {
		t.Fatalf("fixture precondition: state = %+v", got)
	}
	pub.lines = nil

	if err := e.SetExternalLayer("screenshot-drag"); !errors.Is(err, ErrLayerActive) {
		t.Fatalf("a hold layer must refuse an external set too: %v", err)
	}
	assertUnchanged(t, e, pub, State{Layer: "sw"})

	// adr0016's ask-the-server lifecycle must be completely untouched by the
	// refusal: the hold modifier is still resolvable, and PollIdle still
	// commits the layer when the server says the modifier is up.
	if got := e.HoldModifier(); got != "Mod4" {
		t.Fatalf("hold modifier after a refusal: %q", got)
	}
	out, err := e.PollIdle(func(string) (bool, error) { return false, nil })
	if err != nil {
		t.Fatalf("PollIdle: %v", err)
	}
	actionsEqual(t, out, cmd("commit"))
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("hold layer must still commit and exit: %+v", got)
	}
}

// -- no shadowing (the property most likely to be subtly wrong) ------------

func TestExternalLayerDoesNotShadowTheGlobalBindTable(t *testing.T) {
	// sp023 plan decision 1: an external layer is SIGNAL-ONLY. While it is
	// active, match() must consult the GLOBAL index, exactly as it does in
	// the default layer — NOT the layer's own (empty by construction) table.
	//
	// This test is written to FAIL against the naive implementation in which
	// an external layer behaves like any other persistent layer, i.e. match()
	// routes through matchInLayer because e.layers[name] exists. That routing
	// returns no actions for every global chord, which is precisely the
	// stranded-layer-eats-the-keyboard failure [[us019]] AC5 forbids.
	baseline, _, _ := externalEngine()
	want := baseline.Handle(press("Return", "Mod4"))
	actionsEqual(t, want, cmd("exec term"))

	e, _, _ := externalEngine()
	mustSetExternal(t, e, "screenshot-drag")
	got := e.Handle(press("Return", "Mod4"))
	actionsEqual(t, got, cmd("exec term"))
	if e.State().Layer != "screenshot-drag" {
		t.Fatalf("dispatching a global bind must not leave the layer: %+v", e.State())
	}
}

func TestGlobalLayerEntryChordStillWorksWhileAnExternalLayerIsActive(t *testing.T) {
	// The same no-shadow property, seen from the state side: the global
	// EnterLayer bind is still reachable, so the session stays fully usable
	// with a stranded external layer up.
	e, _, _ := externalEngine()
	mustSetExternal(t, e, "screenshot-drag")
	e.Handle(press("o", "Mod4"))
	if got := e.State(); got != (State{Layer: "nav"}) {
		t.Fatalf("state = %+v", got)
	}
}

func TestAChordLayerStillShadowsTheGlobalTable(t *testing.T) {
	// The mutation twin of the no-shadow test: the fall-through must be
	// scoped to the External flag, never widened to layers in general.
	e, _, _ := externalEngine()
	e.Handle(press("o", "Mod4"))
	if got := e.Handle(press("Return", "Mod4")); got != nil {
		// "Return" is one of nav's exit keys, so nav consumes it; what
		// matters is that the GLOBAL $mod+Return never fires here.
		t.Fatalf("a chord layer must still shadow the global table: %#v", got)
	}
}

// -- i3 arbitration (plan decision 4) -------------------------------------

func TestSetExternalLayerIsAllowedWhileI3IsInAMode(t *testing.T) {
	// The divergence from EnterLayer, which refuses here. This USED to be the
	// exact sequence the real flow produced — qs-screenshot.sh put i3 into a
	// real "screenshot" mode for the bar's hint strip before the overlay
	// started — but sp024 moved the aiming phase onto its own External layer
	// and deleted that block, so the shipped flow now runs with i3 in
	// "default" throughout. The property is still load-bearing for the case
	// that outlives it: i3 owning a PANIC mode (zz-fallback-binds.conf's
	// nav/resize/$mode_system) must not make a signal-only layer unreachable.
	// The mode name is kept verbatim so the historical sequence stays
	// exercised too.
	e, pub, _ := externalEngine()
	e.SetI3Mode("screenshot")
	pub.lines = nil
	if err := e.SetExternalLayer("screenshot-drag"); err != nil {
		t.Fatalf("a signal-only layer contests no grabs; it must be allowed: %v", err)
	}
	if got := e.State(); got != (State{Layer: "screenshot-drag"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "screenshot-drag"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
	if e.I3Mode() != "screenshot" {
		t.Fatalf("i3 mode must be untouched: %q", e.I3Mode())
	}
}

func TestChordLayerEntryIsStillRefusedWhileI3IsInAMode(t *testing.T) {
	// The divergence is scoped to SetExternalLayer: EnterLayer's refusal
	// (grab collision) is unchanged.
	e, _, _ := externalEngine()
	e.SetI3Mode("screenshot")
	e.Handle(press("o", "Mod4"))
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
}

func TestI3EnteringANewModeForceExitsAnActiveExternalLayer(t *testing.T) {
	// Involuntary route 2, unchanged: i3 taking a NEW non-default mode
	// still clears whatever layer is up, external or not.
	e, pub, _ := externalEngine()
	e.SetI3Mode("screenshot")
	mustSetExternal(t, e, "screenshot-drag")
	pub.lines = nil
	e.SetI3Mode("resize")
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "default"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

// -- defensive engine-side refusal ----------------------------------------

func TestEnterLayerActionTargetingAnExternalLayerIsRefusedAndLogged(t *testing.T) {
	// Defense in depth: internal/bind's R29 makes this unreachable on a
	// loaded table, so this drives the engine with a table the validator
	// would have refused, and asserts the engine still declines — logged
	// like the i3-mode refusal rather than silently entered.
	binds := []bind.Bind{
		{Chord: "$mod+p", Actions: []bind.Action{bind.EnterLayer{Layer: "screenshot-drag"}}},
	}
	e, logged := loggedEngine(engineOpts{binds: binds, layers: externalLayers()})
	e.Handle(press("p", "Mod4"))
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("a chord must never enter an External layer: %+v", got)
	}
	found := false
	for _, m := range *logged {
		if contains(m, "screenshot-drag") && contains(m, "refus") {
			found = true
		}
	}
	if !found {
		t.Fatalf("the refusal must be logged naming the layer: %v", *logged)
	}
}

// -- shutdown + reconciliation invariants ---------------------------------

func TestShutdownActionsWithAnExternalLayerActiveReturnsNil(t *testing.T) {
	// An External layer has no OnExit by construction (Task 1's R28), so
	// shutdown needs no new teardown path.
	e, _, _ := externalEngine()
	mustSetExternal(t, e, "screenshot-drag")
	if got := e.ShutdownActions(); got != nil {
		t.Fatalf("ShutdownActions = %#v, want nil", got)
	}
}

func TestReconcileHoldsLeavesAnActiveExternalLayerUntouched(t *testing.T) {
	// The existing "X has no opinion about a layer" invariant, extended to
	// the new kind: retracting a stale modifier belief must not clear the
	// external signal.
	e, pub, _ := externalEngine()
	e.Handle(press("Control_L"))
	mustSetExternal(t, e, "screenshot-drag")
	pub.lines = nil
	e.ReconcileHolds(map[string]bool{})
	if got := e.State(); got != (State{Layer: "screenshot-drag"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(e.Held()) != 0 {
		t.Fatalf("the stale belief must still be retracted: %v", e.Held())
	}
}

// -- two-External fixture (sp024 Task 1, bd dotfiles-0tv1.1) ---------------
//
// Every test above declares exactly ONE External layer ("screenshot-drag").
// SetExternalLayer's authority guard (engine.go ~713:
// `e.layerName != DefaultLayer && !e.isExternal(e.layerName)`) checks only
// the CURRENT layer's KIND, so external -> external was already permitted by
// construction — but no fixture ever declared two External layers, so
// nothing exercised it. sp024 needs qs-region.py's unmodified press-time
// "screenshot" -> "screenshot-drag" handoff to keep working once a second
// External layer ("screenshot", the aiming phase) joins the compiled table
// in Task 2; this section pins that property FIRST, against the engine as
// shipped, with no production change. See docs/notes/spec/sp024.md ##
// tasks / Task 1.

// twoExternalLayers is the nav fixture plus BOTH signal-only layers the real
// aiming -> drag gesture will hand off between post-cutover.
func twoExternalLayers() map[string]bind.Layer {
	layers := navLayers()
	layers["screenshot"] = bind.Layer{External: true}
	layers["screenshot-drag"] = bind.Layer{External: true}
	return layers
}

func twoExternalEngine() (*Engine, *recorder, *fakeClock) {
	return buildEngine(engineOpts{binds: externalBinds(), layers: twoExternalLayers()})
}

// TestExternalToExternalHandoff is table-driven over the four success
// criteria this task pins (sp024 Task 1 test_plan names them: handoff
// order, clear-from-second, guard-unchanged, idempotent-reset). Each
// subtest builds its own engine so the scenarios stay independent.
func TestExternalToExternalHandoff(t *testing.T) {
	t.Run("handoff order", func(t *testing.T) {
		// us019 AC6: qs-region.py performs this exact transition, unmodified,
		// at mouse-press time. Both calls must succeed and the publisher must
		// see the two layers in order — never coalesced, never reordered.
		e, pub, _ := twoExternalEngine()
		if err := e.SetExternalLayer("screenshot"); err != nil {
			t.Fatalf("SetExternalLayer(screenshot): %v", err)
		}
		if err := e.SetExternalLayer("screenshot-drag"); err != nil {
			t.Fatalf("SetExternalLayer(screenshot-drag): %v", err)
		}
		if got := e.State(); got != (State{Layer: "screenshot-drag"}) {
			t.Fatalf("state = %+v", got)
		}
		want := []State{{Layer: "screenshot"}, {Layer: "screenshot-drag"}}
		if len(pub.lines) != len(want) {
			t.Fatalf("published: %+v, want %+v", pub.lines, want)
		}
		for i := range want {
			if pub.lines[i] != want[i] {
				t.Fatalf("published[%d] = %+v, want %+v", i, pub.lines[i], want[i])
			}
		}
	})

	t.Run("clear from second", func(t *testing.T) {
		// qs-screenshot.sh:103's clear on exit is unconditional — it never
		// checks which of the two layers is up, so a clear issued from the
		// SECOND external layer must behave exactly like one from the first.
		e, pub, _ := twoExternalEngine()
		mustSetExternal(t, e, "screenshot")
		mustSetExternal(t, e, "screenshot-drag")
		pub.lines = nil
		if err := e.SetExternalLayer(DefaultLayer); err != nil {
			t.Fatalf("clear: %v", err)
		}
		if got := e.State(); got != (State{Layer: "default"}) {
			t.Fatalf("state = %+v", got)
		}
		if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "default"}) {
			t.Fatalf("published: %+v", pub.lines)
		}
	})

	t.Run("guard unchanged", func(t *testing.T) {
		// us019 AC4: a second External declaration must not weaken the
		// authority guard — a chord-entered layer still outranks any
		// external request, refused by name, never silently ignored.
		e, pub, _ := twoExternalEngine()
		e.Handle(press("o", "Mod4"))
		if got := e.State(); got != (State{Layer: "nav"}) {
			t.Fatalf("fixture precondition: state = %+v", got)
		}
		pub.lines = nil
		err := e.SetExternalLayer("screenshot")
		if err == nil {
			t.Fatal("entering an external layer over a chord layer must be refused")
		}
		if !errors.Is(err, ErrLayerActive) {
			t.Fatalf("refusal must be a NAMED error: %v", err)
		}
		if !contains(err.Error(), "nav") {
			t.Fatalf("refusal must name the layer standing in the way: %q", err)
		}
		assertUnchanged(t, e, pub, State{Layer: "nav"})
	})

	t.Run("idempotent reset", func(t *testing.T) {
		// Also the edge case "publish-on-change: screenshot -> screenshot
		// re-set emits no line" — the feed never duplicates state, whichever
		// of the two external layers is being re-set.
		e, pub, _ := twoExternalEngine()
		mustSetExternal(t, e, "screenshot")
		pub.lines = nil
		if err := e.SetExternalLayer("screenshot"); err != nil {
			t.Fatalf("re-set must be an ok no-op: %v", err)
		}
		if got := e.State(); got != (State{Layer: "screenshot"}) {
			t.Fatalf("state = %+v", got)
		}
		if len(pub.lines) != 0 {
			t.Fatalf("idempotent re-set must publish nothing: %+v", pub.lines)
		}
	})
}

// TestClientConnectingMidHandoffIsReplayedOnlyTheCurrentLayer is the
// replay-on-connect edge case, driven against a REAL StatePublisher (not the
// in-memory recorder) so the assertion is about the wire contract a late bar
// client actually observes: connecting between the two SetExternalLayer
// calls of a handoff must replay the CURRENT layer only, never the layer it
// superseded.
func TestClientConnectingMidHandoffIsReplayedOnlyTheCurrentLayer(t *testing.T) {
	path := sockPath(t)
	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer p.Close()

	e := NewEngine(externalBinds(), twoExternalLayers(), Config{
		Publisher: p, Clock: newFakeClock().Now, Mod: "Mod4",
	})
	mustSetExternal(t, e, "screenshot")
	mustSetExternal(t, e, "screenshot-drag")

	c := dial(t, path)
	defer c.Close()
	got := readLine(t, c)
	want := `{"layer":"screenshot-drag","mod":null}` + "\n"
	if got != want {
		t.Fatalf("replay line = %q, want %q (only the CURRENT layer, not the handoff history)", got, want)
	}
}

// TestI3EnteringANewModeForceExitsTheFirstExternalLayerInATwoExternalTable is
// the edge case "SetI3Mode to a non-default mode while 'screenshot' is
// active force-exits it (involuntary route 2, existing behavior)" —
// re-asserted with two External layers declared, since involuntary route 2
// (SetI3Mode) is keyed on "a layer is active", not on which External name.
func TestI3EnteringANewModeForceExitsTheFirstExternalLayerInATwoExternalTable(t *testing.T) {
	e, pub, _ := twoExternalEngine()
	mustSetExternal(t, e, "screenshot")
	pub.lines = nil
	e.SetI3Mode("resize")
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "default"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

// -- helpers ---------------------------------------------------------------

func mustSetExternal(t *testing.T, e *Engine, name string) {
	t.Helper()
	if err := e.SetExternalLayer(name); err != nil {
		t.Fatalf("SetExternalLayer(%q): %v", name, err)
	}
}

// assertUnchanged is the "engine state provably unchanged after every
// refusal" assertion the success criteria ask for: same layer, and nothing
// published by the refused call.
func assertUnchanged(t *testing.T, e *Engine, pub *recorder, want State) {
	t.Helper()
	if got := e.State(); got != want {
		t.Fatalf("state after a refusal: got %+v, want %+v", got, want)
	}
	if len(pub.lines) != 0 {
		t.Fatalf("a refused request must publish nothing: %+v", pub.lines)
	}
}
