package layer

// python: test_layers.py lines 1359-1588 ("hold layers", HAZARD 3, and
// "no exit route may strand the overlay" / dotfiles-hwds.51), PLUS this
// package's own PollIdle tests (hold.go, sp021 Task 7's actual injected-
// ModifierDown mechanism — python never had this seam, since Python's
// daemon computed mods_down itself and called reconcile_hold_layer
// directly; adr0016's "ask the server" shape is the same, only WHO builds
// the down-set differs).

import (
	"errors"
	"testing"

	"hotkeyd/internal/bind"
)

func holdLayers(hold, action string) map[string]bind.Layer {
	var actions []bind.Action
	if action != "" {
		actions = []bind.Action{bind.Command(action)}
	}
	return map[string]bind.Layer{
		"sw": {
			Binds: []bind.Bind{
				{Chord: "Tab", Actions: []bind.Action{bind.Command("next")}},
				{Chord: "Escape", Actions: []bind.Action{bind.Command("cancel"), bind.ExitLayer{}}},
			},
			Hold:          hold,
			OnHoldRelease: actions,
			ExitKeys:      []string{"q"},
		},
	}
}

// holdEngine mirrors test_layers.py's _hold_engine: built directly (not
// through buildEngine) because `mod` is the whole point — the same table
// must mean Mod4 on :0 and Mod1 on :10.
func holdEngine(mod, hold, action string) *Engine {
	return NewEngine(tupleBinds(), holdLayers(hold, action), Config{
		Publisher: &recorder{}, Clock: newFakeClock().Now, Mod: mod,
	})
}

func defaultHoldEngine() *Engine {
	return holdEngine("Mod4", "$mod", "commit")
}

func TestObservingTheHoldModifierReleaseCommitsAndExits(t *testing.T) {
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	if e.State().Layer != "sw" {
		t.Fatalf("state = %+v", e.State())
	}
	actionsEqual(t, e.Handle(release("Super_L")), cmd("commit"))
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestTheCommitDoesNotRequireHavingSeenThePress(t *testing.T) {
	// HAZARD 2: Super_L is not grabbed in the default layer, so at layer
	// entry `held` is empty. Commit must fire on OBSERVING the release,
	// never on believing the modifier was down.
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	if got := e.Held(); len(got) != 0 {
		t.Fatalf("held = %v, want empty", got)
	}
	actionsEqual(t, e.Handle(release("Super_L")), cmd("commit"))
}

func TestTheHoldModifierResolvesPerDisplay(t *testing.T) {
	// HAZARD 1: $mod is Mod4 on :0, Mod1 on the xrdp :10 session.
	e := holdEngine("Mod1", "$mod", "commit")
	e.Handle(press("Tab", "Mod1"))
	if out := e.Handle(release("Super_L")); len(out) != 0 {
		t.Fatalf("wrong-display modifier committed: %+v", out)
	}
	if e.State().Layer != "sw" {
		t.Fatalf("state = %+v", e.State())
	}
	actionsEqual(t, e.Handle(release("Alt_L")), cmd("commit"))
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestAHoldReleaseWithNoActionJustExits(t *testing.T) {
	e := holdEngine("Mod4", "$mod", "")
	e.Handle(press("Tab", "Mod4"))
	if out := e.Handle(release("Super_L")); len(out) != 0 {
		t.Fatalf("out = %+v", out)
	}
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestAnotherModifiersReleaseDoesNotEndAHoldLayer(t *testing.T) {
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	if out := e.Handle(release("Control_L")); len(out) != 0 {
		t.Fatalf("out = %+v", out)
	}
	if e.State().Layer != "sw" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestAHoldReleaseOutsideTheLayerDispatchesNothing(t *testing.T) {
	e := defaultHoldEngine()
	if out := e.Handle(release("Super_L")); len(out) != 0 {
		t.Fatalf("out = %+v", out)
	}
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestHoldModifierReportsTheCurrentLayersHold(t *testing.T) {
	e := defaultHoldEngine()
	if got := e.HoldModifier(); got != "" {
		t.Fatalf("hold_modifier = %q before entry", got)
	}
	e.Handle(press("Tab", "Mod4"))
	if got := e.HoldModifier(); got != "Mod4" {
		t.Fatalf("hold_modifier = %q", got)
	}
}

func TestALayerWithoutAHoldReportsNoHoldModifier(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	if e.State().Layer != "nav" {
		t.Fatalf("state = %+v", e.State())
	}
	if got := e.HoldModifier(); got != "" {
		t.Fatalf("hold_modifier = %q, want none", got)
	}
}

// -- HAZARD 3: the release-before-grab race ---------------------------------

func TestTheServerReportingTheModifierUpCommitsAndExits(t *testing.T) {
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	actionsEqual(t, e.ReconcileHoldLayer(false), cmd("commit"))
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestTheServerReportingTheModifierDownChangesNothing(t *testing.T) {
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	if out := e.ReconcileHoldLayer(true); len(out) != 0 {
		t.Fatalf("out = %+v", out)
	}
	if e.State().Layer != "sw" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestReconcilingNeverCancelsALayerThatDeclaresNoHold(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	if out := e.ReconcileHoldLayer(false); len(out) != 0 {
		t.Fatalf("out = %+v", out)
	}
	if e.State().Layer != "nav" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestReconcilingInTheDefaultLayerIsANoOp(t *testing.T) {
	e := defaultHoldEngine()
	if out := e.ReconcileHoldLayer(false); len(out) != 0 {
		t.Fatalf("out = %+v", out)
	}
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestTheReconciledCommitPublishesOneLineAndLogsWhy(t *testing.T) {
	var lines []string
	e := NewEngine(tupleBinds(), holdLayers("$mod", "commit"), Config{
		Publisher: &recorder{}, Clock: newFakeClock().Now,
		Log: func(m string) { lines = append(lines, m) },
	})
	e.Handle(xev(Press, "Tab", []string{"Mod4"}, 23, 0x40, "", 0))
	lines = nil
	e.ReconcileHoldLayer(false)
	tr := transitions(lines)
	if len(tr) != 1 {
		t.Fatalf("lines: %v", lines)
	}
	if !contains(tr[0], "layer=sw->default") || !contains(tr[0], "hold-released") {
		t.Fatalf("line: %q", tr[0])
	}
}

func TestTheExitKeyFloorStillLeavesAHoldLayer(t *testing.T) {
	// The last resort when the modifier's release was never delivered AND
	// the server answer never arrived.
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	if out := e.Handle(press("q")); len(out) != 0 {
		t.Fatalf("out = %+v", out)
	}
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
}

// -- no exit route may strand the overlay (dotfiles-hwds.51) --------------

func switcherEngine() *Engine {
	layer := bind.Layer{
		Binds:         []bind.Bind{{Chord: "Tab", Actions: []bind.Action{bind.Run{Cmd: "open"}}}},
		ExitKeys:      []string{"q"},
		Hold:          "Mod1",
		OnHoldRelease: []bind.Action{bind.Run{Cmd: "confirm"}},
		OnExit:        []bind.Action{bind.Run{Cmd: "cancel"}},
	}
	binds := []bind.Bind{{Chord: "Mod1+Tab", Actions: []bind.Action{bind.Run{Cmd: "open"}, bind.EnterLayer{Layer: "sw"}}}}
	return NewEngine(binds, map[string]bind.Layer{"sw": layer}, Config{
		Publisher: &recorder{}, Clock: newFakeClock().Now, Mod: "Mod1",
	})
}

func cmds(actions []bind.Action) []string {
	var out []string
	for _, a := range actions {
		if r, ok := a.(bind.Run); ok {
			out = append(out, r.Cmd)
		}
	}
	return out
}

func TestAnExitKeyDeliberatelyLeavesTheOverlayAlone(t *testing.T) {
	e := switcherEngine()
	e.Handle(press("Tab", "Mod1"))
	if e.State().Layer != "sw" {
		t.Fatalf("state = %+v", e.State())
	}
	out := e.Handle(press("q"))
	if e.State().Layer != DefaultLayer {
		t.Fatalf("state = %+v", e.State())
	}
	if got := cmds(out); len(got) != 0 {
		t.Fatalf("exit key ran on_exit: %v", got)
	}
}

func TestAnExplicitExitActionTellsTheOverlay(t *testing.T) {
	e := switcherEngine()
	e.Handle(press("Tab", "Mod1"))
	out := e.run([]bind.Action{bind.ExitLayer{}}, nil)
	if e.State().Layer != DefaultLayer {
		t.Fatalf("state = %+v", e.State())
	}
	got := cmds(out)
	found := false
	for _, c := range got {
		if c == "cancel" {
			found = true
		}
	}
	if !found {
		t.Fatalf("cancel missing: %v", got)
	}
}

func TestTheHoldReleaseCommitsThenStillTellsTheOverlay(t *testing.T) {
	e := switcherEngine()
	e.Handle(press("Tab", "Mod1"))
	out := e.ReconcileHoldLayer(false)
	got := cmds(out)
	confirmIdx, cancelIdx := -1, -1
	for i, c := range got {
		if c == "confirm" {
			confirmIdx = i
		}
		if c == "cancel" {
			cancelIdx = i
		}
	}
	if confirmIdx < 0 || cancelIdx < 0 || confirmIdx >= cancelIdx {
		t.Fatalf("ordering wrong: %v", got)
	}
}

func TestI3TakingAModeTellsTheOverlay(t *testing.T) {
	e := switcherEngine()
	e.Handle(press("Tab", "Mod1"))
	out := e.SetI3Mode("resize")
	if e.State().Layer != DefaultLayer {
		t.Fatalf("state = %+v", e.State())
	}
	got := cmds(out)
	found := false
	for _, c := range got {
		if c == "cancel" {
			found = true
		}
	}
	if !found {
		t.Fatalf("cancel missing: %v", got)
	}
}

func TestLeavingTheLayerTellsTheOverlayExactlyOnce(t *testing.T) {
	e := switcherEngine()
	e.Handle(press("Tab", "Mod1"))
	out := e.run([]bind.Action{bind.Run{Cmd: "something"}, bind.ExitLayer{}}, nil)
	got := cmds(out)
	count := 0
	for _, c := range got {
		if c == "cancel" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("cancel count = %d, want 1: %v", count, got)
	}
}

func TestALayerWithoutOnExitDispatchesNothingExtra(t *testing.T) {
	e := NewEngine(
		[]bind.Bind{{Chord: "Mod4+o", Actions: []bind.Action{bind.EnterLayer{Layer: "nav"}}}},
		map[string]bind.Layer{"nav": {
			Binds:    []bind.Bind{{Chord: "h", Actions: []bind.Action{bind.Command("focus left")}}},
			ExitKeys: []string{"q"},
		}},
		Config{Publisher: &recorder{}, Clock: newFakeClock().Now},
	)
	e.Handle(press("o", "Mod4"))
	out := e.Handle(press("q"))
	if len(out) != 0 {
		t.Fatalf("out = %+v", out)
	}
}

// -- PollIdle (hold.go) — the actual injected-ModifierDown mechanism ------
// adr0016: a hold layer ends by ASKING THE SERVER, sampled standalone,
// never by consulting the engine's own held-set. These tests drive the
// real PollIdle path with a scripted ModifierDown, per this task's
// test_plan.

// countingQuery wraps a ModifierDown and records every modifier it was
// asked about, so tests can assert PollIdle queries NOTHING when the
// engine has no opinion worth checking (and, separately, that it never
// substitutes e.held for the query's answer).
func countingQuery(answers map[string]bool, err error) (ModifierDown, *[]string) {
	var calls []string
	return func(mod string) (bool, error) {
		calls = append(calls, mod)
		if err != nil {
			return false, err
		}
		return answers[mod], nil
	}, &calls
}

func TestPollIdleQueriesNothingWhenTheEngineHasNoOpinion(t *testing.T) {
	e, _, _ := defaultEngine() // default layer, nothing held
	query, calls := countingQuery(nil, nil)
	out, err := e.PollIdle(query)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if out != nil {
		t.Fatalf("out = %+v", out)
	}
	if len(*calls) != 0 {
		t.Fatalf("query called with nothing to check: %v", *calls)
	}
}

func TestPollIdleCommitsAHoldLayerWhenTheServerSaysItsModifierIsUp(t *testing.T) {
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	query, calls := countingQuery(map[string]bool{"Mod4": false}, nil)
	out, err := e.PollIdle(query)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	actionsEqual(t, out, cmd("commit"))
	if e.State().Layer != DefaultLayer {
		t.Fatalf("state = %+v", e.State())
	}
	found := false
	for _, c := range *calls {
		if c == "Mod4" {
			found = true
		}
	}
	if !found {
		t.Fatalf("query never asked about Mod4: %v", *calls)
	}
}

func TestPollIdleDoesNotCommitWhileTheServerSaysTheModifierIsStillDown(t *testing.T) {
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	query, _ := countingQuery(map[string]bool{"Mod4": true}, nil)
	out, err := e.PollIdle(query)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("out = %+v", out)
	}
	if e.State().Layer != "sw" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestPollIdleEnteredWithModifierAlreadyDownNeverConsultsHeld(t *testing.T) {
	// The structural case behind adr0016: the daemon never saw $mod's own
	// press (Tab entered the layer, and $mod was already down before that),
	// so e.Held() is empty exactly as in TestTheCommitDoesNotRequireHavingSeenThePress.
	// PollIdle must still correctly track the modifier via the query alone.
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	if got := e.Held(); len(got) != 0 {
		t.Fatalf("held = %v, want empty (never saw the press)", got)
	}

	// Server says still down: no commit, and critically the decision did
	// NOT come from e.held (which is empty and would say "not held" if
	// consulted — the wrong answer, since the modifier IS physically down).
	query, _ := countingQuery(map[string]bool{"Mod4": true}, nil)
	out, err := e.PollIdle(query)
	if err != nil || len(out) != 0 {
		t.Fatalf("out=%v err=%v, want no commit while server says down", out, err)
	}
	if e.State().Layer != "sw" {
		t.Fatalf("state = %+v", e.State())
	}

	// Server later says up: commits, again without ever having seen a
	// press or release event for the modifier.
	query2, _ := countingQuery(map[string]bool{"Mod4": false}, nil)
	out2, err2 := e.PollIdle(query2)
	if err2 != nil {
		t.Fatalf("err = %v", err2)
	}
	actionsEqual(t, out2, cmd("commit"))
	if e.State().Layer != DefaultLayer {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestPollIdlePropagatesAModifierDownError(t *testing.T) {
	e := defaultHoldEngine()
	e.Handle(press("Tab", "Mod4"))
	wantErr := errors.New("x11: query failed")
	query, _ := countingQuery(nil, wantErr)
	out, err := e.PollIdle(query)
	if err == nil {
		t.Fatalf("expected an error")
	}
	if !errors.Is(err, wantErr) {
		t.Fatalf("error does not wrap the underlying cause: %v", err)
	}
	if out != nil {
		t.Fatalf("out = %+v", out)
	}
	// The layer must not have been silently committed on an error.
	if e.State().Layer != "sw" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestPollIdleAlsoReconcilesASublayerHoldViaTheSameInjectedFunc(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	if e.State().Mod != "move" {
		t.Fatalf("state = %+v", e.State())
	}
	query, calls := countingQuery(map[string]bool{"Ctrl": false}, nil)
	out, err := e.PollIdle(query)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("sublayer reconciliation must not itself dispatch actions: %+v", out)
	}
	if e.State().Mod != "" {
		t.Fatalf("sublayer belief was not retracted: %+v", e.State())
	}
	if e.State().Layer != "nav" {
		t.Fatalf("reconciliation must not exit the layer: %+v", e.State())
	}
	found := false
	for _, c := range *calls {
		if c == "Ctrl" {
			found = true
		}
	}
	if !found {
		t.Fatalf("query never asked about Ctrl: %v", *calls)
	}
}
