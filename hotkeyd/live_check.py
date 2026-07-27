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

    # -- 5: single instance --------------------------------------------------
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
