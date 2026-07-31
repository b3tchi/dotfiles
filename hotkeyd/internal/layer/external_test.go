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
	// The exact sequence the real flow produces: qs-screenshot.sh puts i3
	// into the real "screenshot" mode for the bar's hint strip BEFORE the
	// overlay starts, so the drag signal ALWAYS arrives with
	// i3Mode == "screenshot". Diverges from EnterLayer, which refuses here.
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
