"""Loader tests for the hotkeyd bind table (sp020 Task 2, dotfiles-yvxs).

These replace what i3's own parser used to catch for free: duplicate binds,
dangling layer references, empty commands. Every rejection case asserts the
MESSAGE names the offending chord — a bare non-zero exit tells the person
mid-migration nothing about which line to fix.

Run: pytest hotkeyd/test_binds.py   (or hotkeyd/test-hotkeyd.sh)
"""
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

import binds as B  # noqa: E402


# --------------------------------------------------------------------------
# the shipped table
# --------------------------------------------------------------------------

def test_shipped_table_validates_clean():
    assert B.validate(B.BINDS, B.LAYERS) == []


def test_shipped_table_has_the_nav_layer_with_three_layers():
    nav = B.LAYERS["nav"]
    assert set(nav.mods) == {"move", "resize"}
    assert nav.mods["move"].modifier == "Ctrl"
    assert nav.mods["resize"].modifier == "Mod1"
    assert nav.exit_keys, "a layer with no exit keys cannot be left"


def test_nav_layers_do_not_duplicate_movement_binds():
    """The retired twin mode duplicated every movement bind. The three layers
    must be distinct effective chords, not three copies of the same table."""
    nav = B.LAYERS["nav"]
    base = {B.normalize_chord(b.chord) for b in nav.binds}
    move = {B.normalize_chord(f"{nav.mods['move'].modifier}+{b.chord}")
            for b in nav.mods["move"].binds}
    resize = {B.normalize_chord(f"{nav.mods['resize'].modifier}+{b.chord}")
              for b in nav.mods["resize"].binds}
    assert base & move == set()
    assert base & resize == set()
    assert move & resize == set()


def test_nav_bare_keys_focus_ctrl_moves_alt_resizes():
    nav = B.LAYERS["nav"]
    def cmd(bs, key):
        return next(b.action for b in bs if b.chord == key)
    assert cmd(nav.binds, "h") == "focus left"
    assert cmd(nav.mods["move"].binds, "h") == "move left"
    assert cmd(nav.mods["resize"].binds, "h") == \
        "resize shrink width 5 px or 5 ppt"


@pytest.mark.parametrize("arrow,letter", [
    ("Left", "h"), ("Down", "j"), ("Up", "k"), ("Right", "l"),
])
def test_arrow_keys_do_the_same_thing_as_their_letter(arrow, letter):
    """Letters and arrows come from one shared table so they cannot drift, but
    nothing asserted the MAPPING — swapping _ARROWS so Left focused right
    survived both suites (found during audit). Checked in all three nav layers
    plus the global $mod binds."""
    nav = B.LAYERS["nav"]
    def cmd(bs, key):
        return next(b.action for b in bs if b.chord == key)
    assert cmd(nav.binds, arrow) == cmd(nav.binds, letter)
    for label in ("move", "resize"):
        bs = nav.mods[label].binds
        assert cmd(bs, arrow) == cmd(bs, letter), label
    # The global $mod movement group lives in i3 until its own cutover commit,
    # so there is nothing to check here beyond the nav layers.


@pytest.mark.parametrize("n", range(1, 9))
def test_every_workspace_index_has_all_three_verbs_on_the_right_chord(n):
    """The workspace group carries the same index across three modifier shapes,
    so the failure it is exposed to is a SILENT OFF-BY-ONE: `$mod+Ctrl+5`
    running `5 move` while `$mod+Shift+5` runs `6 follow`. Nothing else in the
    system would notice — both are valid commands and both move a container
    somewhere.

    This is the test that replaced `test_workspace_group_has_not_been_migrated_yet`
    at the cutover (dotfiles-hwds.34). That one asserted the group was still in
    i3 and was written to be rewritten here; the anti-pattern it stood in for is
    covered generally, and derived rather than by roster, by
    `test_no_chord_is_owned_by_both_i3_and_the_daemon` below.
    """
    cmds = {b.chord: b.action.cmd for b in B.BINDS
            if isinstance(b.action, B.Run) and "ws-switch" in b.action.cmd}
    assert cmds[f"$mod+{n}"].endswith(f" {n}")
    assert cmds[f"$mod+Ctrl+{n}"].endswith(f" {n} move")
    assert cmds[f"$mod+Shift+{n}"].endswith(f" {n} follow")


def test_the_workspace_group_stops_at_8_because_mod_0_is_an_i3_mode():
    """`$mod+0` opens i3's `mode "$mode_system"` (lock / exit / suspend /
    reboot / shutdown). Extending the loop to `range(1, 11)` on the reasonable-
    looking grounds that a number row has ten keys would grab it away from i3
    and bind it to a tenth workspace that does not exist — losing the only
    keyboard route to lock and shutdown, which is a bad thing to discover by
    pressing it."""
    ws_keys = {B.parse_chord(b.chord)[1] for b in B.BINDS
               if isinstance(b.action, B.Run) and "ws-switch" in b.action.cmd}
    assert ws_keys == set("12345678")


@pytest.mark.parametrize("a,b", [
    ("Mod4+q", "Super+q"),
    ("Ctrl+Shift+h", "Shift+Control+h"),
    ("Mod1+j", "Alt+j"),
])
def test_modifier_aliases_and_order_fold_to_the_same_chord(a, b):
    assert B.normalize_chord(a) == B.normalize_chord(b)


def test_distinct_chords_do_not_fold():
    assert B.normalize_chord("Mod4+q") != B.normalize_chord("Mod4+Shift+q")


# --------------------------------------------------------------------------
# rejections — each must name the offending chord
# --------------------------------------------------------------------------

def test_duplicate_chord_in_a_layer_is_rejected_by_name():
    layers = {"nav": B.Layer(
        binds=[B.Bind("h", "focus left"), B.Bind("h", "focus right")],
        exit_keys=["q"])}
    problems = B.validate([], layers)
    assert problems, "duplicate chord must be reported"
    assert any("h" in p and "nav" in p for p in problems), problems


def test_duplicate_folds_across_alias_spellings():
    """Super+d and Mod4+d are the same chord; declaring both is a duplicate."""
    problems = B.validate([B.Bind("Super+d", "nop a"),
                           B.Bind("Mod4+d", "nop b")], {})
    assert any("d" in p for p in problems), problems


def test_duplicate_between_generated_and_handwritten_chord_is_rejected():
    generated = [B.Bind(f"Mod4+{n}", f"exec ws-switch {n}") for n in range(1, 9)]
    problems = B.validate(generated + [B.Bind("Mod4+3", "exec something-else")],
                          {})
    assert any("Mod4+3" in p or "3" in p for p in problems), problems


def test_modifier_layer_chord_colliding_with_a_base_chord_is_rejected():
    layers = {"nav": B.Layer(
        binds=[B.Bind("Ctrl+h", "focus left")],
        mods={"move": B.Mod("Ctrl", [B.Bind("h", "move left")])},
        exit_keys=["q"])}
    problems = B.validate([], layers)
    assert any("h" in p for p in problems), problems


def test_reference_to_a_missing_layer_is_rejected_by_name():
    problems = B.validate([B.Bind("Mod4+o", B.enter_layer("nope"))], {})
    assert any("nope" in p for p in problems), problems


def test_reference_to_an_existing_layer_is_accepted():
    layers = {"nav": B.Layer(binds=[B.Bind("h", "focus left")],
                             exit_keys=["q"])}
    assert B.validate([B.Bind("Mod4+o", B.enter_layer("nav"))], layers) == []


@pytest.mark.parametrize("cmd", ["", "   ", "\t\n"])
def test_empty_or_whitespace_command_is_rejected(cmd):
    problems = B.validate([B.Bind("Mod4+x", cmd)], {})
    assert any("Mod4+x" in p for p in problems), problems


@pytest.mark.parametrize("cmd", ["", "  "])
def test_empty_run_command_is_rejected(cmd):
    """The Run() branch of _command_problem was uncovered — deleting it left the
    whole suite green (found by the T2 audit's own mutation battery)."""
    problems = B.validate([B.Bind("Mod4+x", B.run(cmd))], {})
    assert any("Mod4+x" in p for p in problems), problems


def test_invalid_exit_key_chord_is_rejected():
    """exit_keys are chords too; a typo there is a key that cannot leave the
    layer. Also previously uncovered per the T2 audit."""
    layers = {"nav": B.Layer(binds=[B.Bind("h", "focus left")],
                             exit_keys=["q", "NotAKey"])}
    problems = B.validate([], layers)
    assert any("NotAKey" in p for p in problems), problems


@pytest.mark.parametrize("chord", ["Mod4+37", "105", "Ctrl+64"])
def test_keycode_in_a_chord_is_rejected(chord):
    """poc013: Super_L is keycode 133 on :0 but 115 on :10 — the same key.
    Keycodes in the table would silently bind the wrong key per session."""
    problems = B.validate([B.Bind(chord, "nop x")], {})
    assert any(chord in p for p in problems), problems
    # Assert "keycode", NOT "keysym": the word "keysym" appears in BOTH the
    # dedicated keycode branch and the generic _KEYSYMS allowlist fallback, so
    # asserting it passed even with the keycode branch deleted. Audit mutation
    # testing caught that. This matters most when dotfiles-7yk3 replaces the
    # static allowlist with live-keymap resolution: the masking fallback goes
    # away, and only this assertion still guards the branch.
    assert any("keycode" in p.lower() for p in problems), problems


@pytest.mark.parametrize("chord", ["Mod4+1", "Mod4+Shift+8", "Mod4+Ctrl+3"])
def test_single_digit_keys_are_keysyms_not_keycodes(chord):
    """`$mod+1` is the digit-one key — that is how the workspace binds have
    always read. Only multi-digit keys (37, 105, 133) are keycode typos.
    Rejecting single digits would have made the workspace loop unexpressible."""
    assert B.validate([B.Bind(chord, "nop ws")], {}) == []


def test_unknown_modifier_is_rejected_by_name():
    problems = B.validate([B.Bind("Hyper+x", "nop x")], {})
    assert any("Hyper" in p for p in problems), problems


def test_layer_without_exit_keys_is_rejected():
    layers = {"trap": B.Layer(binds=[B.Bind("h", "focus left")], exit_keys=[])}
    problems = B.validate([], layers)
    assert any("trap" in p for p in problems), problems


def test_unknown_modifier_on_a_mod_layer_is_rejected():
    layers = {"nav": B.Layer(
        binds=[B.Bind("h", "focus left")],
        mods={"move": B.Mod("Hyper", [B.Bind("j", "move down")])},
        exit_keys=["q"])}
    problems = B.validate([], layers)
    assert any("Hyper" in p for p in problems), problems


def test_empty_chord_is_rejected():
    problems = B.validate([B.Bind("Mod4+", "nop x")], {})
    assert problems


# --------------------------------------------------------------------------
# layer chords are BARE keysyms (dotfiles-hwds.8)
# --------------------------------------------------------------------------
# Three components read a layer bind's chord and used to disagree: validate()
# normalised it fully, hotkeyd.layer_chords() grabbed it fully, and
# LayerEngine._match_in_layer compares `b.chord == ev.key` against a bare
# keysym. So any layer chord containing a `+` validated, got grabbed, and could
# never fire — validated-but-dead, the exact class this validator exists to
# prevent. Rejecting them here is the fix: a held modifier inside a layer is
# spelled as a Mod sublayer, which is the mechanism the design already has.


@pytest.mark.parametrize("chord", ["Shift+h", "Ctrl+h", "$mod+h", "Mod4+h"])
def test_a_layer_bind_with_a_modifier_is_rejected_by_name(chord):
    layers = {"nav": B.Layer(binds=[B.Bind(chord, "focus left")],
                             exit_keys=["q"])}
    problems = B.validate([], layers)
    assert any(chord in p for p in problems), problems
    assert any("sublayer" in p.lower() or "bare" in p.lower()
               for p in problems), \
        f"the message must say what to do instead: {problems}"


def test_a_modifier_sublayer_bind_with_its_own_modifier_is_rejected():
    """A Mod sublayer already contributes the modifier — `Ctrl+h` inside the
    Ctrl sublayer would be grabbed as Ctrl+Ctrl+h and matched as neither."""
    layers = {"nav": B.Layer(
        binds=[B.Bind("h", "focus left")],
        mods={"move": B.Mod("Ctrl", (B.Bind("Ctrl+j", "move down"),))},
        exit_keys=["q"])}
    problems = B.validate([], layers)
    assert any("Ctrl+j" in p for p in problems), problems


def test_a_modifier_on_an_exit_key_is_rejected_by_name():
    """exit_keys are matched on the KEYSYM alone, deliberately — a layer must
    stay leavable with any modifier still held. So `Ctrl+q` as an exit key is
    not 'q with Ctrl', it is a chord the engine will never look at."""
    layers = {"nav": B.Layer(binds=[B.Bind("h", "focus left")],
                             exit_keys=["Ctrl+q"])}
    problems = B.validate([], layers)
    assert any("Ctrl+q" in p for p in problems), problems


def test_bare_layer_chords_and_exit_keys_are_still_accepted():
    """The control. An over-strict rule that rejected bare keys too would pass
    every assertion above and break the whole feature."""
    layers = {"nav": B.Layer(
        binds=[B.Bind("h", "focus left"), B.Bind("Left", "focus left")],
        mods={"move": B.Mod("Ctrl", (B.Bind("h", "move left"),))},
        exit_keys=["q", "Escape", "Return"])}
    assert B.validate([], layers) == []


def test_global_binds_may_still_carry_modifiers():
    """The rule is scoped to layer tables. Global binds are matched against
    (mods, key) and MUST keep their modifiers — $mod+o is the entry chord."""
    assert B.validate([B.Bind("$mod+o", "nop x"),
                       B.Bind("Ctrl+Shift+F1", "nop y")], {}) == []


# --------------------------------------------------------------------------
# things that must NOT be rejected (guards against over-strict validation)
# --------------------------------------------------------------------------

def test_empty_layers_is_valid():
    assert B.validate([B.Bind("Mod4+q", "kill")], {}) == []


def test_unicode_command_is_accepted():
    assert B.validate([B.Bind("Mod4+n", "exec notify-send 'héllo → wörld ✓'")],
                      {}) == []


def test_same_chord_in_two_different_layers_is_valid():
    """Layers are separate namespaces — `h` in nav and `h` in resize coexist."""
    layers = {
        "nav": B.Layer(binds=[B.Bind("h", "focus left")], exit_keys=["q"]),
        "resize": B.Layer(binds=[B.Bind("h", "resize shrink width 5 px")],
                          exit_keys=["q"]),
    }
    assert B.validate([], layers) == []


def test_release_bind_and_press_bind_on_the_same_chord_coexist():
    """$mod+Shift+d has a --release variant in i3 today; press and release are
    different events, not a duplicate."""
    problems = B.validate([B.Bind("Mod4+Shift+d", "nop press"),
                           B.Bind("Mod4+Shift+d", "nop release",
                                  on_release=True)], {})
    assert problems == []


def test_callable_action_is_accepted():
    assert B.validate([B.Bind("Mod4+F1", lambda ev: None)], {}) == []


# --------------------------------------------------------------------------
# keysym resolution is separate from validation (no X needed to --check)
# --------------------------------------------------------------------------

def test_validate_needs_no_x_display(monkeypatch):
    monkeypatch.delenv("DISPLAY", raising=False)
    assert B.validate(B.BINDS, B.LAYERS) == []


def test_unknown_keysym_name_is_reported_not_crashed():
    problems = B.validate([B.Bind("Mod4+NotAKeysym", "nop x")], {})
    assert any("NotAKeysym" in p for p in problems), problems


# --------------------------------------------------------------------------
# --check CLI contract
# --------------------------------------------------------------------------

def run_check(binds_path=None):
    cmd = [sys.executable, str(HERE / "hotkeyd.py"), "--check"]
    if binds_path:
        cmd += ["--binds", str(binds_path)]
    return subprocess.run(cmd, capture_output=True, text=True)


def test_check_exits_zero_on_the_shipped_table():
    r = run_check()
    assert r.returncode == 0, r.stdout + r.stderr


def test_check_exits_nonzero_and_names_the_chord_on_a_seeded_fault(tmp_path):
    faulty = tmp_path / "faulty.py"
    faulty.write_text(
        "import sys; sys.path.insert(0, %r)\n"
        "from binds import Bind, Layer\n"
        "BINDS = [Bind('Mod4+z', 'kill'), Bind('Mod4+z', 'nop dup')]\n"
        "LAYERS = {}\n" % str(HERE))
    r = run_check(faulty)
    assert r.returncode != 0
    assert "Mod4+z" in (r.stdout + r.stderr)


def test_check_reports_every_problem_not_just_the_first(tmp_path):
    faulty = tmp_path / "many.py"
    faulty.write_text(
        "import sys; sys.path.insert(0, %r)\n"
        "from binds import Bind, Layer, enter_layer\n"
        "BINDS = [Bind('Mod4+z', 'kill'), Bind('Mod4+z', 'nop dup'),\n"
        "         Bind('Mod4+y', ''), Bind('Mod4+o', enter_layer('ghost'))]\n"
        "LAYERS = {}\n" % str(HERE))
    r = run_check(faulty)
    out = r.stdout + r.stderr
    assert r.returncode != 0
    for token in ("Mod4+z", "Mod4+y", "ghost"):
        assert token in out, (token, out)


# --------------------------------------------------------------------------
# the $mod token — one table, two displays (dotfiles-hwds.7, us019 AC3)
# --------------------------------------------------------------------------

def test_mod_token_resolves_to_the_given_modifier():
    """ft003 gives i3 `set_from_resource $mod i3wm.mod Mod4`, and the xrdp
    session sets Mod1. The table must express the same idea or it cannot drive
    both displays — AC3 was only mechanically satisfied while chords hardcoded
    Mod4."""
    assert B.normalize_chord("$mod+o", mod="Mod4") == B.normalize_chord("Mod4+o")
    assert B.normalize_chord("$mod+o", mod="Mod1") == B.normalize_chord("Mod1+o")


def test_mod_token_defaults_to_mod4():
    """Same default i3 uses when the resource is absent (native :0)."""
    assert B.normalize_chord("$mod+o") == B.normalize_chord("Mod4+o")


def test_the_same_chord_means_different_things_on_the_two_displays():
    assert B.normalize_chord("$mod+o", mod="Mod1") != \
        B.normalize_chord("$mod+o", mod="Mod4")


def test_mod_token_composes_with_other_modifiers():
    assert B.normalize_chord("$mod+Shift+q", mod="Mod1") == \
        B.normalize_chord("Mod1+Shift+q")


def test_an_unknown_token_is_still_rejected():
    problems = B.validate([B.Bind("$super+o", "nop x")], {})
    assert any("$super" in p for p in problems), problems


def test_validate_threads_the_mod_through():
    """A duplicate that only collides once $mod resolves must still be caught."""
    problems = B.validate([B.Bind("$mod+o", "nop a"), B.Bind("Mod1+o", "nop b")],
                          {}, mod="Mod1")
    assert problems, "collision after resolution not detected"
    assert B.validate([B.Bind("$mod+o", "nop a"), B.Bind("Mod1+o", "nop b")],
                      {}, mod="Mod4") == []


def test_the_shipped_table_uses_the_mod_token_not_a_hardcoded_modifier():
    """On :10 $mod is Mod1, so a hardcoded Mod4 chord is FREE there — the daemon
    would own and serve it while i3 owns the Alt equivalent."""
    hardcoded = [b.chord for b in B.BINDS
                 if "Mod4" in b.chord or "Super" in b.chord]
    assert hardcoded == [], f"hardcoded modifier in the table: {hardcoded}"


@pytest.mark.parametrize("mod", ["Mod4", "Mod1"])
def test_no_chord_is_owned_by_both_i3_and_the_daemon(mod):
    """sp020's anti-pattern: a chord must not exist in both i3 and the daemon at
    any commit boundary. Groups whose cutover has not landed belong to i3 until
    the commit that deletes them from it.

    This asserts the RULE, not a chord list. It was `== ["$mod+o"]` until the
    entry-point cutover (dotfiles-hwds.33) added four more, and a hardcoded
    roster fails every time the roster legitimately changes — which is the one
    moment you need the anti-pattern check working, not rewritten. The same
    argument the panic-chord fixtures below make for deriving from
    B.PANIC_CHORD.

    Checked under BOTH $mod resolutions because the collision is per-display:
    a chord the daemon owns as Mod4 on :0 can still be live in i3 as Mod1 on
    :10, and a single-resolution check sees neither half.
    """
    clash = binds_py_chords(mod) & i3_owned_chords(mod)
    assert clash == set(), (
        f"double-owned with $mod={mod}: {sorted(clash)} — a chord live in both "
        "engines double-fires, and X raises no BadAccess to warn you (core and "
        "XI2 passive grabs sit in separate conflict domains)")


# --------------------------------------------------------------------------
# the panic chord is RESERVED (sp020 Task 10, dotfiles-hwds.12)
# --------------------------------------------------------------------------
# The one chord i3 keeps forever. If a table could bind it, a future edit would
# quietly take the only key that recovers a session from a daemon that is alive
# and wrong. The validator is display-agnostic while `$mod` is not, so a
# token-only check leaves the chord stealable on ONE display: a table spelling
# `Mod1+<key>` owns it on :10, `Mod4+<key>` on :0, and neither matches a
# `$mod` string compare. One fixture per spelling.
#
# DERIVED from B.PANIC_CHORD, never hardcoded. These were spelled out as
# `...+F12` until the chord moved to $mod+Shift+r (the primary :10 client is an
# Android RDP client with no F12 key), and eleven tests failed for naming the
# chord rather than testing the rule. A test that hardcodes the chord breaks
# every time the chord moves, which is exactly when you want it working.

_PANIC_TAIL = "+".join(B.PANIC_CHORD.split("+")[1:])   # e.g. "Shift+r"
PANIC_SPELLINGS = [B.PANIC_CHORD,
                   f"Mod4+{_PANIC_TAIL}",
                   f"Mod1+{_PANIC_TAIL}"]


@pytest.mark.parametrize("spelling", PANIC_SPELLINGS)
@pytest.mark.parametrize("mod", ["Mod4", "Mod1"])
def test_validator_refuses_the_panic_chord_under_every_spelling(spelling, mod):
    problems = B.validate([B.Bind(spelling, "nop steal")], {}, mod=mod)
    assert problems, \
        f"{spelling!r} accepted with $mod={mod} — the panic chord is stealable"
    assert any(spelling in p for p in problems), problems
    assert any("panic" in p.lower() for p in problems), problems


@pytest.mark.parametrize("spelling", PANIC_SPELLINGS)
def test_the_panic_chord_is_reserved_under_alias_spellings_too(spelling):
    """`Super`/`Alt`/lowercase fold onto Mod4/Mod1, so the alias forms are the
    same chord and must be refused identically."""
    aliased = (spelling.replace("Mod4", "Super").replace("Mod1", "Alt")
               .replace("Shift", "shift"))
    assert B.validate([B.Bind(aliased, "nop steal")], {}), \
        f"{aliased!r} (alias form of {spelling!r}) was accepted"


@pytest.mark.parametrize("spelling", PANIC_SPELLINGS)
def test_a_layer_cannot_bind_the_panic_chord_either(spelling):
    """A layer's grabs are held while the layer is active — exactly the state
    you press panic in. Reserving only the global table leaves that hole open."""
    layers = {"nav": B.Layer(binds=[B.Bind(spelling, "nop steal")],
                             exit_keys=["Escape"])}
    problems = B.validate([], layers)
    assert any(spelling in p for p in problems), problems


def test_the_panic_chord_is_reserved_on_release_too():
    """`--release` is a different event but the same passive grab."""
    assert B.validate([B.Bind(B.PANIC_CHORD, "nop", on_release=True)], {})


def test_the_shipped_table_does_not_bind_the_panic_chord():
    assert B.validate(B.BINDS, B.LAYERS) == []


def test_check_exits_nonzero_on_a_table_that_binds_the_panic_chord(tmp_path):
    faulty = tmp_path / "panic_steal.py"
    faulty.write_text(
        "import sys; sys.path.insert(0, %r)\n"
        "from binds import Bind\n"
        "BINDS = [Bind(%r, 'nop steal')]\n"
        "LAYERS = {}\n" % (str(HERE), "Mod1+" + _PANIC_TAIL))
    r = run_check(faulty)
    assert r.returncode != 0
    assert ("Mod1+" + _PANIC_TAIL) in (r.stdout + r.stderr)


# --------------------------------------------------------------------------
# the fallback bind table is FRESH (sp020 Task 10, dotfiles-hwds.12)
# --------------------------------------------------------------------------
# `i3/config.d/zz-fallback-binds.conf` is what panic links in so i3 can answer
# the chords the daemon owns. Its content is the i3 equivalent of what
# `binds.py` owns — NOT "the set i3 owns today", which are opposites: i3 still
# owns its own binds, so a fallback restating them duplicates every one, and i3
# treats a duplicate keybinding as a CONFIG ERROR (nagbar) rather than
# last-wins. `i3/config.d/native.conf:101` already documents that trap. So the
# freshness rule is
#
#     fallback == binds.py's global chords MINUS the chords i3 still owns
#
# which is empty today (binds.py owns `$mod+o`, and i3/config.common:408 still
# owns it too) and names the directional group the moment T14 cuts it over.

REPO = HERE.parent
FALLBACK = REPO / "i3" / "config.d" / "zz-fallback-binds.conf"
I3_CONFIGS = [REPO / "i3" / "config",
              REPO / "i3" / "config.common",
              REPO / "i3" / "config.d" / "native.conf",
              REPO / "i3" / "config.d" / "wsl.conf"]

_BIND_FLAGS = ("--release", "--border", "--whole-window", "--exclude-titlebar",
               "--no-warn", "--locked")


def _norm_i3_chord(chord, mod="Mod4"):
    """Normalise an i3 chord the way binds.normalize_chord does, but tolerant of
    keysyms `binds.py` has never heard of (XF86*, i3-only spellings)."""
    parts = chord.split("+")
    key = parts[-1].strip()
    mods = set()
    for raw in parts[:-1]:
        name = raw.strip().lower()
        if name == B.MOD_TOKEN:
            name = mod.lower()
        mods.add(B.MODIFIER_ALIASES.get(name, name))
    return tuple(sorted(mods)), key


def _i3_chords(path, mod="Mod4"):
    """Top-level `bindsym` chords in an i3 config file.

    Binds inside a `mode "..." { }` block are deliberately excluded: they are
    grabbed only while that mode is active, so they are not part of the
    always-on ownership set the fallback must not collide with.
    """
    out = set()
    depth = 0
    for line in path.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("mode ") and s.endswith("{"):
            depth += 1
            continue
        if s == "}":
            depth = max(0, depth - 1)
            continue
        if depth or not s.startswith("bindsym"):
            continue
        toks = s.split()[1:]
        while toks and toks[0] in _BIND_FLAGS:
            toks.pop(0)
        if toks:
            out.add(_norm_i3_chord(toks[0], mod))
    return out


def i3_owned_chords(mod="Mod4"):
    owned = set()
    for p in I3_CONFIGS:
        owned |= _i3_chords(p, mod)
    return owned


def fallback_chords(mod="Mod4"):
    return _i3_chords(FALLBACK, mod)


def binds_py_chords(mod="Mod4"):
    return {B.normalize_chord(b.chord, mod) for b in B.BINDS}


def test_the_fallback_file_exists():
    assert FALLBACK.is_file(), \
        "panic links this file in; a missing one is found during the outage"


@pytest.mark.parametrize("mod", ["Mod4", "Mod1"])
def test_the_fallback_is_exactly_what_binds_py_owns_and_i3_does_not(mod):
    expected = binds_py_chords(mod) - i3_owned_chords(mod)
    got = fallback_chords(mod)
    assert got == expected, (
        f"fallback drifted with $mod={mod}: "
        f"missing={sorted(expected - got)} extra={sorted(got - expected)}")


@pytest.mark.parametrize("mod", ["Mod4", "Mod1"])
def test_the_fallback_never_duplicates_a_live_i3_bind(mod):
    """i3 errors on a duplicate keybinding rather than taking last-wins, so a
    fallback restating a live bind fails `i3 -C` on the composed tree — the
    `zz-` prefix settles glob ORDERING only, it grants no override."""
    clash = fallback_chords(mod) & i3_owned_chords(mod)
    assert clash == set(), f"fallback duplicates live i3 binds: {sorted(clash)}"


def test_the_fallback_never_binds_the_panic_chord():
    """Panic's own chord stays in the base config. Rebinding it from the file
    panic links in is a duplicate at exactly the worst moment."""
    reserved = {B.normalize_chord(B.PANIC_CHORD, m) for m in ("Mod4", "Mod1")}
    for mod in ("Mod4", "Mod1"):
        assert fallback_chords(mod) & reserved == set()


def test_the_i3_config_parser_actually_sees_binds():
    """Guard on the guard: a parser that silently returned nothing would make
    every freshness assertion above vacuously true.

    The sentinel was `$mod+o` until the nav cutover (dotfiles-hwds.16) moved it
    out of i3 entirely. Pick chords i3 is expected to keep owning: `$mod+h` is
    a global focus bind that the cutover deliberately does NOT migrate, and
    `$mod+Shift+q` (kill) is not in any migration group.
    """
    owned = i3_owned_chords("Mod4")
    assert (("Mod4",), "h") in owned, "did not find $mod+h in i3/config.common"
    assert (("Mod4", "Shift"), "q") in owned, "did not find $mod+Shift+q"
    # A floor, not a headcount: it exists to catch a parser that returned
    # nothing (or almost nothing), so it must sit well below the real total and
    # stay there as cutovers move binds OUT of i3. It read `> 80` against 81
    # binds — one migration of any size away from failing for the right reason
    # in the wrong place, which is what the entry-point cutover
    # (dotfiles-hwds.33, 81 -> 77) then did. Lowered to `> 50` at that point,
    # which the very next cutover (the 26-chord workspace group,
    # dotfiles-hwds.34, 77 -> 51) then came within ONE bind of tripping.
    #
    # So: a floor set relative to today's total is a tripwire on the next
    # migration, not on the parser. Pinned at 10 instead — deep below anything a
    # cutover will plausibly leave behind, and still an order of magnitude above
    # the zero-or-two a broken parser returns. The two named sentinels above are
    # the real assertions; this line only rules out silent emptiness.
    assert len(owned) > 10, f"only parsed {len(owned)} top-level i3 binds"


def test_nav_left_i3_and_lives_only_in_the_daemon():
    """The cutover's invariant, asserted rather than assumed: nav's entry chord
    is owned by binds.py and by nothing in i3's base config.

    A regression here is the T6 shape — a chord live in both engines. It is no
    longer a BadAccess (XI2 and core grabs do not collide), so nothing at
    runtime would complain; this test is the thing that notices.
    """
    for mod in ("Mod4", "Mod1"):
        entry = B.normalize_chord("$mod+o", mod)
        assert entry not in i3_owned_chords(mod), (
            f"$mod+o is back in i3/config.common with $mod={mod} — "
            "nav is double-owned")
        assert entry in {B.normalize_chord(b.chord, mod) for b in B.BINDS}, (
            f"$mod+o missing from binds.py with $mod={mod}")


# --------------------------------------------------------------------------
# device= (sp020 Task 11, dotfiles-hwds.13)
#
# Core `KeyPress` carries no device identity; XI2's `sourceid` does, so a bind
# can name the keyboard it belongs to. The validator's job here is narrow: keep
# a scoped bind out of the duplicate rule, and refuse a `device=` that could
# never match anything.
# --------------------------------------------------------------------------

def test_a_bind_is_unscoped_by_default():
    """Parity: every bind in the shipped table predates device identity and must
    keep matching whatever produced the key."""
    assert B.Bind("Mod4+o", "nop x").device is None


def test_two_binds_on_one_chord_with_different_devices_are_not_duplicates():
    """`sourceid` disambiguates them at dispatch, so they cannot double-fire —
    calling them a collision would refuse the exact table `device=` exists for."""
    assert B.validate([B.Bind("Mod4+o", "nop a", device="Keyboard A"),
                       B.Bind("Mod4+o", "nop b", device="Keyboard B")],
                      {}) == []


def test_two_binds_on_one_chord_with_the_SAME_device_are_still_duplicates():
    problems = B.validate([B.Bind("Mod4+o", "nop a", device="Keyboard A"),
                           B.Bind("Mod4+o", "nop b", device="Keyboard A")], {})
    assert any("already bound" in p for p in problems), problems


def test_a_scoped_bind_and_an_unscoped_one_on_the_same_chord_coexist():
    """The fallback shape: one keyboard gets a special meaning, everything else
    gets the general one. They are distinguishable, so they are not duplicates."""
    assert B.validate([B.Bind("Mod4+o", "nop laptop", device="Keyboard A"),
                       B.Bind("Mod4+o", "nop any")], {}) == []


def test_two_unscoped_binds_on_one_chord_are_still_duplicates():
    problems = B.validate([B.Bind("Mod4+o", "nop a"),
                           B.Bind("Mod4+o", "nop b")], {})
    assert any("already bound" in p for p in problems), problems


def test_an_empty_device_is_refused_naming_the_chord():
    """A `device=""` matches nothing, so the bind would silently never fire —
    the failure mode the validator exists to convert into a refusal."""
    for bad in ("", "   ", 12):
        problems = B.validate([B.Bind("Mod4+o", "nop x", device=bad)], {})
        assert any("device=" in p and "Mod4+o" in p for p in problems), \
            (bad, problems)


def test_a_layer_bind_may_be_device_scoped_too():
    layers = {"nav": B.Layer(binds=[B.Bind("h", "focus left",
                                           device="Keyboard A"),
                                    B.Bind("h", "nop other",
                                           device="Keyboard B")],
                             exit_keys=["q"])}
    assert B.validate([], layers) == []


def test_the_shipped_table_ignores_no_device():
    """Dropping XTEST by default would kill every xdotool-driven bind and every
    harness in this repo, and whether xrdp's synthesised Shift is XTEST-sourced
    is unmeasured (sp020 Task 15). So the list ships empty, on purpose."""
    assert hasattr(B, "IGNORE_DEVICES")
    assert list(B.IGNORE_DEVICES) == []
