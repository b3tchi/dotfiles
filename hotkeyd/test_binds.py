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
    # $altmod, not a literal: it must differ per display (see the $altmod tests)
    assert nav.mods["resize"].modifier == "$altmod"
    assert B.resolve_mod_name(nav.mods["resize"].modifier, "Mod4") == "Mod1"
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


def test_workspace_group_has_not_been_migrated_yet():
    """Guards sp020's anti-pattern from the other side: the workspace chords are
    still live in i3/config.common, so they must NOT be in this table. When they
    migrate, the commit that adds them here is the commit that deletes them
    there — and this test is what should be rewritten then, deliberately."""
    ws = [b.chord for b in B.BINDS if isinstance(b.action, B.Run)
          and "ws-switch" in b.action.cmd]
    assert ws == [], f"workspace group migrated without deleting it from i3: {ws}"


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


def test_the_shipped_table_is_scoped_to_the_nav_cutover():
    """sp020's anti-pattern: a chord must not exist in both i3 and the daemon at
    any commit boundary. Groups whose cutover is not T6 belong to i3 until the
    commit that deletes them from it."""
    assert [b.chord for b in B.BINDS] == ["$mod+o"], \
        "table carries groups that i3 still owns"


# --------------------------------------------------------------------------
# $altmod — the sublayer modifier must never collide with $mod (T6 audit gap 2)
# --------------------------------------------------------------------------

def test_altmod_avoids_whatever_mod_is():
    """On the xrdp session $mod IS Mod1, and i3 owns Mod1+hjkl as focus binds —
    a literal Mod1 resize layer got BadAccess on every chord and Alt+h did i3's
    focus instead of resizing. $altmod is always the one of the pair the WM does
    not own."""
    assert B.alt_mod_for("Mod4") == "Mod1"
    assert B.alt_mod_for("Mod1") == "Mod4"
    assert B.alt_mod_for("Alt") == "Mod4"


def test_altmod_never_equals_mod():
    for m in ("Mod4", "Mod1", "Super", "Alt"):
        resolved = B.MODIFIER_ALIASES[m.lower()]
        assert B.alt_mod_for(m) != resolved, m


def test_the_resize_sublayer_uses_the_token_not_a_literal():
    assert B.LAYERS["nav"].mods["resize"].modifier == "$altmod"


def test_altmod_resolves_in_a_chord():
    assert B.normalize_chord("$altmod+h", mod="Mod4") == B.normalize_chord("Mod1+h")
    assert B.normalize_chord("$altmod+h", mod="Mod1") == B.normalize_chord("Mod4+h")


def test_the_shipped_table_validates_under_both_display_modifiers():
    for m in ("Mod4", "Mod1"):
        assert B.validate(B.BINDS, B.LAYERS, mod=m) == [], m
