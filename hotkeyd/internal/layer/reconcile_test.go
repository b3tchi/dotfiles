package layer

// python: test_layers.py lines 1140-1230 ("reconciling belief against the
// server", hwds.27 item 4).

import "testing"

func TestReconcileDropsAHoldTheServerDoesNotCorroborate(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Alt_L"))
	if got := e.State(); got != (State{Layer: "nav", Mod: "resize"}) {
		t.Fatalf("state = %+v", got)
	}
	pub.lines = nil
	changed := e.ReconcileHolds(map[string]bool{})
	if !changed {
		t.Fatalf("ReconcileHolds reported no change")
	}
	if got := e.State(); got != (State{Layer: "nav"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "nav"}) {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestReconcileNeverInventsAHoldTheEngineNeverObserved(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	pub.lines = nil
	changed := e.ReconcileHolds(mods("Mod1", "Ctrl"))
	if changed {
		t.Fatalf("ReconcileHolds reported a change")
	}
	if got := e.State(); got != (State{Layer: "nav"}) {
		t.Fatalf("a sublayer was manufactured from the server mask alone: %+v", got)
	}
	if len(pub.lines) != 0 {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestReconcileLeavesACorroboratedHoldAlone(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	if e.State().Mod != "move" {
		t.Fatalf("state = %+v", e.State())
	}
	pub.lines = nil
	if e.ReconcileHolds(mods("Ctrl")) {
		t.Fatalf("ReconcileHolds reported a change")
	}
	if e.State().Mod != "move" {
		t.Fatalf("state = %+v", e.State())
	}
	if len(pub.lines) != 0 {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestReconcileRefreshesACorroboratedHoldPastTheGuardWindow(t *testing.T) {
	e, _, clock := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	clock.Advance(5000)
	e.ReconcileHolds(mods("Ctrl"))
	e.Handle(press("h", "Ctrl"))
	if e.State().Mod != "move" {
		t.Fatalf("a reconciled hold was expired anyway on the next event: %+v", e.State())
	}
}

func TestReconcileLogsTheRetraction(t *testing.T) {
	e, lines := loggedEngine(engineOpts{})
	e.Handle(xev(Press, "o", []string{"Mod4"}, 32, 0x40, "", 0))
	e.Handle(xev(Press, "Alt_L", []string{"Mod4"}, 64, 0x40, "", 0))
	*lines = nil
	e.ReconcileHolds(map[string]bool{})
	tr := transitions(*lines)
	if len(tr) != 1 {
		t.Fatalf("lines: %v", *lines)
	}
	if !contains(tr[0], "mod=resize->none") || !contains(tr[0], "reconcile") {
		t.Fatalf("line: %q", tr[0])
	}
}

func TestReconcileDoesNotLeaveALayer(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Alt_L"))
	e.ReconcileHolds(map[string]bool{})
	if e.State().Layer != "nav" {
		t.Fatalf("reconcile dropped the layer: %+v", e.State())
	}
}

func TestHeldIsExposedSoTheIdlePathCanSkipTheXRoundTrip(t *testing.T) {
	e, _, _ := defaultEngine()
	if got := e.Held(); len(got) != 0 {
		t.Fatalf("held = %v, want empty", got)
	}
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	got := e.Held()
	if len(got) != 1 || got[0] != "Ctrl" {
		t.Fatalf("held = %v, want [Ctrl]", got)
	}
}
