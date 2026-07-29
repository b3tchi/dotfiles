#!/usr/bin/env python3
"""Live-X checks for hotkeyd (sp020 Task 4, XI2 port at Task 11). Driven by
test-hotkeyd.sh stage 6.

These are the assertions that fakes cannot make: a REAL `XIGrabKeycode` against
a real X server, with NumLock and CapsLock actually toggled, dispatching to a
real i3 and reading the effect back out of the tree. poc013 measured that a
bare-mask grab fires 0/3 with NumLock on — that finding only exists because it
was checked against a live server, so it gets checked that way here too, and it
is re-measured under XI2 rather than assumed to carry over.

Prints `PASS <what>` / `FAIL <what>` lines; exits non-zero if anything failed.
"""
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from Xlib import X, Xatom, XK, display as xdisplay  # noqa: E402
from Xlib.ext import xinput, xtest  # noqa: E402

import hotkeyd as H  # noqa: E402

RESULTS = []


def check(ok, what, detail=""):
    RESULTS.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'} {what}" + (f" — {detail}" if detail else ""),
          flush=True)


def code_for(d, name):
    return d.keysym_to_keycode(XK.string_to_keysym(name))


def tap(d, key_code, mod_code=None, n=1):
    for _ in range(n):
        if mod_code:
            xtest.fake_input(d, X.KeyPress, mod_code)
        xtest.fake_input(d, X.KeyPress, key_code)
        xtest.fake_input(d, X.KeyRelease, key_code)
        if mod_code:
            xtest.fake_input(d, X.KeyRelease, mod_code)
        d.sync()
        time.sleep(0.05)


def drain(d, code, seconds=0.6):
    """Count XI2 KeyPress events delivered to our grab within the window.

    XI2, not core: after the Task 11 port the grabs are `XIGrabKeycode`, so the
    server delivers `GenericEvent`/`XI_KeyPress` and a core-typed counter would
    read zero for every check in this file.
    """
    seen = 0
    end = time.time() + seconds
    while time.time() < end:
        if d.pending_events():
            ev = d.next_event()
            k = H.key_event(ev)
            if k is not None and k.kind == "press" and k.detail == code:
                seen += 1
        else:
            time.sleep(0.02)
    return seen


def sources(d, code, seconds=0.6):
    """Every (sourceid, name) that delivered `code` within the window."""
    reg = H.DeviceRegistry(d)
    out = []
    end = time.time() + seconds
    while time.time() < end:
        if d.pending_events():
            ev = d.next_event()
            k = H.key_event(ev)
            if k is not None and k.kind == "press" and k.detail == code:
                out.append((k.sourceid, reg.name(k.sourceid), k.deviceid))
        else:
            time.sleep(0.02)
    return out


def main() -> int:
    d = xdisplay.Display()
    root = d.screen().root
    f10 = code_for(d, "F10")
    f11 = code_for(d, "F11")
    mod4 = code_for(d, "Super_L")
    numlock = code_for(d, "Num_Lock")
    caps = code_for(d, "Caps_Lock")

    # The REAL adapter, not a copy of it: after the XI2 port the grab mechanism
    # lives entirely in XAdapter (extension probe, XIGrabKeycode, the reply's
    # failed-modifier list), and a re-implementation here would grade a copy.
    Adapter = lambda: H.XAdapter(d, root)                       # noqa: E731

    # -- 0: the mechanism itself --------------------------------------------
    ver = H.require_xi2(d)
    check(int(ver.major_version) >= 2, "the display speaks XI2",
          f"{ver.major_version}.{ver.minor_version}")

    # -- 1: a real grab fires, with and without the lock keys on ------------
    g = H.GrabManager(Adapter())
    g.sync_binds(["Mod4+F10"])
    check(not g.problems, "real XIGrabKeycode registered Mod4+F10",
          str(g.problems))

    tap(d, f10, mod4, n=3)
    check(drain(d, f10) == 3, "chord fires with no lock keys")

    for name, kc in (("NumLock", numlock), ("CapsLock", caps)):
        tap(d, kc)                       # toggle on
        time.sleep(0.2)
        drain(d, f10, 0.2)
        tap(d, f10, mod4, n=3)
        got = drain(d, f10)
        check(got == 3, f"chord fires with {name} ON", f"{got}/3")
        tap(d, kc)                       # toggle back off
        time.sleep(0.2)
        drain(d, f10, 0.2)

    # -- 1b: the grab really is per-chord, not an exclusive device grab ------
    # A passing chord alone cannot tell `XIGrabKeycode` from `XIGrabDevice`:
    # both deliver F10 here. What separates them is everything ELSE — an
    # exclusive device grab funnels the whole keyboard to this client (and locks
    # the session if the client hangs), while a passive keycode grab delivers
    # only what it registered. F12 is in nobody's grab set, so silence on F12
    # while F10 fires is the discriminator.
    f12 = code_for(d, "F12")
    drain(d, f12, 0.1)
    tap(d, f12, n=3)
    strays = drain(d, f12)
    check(strays == 0,
          "a key we did NOT grab is not delivered to us — the grab is per "
          "chord, never XIGrabDevice", f"{strays} stray deliveries")
    tap(d, f10, mod4, n=2)
    check(drain(d, f10) == 2,
          "while the chord we DID grab still arrives (else the check above is "
          "satisfied by a daemon that grabbed nothing)")

    # -- 2: a refused grab degrades to one chord, and the rest keep working --
    # MEASURED, and it corrects sp020: the X server keeps core and XI2 passive
    # grabs in SEPARATE conflict domains (`GrabMatchesSecond` compares grabtype),
    # so an XI2 grab is NOT refused by i3's core grab on the same chord — the
    # later grabber simply wins delivery. What still refuses is another XI2
    # grabber, i.e. a second hotkeyd, which is what this checks. See
    # dotfiles-hwds.13's DEVIATION note; ownership auditing therefore cannot
    # lean on BadAccess and belongs to `check --ownership` (sp020 Task 13).
    rival = xdisplay.Display()
    rival.xinput_query_version()
    rival_f11 = code_for(rival, "F11")
    rival.screen().root.xinput_grab_keycode(
        H.XI_ALL_MASTER_DEVICES, X.CurrentTime, rival_f11,
        xinput.GrabModeAsync, xinput.GrabModeAsync, True,
        xinput.KeyPressMask | xinput.KeyReleaseMask, [H.MOD4])
    rival.sync()
    g2 = H.GrabManager(Adapter())
    g2.sync_binds(["Mod4+F11", "Mod4+F10"])
    took_f11 = any("F11" in p for p in g2.problems)
    check(took_f11,
          "a chord another XI2 client already grabbed is REFUSED and reported",
          str(g2.problems))
    check("Mod4+F11" not in g2.chords,
          "a refused chord is not recorded as ours")
    check("Mod4+F10" in g2.chords,
          "the other chord is still grabbed after a refusal")
    drain(d, f10, 0.1)                           # clear anything left queued
    tap(d, f10, mod4, n=2)
    check(drain(d, f10) == 2,
          "and that other chord still FIRES after the refusal")

    # The measurement itself, pinned so the finding cannot rot back into the
    # spec's original claim: i3's core grab neither refuses nor survives ours.
    core_client = xdisplay.Display()
    f9 = code_for(core_client, "F9")
    core_errs = []
    core_client.screen().root.grab_key(
        f9, H.MOD4, 1, X.GrabModeAsync, X.GrabModeAsync,
        onerror=lambda e, r: core_errs.append(e))
    core_client.sync()
    g_core = H.GrabManager(Adapter())
    g_core.sync_binds(["Mod4+F9"])
    check(not core_errs, "the core grabber got its grab", str(core_errs))
    check(not g_core.problems,
          "an XI2 grab over a live CORE grab is NOT refused — core and XI2 "
          "passive grabs are separate conflict domains (corrects sp020)",
          str(g_core.problems))
    tap(d, f9, mod4, n=3)
    got_xi = drain(d, f9)
    got_core = 0
    while core_client.pending_events():
        ev = core_client.next_event()
        if ev.type == X.KeyPress and ev.detail == f9:
            got_core += 1
    check(got_xi == 3 and got_core == 0,
          "and the LATER (XI2) grabber wins delivery outright",
          f"xi2={got_xi} core={got_core}")
    g_core.sync_binds([])

    # -- 3: persistent IPC dispatch actually moves i3 ------------------------
    i3 = H.I3Client()
    before = subprocess.run(["i3-msg", "-t", "get_workspaces"],
                            capture_output=True, text=True).stdout
    ok = i3.command('mark --add hotkeyd-live')
    marks = subprocess.run(["i3-msg", "-t", "get_marks"],
                           capture_output=True, text=True).stdout
    check(ok, "i3 dispatch over the persistent socket returned success")
    check("hotkeyd-live" in marks or before is not None,
          "i3 accepted the command", marks.strip()[:60])
    for i in range(120):
        i3.command(f"nop live {i}")
    check(i3._sock is not None, "one connection survived 120+ dispatches")
    i3.close()

    # -- 4: MappingNotify after a real keymap change -------------------------
    g3 = H.GrabManager(Adapter())
    g3.sync_binds(["Mod4+F10"])
    subprocess.run(["setxkbmap", "-layout", "us"], check=False)
    time.sleep(0.5)
    while d.pending_events():
        d.next_event()
    changed = g3.on_mapping_notify()
    check(not g3.problems, "chords still resolve after a keymap reset",
          str(g3.problems))
    tap(d, code_for(d, "F10"), code_for(d, "Super_L"), n=2)
    check(drain(d, code_for(d, "F10")) == 2,
          "chord still fires after a keymap reset",
          f"regrabbed={changed}")

    # -- 5: the REAL Daemon, driven with REAL X events -----------------------
    # These are the three defects the T4 audit found live. They are re-checked
    # against the real composition (Daemon.pump + XAdapter), not a copy of it.
    import layers as LZ                                   # noqa: PLC0415
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
    pub = LZ.StatePublisher(runtime / "hotkeyd-live-check.sock")

    class NullI3:
        def command(self, cmd):
            return True

        def close(self):
            pass

    import binds as BT                                    # noqa: PLC0415
    dae = H.Daemon(BT, d, pub, i3=NullI3())

    def feed(keysym, kind="press", mods=()):
        """Inject a real key and pump whatever the server delivers."""
        code = code_for(d, keysym)
        mod_codes = [code_for(d, m) for m in mods]
        for mc in mod_codes:
            xtest.fake_input(d, X.KeyPress, mc)
        xtest.fake_input(d, X.KeyPress, code)
        if kind == "press":
            xtest.fake_input(d, X.KeyRelease, code)
        for mc in reversed(mod_codes):
            xtest.fake_input(d, X.KeyRelease, mc)
        d.sync()
        time.sleep(0.15)
        out = []
        while d.pending_events():
            out += dae.pump(d.next_event())
        return out

    check("h" not in dae.grabs.chords,
          "bare layer key is NOT grabbed in the default layer")
    feed("o", mods=["Super_L"])
    check(dae.engine.state["layer"] == "nav", "entered nav via a real keypress",
          str(dae.engine.state))
    check("h" in dae.grabs.chords, "entering nav grabbed its bare keys")
    check("Control_L" in dae.grabs.chords,
          "entering nav grabbed the sublayer modifier key")

    acts = feed("h")
    check(acts == ["focus left"], "bare h focuses in nav", str(acts))

    # hold Ctrl for real, then tap h — the G2 case
    xtest.fake_input(d, X.KeyPress, code_for(d, "Control_L"))
    d.sync()
    time.sleep(0.1)
    while d.pending_events():
        dae.pump(d.next_event())
    check(dae.engine.state["mod"] == "move",
          "held Ctrl is observed as the move sublayer", str(dae.engine.state))
    acts = feed("h", mods=[])
    check(acts == ["move left"], "Ctrl+h MOVES instead of focusing", str(acts))

    # exit while the modifier is still held — the T2 carry-forward risk, live
    acts = feed("q")
    check(dae.engine.state["layer"] == "default",
          "q leaves the layer while Ctrl is still held",
          str(dae.engine.state))
    xtest.fake_input(d, X.KeyRelease, code_for(d, "Control_L"))
    d.sync()
    time.sleep(0.1)
    while d.pending_events():
        dae.pump(d.next_event())
    check("h" not in dae.grabs.chords,
          "leaving the layer released its bare keys again")

    # -- Shift-held exit: the one modifier nothing routes for us -------------
    # Ctrl/Alt work because their keysyms are grabbed, so holding one starts an
    # ACTIVE grab that delivers every following key here. Shift is not a layer
    # modifier and gets no such grab, so `Shift+q` has to be a passive grab in
    # its own right or the key goes to the focused window and the layer sticks.
    # Asserted on a real X grab set, not on the chord list, because the unit
    # test cannot tell a requested grab from an obtained one.
    feed("o", mods=["Super_L"])
    _exits = list(BT.LAYERS["nav"].exit_keys)
    _missing = [k for k in _exits if f"Shift+{k}" not in dae.grabs.chords]
    check(not _missing,
          f"entering nav OBTAINED a Shift-held grab for every exit key "
          f"({', '.join(_exits)})",
          f"missing: {_missing}" if _missing else "")
    shift_code = code_for(d, "Shift_L")
    xtest.fake_input(d, X.KeyPress, shift_code)
    d.sync()
    time.sleep(0.1)
    while d.pending_events():
        dae.pump(d.next_event())
    check(dae.engine.state == {"layer": "nav", "mod": None},
          "held Shift does NOT become a sublayer", str(dae.engine.state))
    feed("q", mods=[])
    check(dae.engine.state["layer"] == "default",
          "Shift+q leaves the layer", str(dae.engine.state))
    xtest.fake_input(d, X.KeyRelease, shift_code)
    d.sync()
    time.sleep(0.1)
    while d.pending_events():
        dae.pump(d.next_event())

    # -- auto-repeat: the G3 case, measured on a real hold -------------------
    # The MECHANISM changed at the XI2 port and the measurement changed with it.
    # Core delivery synthesised a RELEASE+PRESS pair per repeat and the daemon
    # coalesced them by timestamp; XI2 sends no synthetic release at all and
    # instead sets XIKeyRepeat on the press. Both numbers below are read off THIS
    # run rather than asserted from the old shape, so a server that ever went
    # back to release+press pairs would show up here as a changed count rather
    # than as a mystery.
    feed("o", mods=["Super_L"])
    hcode = code_for(d, "h")
    xtest.fake_input(d, X.KeyPress, hcode)
    d.sync()
    time.sleep(1.2)                                    # let X auto-repeat run
    xtest.fake_input(d, X.KeyRelease, hcode)
    d.sync()
    time.sleep(0.2)
    fired, raw = [], []
    while d.pending_events():
        ev = d.next_event()
        k = H.key_event(ev)
        if k is not None:
            raw.append(k)
        fired += dae.pump(ev)
    n_press = sum(1 for k in raw if k.kind == "press")
    n_rel = sum(1 for k in raw if k.kind == "release")
    n_flag = sum(1 for k in raw if k.repeat)
    check(n_press > 3 and n_flag == n_press - 1 and n_rel == 1,
          "XI2 marks auto-repeat on the PRESS (XIKeyRepeat) and sends no "
          "synthetic release — so the flag, not a timestamp pair, is the "
          "discriminator",
          f"{n_press} presses / {n_flag} flagged / {n_rel} releases")
    check(len(fired) == 1,
          "a held key fires ONCE despite the real auto-repeat stream",
          f"{len(fired)} dispatches")

    # -- repeat-filter FAIRNESS: what the guard must NOT swallow --------------
    # The check above proves the filter eats auto-repeat. These prove it eats
    # nothing else, and they are the same two cases the core coalescer had to
    # survive (dotfiles-hwds.4) — a filter keyed on "same keycode as last time"
    # or on "release+press adjacency" fails one of them:
    #   a genuine 10 ms double-tap of ONE key must dispatch TWICE;
    #   a rolling h,j landing on ONE millisecond must keep BOTH.
    # Only a real server can settle either: the events, their timestamps and
    # their repeat flags all come from the server, and no fake can be trusted to
    # reproduce how it stamps them.
    hcode, jcode = code_for(d, "h"), code_for(d, "j")

    def pump_traced(settle=0.2):
        """Pump the queue, recording every key event the daemon LOOKED at."""
        time.sleep(settle)
        seen, out = [], []
        while d.pending_events():
            ev = d.next_event()
            k = H.key_event(ev)
            if k is not None:
                seen.append(k)
            out += dae.pump(ev)
        return seen, out

    def adjacent(seen, same_key, same_time):
        """The release->press adjacency the old core guard had to judge, and
        that any repeat filter must still not mistake for a repeat."""
        for a, b in zip(seen, seen[1:]):
            if a.kind != "release" or b.kind != "press":
                continue
            if ((a.detail == b.detail) == same_key
                    and (a.time == b.time) == same_time):
                return (a, b)
        return None

    def inject_until(shoot, same_key, same_time, tries=8):
        """Fire `shoot` until the server hands back the adjacency the check
        needs. Which side of a millisecond boundary two XTEST events land on is
        a property of the clock, not of the daemon — retrying keeps the check
        deterministic without weakening what it asserts."""
        seen = out = None
        for n in range(1, tries + 1):
            shoot()
            seen, out = pump_traced()
            if adjacent(seen, same_key, same_time):
                return seen, out, n
        return seen, out, 0

    check(dae.engine.state["layer"] == "nav",
          "still in nav for the repeat-filter fairness checks",
          str(dae.engine.state))

    # (a) a genuine double-tap: two taps of a nav bind ~10 ms apart. The release
    # of the first tap and the press of the second sit next to each other in the
    # queue looking EXACTLY like the old auto-repeat pair — same key, adjacent.
    def double_tap():
        xtest.fake_input(d, X.KeyPress, hcode)
        xtest.fake_input(d, X.KeyRelease, hcode)
        d.sync()
        time.sleep(0.01)
        xtest.fake_input(d, X.KeyPress, hcode)
        xtest.fake_input(d, X.KeyRelease, hcode)
        d.sync()

    seen, taps, n = inject_until(double_tap, same_key=True, same_time=False)
    check(n > 0,
          "a 10 ms double-tap really does put release+press of the SAME key on "
          "two different milliseconds (else the next check proves nothing)",
          f"{[(k.detail, k.time) for k in seen or []]}")
    check(not any(k.repeat for k in seen or []),
          "and the server does NOT flag either tap as a repeat",
          f"flagged: {[k.detail for k in seen or [] if k.repeat]}")
    check(taps == ["focus left", "focus left"],
          "a 10 ms double-tap dispatches TWICE — the release+press pair between "
          "the taps is NOT swallowed",
          f"{taps} (attempt {n})")

    # (b) rolling typing: h and j injected as one un-synced batch, which the
    # server stamps with a single millisecond. Release-h is then immediately
    # followed by press-j at the SAME time — the old auto-repeat signature
    # across two different keys.
    def rolling_pair():
        xtest.fake_input(d, X.KeyPress, hcode)
        xtest.fake_input(d, X.KeyRelease, hcode)
        xtest.fake_input(d, X.KeyPress, jcode)
        xtest.fake_input(d, X.KeyRelease, jcode)
        d.sync()

    seen, roll, n = inject_until(rolling_pair, same_key=False, same_time=True)
    check(n > 0,
          "a rolling h,j pair really does land release+press of DIFFERENT keys "
          "on ONE millisecond (else the next check proves nothing)",
          f"{[(k.detail, k.time) for k in seen or []]}")
    check(roll == ["focus left", "focus down"],
          "a same-millisecond release+press of DIFFERENT keys keeps BOTH — fast "
          "rolling typing inside a layer loses no keystroke",
          f"{roll} (attempt {n})")

    # -- 5c: DEVICE ATTRIBUTION, the point of the XI2 port --------------------
    # Two-sided on purpose. A positive-only check passes against an
    # implementation that ignores `sourceid` entirely, so each claim below has
    # its negative twin: the event carries the injecting device AND a bind
    # scoped to a different real device on this same display stays inert.
    reg = H.DeviceRegistry(d)
    xtest_name = None
    inventory = {}
    for dev in d.xinput_query_device(xinput.AllDevices).devices:
        inventory[dev.deviceid] = dev.name
        if dev.name.endswith("XTEST keyboard"):
            xtest_name = dev.name
    check(xtest_name is not None,
          "the display's XI2 inventory names an XTEST keyboard",
          str(sorted(inventory.items())))

    # A real, DIFFERENT keyboard on this display, used as the negative source.
    other_kbd = next((n for i, n in inventory.items()
                      if "keyboard" in n.lower() and n != xtest_name
                      and not n.startswith("Virtual core keyboard")), None)
    check(other_kbd is not None,
          "and a second, distinct keyboard device to scope the negative case to",
          str(other_kbd))

    # (positive) every dispatched event carries the INJECTING device's sourceid
    got = sources(d, code_for(d, "F10"), 0.05)          # clear the queue
    g5 = H.GrabManager(H.XAdapter(d, root))
    g5.sync_binds(["Mod4+F10"])
    tap(d, code_for(d, "F10"), mod4, n=2)
    got = sources(d, code_for(d, "F10"))
    check(len(got) == 2 and all(name == xtest_name for _, name, _ in got),
          f"every grabbed event resolves its source to {xtest_name!r}",
          str(got))
    check(all(sid != did for sid, _, did in got),
          "and sourceid is the SLAVE, not the master in the event header",
          str(got))
    g5.sync_binds([])

    # (positive/negative) a device= bind fires for its own source and for
    # nothing else — driven through the REAL Daemon, on the real server.
    import types                                        # noqa: PLC0415

    def scoped_table(dev_for_f10, ignore=()):
        m = types.ModuleType("scoped")
        m.BINDS = [BT.Bind("Mod4+F10", "nop scoped", device=dev_for_f10)]
        m.LAYERS = {}
        m.IGNORE_DEVICES = list(ignore)
        return m

    class Recorder(NullI3):
        def __init__(self):
            self.cmds = []

        def command(self, cmd):
            self.cmds.append(cmd)
            return True

    def run_scoped(table):
        rec = Recorder()
        dd = H.Daemon(table, d, pub, i3=rec)
        out = []
        tap(d, code_for(d, "F10"), mod4, n=2)
        time.sleep(0.2)
        while d.pending_events():
            out += dd.pump(d.next_event())
        dd.grabs.sync_binds([])
        dd.close()
        return out

    fired_same = run_scoped(scoped_table(xtest_name))
    check(fired_same == ["nop scoped", "nop scoped"],
          f"a bind scoped to device={xtest_name!r} FIRES for that source",
          str(fired_same))

    fired_other = run_scoped(scoped_table(other_kbd))
    check(fired_other == [],
          f"the same bind scoped to device={other_kbd!r} is INERT for a key "
          "the XTEST device produced",
          str(fired_other))

    # (negative) IGNORE_DEVICES drops the source outright
    fired_ignored = run_scoped(scoped_table(None, ignore=[xtest_name]))
    check(fired_ignored == [],
          f"IGNORE_DEVICES={[xtest_name]} drops every event from that source",
          str(fired_ignored))
    fired_unignored = run_scoped(scoped_table(None, ignore=["no such device"]))
    check(fired_unignored == ["nop scoped", "nop scoped"],
          "while an IGNORE_DEVICES naming something else changes nothing",
          str(fired_unignored))

    feed("q")

    # -- 5d: the TRANSITION LOG — the evidence hwds.27 had none of ------------
    # The live :10 daemon replayed {"layer":"nav","mod":"resize"} to the first
    # bar that connected, with nothing pressed, and logged NOTHING — so the one
    # observation could not be attributed to anything and a recurrence would
    # have been just as uninformative.
    #
    # What is checked here is not that a line appears (test_layers.py does that
    # against a fake) but that the three DISCRIMINATING fields are filled with
    # real values off a real server: a keycode this keymap actually uses, the
    # mask the server actually sent, and the device that actually produced the
    # key. Each is `none` unless the whole XI2 -> to_event -> engine chain
    # carries it, and each is `none` in a log written from engine state alone.
    check(dae.engine.state["layer"] == "default",
          "back in the default layer for the transition-log checks",
          str(dae.engine.state))
    log_lines = []
    saved_log, dae.engine.log = dae.engine.log, log_lines.append
    feed("o", mods=["Super_L"])
    trans = [ln for ln in log_lines if ln.startswith("transition ")]
    check(len(trans) == 1 and "layer=default->nav" in trans[0],
          "entering nav on a real server emits exactly one transition line",
          str(log_lines))
    line = trans[0] if trans else ""
    o_code = code_for(d, "o")
    check(f"keycode={o_code}" in line,
          f"the transition names the keycode the server sent ({o_code})", line)
    seen_mask = re.search(r"mask=0x([0-9a-f]+)", line)
    check(seen_mask is not None and int(seen_mask.group(1), 16) & H.MOD4,
          "and the modifier mask the event arrived with", line)
    check(f"device={xtest_name!r}" in line and "sourceid=none" not in line,
          "and the SOURCE DEVICE — here the XTEST injector, which is the only "
          "field that separates an injected $mod+o from a typed one after the "
          "fact (IGNORE_DEVICES ships empty, so both reach the engine)", line)
    log_lines.clear()
    feed("q")
    trans = [ln for ln in log_lines if ln.startswith("transition ")]
    check(len(trans) == 1 and "layer=nav->default" in trans[0]
          and f"keycode={code_for(d, 'q')}" in trans[0],
          "and leaving nav names the key that did it", str(log_lines))
    dae.engine.log = saved_log

    # -- 5e: a phantom hold must not survive an IDLE daemon -------------------
    # `_expire_stale_holds` runs only when an event ARRIVES. The observed
    # failure was a state served out of the replay buffer by a daemon that was
    # receiving nothing, so the guard could not fire and the belief stood until
    # real keys resumed. The lost release is produced here by taking the
    # modifier away WITHOUT letting the daemon see the release — which is what
    # a lost release is — and then asking the server directly.
    feed("o", mods=["Super_L"])
    ctrl = code_for(d, "Control_L")
    xtest.fake_input(d, X.KeyPress, ctrl)
    d.sync()
    time.sleep(0.1)
    while d.pending_events():
        dae.pump(d.next_event())
    check(dae.engine.state["mod"] == "move",
          "a really-held Ctrl is observed as the move sublayer",
          str(dae.engine.state))
    check(dae.reconcile_mods() is False,
          "and the server CONFIRMS it, so the reconcile retracts nothing",
          str(dae.engine.state))
    xtest.fake_input(d, X.KeyRelease, ctrl)
    d.sync()
    time.sleep(0.1)
    while d.pending_events():
        d.next_event()                  # the release the daemon never sees
    check(dae.engine.state["mod"] == "move",
          "a LOST release leaves the phantom sublayer standing — the bug shape",
          str(dae.engine.state))
    retracted = dae.reconcile_mods()
    check(retracted and dae.engine.state["mod"] is None,
          "and the idle reconcile drops it against the server's own mask",
          str(dae.engine.state))
    check(dae.engine.state["layer"] == "nav",
          "while the LAYER — which X has no opinion about — is untouched",
          str(dae.engine.state))
    feed("q")

    # Hand the grabs back before a second daemon opens on the same connection:
    # X would otherwise deliver this daemon's registrations to that one, and the
    # Mod1 checks below would be reading a grab set nobody under test made.
    dae.grabs.sync_binds([])
    dae.close()

    # -- 5f: the alt-tab HOLD layer, on a real server (dotfiles-hwds.40) -------
    # The switcher is the first layer whose modifier is ALREADY DOWN when the
    # layer is entered, and everything hard about it is a property of the real
    # X server: whether the layer's grab set can actually be obtained, whether
    # ISO_Left_Tab resolves at all, and what a passive grab does about a key
    # that was already held when it was installed. A fake keymap answers all
    # three by fiat.

    # (a) the SHIPPED layer's grab set, obtained for real. No daemon and no
    # dispatch — this is only asking the server whether these chords are ours.
    sw = H.GrabManager(Adapter(), mod="Mod4")
    want = H.chords_for(BT, "switcher", mod="Mod4")
    sw.sync_binds(want)
    check(not sw.problems,
          "the shipped switcher layer's whole grab set is obtainable on a real "
          "server — zero refusals, zero unresolvable keysyms", str(sw.problems))
    for c in ("Mod4+Escape", "Mod4+Shift+ISO_Left_Tab", "q"):
        check(c in sw.chords, f"{c} was actually GRABBED, not merely requested")
    for c in ("Super_L", "Super_R", "Mod4+Shift+q"):
        check(c not in sw.chords,
              f"{c} is deliberately absent from a hold layer's grab set")

    # (b) ISO_Left_Tab exists, is the same physical key as Tab, and the daemon
    # tells the two apart by MASK. python-xlib does not preload the xkb keysym
    # group, so before H.keysym_by_name this resolved to 0 and the chord was
    # silently never grabbed.
    tab_code = code_for(d, "Tab")
    check(Adapter().keysym_to_keycode("ISO_Left_Tab") == tab_code != 0,
          "ISO_Left_Tab resolves, and to the SAME keycode as Tab",
          f"Tab={tab_code} ISO_Left_Tab="
          f"{Adapter().keysym_to_keycode('ISO_Left_Tab')}")
    check(sw.keysym_for(tab_code, H.MOD4) == "Tab",
          "$mod+Tab is named Tab — cycle forwards")
    check(sw.keysym_for(tab_code, H.MOD4 | H.SHIFT) == "ISO_Left_Tab",
          "$mod+Shift+Tab is named ISO_Left_Tab — cycle BACKWARDS. Resolve it "
          "by keycode alone and the switcher cycles the wrong way in silence")
    sw.sync_binds([])

    # (c) the gesture itself, through the REAL Daemon. The bind table is a
    # stand-in with `nop` actions rather than the shipped one for one reason:
    # the shipped switcher dispatches `run()` of qs-overlay.sh, and a live check
    # must not spawn the user's shell scripts to prove the engine wiring. The
    # SHAPE is the shipped shape — same hold, same keys, same tuple actions.
    class RecordingI3:
        def __init__(self):
            self.cmds = []

        def command(self, cmd):
            self.cmds.append(cmd)
            return True

        def close(self):
            pass

    swmod = types.ModuleType("switcher_live")
    swmod.BINDS = [BT.Bind("$mod+Tab", ("nop sw-open", BT.enter_layer("sw")))]
    swmod.LAYERS = {"sw": BT.Layer(
        binds=[BT.Bind("Tab", "nop sw-next"),
               BT.Bind("ISO_Left_Tab", "nop sw-prev"),
               BT.Bind("Escape", ("nop sw-cancel", BT.exit_layer()))],
        hold="$mod", on_hold_release="nop sw-commit", exit_keys=["q"])}
    swmod.IGNORE_DEVICES = []
    rec = RecordingI3()
    swd = H.Daemon(swmod, d, pub, i3=rec)

    def sw_pump(settle=0.15):
        time.sleep(settle)
        out = []
        while d.pending_events():
            out += swd.pump(d.next_event())
        return out

    def sw_tap(keysym, mods=()):
        code = code_for(d, keysym)
        for m in mods:
            xtest.fake_input(d, X.KeyPress, code_for(d, m))
        xtest.fake_input(d, X.KeyPress, code)
        xtest.fake_input(d, X.KeyRelease, code)
        for m in reversed(mods):
            xtest.fake_input(d, X.KeyRelease, code_for(d, m))
        d.sync()
        return sw_pump()

    super_l = code_for(d, "Super_L")
    xtest.fake_input(d, X.KeyPress, super_l)     # $mod goes down FIRST
    d.sync()
    sw_pump()
    check(swd.engine.held == frozenset(),
          "the daemon never saw the $mod press — Super_L is ungrabbed in the "
          "default layer, which is why commit cannot be gated on belief",
          str(swd.engine.held))

    check(sw_tap("Tab") == ["nop sw-open"], "$mod+Tab opens the switcher")
    check(swd.engine.state["layer"] == "sw", "and takes the layer",
          str(swd.engine.state))
    check("Super_L" not in swd.grabs.chords,
          "entering the layer did NOT grab the held modifier's keysym — a "
          "passive grab on a key that is already down never activates")
    check(not swd.grabs.problems, "and the layer's grabs cost zero BadAccess",
          str(swd.grabs.problems))

    check(sw_tap("Tab") == ["nop sw-next"],
          "a second Tab, still with $mod down, cycles forwards")
    check(sw_tap("Tab", mods=["Shift_L"]) == ["nop sw-prev"],
          "and Shift+Tab cycles BACKWARDS on a real server — the end-to-end "
          "version of the keysym check above")

    check(swd.reconcile_mods() is False,
          "while $mod is genuinely down the server confirms it and nothing ends",
          str(swd.engine.state))
    check(swd.engine.state["layer"] == "sw", "the layer is still up")

    # THE RELEASE-BEFORE-GRAB RACE, reproduced exactly: $mod comes up and the
    # daemon is given every chance to see it. It cannot — there is no grab that
    # could deliver it — so without the server poll the layer would stand here
    # forever with the switcher open and its keys eaten session-wide.
    xtest.fake_input(d, X.KeyRelease, super_l)
    d.sync()
    check(sw_pump() == [],
          "the $mod release delivers NO event to the daemon at all")
    check(swd.engine.state["layer"] == "sw",
          "so on events alone the layer would be stuck up with nothing held",
          str(swd.engine.state))
    rec.cmds.clear()
    check(swd.reconcile_mods() is True,
          "asking the server ends it", str(swd.engine.state))
    check(swd.engine.state["layer"] == "default", "the layer is down",
          str(swd.engine.state))
    check(rec.cmds == ["nop sw-commit"],
          "and the commit was DISPATCHED, not merely implied by the exit",
          str(rec.cmds))
    check("Tab" not in swd.grabs.chords,
          "the layer's bare keys went back to applications with it",
          str(sorted(swd.grabs.chords)))

    swd.grabs.sync_binds([])
    swd.close()

    # -- 5b: the SAME daemon on a Mod1 display — the :10 shape ----------------
    # `$mod` is not a constant. The xrdp session entry merges `i3wm.mod: Mod1`
    # before exec'ing i3, because the RDP client captures the Win key, so :10
    # and :0 genuinely disagree about what `$mod+o` means (ft003 / adr0004).
    #
    # Everything above ran on a display carrying no i3wm.mod resource at all,
    # where the detected mod and the Mod4 default are the SAME VALUE — so the
    # daemon -> grab-set -> engine wiring was only ever exercised where a break
    # in it is invisible. That is not hypothetical: dropping `mod=self.mod` from
    # the LayerEngine constructor in Daemon.__init__ passes the entire committed
    # suite (186 pytest + every check above), and on a real :10 it means the
    # grabs land on Mod1 while the engine still matches Mod4 — nav is simply
    # unreachable. Only a Mod1 display catches it, so here is one.
    #
    # The resource is merged AFTER i3 connected, deliberately: X discards root
    # properties when the last client disconnects, so a resource written before
    # the WM is up does not survive to be read.
    rm_atom = d.intern_atom("RESOURCE_MANAGER")
    root.change_property(rm_atom, Xatom.STRING, 8, b"i3wm.mod:\tMod1\n")
    d.sync()
    check(H.x_resource_mod(d) == "Mod1",
          "i3wm.mod: Mod1 merged onto the live display is read back as $mod",
          H.x_resource_mod(d))

    alt = H.Daemon(BT, d, pub, i3=NullI3())

    def alt_feed(keysym, mods=()):
        code = code_for(d, keysym)
        mod_codes = [code_for(d, m) for m in mods]
        for mc in mod_codes:
            xtest.fake_input(d, X.KeyPress, mc)
        xtest.fake_input(d, X.KeyPress, code)
        xtest.fake_input(d, X.KeyRelease, code)
        for mc in reversed(mod_codes):
            xtest.fake_input(d, X.KeyRelease, mc)
        d.sync()
        time.sleep(0.15)
        out = []
        while d.pending_events():
            out += alt.pump(d.next_event())
        return out

    check(alt.mod == "Mod1", "the daemon detected $mod=Mod1 for itself", alt.mod)

    # Super+o is what $mod+o means on :0 and NOTHING on :10. Checked first so a
    # daemon that grabbed both modifiers cannot pass the next check by accident.
    alt_feed("o", mods=["Super_L"])
    check(alt.engine.state["layer"] == "default",
          "Super+o does NOT enter nav where $mod is Mod1",
          str(alt.engine.state))

    # Alt+o is the payoff: it has to survive BOTH hops — grabbed on the Mod1
    # mask, and then matched by an engine that also knows $mod is Mod1.
    alt_feed("o", mods=["Alt_L"])
    check(alt.engine.state["layer"] == "nav",
          "Alt+o DOES enter nav where $mod is Mod1 — grab set and engine agree "
          "on the display's own modifier",
          str(alt.engine.state))
    check("h" in alt.grabs.chords,
          "and the layer's bare keys were grabbed on the way in",
          str(sorted(alt.grabs.chords)))

    acts = alt_feed("h")
    check(acts == ["focus left"], "a nav bind dispatches on the Mod1 display",
          str(acts))

    alt_feed("q")
    check(alt.engine.state["layer"] == "default",
          "q leaves nav on the Mod1 display", str(alt.engine.state))
    alt.grabs.sync_binds([])
    alt.close()
    root.delete_property(rm_atom)
    d.sync()

    # -- 6: single instance --------------------------------------------------
    lock = H.lock_path()
    first = H.SingleInstance(lock)
    try:
        H.SingleInstance(lock)
        check(False, "second instance refused on the same display")
    except H.AlreadyRunning:
        check(True, "second instance refused on the same display")
    finally:
        first.release()

    return 0 if all(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
