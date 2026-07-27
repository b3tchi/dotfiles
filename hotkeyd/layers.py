"""Layer engine + state channel for hotkeyd (sp020 Task 3, ft011).

Two pieces, deliberately separable so the engine is testable without X and
without a socket:

- `LayerEngine` — turns key events into actions, owns layer + held-modifier
  state, and publishes every CHANGE (never a repeat) to a publisher.
- `StatePublisher` — a unix-socket fan-out. Bars are read-only consumers
  ([[adr0012]] shape applied to input state); the daemon owns the state.

What this replaces: the bar used to reconstruct layer state from side effects of
`nop nav-move-on` marker binds, because i3 cannot report modifier state, and
guessed at missed releases with a 120 ms timer. The engine sees the modifier
directly. The guard survives — xrdp synthesises Shift around every character it
sends, so a lost release is a property of that SESSION, not of i3.
"""
from __future__ import annotations

import errno
import json
import os
import selectors
import socket
import time
from dataclasses import dataclass, field
from pathlib import Path

import binds as B

# Modifier keysyms -> the canonical modifier name they contribute. The engine
# tracks holds from these events directly rather than trusting the `state` mask,
# which is pre-event in X (the release of Ctrl still carries the Ctrl bit) — the
# exact quirk that forced the masked/bare `bindcode --release` pairs in i3.
MOD_KEYSYMS = {
    "Shift_L": "Shift", "Shift_R": "Shift",
    "Control_L": "Ctrl", "Control_R": "Ctrl",
    "Alt_L": "Mod1", "Alt_R": "Mod1", "Meta_L": "Mod1", "Meta_R": "Mod1",
    "Super_L": "Mod4", "Super_R": "Mod4",
}

# How long a modifier may stay "held" without any event confirming it. Sized for
# xrdp's per-character Shift synthesis; 6dc7751 shrank the bar-side version of
# this from 400 ms to 120 ms and that value is inherited here deliberately.
RELEASE_GUARD_MS = 120

# How long a key may stay "down" without a release before auto-repeat
# suppression gives up on it. A lost release must not make a key permanently
# dead; 1 s is orders of magnitude above any repeat interval.
KEY_WEDGE_MS = 1000

DEFAULT_LAYER = "default"


@dataclass(frozen=True)
class Event:
    """One key event, X-agnostic so the engine is testable without a display.

    `mods` is what the SESSION reports as held at this event — used only to
    corroborate or expire a hold, never as the primary source (see MOD_KEYSYMS).
    """
    kind: str                       # "press" | "release"
    key: str                        # keysym name
    mods: frozenset[str] = field(default_factory=frozenset)


class LayerEngine:
    def __init__(self, binds, layers, publisher=None, clock=None,
                 guard_ms: int = RELEASE_GUARD_MS):
        self.binds = list(binds)
        self.layers = layers
        self.publisher = publisher
        self.clock = clock or time.monotonic
        self.guard_ms = guard_ms

        self._layer = DEFAULT_LAYER
        self._held: dict[str, float] = {}   # canonical modifier -> last seen at
        self._down: dict[str, float] = {}   # non-modifier keys down -> last seen
        self._last_published: dict | None = None
        self._global = self._index(self.binds)

    # -- state ------------------------------------------------------------
    @property
    def state(self) -> dict:
        return {"layer": self._layer, "mod": self._active_mod()}

    def _active_mod(self) -> str | None:
        """Which named modifier sub-layer is active.

        Precedence is the layer's DECLARATION order, not press order: two
        modifiers down must resolve the same way every time, or the bar flaps
        depending on which finger landed first.
        """
        layer = self.layers.get(self._layer)
        if layer is None:
            return None
        for label, mod in layer.mods.items():
            canon = B.MODIFIER_ALIASES.get(str(mod.modifier).lower())
            if canon in self._held:
                return label
        return None

    def _publish(self):
        st = self.state
        if st == self._last_published:
            return                      # publish on CHANGE only
        self._last_published = st
        if self.publisher is not None:
            self.publisher.publish(st)

    # -- event handling ---------------------------------------------------
    def handle(self, ev: Event) -> list:
        """Feed one event. Returns the actions to dispatch (i3 command strings
        and Run objects); callables are invoked here since they own their effect.
        """
        now = self.clock()
        canon = MOD_KEYSYMS.get(ev.key)

        # Expire first, on EVERY event including modifier ones. Skipping it here
        # let a stale hold win precedence for one publish after a lost release.
        self._expire_stale_holds(ev, now)

        if canon is not None:
            if ev.kind == "press":
                self._held[canon] = now
            else:
                self._held.pop(canon, None)
            self._publish()
            return []                   # modifiers never act on their own

        if ev.kind == "release":
            self._down.pop(ev.key, None)
            actions = self._match(ev, on_release=True)
        else:
            if self._is_repeat(ev.key, now):
                # Publish before returning: expiry above may have changed the
                # state, and swallowing it here left the bar showing a layer the
                # engine had already left until the key was finally released.
                self._publish()
                return []               # auto-repeat: one action per press
            self._down[ev.key] = now
            actions = self._match(ev, on_release=False)

        out = self._run(actions, ev)
        # Publish ONCE, after the actions have moved the state. Publishing
        # before would emit the pre-action layer too, so entering a layer would
        # cost two lines instead of the one the contract promises.
        self._publish()
        return out

    def _is_repeat(self, key: str, now: float) -> bool:
        """True for an X auto-repeat press (same key, no release seen).

        Bounded by a wedge window rather than held forever: if a release is LOST
        — the same xrdp hazard the modifier guard exists for — an unbounded rule
        would make that key dead for the rest of the session. The window is far
        longer than any repeat interval, so it never lets a repeat through.
        """
        seen = self._down.get(key)
        if seen is None:
            return False
        if (now - seen) * 1000 > KEY_WEDGE_MS:
            del self._down[key]
            return False
        self._down[key] = now
        return True

    def _expire_stale_holds(self, ev: Event, now: float):
        """Drop a hold the session has stopped reporting for longer than the
        guard window. Without this a lost release latches the modifier and the
        bar lies about the layer until the next press — with it, a fast typist
        inside the window is unaffected."""
        for canon, seen in list(self._held.items()):
            if canon in ev.mods:
                self._held[canon] = now          # corroborated, refresh
            elif (now - seen) * 1000 > self.guard_ms:
                del self._held[canon]

    # -- matching ---------------------------------------------------------
    @staticmethod
    def _index(bs) -> dict:
        out: dict = {}
        for b in bs:
            try:
                key = B.normalize_chord(b.chord) + (b.on_release,)
            except B.BindError:
                continue                # validated at load; skip defensively
            out[key] = b
        return out

    def _match(self, ev: Event, on_release: bool) -> list:
        layer = self.layers.get(self._layer)
        if layer is not None:
            return self._match_in_layer(layer, ev, on_release)
        want = (tuple(sorted(ev.mods)), ev.key, on_release)
        b = self._global.get(want)
        return [b.action] if b else []

    def _match_in_layer(self, layer, ev: Event, on_release: bool) -> list:
        # Exit keys first, and matched on the KEYSYM ALONE — deliberately
        # ignoring held modifiers. i3 needed six binds (q, Ctrl+q, Mod1+q,
        # Shift+q, Escape, Return) because bindsym is modifier-exact; declaring
        # exit_keys once only works if a layer stays leavable while Ctrl or Alt
        # is still down. A layer you cannot leave one-handed is a trap.
        if not on_release and ev.key in layer.exit_keys:
            self._layer = DEFAULT_LAYER
            return []

        mod_label = self._active_mod()
        table = layer.mods[mod_label].binds if mod_label else layer.binds
        for b in table:
            if b.chord == ev.key and b.on_release == on_release:
                return [b.action]
        return []

    def _run(self, actions, ev) -> list:
        out = []
        for a in actions:
            if isinstance(a, B.EnterLayer):
                self._layer = a.layer
            elif isinstance(a, B.ExitLayer):
                self._layer = DEFAULT_LAYER
            elif callable(a):
                a(ev)                   # owns its own effect
            else:
                out.append(a)
        return out


# --------------------------------------------------------------------------
# state channel
# --------------------------------------------------------------------------

class ChannelUnavailable(RuntimeError):
    """The socket's directory is gone. Per [[adr0014]] this is fail-fast: a loop
    cannot re-establish its own vanished precondition from the inside."""


class ChannelBusy(RuntimeError):
    """Another process is already listening — do not steal a live daemon's
    socket, or two daemons fight over one display."""


def socket_path(display: str | None = None) -> Path:
    """Per-display socket path. The screen suffix is stripped (`:10.0` and `:10`
    are one session) — the normalization dotfiles-3x85 needed for RDP sessions,
    which present DISPLAY=:10.0."""
    display = display or os.environ.get("DISPLAY", ":0")
    tag = display.lstrip(":").split(".")[0]
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(runtime) / f"hotkeyd-{tag}.sock"


class StatePublisher:
    """Unix-socket fan-out. Non-blocking on purpose: a bar that stops reading
    must never stall the key path, so a client whose buffer is full loses that
    LINE rather than blocking dispatch.

    Losing a line is safe because this is a last-value feed: any client that
    dropped one is marked stale and re-sent the current state on the next
    `poll()`, so it converges instead of sitting on an old layer forever."""

    def __init__(self, path, backlog: int = 8):
        self.path = Path(path)
        self._clients: list[socket.socket] = []
        self._stale: set[socket.socket] = set()
        self._current: dict | None = None

        if not self.path.parent.is_dir():
            raise ChannelUnavailable(f"no such directory: {self.path.parent}")

        self._reap_stale_socket()
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.setblocking(False)
        try:
            self.srv.bind(str(self.path))
        except OSError as e:
            self.srv.close()
            if e.errno in (errno.ENOENT, errno.EACCES):
                raise ChannelUnavailable(str(e)) from e
            raise
        self.srv.listen(backlog)
        self.sel = selectors.DefaultSelector()
        self.sel.register(self.srv, selectors.EVENT_READ)

    def _reap_stale_socket(self):
        """A SIGKILLed predecessor leaves the socket inode behind and bind()
        would fail EADDRINUSE forever. Probe it: if nobody answers it is stale
        and gets unlinked; if somebody does, this display already has a daemon
        and stealing its socket would put two daemons on one display."""
        if not self.path.exists():
            return
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.settimeout(0.2)
            probe.connect(str(self.path))
        except OSError:
            self.path.unlink(missing_ok=True)    # stale
            return
        else:
            raise ChannelBusy(f"a daemon is already listening on {self.path}")
        finally:
            probe.close()

    @property
    def client_count(self) -> int:
        """Live subscribers. Exposed so tests can assert that a dead client is
        actually reaped rather than merely tolerated — swallowing the write error
        without dropping the socket leaks a closed fd per dead bar, and the list
        grows for the life of the session."""
        return len(self._clients)

    # -- fan-out ----------------------------------------------------------
    def poll(self):
        """Accept pending connections and re-send the current state to any
        client that dropped a line. Cheap; call from the daemon's loop."""
        for conn in list(self._stale):
            self._stale.discard(conn)
            if self._current is not None:
                self._send(conn, self._current)
        for key, _ in self.sel.select(timeout=0):
            if key.fileobj is self.srv:
                try:
                    conn, _ = self.srv.accept()
                except OSError:
                    continue
                conn.setblocking(False)
                self._clients.append(conn)
                if self._current is not None:
                    # Replay on connect: a bar that starts late must never be
                    # blank, which the i3-binding-event feed could not manage.
                    self._send(conn, self._current)

    def publish(self, state: dict):
        self._current = state
        self.poll()
        for c in list(self._clients):
            self._send(c, state)

    def _send(self, conn: socket.socket, state: dict):
        line = (json.dumps(state, separators=(",", ":")) + "\n").encode()
        try:
            conn.send(line)
        except (BlockingIOError, InterruptedError):
            # Slow consumer: drop the LINE, never the key path. Marked stale so
            # the next poll() re-sends the current state and the client
            # converges rather than staying on an old layer.
            self._stale.add(conn)
        except OSError:
            self._drop(conn)

    def _drop(self, conn: socket.socket):
        if conn in self._clients:
            self._clients.remove(conn)
        self._stale.discard(conn)
        try:
            conn.close()
        except OSError:
            pass

    def close(self):
        for c in list(self._clients):
            self._drop(c)
        try:
            self.sel.unregister(self.srv)
        except (KeyError, ValueError):
            pass
        self.srv.close()
        self.path.unlink(missing_ok=True)
