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
	// `missing` is EMPTY for a daemon that wanted nothing, so the wanted
	// count is part of the claim: "zero refusals" out of zero requests is
	// not the statement this line makes.
	rep.Check(haveReport && report.Wanted > 0 && len(report.Missing) == 0,
		"the shipped table's whole grab set is obtainable on a real server — zero refusals",
		describeReport(report, haveReport))

	// -- grab present / absent, probed against the server -------------------
	// THE POSITIVE FIRST, because the two negatives below are gated on it. A
	// daemon that grabbed nothing at all — dead, wedged, or started against
	// the wrong display — also fails to grab bare h and Super_L, and would
	// collect two green lines for claims nothing was under test in
	// ([[im009]]). The gate is the same shape the switcher and Mod1 sections
	// use: a negative is only judged where its positive sibling proved the
	// mechanism was live on this run.
	holdsModO, modODetail, modOErr := rig.ProbeOwned("o", maskMod4)
	rep.Check(modOErr == nil && holdsModO,
		"the daemon OBTAINED $mod+o — a rival XI2 grab on it is refused",
		probeDetail(modODetail, modOErr))

	absent := func(what, key string, mask uint32) {
		owned, detail, err := rig.ProbeOwned(key, mask)
		if err != nil {
			rep.Skip(what, "grab probe failed: "+err.Error())
			return
		}
		rep.Judged(holdsModO, !owned, what, detail,
			"the daemon was not holding $mod+o either, so it was holding no default-layer grab set for this key to be absent from")
	}
	absent("bare h is NOT grabbed in the default layer — it belongs to applications", "h", 0)
	absent("Super_L is ungrabbed in the default layer, which is why a hold layer's commit cannot be gated on belief", "Super_L", 0)

	if !injecting {
		rep.Skip("$mod+o enters nav on a real server", "xdotool is not on PATH")
		return
	}

	// -- entering nav --------------------------------------------------------
	// The baseline for the settle signal is taken BEFORE the injection: what
	// proves nav's grab set landed is the report being published AGAIN, and
	// that is only answerable against a value read before the trigger.
	d.State.Reset()
	d.Log.Reset()
	navWatch := watchGrabs(d.Display)
	_ = in.Tap("super+o")
	_, entered := d.State.Await(inNav, stateWait)
	rep.Check(entered, "$mod+o enters nav on a real server", describeStates(d.State.States()))
	navLanded, navWhy := navWatch.settled(grabSettleTimeout)
	navUp, navUpWhy := gatedOn(
		gate{entered, "the daemon never entered nav this run"},
		gate{navLanded, "nav's grab set was never observed to land — " + navWhy},
	)

	navHoldsBare := rep.Judged(navUp, probeOwned(rig, "h", 0), "entering nav GRABBED its bare keys",
		"a rival grab on bare h is refused while the layer is up", navUpWhy)
	rep.Judged(navUp, probeOwned(rig, "Control_L", 0), "entering nav GRABBED the sublayer modifier key",
		"a rival grab on Control_L is refused while the layer is up", navUpWhy)

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
	rep.Judged(navUp, len(missingShift) == 0,
		"entering nav OBTAINED a Shift-held grab for every exit key (q, Escape, Return)",
		fmt.Sprintf("missing: %v", missingShift), navUpWhy)

	// -- dispatch observed ---------------------------------------------------
	d.Proxy.Reset()
	_ = in.Tap("h")
	cmds, gotFocus := awaitCommand(d.Proxy, "focus left", dispatchGap)
	rep.Judged(navUp, gotFocus, "bare h in nav DISPATCHES `focus left` to the real i3",
		fmt.Sprintf("%v", cmds), navUpWhy)

	// held Ctrl, for real, then h — the sublayer case
	d.State.Reset()
	_ = in.Down("Control_L")
	_, gotMove := d.State.Await(func(s State) bool { return s.Layer == "nav" && s.Mod == "move" }, stateWait)
	rep.Judged(navUp, gotMove, "a really-held Ctrl is observed as the move sublayer",
		describeStates(d.State.States()), navUpWhy)

	d.Proxy.Reset()
	_ = in.Tap("h")
	cmds, gotMoveLeft := awaitCommand(d.Proxy, "move left", dispatchGap)
	rep.Judged(gotMove, gotMoveLeft, "Ctrl+h MOVES instead of focusing",
		fmt.Sprintf("%v", cmds), "the move sublayer was never observed this run")

	// exit while the modifier is still held — the carry-forward risk, live
	d.State.Reset()
	leaveWatch := watchGrabs(d.Display)
	_ = in.Tap("q")
	_, leftHeld := d.State.Await(inDefault, stateWait)
	rep.Judged(gotMove, leftHeld, "q leaves the layer while Ctrl is still held",
		describeStates(d.State.States()), "the move sublayer was never observed this run")
	_ = in.Up("Control_L")
	time.Sleep(settle)
	downLanded, downWhy := leaveWatch.settled(grabSettleTimeout)
	// FOUR preconditions, all read off this run. The third is the one a
	// negative like this always needs: bare h has to have BEEN grabbed for
	// "it is grabbed no longer" to say anything at all. The fourth is the
	// probe's own liveness, which absentProbe reports rather than folding
	// into a false "nobody holds it".
	freeH, freeHGate := absentProbe(rig, "h", 0)
	downPre, downPreWhy := gatedOn(
		gate{leftHeld, "the layer never came down this run"},
		gate{navHoldsBare, "nav's bare keys were never observed grabbed in the first place, so a granted rival grab now proves nothing"},
		gate{downLanded, "the post-exit grab set was never observed to land — " + downWhy},
		freeHGate,
	)
	rep.Judged(downPre, freeH, "leaving the layer RELEASED its bare keys again",
		"a rival grab on bare h is granted once the layer is down", downPreWhy)

	// -- held Shift is not a sublayer ---------------------------------------
	d.State.Reset()
	reWatch := watchGrabs(d.Display)
	_ = in.Tap("super+o")
	_, reEntered := d.State.Await(inNav, stateWait)
	reLanded, reWhy := reWatch.settled(grabSettleTimeout)
	if !reEntered || !reLanded {
		why := "could not re-enter nav"
		if reEntered {
			why = "nav's grab set was never observed to land on re-entry — " + reWhy
		}
		rep.Skip("held Shift does NOT become a sublayer", why)
		rep.Skip("Shift+q leaves the layer", why)
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

// gate is one precondition plus the reason to print when it does not hold.
// Claims here usually need SEVERAL preconditions read off the same run —
// "the layer opened", "its grab set landed", "the key we are about to find
// absent was present while the layer was up" — and an operator reading a
// SKIP needs to know WHICH one was missing, not that some conjunction was
// false.
type gate struct {
	ok  bool
	why string
}

// gatedOn returns whether every gate holds, and the reason of the first one
// that does not.
func gatedOn(gates ...gate) (bool, string) {
	for _, g := range gates {
		if !g.ok {
			return false, g.why
		}
	}
	return true, ""
}

func probeOwned(rig *Rig, key string, mask uint32) bool {
	owned, _, err := rig.ProbeOwned(key, mask)
	return err == nil && owned
}

// absentProbe is the NEGATIVE form of a grab probe, kept honest about its own
// failure.
//
// rig.ProbeOwned answers owned=false BOTH when the chord is genuinely free and
// when the probe could not be taken at all, so `!probeOwned(...)` grades a
// broken probe as proof of absence — the helper's failure mode equalling its
// pass condition, the same shape that made DaemonRig.Actions unsafe for an
// empty-list claim. The returned gate is false when the probe errored, so the
// claim SKIPs with the error visible instead of collecting a free PASS.
func absentProbe(rig *Rig, key string, mask uint32) (free bool, g gate) {
	owned, _, err := rig.ProbeOwned(key, mask)
	if err != nil {
		return false, gate{false, fmt.Sprintf(
			"the rival grab probe for %q could not be taken at all (%v), so nothing was asked about its absence", key, err)}
	}
	return !owned, gate{true, ""}
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

// probeDetail renders a ProbeOwned result for a report line, keeping the
// error visible rather than letting an empty detail read as a quiet answer.
func probeDetail(detail string, err error) string {
	if err != nil {
		return "grab probe failed: " + err.Error()
	}
	return detail
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
	// `back || len(States()) == 0` used to stand here, which wrote
	// ABSENCE OF EVIDENCE straight into the pass expression: a run whose state
	// channel published nothing at all printed
	// "PASS back in the default layer ... — no state was published at all".
	// report.go:60-67 says that must never happen. The empty case is not a
	// pass, it is a run that could not be asked, so it is the GATE — read off
	// the same channel the claim's evidence comes from.
	rep.Judged(len(d.State.States()) > 0, back,
		"back in the default layer for the transition-log checks",
		describeStates(d.State.States()),
		"no state was published on this daemon's socket at all, so which layer it is in is unknown")

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
	openWatch := watchGrabs(d.Display)
	_ = in.Down("Super_L")
	time.Sleep(settle)
	_ = in.Tap("Tab")
	_, opened := d.State.Await(inSwitcher, stateWait)
	rep.Check(opened, "$mod+Tab opens the switcher and takes the layer", describeStates(d.State.States()))
	openLanded, openWhy := openWatch.settled(grabSettleTimeout)
	up, upWhy := gatedOn(
		gate{opened, "the switcher layer never opened this run"},
		gate{openLanded, "the switcher layer's grab set was never observed to land — " + openWhy},
	)

	acts, gotOpen := d.AwaitAction("switcher", dispatchGap)
	rep.Judged(opened, gotOpen, "and DISPATCHES the layer's own action", fmt.Sprintf("%v", acts),
		"the switcher layer never opened this run")

	// EVERY PROBE OF THE LAYER'S GRAB SET, TAKEN HERE, IN ONE PLACE — because
	// the negatives below are gated on the positives, and a gate is only
	// worth anything when both halves are read off the same moment of the
	// same run.
	//
	// THE FAILURE THIS CLOSES (found by audit, with a 600 ms delay injected
	// into resyncGrabs to model python's slower sync): the two "deliberately
	// absent" claims were gated on `opened` alone — the state socket — and
	// so PASSED while the hold layer's grab set was demonstrably NOT
	// installed. The same run FAILED their positive siblings, which is the
	// proof: nothing was grabbed, so of course Super_R was not. A negative
	// that does not verify the mechanism was live is the most dangerous
	// shape a live check has, and this suite already knew the cure — the
	// held-Shift negative above is gated on `probeOwned(rig, "h", 0)`.
	grabbedEscape := probeOwned(rig, "Escape", maskMod4)
	grabbedQ := probeOwned(rig, "q", 0)
	// Silent (ungraded) precondition for the teardown claim at the end of
	// this function: bare Tab must have been HELD while the layer was up for
	// "the layer's bare keys went back to applications" to mean anything.
	tabHeldWhileUp := probeOwned(rig, "Tab", 0)
	// The layer's grab set is demonstrably installed on this run.
	setUp, setUpWhy := gatedOn(
		gate{grabbedEscape && grabbedQ,
			fmt.Sprintf("the switcher layer's own grab set was NOT observed installed on this run "+
				"(rival grabs on $mod+Escape and q came back owned=%v/%v, and the layer's own chords must be owned "+
				"before an UNowned key says anything about the table's intent)", grabbedEscape, grabbedQ)},
	)

	freeSuperL, freeSuperLGate := absentProbe(rig, "Super_L", 0)
	superLPre, superLWhy := gatedOn(gate{setUp, setUpWhy}, freeSuperLGate)
	rep.Judged(superLPre, freeSuperL,
		"entering the layer did NOT grab the held modifier's keysym — a passive grab on a key that is already down never activates",
		"a rival grab on Super_L is still granted", superLWhy)

	// CHANNEL MATCH. This claim's EVIDENCE is the grab report on disk, so its
	// gate needs a same-run positive off THE GRAB REPORT — `openLanded`, the
	// observed republication that proves the switcher's own sync completed and
	// wrote. `setUp` alone (two rival grab probes) does not supply one: the
	// probes can be refused by a layer that is genuinely installed while the
	// report on disk is still the DEFAULT layer's, not yet republished, and
	// this line would then grade the default layer's numbers under the
	// switcher's name. The grab-probe half stays as well, because the claim
	// is about THE LAYER's grab set and a report published by a daemon that
	// never installed one also refuses nothing.
	reportPre, reportWhy := gatedOn(
		gate{openLanded, "the switcher layer's grab report was never observed to be republished — " + openWhy},
		gate{setUp, setUpWhy},
	)
	report, haveReport := proc.CurrentGrabReport(d.Display)
	rep.Judged(reportPre, haveReport && report.Wanted > 0 && len(report.Missing) == 0,
		"and the layer's grabs cost zero refusals", describeReport(report, haveReport), reportWhy)

	for _, c := range []struct {
		owned bool
		name  string
	}{
		{grabbedEscape, "$mod+Escape"},
		{grabbedQ, "q"},
	} {
		rep.Judged(up, c.owned,
			c.name+" was actually GRABBED, not merely requested", "a rival grab on it is refused", upWhy)
	}
	for _, c := range []struct {
		key  string
		mask uint32
		name string
	}{
		{"Super_R", 0, "Super_R"},
		{"q", maskMod4 | maskShift, "$mod+Shift+q"},
	} {
		free, freeGate := absentProbe(rig, c.key, c.mask)
		pre, why := gatedOn(gate{setUp, setUpWhy}, freeGate)
		rep.Judged(pre, free,
			c.name+" is deliberately absent from a hold layer's grab set", "a rival grab on it is granted", why)
	}

	d.ResetActions()
	_ = in.Tap("Tab")
	acts, gotNext := d.AwaitAction("switcher", dispatchGap)
	rep.Judged(up, gotNext, "a second Tab, still with $mod down, cycles forwards", fmt.Sprintf("%v", acts), upWhy)

	d.ResetActions()
	_ = in.Tap("shift+Tab")
	acts, gotPrev := d.AwaitAction("switcher-prev", dispatchGap)
	rep.Judged(up, gotPrev,
		"and Shift+Tab cycles BACKWARDS on a real server — the end-to-end version of the ISO_Left_Tab keysym check",
		fmt.Sprintf("%v", acts), upWhy)

	// While $mod is genuinely down the server confirms it and nothing ends.
	// Both halves are graded: the layer stays up, AND the hold-release action
	// is NOT dispatched. The second is a NEGATIVE about a poll, and a poll
	// that never ran dispatches nothing either — so it is graded further
	// down, once the release has PROVEN this daemon's idle poll runs. The
	// measurement is taken here, while $mod is really down; only the verdict
	// waits.
	d.ResetActions()
	time.Sleep(3 * IdleTickEquivalent)
	cur, _ := d.State.Current()
	// ActionsOK, not Actions: the claim below PASSES on an empty list, and
	// Actions returns an empty list for an unreadable log too. The read's own
	// success is carried forward as a gate.
	heldDuring, heldReadable := d.ActionsOK()
	rep.Judged(up, cur.Layer == "switcher", "the layer is still up", cur.String(), upWhy)

	// THE RELEASE-BEFORE-GRAB RACE: $mod comes up and the daemon cannot see
	// it — there is no grab that could deliver it — so without the server
	// poll the layer would stand here forever with its keys eaten
	// session-wide.
	d.ResetActions()
	d.State.Reset()
	relWatch := watchGrabs(d.Display)
	_ = in.Up("Super_L")
	_, ended := d.State.Await(inDefault, stateWait)
	relLanded, relWhy := relWatch.settled(grabSettleTimeout)
	endedByPoll := rep.Judged(up, ended,
		"releasing $mod ends the layer — the server poll, not an event, is what ends a hold layer",
		describeStates(d.State.States()), upWhy)

	// NOW the negative from above is judgeable: the layer coming down on a
	// release no grab could deliver is the only available proof that the
	// idle poll ran at all on this daemon, this run.
	//
	// CHANNEL MATCH. `endedByPoll` is a STATE-SOCKET positive, and it is the
	// right gate for "the poll ran". But this claim's EVIDENCE is the ACTION
	// LOG, so it also needs a same-run positive off THAT channel — otherwise a
	// dead action channel reads green here while its siblings at
	// :475/:542/:547/:587 all go red, which is precisely the signature the
	// comment above calls "the proof". `gotOpen` is the switcher layer's own
	// dispatch, recorded through the same stub log earlier this run;
	// `heldReadable` is the individual read that produced heldDuring.
	pollPre, pollWhy := gatedOn(
		gate{endedByPoll,
			"the idle poll was never shown to run on this run (the layer did not come down on the $mod release), " +
				"so a silent hold-release action is what a poll that never ran also produces"},
		gate{gotOpen,
			"the action log never recorded the switcher layer's OWN dispatch this run, so an empty log now is what a " +
				"dead action channel also produces"},
		gate{heldReadable, "the action log could not be read at the moment this claim was measured"},
	)
	rep.Judged(pollPre, len(heldDuring) == 0,
		"while $mod is genuinely down the server confirms it and the hold-release action is NOT dispatched",
		fmt.Sprintf("%v", heldDuring), pollWhy)

	acts, gotCommit := d.AwaitAction("switcher-confirm", dispatchGap)
	rep.Judged(ended, gotCommit, "and the commit was DISPATCHED, not merely implied by the exit",
		fmt.Sprintf("%v", acts), "the layer never came down this run")

	freeTab, freeTabGate := absentProbe(rig, "Tab", 0)
	teardown, teardownWhy := gatedOn(
		gate{ended, "the layer never came down this run"},
		gate{tabHeldWhileUp, "bare Tab was never grabbed while the layer was UP, so a granted rival grab now proves nothing"},
		gate{relLanded, "the post-release grab set was never observed to land — " + relWhy},
		freeTabGate,
	)
	rep.Judged(teardown, freeTab,
		"the layer's bare keys went back to applications with it",
		"a rival grab on bare Tab is granted again", teardownWhy)
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

	// Super+o is what $mod+o means on :0 and NOTHING on :10. INJECTED FIRST,
	// so a daemon that grabbed both modifiers cannot pass the next check by
	// accident — but only MEASURED here. The verdict waits, for the reason
	// spelled out below; the same "measure now, judge once the gate exists"
	// shape the hold-release negative in runSwitcherChecks uses.
	const whatQuiet = "Super+o does NOT enter nav where $mod is Mod1"
	d.State.Reset()
	_ = in.Tap("super+o")
	time.Sleep(settle + 300*time.Millisecond)
	sawNav := false
	for _, s := range d.State.States() {
		if s.Layer == "nav" {
			sawNav = true
		}
	}
	quietDetail := describeStates(d.State.States())
	// HALF THE GATE: a daemon that is dead, or that grabbed nothing, also
	// fails to enter nav, so it must really hold Alt+o on the Mod1 mask.
	holdsAltO := probeOwned(rig, "o", maskMod1)

	// Alt+o has to survive BOTH hops — grabbed on the Mod1 mask, and then
	// matched by an engine that also knows $mod is Mod1.
	d.State.Reset()
	d.Proxy.Reset()
	navWatch := watchGrabs(d.Display)
	_ = in.Tap("alt+o")
	_, entered := d.State.Await(inNav, stateWait)
	navLanded, navWhy := navWatch.settled(grabSettleTimeout)
	rep.Check(entered, "Alt+o DOES enter nav where $mod is Mod1 — grab set and engine agree on the display's own modifier",
		describeStates(d.State.States()))

	// CHANNEL MATCH, and THE OTHER HALF OF THE GATE. `sawNav` is read off the
	// STATE SOCKET, so "no nav was published" is only evidence about Super+o
	// once the state socket has been shown to publish AT ALL on this run —
	// and this phase runs against a FRESH rig and a FRESH watcher
	// (main.go:222,234), so nothing earlier in the process carries over. A
	// silent state channel — the watcher connected to a stale socket, a
	// publisher that never replays — would otherwise hand this negative a free
	// PASS while `entered` above went red, the exact split the switcher
	// section calls "the proof". `entered` is that same-channel positive, and
	// it is the FIRST one this phase has; the grab-probe half stays because
	// the two halves answer different questions.
	quietPre, quietWhy := gatedOn(
		gate{holdsAltO, "the daemon does not hold Alt+o on this display, so a quiet Super+o proves nothing"},
		gate{entered, "this daemon's state socket never published nav at all this run, so a state list with no nav in it " +
			"is what a silent state channel also produces, not evidence about Super+o"},
	)
	rep.Judged(quietPre, !sawNav, whatQuiet, quietDetail, quietWhy)
	navUp, navUpWhy := gatedOn(
		gate{entered, "the daemon never entered nav on the Mod1 display"},
		gate{navLanded, "nav's grab set was never observed to land on the Mod1 display — " + navWhy},
	)
	rep.Judged(navUp, probeOwned(rig, "h", 0), "and the layer's bare keys were grabbed on the way in",
		"a rival grab on bare h is refused", navUpWhy)

	_ = in.Tap("h")
	cmds, gotDispatch := awaitCommand(d.Proxy, "focus left", dispatchGap)
	rep.Judged(navUp, gotDispatch, "a nav bind dispatches on the Mod1 display", fmt.Sprintf("%v", cmds), navUpWhy)

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
