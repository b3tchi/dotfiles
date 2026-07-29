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
`DeviceEventData`); the hand-unpacking `quickshell/qs-keymon.py` used to do was
needed only for XI2 *raw* events, which have no registered parser, and
grabbed-keycode delivery is not raw. (That helper is deleted — dotfiles-hwds.40
moved the alt-tab switcher it drove into this daemon.)

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

#: How often the run loop records that it is still turning. Well under
#: HEARTBEAT_STALE_S so an ordinary loop turn never looks late.
HEARTBEAT_PERIOD_S = 1.0

#: How old a heartbeat has to be before the daemon counts as NOT SERVING.
#: Generous on purpose. The cost of calling a healthy daemon wedged is that
#: `start` reaps it and respawns — a visible keyboard hiccup — so the window has
#: to clear the worst legitimate stall on the loop, which is a blocking i3
#: command reply, not the 1 s beat period.
HEARTBEAT_STALE_S = 5.0

#: `--health` exit codes. 0 keeps the shell idiom (`if hotkeyd.py --health`).
#:
#: 6 and 7 are deliberately DIFFERENT, and the difference is a safety boundary,
#: not a nicety. 6 is the daemon's own evidence about itself — its run loop
#: stopped — and it is the only verdict `start` is allowed to end a process on.
#: 7 says the daemon looks fine but this display did not answer US, which can
#: also mean the caller simply has no X authority (a `status` run from a tmux
#: pane or an ssh session with no XAUTHORITY). Reaping on 7 would let a caller's
#: own missing credential kill a daemon that is serving the session perfectly —
#: the same shape of mistake as reading a missing `xdpyinfo` as a dead server,
#: which is what produced this bug report in the first place.
HEALTH_OK = 0
HEALTH_NOT_SERVING = 6
HEALTH_DISPLAY_UNREACHABLE = 7
#: Someone else holds an EXCLUSIVE keyboard grab on this display, so every
#: passive grab — the daemon's and i3's alike — is bypassed and nothing fires.
#: Its own code because the cure is on the other client, not here: restarting
#: the daemon cannot fix it, and 6 ("its loop stopped") would send whoever
#: reads it to `start` (dotfiles-hwds.30).
HEALTH_KEYBOARD_GRABBED = 8

#: How many times the grab probe asks before condemning, and how long it waits
#: between asks. Sized for the false positive it must not produce: the daemon's
#: own passive grab is promoted to an implicit ACTIVE grab while a grabbed key
#: is HELD (dotfiles-hwds.31), which looks identical to a foreign grab from
#: outside. That state ends on key release, so a keystroke cannot survive three
#: asks 300 ms apart, while a locker's grab survives all of them.
GRAB_PROBE_ATTEMPTS = 3
GRAB_PROBE_DELAY_S = 0.3

#: The daemon is up and serving SOME of its table — chords the table asks for
#: are not grabbed (dotfiles-hwds.42). Its own code because the cure differs
#: from every other failure here: the daemon is fine, the grab set is not, and
#: `hotkeyd.sh restart` is the fix rather than an investigation.
HEALTH_DEGRADED = 9

#: How long the display probe waits for the server to answer. A HUNG X server —
#: as opposed to a dead one — never closes the connection, so an unguarded
#: `Display()` blocks in the handshake forever. `hotkeyd.sh start` runs from
#: i3's `exec_always`, so an unbounded probe there does not just delay a
#: diagnostic, it stalls the session's startup.
PROBE_TIMEOUT_S = 3.0


def _runtime_dir() -> Path:
    return Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")


def lock_path(display: str | None = None) -> Path:
    """Per-display lock. Screen suffix stripped so `:10.0` and `:10` are one
    session (dotfiles-3x85 normalization; RDP sessions present `:10.0`)."""
    display = display or os.environ.get("DISPLAY", ":0")
    tag = display.lstrip(":").split(".")[0]
    return _runtime_dir() / f"hotkeyd-{tag}.lock"


def grab_report_path(display: str | None = None) -> Path:
    """Where the daemon publishes its grab report (dotfiles-hwds.42).

    A sidecar rather than the lock file: the lock's MTIME is the heartbeat, so
    writing the report there would beat the heart on every re-grab and make a
    wedged daemon that still receives MappingNotify look alive.
    """
    display = display or os.environ.get("DISPLAY", ":0")
    tag = display.lstrip(":").split(".")[0]
    return _runtime_dir() / f"hotkeyd-{tag}.grabs"


def write_grab_report(display: str | None, report: dict) -> None:
    """Publish the report, best effort.

    Never raises: a runtime dir that went read-only is not a reason to stop
    serving the keyboard (adr0014), and a missing report is read as "this
    daemon does not publish one" rather than as damage — see `health`.
    """
    try:
        p = grab_report_path(display)
        tmp = p.with_suffix(".grabs.tmp")
        tmp.write_text(json.dumps(report))
        tmp.replace(p)                      # atomic: no half-written report
    except OSError:
        pass


def read_grab_report(display: str | None = None) -> dict | None:
    """The daemon's last published report, or None when there is not one."""
    try:
        return json.loads(grab_report_path(display).read_text())
    except (OSError, ValueError):
        return None


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
    predicate would be a no-op. (`qs-keymon.py`, now deleted, read the raw header
    instead because it listened for RAW events, which have no grab and no
    meaningful sourceid split.)

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
    killed daemon does not lock its display out of a restart.

    The lock file doubles as the daemon's HEARTBEAT (dotfiles-hwds.28). The
    flock answers "is a process alive", which is the same thing `pgrep` answers
    and is not the question anyone actually has during an outage: the kernel
    holds the lock just as firmly for a daemon frozen mid-loop as for one
    serving the keyboard. The file's mtime answers the question that matters —
    when did the run loop last turn — and it rides on a file that already
    exists, is already per-display, and is already the thing `start` reasons
    about, rather than inventing a second runtime artifact to leak.
    """

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
        self._beat_at = 0.0
        self.beat()

    def _utime(self):
        os.utime(self.path, None)

    def beat(self, now: float | None = None):
        """Record that the run loop is still turning.

        Called from the TOP of the loop, so it covers the idle path and the
        event path with one call site — a heartbeat that only ran while idle
        would go stale during a burst of keystrokes, i.e. it would report
        "wedged" exactly when the daemon was busiest.

        Rate-limited on the monotonic clock: the loop turns ~4x a second idle
        and once per event otherwise, and an unconditional `utime` here would
        put a syscall on the key path to buy nothing.
        """
        now = time.monotonic() if now is None else now
        if now - self._beat_at < HEARTBEAT_PERIOD_S:
            return
        self._beat_at = now
        try:
            self._utime()
        except OSError:
            # adr0014 again: a runtime dir that went read-only under us is not
            # a reason to stop serving the keyboard. The beat going stale is
            # itself the report.
            pass

    def release(self):
        try:
            fcntl.flock(self._fh, fcntl.LOCK_UN)
        except OSError:
            pass
        self._fh.close()


# --------------------------------------------------------------------------
# grabs
# --------------------------------------------------------------------------

def _grab_log(msg: str):
    """Where a grab problem goes. Same stream as the layer transitions, so the
    two sit in one ordered story in `~/.local/state/hotkeyd-<n>.log` — a chord
    that stopped being served is only diagnosable next to what the engine
    believed at the time."""
    print(f"hotkeyd: {msg}", file=sys.stderr, flush=True)


# Keysym groups python-xlib does NOT preload. `Xlib.XK` ships latin1 and
# miscellany only, so every other name it is asked about resolves to 0 — and a
# keysym of 0 is reported by GrabManager as "not on the current keymap", i.e. a
# chord that is silently never grabbed on a display where the key exists.
#
# MEASURED, not assumed: `XK.string_to_keysym("ISO_Left_Tab")` is 0 out of the
# box and 0xfe20 after `load_keysym_group("xkb")`. ISO_Left_Tab is what X
# delivers for Shift+Tab and is the switcher's cycle-backwards key
# (dotfiles-hwds.40), so without this the bind loads, validates, reports no
# problem in --check, and is dead on every real display. `xf86` is loaded for
# the same reason — binds._KEYSYMS already lists the media keys, and they would
# fail the same way the day something binds one.
_KEYSYM_GROUPS = ("xkb", "xf86")
_keysym_groups_loaded = False


def keysym_by_name(name: str) -> int:
    """Resolve a keysym NAME to its number, with the non-default groups loaded.

    Loaded lazily and once: `Xlib.XK` is imported inside functions throughout
    this module so `--check` works with no display, and `load_keysym_group`
    mutates XK's module-level table, so doing it at import would drag Xlib into
    every headless path for nothing.
    """
    global _keysym_groups_loaded
    from Xlib import XK                                  # noqa: PLC0415
    if not _keysym_groups_loaded:
        for group in _KEYSYM_GROUPS:
            try:
                XK.load_keysym_group(group)
            except Exception:                            # noqa: BLE001
                # A python-xlib without that group is not a reason to refuse to
                # start: every keysym it DOES know still resolves, and the ones
                # it does not are reported per chord as they always were.
                pass
        _keysym_groups_loaded = True
    return XK.string_to_keysym(name)


class GrabManager:
    """Owns the mapping chord -> (keycode, mask) and the grabs registered for it.

    `display` is anything with `keysym_to_keycode` / `grab_key` / `ungrab_key` /
    `sync` — the real X display in production, a recorder in tests.
    """

    def __init__(self, display, mod: str = None, log=None, on_report=None):
        self.d = display
        # Called with grab_report() whenever the grab set is (re)computed, so
        # `status` can answer SERVING rather than merely ALIVE
        # (dotfiles-hwds.42). None in tests that do not care.
        self.on_report = on_report
        self.mod = mod or default_binds.DEFAULT_MOD
        self.problems: list[str] = []
        self._active: dict[str, tuple[int, int]] = {}   # chord -> (code, mask)
        # What the TABLE asks for, as opposed to what is currently grabbed.
        # dotfiles-hwds.41: re-deriving the next grab set from `_active` made
        # the set monotonic — a chord lost to one transient keymap could never
        # return, because the thing that would have asked for it again was the
        # very entry that got deleted.
        self._wanted: list[str] = []
        self.log = log or _grab_log
        # Problems already reported, so a chord that stays unresolvable across a
        # burst of MappingNotify is announced once rather than per event.
        self._reported: set[str] = set()

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
        self._wanted = list(dict.fromkeys(chords))
        self._apply()
        self.d.sync()
        self._publish()

    def _apply(self) -> bool:
        """Re-resolve THE WANTED SET against the live keymap and move only the
        difference. Returns True if any grab actually changed.

        Resolution is redone for every wanted chord, including the ones with no
        current grab: that is what lets a chord return after the keymap that
        hid it settles (dotfiles-hwds.41). A chord that still cannot resolve is
        reported and stays wanted — never deleted from the set that will be
        asked for again.
        """
        self.problems = []
        resolved: dict[str, tuple[int, int]] = {}
        # TWO CHORDS CAN RESOLVE TO ONE GRAB, and asking X for the same passive
        # grab twice is a BadAccess against ourselves — reported as "already
        # grabbed by another client?", which would be a lie about our own
        # duplicate. `Tab` and `ISO_Left_Tab` are the shipped instance: they are
        # the same physical key at two shift levels, so bare forms of both are
        # (23, 0). First wanted chord wins; the loser is not a problem, it is
        # the same grab under another name.
        taken: dict[tuple[int, int], str] = {}
        for chord in self._wanted:
            r = self._resolve(chord)
            if r is None or r in taken:
                continue
            taken[r] = chord
            resolved[chord] = r

        changed = False
        for chord, (code, mask) in list(self._active.items()):
            if resolved.get(chord) != (code, mask):
                self._ungrab(code, mask)
                del self._active[chord]
                changed = True

        for chord, (code, mask) in resolved.items():
            if self._active.get(chord) != (code, mask):
                self._grab(chord, code, mask)
                changed = True
        self._report_problems()
        return changed

    def _report_problems(self):
        """Announce a problem the first time it appears.

        Printing only at startup (which is what the daemon did) meant every
        mid-session grab loss was discarded unread — the live :10 log showed
        "59 chords grabbed", zero BadAccess and no error while the directional
        group was already dead. Announcing on every MappingNotify instead would
        spam a burst, so the report is edge-triggered on the problem TEXT.
        """
        current = set(self.problems)
        for msg in sorted(current - self._reported):
            self.log(msg)
        self._reported = current

    def _publish(self):
        if self.on_report is not None:
            self.on_report(self.grab_report())

    @property
    def chords(self):
        return list(self._active)

    def grab_report(self) -> dict:
        """What the table ASKED for against what X actually granted.

        The daemon has always known this — `_wanted` beside `_active` — and
        never said it, which is dotfiles-hwds.42: during the hwds.41 outage the
        :10 daemon had lost the whole directional group while `status` printed
        "running (pid …, socket …)". Liveness was true, serving was not, and
        the tool could not tell them apart.

        `missing` is NAMED, not counted. A count says something is wrong and
        leaves whoever is mid-outage diffing the table by hand, which is the
        expensive half.

        Chords that resolve to the SAME grab are not missing: `Tab` and
        `ISO_Left_Tab` are one physical key at two shift levels, so the second
        never gets its own entry in `_active` and never should (see `_apply`).
        Those are excluded by comparing against what resolution produced rather
        than against the raw wanted list.
        """
        taken: dict[tuple[int, int], str] = {}
        missing: list[str] = []
        for chord in self._wanted:
            r = self._resolve(chord)
            if r is None:
                missing.append(chord)
                continue
            if r in taken:
                continue                    # same grab under another name
            taken[r] = chord
            if chord not in self._active:
                missing.append(chord)
        return {"wanted": len(taken) + len(missing),
                "active": len(self._active),
                "missing": missing}

    def keysym_for(self, keycode: int, state: int | None = None) -> str | None:
        """What keysym an incoming event's keycode is, per THIS daemon's grabs.

        `state` disambiguates two keysyms that share a keycode. `ISO_Left_Tab`
        IS the shifted `Tab` key — one keycode, two names, and X delivers the
        name for the level that was actually used. A code-only lookup answers
        with whichever chord happens to sit first in the grab table, so the
        switcher's cycle-BACKWARDS bind would resolve to `Tab` and cycle
        forwards instead: a wrong direction, silently, with nothing logged.

        The mask match is tried first and the code-only answer is the fallback,
        so every chord that does not share a keycode with another resolves
        exactly as it did before.
        """
        if state is not None:
            want = state & ~LOCK_BITS
            for chord, (code, mask) in self._active.items():
                if code == keycode and mask == want:
                    return default_binds.parse_chord(chord, self.mod)[1]
        for chord, (code, _) in self._active.items():
            if code == keycode:
                return default_binds.parse_chord(chord, self.mod)[1]
        return None

    def on_mapping_notify(self) -> bool:
        """Compare-then-regrab against THE WANTED SET. poc013 saw two spurious
        MappingNotify at every daemon startup, so regrabbing unconditionally
        would churn every grab for nothing; `_apply` moves only what changed.

        dotfiles-hwds.41: this used to walk `self._active` instead, which made
        the grab set monotonic — a chord whose keysym momentarily resolved to 0
        (routine on `:10`, where xrdp reprograms the keymap on every RDP
        reconnect) was deleted, and the next notify iterated a set that no
        longer mentioned it. Half the table could die with the daemon still
        reporting healthy. Driving from `_wanted` makes every re-grab a chance
        to recover rather than another chance to lose.
        """
        changed = self._apply()
        if changed:
            self.d.sync()
        # PUBLISH UNCONDITIONALLY, not only when `changed`. A re-grab that
        # changes nothing still confirms the current state, and the report is
        # what `status` reads — a stale one after a keymap settled would name
        # chords that have since come back (dotfiles-hwds.42).
        self._publish()
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

# Keys whose SHIFTED level is a DIFFERENT keysym on a standard keymap. X names
# an event after the level actually used, so when a layer binds both forms the
# base key's Shift variant must not also be grabbed: `$mod+Shift+Tab` and
# `$mod+Shift+ISO_Left_Tab` are one and the same (keycode, mask), and which of
# the two names the daemon then gives an incoming event would come down to the
# order they happen to sit in the grab table.
SHIFTED_KEYSYM = {"Tab": "ISO_Left_Tab"}


def layer_chords(table, name: str,
                 mod: str = default_binds.DEFAULT_MOD) -> list[str]:
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

    A HOLD LAYER (`Layer.hold`, dotfiles-hwds.40) is the one shape where the
    bare grabs above are not enough, and where the modifier-keysym route is not
    available at all. Its modifier is already DOWN when the layer is entered
    (`$mod+Tab` is what enters it), and a passive grab installed while its key
    is already held never activates — so grabbing `Super_L` here would deliver
    neither the press nor the release, and the active grab the sublayer case
    relies on never exists. Two consequences, both handled:

    - every one of the layer's keys is grabbed with the hold modifier in the
      mask as well as bare, because that is the mask they will actually arrive
      with. Bare stays too: it is what makes the exit-key floor work in the one
      state that needs a floor, when the layer is up with nothing held.
    - the hold modifier's own keysyms are NOT grabbed. There is nothing to
      catch, and the release is observed by asking the server instead
      (`LayerEngine.reconcile_hold_layer`).

    The Shift variants are added for the layer's BINDS and not its exit keys:
    `$mod+Shift+<key>` is how xrdp delivers a shifted character on `:10` (it
    synthesises Shift around every one), and `Shift+Tab` arrives as a different
    keysym entirely — but `$mod+Shift+q` is i3's `kill`, and grabbing an exit
    key's Shift variant would take it and log a BadAccess on every layer entry.
    """
    layer = table.LAYERS[name]
    keys = [b.chord for b in layer.binds]
    out = keys + list(layer.exit_keys)
    routed = set()
    for mod_ in layer.mods.values():
        canon = default_binds.canon_modifier(mod_.modifier, mod) \
            or mod_.modifier
        out += [f"{canon}+{b.chord}" for b in mod_.binds]
        out += MOD_KEYSYMS_BY_NAME.get(canon, [])
        if canon != "Shift":            # see the docstring: never routed
            routed.add(canon)
    hold = default_binds.canon_modifier(getattr(layer, "hold", None), mod)
    if hold is not None:
        out += [f"{hold}+{c}" for c in keys + list(layer.exit_keys)]
        out += [f"{hold}+Shift+{c}" for c in keys
                if SHIFTED_KEYSYM.get(c) not in keys]
        routed.add(hold)
    for canon in EXIT_MODIFIERS:
        if canon in routed:
            continue
        out += [f"{canon}+{k}" for k in layer.exit_keys]
    return list(dict.fromkeys(out))


def chords_for(table, layer: str | None = None,
               mod: str = default_binds.DEFAULT_MOD) -> list[str]:
    """The grab set for the CURRENT state. Re-synced on every layer transition.

    `mod` is what `$mod` resolves to on this display. The GrabManager resolves
    the token again when it parses each chord, so it matters here only for the
    modifier names a layer computes for itself — a `Mod` sublayer's and a hold
    layer's — which are looked up by canonical name, not parsed.
    """
    out = global_chords(table)
    if layer and layer != L.DEFAULT_LAYER and layer in table.LAYERS:
        out = out + layer_chords(table, layer, mod)
    return list(dict.fromkeys(out))


def all_chords(table, mod: str = default_binds.DEFAULT_MOD) -> list[str]:
    """Every chord any state could grab — used for reporting by --check, not as
    a runtime grab set (see chords_for)."""
    out = global_chords(table)
    for name in table.LAYERS:
        out += layer_chords(table, name, mod)
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
        ks = keysym_by_name(name)
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
        self.grabs = GrabManager(
            self.adapter, mod=self.mod,
            on_report=lambda rep: write_grab_report(self.display, rep))
        self.devices = DeviceRegistry(d)
        self.adapter.watch_devices()
        self.engine = L.LayerEngine(table.BINDS, table.LAYERS,
                                    publisher=publisher, mod=self.mod)
        self.wire_i3_mode()
        self.grabs.sync_binds(chords_for(table, mod=self.mod))

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
                                         self.engine.state["layer"],
                                         mod=self.mod))

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
        not touch it. A HOLD layer is the exception, and only because X does
        have an opinion there: see below.

        A HOLD LAYER (dotfiles-hwds.40) is the second reason to ask, and the
        only one where the answer can DISPATCH. Its modifier goes down before
        the layer is entered, so the engine never saw the press and
        `self.engine.held` is empty — the short-circuit above would skip the
        query in exactly the state that needs it most. While such a layer is up
        the query is the ONLY channel that can observe the modifier coming up:
        a passive grab installed on a key that is already held never activates,
        so its release is delivered to the focused window and never here.

        A failed query is swallowed. adr0014: the idle path must not turn a
        transient X answer into a dead daemon that was otherwise serving the
        keyboard fine.
        """
        hold = self.engine.hold_modifier
        if not self.engine.held and hold is None:
            return False
        try:
            mask = int(self.d.screen().root.query_pointer().mask)
        except Exception:                               # noqa: BLE001
            return False
        down = mods_from_mask(mask)
        changed = self.engine.reconcile_holds(down)
        before = self.engine.state["layer"]
        for action in self.engine.reconcile_hold_layer(down):
            _dispatch(self.i3, action)
        if self.engine.state["layer"] != before:
            self.resync_grabs()
            changed = True
        return changed

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

        name = (self.grabs.keysym_for(k.detail, k.state)
                or _keysym_name(self.d, k.detail))
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


# How long the idle branch may sleep. The default is the cost of noticing a
# phantom held modifier (dotfiles-hwds.27) and nothing is waiting on it.
IDLE_TIMEOUT_S = 0.25
# ...but while a HOLD LAYER is up, that sleep IS the commit latency: the
# modifier's release cannot be delivered as an event (its key was already down
# when the layer's grabs went in, so no passive grab ever activated), so the
# server poll is the only thing that will ever end the switcher. 20 ms is below
# the threshold at which a released alt-tab feels delayed, and it costs ~50
# query_pointer round-trips per second for the second or two a switcher is
# open — never while the daemon is merely running.
HOLD_TIMEOUT_S = 0.02


def idle_timeout(dae) -> float:
    return HOLD_TIMEOUT_S if dae.engine.hold_modifier else IDLE_TIMEOUT_S


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
    # Startup problems are already on the stream: GrabManager reports each one
    # the first time it appears, at whatever sync produced it (dotfiles-hwds.41).
    # Reprinting them here would double every line of the first sync while still
    # saying nothing about the mid-session losses that were the actual bug.

    reload_wanted = {"flag": False}
    stop = {"flag": False}
    signal.signal(signal.SIGHUP,
                  lambda *_: reload_wanted.__setitem__("flag", True))
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__("flag", True))
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__("flag", True))

    print(f"hotkeyd: {len(dae.grabs.chords)} chords grabbed on {disp_name} "
          f"via XI2 ($mod={dae.mod})",
          file=sys.stderr, flush=True)
    # "N chords grabbed" is TRUE AND MEANINGLESS while another client holds an
    # exclusive keyboard grab: the grabs are registered, and every one of them
    # is bypassed (dotfiles-hwds.30). On :0 that combination — a confident
    # startup line above a completely inert daemon — is what sent an afternoon
    # of debugging at hotkeyd, which was never the holder.
    #
    # Probed on a SEPARATE connection so the daemon's own passive grabs are not
    # what is being asked about, and only at startup: nothing is held a
    # millisecond after launch, so the dotfiles-hwds.31 implicit-grab false
    # positive cannot fire here the way it could mid-session.
    #
    # A WARNING, never a refusal to start. The grab is somebody else's and it
    # will end — a screen gets unlocked — and a daemon that exited here would
    # need a human to notice and restart it at exactly the moment the user is
    # returning to the machine.
    _grabbed = probe_keyboard_grab(disp_name)
    if _grabbed is not None:
        print(f"hotkeyd: WARNING on {disp_name} — {_grabbed}. The chords above "
              f"are registered but BYPASSED: an exclusive grab overrides every "
              f"passive one, i3's included, so no bind fires here until it is "
              f"released. Usual holder: a locked screen. Not a daemon fault "
              f"and not fixable by restarting it (dotfiles-hwds.30)",
              file=sys.stderr, flush=True)
    code = 0
    try:
        while not stop["flag"]:
            # Proof that this loop is turning, for `hotkeyd.sh status` and for
            # `start`'s decision about a daemon that is already there
            # (dotfiles-hwds.28). Top of the loop so it covers the idle branch
            # and the event branch alike; rate-limited inside beat().
            inst.beat()
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
                    select.select(waits, [], [], idle_timeout(dae))
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


# --------------------------------------------------------------------------
# is this daemon SERVING? (dotfiles-hwds.28)
# --------------------------------------------------------------------------

def probe_display(name: str) -> str | None:
    """Can a fresh client open this display? Returns None when it can, or a
    short reason when it cannot.

    Uses python-xlib and NOTHING ELSE. dotfiles-hwds.28 was filed as a dead `:0`
    on the strength of `xdpyinfo` failing, and `xdpyinfo` was simply not
    installed on that machine — a 127 that read as "the X server is gone" while
    Xorg had been up for eleven days and the daemon was serving normally. A
    liveness probe that reports death when its own tool is missing is the
    dotfiles-hwds.19/.21 lesson wearing a different hat. python-xlib cannot be
    missing anywhere the daemon itself can run, because the daemon imports it.

    Bounded by PROBE_TIMEOUT_S, via SIGALRM. Measured (frozen Xvfb, SIGSTOP):
    python-xlib blocks in the connection handshake at
    `protocol/display.py:561`, which is `select.select(..., timeout=None)` — so
    a socket timeout does NOT bound it, because there is no socket call to time
    out. An alarm whose handler raises does: Python re-raises out of the
    interrupted `select`, and xlib's own `except select.error` for EINTR cannot
    swallow it because it is not a select.error.

    Safe here and nowhere else: this runs in the short-lived `--health` process,
    on its main thread, never in the daemon.
    """
    def _too_slow(_sig, _frm):
        raise TimeoutError(f"no answer in {PROBE_TIMEOUT_S:.0f}s "
                           f"(server hung?)")

    prev = signal.signal(signal.SIGALRM, _too_slow)
    signal.setitimer(signal.ITIMER_REAL, PROBE_TIMEOUT_S)
    try:
        from Xlib import display as xdisplay        # noqa: PLC0415
        d = xdisplay.Display(name)
    except Exception as e:                          # noqa: BLE001
        return f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, prev)
    try:
        d.close()
    except Exception:                               # noqa: BLE001
        pass
    return None


def _grab_attempt(name: str) -> bool:
    """Does somebody else hold an exclusive keyboard grab on `name`?

    Asked the only way X answers it: try to take one. `AlreadyGrabbed` means
    another client has it — the protocol offers no way to learn WHO, which is
    why the message this feeds names the usual holder rather than the actual
    one. Success is released immediately; holding it would be the very outage
    being probed for.
    """
    from Xlib import X, display as xdisplay          # noqa: PLC0415
    d = xdisplay.Display(name)
    try:
        r = d.screen().root.grab_keyboard(
            True, X.GrabModeAsync, X.GrabModeAsync, X.CurrentTime)
        if r == X.GrabSuccess:
            d.ungrab_keyboard(X.CurrentTime)
            d.sync()
            return False
        return True
    finally:
        try:
            d.close()
        except Exception:                            # noqa: BLE001
            pass


def probe_keyboard_grab(name: str,
                        attempts: int = GRAB_PROBE_ATTEMPTS,
                        delay: float = GRAB_PROBE_DELAY_S,
                        _attempt=_grab_attempt) -> str | None:
    """None when nothing foreign holds the keyboard, else a short reason.

    RETRIES, and that is the whole design (dotfiles-hwds.31): the daemon's own
    per-chord passive grab becomes an implicit ACTIVE grab while a grabbed key
    is held, which is indistinguishable from a locker's grab in a single ask.
    Held keys are transient and lockers are not, so ONE clear answer acquits.

    Silent when it cannot ask at all. `probe_display` already owns "the display
    did not answer", and two probes reporting one fault in different words is
    how dotfiles-hwds.28 got misfiled as a dead X server.
    """
    for i in range(attempts):
        try:
            if not _attempt(name):
                return None
        except Exception:                            # noqa: BLE001
            return None
        if i + 1 < attempts and delay:
            time.sleep(delay)
    return (f"another client holds an exclusive keyboard grab "
            f"({attempts} probes, {delay:.1f}s apart, all AlreadyGrabbed)")


def health(display: str | None = None,
           probe_display=probe_display,
           probe_grab=probe_keyboard_grab) -> tuple[int, str]:
    """Is the daemon on this display SERVING? Returns (exit code, one line).

    Two probes, in the order that makes the answer actionable:

    1. THE HEARTBEAT — has this display's run loop turned recently. This is the
       one `pgrep` cannot answer and the one the outage needs: a frozen daemon
       holds its flock, keeps its state socket bound (so connections still
       complete out of the listen backlog) and matches every process pattern,
       while serving nothing.
    2. THE DISPLAY — can a fresh client reach it at all. A beating daemon on a
       display nothing serves is a contradiction worth printing rather than
       swallowing, and this is the probe `status` was missing entirely. It gets
       its OWN exit code because it is the weaker evidence of the two — see
       HEALTH_DISPLAY_UNREACHABLE.

    The message names which probe failed, because a bare non-zero exit during an
    outage ends the investigation instead of directing it.
    """
    lock = lock_path(display)
    disp = display or os.environ.get("DISPLAY", ":0")
    try:
        age = time.time() - lock.stat().st_mtime
    except OSError:
        return (HEALTH_NOT_SERVING,
                f"hotkeyd: {disp} — NOT SERVING: no daemon has run here "
                f"(no lock at {lock})")
    if age > HEARTBEAT_STALE_S:
        return (HEALTH_NOT_SERVING,
                f"hotkeyd: {disp} — NOT SERVING: last heartbeat {age:.0f}s ago "
                f"(> {HEARTBEAT_STALE_S:.0f}s); the run loop has stopped "
                f"turning")
    why = probe_display(disp)
    if why is not None:
        return (HEALTH_DISPLAY_UNREACHABLE,
                f"hotkeyd: {disp} — NOT SERVING: the display {disp} is "
                f"unreachable — {why}")
    # 3. THE KEYBOARD ITSELF (dotfiles-hwds.30). Everything above can be true
    #    while not one chord fires: an exclusive keyboard grab bypasses every
    #    PASSIVE grab on the display, so the daemon's and i3's alike are inert
    #    until it is released. Nothing in the first two probes can see that —
    #    the loop turns, the display answers, the grabs are registered — which
    #    is exactly how :0 sat dead for days while `status` said "running".
    #
    #    The cure is on the OTHER client, so this must not read like the
    #    daemon's own failure and must not point at `start`.
    grabbed = probe_grab(disp)
    if grabbed is not None:
        return (HEALTH_KEYBOARD_GRABBED,
                f"hotkeyd: {disp} — NOT SERVING: {grabbed}. Every chord on "
                f"{disp} is bypassed until it releases — restarting the daemon "
                f"cannot fix this. Usual holder: a LOCKED SCREEN (a screensaver "
                f"or locker grabs the keyboard by design; try "
                f"`xfce4-screensaver-command -q`), or a modal that took the "
                f"keyboard and never gave it back. X names no holder, so this "
                f"is the whole answer the protocol can give")
    # 4. THE GRAB SET ITSELF (dotfiles-hwds.42). Everything above can be true
    #    while half the table is not grabbed: that is the hwds.41 outage, where
    #    the directional group was gone and `status` said "running".
    #
    #    LAST on purpose. A stale heartbeat, an unreachable display and a
    #    foreign grab each EXPLAIN missing grabs, and reporting the consequence
    #    over the cause sends the operator to the wrong problem.
    #
    #    ABSENCE IS NOT DAMAGE. A daemon started before this feature publishes
    #    no report, and condemning it would repeat dotfiles-hwds.29's mistake of
    #    reading absence as staleness.
    report = read_grab_report(disp)
    if report and report.get("missing"):
        missing = report["missing"]
        shown = ", ".join(missing[:6]) + ("…" if len(missing) > 6 else "")
        return (HEALTH_DEGRADED,
                f"hotkeyd: {disp} — DEGRADED: {report.get('active')} of "
                f"{report.get('wanted')} chords grabbed; missing: {shown}. The "
                f"daemon is alive and these binds are dead — `hotkeyd.sh "
                f"restart {disp}` re-resolves them against the current keymap")
    return (HEALTH_OK,
            f"hotkeyd: {disp} — serving (heartbeat {age:.1f}s ago, display "
            f"reachable, keyboard not grabbed elsewhere"
            + (f", {report.get('active')} chords grabbed)" if report else ")"))


def main_argv(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="hotkeyd")
    ap.add_argument("--binds", help="path to a bind table module "
                                    "(default: the shipped binds.py)")
    ap.add_argument("--check", action="store_true",
                    help="validate the bind table and exit; no grabs, no X")
    ap.add_argument("--display", help="X display (default: $DISPLAY)")
    ap.add_argument("--health", action="store_true",
                    help="report whether this display's daemon is SERVING "
                         "(not merely alive); no grabs, no table")
    args = ap.parse_args(argv)

    if args.health:
        # BEFORE load_table on purpose: a daemon whose table is the reason it is
        # sick still has to be diagnosable, and a health probe that refuses to
        # answer until binds.py validates is one more check that cannot observe
        # the failure it exists for.
        rc, msg = health(args.display)
        print(msg)
        return rc

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


def main() -> int:
    return main_argv()


if __name__ == "__main__":
    sys.exit(main())
