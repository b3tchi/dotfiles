#!/usr/bin/env python3
"""hotkeyd — global keybinding daemon for X11 sessions (sp020, ft011).

Owns its own grabs (per-bind `XGrabKey` on the root window, never
`XGrabKeyboard` — an exclusive grab held by a hung daemon locks the whole
session, per-key grabs degrade to "that chord stopped working") and dispatches
over ONE persistent i3 IPC connection, so no `i3-msg` process is spawned per
keystroke.

Layer state and the bar feed live in `layers.py`; the bind table in `binds.py`.

`--check` validates the table and exits without touching X, which is the `i3 -C`
replacement once binds leave i3 — it works headless and in a pre-commit hook.

Dependencies: python-xlib (adr0015 condition 1).
"""
from __future__ import annotations

import argparse
import errno
import fcntl
import importlib.util
import os
import signal
import socket
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import binds as default_binds  # noqa: E402
import layers as L  # noqa: E402

# X modifier masks. Duplicated as plain ints rather than imported from Xlib so
# the pure-logic tests (and --check) run with no X library present at all.
SHIFT, LOCK, CTRL, MOD1, MOD2, MOD3, MOD4, MOD5 = (
    1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4, 1 << 5, 1 << 6, 1 << 7)

MASK_BY_NAME = {"Shift": SHIFT, "Ctrl": CTRL, "Mod1": MOD1, "Mod2": MOD2,
                "Mod3": MOD3, "Mod4": MOD4, "Mod5": MOD5}
NAME_BY_MASK = {v: k for k, v in MASK_BY_NAME.items()}

# NumLock and CapsLock ride in the event state but are not layer modifiers.
# poc013 measured the consequence of ignoring them at GRAB time: a bare-mask
# grab fires 3/3 with NumLock off and 0/3 with NumLock on.
LOCK_VARIANTS = (0, LOCK, MOD2, LOCK | MOD2)
LOCK_BITS = LOCK | MOD2


class GrabRefused(Exception):
    """X refused a grab — almost always BadAccess because another client (i3,
    mid-migration) already owns that chord."""


class AlreadyRunning(RuntimeError):
    """Another daemon holds this display's lock."""


class TableInvalid(Exception):
    """A bind table that cannot be loaded — unreadable, unimportable, or
    rejected by the validator.

    Deliberately an Exception and NOT a SystemExit: the reload path catches
    Exception to keep the old table, and SystemExit (a BaseException) sailed
    straight through that handler and killed the daemon on a bad SIGHUP.
    """


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _runtime_dir() -> Path:
    return Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")


def lock_path(display: str | None = None) -> Path:
    """Per-display lock. Screen suffix stripped so `:10.0` and `:10` are one
    session (dotfiles-3x85 normalization; RDP sessions present `:10.0`)."""
    display = display or os.environ.get("DISPLAY", ":0")
    tag = display.lstrip(":").split(".")[0]
    return _runtime_dir() / f"hotkeyd-{tag}.lock"


def x_resource_mod(xdisp=None) -> str:
    """What `$mod` means on THIS display.

    Read from the `i3wm.mod` X resource — the same source i3 reads via
    `set_from_resource $mod i3wm.mod Mod4` (ft003), with the same default. The
    xrdp session entry merges `i3wm.mod: Mod1` before exec'ing i3, so the two
    displays genuinely disagree and a table that hardcodes a modifier is wrong
    on one of them.
    """
    if xdisp is None:
        return default_binds.DEFAULT_MOD
    try:
        prop = xdisp.screen().root.get_full_property(
            xdisp.intern_atom("RESOURCE_MANAGER"), 0)
        if prop is None or not prop.value:
            return default_binds.DEFAULT_MOD
        raw = prop.value
        text = raw.decode(errors="replace") if isinstance(
            raw, (bytes, bytearray)) else str(raw)
        for line in text.splitlines():
            name, _, value = line.partition(":")
            if name.strip() == "i3wm.mod" and value.strip():
                return value.strip()
    except Exception:                           # noqa: BLE001
        pass
    return default_binds.DEFAULT_MOD


def to_event(kind: str, keysym: str, state: int) -> L.Event:
    """Translate an X key event into the engine's X-agnostic Event.

    Lock bits are stripped: with NumLock on, `Ctrl+h` arrives with Mod2 set, and
    leaving it in would make it a different chord than `Ctrl+h` without it.
    """
    state &= ~LOCK_BITS
    mods = {name for mask, name in NAME_BY_MASK.items() if state & mask}
    return L.Event(kind, keysym, frozenset(mods))


class SingleInstance:
    """flock-based single instance, the `qs-focus-border.py` pattern. Held for
    the process lifetime; the kernel releases it even on SIGKILL, so a hard-
    killed daemon does not lock its display out of a restart."""

    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = open(self.path, "w")
        try:
            fcntl.flock(self._fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            self._fh.close()
            if e.errno in (errno.EACCES, errno.EAGAIN):
                raise AlreadyRunning(
                    f"another hotkeyd holds {self.path}") from e
            raise
        self._fh.write(f"{os.getpid()}\n")
        self._fh.flush()

    def release(self):
        try:
            fcntl.flock(self._fh, fcntl.LOCK_UN)
        except OSError:
            pass
        self._fh.close()


# --------------------------------------------------------------------------
# grabs
# --------------------------------------------------------------------------

class GrabManager:
    """Owns the mapping chord -> (keycode, mask) and the grabs registered for it.

    `display` is anything with `keysym_to_keycode` / `grab_key` / `ungrab_key` /
    `sync` — the real X display in production, a recorder in tests.
    """

    def __init__(self, display, mod: str = None):
        self.d = display
        self.mod = mod or default_binds.DEFAULT_MOD
        self.problems: list[str] = []
        self._active: dict[str, tuple[int, int]] = {}   # chord -> (code, mask)

    def _resolve(self, chord: str) -> tuple[int, int] | None:
        try:
            mods, key = default_binds.parse_chord(chord, self.mod)
        except default_binds.BindError as e:
            self.problems.append(str(e))
            return None
        mask = 0
        for m in mods:
            mask |= MASK_BY_NAME.get(m, 0)
        code = self.d.keysym_to_keycode(key)
        if not code:
            self.problems.append(
                f"chord {chord!r}: keysym {key!r} is not on the current keymap")
            return None
        return code, mask

    def _grab(self, chord: str, code: int, mask: int):
        for extra in LOCK_VARIANTS:
            try:
                self.d.grab_key(code, mask | extra)
            except GrabRefused as e:
                # Per-chord degradation, never a dead daemon: mid-cutover this
                # is exactly what a chord still bound in i3 looks like, and the
                # rest of the table must keep working (poc013 probe 4).
                self.problems.append(
                    f"chord {chord!r}: {e} — already grabbed by another client?")
                return
        self._active[chord] = (code, mask)

    def _ungrab(self, code: int, mask: int):
        for extra in LOCK_VARIANTS:
            self.d.ungrab_key(code, mask | extra)

    def sync_binds(self, chords):
        """Make the registered grabs match `chords`.

        Only the difference moves: a chord present before and after keeps its
        grab untouched, so SIGHUP reload never drops a grab mid-gesture.
        """
        wanted = list(dict.fromkeys(chords))
        self.problems = []
        resolved: dict[str, tuple[int, int]] = {}
        for chord in wanted:
            r = self._resolve(chord)
            if r is not None:
                resolved[chord] = r

        for chord, (code, mask) in list(self._active.items()):
            if resolved.get(chord) != (code, mask):
                self._ungrab(code, mask)
                del self._active[chord]

        for chord, (code, mask) in resolved.items():
            if self._active.get(chord) != (code, mask):
                self._grab(chord, code, mask)
        self.d.sync()

    @property
    def chords(self):
        return list(self._active)

    def keysym_for(self, keycode: int) -> str | None:
        for chord, (code, _) in self._active.items():
            if code == keycode:
                return default_binds.parse_chord(chord, self.mod)[1]
        return None

    def on_mapping_notify(self) -> bool:
        """Compare-then-regrab. poc013 saw two spurious MappingNotify at every
        daemon startup, so regrabbing unconditionally would churn every grab for
        nothing; only a keycode that actually moved is re-registered."""
        changed = False
        self.problems = []
        for chord, (code, mask) in list(self._active.items()):
            r = self._resolve(chord)
            if r is None:
                self._ungrab(code, mask)
                del self._active[chord]
                changed = True
                continue
            new_code, new_mask = r
            if (new_code, new_mask) != (code, mask):
                self._ungrab(code, mask)
                self._grab(chord, new_code, new_mask)
                changed = True
        if changed:
            self.d.sync()
        return changed


# --------------------------------------------------------------------------
# i3 IPC
# --------------------------------------------------------------------------

MAGIC = b"i3-ipc"
HDR = struct.Struct("=6sII")
RUN_COMMAND = 0


def i3_socket_path(display: str | None = None, xdisp=None) -> str:
    """Resolve THIS display's i3 socket.

    Deliberately ignores `$I3SOCK`. i3 exports it into the environment of every
    process it execs, so a daemon started for `:10` by `:0`'s i3 inherits `:0`'s
    socket and every dispatch lands on the WRONG window manager — press a chord
    in the RDP session, a window moves on the native desktop. It also goes stale
    across an i3 restart, after which the daemon can never reconnect.

    Order: explicit `$HOTKEYD_I3SOCK` (an operator/test override that i3 never
    injects, so it cannot mis-route a session) -> the `I3_SOCKET_PATH` root
    property of our OWN X connection, which i3 rewrites on every restart ->
    `i3 --get-socketpath` with DISPLAY pinned and I3SOCK scrubbed.
    """
    override = os.environ.get("HOTKEYD_I3SOCK")
    if override:
        return override

    if xdisp is not None:
        try:
            prop = xdisp.screen().root.get_full_property(
                xdisp.intern_atom("I3_SOCKET_PATH"), 0)
            if prop is not None and prop.value:
                value = prop.value
                if isinstance(value, (bytes, bytearray)):
                    return value.decode().rstrip("\x00")
                return str(value).rstrip("\x00")
        except Exception:                       # noqa: BLE001
            pass                                # fall through to the CLI

    env = {k: v for k, v in os.environ.items() if k != "I3SOCK"}
    if display:
        env["DISPLAY"] = display
    return subprocess.run(["i3", "--get-socketpath"], capture_output=True,
                          text=True, check=True, env=env).stdout.strip()


class I3Client:
    """One connection for the process lifetime, reconnecting only when i3 itself
    restarts (which changes the socket path). Spawning `i3-msg` per keystroke is
    a ~30 ms process launch on the exact path this daemon exists to keep short.
    """

    def __init__(self, path_getter=i3_socket_path):
        self._path_getter = path_getter
        self._sock: socket.socket | None = None

    def _connect(self):
        path = self._path_getter()
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(path)
        self._sock = s

    def command(self, cmd: str) -> bool:
        """Returns True on success. A dispatch failure is REPORTED, never fatal:
        losing i3 must not take the keyboard layer down with it."""
        for attempt in (1, 2):
            try:
                if self._sock is None:
                    self._connect()
                payload = cmd.encode()
                self._sock.sendall(HDR.pack(MAGIC, len(payload), RUN_COMMAND)
                                   + payload)
                self._recv_reply()
                return True
            except (OSError, ConnectionError, subprocess.CalledProcessError):
                self.close()
                if attempt == 2:
                    return False
        return False

    def _recv_reply(self):
        hdr = self._recv_exact(HDR.size)
        _, length, _ = HDR.unpack(hdr)
        if length:
            self._recv_exact(length)

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("i3 IPC closed")
            buf += chunk
        return buf

    def close(self):
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None


# --------------------------------------------------------------------------
# table loading + --check
# --------------------------------------------------------------------------

def load_table(path: str | None, validate: bool = True):
    """Import a bind table and VALIDATE it before handing it over.

    Validation lives here, not only in `--check`, because every path that loads
    a table is a path where a broken one hurts: startup, SIGHUP, and the
    escape-hatch restart. us019 AC4 asks for the bind set to be refused before
    it is loaded — leaving that to whoever remembers to run `--check` is not
    that. Everything that can go wrong raises TableInvalid, so a caller can keep
    the table it already has.
    """
    if not path:
        mod = default_binds
    else:
        p = Path(path).expanduser().resolve()
        if not p.is_file():
            raise TableInvalid(f"no such bind table: {p}")
        spec = importlib.util.spec_from_file_location(
            f"hotkeyd_binds_{p.stem}", p)
        if spec is None or spec.loader is None:
            raise TableInvalid(f"cannot import bind table: {p}")
        mod = importlib.util.module_from_spec(spec)
        # Register BEFORE exec: dataclasses (and typing) resolve a class's
        # module through sys.modules[cls.__module__], so a table module that
        # defines its own dataclasses dies with "'NoneType' object has no
        # attribute '__dict__'" if it is not there. Any table derived from
        # binds.py hits this.
        sys.modules[spec.name] = mod
        try:
            spec.loader.exec_module(mod)
        except Exception as e:                  # noqa: BLE001
            sys.modules.pop(spec.name, None)
            raise TableInvalid(f"bind table {p} failed to import: {e}") from e
        for attr in ("BINDS", "LAYERS"):
            if not hasattr(mod, attr):
                raise TableInvalid(f"bind table {p} defines no {attr}")

    if validate:
        problems = default_binds.validate(mod.BINDS, mod.LAYERS)
        if problems:
            raise TableInvalid(
                f"{len(problems)} problem(s) in the bind table:\n  "
                + "\n  ".join(problems))
    return mod


# canonical modifier -> the keysyms that produce it, so a layer can grab the
# modifier KEYS themselves. Without these grabs a Ctrl press inside a layer never
# reaches the daemon, `_held` stays empty, and the move/resize sublayers are dead
# in a real session while every unit test still passes.
MOD_KEYSYMS_BY_NAME: dict[str, list[str]] = {}
for _ks, _canon in L.MOD_KEYSYMS.items():
    MOD_KEYSYMS_BY_NAME.setdefault(_canon, []).append(_ks)


def global_chords(table) -> list[str]:
    """What is grabbed in the default layer: the global binds, and nothing else.

    Layer binds are deliberately NOT here. Grabbing nav's bare `h`/`Escape`/
    `Return` permanently would swallow those keys from every application for as
    long as the daemon runs — the keyboard layer must be invisible until a layer
    is actually entered.
    """
    return list(dict.fromkeys(b.chord for b in table.BINDS))


def layer_chords(table, name: str, mod_name: str = None) -> list[str]:
    """The extra chords a layer needs while it is ACTIVE: its bare keys, its exit
    keys, its modifier-prefixed sublayer chords, and the modifier keys themselves
    (so held-modifier state is observable at all)."""
    layer = table.LAYERS[name]
    out = [b.chord for b in layer.binds] + list(layer.exit_keys)
    for mod in layer.mods.values():
        canon = default_binds.MODIFIER_ALIASES.get(
            default_binds.resolve_mod_name(mod.modifier, mod_name).lower(),
            mod.modifier)
        out += [f"{canon}+{b.chord}" for b in mod.binds]
        out += MOD_KEYSYMS_BY_NAME.get(canon, [])
    return list(dict.fromkeys(out))


def chords_for(table, layer: str | None = None, mod_name: str = None) -> list[str]:
    """The grab set for the CURRENT state. Re-synced on every layer transition."""
    out = global_chords(table)
    if layer and layer != L.DEFAULT_LAYER and layer in table.LAYERS:
        out = out + layer_chords(table, layer, mod_name)
    return list(dict.fromkeys(out))


def all_chords(table) -> list[str]:
    """Every chord any state could grab — used for reporting by --check, not as
    a runtime grab set (see chords_for)."""
    out = global_chords(table)
    for name in table.LAYERS:
        out += layer_chords(table, name)
    return list(dict.fromkeys(out))


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
          f"{len(table.LAYERS)} layer(s), {n_layer_binds} layer binds, "
          f"{len(all_chords(table))} chords to grab")
    return 0


# --------------------------------------------------------------------------
# daemon
# --------------------------------------------------------------------------

class XAdapter:
    """Adapts python-xlib to the GrabManager's four-method interface, and turns
    an async X error into the synchronous GrabRefused the manager degrades on.
    Defined at module scope (not inside the run loop) so the live checks can
    exercise the REAL adapter instead of a copy of it."""

    def __init__(self, d, root):
        self.d, self.root = d, root

    def keysym_to_keycode(self, name):
        from Xlib import XK                              # noqa: PLC0415
        ks = XK.string_to_keysym(name)
        return self.d.keysym_to_keycode(ks) if ks else 0

    def grab_key(self, code, mask):
        from Xlib import X                               # noqa: PLC0415
        errs = []
        self.root.grab_key(code, mask, 1, X.GrabModeAsync, X.GrabModeAsync,
                           onerror=lambda err, req: errs.append(err))
        self.d.sync()
        if errs:
            raise GrabRefused(type(errs[0]).__name__)

    def ungrab_key(self, code, mask):
        self.root.ungrab_key(code, mask)

    def sync(self):
        self.d.sync()


class Daemon:
    """The whole thing wired together: grabs -> engine -> dispatch + state feed.

    `pump()` is the unit of work and is public so the live checks can drive the
    REAL composition with REAL X events, rather than re-implementing the loop
    (and then testing the re-implementation).
    """

    def __init__(self, table, d, publisher, i3=None, display=None):
        self.table = table
        self.d = d
        self.display = display or os.environ.get("DISPLAY")
        self.pub = publisher
        # Resolve i3's socket through OUR OWN X connection, re-read on every
        # reconnect: that is what keeps a per-display daemon talking to its own
        # window manager, and what lets it follow an i3 restart.
        # BOTH arguments: xdisp for the root-property read, display for the CLI
        # fallback's pinned env. Passing only xdisp meant that whenever the
        # property was absent or unreadable the fallback inherited the AMBIENT
        # DISPLAY — so a :10 daemon started from :0's session resolved :0's
        # socket, which is the very bug this task exists to remove.
        self.i3 = i3 if i3 is not None else I3Client(
            lambda: i3_socket_path(display=self.display, xdisp=d))
        self.mod = x_resource_mod(d)
        self.grabs = GrabManager(XAdapter(d, d.screen().root), mod=self.mod)
        self.engine = L.LayerEngine(table.BINDS, table.LAYERS,
                                    publisher=publisher, mod=self.mod)
        self.grabs.sync_binds(chords_for(table, mod_name=self.mod))

    def resync_grabs(self):
        self.grabs.sync_binds(chords_for(self.table,
                                         self.engine.state["layer"],
                                         self.mod))

    def pump(self, ev, peek=None) -> list:
        """Handle one X event. `peek` returns the next queued event or None and
        exists for auto-repeat coalescing. Returns the actions dispatched."""
        from Xlib import X                               # noqa: PLC0415

        if ev.type == X.MappingNotify:
            self.d.refresh_keyboard_mapping(ev)
            self.grabs.on_mapping_notify()
            return []
        if ev.type not in (X.KeyPress, X.KeyRelease):
            return []

        # Auto-repeat arrives as RELEASE+PRESS pairs sharing one timestamp:
        # python-xlib exposes no XKB binding, so detectable auto-repeat cannot be
        # switched on and the pairs must be coalesced here. Without this the
        # engine sees a genuine release between every repeat, so nothing is ever
        # suppressed and on_release binds fire ~15x a second while a key is held.
        # Measured on Xvfb: a 1.5 s hold delivers 22 press + 22 release.
        if ev.type == X.KeyRelease and peek is not None:
            nxt = peek()
            if nxt is not None:
                if (nxt.type == X.KeyPress and nxt.detail == ev.detail
                        and nxt.time == ev.time):
                    return []           # synthetic pair: swallow both
                self._pending.append(nxt)

        name = self.grabs.keysym_for(ev.detail) or _keysym_name(self.d, ev)
        if name is None:
            return []
        kind = "press" if ev.type == X.KeyPress else "release"
        before = self.engine.state["layer"]
        actions = self.engine.handle(to_event(kind, name, ev.state))
        for action in actions:
            _dispatch(self.i3, action)
        if self.engine.state["layer"] != before:
            # A layer's bare keys exist only while that layer is active, so they
            # never shadow an application's keyboard outside it. sync_binds moves
            # only the difference, so nothing is dropped mid-gesture.
            self.resync_grabs()
        return actions

    _pending: list = []

    def close(self):
        self.pub.close()
        self.i3.close()


def run_daemon(table, display_name: str | None) -> int:
    """Grab, dispatch, publish. Returns a process exit code.

    Fail-fast on a lost X connection ([[adr0014]]): the daemon dies and the
    launcher (or the i3 escape-hatch bind) restarts it, rather than spinning
    against a server that is gone.
    """
    import select                                        # noqa: PLC0415
    from Xlib import X, display as xdisplay              # noqa: PLC0415
    from Xlib.error import ConnectionClosedError         # noqa: PLC0415

    disp_name = display_name or os.environ.get("DISPLAY", ":0")
    inst = SingleInstance(lock_path(disp_name))
    d = xdisplay.Display(disp_name)
    pub = L.StatePublisher(L.socket_path(disp_name))
    dae = Daemon(table, d, pub, display=disp_name)
    dae._pending = []
    for p in dae.grabs.problems:
        print(f"hotkeyd: {p}", file=sys.stderr)

    reload_wanted = {"flag": False}
    stop = {"flag": False}
    signal.signal(signal.SIGHUP,
                  lambda *_: reload_wanted.__setitem__("flag", True))
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__("flag", True))
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__("flag", True))

    def peek():
        if dae._pending:
            return dae._pending.pop(0)
        return d.next_event() if d.pending_events() else None

    print(f"hotkeyd: {len(dae.grabs.chords)} chords grabbed on {disp_name} "
          f"($mod={dae.mod})",
          file=sys.stderr, flush=True)
    code = 0
    try:
        while not stop["flag"]:
            pub.poll()
            if reload_wanted["flag"]:
                reload_wanted["flag"] = False
                try:
                    fresh = load_table(getattr(table, "__file__", None))
                    dae.table = fresh
                    dae.engine = L.LayerEngine(fresh.BINDS, fresh.LAYERS,
                                               publisher=pub, mod=dae.mod)
                    dae.resync_grabs()
                    print("hotkeyd: reloaded", file=sys.stderr, flush=True)
                except TableInvalid as e:
                    print(f"hotkeyd: reload REFUSED, keeping the running table"
                          f"\n  {e}", file=sys.stderr, flush=True)
                except Exception as e:                   # noqa: BLE001
                    print(f"hotkeyd: reload failed, keeping the old table: {e}",
                          file=sys.stderr, flush=True)
            try:
                if dae._pending:
                    ev = dae._pending.pop(0)
                elif not d.pending_events():
                    select.select([d.fileno()], [], [], 0.25)
                    continue
                else:
                    ev = d.next_event()
                dae.pump(ev, peek=peek)
            except ConnectionClosedError:
                print("hotkeyd: X connection lost, exiting", file=sys.stderr)
                code = 1
                break
    finally:
        dae.close()
        inst.release()
    return code


def _keysym_name(d, ev):
    from Xlib import XK                                  # noqa: PLC0415
    ks = d.keycode_to_keysym(ev.detail, 0)
    return XK.keysym_to_string(ks) if ks else None


def _dispatch(i3: I3Client, action):
    if isinstance(action, default_binds.Run):
        subprocess.Popen(action.cmd, shell=True,
                         start_new_session=True)
        return
    if isinstance(action, str):
        if not i3.command(action):
            print(f"hotkeyd: i3 dispatch failed: {action}", file=sys.stderr,
                  flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(prog="hotkeyd")
    ap.add_argument("--binds", help="path to a bind table module "
                                    "(default: the shipped binds.py)")
    ap.add_argument("--check", action="store_true",
                    help="validate the bind table and exit; no grabs, no X")
    ap.add_argument("--display", help="X display (default: $DISPLAY)")
    args = ap.parse_args()

    try:
        # --check does its own reporting, so it loads WITHOUT validating and
        # then prints the full problem list; every other path wants the refusal.
        table = load_table(args.binds, validate=not args.check)
    except TableInvalid as e:
        print(f"hotkeyd: {e}", file=sys.stderr)
        return 1
    if args.check:
        return check(table)
    try:
        return run_daemon(table, args.display)
    except AlreadyRunning as e:
        print(f"hotkeyd: {e}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
