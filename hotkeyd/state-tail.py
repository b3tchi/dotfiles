#!/usr/bin/env python3
"""Print hotkeyd's layer-state feed line by line (sp020 T7, ft011).

Exists because the bar is QML and this box has no socat: quickshell can spawn a
process and read its stdout, but it cannot open a unix socket itself. One tiny
reader per bar, stdout line-buffered, so `Process { stdout: SplitParser }` works
exactly as it does for the stats and notification feeds.

Contract, and why each half matters:
  - Prints the daemon's JSON lines VERBATIM. The daemon replays the current
    state on connect, so the first line is always the truth as of now and a bar
    that starts late is never blank.
  - Exits non-zero the moment the socket is missing or closes, instead of
    retrying inside its own loop. That is [[adr0014]]: a reader cannot
    re-establish its own vanished precondition, so it dies and lets the layer
    above decide. The bar's respawn timer is that layer.

usage: state-tail.py [display]        (default: $DISPLAY)
"""
from __future__ import annotations

import os
import socket
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import layers as L  # noqa: E402


def main() -> int:
    display = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DISPLAY")
    path = L.socket_path(display)
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.connect(str(path))
    except OSError as e:
        print(f"state-tail: cannot connect to {path}: {e}", file=sys.stderr)
        return 1

    buf = b""
    try:
        while True:
            chunk = c.recv(4096)
            if not chunk:
                return 0            # daemon went away: exit, let the host respawn
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if line:
                    # One JSON object per line, passed through untouched.
                    sys.stdout.write(line.decode(errors="replace") + "\n")
                    sys.stdout.flush()
    except OSError as e:
        print(f"state-tail: {path}: {e}", file=sys.stderr)
        return 1
    finally:
        c.close()


if __name__ == "__main__":
    sys.exit(main())
