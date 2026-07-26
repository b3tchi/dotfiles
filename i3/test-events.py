#!/usr/bin/env python3
"""Parse an `i3-msg -t subscribe` capture into one line per event.

Test helper for i3/test-nav-mode.sh. i3 streams events as CONCATENATED JSON
objects with no separator, so a line-based reader cannot consume them —
raw_decode walks the buffer object by object instead.

usage: test-events.py <capture-file> [prefix]
  no prefix  -> every event: "BINDING <mods> <command>" or "MODE <change>"
  prefix     -> only binding commands starting with it, joined by "|"
                (e.g. `nop ` to assert the nav mode's Shift signal pair)
"""
import json
import sys


def events(path):
    raw = open(path).read().strip()
    dec, i = json.JSONDecoder(), 0
    while i < len(raw):
        obj, i = dec.raw_decode(raw, i)
        while i < len(raw) and raw[i] in " \n\r\t":
            i += 1
        yield obj


def main() -> int:
    path = sys.argv[1]
    prefix = sys.argv[2] if len(sys.argv) > 2 else None

    if prefix is not None:
        hits = []
        for obj in events(path):
            cmd = ((obj.get("binding") or {}).get("command") or "").strip()
            if cmd.startswith(prefix):
                hits.append(cmd)
        print("|".join(hits))
        return 0

    for obj in events(path):
        b = obj.get("binding")
        if b:
            print("BINDING %s %s" % (",".join(b.get("mods") or []), b.get("command")))
        else:
            print("MODE %s" % obj.get("change"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
