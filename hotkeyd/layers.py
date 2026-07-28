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
import sys
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

# What i3 calls "no mode is active". i3 reports it under this exact name both in
# the `mode` event's `change` field and in GET_BINDING_STATE.
DEFAULT_I3_MODE = "default"


def _stderr_log(msg: str):
    print(f"hotkeyd: {msg}", file=sys.stderr, flush=True)


@dataclass(frozen=True)
class Event:
    """One key event, X-agnostic so the engine is testable without a display.

    `mods` is what the SESSION reports as held at this event — used only to
    corroborate or expire a hold, never as the primary source (see MOD_KEYSYMS).

    `device` / `device_id` are the SOURCE device that produced the event —
    XI2's `sourceid` (the physical slave) and the name it resolves to, not the
    master in the event header. They are what a `Bind(device=...)` predicate is
    matched against. Both default to None so every X-free test and every
    unscoped bind behaves exactly as before the XI2 port.

    `keycode` / `raw_state` are carried for the TRANSITION LOG and nothing else —
    no matching decision reads them. They exist because dotfiles-hwds.27 needs
    to know what an event physically was, not what the engine made of it:
    `key` is already a keysym resolved through a keymap that the xrdp session
    resets on every connect, and `mods` has had the lock bits stripped. Both
    default to None, so an X-free caller keeps building the Event it always did
    and the log says `none` rather than inventing a plausible number.
    """
    kind: str                       # "press" | "release"
    key: str                        # keysym name
    mods: frozenset[str] = field(default_factory=frozenset)
    device: str | None = None       # XI2 source device NAME
    device_id: int | None = None    # XI2 sourceid
    keycode: int | None = None      # the raw keycode X delivered
    raw_state: int | None = None    # the modifier mask X delivered, lock bits in


def _or_none(v, fmt=str) -> str:
    return "none" if v is None else fmt(v)


def format_transition(prev: dict, new: dict, ev: Event | None = None,
                      held=(), i3_mode: str | None = None,
                      note: str | None = None) -> str:
    """One line describing a published state change, and why it happened.

    This is the whole deliverable of dotfiles-hwds.27. The live `:10` daemon
    replayed `{"layer":"nav","mod":"resize"}` to the first bar that connected,
    ~30 s after it started, with nothing pressed — and logged NOTHING, so the
    single observation could not be attributed and a recurrence would have been
    just as uninformative. While the daemon believes it is in a layer it grabs
    that layer's BARE keys (`h j k l`, the arrows, `q`, `Escape`, `Return`), so
    a spontaneous layer belief eats those keys from every application.

    Every field earns its place by discriminating between the ticket's three
    candidate causes:

    - `keycode` / `mask` — what X actually delivered, BEFORE the keysym lookup
      and BEFORE the lock bits were stripped. The xrdp session resets its keymap
      on every connect, so `key` alone cannot say which physical key it was; and
      a chord that matched on a mask nobody was holding is the cause-1 shape.
    - `sourceid` / `device` — the only channel that separates a real keystroke
      from an injected one, since injection shares the display with real input.
      `binds.IGNORE_DEVICES` ships EMPTY (deliberately — XTEST is what every
      harness in this repo injects with), so an injected `$mod+o` reaches the
      engine and looks identical to a typed one in every field except this one.
    - `held` / `i3_mode` — the two pieces of engine belief that decide which
      sublayer is published and whether entry was allowed at all.

    A field the daemon could not resolve prints `none`. Printing a plausible
    stand-in instead would be worse than no log: cause 1 turns entirely on
    provenance, and a log that guesses at provenance cannot settle it.
    """
    parts = ["transition",
             f"layer={prev.get('layer')}->{new.get('layer')}",
             f"mod={_or_none(prev.get('mod'))}->{_or_none(new.get('mod'))}"]
    if ev is None:
        parts.append("trigger=none")
    else:
        parts += [
            f"trigger={ev.kind}:{ev.key}",
            "keycode=" + _or_none(ev.keycode),
            "mask=" + _or_none(ev.raw_state, lambda v: f"0x{v:04x}"),
            "mods=" + (",".join(sorted(ev.mods)) or "none"),
            "sourceid=" + _or_none(ev.device_id),
            "device=" + _or_none(ev.device, repr),
        ]
    parts.append("held=" + (",".join(sorted(held)) or "none"))
    parts.append(f"i3_mode={i3_mode}")
    if note:
        parts.append(f"note={note}")
    return " ".join(parts)


def device_matches(bind, ev: Event) -> bool:
    """Does this bind accept the event's SOURCE device?

    An unscoped bind (`device=None`) accepts anything, which is what keeps the
    whole shipped table behaving as it did before device identity existed. A
    scoped bind accepts only its own device — and, deliberately, NOT an event
    whose source could not be resolved: an unattributable event must not
    activate a bind whose entire purpose is attribution.
    """
    want = getattr(bind, "device", None)
    if want is None:
        return True
    return ev.device == want


class LayerEngine:
    def __init__(self, binds, layers, publisher=None, clock=None,
                 guard_ms: int = RELEASE_GUARD_MS, mod: str = None, log=None):
        self.binds = list(binds)
        self.layers = layers
        self.publisher = publisher
        self.clock = clock or time.monotonic
        self.guard_ms = guard_ms
        # What `$mod` resolves to on this display (Mod4 native, Mod1 on xrdp).
        self.mod = mod or B.DEFAULT_MOD
        self.log = log or _stderr_log

        # i3's binding mode, fed in by the daemon from i3's `mode` event. The
        # engine starts optimistic: a daemon that cannot ask i3 (no IPC, an
        # injected stub) must still be usable, so "unknown" means "default".
        self._i3_mode = DEFAULT_I3_MODE

        self._layer = DEFAULT_LAYER
        self._held: dict[str, float] = {}   # canonical modifier -> last seen at
        self._down: dict[str, float] = {}   # non-modifier keys down -> last seen
        # Seeded with the STARTING state, not None: the contract is "publish on
        # change", and the state a fresh engine is already in is not a change.
        # Seeding it None meant the first event of the session emitted a
        # `default` line even when nothing had happened — which also made
        # "a refused layer entry publishes nothing" impossible to state exactly.
        self._last_published: dict | None = {
            "layer": self._layer, "mod": None}
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

    # -- belief vs. the server (dotfiles-hwds.27) --------------------------
    @property
    def held(self) -> frozenset[str]:
        """The modifiers the engine currently BELIEVES are down.

        Exposed so the daemon's idle path can skip its reconciliation X
        round-trip entirely when there is no belief to check — see
        `reconcile_holds`.
        """
        return frozenset(self._held)

    def reconcile_holds(self, mods_down, now=None) -> bool:
        """Retract held-modifier beliefs the session does not corroborate.

        `_expire_stale_holds` runs only when an EVENT arrives, which is correct
        while keys are flowing and useless when they are not: an idle daemon
        holding a phantom modifier keeps publishing (and REPLAYING to every bar
        that connects) a sublayer nobody is standing in, with nothing scheduled
        that would ever notice. dotfiles-hwds.27 was observed in exactly that
        shape — a state served out of the replay buffer that corrected itself
        only once real events resumed.

        `mods_down` is what the SERVER says is down right now, sampled outside
        any event. That distinction is the reason this is sound: the `state`
        mask ON an event is pre-event in X (the release of Ctrl still carries
        the Ctrl bit), which is precisely why the engine tracks holds from
        MOD_KEYSYMS instead — but a standalone query has no event to be "pre".

        RETRACT ONLY, never assert. A modifier the engine never observed being
        pressed is not added here even when the server reports it down: `_held`
        is what this daemon has SEEN, and manufacturing a sublayer out of a
        modifier belonging to some other client's gesture would invent the very
        class of state this method exists to remove.

        The LAYER is deliberately untouched. X has no opinion about `nav`, so
        there is nothing to reconcile it against, and a reconciler that dropped
        the layer on a modifier mismatch would silently cancel a legitimate nav
        the user is standing in.
        """
        now = self.clock() if now is None else now
        dropped = sorted(c for c in self._held if c not in mods_down)
        for canon in self._held:
            if canon in mods_down:
                self._held[canon] = now      # corroborated by the server
        for canon in dropped:
            del self._held[canon]
        if not dropped:
            return False
        before = self._last_published
        self._publish(note="reconcile:dropped=" + ",".join(dropped))
        return self._last_published != before

    # -- i3-mode arbitration ----------------------------------------------
    @property
    def i3_mode(self) -> str:
        """The i3 binding mode this engine last heard about."""
        return self._i3_mode

    def set_i3_mode(self, name: str | None):
        """Feed i3's binding mode in. The daemon calls this from the `mode`
        event on the IPC connection it already holds.

        i3 modes hold their own passive grabs on the same bare keys a layer
        wants, so two active "modes" mean two owners: the daemon's grabs are
        refused with BadAccess while its published state still claims the layer,
        and the keys answer to i3 (dotfiles-hwds.10, reproduced). Arbitration is
        one-sided on purpose — i3 grabbed first and cannot be asked to yield, so
        the daemon is the one that steps back.
        """
        name = DEFAULT_I3_MODE if not name else str(name)
        if name == self._i3_mode:
            return
        self._i3_mode = name
        if name != DEFAULT_I3_MODE and self._layer != DEFAULT_LAYER:
            self._layer = DEFAULT_LAYER
            # _publish is change-only, so a layer exit that raced this event
            # costs one `default` line in total, not two. No triggering key is
            # passed because there ISN'T one — see format_transition on why the
            # log must not imply otherwise.
            self._publish(note=f"i3-entered-mode:{name}")

    def _i3_owns_the_keyboard(self) -> bool:
        return self._i3_mode != DEFAULT_I3_MODE

    def _publish(self, ev: Event | None = None, note: str | None = None):
        """Publish the state, and LOG the change with what caused it.

        Logging lives here rather than at each of the four assignments that move
        the layer because this is the one place that knows a change actually
        reached the socket: what a bar was told is the thing a recurrence of
        dotfiles-hwds.27 has to be explained against, and a refused layer entry
        (which publishes nothing) must not appear as a transition.
        """
        st = self.state
        if st == self._last_published:
            return                      # publish on CHANGE only
        prev, self._last_published = self._last_published, st
        self.log(format_transition(prev, st, ev, held=self._held,
                                   i3_mode=self._i3_mode, note=note))
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
            self._publish(ev)
            return []                   # modifiers never act on their own

        if ev.kind == "release":
            self._down.pop(ev.key, None)
            actions = self._match(ev, on_release=True)
        else:
            if self._is_repeat(ev.key, now):
                # Publish before returning: expiry above may have changed the
                # state, and swallowing it here left the bar showing a layer the
                # engine had already left until the key was finally released.
                self._publish(ev)
                return []               # auto-repeat: one action per press
            self._down[ev.key] = now
            actions = self._match(ev, on_release=False)

        out = self._run(actions, ev)
        # Publish ONCE, after the actions have moved the state. Publishing
        # before would emit the pre-action layer too, so entering a layer would
        # cost two lines instead of the one the contract promises.
        self._publish(ev)
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
    def _index(self, bs) -> dict:
        """chord identity -> the binds on it, in table order.

        A LIST rather than one bind: `device=` splits one chord across several
        binds that the validator deliberately does not call duplicates, because
        `sourceid` disambiguates them at dispatch. Every other chord has exactly
        one entry, so the lookup below is the same lookup it always was.
        """
        out: dict = {}
        for b in bs:
            try:
                key = B.normalize_chord(b.chord, self.mod) + (b.on_release,)
            except B.BindError:
                continue                # validated at load; skip defensively
            out.setdefault(key, []).append(b)
        return out

    def _match(self, ev: Event, on_release: bool) -> list:
        layer = self.layers.get(self._layer)
        if layer is not None:
            return self._match_in_layer(layer, ev, on_release)
        want = (tuple(sorted(ev.mods)), ev.key, on_release)
        for b in self._global.get(want, ()):
            if device_matches(b, ev):
                return [b.action]
        return []

    def _match_in_layer(self, layer, ev: Event, on_release: bool) -> list:
        # Exit keys first, and matched on the KEYSYM ALONE — deliberately
        # ignoring held modifiers. i3 needed six binds (q, Ctrl+q, Mod1+q,
        # Shift+q, Escape, Return) because bindsym is modifier-exact; declaring
        # exit_keys once only works if a layer stays leavable while Ctrl or Alt
        # is still down. A layer you cannot leave one-handed is a trap.
        if not on_release and ev.key in layer.exit_keys:
            self._layer = DEFAULT_LAYER
            return []

        # Layer chords are BARE keysyms, so this comparison is the whole match.
        # That is a validated invariant, not an assumption: `binds._scan(bare=
        # True)` refuses any layer or sublayer chord carrying a modifier, and
        # every load path validates (dotfiles-hwds.8). Held modifiers are
        # expressed as Mod sublayers — which is what picks `table` on the line
        # above — so there is nothing left for a `+` to mean here.
        mod_label = self._active_mod()
        table = layer.mods[mod_label].binds if mod_label else layer.binds
        for b in table:
            if (b.chord == ev.key and b.on_release == on_release
                    and device_matches(b, ev)):
                return [b.action]
        return []

    def _run(self, actions, ev) -> list:
        out = []
        for a in actions:
            if isinstance(a, B.EnterLayer):
                if self._i3_owns_the_keyboard():
                    # Refuse the transition outright: the layer's grabs would be
                    # refused by X anyway, and taking the layer regardless is
                    # what made the daemon's state disagree with reality. Not
                    # entering means the daemon never asks for those grabs.
                    self.log(f"refusing to enter layer {a.layer!r}: "
                             f"i3 is in mode {self._i3_mode!r}")
                    continue
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
