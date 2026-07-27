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

# The layer's SECOND modifier, for a sublayer that must not collide with `$mod`.
# It cannot be a fixed modifier: nav's resize layer used a literal Mod1, which is
# free on :0 but IS `$mod` on the xrdp session — where i3 owns Mod1+hjkl as its
# focus binds, so the daemon got BadAccess on every one of them and Alt+h did
# i3's focus instead of the layer's resize. `$altmod` is "Alt, unless Alt is
# already $mod, in which case Super" — always the one of the pair that the WM
# does not own.
ALT_TOKEN = "$altmod"


def alt_mod_for(mod: str = DEFAULT_MOD) -> str:
    return "Mod4" if str(mod).strip().lower() in ("mod1", "alt") else "Mod1"


def resolve_mod_name(name: str, mod: str = DEFAULT_MOD) -> str:
    """Resolve a modifier token to a concrete modifier name."""
    low = str(name).strip().lower()
    if low == MOD_TOKEN:
        return str(mod)
    if low == ALT_TOKEN:
        return alt_mod_for(mod)
    return str(name)


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
        if name in (MOD_TOKEN, ALT_TOKEN):
            name = resolve_mod_name(name, mod).lower()
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


# --------------------------------------------------------------------------
# table shape
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Bind:
    chord: str
    action: Action
    on_release: bool = False


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


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

def _command_problem(bind: Bind, where: str) -> str | None:
    a = bind.action
    if isinstance(a, str) and not a.strip():
        return f"{where}: chord {bind.chord!r} has an empty command"
    if isinstance(a, Run) and not a.cmd.strip():
        return f"{where}: chord {bind.chord!r} has an empty run() command"
    return None


def _key(bind: Bind, prefix: str = "", mod: str = DEFAULT_MOD) -> tuple:
    """Duplicate-detection identity. `on_release` is part of it: press and
    release on one chord are different events, not a collision (i3 does the
    same with `--release`)."""
    chord = f"{prefix}+{bind.chord}" if prefix else bind.chord
    return normalize_chord(chord, mod) + (bind.on_release,)


def _scan(bs: Iterable[Bind], where: str, layers, seen: dict,
          prefix: str = "", mod: str = DEFAULT_MOD) -> list[str]:
    problems: list[str] = []
    for b in bs:
        try:
            k = _key(b, prefix, mod)
        except BindError as e:
            problems.append(f"{where}: {e}")
            continue
        if k in seen:
            problems.append(
                f"{where}: chord {b.chord!r} is already bound in "
                f"{seen[k]} (duplicate binds double-fire)")
        else:
            seen[k] = where
        p = _command_problem(b, where)
        if p:
            problems.append(p)
        if isinstance(b.action, EnterLayer) and b.action.layer not in layers:
            problems.append(
                f"{where}: chord {b.chord!r} enters layer "
                f"{b.action.layer!r}, which does not exist")
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
                          mod=mod)
        for label, mod_ in layer.mods.items():
            where = f"layer {name!r} mod {label!r}"
            try:
                canon = MODIFIER_ALIASES.get(
                    resolve_mod_name(mod_.modifier, mod).strip().lower())
            except Exception:  # pragma: no cover - defensive
                canon = None
            if canon is None:
                problems.append(
                    f"{where}: unknown modifier {mod_.modifier!r}")
                continue
            problems += _scan(mod_.binds, where, layers, seen, prefix=canon,
                              mod=mod)
        if not layer.exit_keys:
            problems.append(
                f"layer {name!r} has no exit_keys — it could not be left")
        else:
            for k in layer.exit_keys:
                try:
                    parse_chord(k, mod)
                except BindError as e:
                    problems.append(f"layer {name!r} exit key: {e}")
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

# Used by the workspace group when it migrates (not yet — see BINDS below).
WS_SWITCH = "~/.local/bin/ws-switch.nu"
NAV_STEP = "5 px or 5 ppt"

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
            # $altmod, not a literal Mod1: on the xrdp session $mod IS Mod1,
            # and i3 owns Mod1+hjkl there as its focus binds — a literal Mod1
            # made the whole resize layer unreachable on that display.
            "resize": Mod("$altmod", tuple(_nav_binds("resize"))),
        },
        # q must work with a modifier still held — a layer you cannot leave
        # while holding Ctrl is a trap. The daemon matches exit keys against
        # the keysym regardless of held modifiers.
        exit_keys=["q", "Escape", "Return"],
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
]
