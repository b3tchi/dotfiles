package main

// daemonchecks.go drives the REAL Go daemon binary, on a real Xvfb, with a
// real i3, and grades what the outside world can see of it:
//
//	grab present         — probed by trying to take the same grab (two X
//	                       clients cannot both hold one passive grab, so a
//	                       refusal is the SERVER confirming the daemon
//	                       OBTAINED the chord, not merely requested it)
//	dispatch observed    — i3 Commands through a recording proxy in front of
//	                       the real i3; Run actions through stubs in a
//	                       sandbox HOME
//	layer transitions    — the state socket, one JSON line per change
//	device attribution   — the transition log's sourceid=/device= fields
//
// Every claim below is about behaviour, never about the daemon's private
// bookkeeping — which is the point of running the shipped binary rather than
// constructing one in-process.

import (
	"fmt"
	"strings"
	"time"

	"hotkeyd/internal/layer"
	"hotkeyd/internal/proc"
)

const (
	settle      = 250 * time.Millisecond
	stateWait   = 3 * time.Second
	dispatchGap = 1500 * time.Millisecond
)

func inNav(s State) bool      { return s.Layer == "nav" }
func inDefault(s State) bool  { return s.Layer == "default" }
func inSwitcher(s State) bool { return s.Layer == "switcher" }

// runDaemonChecks is the main daemon phase, on the display's own $mod.
func runDaemonChecks(rep *Reporter, rig *Rig, in *Injector, d *DaemonRig) {
	injecting := in.Available()

	n, mod, ok := d.GrabSummary()
	rep.Check(ok && n > 0, "the real daemon started and announced its grab set",
		fmt.Sprintf("%d chords, $mod=%s", n, mod))

	report, haveReport := proc.CurrentGrabReport(d.Display)
	rep.Check(haveReport && len(report.Missing) == 0,
		"the shipped table's whole grab set is obtainable on a real server — zero refusals",
		describeReport(report, haveReport))

	// -- grab present / absent, probed against the server -------------------
	probe := func(what, key string, mask uint32, wantOwned bool) {
		owned, detail, err := rig.ProbeOwned(key, mask)
		if err != nil {
			rep.Skip(what, "grab probe failed: "+err.Error())
			return
		}
		rep.Check(owned == wantOwned, what, detail)
	}

	probe("the daemon OBTAINED $mod+o — a rival XI2 grab on it is refused", "o", maskMod4, true)
	probe("bare h is NOT grabbed in the default layer — it belongs to applications", "h", 0, false)
	probe("Super_L is ungrabbed in the default layer, which is why a hold layer's commit cannot be gated on belief", "Super_L", 0, false)

	if !injecting {
		rep.Skip("$mod+o enters nav on a real server", "xdotool is not on PATH")
		return
	}

	// -- entering nav --------------------------------------------------------
	d.State.Reset()
	d.Log.Reset()
	_ = in.Tap("super+o")
	_, entered := d.State.Await(inNav, stateWait)
	rep.Check(entered, "$mod+o enters nav on a real server", describeStates(d.State.States()))

	rep.Judged(entered, probeOwned(rig, "h", 0), "entering nav GRABBED its bare keys",
		"a rival grab on bare h is refused while the layer is up", "the daemon never entered nav this run")
	rep.Judged(entered, probeOwned(rig, "Control_L", 0), "entering nav GRABBED the sublayer modifier key",
		"a rival grab on Control_L is refused while the layer is up", "the daemon never entered nav this run")

	// Shift-held exits: Ctrl/Alt work because their keysyms are grabbed, so
	// holding one starts an ACTIVE grab that delivers every following key.
	// Shift is not a layer modifier and gets no such grab, so `Shift+q` has
	// to be a passive grab in its own right or the key goes to the focused
	// window and the layer sticks. Asserted on the REAL grab set, because a
	// requested grab and an obtained one are not the same thing.
	var missingShift []string
	for _, k := range []string{"q", "Escape", "Return"} {
		if !probeOwned(rig, k, maskShift) {
			missingShift = append(missingShift, "Shift+"+k)
		}
	}
	rep.Judged(entered, len(missingShift) == 0,
		"entering nav OBTAINED a Shift-held grab for every exit key (q, Escape, Return)",
		fmt.Sprintf("missing: %v", missingShift), "the daemon never entered nav this run")

	// -- dispatch observed ---------------------------------------------------
	d.Proxy.Reset()
	_ = in.Tap("h")
	cmds, gotFocus := awaitCommand(d.Proxy, "focus left", dispatchGap)
	rep.Judged(entered, gotFocus, "bare h in nav DISPATCHES `focus left` to the real i3",
		fmt.Sprintf("%v", cmds), "the daemon never entered nav this run")

	// held Ctrl, for real, then h — the sublayer case
	d.State.Reset()
	_ = in.Down("Control_L")
	_, gotMove := d.State.Await(func(s State) bool { return s.Layer == "nav" && s.Mod == "move" }, stateWait)
	rep.Judged(entered, gotMove, "a really-held Ctrl is observed as the move sublayer",
		describeStates(d.State.States()), "the daemon never entered nav this run")

	d.Proxy.Reset()
	_ = in.Tap("h")
	cmds, gotMoveLeft := awaitCommand(d.Proxy, "move left", dispatchGap)
	rep.Judged(gotMove, gotMoveLeft, "Ctrl+h MOVES instead of focusing",
		fmt.Sprintf("%v", cmds), "the move sublayer was never observed this run")

	// exit while the modifier is still held — the carry-forward risk, live
	d.State.Reset()
	_ = in.Tap("q")
	_, leftHeld := d.State.Await(inDefault, stateWait)
	rep.Judged(gotMove, leftHeld, "q leaves the layer while Ctrl is still held",
		describeStates(d.State.States()), "the move sublayer was never observed this run")
	_ = in.Up("Control_L")
	time.Sleep(settle)
	rep.Judged(leftHeld, !probeOwned(rig, "h", 0), "leaving the layer RELEASED its bare keys again",
		"a rival grab on bare h is granted once the layer is down", "the layer never came down this run")

	// -- held Shift is not a sublayer ---------------------------------------
	d.State.Reset()
	_ = in.Tap("super+o")
	_, reEntered := d.State.Await(inNav, stateWait)
	if !reEntered {
		rep.Skip("held Shift does NOT become a sublayer", "could not re-enter nav")
		rep.Skip("Shift+q leaves the layer", "could not re-enter nav")
	} else {
		d.State.Reset()
		_ = in.Down("Shift_L")
		time.Sleep(settle + 200*time.Millisecond)
		gotSublayer := false
		for _, s := range d.State.States() {
			if s.Mod != "" {
				gotSublayer = true
			}
		}
		// The precondition this negative needs, read off the same run: the
		// daemon is STILL IN NAV and still holding its grabs. Without it a
		// dead daemon publishes no sublayer either, and "no sublayer" would
		// be free. (Caught by running this suite against the python daemon,
		// whose publisher does not replay on connect — the negative read
		// green off an empty state list.)
		stillUp := probeOwned(rig, "h", 0)
		rep.Judged(stillUp, !gotSublayer, "held Shift does NOT become a sublayer",
			describeStates(d.State.States()),
			"the daemon was not holding nav's bare keys, so nothing was under test")
		d.State.Reset()
		_ = in.Tap("q")
		_, leftShift := d.State.Await(inDefault, stateWait)
		rep.Check(leftShift, "Shift+q leaves the layer", describeStates(d.State.States()))
		_ = in.Up("Shift_L")
		time.Sleep(settle)
	}

	// -- auto-repeat coalescing, GATED on the measured repeat stream --------
	runRepeatCoalescing(rep, in, d)

	// -- repeat-filter FAIRNESS: what the guard must NOT swallow ------------
	runFairness(rep, in, d)

	// -- the TRANSITION LOG — the evidence hwds.27 had none of --------------
	runTransitionLogChecks(rep, rig, in, d)

	// -- the alt-tab HOLD layer ----------------------------------------------
	runSwitcherChecks(rep, rig, in, d)
}

func probeOwned(rig *Rig, key string, mask uint32) bool {
	owned, _, err := rig.ProbeOwned(key, mask)
	return err == nil && owned
}

func awaitCommand(p *I3Proxy, want string, timeout time.Duration) ([]string, bool) {
	deadline := time.Now().Add(timeout)
	for {
		got := p.Commands()
		for _, c := range got {
			if strings.Contains(c, want) {
				return got, true
			}
		}
		if time.Now().After(deadline) {
			return got, false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func describeStates(all []State) string {
	parts := make([]string, 0, len(all))
	for _, s := range all {
		parts = append(parts, s.String())
	}
	if len(parts) == 0 {
		return "no state was published at all"
	}
	return strings.Join(parts, " -> ")
}

func describeReport(r *proc.GrabReport, ok bool) string {
	if !ok || r == nil {
		return "no grab report was published for this display"
	}
	return fmt.Sprintf("wanted=%d active=%d missing=%v", r.Wanted, r.Active, r.Missing)
}

// runRepeatCoalescing is live_check.py's judged() case, out of process: hold
// a nav bare key and count DISPATCHES rather than events.
func runRepeatCoalescing(rep *Reporter, in *Injector, d *DaemonRig) {
	const what = "a held key fires ONCE despite the real auto-repeat stream"
	if !in.Available() {
		rep.Skip(what, "xdotool is not on PATH")
		return
	}
	d.State.Reset()
	_ = in.Tap("super+o")
	if _, ok := d.State.Await(inNav, stateWait); !ok {
		rep.Skip(what, "could not enter nav")
		return
	}
	d.Proxy.Reset()
	_ = in.Down("h")
	time.Sleep(1200 * time.Millisecond)
	_ = in.Up("h")
	time.Sleep(dispatchGap)
	cmds := d.Proxy.Commands()
	n := 0
	for _, c := range cmds {
		if strings.Contains(c, "focus left") {
			n++
		}
	}
	// THE GATE: the claim is judged only if the server really produced a
	// repeat stream on this run (measured in the mechanism phase). Without
	// it, "1 dispatch" would be free — the exact vacuity im009 is about.
	rep.Judged(facts.Repeat.Held(), n == 1, what,
		fmt.Sprintf("%d dispatches from a %s hold (%s)", n, "1.2s", facts.Repeat.Detail),
		"no repeat stream was measured on this run ("+facts.Repeat.Detail+"), so 1 dispatch would be free")
	d.State.Reset()
	_ = in.Tap("q")
	_, _ = d.State.Await(inDefault, stateWait)
}

func runFairness(rep *Reporter, in *Injector, d *DaemonRig) {
	const (
		whatDouble = "a 10 ms double-tap dispatches TWICE — the release+press pair between the taps is NOT swallowed"
		whatRoll   = "a same-millisecond release+press of DIFFERENT keys keeps BOTH — fast rolling typing inside a layer loses no keystroke"
	)
	if !in.Available() {
		rep.Skip(whatDouble, "xdotool is not on PATH")
		rep.Skip(whatRoll, "xdotool is not on PATH")
		return
	}
	d.State.Reset()
	_ = in.Tap("super+o")
	_, ok := d.State.Await(inNav, stateWait)
	rep.Check(ok, "still in nav for the repeat-filter fairness checks", describeStates(d.State.States()))
	if !ok {
		rep.Skip(whatDouble, "not in nav")
		rep.Skip(whatRoll, "not in nav")
		return
	}

	d.Proxy.Reset()
	_ = in.TapSequence(10, "h", "h")
	time.Sleep(dispatchGap)
	got := countCommands(d.Proxy.Commands(), "focus left")
	rep.Judged(facts.DoubleTapAdjacent, got == 2, whatDouble,
		fmt.Sprintf("%d dispatches of `focus left`", got),
		"the 10 ms double-tap never produced the release+press adjacency this run, so this claim was untested")

	d.Proxy.Reset()
	_ = in.TapSequence(0, "h", "j")
	time.Sleep(dispatchGap)
	cmds := d.Proxy.Commands()
	left := countCommands(cmds, "focus left")
	down := countCommands(cmds, "focus down")
	rep.Judged(facts.RollingSameMillisecond, left == 1 && down == 1, whatRoll,
		fmt.Sprintf("focus left x%d, focus down x%d (%v)", left, down, cmds),
		"the rolling pair never landed on ONE millisecond this run, so this claim was untested")

	d.State.Reset()
	_ = in.Tap("q")
	_, _ = d.State.Await(inDefault, stateWait)
}

func countCommands(cmds []string, want string) int {
	n := 0
	for _, c := range cmds {
		if strings.Contains(c, want) {
			n++
		}
	}
	return n
}

// runTransitionLogChecks grades the three DISCRIMINATING fields of the
// transition line, filled with real values off a real server: a keycode this
// keymap actually uses, the mask the server actually sent, and the device
// that actually produced the key. Each is `none` unless the whole
// XI2 -> event -> engine chain carries it, and each is `none` in a log
// written from engine state alone.
func runTransitionLogChecks(rep *Reporter, rig *Rig, in *Injector, d *DaemonRig) {
	if !in.Available() {
		rep.Skip("entering nav on a real server emits exactly one transition line", "xdotool is not on PATH")
		return
	}
	_, back := d.State.Await(inDefault, stateWait)
	rep.Check(back || len(d.State.States()) == 0, "back in the default layer for the transition-log checks",
		describeStates(d.State.States()))

	d.Log.Reset()
	d.State.Reset()
	_ = in.Tap("super+o")
	_, entered := d.State.Await(inNav, stateWait)
	time.Sleep(settle)

	trs := transitions(d.Log.Lines())
	var enter *Transition
	for i := range trs {
		if trs[i].From == "default" && trs[i].To == "nav" {
			enter = &trs[i]
		}
	}
	rep.Judged(entered, len(trs) == 1 && enter != nil,
		"entering nav on a real server emits exactly one transition line",
		fmt.Sprintf("%d transition lines: %v", len(trs), rawOf(trs)),
		"the daemon never entered nav this run")
	if enter == nil {
		rep.Skip("the transition names the keycode the server sent", "no default->nav transition line this run")
		rep.Skip("and the modifier mask the event arrived with", "no default->nav transition line this run")
		rep.Skip("and the SOURCE DEVICE that produced the key", "no default->nav transition line this run")
	} else {
		wantCode, err := rig.Keycode("o")
		rep.Check(err == nil && enter.Keycode == fmt.Sprint(wantCode),
			fmt.Sprintf("the transition names the keycode the server sent (%d)", wantCode), enter.Raw)
		rep.Check(enter.MaskPresent && enter.Mask&uint64(maskMod4) != 0,
			"and the modifier mask the event arrived with", enter.Raw)
		// EDGE CASE: injected input comes from the XTEST slave, so the
		// device this names is the injector — which is exactly the field
		// that separates an injected $mod+o from a typed one after the
		// fact. A claim about a PHYSICAL slave would need a human.
		rep.Check(strings.HasSuffix(enter.Device, "XTEST keyboard") && enter.SourceID != "",
			"and the SOURCE DEVICE that produced the key — here the XTEST injector, the only field that separates an injected $mod+o from a typed one",
			enter.Raw)
	}

	d.Log.Reset()
	d.State.Reset()
	_ = in.Tap("q")
	_, left := d.State.Await(inDefault, stateWait)
	time.Sleep(settle)
	trs = transitions(d.Log.Lines())
	qCode, _ := rig.Keycode("q")
	okLeave := len(trs) == 1 && trs[0].From == "nav" && trs[0].To == "default" && trs[0].Keycode == fmt.Sprint(qCode)
	rep.Judged(left, okLeave, "and leaving nav names the key that did it",
		fmt.Sprintf("%v", rawOf(trs)), "the daemon never left nav this run")
}

func rawOf(trs []Transition) []string {
	out := make([]string, 0, len(trs))
	for _, t := range trs {
		out = append(out, t.Raw)
	}
	return out
}

// runSwitcherChecks drives the alt-tab HOLD layer on a real server: the
// first layer whose modifier is ALREADY DOWN when the layer is entered.
// Everything hard about it is a property of the real X server — whether the
// grab set can be obtained, and what a passive grab does about a key that
// was already held when it was installed.
func runSwitcherChecks(rep *Reporter, rig *Rig, in *Injector, d *DaemonRig) {
	if !in.Available() {
		rep.Skip("$mod+Tab opens the switcher and takes the layer", "xdotool is not on PATH")
		return
	}
	d.State.Reset()
	d.ResetActions()

	// $mod goes down FIRST, as a real hold.
	_ = in.Down("Super_L")
	time.Sleep(settle)
	_ = in.Tap("Tab")
	_, opened := d.State.Await(inSwitcher, stateWait)
	rep.Check(opened, "$mod+Tab opens the switcher and takes the layer", describeStates(d.State.States()))
	acts, gotOpen := d.AwaitAction("switcher", dispatchGap)
	rep.Judged(opened, gotOpen, "and DISPATCHES the layer's own action", fmt.Sprintf("%v", acts),
		"the switcher layer never opened this run")

	rep.Judged(opened, !probeOwned(rig, "Super_L", 0),
		"entering the layer did NOT grab the held modifier's keysym — a passive grab on a key that is already down never activates",
		"a rival grab on Super_L is still granted", "the switcher layer never opened this run")

	report, haveReport := proc.CurrentGrabReport(d.Display)
	rep.Judged(opened, haveReport && len(report.Missing) == 0,
		"and the layer's grabs cost zero refusals", describeReport(report, haveReport),
		"the switcher layer never opened this run")

	for _, c := range []struct {
		key  string
		mask uint32
		name string
	}{
		{"Escape", maskMod4, "$mod+Escape"},
		{"q", 0, "q"},
	} {
		rep.Judged(opened, probeOwned(rig, c.key, c.mask),
			c.name+" was actually GRABBED, not merely requested", "a rival grab on it is refused",
			"the switcher layer never opened this run")
	}
	for _, c := range []struct {
		key  string
		mask uint32
		name string
	}{
		{"Super_R", 0, "Super_R"},
		{"q", maskMod4 | maskShift, "$mod+Shift+q"},
	} {
		rep.Judged(opened, !probeOwned(rig, c.key, c.mask),
			c.name+" is deliberately absent from a hold layer's grab set", "a rival grab on it is granted",
			"the switcher layer never opened this run")
	}

	d.ResetActions()
	_ = in.Tap("Tab")
	acts, gotNext := d.AwaitAction("switcher", dispatchGap)
	rep.Judged(opened, gotNext, "a second Tab, still with $mod down, cycles forwards", fmt.Sprintf("%v", acts),
		"the switcher layer never opened this run")

	d.ResetActions()
	_ = in.Tap("shift+Tab")
	acts, gotPrev := d.AwaitAction("switcher-prev", dispatchGap)
	rep.Judged(opened, gotPrev,
		"and Shift+Tab cycles BACKWARDS on a real server — the end-to-end version of the ISO_Left_Tab keysym check",
		fmt.Sprintf("%v", acts), "the switcher layer never opened this run")

	// While $mod is genuinely down the server confirms it and nothing ends.
	// Both halves are graded: the layer stays up, AND the hold-release
	// action is NOT dispatched. Only the second one can tell "the poll
	// correctly found $mod down" from "the poll never ran".
	d.ResetActions()
	time.Sleep(3 * IdleTickEquivalent)
	cur, _ := d.State.Current()
	held := d.Actions()
	rep.Judged(opened, len(held) == 0,
		"while $mod is genuinely down the server confirms it and the hold-release action is NOT dispatched",
		fmt.Sprintf("%v", held), "the switcher layer never opened this run")
	rep.Judged(opened, cur.Layer == "switcher", "the layer is still up",
		cur.String(), "the switcher layer never opened this run")

	// THE RELEASE-BEFORE-GRAB RACE: $mod comes up and the daemon cannot see
	// it — there is no grab that could deliver it — so without the server
	// poll the layer would stand here forever with its keys eaten
	// session-wide.
	d.ResetActions()
	d.State.Reset()
	_ = in.Up("Super_L")
	_, ended := d.State.Await(inDefault, stateWait)
	rep.Judged(opened, ended, "releasing $mod ends the layer — the server poll, not an event, is what ends a hold layer",
		describeStates(d.State.States()), "the switcher layer never opened this run")
	acts, gotCommit := d.AwaitAction("switcher-confirm", dispatchGap)
	rep.Judged(ended, gotCommit, "and the commit was DISPATCHED, not merely implied by the exit",
		fmt.Sprintf("%v", acts), "the layer never came down this run")
	rep.Judged(ended, !probeOwned(rig, "Tab", 0),
		"the layer's bare keys went back to applications with it",
		"a rival grab on bare Tab is granted again", "the layer never came down this run")
}

// IdleTickEquivalent mirrors cmd/hotkeyd's IdleTick. Duplicated rather than
// imported because that package is `main`; a drift would only make this wait
// longer or shorter, never change a verdict.
const IdleTickEquivalent = 250 * time.Millisecond

// runModOneChecks is live_check.py's :10 shape: `$mod` is not a constant.
// The xrdp session merges `i3wm.mod: Mod1` before exec'ing i3 (ft003 /
// adr0004), so :10 and :0 genuinely disagree about what `$mod+o` means.
// Every check above ran where the detected mod and the Mod4 default are the
// SAME VALUE — so the grab-set -> engine wiring was only exercised where a
// break in it is invisible.
func runModOneChecks(rep *Reporter, rig *Rig, in *Injector, d *DaemonRig) {
	// The resource itself, read back off the LIVE display through the same
	// request the daemon's ResolveMod uses (RESOURCE_MANAGER is predefined
	// atom 23, so no InternAtom is needed). Distinct from the daemon's
	// detection below: this asks whether the merge survived on the server,
	// which is the half X discards when the last client disconnects.
	const resourceManagerAtom, stringAtom = 23, 31
	_, _, value, err := rig.Conn.GetPropertyAll(rig.Root, resourceManagerAtom, stringAtom)
	rep.Check(err == nil && strings.Contains(string(value), "i3wm.mod"),
		"i3wm.mod: Mod1 merged onto the live display is readable back off the root window",
		fmt.Sprintf("err=%v RESOURCE_MANAGER=%q", err, strings.TrimSpace(string(value))))

	n, mod, ok := d.GrabSummary()
	rep.Check(ok && mod == "Mod1", "the daemon detected $mod=Mod1 for itself on a display carrying i3wm.mod: Mod1",
		fmt.Sprintf("%d chords, $mod=%s", n, mod))
	if !in.Available() {
		rep.Skip("Super+o does NOT enter nav where $mod is Mod1", "xdotool is not on PATH")
		return
	}

	// Super+o is what $mod+o means on :0 and NOTHING on :10. Checked first
	// so a daemon that grabbed both modifiers cannot pass the next check by
	// accident.
	d.State.Reset()
	_ = in.Tap("super+o")
	time.Sleep(settle + 300*time.Millisecond)
	sawNav := false
	for _, s := range d.State.States() {
		if s.Layer == "nav" {
			sawNav = true
		}
	}
	// Same gate: a daemon that is dead, or that grabbed nothing, also fails
	// to enter nav. The precondition is that it really did obtain Alt+o on
	// the Mod1 mask, asked on this run.
	holdsAltO := probeOwned(rig, "o", maskMod1)
	rep.Judged(holdsAltO, !sawNav, "Super+o does NOT enter nav where $mod is Mod1",
		describeStates(d.State.States()),
		"the daemon does not hold Alt+o on this display, so a quiet Super+o proves nothing")

	// Alt+o has to survive BOTH hops — grabbed on the Mod1 mask, and then
	// matched by an engine that also knows $mod is Mod1.
	d.State.Reset()
	d.Proxy.Reset()
	_ = in.Tap("alt+o")
	_, entered := d.State.Await(inNav, stateWait)
	rep.Check(entered, "Alt+o DOES enter nav where $mod is Mod1 — grab set and engine agree on the display's own modifier",
		describeStates(d.State.States()))
	rep.Judged(entered, probeOwned(rig, "h", 0), "and the layer's bare keys were grabbed on the way in",
		"a rival grab on bare h is refused", "the daemon never entered nav on the Mod1 display")

	_ = in.Tap("h")
	cmds, gotDispatch := awaitCommand(d.Proxy, "focus left", dispatchGap)
	rep.Judged(entered, gotDispatch, "a nav bind dispatches on the Mod1 display", fmt.Sprintf("%v", cmds),
		"the daemon never entered nav on the Mod1 display")

	d.State.Reset()
	_ = in.Tap("q")
	_, left := d.State.Await(inDefault, stateWait)
	rep.Judged(entered, left, "q leaves nav on the Mod1 display", describeStates(d.State.States()),
		"the daemon never entered nav on the Mod1 display")
}

// runSingleInstanceCheck starts a SECOND daemon on the same display and
// asserts it refuses to run.
func runSingleInstanceCheck(rep *Reporter, d *DaemonRig) {
	code, out := d.RunOnce(10*time.Second, "--display", d.Display)
	rep.Check(code == 3, "a second instance on the same display is refused (exit 3)",
		fmt.Sprintf("exit=%d %s", code, firstLine(out)))
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// stateSocketPath is where the daemon publishes for this display.
func stateSocketPath(display string) string { return layer.SocketPath(display) }
