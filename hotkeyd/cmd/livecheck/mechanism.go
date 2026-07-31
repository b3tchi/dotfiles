package main

// mechanism.go holds the claims livecheck makes with its OWN X connection:
// the XI2 grab mechanism, the keymap, the device inventory, and what the
// server does with two competing grabbers. No daemon is running for any of
// them.
//
// These are not a re-implementation of the daemon's grab path — they go
// through internal/x11's XIPassiveGrabDevice and GrabModifierVariants, which
// is the same code cmd/hotkeyd's GrabManager calls. That is what
// live_check.py means by "the REAL adapter, not a copy of it": the object
// under test is the wire request and the server's answer to it.

import (
	"fmt"
	"os/exec"
	"sort"
	"strings"
	"time"
)

const drainWindow = 600 * time.Millisecond

// runMechanism runs every daemon-free claim against display.
func runMechanism(rep *Reporter, rig *Rig, in *Injector, i3sock string) {
	// -- 0: the mechanism itself (py:130) -----------------------------------
	ver, err := rig.Conn.XIQueryVersion(rig.Ext.MajorOpcode, 2, 3)
	if err != nil {
		rep.Check(false, "the display speaks XI2", err.Error())
		return
	}
	rep.Check(ver.Major >= 2, "the display speaks XI2", fmt.Sprintf("%d.%d", ver.Major, ver.Minor))

	injecting := in.Available()
	skipNoInject := func(what string) {
		rep.Skip(what, "xdotool is not on PATH, so no key could be injected on this run")
	}

	// -- 1: a real grab fires, with and without the lock keys on ------------
	res, err := rig.Grab("f10", "F10", maskMod4)
	if err != nil {
		rep.Check(false, "real XIPassiveGrabDevice registered $mod+F10", err.Error())
		return
	}
	rep.Check(res.AllSucceeded(), "real XIPassiveGrabDevice registered $mod+F10",
		fmt.Sprintf("%d modifier variants refused", len(res.Failed)))

	f10, _ := rig.Keycode("F10")

	if !injecting {
		skipNoInject("chord fires with no lock keys")
		skipNoInject("chord fires with NumLock ON")
		skipNoInject("chord fires with CapsLock ON")
	} else {
		rig.Drain(150 * time.Millisecond)
		_ = in.TapN("super+F10", 3, 50*time.Millisecond)
		got := Presses(rig.Drain(drainWindow), f10)
		rep.Check(got == 3, "chord fires with no lock keys", fmt.Sprintf("%d/3", got))

		// poc013 measured a bare-mask grab firing 0/3 with NumLock on. That
		// finding only exists because it was checked against a live server,
		// so it is re-measured here rather than assumed to carry over.
		for _, lock := range []struct{ name, key string }{{"NumLock", "Num_Lock"}, {"CapsLock", "Caps_Lock"}} {
			_ = in.Tap(lock.key)
			time.Sleep(200 * time.Millisecond)
			rig.Drain(200 * time.Millisecond)
			_ = in.TapN("super+F10", 3, 50*time.Millisecond)
			got := Presses(rig.Drain(drainWindow), f10)
			rep.Check(got == 3, "chord fires with "+lock.name+" ON", fmt.Sprintf("%d/3", got))
			_ = in.Tap(lock.key)
			time.Sleep(200 * time.Millisecond)
			rig.Drain(200 * time.Millisecond)
		}
	}

	// -- 1b: per-chord, never an exclusive device grab ----------------------
	// A passing chord alone cannot tell XIPassiveGrabDevice from an exclusive
	// device grab: both deliver F10 here. What separates them is everything
	// ELSE — F12 is in nobody's grab set, so silence on F12 while F10 fires
	// is the discriminator.
	//
	// The two are one claim, not two lines: the file's own comment said so
	// and the code did not enforce it. A dead injector (or a grab that was
	// never obtained) delivers no F12 either, so the negative was collecting
	// a PASS in exactly the run where its sibling went red. It is now GATED
	// on the sibling, measured first, and reported in the same order as
	// before ([[im009]]; report.go's Judged doc: splitting a precondition
	// into its own line does not close the vacuity).
	if !injecting {
		skipNoInject("a key we did NOT grab is not delivered to us — the grab is per chord")
		skipNoInject("while the chord we DID grab still arrives")
	} else {
		f12, _ := rig.Keycode("F12")
		rig.Drain(100 * time.Millisecond)
		_ = in.TapN("F12", 3, 30*time.Millisecond)
		strays := Presses(rig.Drain(drainWindow), f12)
		_ = in.TapN("super+F10", 2, 50*time.Millisecond)
		got := Presses(rig.Drain(drainWindow), f10)
		rep.Judged(got == 2, strays == 0,
			"a key we did NOT grab is not delivered to us — the grab is per chord, never an exclusive device grab",
			fmt.Sprintf("%d stray deliveries", strays),
			fmt.Sprintf("the chord we DID grab did not arrive either (%d/2), so silence on F12 is what a dead injector "+
				"or an unobtained grab produces, not evidence about the grab's scope", got))
		rep.Check(got == 2,
			"while the chord we DID grab still arrives (else the check above is satisfied by a client that grabbed nothing)",
			fmt.Sprintf("%d/2", got))
	}

	// -- 2: a second XI2 grabber is REFUSED ---------------------------------
	// MEASURED, and it corrects sp020: the X server keeps core and XI2
	// passive grabs in SEPARATE conflict domains, so an XI2 grab is NOT
	// refused by i3's core grab on the same chord. What still refuses is
	// another XI2 grabber — which is what this checks.
	rival, err := OpenRig(rig.Display)
	if err != nil {
		rep.Skip("a chord another XI2 client already grabbed is REFUSED", "second connection: "+err.Error())
	} else {
		rres, rerr := rival.Grab("rival", "F11", maskMod4)
		if rerr != nil || !rres.AllSucceeded() {
			rep.Skip("a chord another XI2 client already grabbed is REFUSED",
				fmt.Sprintf("the rival client could not take $mod+F11 first (err=%v refused=%d)", rerr, len(rres.Failed)))
		} else {
			mine, err := rig.Grab("f11", "F11", maskMod4)
			refused := err == nil && len(mine.Failed) > 0
			rep.Check(refused,
				"a chord another XI2 client already grabbed is REFUSED and reported",
				fmt.Sprintf("%d of 4 modifier variants refused (err=%v)", len(mine.Failed), err))
			_, heldF11 := rig.held["f11"]
			// Gated on the refusal actually happening: a grab request that
			// ERRORED records nothing either, and this negative would then be
			// green about bookkeeping that was never exercised.
			rep.Judged(refused, !heldF11, "a fully refused chord is not recorded as ours",
				fmt.Sprintf("held=%v", sortedKeys(rig.held)),
				"the second grab was not refused at all, so there is no refusal for the bookkeeping to have handled")
			_, heldF10 := rig.held["f10"]
			rep.Check(heldF10, "the other chord is still grabbed after a refusal",
				fmt.Sprintf("held=%v", sortedKeys(rig.held)))
			if !injecting {
				skipNoInject("and that other chord still FIRES after the refusal")
			} else {
				rig.Drain(100 * time.Millisecond)
				_ = in.TapN("super+F10", 2, 50*time.Millisecond)
				got := Presses(rig.Drain(drainWindow), f10)
				rep.Check(got == 2, "and that other chord still FIRES after the refusal", fmt.Sprintf("%d/2", got))
			}
		}
		rival.Close()
	}

	// -- 2b: core and XI2 are separate conflict domains ---------------------
	// live_check.py installs its own core grabber with python-xlib's
	// grab_key. internal/x11 has no core GrabKey request and deliberately
	// never will (adr0018: XI2 only, never a core fallback), so the core
	// grabber here is the REAL i3 — which grabs the chords in its config
	// with core XGrabKey. The rig's i3 config carries a marker binding for
	// exactly this: `bindsym Mod4+F8 mark --add i3-got-f8`.
	runCoreDomainChecks(rep, rig, in, i3sock, injecting)

	// -- 4: a real keymap change --------------------------------------------
	if _, err := exec.LookPath("setxkbmap"); err != nil {
		rep.Skip("chords still resolve after a keymap reset", "setxkbmap is not on PATH")
		rep.Skip("chord still fires after a keymap reset", "setxkbmap is not on PATH")
	} else {
		cmd := exec.Command("setxkbmap", "-layout", "us")
		cmd.Env = childEnv(nil, rig.Display, "")
		_ = cmd.Run()
		time.Sleep(500 * time.Millisecond)
		rig.Drain(200 * time.Millisecond)

		err := rig.ReloadKeymap()
		_ = rig.Ungrab("f10")
		res, gerr := rig.Grab("f10", "F10", maskMod4)
		rep.Check(err == nil && gerr == nil && res.AllSucceeded(),
			"chords still resolve after a keymap reset",
			fmt.Sprintf("reload=%v grab=%v refused=%d", err, gerr, len(res.Failed)))

		if !injecting {
			skipNoInject("chord still fires after a keymap reset")
		} else {
			f10, _ = rig.Keycode("F10")
			rig.Drain(100 * time.Millisecond)
			_ = in.TapN("super+F10", 2, 50*time.Millisecond)
			got := Presses(rig.Drain(drainWindow), f10)
			rep.Check(got == 2, "chord still fires after a keymap reset", fmt.Sprintf("%d/2", got))
		}
	}

	// -- 5c: DEVICE ATTRIBUTION at the wire ---------------------------------
	runDeviceChecks(rep, rig, in, injecting)

	// -- 5f(b): ISO_Left_Tab resolves, and by MASK --------------------------
	runKeysymLevelChecks(rep, rig)

	// -- auto-repeat and repeat-filter fairness, MEASURED -------------------
	runTimingMeasurements(rep, rig, in, injecting)

	_ = rig.Ungrab("f10")
	_ = rig.Ungrab("f11")

	// THE INSTRUMENT ITSELF, graded. Every claim above that needed injected
	// input is only as good as the injector; a silently-failing xdotool
	// would turn each of them into a red line about the daemon. Reported as
	// its own verdict so a broken instrument cannot masquerade as a broken
	// daemon.
	if injecting {
		errs := in.Errors()
		// CHANNEL MATCH. The pass condition is an EMPTY error list, and a run
		// that injected nothing at all has one too — "every injection was
		// accepted" is vacuously true over an empty set. The attempt count is
		// the injector's own same-channel positive.
		rep.Judged(in.Attempts() > 0, len(errs) == 0,
			"every key injection this run was accepted by xdotool",
			fmt.Sprintf("%d injections, %d refused%s", in.Attempts(), len(errs), joinErrs(errs)),
			"xdotool was on PATH but no injection was ever attempted, so an empty refusal list is vacuous")
	}
}

func joinErrs(errs []string) string {
	if len(errs) == 0 {
		return ""
	}
	return ": " + strings.Join(errs, "; ")
}

func sortedKeys(m map[string][]uint32) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// runCoreDomainChecks pins the measurement live_check.py:204-229 makes,
// using the real i3 as the core grabber.
func runCoreDomainChecks(rep *Reporter, rig *Rig, in *Injector, i3sock string, injecting bool) {
	const what = "an XI2 grab over a live CORE grab is NOT refused — core and XI2 passive grabs are separate conflict domains (corrects sp020)"

	cfg, err := i3msg(i3sock, rig.Display, "-t", "get_config")
	hasMarker := err == nil && strings.Contains(cfg, coreMarkerBind)
	if !hasMarker {
		why := fmt.Sprintf("the rig's i3 has no `%s` binding, so nothing holds a CORE grab to compete with (err=%v)", coreMarkerBind, err)
		rep.Skip("the core grabber (real i3) holds a core grab on $mod+F8", why)
		rep.Skip(what, why)
		rep.Skip("and the LATER (XI2) grabber wins delivery outright", why)
		return
	}
	// `Check(true, ...)` stood here. The guard above makes it unreachable
	// unless hasMarker, so it was never actually vacuous — but a pass
	// expression that is a LITERAL cannot be read as evidence by anyone
	// auditing this file, and the whole discipline here is that the verdict
	// is computed from an observation. The observation is hasMarker.
	rep.Check(hasMarker, "the core grabber (real i3) holds a core grab on $mod+F8", "from i3's own GET_CONFIG")

	res, gerr := rig.Grab("f8", "F8", maskMod4)
	rep.Check(gerr == nil && res.AllSucceeded(), what,
		fmt.Sprintf("%d of 4 modifier variants refused (err=%v)", len(res.Failed), gerr))

	if !injecting {
		rep.Skip("and the LATER (XI2) grabber wins delivery outright", "xdotool is not on PATH")
		_ = rig.Ungrab("f8")
		return
	}
	_, _ = i3msg(i3sock, rig.Display, "unmark", coreMarkerName)
	f8, _ := rig.Keycode("F8")
	rig.Drain(100 * time.Millisecond)
	_ = in.TapN("super+F8", 3, 60*time.Millisecond)
	gotXI := Presses(rig.Drain(drainWindow), f8)
	// CHANNEL MATCH. "i3 did NOT also get the key" is an ABSENCE read off
	// i3's IPC, so the read itself has to have succeeded: i3msg's error was
	// discarded here, and a failed i3-msg hands back its stderr, which
	// contains no mark either — so a dead i3 channel made half this claim
	// pass for free while the other half (gotXI, the X event stream) carried
	// it. The X-channel positive gates the X-channel half; the i3-channel
	// read gates the i3-channel half.
	marks, marksErr := i3msg(i3sock, rig.Display, "-t", "get_marks")
	gotCore := strings.Contains(marks, coreMarkerName)
	rep.Judged(marksErr == nil, gotXI == 3 && !gotCore,
		"and the LATER (XI2) grabber wins delivery outright",
		fmt.Sprintf("xi2=%d/3 i3_marks=%s", gotXI, strings.TrimSpace(marks)),
		fmt.Sprintf("i3's mark list could not be read at all (%v), so an absent mark says nothing about who got the key", marksErr))
	_ = rig.Ungrab("f8")
}

const (
	coreMarkerName = "hotkeyd-live-i3-core"
	coreMarkerBind = "bindsym Mod4+F8 mark --add " + coreMarkerName
)

func runDeviceChecks(rep *Reporter, rig *Rig, in *Injector, injecting bool) {
	inv, err := rig.DeviceNames()
	if err != nil {
		rep.Check(false, "the display's XI2 inventory names an XTEST keyboard", err.Error())
		return
	}
	var xtestName, otherKbd string
	names := make([]string, 0, len(inv))
	for id, n := range inv {
		names = append(names, fmt.Sprintf("%d=%s", id, n))
		if strings.HasSuffix(n, "XTEST keyboard") {
			xtestName = n
		}
	}
	for _, n := range inv {
		if n == xtestName || !strings.Contains(strings.ToLower(n), "keyboard") {
			continue
		}
		if strings.HasPrefix(n, "Virtual core keyboard") {
			continue
		}
		otherKbd = n
	}
	sort.Strings(names)
	rep.Check(xtestName != "", "the display's XI2 inventory names an XTEST keyboard", strings.Join(names, " "))
	rep.Check(otherKbd != "",
		"and a second, distinct keyboard device to scope a negative case to", otherKbd)

	if !injecting {
		rep.Skip("every grabbed event resolves its source to the XTEST keyboard", "xdotool is not on PATH")
		rep.Skip("and sourceid is the SLAVE, not the master in the event header", "xdotool is not on PATH")
		return
	}
	// EDGE CASE (task design): XTEST-injected events carry the XTEST slave's
	// sourceid. The attribution claim therefore EXPECTS XTEST for injected
	// input — a claim about a PHYSICAL slave could only be made by a human at
	// a real keyboard, so none is made here.
	res, err := rig.Grab("attr", "F10", maskMod4)
	if err != nil || !res.AllSucceeded() {
		rep.Skip("every grabbed event resolves its source to the XTEST keyboard",
			fmt.Sprintf("could not grab $mod+F10 for the attribution probe (err=%v refused=%d)", err, len(res.Failed)))
		return
	}
	f10, _ := rig.Keycode("F10")
	rig.Drain(100 * time.Millisecond)
	_ = in.TapN("super+F10", 2, 60*time.Millisecond)
	evs := rig.Drain(drainWindow)
	var presses []KeyEvent
	for _, e := range evs {
		if e.Press && e.Keycode == f10 {
			presses = append(presses, e)
		}
	}
	allXTest := len(presses) == 2
	for _, e := range presses {
		if inv[e.SourceID] != xtestName {
			allXTest = false
		}
	}
	rep.Check(allXTest && xtestName != "",
		fmt.Sprintf("every grabbed event resolves its source to %q", xtestName),
		describeSources(presses, inv))
	slaveNotMaster := len(presses) > 0
	for _, e := range presses {
		if e.SourceID == e.DeviceID {
			slaveNotMaster = false
		}
	}
	rep.Check(slaveNotMaster,
		"and sourceid is the SLAVE, not the master in the event header",
		describeSources(presses, inv))
	_ = rig.Ungrab("attr")
}

func describeSources(evs []KeyEvent, inv map[uint16]string) string {
	parts := make([]string, 0, len(evs))
	for _, e := range evs {
		parts = append(parts, fmt.Sprintf("sourceid=%d(%s) deviceid=%d", e.SourceID, inv[e.SourceID], e.DeviceID))
	}
	if len(parts) == 0 {
		return "no press events arrived"
	}
	return strings.Join(parts, ", ")
}

func runKeysymLevelChecks(rep *Reporter, rig *Rig) {
	tab, err := rig.Keycode("Tab")
	if err != nil {
		rep.Check(false, "ISO_Left_Tab resolves, and to the SAME keycode as Tab", err.Error())
		return
	}
	iso, err := rig.Keycode("ISO_Left_Tab")
	rep.Check(err == nil && iso == tab && tab != 0,
		"ISO_Left_Tab resolves, and to the SAME keycode as Tab",
		fmt.Sprintf("Tab=%d ISO_Left_Tab=%d err=%v", tab, iso, err))

	lvl0, ok0 := keysymAtLevel(rig.Mapping, tab, 0)
	rep.Check(ok0 && lvl0 == keysymByName["Tab"],
		"$mod+Tab is named Tab — cycle forwards",
		fmt.Sprintf("level 0 = %s", nameForKeysym(lvl0)))
	lvl1, ok1 := keysymAtLevel(rig.Mapping, tab, 1)
	rep.Check(ok1 && lvl1 == keysymByName["ISO_Left_Tab"],
		"$mod+Shift+Tab is named ISO_Left_Tab — cycle BACKWARDS. Resolve it by keycode alone and the switcher cycles the wrong way in silence",
		fmt.Sprintf("level 1 = %s", nameForKeysym(lvl1)))
}

// repeatStream is the auto-repeat measurement, read off THIS run and handed
// to the daemon phase as the precondition its coalescing claim is gated on.
type repeatStream struct {
	Measured bool
	Presses  int
	Flagged  int
	Releases int
	Detail   string
}

// Held reports whether the server really produced a repeat stream.
func (r repeatStream) Held() bool {
	return r.Measured && r.Presses > 3 && r.Flagged == r.Presses-1 && r.Releases == 1
}

type timingFacts struct {
	Repeat repeatStream

	DoubleTapAdjacent bool
	DoubleTapDetail   string
	DoubleTapNoRepeat bool

	RollingSameMillisecond bool
	RollingDetail          string
}

var facts timingFacts

func runTimingMeasurements(rep *Reporter, rig *Rig, in *Injector, injecting bool) {
	if !injecting {
		rep.Skip("XI2 marks auto-repeat on the PRESS (XIKeyRepeat) and sends no synthetic release", "xdotool is not on PATH")
		rep.Skip("a 10 ms double-tap really does put release+press of the SAME key on two different milliseconds", "xdotool is not on PATH")
		rep.Skip("and the server does NOT flag either tap as a repeat", "xdotool is not on PATH")
		rep.Skip("a rolling h,j pair really does land release+press of DIFFERENT keys on ONE millisecond", "xdotool is not on PATH")
		return
	}

	// The MEASUREMENT: XI2 sends no synthetic release for auto-repeat and
	// instead sets XIKeyRepeat on the press. Both numbers are read off THIS
	// run rather than asserted from the old core shape, so a server that
	// went back to release+press pairs shows up as a changed count rather
	// than as a mystery. Measured on F10 (a chord no shipped bind owns), so
	// this can be taken while the daemon holds the rest of the table.
	res, err := rig.Grab("rep", "F10", 0)
	if err != nil || !res.AllSucceeded() {
		rep.Skip("XI2 marks auto-repeat on the PRESS (XIKeyRepeat) and sends no synthetic release",
			fmt.Sprintf("could not grab bare F10 (err=%v refused=%d)", err, len(res.Failed)))
	} else {
		f10, _ := rig.Keycode("F10")
		rig.Drain(150 * time.Millisecond)
		_ = in.Down("F10")
		time.Sleep(1200 * time.Millisecond)
		_ = in.Up("F10")
		evs := rig.Drain(400 * time.Millisecond)
		var p, f, r int
		for _, e := range evs {
			if e.Keycode != f10 {
				continue
			}
			if e.Press {
				p++
				if e.Repeat {
					f++
				}
			} else {
				r++
			}
		}
		facts.Repeat = repeatStream{
			Measured: true, Presses: p, Flagged: f, Releases: r,
			Detail: fmt.Sprintf("%d presses / %d flagged / %d releases", p, f, r),
		}
		rep.Check(facts.Repeat.Held(),
			"XI2 marks auto-repeat on the PRESS (XIKeyRepeat) and sends no synthetic release — so the flag, not a timestamp pair, is the discriminator",
			facts.Repeat.Detail)
		_ = rig.Ungrab("rep")
	}

	// The two adjacencies the repeat filter must NOT mistake for a repeat.
	// Which side of a millisecond boundary two injected events land on is a
	// property of the clock, not of the daemon, so each is retried until the
	// server hands back the shape the check needs — and if it never does,
	// the dependent claim SKIPs rather than passing for free.
	hKey, err := rig.Grab("h", "h", 0)
	jKey, err2 := rig.Grab("j", "j", 0)
	if err != nil || err2 != nil || !hKey.AllSucceeded() || !jKey.AllSucceeded() {
		rep.Skip("a 10 ms double-tap really does put release+press of the SAME key on two different milliseconds",
			fmt.Sprintf("could not grab bare h/j (err=%v/%v)", err, err2))
		rep.Skip("and the server does NOT flag either tap as a repeat", "no bare h grab")
		rep.Skip("a rolling h,j pair really does land release+press of DIFFERENT keys on ONE millisecond", "no bare h/j grab")
		return
	}
	hc, _ := rig.Keycode("h")
	jc, _ := rig.Keycode("j")

	var seen []KeyEvent
	for attempt := 1; attempt <= 8; attempt++ {
		rig.Drain(100 * time.Millisecond)
		_ = in.TapSequence(10, "h", "h")
		seen = rig.Drain(400 * time.Millisecond)
		if a := adjacent(seen, hc, hc, true, false); a {
			facts.DoubleTapAdjacent = true
			break
		}
	}
	facts.DoubleTapDetail = describeTimes(seen)
	rep.Check(facts.DoubleTapAdjacent,
		"a 10 ms double-tap really does put release+press of the SAME key on two different milliseconds (else the dependent claim proves nothing)",
		facts.DoubleTapDetail)
	flagged := 0
	for _, e := range seen {
		if e.Repeat {
			flagged++
		}
	}
	facts.DoubleTapNoRepeat = flagged == 0 && len(seen) > 0
	rep.Judged(facts.DoubleTapAdjacent, facts.DoubleTapNoRepeat,
		"and the server does NOT flag either tap as a repeat",
		fmt.Sprintf("%d flagged of %d events", flagged, len(seen)),
		"the double-tap adjacency never materialised this run")

	for attempt := 1; attempt <= 8; attempt++ {
		rig.Drain(100 * time.Millisecond)
		_ = in.TapSequence(0, "h", "j")
		seen = rig.Drain(400 * time.Millisecond)
		if adjacent(seen, hc, jc, false, true) {
			facts.RollingSameMillisecond = true
			break
		}
	}
	facts.RollingDetail = describeTimes(seen)
	rep.Check(facts.RollingSameMillisecond,
		"a rolling h,j pair really does land release+press of DIFFERENT keys on ONE millisecond (else the dependent claim proves nothing)",
		facts.RollingDetail)

	_ = rig.Ungrab("h")
	_ = rig.Ungrab("j")
}

// adjacent reports whether the drained stream contains a release->press pair
// with the requested same-key / same-millisecond shape — the release+press
// adjacency any repeat filter must judge without mistaking it for a repeat.
func adjacent(evs []KeyEvent, firstCode, secondCode byte, sameKey, sameTime bool) bool {
	for i := 0; i+1 < len(evs); i++ {
		a, b := evs[i], evs[i+1]
		if a.Press || !b.Press {
			continue
		}
		if (a.Keycode == b.Keycode) != sameKey {
			continue
		}
		if (a.Time == b.Time) != sameTime {
			continue
		}
		if !sameKey && (a.Keycode != firstCode || b.Keycode != secondCode) {
			continue
		}
		return true
	}
	return false
}

func describeTimes(evs []KeyEvent) string {
	parts := make([]string, 0, len(evs))
	for _, e := range evs {
		kind := "press"
		if !e.Press {
			kind = "release"
		}
		parts = append(parts, fmt.Sprintf("%s:%d@%d", kind, e.Keycode, e.Time))
	}
	if len(parts) == 0 {
		return "no events arrived"
	}
	return strings.Join(parts, " ")
}

// i3msg runs i3-msg against the RIG's i3, with I3SOCK pinned to the rig's
// socket. Pinning matters for the reason test-hotkeyd.sh already documents:
// i3-msg follows the ambient $I3SOCK, which on a developer machine points at
// their real session, so an unpinned call answers from the wrong i3 and the
// gate passes for the wrong reason.
func i3msg(sock, display string, args ...string) (string, error) {
	cmd := exec.Command("i3-msg", args...)
	env := childEnv(nil, display, "")
	if sock != "" {
		env = append(env, "I3SOCK="+sock)
	}
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	return string(out), err
}
