package layer

// python: test_layers.py lines 1232-1357 ("ONE-SHOT layers" and
// "tuple actions").

import (
	"testing"

	"hotkeyd/internal/bind"
)

func oneshotLayers() map[string]bind.Layer {
	return map[string]bind.Layer{
		"os": {
			Binds: []bind.Bind{
				{Chord: "a", Actions: []bind.Action{bind.Run{Cmd: "echo a"}}},
				{Chord: "b", Actions: []bind.Action{bind.Command("i3-cmd-b")}},
			},
			ExitKeys: []string{"q", "Escape"},
			OneShot:  true,
		},
		"sticky": {
			Binds:    []bind.Bind{{Chord: "a", Actions: []bind.Action{bind.Run{Cmd: "echo a"}}}},
			ExitKeys: []string{"q"},
		},
	}
}

func oneshotBinds() []bind.Bind {
	return []bind.Bind{
		{Chord: "$mod+F1", Actions: []bind.Action{bind.EnterLayer{Layer: "os"}}},
		{Chord: "$mod+F2", Actions: []bind.Action{bind.EnterLayer{Layer: "sticky"}}},
	}
}

func oneshotEngine() (*Engine, *recorder, *fakeClock) {
	return buildEngine(engineOpts{binds: oneshotBinds(), layers: oneshotLayers()})
}

func TestAOneShotLayerExitsAfterABindFires(t *testing.T) {
	e, _, _ := oneshotEngine()
	e.Handle(press("F1", "Mod4"))
	if e.State().Layer != "os" {
		t.Fatalf("state = %+v", e.State())
	}
	e.Handle(press("a"))
	if e.State().Layer != "default" {
		t.Fatalf("a one-shot layer must return to default after ONE bind: %+v", e.State())
	}
}

func TestAOneShotLayerStillDispatchesTheActionItExitsOn(t *testing.T) {
	e, _, _ := oneshotEngine()
	e.Handle(press("F1", "Mod4"))
	out := e.Handle(press("b"))
	actionsEqual(t, out, cmd("i3-cmd-b"))
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestANormalLayerStillPersistsAfterABindFires(t *testing.T) {
	e, _, _ := oneshotEngine()
	e.Handle(press("F2", "Mod4"))
	e.Handle(press("a"))
	if e.State().Layer != "sticky" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestAOneShotLayerExitPublishesExactlyOneLine(t *testing.T) {
	e, pub, _ := oneshotEngine()
	e.Handle(press("F1", "Mod4"))
	pub.lines = nil
	e.Handle(press("a"))
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "default"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestAKeyThatMatchesNothingDoesNotLeaveAOneShotLayer(t *testing.T) {
	e, _, _ := oneshotEngine()
	e.Handle(press("F1", "Mod4"))
	e.Handle(press("z"))
	if e.State().Layer != "os" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestTheOneShotExitIsLoggedAsATransition(t *testing.T) {
	var lines []string
	e, _, _ := buildEngine(engineOpts{
		binds: oneshotBinds(), layers: oneshotLayers(),
		log: func(m string) { lines = append(lines, m) },
	})
	e.Handle(xev(Press, "F1", []string{"Mod4"}, 67, 0x40, "", 0))
	lines = nil
	e.Handle(xev(Press, "a", nil, 38, 0x0, "", 0))
	tr := transitions(lines)
	if len(tr) != 1 {
		t.Fatalf("lines: %v", lines)
	}
	if !contains(tr[0], "layer=os->default") || !contains(tr[0], "trigger=press:a") {
		t.Fatalf("line: %q", tr[0])
	}
}

// -- repeat presses must never re-trigger a one-shot exit -----------------
// Task edge_case: "XIKeyRepeat-flagged presses must not re-trigger one-shot
// exits." Not a literal python test (test_layers.py never combined
// one-shot + auto-repeat), added because the task names it explicitly.
// Structural guarantee: isRepeat() short-circuits handle() BEFORE match(),
// so a held key can never re-fire a bind regardless of which layer it
// left the engine in.

func TestRepeatPressOfAOneShotFiringKeyDoesNotReExit(t *testing.T) {
	e, _, _ := oneshotEngine()
	e.Handle(press("F1", "Mod4"))
	out := e.Handle(press("a")) // fires "echo a", exits to default
	actionsEqual(t, out, run("echo a"))
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
	// Auto-repeat: same key, NO release between. isRepeat must short-circuit
	// before any bind (including one in the layer we've already left) can
	// fire again.
	if out := e.Handle(press("a")); len(out) != 0 {
		t.Fatalf("repeat press dispatched: %+v", out)
	}
	if out := e.Handle(press("a")); len(out) != 0 {
		t.Fatalf("repeat press dispatched: %+v", out)
	}
}

// -- tuple actions (dotfiles-hwds.40) --------------------------------------

func tupleLayers() map[string]bind.Layer {
	return map[string]bind.Layer{
		"sw": {
			Binds: []bind.Bind{
				{Chord: "Tab", Actions: []bind.Action{bind.Command("next")}},
				{Chord: "Escape", Actions: []bind.Action{bind.Command("cancel"), bind.ExitLayer{}}},
			},
			ExitKeys: []string{"q"},
		},
	}
}

func tupleBinds() []bind.Bind {
	return []bind.Bind{
		{Chord: "$mod+Tab", Actions: []bind.Action{bind.Command("open"), bind.EnterLayer{Layer: "sw"}}},
	}
}

func TestATupleActionDispatchesEveryPartInOrder(t *testing.T) {
	e, _, _ := buildEngine(engineOpts{binds: tupleBinds(), layers: tupleLayers()})
	actionsEqual(t, e.Handle(press("Tab", "Mod4")), cmd("open"))
	if e.State().Layer != "sw" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestATupleActionInsideALayerCanDispatchAndExit(t *testing.T) {
	e, _, _ := buildEngine(engineOpts{binds: tupleBinds(), layers: tupleLayers()})
	e.Handle(press("Tab", "Mod4"))
	actionsEqual(t, e.Handle(press("Escape", "Mod4")), cmd("cancel"))
	if e.State().Layer != "default" {
		t.Fatalf("state = %+v", e.State())
	}
}

func TestATupleExitPublishesExactlyOneLine(t *testing.T) {
	e, pub, _ := buildEngine(engineOpts{binds: tupleBinds(), layers: tupleLayers()})
	e.Handle(press("Tab", "Mod4"))
	pub.lines = nil
	e.Handle(press("Escape", "Mod4"))
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "default"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}
