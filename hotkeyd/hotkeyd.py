#!/usr/bin/env python3
"""hotkeyd — global keybinding daemon for X11 sessions (sp020, ft011).

Task 2 scope (dotfiles-yvxs): the `--check` validation front-end only. The grab
loop, i3 IPC dispatch and layer engine land in Tasks 3-4 (dotfiles-7cc7,
dotfiles-hwds.1); running without `--check` says so rather than pretending.

`--check` is the replacement for `i3 -C` once binds leave i3: it loads the table,
reports EVERY problem with the offending chord named, and exits non-zero. It
needs no X connection, so it works headless and in a pre-commit hook.
"""
from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import binds as default_binds  # noqa: E402


def load_table(path: str | None):
    """Import a bind table module. Default is the shipped `binds.py`."""
    if not path:
        return default_binds
    p = Path(path).expanduser().resolve()
    if not p.is_file():
        raise SystemExit(f"hotkeyd: no such bind table: {p}")
    spec = importlib.util.spec_from_file_location(f"hotkeyd_binds_{p.stem}", p)
    if spec is None or spec.loader is None:
        raise SystemExit(f"hotkeyd: cannot import bind table: {p}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for attr in ("BINDS", "LAYERS"):
        if not hasattr(mod, attr):
            raise SystemExit(f"hotkeyd: bind table {p} defines no {attr}")
    return mod


def check(table) -> int:
    problems = default_binds.validate(table.BINDS, table.LAYERS)
    if problems:
        print(f"hotkeyd: {len(problems)} problem(s) in the bind table:",
              file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1
    n_layer_binds = sum(
        len(l.binds) + sum(len(m.binds) for m in l.mods.values())
        for l in table.LAYERS.values())
    print(f"hotkeyd: OK — {len(table.BINDS)} global binds, "
          f"{len(table.LAYERS)} layer(s), {n_layer_binds} layer binds")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="hotkeyd")
    ap.add_argument("--binds", help="path to a bind table module "
                                    "(default: the shipped binds.py)")
    ap.add_argument("--check", action="store_true",
                    help="validate the bind table and exit; no grabs, no X")
    ap.add_argument("--display", help="X display (grab loop; not yet implemented)")
    args = ap.parse_args()

    table = load_table(args.binds)
    if args.check:
        return check(table)

    print("hotkeyd: grab loop not implemented yet — Tasks 3-4 "
          "(dotfiles-7cc7, dotfiles-hwds.1). Use --check for now.",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
