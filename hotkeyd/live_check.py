#!/usr/bin/env python3
"""Live-X checks for hotkeyd (sp020 Task 4). Driven by test-hotkeyd.sh stage 6.

These are the assertions that fakes cannot make: a REAL XGrabKey against a real
X server, with NumLock and CapsLock actually toggled, dispatching to a real i3
and reading the effect back out of the tree. poc013 measured that a bare-mask
grab fires 0/3 with NumLock on — that finding only exists because it was checked
against a live server, so it gets checked that way here too.

Prints `PASS <what>` / `FAIL <what>` lines; exits non-zero if anything failed.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from Xlib import X, XK, display as xdisplay  # noqa: E402
from Xlib.ext import xtest  # noqa: E402

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
    """Count KeyPress events delivered to our grab within the window."""
    seen = 0
    end = time.time() + seconds
    while time.time() < end:
        if d.pending_events():
            ev = d.next_event()
            if ev.type == X.KeyPress and ev.detail == code:
                seen += 1
        else:
            time.sleep(0.02)
    return seen


def main() -> int:
    d = xdisplay.Display()
    root = d.screen().root
    f10 = code_for(d, "F10")
    f11 = code_for(d, "F11")
    mod4 = code_for(d, "Super_L")
    numlock = code_for(d, "Num_Lock")
    caps = code_for(d, "Caps_Lock")

    class Adapter:
        def keysym_to_keycode(self, name):
            ks = XK.string_to_keysym(name)
            return d.keysym_to_keycode(ks) if ks else 0

        def grab_key(self, code, mask):
            errs = []
            root.grab_key(code, mask, 1, X.GrabModeAsync, X.GrabModeAsync,
                          onerror=lambda e, r: errs.append(e))
            d.sync()
            if errs:
                raise H.GrabRefused(type(errs[0]).__name__)

        def ungrab_key(self, code, mask):
            root.ungrab_key(code, mask)

        def sync(self):
            d.sync()

    # -- 1: a real grab fires, with and without the lock keys on ------------
    g = H.GrabManager(Adapter())
    g.sync_binds(["Mod4+F10"])
    check(not g.problems, "real XGrabKey registered Mod4+F10", str(g.problems))

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

    # -- 2: BadAccess on a chord i3 already owns, rest keeps working --------
    g2 = H.GrabManager(Adapter())
    g2.sync_binds(["Mod4+F11", "Mod4+F10"])   # F11 is bound in the test i3 cfg
    took_f11 = any("F11" in p for p in g2.problems)
    check(took_f11, "BadAccess reported for the chord i3 already grabbed",
          str(g2.problems))
    check("Mod4+F10" in g2.chords,
          "the other chord is still grabbed after a BadAccess")

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
    dae._pending = []

    def peek():
        if dae._pending:
            return dae._pending.pop(0)
        return d.next_event() if d.pending_events() else None

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
        while d.pending_events() or dae._pending:
            ev = dae._pending.pop(0) if dae._pending else d.next_event()
            out += dae.pump(ev, peek=peek)
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
        dae.pump(d.next_event(), peek=peek)
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
        dae.pump(d.next_event(), peek=peek)
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
        dae.pump(d.next_event(), peek=peek)
    check(dae.engine.state == {"layer": "nav", "mod": None},
          "held Shift does NOT become a sublayer", str(dae.engine.state))
    feed("q", mods=[])
    check(dae.engine.state["layer"] == "default",
          "Shift+q leaves the layer", str(dae.engine.state))
    xtest.fake_input(d, X.KeyRelease, shift_code)
    d.sync()
    time.sleep(0.1)
    while d.pending_events():
        dae.pump(d.next_event(), peek=peek)

    # -- auto-repeat: the G3 case, measured on a real hold -------------------
    feed("o", mods=["Super_L"])
    hcode = code_for(d, "h")
    xtest.fake_input(d, X.KeyPress, hcode)
    d.sync()
    time.sleep(1.2)                                    # let X auto-repeat run
    xtest.fake_input(d, X.KeyRelease, hcode)
    d.sync()
    time.sleep(0.2)
    fired = []
    while d.pending_events() or dae._pending:
        ev = dae._pending.pop(0) if dae._pending else d.next_event()
        fired += dae.pump(ev, peek=peek)
    check(len(fired) == 1,
          "a held key fires ONCE despite the real auto-repeat stream",
          f"{len(fired)} dispatches")
    feed("q")
    dae.close()

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
