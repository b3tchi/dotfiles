#!/usr/bin/env python3
# Held-Shift monitor for the i3 nav-mode indicator (dotfiles-5u6m).
#
# Prints "shift 1" when Shift is physically down and "shift 0" when it is not,
# one line per CHANGE only, flushed per line. Consumed by quickshell's Bar.qml
# while i3 is in mode "nav", where it decides whether the mode pill reads
# "nav" or "nav MOVE".
#
# Why not reuse qs-keymon.py: that one reports raw key EDGES (press 50 /
# release 50) and the consumer has to pair them up into a state. Any edge that
# never arrives — a release swallowed while another client holds a grab, a
# release that happens while the listener is being started or torn down at mode
# entry/exit, an X server that resets modifiers under it — leaves the consumer
# stuck in the wrong state until the next press. This one asks the server for
# the CURRENT modifier mask instead, so it is self-correcting: a missed
# transition costs at most one poll interval, never a stuck indicator.
#
# XQueryPointer's mask is the authoritative logical modifier state (the same
# bits X hands to every client in a KeyPress event), so this also reports Shift
# correctly no matter which physical key or keymap produced it — Shift_L,
# Shift_R, or a remapped key that maps into the shift modifier at all. The
# keycode-based approach could only ever know about the codes hardcoded in it.
#
# Dependencies: python-xlib (same as qs-keymon.py — already required by the
# switcher, so this adds no new package to any platform).

import sys
import time

from Xlib import X, display

POLL_SECONDS = 0.04  # 25 Hz — well under the ~100ms that reads as "instant"


def main() -> int:
    d = display.Display()
    root = d.screen().root

    last = None
    while True:
        # query_pointer() round-trips to the server; .mask carries the live
        # modifier+button state. ShiftMask is set while EITHER Shift is down.
        try:
            held = bool(root.query_pointer().mask & X.ShiftMask)
        except Exception:
            # A display that went away (session teardown) ends the monitor
            # rather than spinning on errors — the consumer respawns it.
            return 0

        if held != last:
            print("shift 1" if held else "shift 0", flush=True)
            last = held

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main() or 0)
