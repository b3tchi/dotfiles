package layer

// Test inventory note (task evidence, dotfiles-ylmp.6): this file plus
// reconcile_test.go, i3mode_test.go, oneshot_test.go and hold_test.go
// re-express hotkeyd/test_layers.py's LayerEngine scenarios. The full
// scenario -> Go-test-or-dropped-with-reason inventory is recorded in this
// task's bd notes, not duplicated here; a short pointer per section below
// names which python section a file covers.

import (
	"fmt"
	"testing"
	"time"

	"hotkeyd/internal/bind"
)

// -- fixtures -------------------------------------------------------------

// fakeClock is a monotonic clock under test control — the 120 ms guard
// cannot be tested against wall time without making the suite slow and
// flaky. Mirrors test_layers.py's FakeClock.
type fakeClock struct {
	now time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Unix(1000, 0)}
}

func (c *fakeClock) Now() time.Time { return c.now }

func (c *fakeClock) Advance(ms int) {
	c.now = c.now.Add(time.Duration(ms) * time.Millisecond)
}

// recorder stands in for the socket publisher: records exactly what was
// published. Mirrors test_layers.py's Recorder.
type recorder struct {
	lines []State
}

func (r *recorder) Publish(s State) { r.lines = append(r.lines, s) }

func mods(names ...string) map[string]bool {
	out := map[string]bool{}
	for _, n := range names {
		out[n] = true
	}
	return out
}

func press(key string, m ...string) Event {
	return Event{Kind: Press, Key: key, Mods: mods(m...)}
}

func release(key string, m ...string) Event {
	return Event{Kind: Release, Key: key, Mods: mods(m...)}
}

// xev builds an Event carrying the transition-log-only fields (keycode,
// raw_state, device, device_id) — mirrors test_layers.py's xev().
func xev(kind Kind, key string, m []string, keycode int, rawState uint32, device string, deviceID int) Event {
	ev := Event{Kind: kind, Key: key, Mods: mods(m...)}
	if keycode != 0 || kind == Press {
		kc := keycode
		ev.Keycode = &kc
	}
	rs := rawState
	ev.RawState = &rs
	if device != "" {
		ev.Device = device
	}
	if deviceID != 0 {
		did := deviceID
		ev.DeviceID = &did
	}
	return ev
}

// -- nav fixture ------------------------------------------------------------
// A local stand-in for binds.py's shipped "nav" layer (bare keys focus, Ctrl
// moves, Alt resizes, exit_keys q/Escape/Return) — deliberately NOT the real
// production table from cmd/hotkeyd/config.go. This package's test_plan is
// "pure unit tests, zero X and zero i3" against the ENGINE; chord-for-chord
// fidelity to the shipped table is cmd/hotkeyd/config_test.go's golden-dump
// parity job (sp021 Task 6, already landed), not this package's.

func navLayers() map[string]bind.Layer {
	return map[string]bind.Layer{
		"nav": {
			Binds: []bind.Bind{
				{Chord: "h", Actions: []bind.Action{bind.Command("focus left")}},
			},
			Mods: map[string]bind.Mod{
				"move": {Modifier: "Ctrl", Binds: []bind.Bind{
					{Chord: "h", Actions: []bind.Action{bind.Command("move left")}},
					{Chord: "j", Actions: []bind.Action{bind.Command("move down")}},
				}},
				"resize": {Modifier: "Mod1", Binds: []bind.Bind{
					{Chord: "h", Actions: []bind.Action{bind.Command("resize shrink width 5 px or 5 ppt")}},
				}},
			},
			ExitKeys: []string{"q", "Escape", "Return"},
		},
	}
}

func navBinds() []bind.Bind {
	return []bind.Bind{
		{Chord: "$mod+o", Actions: []bind.Action{bind.EnterLayer{Layer: "nav"}}},
	}
}

// engine builds an Engine over the nav fixture by default (mirrors
// test_layers.py's engine() helper); binds/layers/clock/pub may be
// overridden.
type engineOpts struct {
	binds  []bind.Bind
	layers map[string]bind.Layer
	clock  *fakeClock
	pub    *recorder
	log    func(string)
	mod    string
}

func buildEngine(o engineOpts) (*Engine, *recorder, *fakeClock) {
	clock := o.clock
	if clock == nil {
		clock = newFakeClock()
	}
	pub := o.pub
	if pub == nil {
		pub = &recorder{}
	}
	binds_ := o.binds
	if binds_ == nil {
		binds_ = navBinds()
	}
	layers := o.layers
	if layers == nil {
		layers = navLayers()
	}
	e := NewEngine(binds_, layers, Config{
		Publisher: pub,
		Clock:     clock.Now,
		Mod:       o.mod,
		Log:       o.log,
	})
	return e, pub, clock
}

func defaultEngine() (*Engine, *recorder, *fakeClock) {
	return buildEngine(engineOpts{})
}

// loggedEngine returns the engine plus a pointer to its accumulating log
// lines — a pointer because the log closure appends to a variable in THIS
// function's frame; returning the slice by value would hand the caller a
// snapshot that never sees later appends.
func loggedEngine(o engineOpts) (*Engine, *[]string) {
	lines := &[]string{}
	o.log = func(m string) { *lines = append(*lines, m) }
	e, _, _ := buildEngine(o)
	return e, lines
}

func transitions(lines []string) []string {
	var out []string
	for _, l := range lines {
		if len(l) >= len("transition ") && l[:len("transition ")] == "transition " {
			out = append(out, l)
		}
	}
	return out
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && indexOf(s, substr) >= 0
}

func indexOf(s, substr string) int {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}

func actionsEqual(t *testing.T, got []bind.Action, want ...bind.Action) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("actions: got %#v, want %#v", got, want)
	}
	for i := range got {
		if fmt.Sprintf("%#v", got[i]) != fmt.Sprintf("%#v", want[i]) {
			t.Fatalf("actions[%d]: got %#v, want %#v", i, got[i], want[i])
		}
	}
}

func cmd(s string) bind.Action { return bind.Command(s) }
func run(s string) bind.Action { return bind.Run{Cmd: s} }

// -- state transitions — exactly one line per change -----------------------
// python: test_layers.py lines 74-123 ("state transitions" section)

func TestStartsInDefaultAndPublishesNothingUntilSomethingChanges(t *testing.T) {
	e, pub, _ := defaultEngine()
	if got := e.State(); got != (State{Layer: DefaultLayer, Mod: ""}) {
		t.Fatalf("initial state = %+v", got)
	}
	if len(pub.lines) != 0 {
		t.Fatalf("published before any event: %+v", pub.lines)
	}
}

func TestEnteringAndLeavingALayerPublishesOneLineEach(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "nav"}) {
		t.Fatalf("after entering nav: %+v", pub.lines)
	}
	e.Handle(press("q"))
	if len(pub.lines) != 2 || pub.lines[1] != (State{Layer: "default"}) {
		t.Fatalf("after leaving nav: %+v", pub.lines)
	}
}

func TestModifierPressAndReleasePublishesOneLineEach(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	pub.lines = nil
	e.Handle(press("Control_L"))
	if len(pub.lines) != 1 || pub.lines[0] != (State{Layer: "nav", Mod: "move"}) {
		t.Fatalf("after Ctrl press: %+v", pub.lines)
	}
	e.Handle(release("Control_L"))
	if len(pub.lines) != 2 || pub.lines[1] != (State{Layer: "nav"}) {
		t.Fatalf("after Ctrl release: %+v", pub.lines)
	}
}

func TestNoDuplicateLineWhenNothingChanged(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	pub.lines = nil
	for i := 0; i < 5; i++ {
		e.Handle(press("h"))
		e.Handle(release("h"))
	}
	if len(pub.lines) != 0 {
		t.Fatalf("churn published: %+v", pub.lines)
	}
}

func TestRepeatedModifierPressPublishesOnce(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	pub.lines = nil
	e.Handle(press("Control_L"))
	e.Handle(press("Control_L")) // X auto-repeat
	e.Handle(press("Control_L"))
	if len(pub.lines) != 1 {
		t.Fatalf("repeated Ctrl press published %d lines, want 1: %+v", len(pub.lines), pub.lines)
	}
}

// -- dispatch --------------------------------------------------------------
// python: test_layers.py lines 125-297

func TestBareKeysFocusCtrlMovesAltResizesInTheNavLayer(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(release("o", "Mod4"))
	actionsEqual(t, e.Handle(press("h")), cmd("focus left"))
	e.Handle(release("h"))
	e.Handle(press("Control_L"))
	actionsEqual(t, e.Handle(press("h", "Ctrl")), cmd("move left"))
	e.Handle(release("h", "Ctrl"))
	e.Handle(release("Control_L"))
	e.Handle(press("Alt_L"))
	actionsEqual(t, e.Handle(press("h", "Mod1")), cmd("resize shrink width 5 px or 5 ppt"))
}

func TestPressBindFiresOncePerPressWithNoRepeatWhileHeld(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	var fired []bind.Action
	for i := 0; i < 4; i++ {
		fired = append(fired, e.Handle(press("h"))...) // repeats, no release
	}
	actionsEqual(t, fired, cmd("focus left"))
	e.Handle(release("h"))
	actionsEqual(t, e.Handle(press("h")), cmd("focus left"))
}

func TestOnReleaseBindFiresOnReleaseAndNotOnPress(t *testing.T) {
	binds := []bind.Bind{{Chord: "Mod4+Shift+d", Actions: []bind.Action{bind.Command("nop confirm")}, OnRelease: true}}
	e, _, _ := buildEngine(engineOpts{binds: binds, layers: map[string]bind.Layer{}})
	if out := e.Handle(press("d", "Mod4", "Shift")); len(out) != 0 {
		t.Fatalf("press fired: %+v", out)
	}
	actionsEqual(t, e.Handle(release("d", "Mod4", "Shift")), cmd("nop confirm"))
}

func TestAnOrphanReleaseDoesNotFireAnOnReleaseBind(t *testing.T) {
	binds := []bind.Bind{{Chord: "Mod4+Print", Actions: []bind.Action{bind.Command("nop shot")}, OnRelease: true}}
	e, _, _ := buildEngine(engineOpts{binds: binds, layers: map[string]bind.Layer{}})
	if out := e.Handle(release("Print", "Mod4")); len(out) != 0 {
		t.Fatalf("orphan release fired: %+v", out)
	}
}

func TestTheXRDPBurstFiresAnOnReleaseBindExactlyOnce(t *testing.T) {
	binds := []bind.Bind{{Chord: "Mod4+Print", Actions: []bind.Action{bind.Command("nop shot")}, OnRelease: true}}
	e, _, _ := buildEngine(engineOpts{binds: binds, layers: map[string]bind.Layer{}})
	var fired []bind.Action
	fired = append(fired, e.Handle(release("Print", "Mod4"))...) // the spurious leading one
	fired = append(fired, e.Handle(press("Print", "Mod4"))...)
	fired = append(fired, e.Handle(release("Print", "Mod4"))...) // the real one
	actionsEqual(t, fired, cmd("nop shot"))
}

func TestSuppressingOrphanReleasesDoesNotBreakANormalPressRelease(t *testing.T) {
	binds := []bind.Bind{{Chord: "Mod4+Print", Actions: []bind.Action{bind.Command("nop shot")}, OnRelease: true}}
	e, _, _ := buildEngine(engineOpts{binds: binds, layers: map[string]bind.Layer{}})
	e.Handle(press("Print", "Mod4"))
	actionsEqual(t, e.Handle(release("Print", "Mod4")), cmd("nop shot"))
	e.Handle(press("Print", "Mod4"))
	actionsEqual(t, e.Handle(release("Print", "Mod4")), cmd("nop shot"))
}

func TestPressAndReleaseBindsOnOneChordEachFireOnTheirOwnEvent(t *testing.T) {
	binds := []bind.Bind{
		{Chord: "Mod4+d", Actions: []bind.Action{bind.Command("nop press")}},
		{Chord: "Mod4+d", Actions: []bind.Action{bind.Command("nop release")}, OnRelease: true},
	}
	e, _, _ := buildEngine(engineOpts{binds: binds, layers: map[string]bind.Layer{}})
	actionsEqual(t, e.Handle(press("d", "Mod4")), cmd("nop press"))
	actionsEqual(t, e.Handle(release("d", "Mod4")), cmd("nop release"))
}

func TestOnReleaseIsDiscriminatedInsideALayerToo(t *testing.T) {
	layers := map[string]bind.Layer{"pick": {
		Binds: []bind.Bind{
			{Chord: "Return", Actions: []bind.Action{bind.Command("nop chose")}, OnRelease: true},
			{Chord: "j", Actions: []bind.Action{bind.Command("nop next")}},
		},
		ExitKeys: []string{"Escape"},
	}}
	binds := []bind.Bind{{Chord: "Mod4+w", Actions: []bind.Action{bind.EnterLayer{Layer: "pick"}}}}
	e, _, _ := buildEngine(engineOpts{binds: binds, layers: layers})
	e.Handle(press("w", "Mod4"))
	if out := e.Handle(press("Return")); len(out) != 0 {
		t.Fatalf("press fired the on_release bind: %+v", out)
	}
	actionsEqual(t, e.Handle(release("Return")), cmd("nop chose"))
	actionsEqual(t, e.Handle(press("j")), cmd("nop next"))
	if out := e.Handle(release("j")); len(out) != 0 {
		t.Fatalf("release of a press-only bind fired: %+v", out)
	}
}

func TestExitLayerVerbLeavesTheLayerAndIsNotDispatched(t *testing.T) {
	layers := map[string]bind.Layer{"pick": {
		Binds:    []bind.Bind{{Chord: "d", Actions: []bind.Action{bind.ExitLayer{}}}},
		ExitKeys: []string{"Escape"},
	}}
	binds := []bind.Bind{{Chord: "Mod4+w", Actions: []bind.Action{bind.EnterLayer{Layer: "pick"}}}}
	e, pub, _ := buildEngine(engineOpts{binds: binds, layers: layers})
	e.Handle(press("w", "Mod4"))
	if out := e.Handle(press("d")); len(out) != 0 {
		t.Fatalf("ExitLayer leaked into dispatch: %+v", out)
	}
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state after exit_layer(): %+v", got)
	}
	if last := pub.lines[len(pub.lines)-1]; last != (State{Layer: "default"}) {
		t.Fatalf("last published: %+v", last)
	}
}

func TestAKeyWhoseReleaseWasLostBecomesUsableAgain(t *testing.T) {
	e, _, clock := defaultEngine()
	e.Handle(press("o", "Mod4"))
	actionsEqual(t, e.Handle(press("h")), cmd("focus left"))
	if out := e.Handle(press("h")); len(out) != 0 {
		t.Fatalf("repeat not suppressed: %+v", out)
	}
	clock.Advance(KeyWedgeMS + 100)
	actionsEqual(t, e.Handle(press("h")), cmd("focus left"))
}

func TestBothHandsOfAModifierAreRecognised(t *testing.T) {
	for _, modKey := range []string{"Control_L", "Control_R"} {
		t.Run(modKey, func(t *testing.T) {
			e, _, _ := defaultEngine()
			e.Handle(press("o", "Mod4"))
			e.Handle(press(modKey))
			if got := e.State(); got != (State{Layer: "nav", Mod: "move"}) {
				t.Fatalf("state = %+v", got)
			}
			actionsEqual(t, e.Handle(press("h")), cmd("move left"))
		})
	}
}

func TestLayerBindsShadowGlobalBindsWhileALayerIsActive(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	actionsEqual(t, e.Handle(press("h", "Mod4")), cmd("focus left"))
}

func TestUnboundKeyInALayerDispatchesNothingAndStaysInTheLayer(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	if out := e.Handle(press("z")); len(out) != 0 {
		t.Fatalf("unbound key dispatched: %+v", out)
	}
	if e.State().Layer != "nav" {
		t.Fatalf("left the layer on an unbound key: %+v", e.State())
	}
}

func TestRunAndLayerVerbsComeBackAsActionObjects(t *testing.T) {
	binds := []bind.Bind{{Chord: "Mod4+p", Actions: []bind.Action{bind.Run{Cmd: "qs-overlay.sh projects"}}}}
	e, _, _ := buildEngine(engineOpts{binds: binds, layers: map[string]bind.Layer{}})
	actionsEqual(t, e.Handle(press("p", "Mod4")), run("qs-overlay.sh projects"))
}

func TestCallableActionIsInvokedNotReturned(t *testing.T) {
	var seenChord string
	f := bind.Func(func(ev bind.Event) error {
		seenChord = ev.Chord
		return nil
	})
	binds := []bind.Bind{{Chord: "Mod4+F1", Actions: []bind.Action{f}}}
	e, _, _ := buildEngine(engineOpts{binds: binds, layers: map[string]bind.Layer{}})
	if out := e.Handle(press("F1", "Mod4")); len(out) != 0 {
		t.Fatalf("callable action was returned instead of invoked: %+v", out)
	}
	// Deviation from python (which asserted seen == ["F1"], the raw key):
	// bind.Func's signature (landed by sp021 Task 5) only carries Chord +
	// OnRelease, not the raw key — see the package doc's "callable actions"
	// section. Chord is the closest available fact, and it IS the fired
	// bind's chord.
	if seenChord != "Mod4+F1" {
		t.Fatalf("callable saw chord %q, want %q", seenChord, "Mod4+F1")
	}
}

// -- exit keys ---------------------------------------------------------
// python: test_layers.py lines 300-441

func TestExitKeyWorksWhileALayerModifierIsStillHeld(t *testing.T) {
	cases := []struct{ modKey, label, canon string }{
		{"Control_L", "move", "Ctrl"},
		{"Alt_L", "resize", "Mod1"},
	}
	for _, c := range cases {
		t.Run(c.modKey, func(t *testing.T) {
			e, _, _ := defaultEngine()
			e.Handle(press("o", "Mod4"))
			e.Handle(press(c.modKey))
			if got := e.State(); got != (State{Layer: "nav", Mod: c.label}) {
				t.Fatalf("state = %+v", got)
			}
			e.Handle(press("q", c.canon))
			if got := e.State(); got != (State{Layer: "default"}) {
				t.Fatalf("state after exit key = %+v", got)
			}
		})
	}
}

func TestExitKeyWorksWhileShiftIsHeld(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	if got := e.State(); got != (State{Layer: "nav"}) {
		t.Fatalf("state = %+v", got)
	}
	e.Handle(press("q", "Shift"))
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state after exit key = %+v", got)
	}
	if last := pub.lines[len(pub.lines)-1]; last != (State{Layer: "default"}) {
		t.Fatalf("last published: %+v", last)
	}
}

func TestShiftHeldExitWorksFromInsideAModifierSublayer(t *testing.T) {
	// The :10 case: xrdp synthesises Shift around characters it sends, so a
	// Shift-flagged exit can arrive while Ctrl or Alt is genuinely held.
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	if got := e.State(); got != (State{Layer: "nav", Mod: "move"}) {
		t.Fatalf("state = %+v", got)
	}
	e.Handle(press("q", "Shift", "Ctrl"))
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state after exit key = %+v", got)
	}
}

func TestShiftDoesNotBecomeALayerModifier(t *testing.T) {
	e, _, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Shift_L"))
	if got := e.State(); got != (State{Layer: "nav"}) {
		t.Fatalf("Shift became a layer modifier: %+v", got)
	}
}

func TestLayerExitWhileAModifierIsHeldPublishesDefaultNotAStuckMod(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	pub.lines = nil
	e.Handle(press("Escape", "Ctrl"))
	if last := pub.lines[len(pub.lines)-1]; last != (State{Layer: "default"}) {
		t.Fatalf("last published: %+v", last)
	}
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
}

func TestStillHeldModifierAfterExitDoesNotReEnterAModState(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.Handle(press("o", "Mod4"))
	e.Handle(press("Control_L"))
	e.Handle(press("q", "Ctrl"))
	pub.lines = nil
	e.Handle(release("Control_L"))
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 0 {
		t.Fatalf("published after leaving: %+v", pub.lines)
	}
}

func TestAModsLessLayerIsStillLeftWithAModifierHeld(t *testing.T) {
	for _, modKey := range []string{"Control_L", "Alt_L", "Shift_L"} {
		t.Run(modKey, func(t *testing.T) {
			binds := []bind.Bind{{Chord: "$mod+o", Actions: []bind.Action{bind.EnterLayer{Layer: "plain"}}}}
			layers := map[string]bind.Layer{"plain": {
				Binds:    []bind.Bind{{Chord: "h", Actions: []bind.Action{bind.Command("focus left")}}},
				ExitKeys: []string{"q", "Escape"},
			}}
			e, _, _ := buildEngine(engineOpts{binds: binds, layers: layers})
			e.Handle(press("o", "Mod4"))
			if got := e.State(); got != (State{Layer: "plain"}) {
				t.Fatalf("state = %+v", got)
			}
			e.Handle(press(modKey))
			e.Handle(press("q", modKeysyms[modKey]))
			if e.State().Layer != "default" {
				t.Fatalf("a mods-less layer could not be left with %s held", modKey)
			}
		})
	}
}

func TestEveryDeclaredExitKeyLeavesTheLayer(t *testing.T) {
	for _, key := range []string{"q", "Escape", "Return"} {
		t.Run(key, func(t *testing.T) {
			e, _, _ := defaultEngine()
			e.Handle(press("o", "Mod4"))
			e.Handle(press(key))
			if e.State().Layer != "default" {
				t.Fatalf("exit key %q did not leave the layer", key)
			}
		})
	}
}

// -- "grabbed => must fire" and the real production table --------------
//
// python: test_every_layer_bind_the_grabber_registers_can_actually_fire
// (test_layers.py:405-433) iterates the REAL binds.py nav table and asserts
// every declared chord actually dispatches through the engine.
//
// DROPPED (with reason), not silently: this package's fixture nav (above)
// is a local stand-in, not the shipped table — cmd/hotkeyd/config.go IS the
// shipped table, and cmd/hotkeyd/config_test.go's golden-dump parity test
// (sp021 Task 6, bd dotfiles-ylmp.5, already landed) is what proves EVERY
// entry in the real table round-trips through bind.Validate. Re-running that
// same proof here against a duplicate copy of the table would just be two
// tests protecting one invariant from two places, and internal/layer's own
// test_plan is explicit: "zero X and zero i3" pure-unit tests over the
// ENGINE, not table transcription fidelity. The properties this python test
// actually protects — a layer bind's chord IS what fires, a sublayer bind
// resolves through the right modifier — are covered directly above
// (TestBareKeysFocusCtrlMovesAltResizesInTheNavLayer and friends) against
// this package's own fixture, which exercises the identical matching code
// path.

// -- source-device matching (sp020 Task 11, dotfiles-hwds.13) -----------
// python: test_layers.py lines 890-989

func evd(key string, m []string, device string, kind Kind) Event {
	ev := Event{Kind: kind, Key: key, Mods: mods(m...), Device: device}
	return ev
}

func tap(e *Engine, key string, m []string, device string) []bind.Action {
	out := e.Handle(evd(key, m, device, Press))
	e.Handle(evd(key, m, device, Release))
	return out
}

func TestAnUnscopedBindMatchesAnySource(t *testing.T) {
	e, _, _ := buildEngine(engineOpts{
		binds:  []bind.Bind{{Chord: "Mod4+o", Actions: []bind.Action{bind.Command("nop any")}}},
		layers: map[string]bind.Layer{},
	})
	for _, dev := range []string{"", "Keyboard A", "Virtual core XTEST keyboard"} {
		actionsEqual(t, tap(e, "o", []string{"Mod4"}, dev), cmd("nop any"))
	}
}

func TestAScopedGlobalBindFiresOnlyForItsDevice(t *testing.T) {
	e, _, _ := buildEngine(engineOpts{
		binds:  []bind.Bind{{Chord: "Mod4+o", Actions: []bind.Action{bind.Command("nop a")}, Device: "Keyboard A"}},
		layers: map[string]bind.Layer{},
	})
	actionsEqual(t, tap(e, "o", []string{"Mod4"}, "Keyboard A"), cmd("nop a"))
	if out := tap(e, "o", []string{"Mod4"}, "Keyboard B"); len(out) != 0 {
		t.Fatalf("wrong device fired: %+v", out)
	}
	if out := tap(e, "o", []string{"Mod4"}, ""); len(out) != 0 {
		t.Fatalf("unattributable event satisfied a device predicate: %+v", out)
	}
}

func TestOneChordResolvesToDifferentActionsPerSource(t *testing.T) {
	e, _, _ := buildEngine(engineOpts{
		binds: []bind.Bind{
			{Chord: "Mod4+o", Actions: []bind.Action{bind.Command("nop a")}, Device: "Keyboard A"},
			{Chord: "Mod4+o", Actions: []bind.Action{bind.Command("nop b")}, Device: "Keyboard B"},
		},
		layers: map[string]bind.Layer{},
	})
	actionsEqual(t, tap(e, "o", []string{"Mod4"}, "Keyboard A"), cmd("nop a"))
	actionsEqual(t, tap(e, "o", []string{"Mod4"}, "Keyboard B"), cmd("nop b"))
}

func TestAScopedBindIsTriedBeforeTheUnscopedFallback(t *testing.T) {
	e, _, _ := buildEngine(engineOpts{
		binds: []bind.Bind{
			{Chord: "Mod4+o", Actions: []bind.Action{bind.Command("nop a")}, Device: "Keyboard A"},
			{Chord: "Mod4+o", Actions: []bind.Action{bind.Command("nop any")}},
		},
		layers: map[string]bind.Layer{},
	})
	actionsEqual(t, tap(e, "o", []string{"Mod4"}, "Keyboard A"), cmd("nop a"))
	actionsEqual(t, tap(e, "o", []string{"Mod4"}, "Keyboard B"), cmd("nop any"))
}

func TestAScopedLayerBindFiresOnlyForItsDevice(t *testing.T) {
	layers := map[string]bind.Layer{"nav": {
		Binds:    []bind.Bind{{Chord: "h", Actions: []bind.Action{bind.Command("focus left")}, Device: "Keyboard A"}},
		ExitKeys: []string{"q"},
	}}
	e, _, _ := buildEngine(engineOpts{
		binds:  []bind.Bind{{Chord: "Mod4+o", Actions: []bind.Action{bind.EnterLayer{Layer: "nav"}}}},
		layers: layers,
	})
	e.Handle(evd("o", []string{"Mod4"}, "Keyboard A", Press))
	if e.State().Layer != "nav" {
		t.Fatalf("state = %+v", e.State())
	}
	if out := tap(e, "h", nil, "Keyboard B"); len(out) != 0 {
		t.Fatalf("wrong device fired in layer: %+v", out)
	}
	actionsEqual(t, tap(e, "h", nil, "Keyboard A"), cmd("focus left"))
}

func TestAScopedSublayerBindFiresOnlyForItsDevice(t *testing.T) {
	layers := map[string]bind.Layer{"nav": {
		Binds: []bind.Bind{{Chord: "h", Actions: []bind.Action{bind.Command("focus left")}}},
		Mods: map[string]bind.Mod{
			"move": {Modifier: "Ctrl", Binds: []bind.Bind{
				{Chord: "h", Actions: []bind.Action{bind.Command("move left")}, Device: "Keyboard A"},
			}},
		},
		ExitKeys: []string{"q"},
	}}
	e, _, _ := buildEngine(engineOpts{
		binds:  []bind.Bind{{Chord: "Mod4+o", Actions: []bind.Action{bind.EnterLayer{Layer: "nav"}}}},
		layers: layers,
	})
	e.Handle(evd("o", []string{"Mod4"}, "Keyboard A", Press))
	e.Handle(evd("Control_L", nil, "Keyboard A", Press))
	if e.State().Mod != "move" {
		t.Fatalf("state = %+v", e.State())
	}
	if out := tap(e, "h", nil, "Keyboard B"); len(out) != 0 {
		t.Fatalf("wrong device fired in sublayer: %+v", out)
	}
	actionsEqual(t, tap(e, "h", nil, "Keyboard A"), cmd("move left"))
}

func TestExitKeysAreNeverDeviceScoped(t *testing.T) {
	layers := map[string]bind.Layer{"nav": {
		Binds:    []bind.Bind{{Chord: "h", Actions: []bind.Action{bind.Command("focus left")}, Device: "Keyboard A"}},
		ExitKeys: []string{"q"},
	}}
	e, _, _ := buildEngine(engineOpts{
		binds:  []bind.Bind{{Chord: "Mod4+o", Actions: []bind.Action{bind.EnterLayer{Layer: "nav"}}}},
		layers: layers,
	})
	e.Handle(evd("o", []string{"Mod4"}, "Keyboard A", Press))
	e.Handle(evd("q", nil, "Keyboard B", Press))
	if e.State().Layer != "default" {
		t.Fatalf("device-scoped exit key trapped the layer: %+v", e.State())
	}
}

func TestAnEventBuiltWithoutADeviceIsUnchanged(t *testing.T) {
	e := Event{Kind: Press, Key: "h", Mods: map[string]bool{}}
	if e.Device != "" || e.DeviceID != nil {
		t.Fatalf("zero-value event carries a device: %+v", e)
	}
}

func TestTheEventCarriesTheSourceIDAlongsideTheName(t *testing.T) {
	id := 12
	e := Event{Kind: Press, Key: "h", Mods: map[string]bool{}, Device: "Keyboard A", DeviceID: &id}
	if e.Device != "Keyboard A" || e.DeviceID == nil || *e.DeviceID != 12 {
		t.Fatalf("event = %+v", e)
	}
}

// -- layer-transition log (dotfiles-hwds.27) -----------------------------
// python: test_layers.py lines 991-1102

func TestEnteringALayerLogsOneTransitionNamingTheTriggeringEvent(t *testing.T) {
	e, lines := loggedEngine(engineOpts{})
	e.Handle(xev(Press, "o", []string{"Mod4"}, 32, 0x40, "AT Translated Set 2 keyboard", 12))
	tr := transitions(*lines)
	if len(tr) != 1 {
		t.Fatalf("expected exactly one transition line, got %v", lines)
	}
	for _, want := range []string{"layer=default->nav", "trigger=press:o", "keycode=32",
		"mask=0x0040", "mods=Mod4", "sourceid=12", "AT Translated Set 2 keyboard", "held=none"} {
		if !contains(tr[0], want) {
			t.Fatalf("%q missing from %q", want, tr[0])
		}
	}
}

func TestLeavingALayerLogsTheTransitionAndTheKeyThatDidIt(t *testing.T) {
	var lines []string
	e, _, _ := buildEngine(engineOpts{log: func(m string) { lines = append(lines, m) }})
	e.Handle(xev(Press, "o", []string{"Mod4"}, 32, 0x40, "", 0))
	lines = nil
	e.Handle(xev(Press, "Escape", nil, 9, 0x0, "", 0))
	tr := transitions(lines)
	if len(tr) != 1 {
		t.Fatalf("lines: %v", lines)
	}
	if !contains(tr[0], "layer=nav->default") || !contains(tr[0], "keycode=9") || !contains(tr[0], "trigger=press:Escape") {
		t.Fatalf("line: %q", tr[0])
	}
}

func TestAHeldModifierSublayerChangeIsLoggedToo(t *testing.T) {
	var lines []string
	e, _, _ := buildEngine(engineOpts{log: func(m string) { lines = append(lines, m) }})
	e.Handle(xev(Press, "o", []string{"Mod4"}, 32, 0x40, "", 0))
	lines = nil
	e.Handle(xev(Press, "Alt_L", []string{"Mod4"}, 64, 0x40, "", 0))
	tr := transitions(lines)
	if len(tr) != 1 {
		t.Fatalf("lines: %v", lines)
	}
	if !contains(tr[0], "mod=none->resize") || !contains(tr[0], "keycode=64") {
		t.Fatalf("line: %q", tr[0])
	}
	if !contains(tr[0], "layer=nav->nav") {
		t.Fatalf("line: %q", tr[0])
	}
	if !contains(tr[0], "held=Mod1") {
		t.Fatalf("held not shown: %q", tr[0])
	}
}

func TestAnEventThatChangesNothingLogsNoTransition(t *testing.T) {
	e, lines := loggedEngine(engineOpts{})
	e.Handle(xev(Press, "z", nil, 52, 0, "", 0))
	e.Handle(xev(Release, "z", nil, 52, 0, "", 0))
	if tr := transitions(*lines); len(tr) != 0 {
		t.Fatalf("unexpected transitions: %v", tr)
	}
}

func TestAnUnattributableEventIsLoggedAsUnattributableNotGuessed(t *testing.T) {
	e, lines := loggedEngine(engineOpts{})
	e.Handle(Event{Kind: Press, Key: "o", Mods: mods("Mod4")})
	tr := transitions(*lines)
	if len(tr) != 1 {
		t.Fatalf("lines: %v", lines)
	}
	for _, want := range []string{"keycode=none", "sourceid=none", "device=none"} {
		if !contains(tr[0], want) {
			t.Fatalf("%q missing from %q", want, tr[0])
		}
	}
}

func TestTheTransitionLogNamesTheI3ModeTheEngineBelieved(t *testing.T) {
	e, lines := loggedEngine(engineOpts{})
	e.Handle(xev(Press, "o", []string{"Mod4"}, 32, 0x40, "", 0))
	tr := transitions(*lines)
	if len(tr) == 0 || !contains(tr[0], "i3_mode=default") {
		t.Fatalf("lines: %v", lines)
	}
}

// -- what CANNOT put the engine into a layer (hwds.27 causes 2 and 3) ----
// python: test_layers.py lines 1104-1137

func TestNoAmountOfI3ModeTrafficCanEnterALayer(t *testing.T) {
	e, pub, _ := defaultEngine()
	for _, name := range []string{"default", "resize", "default", "nav", "default", ""} {
		e.SetI3Mode(name)
		if e.State().Layer != "default" {
			t.Fatalf("i3 mode %q entered a layer", name)
		}
	}
	if len(pub.lines) != 0 {
		t.Fatalf("i3 mode traffic alone published: %+v", pub.lines)
	}
}

func TestReconcilingHoldsCanNeverEnterALayer(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.ReconcileHolds(mods("Mod1", "Ctrl", "Shift"))
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
	if len(pub.lines) != 0 {
		t.Fatalf("published: %+v", pub.lines)
	}
}

func TestAFreshEnginePublishesNothingAtAllBeforeTheFirstKey(t *testing.T) {
	e, pub, _ := defaultEngine()
	e.SetI3Mode("default")
	e.ReconcileHolds(map[string]bool{})
	if len(pub.lines) != 0 {
		t.Fatalf("published: %+v", pub.lines)
	}
	if got := e.State(); got != (State{Layer: "default"}) {
		t.Fatalf("state = %+v", got)
	}
}
