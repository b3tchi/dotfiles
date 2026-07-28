#!/usr/bin/env python3
"""hotkeyd — global keybinding daemon for X11 sessions (sp020, ft011).

Owns its own grabs (per-chord `XIGrabKeycode` against `XIAllMasterDevices` on
the root window, never `XIGrabDevice` / `XGrabKeyboard` — an exclusive grab held
by a hung daemon locks the whole session, per-key grabs degrade to "that chord
stopped working") and dispatches over ONE persistent i3 IPC connection, so no
`i3-msg` process is spawned per keystroke.

Grabs go through XI2 rather than core `XGrabKey` because a core `KeyPress`
carries no device identity, so the daemon could not tell one keyboard from
another — or a real keystroke from an injected one — and injection shares the
display with real input. `XIDeviceEvent.sourceid` is the only channel that can.
`python-xlib` 0.33 parses these events itself (`Xlib.ext.xinput` registers
`DeviceEventData`); the hand-unpacking in `quickshell/qs-keymon.py` is needed
only for XI2 *raw* events, which have no registered parser, and grabbed-keycode
delivery is not raw.

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
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import time
from dataclasses import dataclass
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

# XInput2 wire constants, duplicated as plain ints for the same reason the
# modifier masks are: `--check` and the pure-logic tests import this module on
# boxes with no X library at all.
XI_ALL_MASTER_DEVICES = 1               # XIAllMasterDevices
XI_KEY_PRESS, XI_KEY_RELEASE = 2, 3     # XI_KeyPress / XI_KeyRelease evtypes
XI_DEVICE_CHANGED, XI_HIERARCHY_CHANGED = 1, 11
XI_KEY_REPEAT = 1 << 16                 # XIKeyRepeat, set on an auto-repeat press
GENERIC_EVENT = 35                      # Xlib.ext.ge.GenericEventCode


class GrabRefused(Exception):
    """X refused a grab — almost always BadAccess because another client already
    owns that chord.

    XI2 reports this in the `XIPassiveGrabDevice` REPLY (a per-modifier status
    list) rather than as an asynchronous X error, so the refusal is synchronous
    here where the core path had to round-trip a `sync()`.

    Measured caveat, and it is a real one: the X server keeps core and XI2
    passive grabs in SEPARATE conflict domains (`GrabMatchesSecond` compares
    grabtype), so this is raised for a colliding XI2 grabber — a second hotkeyd
    — and NOT for i3's core grab on the same chord. See the header of
    `live_check.py` section 2, which measures both directions.
    """


class XI2Unavailable(RuntimeError):
    """This display cannot do XI2, so the daemon cannot resolve a source device.

    Fail fast with this named error and NEVER fall back to core `XGrabKey`: a
    silent fallback would leave the daemon running with no device attribution at
    all — the one property the port exists for — and nothing would say so.
    """


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


def mods_from_mask(mask: int) -> frozenset[str]:
    """Canonical modifier names in an X modifier mask, lock bits dropped.

    NumLock and CapsLock ride in every mask but are not layer modifiers, so
    leaving them in would make `Ctrl+h` with NumLock on a different chord than
    `Ctrl+h` without it.
    """
    mask &= ~LOCK_BITS
    return frozenset(name for bit, name in NAME_BY_MASK.items() if mask & bit)


def to_event(kind: str, keysym: str, state: int,
             device: str | None = None,
             device_id: int | None = None,
             keycode: int | None = None) -> L.Event:
    """Translate an X key event into the engine's X-agnostic Event.

    `state` is carried through UNSTRIPPED as `raw_state` alongside the cleaned
    `mods`, and the keycode alongside the keysym, purely so the engine's
    transition log can say what X delivered rather than what the matcher made
    of it (dotfiles-hwds.27). Nothing matches on either.
    """
    return L.Event(kind, keysym, mods_from_mask(state), device=device,
                   device_id=device_id, keycode=keycode, raw_state=state)


@dataclass(frozen=True)
class KeyEvent:
    """One XI2 key event, reduced to what the daemon acts on.

    Exists so the grab mechanism appears in exactly one place: everything below
    reads this record, not an `XIDeviceEvent` layout.
    """
    kind: str                       # "press" | "release"
    detail: int                     # keycode
    state: int                      # effective modifier mask, as core `state`
    time: int
    sourceid: int | None = None     # the SLAVE that produced it
    deviceid: int | None = None     # the MASTER it was routed through
    repeat: bool = False


def _mod_state(mods) -> int:
    """`effective_mods` off an XI2 ModifierInfo.

    Effective, not base: it folds in the latched and LOCKED bits, which is what
    makes this the same number core `KeyPress.state` carried — measured equal on
    a live server for a Ctrl-held press. `to_event` then strips the lock bits.
    """
    if mods is None:
        return 0
    try:
        return int(mods["effective_mods"])
    except (TypeError, KeyError, IndexError):
        return int(getattr(mods, "effective_mods", 0) or 0)


def key_event(ev) -> KeyEvent | None:
    """Normalise an XI2 device event; None for anything that is not a key event.

    Core `KeyPress`/`KeyRelease` are deliberately NOT accepted. Every grab this
    daemon holds is an XI2 grab, so a core key event cannot be one of ours — and
    accepting one would mean dispatching an event with no resolvable source
    device, which is exactly the blind spot the XI2 port removes.
    """
    if getattr(ev, "type", None) != GENERIC_EVENT:
        return None
    evtype = getattr(ev, "evtype", None)
    if evtype not in (XI_KEY_PRESS, XI_KEY_RELEASE):
        return None
    data = getattr(ev, "data", None)
    if data is None:
        return None
    return KeyEvent(
        kind="press" if evtype == XI_KEY_PRESS else "release",
        detail=int(data.detail),
        state=_mod_state(getattr(data, "mods", None)),
        time=int(getattr(data, "time", 0) or 0),
        sourceid=getattr(data, "sourceid", None),
        deviceid=getattr(data, "deviceid", None),
        repeat=bool(int(getattr(data, "flags", 0) or 0) & XI_KEY_REPEAT),
    )


class DeviceRegistry:
    """XI2 device id -> device name, cached for the process lifetime.

    Resolution is per SOURCE id, never the master in the event header: XI2 puts
    the master keyboard in `deviceid` and the physical slave that actually
    produced the event in `sourceid`, so reading the header would make every
    keyboard on a display report as `Virtual core keyboard` and the whole
    predicate would be a no-op. (`qs-keymon.py` reads the raw header because it
    listens for RAW events, which have no grab and no meaningful sourceid split.)

    The cache is dropped wholesale on an XI2 hierarchy or device change — a
    bluetooth keyboard powering off, a device plugged in after startup — because
    ids are reused and a stale name would attribute one keyboard's keys to
    another. A lookup that FAILS is not cached: the id may exist after the next
    hierarchy change, and caching the miss would keep it nameless forever.
    """

    def __init__(self, display):
        self.d = display
        self._names: dict[int, str] = {}

    def invalidate(self):
        self._names.clear()

    def name(self, deviceid) -> str | None:
        if deviceid is None:
            return None
        cached = self._names.get(deviceid)
        if cached is not None:
            return cached
        found = None
        try:
            reply = self.d.xinput_query_device(deviceid)
            for dev in getattr(reply, "devices", ()) or ():
                if dev.deviceid == deviceid:
                    found = dev.name
                    break
        except Exception:                           # noqa: BLE001
            # A device that vanished between the press and this lookup answers
            # BadDevice. An unattributable key is still a key: it dispatches
            # with device=None (and so cannot satisfy a `device=` predicate).
            found = None
        if isinstance(found, (bytes, bytearray)):
            found = found.decode(errors="replace")
        if found is not None:
            self._names[deviceid] = found
        return found


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
SUBSCRIBE = 2
GET_BINDING_STATE = 12

# i3 tags an unsolicited event by setting the high bit of the message type. On a
# subscribed connection an event can land between a request and its reply, so
# every read has to test this bit — a client that takes the next message as its
# reply is one message behind for the rest of the session (i3 IPC docs).
EVENT_MASK = 0x80000000
EVENT_MODE = 2

# adr0014: a lost i3 is not retried in a tight loop. poll_events() runs on every
# iteration of the key loop, so the reconnect attempt is on a timer.
I3_RECONNECT_BACKOFF_S = 5.0


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

    The same connection carries events. i3 allows commands and a subscription on
    one socket (it only warns that replies and events interleave, which
    `_read_message` handles), so mode arbitration costs no second socket and no
    `i3-msg -t subscribe` process — sp020's "one persistent i3 IPC connection".
    """

    def __init__(self, path_getter=i3_socket_path, on_event=None):
        self._path_getter = path_getter
        self._sock: socket.socket | None = None
        self.on_event = on_event
        self._subs: list[str] = []
        self._retry_at = 0.0
        # Bumped by every successful connect. poll_events() compares it against
        # what it last reported, so a reconnect made by ANY path (a dispatch,
        # the poll itself) is surfaced once — the daemon uses that to re-read
        # i3's binding state, which a restarted i3 has reset.
        self._gen = 0
        self._seen_gen = 0

    def _connect(self):
        path = self._path_getter()
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(path)
        self._sock = s
        self._gen += 1
        if self._subs:
            self._send(SUBSCRIBE, json.dumps(self._subs))
            self._read_message()

    def _send(self, mtype: int, payload: str = ""):
        data = payload.encode()
        self._sock.sendall(HDR.pack(MAGIC, len(data), mtype) + data)

    def command(self, cmd: str) -> bool:
        """Returns True on success. A dispatch failure is REPORTED, never fatal:
        losing i3 must not take the keyboard layer down with it."""
        for attempt in (1, 2):
            try:
                if self._sock is None:
                    self._connect()
                self._send(RUN_COMMAND, cmd)
                self._recv_reply()
                return True
            except (OSError, ConnectionError, subprocess.CalledProcessError):
                self.close()
                if attempt == 2:
                    return False
        return False

    # -- events -----------------------------------------------------------
    def subscribe(self, events) -> bool:
        """Subscribe to i3 events on THIS connection. Idempotent; the wanted set
        is remembered so every later reconnect re-subscribes."""
        for e in events:
            if e not in self._subs:
                self._subs.append(e)
        try:
            if self._sock is None:
                self._connect()             # subscribes as part of connecting
            else:
                self._send(SUBSCRIBE, json.dumps(self._subs))
                self._read_message()
            # This connect is the caller's own, not news to report back to it.
            self._seen_gen = self._gen
            return True
        except (OSError, ConnectionError, subprocess.CalledProcessError):
            self.close()
            return False

    def binding_state(self) -> str:
        """The mode i3 is in RIGHT NOW. Needed because no `mode` event is ever
        sent for a mode i3 entered before we subscribed — a daemon started (or
        restarted) mid-mode would otherwise believe it owns the keyboard."""
        try:
            if self._sock is None:
                self._connect()
            self._send(GET_BINDING_STATE, "")
            _, payload = self._recv_reply()
        except (OSError, ConnectionError, subprocess.CalledProcessError):
            self.close()
            return L.DEFAULT_I3_MODE
        try:
            data = json.loads(payload or b"{}")
        except ValueError:
            return L.DEFAULT_I3_MODE
        if isinstance(data, dict) and data.get("name"):
            return str(data["name"])
        return L.DEFAULT_I3_MODE

    def fileno(self) -> int | None:
        return self._sock.fileno() if self._sock is not None else None

    def poll_events(self) -> bool:
        """Drain whatever i3 has queued, without blocking. Returns True if the
        connection was (re-)established since the last poll, which is the
        daemon's cue to re-read the binding state."""
        import select                                       # noqa: PLC0415

        if self._sock is None:
            if not self._subs:
                return False                # nothing to keep alive
            now = time.monotonic()
            if now < self._retry_at:
                return False
            self._retry_at = now + I3_RECONNECT_BACKOFF_S
            try:
                self._connect()
            except (OSError, ConnectionError,
                    subprocess.CalledProcessError):
                self.close()
                return False
        fresh = self._gen != self._seen_gen
        self._seen_gen = self._gen
        while self._sock is not None:
            try:
                r, _, _ = select.select([self._sock], [], [], 0)
                if not r:
                    break
                self._read_message()
            except (OSError, ConnectionError):
                self.close()
                break
        return fresh

    def _read_message(self) -> tuple[int, bytes] | None:
        """Read one message. Events are dispatched and reported as None so the
        caller can keep waiting for its actual reply."""
        hdr = self._recv_exact(HDR.size)
        _, length, mtype = HDR.unpack(hdr)
        payload = self._recv_exact(length) if length else b""
        if mtype & EVENT_MASK:
            self._dispatch_event(mtype & ~EVENT_MASK, payload)
            return None
        return mtype, payload

    def _dispatch_event(self, kind: int, payload: bytes):
        if self.on_event is None:
            return
        try:
            data = json.loads(payload or b"{}")
        except ValueError:
            data = {}
        self.on_event(kind, data)

    def _recv_reply(self) -> tuple[int, bytes]:
        while True:
            msg = self._read_message()
            if msg is not None:
                return msg

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


# The modifiers a hand is plausibly still holding when it reaches for an exit
# key. Each one must be able to DELIVER that key to the daemon — see
# layer_chords for which of the two routes each gets.
EXIT_MODIFIERS = ("Shift", "Ctrl", "Mod1")


def layer_chords(table, name: str) -> list[str]:
    """The extra chords a layer needs while it is ACTIVE: its bare keys, its exit
    keys (bare and modifier-held), its modifier-prefixed sublayer chords, and
    the modifier keys themselves (so held-modifier state is observable at all).

    A layer must stay leavable one-handed, with whatever modifier is still down
    — the engine matches exit keys on the keysym alone precisely so that works.
    But the engine only sees an event that X delivered, and X delivers by MASK:
    a bare `q` grab has mask 0, while `Ctrl+q` arrives with CtrlMask and matches
    no grab at all. There are two ways an exit key can reach us with a modifier
    held, and each modifier gets exactly one of them:

    - the modifier is DECLARED as a sublayer: its keysyms are grabbed below, and
      holding one starts an ACTIVE grab that routes every following key here
      regardless of mask. Nothing more is needed — and adding a passive variant
      anyway would be actively harmful, because `Mod1+q` is i3's `$mod+q` on the
      xrdp display (`split toggle`, i3/config.common) and every layer entry
      would then log a BadAccess.
    - the modifier is NOT declared: no keysym grab, no active grab, so the mask
      variant must be grabbed explicitly or the layer is a trap. That is the
      Shift case dotfiles-hwds.17 fixed, and dotfiles-hwds.18 is the same hole
      for Ctrl/Alt in any layer that declares no `mods` — `nav` happens to
      declare both, so the shipped table never exposed it.

    Shift is always in the explicit set: grabbing `Shift_L`/`Shift_R` to get an
    active grab is forbidden — it would swallow every capital letter, ruinous on
    :10 where xrdp synthesises Shift around every character it sends.

    Deliberately NOT generalised to the layer's other binds: grabbing `Shift+h`
    would take a chord the daemon has no meaning for from every application for
    as long as the layer is up.
    """
    layer = table.LAYERS[name]
    out = [b.chord for b in layer.binds] + list(layer.exit_keys)
    routed = set()
    for mod in layer.mods.values():
        canon = default_binds.MODIFIER_ALIASES.get(
            str(mod.modifier).lower(), mod.modifier)
        out += [f"{canon}+{b.chord}" for b in mod.binds]
        out += MOD_KEYSYMS_BY_NAME.get(canon, [])
        if canon != "Shift":            # see the docstring: never routed
            routed.add(canon)
    for canon in EXIT_MODIFIERS:
        if canon in routed:
            continue
        out += [f"{canon}+{k}" for k in layer.exit_keys]
    return list(dict.fromkeys(out))


def chords_for(table, layer: str | None = None) -> list[str]:
    """The grab set for the CURRENT state. Re-synced on every layer transition."""
    out = global_chords(table)
    if layer and layer != L.DEFAULT_LAYER and layer in table.LAYERS:
        out = out + layer_chords(table, layer)
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

def require_xi2(d):
    """Assert this display can do XI2, or raise XI2Unavailable naming why.

    Called before the first grab, so an XI2-less display costs a named non-zero
    exit at startup rather than a stack trace at the first keypress — and never
    a silent degradation to core grabs (see XI2Unavailable).
    """
    try:
        info = d.query_extension("XInputExtension")
    except Exception as e:                              # noqa: BLE001
        raise XI2Unavailable(
            f"cannot query the XInputExtension on this display: {e}") from e
    if not info:
        raise XI2Unavailable(
            "this display has no XInputExtension — hotkeyd grabs with "
            "XIGrabKeycode and will not fall back to core grabs, which carry "
            "no source device")
    try:
        ver = d.xinput_query_version()
    except Exception as e:                              # noqa: BLE001
        raise XI2Unavailable(
            f"XIQueryVersion failed on this display: {e}") from e
    major = int(getattr(ver, "major_version", 0) or 0)
    minor = int(getattr(ver, "minor_version", 0) or 0)
    if major < 2:
        raise XI2Unavailable(
            f"this display speaks XInput {major}.{minor}; hotkeyd needs XI2 "
            "(2.0 or later) for XIGrabKeycode and sourceid")
    return ver


class XAdapter:
    """Adapts python-xlib's XI2 to the GrabManager's four-method interface, and
    turns a refused passive grab into the synchronous GrabRefused the manager
    degrades on. Defined at module scope (not inside the run loop) so the live
    checks can exercise the REAL adapter instead of a copy of it.

    Every grab is `XIGrabKeycode` against `XIAllMasterDevices` — per chord, per
    lock-bit variant, on the root window. Never `XIGrabDevice`: an exclusive
    grab held by a hung daemon locks the whole session, while a per-chord
    passive grab degrades to "that chord stopped working".
    """

    def __init__(self, d, root):
        self.d, self.root = d, root
        self.xi_version = require_xi2(d)

    def keysym_to_keycode(self, name):
        from Xlib import XK                              # noqa: PLC0415
        ks = XK.string_to_keysym(name)
        return self.d.keysym_to_keycode(ks) if ks else 0

    def grab_key(self, code, mask):
        from Xlib import X                               # noqa: PLC0415
        from Xlib.error import XError                    # noqa: PLC0415
        from Xlib.ext import xinput                      # noqa: PLC0415
        try:
            reply = self.root.xinput_grab_keycode(
                XI_ALL_MASTER_DEVICES, X.CurrentTime, code,
                xinput.GrabModeAsync, xinput.GrabModeAsync, True,
                xinput.KeyPressMask | xinput.KeyReleaseMask, [mask])
        except XError as e:
            raise GrabRefused(type(e).__name__) from e
        # A non-empty `modifiers` list is the reply's per-modifier failure
        # report. The only status the server returns for a passive-grab
        # collision on a viewable root window is BadAccess (xserver
        # `AddPassiveGrabToList`); the other statuses arrive as real X errors,
        # caught above. python-xlib decodes each GrabModifierInfo as a bare
        # Card32 and so loses the status byte, which is why this names the
        # status rather than reading it.
        if getattr(reply, "modifiers", None):
            raise GrabRefused("BadAccess")

    def ungrab_key(self, code, mask):
        self.root.xinput_ungrab_keycode(XI_ALL_MASTER_DEVICES, code, [mask])

    def sync(self):
        self.d.sync()

    def watch_devices(self):
        """Ask for XI2 hierarchy / device-changed events on the root window.

        Not part of the GrabManager interface — the daemon calls it so a device
        appearing or disappearing invalidates the name cache. Key events are
        deliberately NOT selected here: those arrive through the grabs.
        """
        from Xlib.ext import xinput                      # noqa: PLC0415
        self.root.xinput_select_events(
            [(xinput.AllDevices,
              xinput.HierarchyChangedMask | xinput.DeviceChangedMask)])
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
        self.adapter = XAdapter(d, d.screen().root)
        self.grabs = GrabManager(self.adapter, mod=self.mod)
        self.devices = DeviceRegistry(d)
        self.adapter.watch_devices()
        self.engine = L.LayerEngine(table.BINDS, table.LAYERS,
                                    publisher=publisher, mod=self.mod)
        self.wire_i3_mode()
        self.grabs.sync_binds(chords_for(table))

    @property
    def ignore_devices(self) -> frozenset:
        """Source device names whose events are dropped outright.

        Read off the CURRENT table rather than snapshotted at construction, so a
        SIGHUP reload changes it the way it changes every other table value.
        """
        return frozenset(getattr(self.table, "IGNORE_DEVICES", ()) or ())

    # -- i3-mode arbitration ----------------------------------------------
    def wire_i3_mode(self) -> bool:
        """Subscribe to i3's `mode` event on the connection we already hold and
        seed the engine with the mode i3 is in right now.

        Guarded by getattr because the live checks (and any embedder) inject a
        minimal i3 stub: event support is optional wiring, and a client without
        it simply never arbitrates rather than breaking the daemon.
        """
        subscribe = getattr(self.i3, "subscribe", None)
        if subscribe is None:
            return False
        self.i3.on_event = self._on_i3_event
        subscribe(["mode"])
        self.sync_i3_mode()
        return True

    def _on_i3_event(self, kind: int, data: dict):
        if kind == EVENT_MODE:
            self.engine.set_i3_mode(data.get("change"))

    def sync_i3_mode(self):
        state = getattr(self.i3, "binding_state", None)
        if state is None:
            return
        self.engine.set_i3_mode(state())

    def pump_i3(self):
        """One non-blocking pass over the i3 connection. Called from the key
        loop, so an i3 mode takes the keyboard back within one iteration."""
        poll = getattr(self.i3, "poll_events", None)
        if poll is None:
            return
        before = self.engine.state["layer"]
        if poll():
            # A reconnect means a restarted i3, whose mode has reset. Believing
            # the last mode we heard would refuse every layer entry from here on.
            self.sync_i3_mode()
        if self.engine.state["layer"] != before:
            self.resync_grabs()

    def i3_fileno(self) -> int | None:
        fileno = getattr(self.i3, "fileno", None)
        return fileno() if fileno is not None else None

    def resync_grabs(self):
        self.grabs.sync_binds(chords_for(self.table,
                                         self.engine.state["layer"]))

    # -- belief vs. the server (dotfiles-hwds.27) --------------------------
    def reconcile_mods(self) -> bool:
        """Check the engine's held-modifier belief against the X server.

        Called from the IDLE branch of the run loop only — never from `pump` —
        so it costs nothing on the key path and at most one round-trip per
        `select` timeout (~4/s). It short-circuits to zero round-trips whenever
        the engine believes nothing is held, which is the whole session apart
        from the seconds someone is standing in a sublayer.

        The published state is supposed to be reconcilable against reality, and
        the held-modifier half of it genuinely is: `query_pointer` reports what
        the server currently has down, sampled outside any event, so it is not
        the pre-event mask the engine deliberately distrusts. The LAYER half is
        not reconcilable — X has no notion of `nav` — and `reconcile_holds` does
        not touch it.

        A failed query is swallowed. adr0014: the idle path must not turn a
        transient X answer into a dead daemon that was otherwise serving the
        keyboard fine.
        """
        if not self.engine.held:
            return False
        try:
            mask = int(self.d.screen().root.query_pointer().mask)
        except Exception:                               # noqa: BLE001
            return False
        return self.engine.reconcile_holds(mods_from_mask(mask))

    def pump(self, ev) -> list:
        """Handle one X event. Returns the actions dispatched."""
        from Xlib import X                               # noqa: PLC0415

        if ev.type == X.MappingNotify:
            self.d.refresh_keyboard_mapping(ev)
            self.grabs.on_mapping_notify()
            return []
        if (ev.type == GENERIC_EVENT
                and getattr(ev, "evtype", None) in (XI_HIERARCHY_CHANGED,
                                                    XI_DEVICE_CHANGED)):
            # A device arrived or left. Ids are reused, so every cached name is
            # now suspect — this is the bluetooth-keyboard-powering-off case and
            # the plugged-in-after-startup case, one handler for both.
            self.devices.invalidate()
            return []

        k = key_event(ev)
        if k is None:
            return []

        # Auto-repeat. Core delivery synthesised a RELEASE+PRESS pair per repeat
        # and the daemon had to coalesce them by timestamp; XI2 sends neither the
        # synthetic release nor an unmarked press — it sets XIKeyRepeat on the
        # press itself. Measured on Xvfb: a 1.2 s hold delivers 15 XI2 presses,
        # 14 of them flagged, and exactly 1 release. Dropping them here rather
        # than relying on the engine's own repeat suppression keeps the guard
        # independent of that suppression's wedge timeout, which a repeat
        # arriving after a stall would otherwise slip past.
        if k.repeat:
            return []

        name = self.grabs.keysym_for(k.detail) or _keysym_name(self.d, k.detail)
        if name is None:
            return []

        # Source device, resolved per event. `sourceid` is the physical slave,
        # never the master in the event header — see DeviceRegistry.
        device = self.devices.name(k.sourceid)
        if device is not None and device in self.ignore_devices:
            return []

        before = self.engine.state["layer"]
        actions = self.engine.handle(
            to_event(k.kind, name, k.state, device=device,
                     device_id=k.sourceid, keycode=k.detail))
        for action in actions:
            _dispatch(self.i3, action)
        if self.engine.state["layer"] != before:
            # A layer's bare keys exist only while that layer is active, so they
            # never shadow an application's keyboard outside it. sync_binds moves
            # only the difference, so nothing is dropped mid-gesture.
            self.resync_grabs()
        return actions

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
    d = xdisplay.Display(disp_name)
    # Probed BEFORE the lock and the socket, so a display that cannot do XI2
    # costs a named exit and leaves nothing behind to reap.
    require_xi2(d)
    inst = SingleInstance(lock_path(disp_name))
    pub = L.StatePublisher(L.socket_path(disp_name))
    dae = Daemon(table, d, pub, display=disp_name)
    for p in dae.grabs.problems:
        print(f"hotkeyd: {p}", file=sys.stderr)

    reload_wanted = {"flag": False}
    stop = {"flag": False}
    signal.signal(signal.SIGHUP,
                  lambda *_: reload_wanted.__setitem__("flag", True))
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__("flag", True))
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__("flag", True))

    print(f"hotkeyd: {len(dae.grabs.chords)} chords grabbed on {disp_name} "
          f"via XI2 ($mod={dae.mod})",
          file=sys.stderr, flush=True)
    code = 0
    try:
        while not stop["flag"]:
            pub.poll()
            dae.pump_i3()
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
                if not d.pending_events():
                    # Idle: nothing is arriving, which is exactly when a hold
                    # the session stopped reporting would otherwise latch —
                    # the guard window only ever runs on an event.
                    dae.reconcile_mods()
                    # i3's socket is in the wait set too, so a mode change wakes
                    # the loop immediately instead of up to 250 ms later — the
                    # window in which both engines would think they own the keys.
                    waits = [d.fileno()]
                    i3fd = dae.i3_fileno()
                    if i3fd is not None:
                        waits.append(i3fd)
                    select.select(waits, [], [], 0.25)
                    continue
                ev = d.next_event()
                dae.pump(ev)
            except ConnectionClosedError:
                print("hotkeyd: X connection lost, exiting", file=sys.stderr)
                code = 1
                break
    finally:
        dae.close()
        inst.release()
    return code


def _keysym_name(d, keycode: int):
    from Xlib import XK                                  # noqa: PLC0415
    ks = d.keycode_to_keysym(keycode, 0)
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
    except XI2Unavailable as e:
        # Named, non-zero, no traceback: an operator reading the launcher log
        # has to be able to tell "this display cannot do XI2" from "the daemon
        # crashed". 5 is distinct from 3 (another daemon) and 4 (panic latch).
        print(f"hotkeyd: XI2 unavailable — {e}", file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main())
