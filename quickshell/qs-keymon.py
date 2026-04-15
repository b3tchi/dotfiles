#!/usr/bin/env python3
# Global raw key-event listener for the quickshell alt-tab switcher.
#
# Uses X Input Extension 2 RawKeyPress/RawKeyRelease events on the root window
# — no client window is created, so it doesn't pollute the i3 tree the way
# `xinput test-xi2` does (which creates a 1115x1013 event-catcher window with
# no WM_CLASS and no PID, appearing as an empty frame in the window list).
#
# Output: one line per interesting key event: "press <code>" or "release <code>".
# Consecutive duplicates are deduplicated. Output is flushed per line.
#
# Dependencies: python-xlib (Arch/Manjaro/Arch ARM: `pacman -S python-xlib`;
# Termux: `pkg install python-xlib` or `pip install python-xlib`).

import struct
import sys
from Xlib import display
from Xlib.ext import xinput

# X11 keycodes (not scancodes): 64=Alt_L, 108=Alt_R, 133=Super_L,
# 134=Super_R, 23=Tab, 25=W. Must stay in sync with the keyMonitor
# handler in quickshell/overlay/shell.qml.
INTERESTING = {64, 108, 133, 134, 23, 25}

# python-xlib 0.33 does not register a parser for XI2 raw events, so they
# arrive as bare GenericEvent with only `evtype` filled in — the rest of the
# event body is available as an opaque byte string in `event.data`. The raw
# event layout starts with deviceid(u16) + time(u32) + detail(u32), so the
# keycode lives at offset 6 and we unpack it manually.
_RAW_HEADER = struct.Struct("<HII")  # deviceid, time, detail


def main() -> int:
    d = display.Display()
    if not d.has_extension("XInputExtension"):
        print("XInputExtension not available", file=sys.stderr)
        return 1

    root = d.screen().root
    root.xinput_select_events([
        (xinput.AllMasterDevices,
         xinput.RawKeyPressMask | xinput.RawKeyReleaseMask),
    ])
    d.sync()

    last = None
    while True:
        event = d.next_event()
        evtype = getattr(event, "evtype", None)
        if evtype == xinput.RawKeyPress:
            action = "press"
        elif evtype == xinput.RawKeyRelease:
            action = "release"
        else:
            continue

        data = getattr(event, "data", None)
        if not isinstance(data, (bytes, bytearray)) or len(data) < _RAW_HEADER.size:
            continue
        _, _, code = _RAW_HEADER.unpack_from(data, 0)
        if code not in INTERESTING:
            continue

        msg = f"{action} {code}"
        if msg != last:
            print(msg, flush=True)
            last = msg


if __name__ == "__main__":
    sys.exit(main() or 0)
