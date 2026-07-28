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


# --------------------------------------------------------------------------
# table shape
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Bind:
    chord: str
    action: Action
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
                          mod=mod, bare=True)
        for label, mod_ in layer.mods.items():
            where = f"layer {name!r} mod {label!r}"
            try:
                canon = MODIFIER_ALIASES.get(str(mod_.modifier).strip().lower())
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
]
