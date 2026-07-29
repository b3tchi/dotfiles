"""Declarative bind table for the hotkeyd global keybinding layer (sp020, ft011).

A Python module rather than YAML: binds need composition — workspace loops,
per-layer tables, shared command builders — and a module gives that plus
comments without anyone writing a parser.

`validate()` is what replaces i3's own duplicate-binding detection once binds
leave i3. It is pure: no X connection, so `hotkeyd.py --check` works headless
and in a pre-commit hook. Keysym-to-keycode resolution happens later, against a
live display, in the daemon (poc013: `Super_L` is keycode 133 on `:0` but 115 on
the xrdp `:10` session, so keycodes must never appear in this table).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Iterable, Union

# --------------------------------------------------------------------------
# chords
# --------------------------------------------------------------------------

# Canonical modifier names, plus every spelling the i3 configs and human habit
# already use. Folding these is what makes duplicate detection real: `Super+d`
# and `Mod4+d` are the same chord and declaring both must be an error, not two
# binds racing for one key.
MODIFIER_ALIASES = {
    "shift": "Shift",
    "lock": "Lock",
    "ctrl": "Ctrl", "control": "Ctrl",
    "mod1": "Mod1", "alt": "Mod1", "meta": "Mod1",
    "mod2": "Mod2", "numlock": "Mod2",
    "mod3": "Mod3",
    "mod4": "Mod4", "super": "Mod4", "win": "Mod4", "logo": "Mod4",
    "mod5": "Mod5",
}

# Keysym names accepted in a chord's key position. Deliberately a static set
# rather than an X round-trip: validation must run with no display (--check in
# a hook, on a headless box). The daemon does the real keymap resolution and
# reports a keysym that is absent from the *current* keymap at that point.
_KEYSYMS = frozenset(
    list("abcdefghijklmnopqrstuvwxyz0123456789")
    + [f"F{n}" for n in range(1, 25)]
    + [
        "Return", "Escape", "Tab", "ISO_Left_Tab", "space", "BackSpace",
        "Delete", "Insert", "Home", "End", "Prior", "Next",
        "Left", "Right", "Up", "Down",
        "minus", "plus", "equal", "comma", "period", "slash", "backslash",
        "semicolon", "apostrophe", "grave", "bracketleft", "bracketright",
        "Print", "Pause", "Menu",
        "Shift_L", "Shift_R", "Control_L", "Control_R",
        "Alt_L", "Alt_R", "Super_L", "Super_R", "Meta_L", "Meta_R",
        "Num_Lock", "Caps_Lock",
        "XF86MonBrightnessUp", "XF86MonBrightnessDown",
        "XF86AudioRaiseVolume", "XF86AudioLowerVolume", "XF86AudioMute",
        "XF86AudioPlay", "XF86AudioNext", "XF86AudioPrev",
    ]
)


# The `$mod` token, resolved per display at daemon start from the same X
# resource i3 reads (`i3wm.mod`, ft003) with the same Mod4 default. The xrdp
# session sets Mod1 (xrdp/xinitrc) because Super does not survive an RDP client,
# so ONE table has to mean Super on :0 and Alt on :10 — hardcoding Mod4 left
# every such chord FREE on :10, where the daemon would own and serve it while i3
# owned the Alt equivalent.
MOD_TOKEN = "$mod"
DEFAULT_MOD = "Mod4"

# The one chord i3 keeps forever (i3/config.common, `hotkeyd-panic.sh panic`).
# Pressing it stops the daemon, links i3/config.d/zz-fallback-binds.conf and
# reloads i3 — the way back from a daemon that is dead OR alive and wrong.
#
# Moved from $mod+Shift+r when the restart verbs consolidated onto that chord
# as the hammer. One modifier out, not away: reachability without an F12 row is
# why panic left $mod+Shift+F12 in the first place, and $mod+Ctrl+Shift+r keeps
# it. The hammer RESTARTS the daemon and panic STOPS it, so they must stay
# separate chords — if the daemon is what is broken, restarting it reinstates
# the fault, and that is precisely when the other chord is needed.
PANIC_CHORD = "$mod+Ctrl+Shift+r"

# Every modifier `$mod` resolves to on a display this repo runs on: Mod4 on the
# native :0 session, Mod1 on the xrdp :10 session (xrdp/xinitrc merges
# `i3wm.mod: Mod1`). Both are enumerated because RESERVED_CHORDS below has to
# hold under whichever one the validator happens to be called with.
MOD_RESOLUTIONS = ("Mod4", "Mod1")


class BindError(ValueError):
    """A chord or table that cannot be loaded. Message names the offender."""


def parse_chord(chord: str, mod: str = DEFAULT_MOD) -> tuple[frozenset[str], str]:
    """Split a chord into (canonical modifiers, keysym name).

    `mod` is what the `$mod` token resolves to on this display.

    Raises BindError naming the chord for anything unusable: an unknown
    modifier, an empty key, or a bare keycode (see the module docstring).
    """
    if not isinstance(chord, str) or not chord.strip():
        raise BindError(f"empty chord: {chord!r}")
    parts = chord.split("+")
    key = parts[-1].strip()
    if not key:
        raise BindError(f"chord {chord!r} has no key after the last '+'")
    # A single digit IS a keysym ("1" is the digit-one key, and `$mod+1` is how
    # the workspace binds have always read). Multi-digit means someone typed a
    # keycode — `37`, `105`, `133` — which is the portability trap.
    if key.isdigit() and len(key) > 1:
        raise BindError(
            f"chord {chord!r} uses a keycode ({key}); use a keysym name — "
            "keycodes differ per session (Super_L is 133 on :0, 115 on :10)")
    mods = set()
    for raw in parts[:-1]:
        name = raw.strip().lower()
        if name == MOD_TOKEN:
            name = str(mod).lower()
        canon = MODIFIER_ALIASES.get(name)
        if canon is None:
            raise BindError(f"chord {chord!r} has unknown modifier {raw!r}")
        mods.add(canon)
    if key not in _KEYSYMS:
        raise BindError(
            f"chord {chord!r} has unknown keysym {key!r} "
            "(add it to binds._KEYSYMS if the keymap really has it)")
    return frozenset(mods), key


def normalize_chord(chord: str, mod: str = DEFAULT_MOD) -> tuple[tuple[str, ...], str]:
    """Order-insensitive, alias-folded identity of a chord, for dup detection."""
    mods, key = parse_chord(chord, mod)
    return tuple(sorted(mods)), key


def canon_modifier(name, mod: str = DEFAULT_MOD) -> str | None:
    """Canonical name for a modifier written on its own, `$mod` resolved.

    `MODIFIER_ALIASES` alone is not enough anywhere a modifier is named OUTSIDE
    a chord — a `Mod` sublayer's `modifier`, a layer's `hold`. `parse_chord`
    resolves the `$mod` token for chords, so `$mod+Tab` has always meant Super
    on `:0` and Alt on the xrdp `:10` session; a bare `"$mod"` looked up in
    `MODIFIER_ALIASES` resolves to None on BOTH, which is a feature that works
    on neither display rather than one that works on the wrong one.

    Returns None for anything unresolvable, so callers report the offender
    themselves rather than guessing a modifier.
    """
    if not isinstance(name, str):
        return None
    n = name.strip().lower()
    if n == MOD_TOKEN:
        n = str(mod).strip().lower()
    return MODIFIER_ALIASES.get(n)


# The panic chord under EVERY spelling that reaches it, as normalised
# identities. Reserving the literal `$mod` token alone leaves a hole, because
# this validator is display-agnostic while `$mod` is not: a table that spells
# `Mod1+Shift+r` steals the chord on :10 and `Mod4+Shift+r` steals it on :0,
# and neither is a string match for `$mod`. Normalising the token under both
# resolutions closes it in both directions — a `$mod+Shift+r` in the table
# normalises to whichever resolution the validator was called with, and both
# are in the set. Alias folding (`Super`, `Alt`, `win`, case) comes free from
# normalize_chord.
RESERVED_CHORDS = {normalize_chord(PANIC_CHORD, m) for m in MOD_RESOLUTIONS}


# --------------------------------------------------------------------------
# actions
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Run:
    """Spawn a process. Distinct from an i3 command so the daemon need not
    route everything through the WM."""
    cmd: str


@dataclass(frozen=True)
class EnterLayer:
    layer: str


@dataclass(frozen=True)
class ExitLayer:
    pass


def run(cmd: str) -> Run:
    return Run(cmd)


def enter_layer(name: str) -> EnterLayer:
    return EnterLayer(name)


def exit_layer() -> ExitLayer:
    return ExitLayer()


Action = Union[str, Run, EnterLayer, ExitLayer, Callable]

# A bind's action may also be a TUPLE of actions, dispatched in order. One
# chord is one bind, so a gesture that both DOES something and moves the layer
# has nowhere else to say so: the switcher's `$mod+Tab` must open the overlay
# and take the layer, and its `Escape` must cancel the overlay and leave.
# `one_shot` cannot express either — it is all-or-nothing per layer, and this
# layer's `Tab` deliberately does NOT exit.
Actions = Union[Action, tuple]


def actions_of(bind) -> list:
    """The action list of a bind, whether it declared one action or several."""
    a = bind.action
    return list(a) if isinstance(a, (list, tuple)) else [a]


# --------------------------------------------------------------------------
# table shape
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Bind:
    chord: str
    action: Actions
    on_release: bool = False
    # Restrict this bind to ONE source device, by name as XI2 reports it
    # (`xinput list`). None — the default — means "any source". Core X11
    # `KeyPress` carries no device identity at all, which is why the daemon
    # grabs through XI2: `XIDeviceEvent.sourceid` is the only channel that can
    # tell one keyboard from another, or a real keystroke from an injected one,
    # since injection and real input share a display.
    device: str | None = None


# Source devices whose events the daemon drops outright, by XI2 name. Matched
# against the SOURCE (slave) device, not the master.
#
# EMPTY BY DEFAULT, deliberately. The obvious entry is
# "Virtual core XTEST keyboard" — but XTEST is also what `xdotool` uses, what
# every harness in this repo injects with, and what any user-facing automation
# would come through, so dropping it by default would silently kill binds that
# work today. And whether the xrdp session's synthesised Shift arrives as XTEST
# (5) or as `xrdpKeyboard` (7) is UNMEASURED — it cannot be settled by
# injection, since XTEST is what a harness injects with — so it needs a human
# at a real RDP client ([[sp020]] Task 15 / dotfiles-hwds.3). Until that lands
# the 120 ms release guard stays and nothing is ignored.
IGNORE_DEVICES: list[str] = []


@dataclass(frozen=True)
class Mod:
    """A held-modifier sub-layer: while `modifier` is down, `binds` apply."""
    modifier: str
    binds: tuple[Bind, ...] = ()


@dataclass
class Layer:
    binds: list[Bind] = field(default_factory=list)
    mods: dict[str, Mod] = field(default_factory=dict)
    exit_keys: list[str] = field(default_factory=list)
    # Return to the default layer as soon as ANY bind here fires — a menu you
    # answer once, rather than a mode you stand in. i3 spelled this by
    # appending `, mode "default"` to every single bind in the block, which is
    # the LAYER being one-shot rather than a per-bind choice; declared per bind
    # it would be a per-bind opportunity to forget, and the layer this exists
    # for is the one where forgetting leaves a bare `r` on `reboot`.
    #
    # Only a bind that actually FIRES ends the layer. A key matching nothing is
    # swallowed exactly as in a persistent layer, so a typo does not silently
    # drop you out of the mode you believe you are in.
    one_shot: bool = False

    # A HOLD LAYER (dotfiles-hwds.40): the modifier whose RELEASE ends the
    # layer, dispatching `on_hold_release` on the way out. `$mod` is accepted
    # and resolves per display like a chord's does — see `canon_modifier`.
    #
    # This is what a layer needs to be an alt-tab switcher and what i3 could not
    # express at all: cycle while the modifier stays down, commit when it comes
    # up. It is NOT a `Mod` sublayer — a sublayer says "while this is held these
    # OTHER binds apply" and never acts on its own; a hold says "this layer
    # exists only while this is held", which is a lifetime, not a table.
    #
    # The modifier is held BEFORE the layer is entered ($mod+Tab enters it), so
    # the engine never saw the press and `_held` is empty. Nothing here reads
    # that belief: the layer ends when a release is OBSERVED, or when the server
    # is asked directly and answers that the modifier is up
    # (`LayerEngine.reconcile_hold_layer`).
    hold: str | None = None
    on_hold_release: Actions | None = None


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

def _action_problem(a, where: str, what: str) -> str | None:
    if isinstance(a, str) and not a.strip():
        return f"{where}: {what} has an empty command"
    if isinstance(a, Run) and not a.cmd.strip():
        return f"{where}: {what} has an empty run() command"
    return None


def _command_problem(bind: Bind, where: str) -> str | None:
    what = f"chord {bind.chord!r}"
    if isinstance(bind.action, (list, tuple)) and not bind.action:
        return f"{where}: {what} has an empty action tuple"
    for a in actions_of(bind):
        p = _action_problem(a, where, what)
        if p:
            return p
    return None


def _device_problem(bind: Bind, where: str) -> str | None:
    """A `device=` that can never match is a bind that silently never fires.

    Only the shape is checked here, never the name against a live inventory:
    `validate()` is pure and runs headless (`--check` in a pre-commit hook), and
    a device may legitimately be absent at validation time and present at press
    time — a bluetooth keyboard that is off right now.
    """
    dev = getattr(bind, "device", None)
    if dev is None:
        return None
    if not isinstance(dev, str) or not dev.strip():
        return (f"{where}: chord {bind.chord!r} has an empty device= "
                f"({dev!r}); omit it to match any source device")
    return None


def _key(bind: Bind, prefix: str = "", mod: str = DEFAULT_MOD) -> tuple:
    """Duplicate-detection identity. `on_release` is part of it: press and
    release on one chord are different events, not a collision (i3 does the
    same with `--release`).

    `device` is part of it for the same reason: two binds on one chord scoped to
    DIFFERENT source devices are disambiguated at dispatch by `sourceid` and
    cannot double-fire, so calling them a collision would refuse the exact table
    the `device=` predicate exists to express. Two binds on one chord with the
    SAME device (`None` included) still collide.
    """
    chord = f"{prefix}+{bind.chord}" if prefix else bind.chord
    return normalize_chord(chord, mod) + (bind.on_release, bind.device)


def _bare_problem(bind: Bind, where: str, mod: str) -> str | None:
    """Layer chords must be BARE keysyms — see `_scan(bare=True)`."""
    try:
        mods, _ = parse_chord(bind.chord, mod)
    except BindError:
        return None                     # reported by the caller's own parse
    if not mods:
        return None
    return (f"{where}: chord {bind.chord!r} carries modifiers "
            f"({'+'.join(sorted(mods))}); layer binds must be BARE keysyms — "
            "express a held modifier as a Mod sublayer. The engine matches a "
            "layer bind against the keysym alone, so this chord would be "
            "grabbed and could never fire")


def _scan(bs: Iterable[Bind], where: str, layers, seen: dict,
          prefix: str = "", mod: str = DEFAULT_MOD,
          bare: bool = False) -> list[str]:
    """`bare` marks a LAYER table (the layer's own binds, or a Mod sublayer's).

    Inside a layer the modifier is not part of the chord: the sublayer supplies
    it, and `LayerEngine._match_in_layer` compares the chord to the bare keysym
    of the event. Three components used to read these chords differently — this
    validator normalised them, `hotkeyd.layer_chords` grabbed them, and the
    engine could never match them (dotfiles-hwds.8). Refusing them here keeps
    the three in agreement by construction, and keeps the grab set narrow:
    grabbing `Shift+h` inside a layer would take a chord the daemon has no
    meaning for.
    """
    problems: list[str] = []
    for b in bs:
        if bare:
            p = _bare_problem(b, where, mod)
            if p:
                problems.append(p)
                continue
        try:
            k = _key(b, prefix, mod)
        except BindError as e:
            problems.append(f"{where}: {e}")
            continue
        # Checked before duplicate detection and in EVERY context — global
        # table, layer, held-modifier sublayer. A layer's grabs are live
        # exactly while the layer is active, which is the state panic exists
        # to escape, so "only the global table is reserved" is not a rule.
        if k[:2] in RESERVED_CHORDS:
            problems.append(
                f"{where}: chord {b.chord!r} is the panic chord "
                f"({PANIC_CHORD}), reserved for i3 — it is the only way back "
                "from a daemon that is dead or wrong, so no table may bind it")
        if k in seen:
            problems.append(
                f"{where}: chord {b.chord!r} is already bound in "
                f"{seen[k]} (duplicate binds double-fire)")
        else:
            seen[k] = where
        p = _command_problem(b, where)
        if p:
            problems.append(p)
        p = _device_problem(b, where)
        if p:
            problems.append(p)
        for a in actions_of(b):
            if isinstance(a, EnterLayer) and a.layer not in layers:
                problems.append(
                    f"{where}: chord {b.chord!r} enters layer "
                    f"{a.layer!r}, which does not exist")
    return problems


def _hold_problems(name: str, layer, mod: str) -> list[str]:
    """A hold layer's own declaration, checked under THIS display's `$mod`."""
    where = f"layer {name!r}"
    problems: list[str] = []
    if layer.hold is None:
        if layer.on_hold_release is not None:
            problems.append(
                f"{where}: on_hold_release is declared with no hold modifier, "
                "so nothing could ever dispatch it")
        return problems
    canon = canon_modifier(layer.hold, mod)
    if canon is None:
        problems.append(f"{where}: unknown hold modifier {layer.hold!r}")
        return problems
    if canon == "Shift":
        # Not a style rule. xrdp synthesises Shift around every character it
        # sends on `:10`, so a Shift HOLD is not observable in that session at
        # all — the same measurement that made the nav layer use Ctrl and not
        # Shift as its move modifier. A layer whose entire lifetime hangs off a
        # Shift release would end at an arbitrary moment there.
        problems.append(
            f"{where}: hold modifier {layer.hold!r} resolves to Shift; xrdp "
            "synthesises Shift around every character on :10, so a held Shift "
            "is not observable there and the layer's lifetime would be random")
    for a in ([] if layer.on_hold_release is None
              else (list(layer.on_hold_release)
                    if isinstance(layer.on_hold_release, (list, tuple))
                    else [layer.on_hold_release])):
        p = _action_problem(a, where, "on_hold_release")
        if p:
            problems.append(p)
    return problems


def validate(binds: Iterable[Bind] = None,
             layers: dict[str, Layer] = None,
             mod: str = DEFAULT_MOD) -> list[str]:
    """Return every problem found, as human-readable strings naming the chord.

    Empty list means the table is loadable. Reports ALL problems rather than
    the first: mid-migration you want the whole list, not one round trip per
    typo.
    """
    binds = BINDS if binds is None else binds
    layers = LAYERS if layers is None else layers

    problems = _scan(binds, "global", layers, {}, mod=mod)

    for name, layer in layers.items():
        seen: dict = {}
        problems += _scan(layer.binds, f"layer {name!r}", layers, seen,
                          mod=mod, bare=True)
        problems += _hold_problems(name, layer, mod)
        for label, mod_ in layer.mods.items():
            where = f"layer {name!r} mod {label!r}"
            try:
                canon = canon_modifier(mod_.modifier, mod)
            except Exception:  # pragma: no cover - defensive
                canon = None
            if canon is None:
                problems.append(
                    f"{where}: unknown modifier {mod_.modifier!r}")
                continue
            problems += _scan(mod_.binds, where, layers, seen, prefix=canon,
                              mod=mod, bare=True)
        if not layer.exit_keys:
            problems.append(
                f"layer {name!r} has no exit_keys — it could not be left")
        else:
            for k in layer.exit_keys:
                try:
                    mods, _ = parse_chord(k, mod)
                except BindError as e:
                    problems.append(f"layer {name!r} exit key: {e}")
                    continue
                if mods:
                    # An exit key is matched on the KEYSYM alone, on purpose: a
                    # layer must stay leavable with any modifier still held.
                    # `Ctrl+q` here is therefore not "q with Ctrl" — it is a
                    # chord nothing ever compares against, so the layer would be
                    # a trap in exactly the way exit_keys exist to prevent.
                    problems.append(
                        f"layer {name!r} exit key {k!r} carries modifiers "
                        f"({'+'.join(sorted(mods))}); exit keys are BARE "
                        "keysyms and already work with any modifier held")
    return problems


def load(binds: Iterable[Bind] = None,
         layers: dict[str, Layer] = None,
         mod: str = DEFAULT_MOD) -> tuple[list[Bind], dict]:
    """Validate and return the table, or raise BindError listing every problem."""
    binds = BINDS if binds is None else binds
    layers = LAYERS if layers is None else layers
    problems = validate(binds, layers, mod)
    if problems:
        raise BindError("\n".join(problems))
    return list(binds), layers


# --------------------------------------------------------------------------
# the table
# --------------------------------------------------------------------------

WS_SWITCH = "~/.local/bin/ws-switch.nu"
NAV_STEP = "5 px or 5 ppt"
# The switcher speaks to quickshell over the verbs qs-overlay.sh ALREADY
# exposes; the cutover adds no quickshell entry point (dotfiles-hwds.40).
QS_OVERLAY = "~/.dotfiles/quickshell/qs-overlay.sh"

# Direction -> (focus, move, resize) triples, shared by the letter keys and the
# arrow keys so the two can never drift apart. Resize directions match the
# standalone i3 `resize` mode: h/l shrink/grow width, k/j shrink/grow height.
_DIRS = {
    "h": ("left", "shrink width"),
    "j": ("down", "grow height"),
    "k": ("up", "shrink height"),
    "l": ("right", "grow width"),
}
_ARROWS = {"Left": "h", "Down": "j", "Up": "k", "Right": "l"}


def _nav_binds(kind: str) -> list[Bind]:
    out = []
    for key, (dirn, resize) in _DIRS.items():
        for k in (key, *[a for a, d in _ARROWS.items() if d == key]):
            if kind == "focus":
                out.append(Bind(k, f"focus {dirn}"))
            elif kind == "move":
                out.append(Bind(k, f"move {dirn}"))
            else:
                out.append(Bind(k, f"resize {resize} {NAV_STEP}"))
    return out


def _workspace_binds() -> list[Bind]:
    """The workspace group: switch / move-container / move-and-follow, indexed
    by DISPLAY POSITION rather than by i3 workspace name.

    One loop rather than three literal rows because the three rows differ only
    in the `ws-switch.nu` verb, and three hand-written blocks of eight is how
    `$mod+Ctrl+5` ends up saying `5 move` while `$mod+Shift+5` says `6 follow`.
    Same argument as `_nav_binds` above.

    The index is a position, not a name: `ws-switch.nu` resolves Nth-in-bar
    against the live workspace list, which is what makes named project
    workspaces reachable from a number row at all. That indirection is the
    reason these are `run()` and not i3 `workspace N` commands, and it is why
    the group keeps a nushell hop on its dispatch path — the same hop i3 had.
    """
    out = []
    for n in range(1, 9):
        out.append(Bind(f"$mod+{n}", run(f"{WS_SWITCH} {n}")))
        out.append(Bind(f"$mod+Ctrl+{n}", run(f"{WS_SWITCH} {n} move")))
        out.append(Bind(f"$mod+Shift+{n}", run(f"{WS_SWITCH} {n} follow")))
    return out


def _directional_binds() -> list[Bind]:
    """The global directional group: `$mod` + direction focuses, `$mod+Shift` +
    direction moves, for the hjkl letters and the arrow keys alike.

    Built from the SAME `_DIRS` / `_ARROWS` tables the nav layer uses, so the
    two spellings of "left" cannot drift apart and neither can the global binds
    and the layer that exists to do the same thing without a held modifier.
    That sharing is the point: `_nav_binds` and this function disagreeing would
    be invisible until someone used the one that was wrong.
    """
    out = []
    for key, (dirn, _resize) in _DIRS.items():
        for k in (key, *[a for a, d in _ARROWS.items() if d == key]):
            out.append(Bind(f"$mod+{k}", f"focus {dirn}"))
            out.append(Bind(f"$mod+Shift+{k}", f"move {dirn}"))
    return out


LAYERS: dict[str, Layer] = {
    # Navigation layer (was i3 `mode "nav"`, dotfiles-5u6m). Bare keys focus,
    # a held Ctrl moves, a held Alt resizes.
    #
    # Ctrl and not Shift is the move modifier for a portability reason that
    # outlives i3: xrdp synthesises Shift around every character it sends, so a
    # HELD Shift is not observable in that session at all. Ctrl and Alt cross
    # the wire as real holds.
    #
    # The `nop nav-move-on` marker binds this table replaces existed only
    # because i3 cannot report modifier state. The daemon sees the modifier
    # directly and publishes it on the state socket, so there is nothing to
    # encode here.
    "nav": Layer(
        binds=_nav_binds("focus"),
        mods={
            "move": Mod("Ctrl", tuple(_nav_binds("move"))),
            "resize": Mod("Mod1", tuple(_nav_binds("resize"))),
        },
        # q must work with a modifier still held — a layer you cannot leave
        # while holding Ctrl is a trap. The daemon matches exit keys against
        # the keysym regardless of held modifiers.
        exit_keys=["q", "Escape", "Return"],
    ),

    # Session actions (was i3 `mode "$mode_system"`, dotfiles-hwds.38). Entered
    # by `$mod+0`; one key, one action, back to default.
    #
    # ONE-SHOT because i3's block appended `, mode "default"` to every bind. A
    # persistent version of THIS layer would leave the keyboard in a state
    # where a bare `r` reboots the machine and a bare `p` powers it off.
    #
    # Verbatim from i3, including two things worth naming rather than quietly
    # improving mid-cutover:
    #   - `p` is shutdown, but the mode's own label promised `(Shift+s)hutdown`
    #     and no Shift+s bind ever existed. The label has been wrong, not the
    #     binding. Preserved as-is; the hint strip that shows it is the bar's,
    #     and correcting the two together is its own change.
    #   - every action is a `run()` of the system's `i3exit` script (Manjaro
    #     ships it at /usr/bin/i3exit), not an i3 command. i3 dispatched these
    #     through `exec` too, so nothing about them was ever WM-specific.
    #
    # BLAST RADIUS, stated because it is worse than any other layer's. Layer
    # entry needs a matched `$mod+0`, and dotfiles-ukyj is an OPEN, UNEXPLAINED
    # report of the daemon entering `nav` on :10 from an event nothing physical
    # produced. The same mechanism aimed at this layer puts the next keystroke
    # on a bare `r`/`p`. That exposure is not NEW — i3's mode had the identical
    # shape and the identical bare keys — but it moves here with the binds, and
    # ukyj's severity should be read in that light.
    "system": Layer(
        binds=[
            Bind("l", run("i3exit lock")),
            Bind("e", run("i3exit logout")),
            Bind("u", run("i3exit switch_user")),
            Bind("s", run("i3exit suspend")),
            Bind("h", run("i3exit hibernate")),
            Bind("r", run("i3exit reboot")),
            Bind("p", run("i3exit shutdown")),
        ],
        exit_keys=["q", "Escape", "Return"],
        one_shot=True,
    ),

    # Alt-tab switcher (was quickshell/qs-keymon.py + four `nop` grabs in i3,
    # dotfiles-hwds.40). The marquee case for the whole daemon: the gesture
    # carries STATE between a press and a release — cycle on repeated Tab while
    # $mod stays down, commit when $mod comes up — which i3 cannot express in
    # any form. The old answer was a second event mechanism running beside i3:
    # a python-xlib XI2 RAW listener that saw every keystroke on the session
    # and drove the overlay directly. This layer is that feature with one
    # mechanism instead of two.
    #
    # WHAT ENDS THE LAYER, and why each one exists:
    #   $mod release -> `on_hold_release`, the primary gesture. Observed by
    #     asking the server, never by belief — see `hold` on `Layer` and
    #     `LayerEngine.reconcile_hold_layer`.
    #   Escape       -> cancels the overlay AND leaves. It cannot be an
    #     exit_key: exit keys are matched before any bind and dispatch nothing,
    #     so Escape would drop the layer and leave the overlay on screen.
    #   Return       -> the same shape, committing instead of cancelling.
    #   space        -> hands off to the overlay. Search means TYPING, and
    #     typing means releasing $mod, which would otherwise commit instantly
    #     and end the search before the first character. Leaving the layer
    #     hands every subsequent key to the (focused) overlay, which is exactly
    #     what the pre-cutover behaviour was: keymon's search branch was gated
    #     to `mode === "switcher"`, so it stopped acting once search began.
    #   q            -> the exit_keys FLOOR. Dispatches nothing and leaves the
    #     overlay up, deliberately: it is the escape hatch for a layer that is
    #     somehow still up with nothing held, and once the layer is gone the
    #     overlay's own Escape (it is focused and holds no keyboard grab) works
    #     normally again.
    #
    # `Tab` and `w` are both `switcher next` because they always were: keymon
    # treated keycodes 23 and 25 identically. `ISO_Left_Tab` is what X delivers
    # for Shift+Tab, and it is the least trustworthy bind in the group on the
    # xrdp `:10` display, where Shift is synthesised around every character.
    "switcher": Layer(
        binds=[
            Bind("Tab", run(f"{QS_OVERLAY} switcher")),
            Bind("w", run(f"{QS_OVERLAY} switcher")),
            Bind("ISO_Left_Tab", run(f"{QS_OVERLAY} switcher-prev")),
            Bind("space", (run(f"{QS_OVERLAY} switcher-search"),
                           exit_layer())),
            Bind("Escape", (run(f"{QS_OVERLAY} switcher-cancel"),
                            exit_layer())),
            Bind("Return", (run(f"{QS_OVERLAY} switcher-confirm"),
                            exit_layer())),
        ],
        hold="$mod",
        on_hold_release=run(f"{QS_OVERLAY} switcher-confirm"),
        exit_keys=["q"],
    ),
}

BINDS: list[Bind] = [
    # SCOPED TO THE T6 CUTOVER, DELIBERATELY. sp020's anti-pattern is that a
    # chord must not exist in both i3 and this table at any commit boundary —
    # a chord bound in both double-fires. Only the nav entry chord is here,
    # because nav is the group T6 migrates.
    #
    # The focus/move and workspace groups that used to sit here were removed:
    # they are still live in i3/config.common, so listing them here meant the
    # daemon would grab and serve them the moment autostart fired on :10, where
    # $mod is Mod1 and the Mod4 forms were free. Reintroduce each group in the
    # SAME commit that deletes it from the i3 config, never before.
    Bind("$mod+o", enter_layer("nav")),

    # ---- THE ENTRY-POINT GROUP (dotfiles-hwds.33) -------------------------
    # The four binds `i3/config` carried itself rather than delegating to
    # `config.common` — terminal, launcher, project picker, bar restart. They
    # sat in the entry point because they are the ones whose COMMAND (not
    # keysym) differs per session type, and an entry point was the only i3
    # scope that could express that.
    #
    # SCOPE: the two sessions this host runs — native `:0` and the xrdp `:10`
    # that `xrdp/xinitrc` starts with a bare `exec i3`. Both load `i3/config`,
    # so both are served from here now. `i3/config-xrdp` is a SEPARATE entry
    # point for proot Arch on Android and is deliberately untouched — it keeps
    # its own four binds, and nothing double-fires because that session starts
    # no daemon (it includes no `config.d` overlay, and `hotkeyd.sh start` is
    # autostarted only from `native.conf` / `wsl.conf`). Migrating proot needs
    # that autostart wired first; it is not in this change.
    #
    # Why the daemon rather than pushing them down into the config.d overlays:
    # MEASURED, an i3 variable set in an included overlay is INVISIBLE to the
    # file that included it — `gaps top $v` with `$v` set in the include fails
    # byte-identically to a genuinely undefined var. A var and the binds using
    # it must therefore share one file, and since i3 treats a duplicate
    # keybinding as a config ERROR rather than last-wins, that would have meant
    # a private copy of all four in native.conf AND wsl.conf. The daemon has no
    # such limit: it resolves `$mod` per display at startup, so this one table
    # means Super on :0 and Alt on :10.
    #
    # NOT MIGRATED, deliberately: `$mod+Shift+c` (`reload, exec ...`). It is a
    # recovery key — the way back from a bad config — and putting i3 reload
    # behind the daemon is the loss that 62075b7d just undid for `restart`.
    # It stays in i3/config, where a dead daemon cannot take it away.
    Bind("$mod+Return", run("~/.local/bin/wm-launch-terminal st")),
    Bind("$mod+d", run("~/.dotfiles/quickshell/qs-overlay.sh launcher")),
    Bind("$mod+p", run("~/.dotfiles/quickshell/qs-overlay.sh projects")),
    # $mod+Shift+d (bar restart, on_release) was migrated here and then REMOVED
    # when the restart verbs consolidated onto the $mod+Shift+r hammer, which
    # restarts the bar as one of its three steps. A chord doing a strict subset
    # of another chord's work is the kind of thing that survives for years
    # because nobody is sure what still depends on it.
    #
    # Dropping it also took the daemon's ONLY on_release bind with it, which
    # closes this table's exposure to dotfiles-hwds.24: xrdp may deliver each
    # keystroke on :10 as release-press-release, and nothing in the engine
    # dedups releases (`_is_repeat` guards the press path only), so an
    # on_release bind there could fire twice per press. The remaining
    # --release bind in the system, $mod+Print, is i3-owned and unaffected.
    # Re-adding any on_release bind here reopens that, unmeasured.

    # ---- THE WORKSPACE GROUP (dotfiles-hwds.34) ---------------------------
    # 26 chords: the number row in three rows (switch / move / move+follow),
    # plus the two `workspace next|prev` arrows that share the group's
    # `$mod+Ctrl` shape.
    #
    # GRAB-OWNERSHIP CLOSURE, checked under both `$mod` resolutions: nothing
    # else in the i3 tree binds a digit or `$mod+Ctrl+Left|Right` under either
    # Mod4 or Mod1. `$mod+0` is NOT in the group — it opens i3's
    # `mode "$mode_system"`, so migrating it means porting a whole i3 mode to a
    # layer, not moving a bind. It stays with i3 and the closure stops at 8.
    #
    # `$mod+Ctrl+Left|Right` are i3 commands, not `run()`: `workspace
    # next|prev` needs no index resolution, so routing them through
    # `ws-switch.nu` would add a nushell start to a bind that never needed one.
    # They join the group because they collide with its `$mod+Ctrl` shape and
    # a cutover is scoped by grab closure, not by action type.
    #
    # THE `$mod+Shift+<digit>` ROW IS THE RISK ROW ON :10. xrdp synthesises
    # Shift around every character it sends, which is exactly why the nav layer
    # uses Ctrl and not Shift as its move modifier. The difference here is that
    # these are PASSIVE GRABS on (keycode, mask) rather than modifier-state
    # reads — the same mechanism i3 has been serving this row with on :10 all
    # along — so parity is expected, not assumed. It is the first thing to
    # check on the live :10 session after the cutover.
    *_workspace_binds(),
    Bind("$mod+Ctrl+Right", "workspace next"),
    Bind("$mod+Ctrl+Left", "workspace prev"),

    # ---- THE LAYOUT GROUP (dotfiles-hwds.36) ------------------------------
    # How a container is ARRANGED: border style, split orientation, layout
    # mode, fullscreen, sticky, scratchpad, and focus-parent. Twelve chords,
    # every one a plain i3 command — no `run()`, no per-display value, so this
    # group needs nothing from the daemon that i3 was not already giving it.
    # It migrates because sp020 is moving the table, not because the daemon
    # does these better.
    #
    # GRAB-OWNERSHIP CLOSURE, checked under both resolutions. Three i3 binds
    # sit on the same KEYSYMS and are deliberately NOT here, because closure is
    # by chord and a passive grab matches its mask exactly (plus the lock-bit
    # variants): `$mod+Ctrl+t` (picom), `$mod+Shift+e` (exit nagbar) and
    # `$mod+Shift+s` (region screenshot) are different chords from `$mod+t`,
    # `$mod+e` and `$mod+s`, so i3 keeps serving them with no contest.
    #
    # `$mod+Shift+q` (kill) is NOT in the group, for the same reason
    # `$mod+Shift+c` (reload) was left out of the entry-point one: it is a
    # recovery key. Grabs die with the daemon, so a bind that exists to deal
    # with a window that is already misbehaving is worth keeping in the engine
    # that cannot lose its grabs. Killing a wedged fullscreen window must not
    # depend on the daemon being healthy.
    Bind("$mod+u", "border none"),
    Bind("$mod+y", "border pixel 4"),
    # Verbatim from i3, `bellow` typo and all. A cutover moves a bind; it does
    # not quietly reword the notification the user has been reading for years.
    Bind("$mod+s", "split h;exec notify-send 'tile side'"),
    Bind("$mod+b", "split v;exec notify-send 'tile bellow'"),
    Bind("$mod+q", "split toggle"),
    Bind("$mod+z", "fullscreen toggle"),
    Bind("$mod+t", "layout tabbed"),
    Bind("$mod+e", "layout toggle split"),
    Bind("$mod+Shift+p", "sticky toggle"),
    Bind("$mod+a", "focus parent"),
    Bind("$mod+Shift+minus", "move scratchpad"),
    Bind("$mod+minus", "scratchpad show"),

    # ---- THE DIRECTIONAL GROUP (dotfiles-hwds.37) -------------------------
    # 16 chords: `$mod`+hjkl and `$mod`+arrows focus, the `$mod+Shift` forms of
    # both move. THIS IS THE GROUP TASK 6 SHIPPED AND REVERTED (fd9e9f2), so it
    # is worth being explicit about why it is safe now and was not then.
    #
    # T6 failed because the table HARDCODED Mod4. On :10 `$mod` is Mod1, so the
    # Mod4 forms were free: the daemon grabbed and served them while i3 went on
    # serving the Mod1 forms, and the split was invisible on :0 where the two
    # agree. `$mod` resolves per display now (dotfiles-hwds.7), from the same
    # `i3wm.mod` X resource i3 reads, so one table means Mod4 on :0 and Mod1 on
    # :10 by construction rather than by hand.
    #
    # The `$mod+Shift+<letter>` half was the other open risk: xrdp wraps every
    # character it sends in a synthetic Shift, which is exactly why the nav
    # layer uses Ctrl and not Shift as its move modifier. MEASURED on the live
    # :10 session with a real RDP client (dotfiles-hwds.35) — six presses of a
    # `$mod+Shift+<char>` bind produced six dispatches, tightest gap 1.88s, no
    # sub-100ms pair. A passive grab matches (keycode, mask) and is not a
    # modifier-STATE read, which is what the nav layer's constraint was about.
    #
    # Closure checked under both resolutions: `$mod+Ctrl+Left|Right` is already
    # this table's (workspace prev/next), nav's bare hjkl and arrows are
    # layer-scoped rather than global, and nothing else in the i3 tree binds
    # these keysyms.
    #
    # The nav LAYER stays exactly as it is. It is not made redundant by this:
    # nav does the same motions with NO modifier held, which is the whole
    # ergonomic point, and it also carries the resize sublayer that has no
    # global spelling at all.
    *_directional_binds(),

    # ---- THE SCREENSHOT GROUP (dotfiles-hwds.39) --------------------------
    # Four chords: the three `i3-scrot` captures and the quickshell region
    # picker. Closure checked under both `$mod` resolutions — nothing else in
    # the i3 tree binds `Print` under any mask, and `$mod+Shift+s` is a
    # different chord from the layout group's `$mod+s` (a passive grab matches
    # its mask exactly, plus the lock variants).
    #
    # `Print` IS THE FIRST GLOBAL BIND WITH NO MODIFIER AT ALL. Its base mask is
    # 0, and the four lock variants are grabbed off that — the same path a
    # modifier chord takes, so NumLock does not hide it.
    #
    # THE TWO on_release BINDS. This table deliberately had none after
    # `$mod+Shift+d` left (see the entry-point note above), because
    # dotfiles-hwds.24 measured xrdp delivering every character on `:10` as
    # release-press-release — a leading release with no press before it, which
    # would fire an on_release bind twice per keypress. That is closed by
    # construction now: the engine only matches a release for a key it saw go
    # down (`layers.handle`), so the orphan release is dropped. Migrating these
    # two is what made that guard worth building rather than a hypothetical.
    #
    # `--release` is kept rather than quietly converted to a press bind: these
    # capture the screen, and firing while the user still has the key down is a
    # different behaviour, not a tidier one.
    #
    # THE i3 MODES STAY WITH i3. `mode "screenshot"` / `"screenshot-drag"` are
    # not a keybind group — qs-screenshot.sh and qs-region.py enter them over
    # i3-msg so the bar paints a hint strip, and their only bindsyms are
    # dead-overlay Escape/q fallbacks. Consequence worth stating: while either
    # mode is up the engine refuses layer entry (`_i3_owns_the_keyboard`), so
    # nav cannot be entered mid-capture. That is the correct arbitration — the
    # region selector holds a pointer+keyboard grab and owns the keyboard.
    Bind("Print", run("i3-scrot")),
    Bind("$mod+Print", run("i3-scrot -w"), on_release=True),
    Bind("$mod+Shift+Print", run("i3-scrot -s"), on_release=True),
    Bind("$mod+Shift+s", run("~/.dotfiles/quickshell/qs-screenshot.sh")),

    # ---- THE SYSTEM MODE (dotfiles-hwds.38) -------------------------------
    # One chord, because the seven session actions behind it are a LAYER (see
    # LAYERS["system"] above) rather than seven global binds. i3 expressed the
    # same shape as `mode "$mode_system"`.
    #
    # `$mod+0` is why the workspace group stops at 8: the number row's tenth
    # key has never been a workspace.
    Bind("$mod+0", enter_layer("system")),

    # ---- THE ALT-TAB SWITCHER (dotfiles-hwds.40) --------------------------
    # Two chords, both entering LAYERS["switcher"] (see there for the whole
    # gesture). The action is a TUPLE because entry has to do two things at
    # once: open the overlay and take the layer. Opening it is what the first
    # press means — `switcher next` on a hidden overlay shows it with the
    # previous MRU window preselected, which is the classic alt-tab toggle.
    #
    # WHAT LEAVES i3 WITH THEM: four `nop` grabs. `native.conf` spelled them as
    # Mod4+ and Mod1+ PAIRS and `wsl.conf` as the `$mod+` forms, because the
    # grab existed only to stop the key leaking into the focused window while
    # the raw listener did the real work — nothing was dispatched, so binding
    # both modifiers cost nothing.
    #
    # THAT PAIR DOES NOT SURVIVE, and it is a real behaviour change on `:0`:
    # `$mod` resolves to ONE modifier per display, so the native session serves
    # Super+Tab and Alt+Tab now leaks to the focused window instead of opening
    # the switcher. A static table cannot say "Mod1 as well, unless Mod1 is
    # already what $mod means" — on `:10` the second form would be a duplicate
    # chord and the validator would (correctly) refuse the table. Filed as
    # dotfiles-y2ju rather than papered over.
    #
    # GRAB-OWNERSHIP CLOSURE, checked under both resolutions: after the four
    # `nop` lines are deleted, nothing in the i3 tree binds Tab or w under any
    # mask. The layer's own grab set adds `$mod+`-masked and `$mod+Shift+`
    # masked forms of its keys (see hotkeyd.layer_chords for why) — of those,
    # only `$mod+Return` and `$mod+q` collide with anything, and both are THIS
    # table's own binds, shadowed by the layer exactly while it is up.
    Bind("$mod+Tab", (run(f"{QS_OVERLAY} switcher"),
                      enter_layer("switcher"))),
    Bind("$mod+w", (run(f"{QS_OVERLAY} switcher"),
                    enter_layer("switcher"))),
]
