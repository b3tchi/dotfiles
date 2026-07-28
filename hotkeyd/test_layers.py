"""Layer engine + state channel tests (sp020 Task 3, dotfiles-7cc7).

The engine is driven by synthesised events — no X server — so every transition
is asserted exactly rather than inferred from a live session. The socket tests
use a real unix socket with scripted readers, because the properties that matter
(replay on connect, a reader that never reads, a reader killed mid-stream) only
exist at the socket layer.

Run: pytest hotkeyd/test_layers.py   (or hotkeyd/test-hotkeyd.sh)
"""
import json
import os
import socket
import sys
import threading
import time
from pathlib import Path

import pytest

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

import binds as B  # noqa: E402
import layers as L  # noqa: E402


# --------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------

class FakeClock:
    """Monotonic clock under test control — the 120 ms release guard cannot be
    tested against wall time without making the suite slow and flaky."""

    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def advance(self, ms):
        self.now += ms / 1000.0


class Recorder:
    """Stands in for the socket publisher: records exactly what was published."""

    def __init__(self):
        self.lines = []

    def publish(self, state):
        self.lines.append(state)


def engine(binds=None, layers=None, clock=None, pub=None, log=None):
    clock = clock or FakeClock()
    pub = pub if pub is not None else Recorder()
    binds = B.BINDS if binds is None else binds
    layers = B.LAYERS if layers is None else layers
    return (L.LayerEngine(binds, layers, publisher=pub, clock=clock, log=log),
            pub, clock)


def press(key, mods=()):
    return L.Event("press", key, frozenset(mods))


def release(key, mods=()):
    return L.Event("release", key, frozenset(mods))


# --------------------------------------------------------------------------
# state transitions — exactly one line per change
# --------------------------------------------------------------------------

def test_starts_in_default_and_publishes_nothing_until_something_changes():
    e, pub, _ = engine()
    assert e.state == {"layer": "default", "mod": None}
    assert pub.lines == []


def test_entering_and_leaving_a_layer_publishes_one_line_each():
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    assert pub.lines == [{"layer": "nav", "mod": None}]
    e.handle(press("q"))
    assert pub.lines == [{"layer": "nav", "mod": None},
                         {"layer": "default", "mod": None}]


def test_modifier_press_and_release_publishes_one_line_each():
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    pub.lines.clear()
    e.handle(press("Control_L"))
    assert pub.lines == [{"layer": "nav", "mod": "move"}]
    e.handle(release("Control_L"))
    assert pub.lines == [{"layer": "nav", "mod": "move"},
                         {"layer": "nav", "mod": None}]


def test_no_duplicate_line_when_nothing_changed():
    """The old bar had to debounce per-keystroke churn (64321d7). The engine
    publishes on CHANGE, so there is nothing to debounce."""
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    pub.lines.clear()
    for _ in range(5):
        e.handle(press("h"))
        e.handle(release("h"))
    assert pub.lines == []


def test_repeated_modifier_press_publishes_once():
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    pub.lines.clear()
    e.handle(press("Control_L"))
    e.handle(press("Control_L"))  # X auto-repeat
    e.handle(press("Control_L"))
    assert pub.lines == [{"layer": "nav", "mod": "move"}]


# --------------------------------------------------------------------------
# dispatch
# --------------------------------------------------------------------------

def test_bare_keys_focus_ctrl_moves_alt_resizes_in_the_nav_layer():
    """Each tap is press+release: X delivers a release before the next press of
    the same key, and a press with no release between is auto-repeat (suppressed
    on purpose — see test_press_bind_fires_once_per_press_with_no_repeat)."""
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(release("o", ["Mod4"]))
    assert e.handle(press("h")) == ["focus left"]
    e.handle(release("h"))
    e.handle(press("Control_L"))
    assert e.handle(press("h", ["Ctrl"])) == ["move left"]
    e.handle(release("h", ["Ctrl"]))
    e.handle(release("Control_L"))
    e.handle(press("Alt_L"))
    assert e.handle(press("h", ["Mod1"])) == ["resize shrink width 5 px or 5 ppt"]


def test_press_bind_fires_once_per_press_with_no_repeat_while_held():
    """AC2. X auto-repeat delivers a stream of presses with no release between;
    a bind that fired per repeat would move a window across the screen."""
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    fired = []
    for _ in range(4):
        fired += e.handle(press("h"))       # repeats, no release
    assert fired == ["focus left"]
    e.handle(release("h"))
    assert e.handle(press("h")) == ["focus left"]


def test_on_release_bind_fires_on_release_and_not_on_press():
    """AC2. This is what the alt-tab switcher needed and i3 could not do —
    the reason qs-keymon.py exists as a second event mechanism."""
    binds = [B.Bind("Mod4+Shift+d", "nop confirm", on_release=True)]
    e, _, _ = engine(binds=binds, layers={})
    assert e.handle(press("d", ["Mod4", "Shift"])) == []
    assert e.handle(release("d", ["Mod4", "Shift"])) == ["nop confirm"]


def test_press_and_release_binds_on_one_chord_each_fire_on_their_own_event():
    binds = [B.Bind("Mod4+d", "nop press"),
             B.Bind("Mod4+d", "nop release", on_release=True)]
    e, _, _ = engine(binds=binds, layers={})
    assert e.handle(press("d", ["Mod4"])) == ["nop press"]
    assert e.handle(release("d", ["Mod4"])) == ["nop release"]


def test_on_release_is_discriminated_inside_a_layer_too():
    """The global path keys binds by (mods, key, on_release); the LAYER path
    matches by chord and must check the flag itself. Dropping that check there
    survived the whole suite — the nav table has no release binds, and every
    other on_release test used global binds."""
    layers = {"pick": B.Layer(
        binds=[B.Bind("Return", "nop chose", on_release=True),
               B.Bind("j", "nop next")],
        exit_keys=["Escape"])}
    e, _, _ = engine(binds=[B.Bind("Mod4+w", B.enter_layer("pick"))],
                     layers=layers)
    e.handle(press("w", ["Mod4"]))
    assert e.handle(press("Return")) == []          # press must NOT fire it
    assert e.handle(release("Return")) == ["nop chose"]
    assert e.handle(press("j")) == ["nop next"]     # press bind still on press
    assert e.handle(release("j")) == []


def test_exit_layer_verb_leaves_the_layer_and_is_not_dispatched():
    """T3 audit M5: this branch was untested, and exit_layer() is published
    ft011 api_surface. With the branch dead the ExitLayer OBJECT falls through
    into the returned action list and gets sent to i3 as a garbage command."""
    layers = {"pick": B.Layer(binds=[B.Bind("d", B.exit_layer())],
                              exit_keys=["Escape"])}
    e, pub, _ = engine(binds=[B.Bind("Mod4+w", B.enter_layer("pick"))],
                       layers=layers)
    e.handle(press("w", ["Mod4"]))
    assert e.handle(press("d")) == []          # nothing dispatched to i3
    assert e.state == {"layer": "default", "mod": None}
    assert pub.lines[-1] == {"layer": "default", "mod": None}


def test_a_key_whose_release_was_lost_becomes_usable_again(fake_clock=None):
    """T3 audit M2: KEY_WEDGE_MS expiry was untested — without it a single lost
    release (the xrdp hazard) makes that key dead for the rest of the session."""
    e, _, clock = engine()
    e.handle(press("o", ["Mod4"]))
    assert e.handle(press("h")) == ["focus left"]
    assert e.handle(press("h")) == []          # repeat suppressed, no release
    clock.advance(L.KEY_WEDGE_MS + 100)
    assert e.handle(press("h")) == ["focus left"], "key wedged after lost release"


@pytest.mark.parametrize("mod_key", ["Control_L", "Control_R"])
def test_both_hands_of_a_modifier_are_recognised(mod_key):
    """T3 audit M3: only the _L variants were exercised, so dropping Control_R
    from MOD_KEYSYMS left the suite green."""
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press(mod_key))
    assert e.state == {"layer": "nav", "mod": "move"}
    assert e.handle(press("h")) == ["move left"]


def test_layer_binds_shadow_global_binds_while_a_layer_is_active():
    """i3 mode parity: in a mode, only that mode's binds are live. A global
    Mod4+h leaking through while nav is active would be a surprise."""
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    assert e.handle(press("h", ["Mod4"])) == ["focus left"]  # nav's, not global


def test_unbound_key_in_a_layer_dispatches_nothing_and_stays_in_the_layer():
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    assert e.handle(press("z")) == []
    assert e.state["layer"] == "nav"


def test_run_and_layer_verbs_come_back_as_action_objects():
    binds = [B.Bind("Mod4+p", B.run("qs-overlay.sh projects"))]
    e, _, _ = engine(binds=binds, layers={})
    assert e.handle(press("p", ["Mod4"])) == [B.Run("qs-overlay.sh projects")]


def test_callable_action_is_invoked_not_returned():
    seen = []
    binds = [B.Bind("Mod4+F1", lambda ev: seen.append(ev.key))]
    e, _, _ = engine(binds=binds, layers={})
    assert e.handle(press("F1", ["Mod4"])) == []
    assert seen == ["F1"]


# --------------------------------------------------------------------------
# exit keys — the carry-forward risk from Task 2's audit
# --------------------------------------------------------------------------

@pytest.mark.parametrize("mod_key,label", [("Control_L", "move"),
                                           ("Alt_L", "resize")])
def test_exit_key_works_while_a_layer_modifier_is_still_held(mod_key, label):
    """i3 needed six separate exit binds (q, Ctrl+q, Mod1+q, Shift+q, ...)
    because bindsym is modifier-exact. binds.py declares exit_keys once, on the
    promise that the engine matches them regardless of held modifiers. If that
    promise breaks, the nav layer is un-leavable while Ctrl or Alt is down —
    a real regression against today's behaviour."""
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press(mod_key))
    assert e.state == {"layer": "nav", "mod": label}
    e.handle(press("q", [L.MOD_KEYSYMS[mod_key]]))
    assert e.state == {"layer": "default", "mod": None}


def test_exit_key_works_while_shift_is_held():
    """Shift is not a layer modifier, so unlike Ctrl/Alt nothing establishes an
    active grab that routes the key here — the grab set carries an explicit
    `Shift+<exit key>` (hotkeyd.layer_chords) to get the event delivered. This
    asserts the other half: once delivered, the engine leaves the layer
    regardless of ShiftMask riding in ev.mods.

    Scope, stated so it is not over-read: this drives LayerEngine.handle with a
    keysym string directly. It does NOT exercise keycode->keysym resolution and
    so does not pin which shift level that lookup uses. The end-to-end path is
    covered only by live_check.py, which presses a real Shift_L before tapping
    the exit key. (In production the name comes from GrabManager.keysym_for,
    which maps the keycode back through the grabbed chord and is
    shift-level-independent by construction; `_keysym_name` is the fallback for
    keycodes no grab claims.)
    """
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    assert e.state == {"layer": "nav", "mod": None}
    e.handle(press("q", ["Shift"]))
    assert e.state == {"layer": "default", "mod": None}
    assert pub.lines[-1] == {"layer": "default", "mod": None}


def test_shift_held_exit_works_from_inside_a_modifier_sublayer():
    """The :10 case: xrdp synthesises Shift around characters it sends, so a
    Shift-flagged exit can arrive while Ctrl or Alt is genuinely held."""
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    assert e.state == {"layer": "nav", "mod": "move"}
    e.handle(press("q", ["Shift", "Ctrl"]))
    assert e.state == {"layer": "default", "mod": None}


def test_shift_does_not_become_a_layer_modifier():
    """Guard on the scope of the fix: Shift must not start publishing itself as
    a held mod, or the bar paints a sublayer that has no binds behind it."""
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Shift_L"))
    assert e.state == {"layer": "nav", "mod": None}


def test_layer_exit_while_a_modifier_is_held_publishes_default_not_a_stuck_mod():
    """Edge case from the spec: the state feed must not strand the bar showing
    'nav MOVE' after the layer is gone."""
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    pub.lines.clear()
    e.handle(press("Escape", ["Ctrl"]))
    assert pub.lines[-1] == {"layer": "default", "mod": None}
    assert e.state == {"layer": "default", "mod": None}


def test_still_held_modifier_after_exit_does_not_re_enter_a_mod_state():
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    e.handle(press("q", ["Ctrl"]))
    pub.lines.clear()
    e.handle(release("Control_L"))
    assert e.state == {"layer": "default", "mod": None}
    assert pub.lines == []


@pytest.mark.parametrize("mod_key", ["Control_L", "Alt_L", "Shift_L"])
def test_a_mods_less_layer_is_still_left_with_a_modifier_held(mod_key):
    """The match half of dotfiles-hwds.18. The grab half (hotkeyd.layer_chords)
    is what was missing; the engine already ignores modifiers on exit keys, and
    that must keep holding for a layer with no `mods` at all — otherwise the
    grabs the daemon now takes would arrive and still do nothing."""
    binds = [B.Bind("$mod+o", B.enter_layer("plain"))]
    layers = {"plain": B.Layer(binds=[B.Bind("h", "focus left")],
                               exit_keys=["q", "Escape"])}
    e, _, _ = engine(binds=binds, layers=layers)
    e.handle(press("o", ["Mod4"]))
    assert e.state == {"layer": "plain", "mod": None}
    e.handle(press(mod_key))
    e.handle(press("q", [L.MOD_KEYSYMS[mod_key]]))
    assert e.state["layer"] == "default", \
        f"a mods-less layer could not be left with {mod_key} held"


def test_every_layer_bind_the_grabber_registers_can_actually_fire():
    """The grab-set / match-set seam (dotfiles-hwds.8). The daemon grabs every
    chord in a layer's table; the engine matches layer binds by comparing the
    chord to a BARE keysym. Anything that validates and gets grabbed must
    dispatch — a bind that is grabbed and silently dead is worse than one that
    was never declared, because the key stops reaching the application too."""
    # The event is built from what X would DELIVER for that chord — the bare
    # keysym, with the chord's modifiers in `mods`. Feeding the chord string
    # itself as the keysym would make this tautological: `b.chord == ev.key`
    # matches trivially when the two are the same string, which is exactly the
    # comparison under test.
    layer = B.LAYERS["nav"]
    for b in layer.binds:
        mods, key = B.parse_chord(b.chord)
        e, _, _ = engine()
        e.handle(press("o", ["Mod4"]))
        assert e.handle(press(key, tuple(mods))) == [b.action], \
            f"nav bind {b.chord!r} is grabbed but never fires"
    keysym_for = {"Ctrl": "Control_L", "Mod1": "Alt_L", "Mod4": "Super_L"}
    for label, mod in layer.mods.items():
        canon = B.MODIFIER_ALIASES[str(mod.modifier).lower()]
        for b in mod.binds:
            mods, key = B.parse_chord(b.chord)
            e, _, _ = engine()
            e.handle(press("o", ["Mod4"]))
            e.handle(press(keysym_for[canon]))
            assert e.state["mod"] == label
            assert e.handle(press(key, tuple(mods))) == [b.action], \
                f"{label} sublayer bind {b.chord!r} is grabbed but never fires"


@pytest.mark.parametrize("key", ["q", "Escape", "Return"])
def test_every_declared_exit_key_leaves_the_layer(key):
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press(key))
    assert e.state["layer"] == "default"


# --------------------------------------------------------------------------
# i3-mode arbitration — never two active owners (dotfiles-hwds.10)
# --------------------------------------------------------------------------
# i3 binding modes hold their OWN passive grabs on the bare keys a layer wants,
# so a layer entered while an i3 mode is up produces two owners: i3 answers `h`
# with its resize command, the daemon still publishes `layer=nav`, and the keys
# the daemon believes it owns were refused with BadAccess. Reproduced on Xvfb
# with the real config (`i3-msg 'mode "resize"'` then `$mod+o` -> 11 BadAccess
# and a divergent layer=nav). The engine is the arbiter: it knows i3's mode
# because the daemon feeds it the `mode` event off the connection it already has.


def test_layer_entry_is_refused_while_i3_is_in_a_mode():
    logged = []
    e, pub, _ = engine(log=logged.append)
    e.set_i3_mode("resize")
    e.handle(press("o", ["Mod4"]))
    assert e.state == {"layer": "default", "mod": None}, \
        "entered a layer whose keys i3's mode already owns"
    assert pub.lines == [], "published a layer it never actually took"
    assert any("resize" in m for m in logged), \
        f"the refusal must name the i3 mode; logged: {logged}"


def test_layer_entry_still_works_while_i3_is_in_the_default_mode():
    """The negative case. Arbitration that refuses everything would satisfy the
    'one owner' invariant trivially and break the whole feature."""
    e, pub, _ = engine()
    e.set_i3_mode("default")
    e.handle(press("o", ["Mod4"]))
    assert e.state == {"layer": "nav", "mod": None}
    assert pub.lines == [{"layer": "nav", "mod": None}]


def test_i3_entering_a_mode_leaves_an_active_layer_publishing_default_once():
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    pub.lines.clear()
    e.set_i3_mode("resize")
    assert e.state == {"layer": "default", "mod": None}
    assert pub.lines == [{"layer": "default", "mod": None}], \
        "exactly one default line on the i3-mode takeover"


def test_i3_mode_takeover_clears_a_held_sublayer_too():
    """The bar must not be left showing `move` for a layer that no longer
    exists — the published line is the whole state, not just the layer name."""
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    assert e.state == {"layer": "nav", "mod": "move"}
    pub.lines.clear()
    e.set_i3_mode("$mode_system")
    assert e.state == {"layer": "default", "mod": None}
    assert pub.lines == [{"layer": "default", "mod": None}]


def test_a_layer_exit_racing_an_i3_mode_entry_publishes_one_default_line():
    """Spec edge case: the user leaves the layer in the same instant i3 takes a
    mode. Two `default` lines would make a bar flicker through a state that
    never existed."""
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    pub.lines.clear()
    e.handle(press("q"))                 # user exits
    e.set_i3_mode("resize")              # i3's event arrives just after
    assert pub.lines == [{"layer": "default", "mod": None}]


def test_repeated_mode_events_for_the_same_mode_publish_nothing_extra():
    e, pub, _ = engine()
    e.set_i3_mode("resize")
    e.set_i3_mode("resize")
    e.set_i3_mode("resize")
    assert pub.lines == []


def test_leaving_the_i3_mode_makes_the_layer_enterable_again():
    """The arbitration must be a gate, not a latch: i3 going back to `default`
    hands ownership back."""
    e, pub, _ = engine()
    e.set_i3_mode("resize")
    e.handle(press("o", ["Mod4"]))
    e.handle(release("o", ["Mod4"]))
    assert e.state["layer"] == "default"
    e.set_i3_mode("default")
    e.handle(press("o", ["Mod4"]))
    assert e.state["layer"] == "nav"
    assert pub.lines == [{"layer": "nav", "mod": None}]


def test_an_empty_mode_name_is_read_as_default():
    """i3 reports the default binding state as the literal `default`; a missing
    or empty name must not be mistaken for 'some mode is up' and wedge the
    daemon out of every layer for the rest of the session."""
    for name in (None, "", "default"):
        e, _, _ = engine()
        e.set_i3_mode(name)
        e.handle(press("o", ["Mod4"]))
        assert e.state["layer"] == "nav", f"{name!r} blocked layer entry"


def test_the_two_owners_never_overlap_across_the_transition_matrix():
    """The invariant, stated once: at no point may i3's mode and the daemon's
    layer BOTH be non-default. Each looks fine alone — that is the defect."""
    e, _, _ = engine()
    script = [
        ("i3", "resize"), ("key", "o"), ("i3", "default"), ("key", "o"),
        ("i3", "$mode_system"), ("i3", "default"), ("key", "o"),
        ("key", "q"), ("i3", "screenshot"), ("key", "o"), ("i3", "default"),
    ]
    for kind, arg in script:
        if kind == "i3":
            e.set_i3_mode(arg)
        else:
            e.handle(press(arg, ["Mod4"] if arg == "o" else []))
        both = e.i3_mode != "default" and e.state["layer"] != "default"
        assert not both, (
            f"two active owners after {kind} {arg!r}: "
            f"i3={e.i3_mode!r} daemon={e.state['layer']!r}")


# --------------------------------------------------------------------------
# two modifiers at once — deterministic precedence
# --------------------------------------------------------------------------

def test_two_modifiers_held_resolve_by_declaration_order_deterministically():
    """Spec edge case. nav declares move (Ctrl) before resize (Alt), so Ctrl
    wins while both are down — and it must not flap depending on press order."""
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    e.handle(press("Alt_L"))
    assert e.state["mod"] == "move"
    assert e.handle(press("h")) == ["move left"]


def test_two_modifiers_reverse_press_order_resolves_the_same_way():
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Alt_L"))
    e.handle(press("Control_L"))
    assert e.state["mod"] == "move", "precedence must not depend on press order"


def test_releasing_the_winning_modifier_falls_back_to_the_other():
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    e.handle(press("Alt_L"))
    e.handle(release("Control_L"))
    assert e.state["mod"] == "resize"
    assert e.handle(press("h")) == ["resize shrink width 5 px or 5 ppt"]


# --------------------------------------------------------------------------
# the 120 ms release fall-back (xrdp Shift synthesis)
# --------------------------------------------------------------------------

def test_modifier_with_a_missed_release_clears_after_the_guard_window():
    """xrdp synthesises Shift around every character, so a release can be lost.
    A latched modifier means the bar lies about the layer indefinitely."""
    e, pub, clock = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    assert e.state["mod"] == "move"
    clock.advance(200)
    e.handle(press("h"))          # unrelated event, mods no longer report Ctrl
    assert e.state["mod"] is None
    assert pub.lines[-1] == {"layer": "nav", "mod": None}


def test_modifier_is_not_cleared_inside_the_guard_window():
    """The guard must not fight legitimate fast typing: within 120 ms an event
    whose mods omit Ctrl is treated as the xrdp churn it usually is."""
    e, _, clock = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    clock.advance(50)
    e.handle(press("h"))
    assert e.state["mod"] == "move"
    assert e.handle(press("j")) == ["move down"]


def test_an_event_that_still_reports_the_modifier_refreshes_the_guard():
    e, _, clock = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    for _ in range(5):
        clock.advance(100)
        e.handle(press("h", ["Ctrl"]))     # still held per event state
    assert e.state["mod"] == "move"


def test_explicit_release_beats_the_guard_immediately():
    e, _, clock = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    e.handle(release("Control_L"))
    assert e.state["mod"] is None


# --------------------------------------------------------------------------
# state channel — real unix socket
# --------------------------------------------------------------------------

@pytest.fixture
def sockpath(tmp_path):
    return tmp_path / "hotkeyd-77.sock"


def read_lines(sock, count, timeout=2.0):
    sock.settimeout(timeout)
    buf = b""
    out = []
    end = time.time() + timeout
    while len(out) < count and time.time() < end:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.strip():
                out.append(json.loads(line))
    return out


def connect(path):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.connect(str(path))
    return c


def test_publisher_creates_the_socket_and_a_client_can_connect(sockpath):
    p = L.StatePublisher(sockpath)
    try:
        assert sockpath.exists()
        c = connect(sockpath)
        c.close()
    finally:
        p.close()


def test_client_connecting_mid_layer_gets_current_state_first(sockpath):
    """The 'late bar is never blank' property."""
    p = L.StatePublisher(sockpath)
    try:
        p.publish({"layer": "nav", "mod": "move"})
        c = connect(sockpath)
        p.poll()
        assert read_lines(c, 1) == [{"layer": "nav", "mod": "move"}]
        c.close()
    finally:
        p.close()


def test_subsequent_changes_arrive_in_order_after_the_replay(sockpath):
    p = L.StatePublisher(sockpath)
    try:
        p.publish({"layer": "nav", "mod": None})
        c = connect(sockpath)
        p.poll()
        p.publish({"layer": "nav", "mod": "move"})
        p.publish({"layer": "default", "mod": None})
        got = read_lines(c, 3)
        assert got == [{"layer": "nav", "mod": None},
                       {"layer": "nav", "mod": "move"},
                       {"layer": "default", "mod": None}]
        c.close()
    finally:
        p.close()


def test_two_clients_each_get_the_full_stream(sockpath):
    p = L.StatePublisher(sockpath)
    try:
        a = connect(sockpath)
        b = connect(sockpath)
        p.poll()
        p.publish({"layer": "nav", "mod": None})
        p.publish({"layer": "nav", "mod": "resize"})
        for c in (a, b):
            assert read_lines(c, 3)[-2:] == [{"layer": "nav", "mod": None},
                                             {"layer": "nav", "mod": "resize"}]
        a.close()
        b.close()
    finally:
        p.close()


def test_a_client_that_never_reads_does_not_block_publishing(sockpath):
    """Slow-consumer edge case: dispatch must complete even when a bar hangs.
    Writes must never block the key path.

    Runs the publish loop on a worker thread and joins with a timeout, because a
    blocking write does not fail this test — it HANGS it, and a suite that hangs
    on a regression is worse than one that fails (CI waits forever instead of
    telling you). The thread is a daemon so a wedged write cannot outlive the
    run either."""
    p = L.StatePublisher(sockpath)
    try:
        c = connect(sockpath)
        p.poll()
        done = threading.Event()

        def flood():
            for i in range(5000):      # far beyond any socket buffer
                p.publish({"layer": "nav", "mod": str(i)})
            done.set()

        t = threading.Thread(target=flood, daemon=True)
        t.start()
        assert done.wait(timeout=5.0), \
            "publishing blocked on a reader that never reads"
        c.close()
    finally:
        p.close()


def test_a_client_killed_mid_stream_does_not_kill_the_publisher(sockpath):
    p = L.StatePublisher(sockpath)
    try:
        c = connect(sockpath)
        p.poll()
        p.publish({"layer": "nav", "mod": None})
        assert p.client_count == 1
        c.close()                       # gone, unread data in flight
        for i in range(50):
            p.publish({"layer": "nav", "mod": f"x{i}"})
        p.poll()
        # Reaped, not merely tolerated: swallowing the OSError without dropping
        # the socket leaks a closed fd per dead bar, and the list grows for the
        # life of the session. Asserting survival alone missed that.
        assert p.client_count == 0, "dead client was not reaped"
        survivor = connect(sockpath)
        p.poll()
        assert read_lines(survivor, 1)  # still serving
        assert p.client_count == 1
        survivor.close()
    finally:
        p.close()


def test_stale_socket_file_from_a_killed_predecessor_is_rebound(sockpath):
    """SIGKILL leaves the socket inode behind; bind() would fail EADDRINUSE.
    A daemon that cannot restart after a hard kill is unusable — the escape
    hatch depends on this."""
    sockpath.write_bytes(b"")           # a stale file where the socket goes
    p = L.StatePublisher(sockpath)
    try:
        c = connect(sockpath)
        c.close()
    finally:
        p.close()


def test_a_live_predecessor_is_not_stolen(sockpath):
    """The flip side: an ACTUALLY listening socket must not be hijacked, or two
    daemons would fight over one display."""
    first = L.StatePublisher(sockpath)
    try:
        with pytest.raises(L.ChannelBusy):
            L.StatePublisher(sockpath)
    finally:
        first.close()


def test_vanished_parent_directory_fails_fast_instead_of_spinning(sockpath):
    """adr0014: a reader loop cannot re-establish its own vanished precondition
    from the inside; it must die and let the layer above decide.

    Asserts the message NAMES the missing directory, which only the explicit
    pre-check produces — bind()'s own ENOENT says just "No such file or
    directory". Without that, deleting the pre-check passed the whole suite,
    since the fallback raised the same class with a useless message."""
    missing = sockpath.parent / "gone" / "hotkeyd.sock"
    with pytest.raises(L.ChannelUnavailable) as ei:
        L.StatePublisher(missing)
    assert str(missing.parent) in str(ei.value), str(ei.value)


def test_close_removes_the_socket_file(sockpath):
    p = L.StatePublisher(sockpath)
    p.close()
    assert not sockpath.exists()


def test_engine_publishes_through_a_real_socket_end_to_end(sockpath):
    """The pieces are tested apart; this asserts they are wired together."""
    p = L.StatePublisher(sockpath)
    try:
        e = L.LayerEngine(B.BINDS, B.LAYERS, publisher=p, clock=FakeClock())
        c = connect(sockpath)
        p.poll()
        e.handle(press("o", ["Mod4"]))
        e.handle(press("Control_L"))
        e.handle(press("q", ["Ctrl"]))
        got = read_lines(c, 4)
        assert got[-3:] == [{"layer": "nav", "mod": None},
                            {"layer": "nav", "mod": "move"},
                            {"layer": "default", "mod": None}]
        c.close()
    finally:
        p.close()


def test_socket_path_helper_is_per_display(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    assert L.socket_path(":0") == tmp_path / "hotkeyd-0.sock"
    assert L.socket_path(":10.0") == tmp_path / "hotkeyd-10.sock"
    assert L.socket_path(":0") != L.socket_path(":10")


def test_socket_path_falls_back_when_xdg_runtime_dir_is_unset(monkeypatch):
    """T3 audit M8: the fallback was untested. A session with no
    XDG_RUNTIME_DIR (some xrdp/proot starts) must still get a per-user path
    rather than crashing or landing in the filesystem root."""
    monkeypatch.delenv("XDG_RUNTIME_DIR", raising=False)
    assert L.socket_path(":0") == Path(f"/run/user/{os.getuid()}/hotkeyd-0.sock")


def test_a_dropped_line_is_resent_on_the_next_poll(sockpath):
    """A state feed is last-value semantics: a client that missed the CURRENT
    line must not stay stale forever. Fill the buffer so lines drop, then drain
    and poll — the client must converge on the latest state."""
    p = L.StatePublisher(sockpath)
    try:
        c = connect(sockpath)
        p.poll()
        for i in range(5000):                 # overflow the socket buffer
            p.publish({"layer": "nav", "mod": str(i)})
        p.publish({"layer": "default", "mod": None})
        c.recv(1 << 20)                       # drain what fits
        time.sleep(0.05)
        p.poll()                              # resend pass
        got = read_lines(c, 1, timeout=1.0)
        assert got, "no resend after the client drained"
        c.close()
    finally:
        p.close()


# --------------------------------------------------------------------------
# source-device matching (sp020 Task 11, dotfiles-hwds.13)
#
# The engine is where a `device=` predicate is judged, because that is where a
# bind is chosen. Two-sided throughout: a positive-only check passes against an
# engine that ignores `Event.device` entirely.
# --------------------------------------------------------------------------

def ev(key, mods=(), device=None, kind="press"):
    return L.Event(kind, key, frozenset(mods), device=device)


def tap(engine, key, mods=(), device=None):
    """Press and release. The release matters: without it the engine's own
    auto-repeat suppression treats the next press of the same key as a repeat,
    and a device check would be graded on an event that never reached it."""
    out = engine.handle(ev(key, mods, device))
    engine.handle(ev(key, mods, device, kind="release"))
    return out


def test_an_unscoped_bind_matches_any_source():
    e = L.LayerEngine([B.Bind("Mod4+o", "nop any")], {})
    for dev in (None, "Keyboard A", "Virtual core XTEST keyboard"):
        assert tap(e, "o", ["Mod4"], dev) == ["nop any"]


def test_a_scoped_global_bind_fires_only_for_its_device():
    e = L.LayerEngine([B.Bind("Mod4+o", "nop a", device="Keyboard A")], {})
    assert tap(e, "o", ["Mod4"], "Keyboard A") == ["nop a"]
    assert tap(e, "o", ["Mod4"], "Keyboard B") == []
    assert tap(e, "o", ["Mod4"], None) == [], \
        "an unattributable event must not satisfy a device predicate"


def test_one_chord_resolves_to_different_actions_per_source():
    e = L.LayerEngine([B.Bind("Mod4+o", "nop a", device="Keyboard A"),
                       B.Bind("Mod4+o", "nop b", device="Keyboard B")], {})
    assert tap(e, "o", ["Mod4"], "Keyboard A") == ["nop a"]
    assert tap(e, "o", ["Mod4"], "Keyboard B") == ["nop b"]


def test_a_scoped_bind_is_tried_before_the_unscoped_fallback():
    """Table order decides, and the scoped bind is written first — otherwise the
    catch-all would shadow it and the predicate would never be reachable."""
    e = L.LayerEngine([B.Bind("Mod4+o", "nop a", device="Keyboard A"),
                       B.Bind("Mod4+o", "nop any")], {})
    assert tap(e, "o", ["Mod4"], "Keyboard A") == ["nop a"]
    assert tap(e, "o", ["Mod4"], "Keyboard B") == ["nop any"]


def test_a_scoped_layer_bind_fires_only_for_its_device():
    layers = {"nav": B.Layer(binds=[B.Bind("h", "focus left",
                                           device="Keyboard A")],
                             exit_keys=["q"])}
    e = L.LayerEngine([B.Bind("Mod4+o", B.enter_layer("nav"))], layers)
    e.handle(ev("o", ["Mod4"], "Keyboard A"))
    assert e.state["layer"] == "nav"
    assert tap(e, "h", device="Keyboard B") == []
    assert tap(e, "h", device="Keyboard A") == ["focus left"]


def test_a_scoped_sublayer_bind_fires_only_for_its_device():
    layers = {"nav": B.Layer(
        binds=[B.Bind("h", "focus left")],
        mods={"move": B.Mod("Ctrl", (B.Bind("h", "move left",
                                            device="Keyboard A"),))},
        exit_keys=["q"])}
    e = L.LayerEngine([B.Bind("Mod4+o", B.enter_layer("nav"))], layers)
    e.handle(ev("o", ["Mod4"], "Keyboard A"))
    e.handle(ev("Control_L", device="Keyboard A"))
    assert e.state["mod"] == "move"
    assert tap(e, "h", device="Keyboard B") == []
    assert tap(e, "h", device="Keyboard A") == ["move left"]


def test_exit_keys_are_never_device_scoped():
    """A layer must stay leavable whatever produced the key: exit keys are
    matched on the keysym alone, and a source predicate on the way OUT would
    turn the layer into a trap for the second keyboard."""
    layers = {"nav": B.Layer(binds=[B.Bind("h", "focus left",
                                           device="Keyboard A")],
                             exit_keys=["q"])}
    e = L.LayerEngine([B.Bind("Mod4+o", B.enter_layer("nav"))], layers)
    e.handle(ev("o", ["Mod4"], "Keyboard A"))
    e.handle(ev("q", device="Keyboard B"))
    assert e.state["layer"] == "default"


def test_the_event_carries_the_source_id_alongside_the_name():
    e = L.Event("press", "h", frozenset(), device="Keyboard A", device_id=12)
    assert (e.device, e.device_id) == ("Keyboard A", 12)


def test_an_event_built_without_a_device_is_unchanged():
    """Parity: every X-free caller in the suite constructs Event(kind, key,
    mods) and must keep meaning 'any source'."""
    e = L.Event("press", "h", frozenset())
    assert e.device is None and e.device_id is None


# --------------------------------------------------------------------------
# layer-transition log (dotfiles-hwds.27)
# --------------------------------------------------------------------------
# A daemon that spontaneously believes it is in `nav` GRABS that layer's bare
# keys — h/j/k/l, the arrows, q, Escape, Return — and swallows them from every
# application until it changes its mind. That happened once on the live :10
# session ~30 s after the first start, and the daemon logged NOTHING, so the
# only evidence left was a replayed socket line.
#
# The log below is the evidence a recurrence has to leave behind. Every field is
# there because it discriminates between the ticket's candidate causes: the
# KEYCODE and MASK say whether the event looked like a real chord, and the
# SOURCE DEVICE says whether anything physical produced it at all — an
# XTEST-injected `$mod+o` and a typed one are otherwise indistinguishable, and
# `binds.IGNORE_DEVICES` ships empty, so injection reaches the engine today.


def logged_engine(**kw):
    lines = []
    e, pub, _clock = engine(log=lines.append, **kw)
    return e, pub, lines


def xev(kind, key, mods=(), keycode=None, raw_state=None,
        device=None, device_id=None):
    return L.Event(kind, key, frozenset(mods), device=device,
                   device_id=device_id, keycode=keycode, raw_state=raw_state)


def transitions(lines):
    return [ln for ln in lines if ln.startswith("transition ")]


def test_entering_a_layer_logs_one_transition_naming_the_triggering_event():
    e, _, lines = logged_engine()
    e.handle(xev("press", "o", ["Mod4"], keycode=32, raw_state=0x40,
                 device="AT Translated Set 2 keyboard", device_id=12))
    t = transitions(lines)
    assert len(t) == 1, f"expected exactly one transition line, got {lines}"
    line = t[0]
    for want in ("layer=default->nav", "trigger=press:o", "keycode=32",
                 "mask=0x0040", "mods=Mod4", "sourceid=12",
                 "AT Translated Set 2 keyboard", "held=none"):
        assert want in line, f"{want!r} missing from {line!r}"


def test_leaving_a_layer_logs_the_transition_and_the_key_that_did_it():
    e, _, lines = logged_engine()
    e.handle(xev("press", "o", ["Mod4"], keycode=32, raw_state=0x40))
    lines.clear()
    e.handle(xev("press", "Escape", keycode=9, raw_state=0x0))
    t = transitions(lines)
    assert len(t) == 1, lines
    assert "layer=nav->default" in t[0] and "keycode=9" in t[0], t[0]
    assert "trigger=press:Escape" in t[0], t[0]


def test_a_held_modifier_sublayer_change_is_logged_too():
    """`mod` is half of what the socket publishes, and the live observation was
    `{"layer":"nav","mod":"resize"}` — a log that recorded only the layer could
    not tell that report apart from `{"layer":"nav","mod":null}`."""
    e, _, lines = logged_engine()
    e.handle(xev("press", "o", ["Mod4"], keycode=32, raw_state=0x40))
    lines.clear()
    e.handle(xev("press", "Alt_L", ["Mod4"], keycode=64, raw_state=0x40))
    t = transitions(lines)
    assert len(t) == 1, lines
    assert "mod=none->resize" in t[0] and "keycode=64" in t[0], t[0]
    assert "layer=nav->nav" in t[0], t[0]
    assert "held=Mod1" in t[0], \
        f"the log must show WHICH modifiers the engine believed held: {t[0]}"


def test_an_event_that_changes_nothing_logs_no_transition():
    """The log has to stay readable across a whole session or nobody will leave
    it running, which is the entire point of adding it."""
    e, _, lines = logged_engine()
    e.handle(xev("press", "z", keycode=52, raw_state=0))
    e.handle(xev("release", "z", keycode=52, raw_state=0))
    assert transitions(lines) == [], lines


def test_i3_forcing_a_layer_exit_logs_it_with_no_triggering_key():
    e, _, lines = logged_engine()
    e.handle(xev("press", "o", ["Mod4"], keycode=32, raw_state=0x40))
    lines.clear()
    e.set_i3_mode("resize")
    t = transitions(lines)
    assert len(t) == 1, lines
    assert "layer=nav->default" in t[0], t[0]
    assert "trigger=none" in t[0], \
        "no key caused this; the log must not imply one"
    assert "resize" in t[0], f"the note must name the i3 mode: {t[0]}"


def test_an_unattributable_event_is_logged_as_unattributable_not_guessed():
    """The XI2 lookup fails for a device that vanished between the press and the
    query. A log that printed a plausible-looking device there would be worse
    than no log at all: cause 1 in the ticket turns entirely on provenance."""
    e, _, lines = logged_engine()
    e.handle(xev("press", "o", ["Mod4"]))
    t = transitions(lines)
    assert len(t) == 1, lines
    assert "keycode=none" in t[0] and "sourceid=none" in t[0], t[0]
    assert "device=none" in t[0], t[0]


def test_the_transition_log_names_the_i3_mode_the_engine_believed():
    e, _, lines = logged_engine()
    e.handle(xev("press", "o", ["Mod4"], keycode=32, raw_state=0x40))
    assert "i3_mode=default" in transitions(lines)[0]


# --------------------------------------------------------------------------
# what CANNOT put the engine into a layer (hwds.27 causes 2 and 3)
# --------------------------------------------------------------------------
# The ticket names three candidates. Two of them — a startup state computed
# before real modifier state is known, and an artifact of the i3 restart — are
# claims about NON-KEY inputs putting the engine into `nav`. There are exactly
# three such inputs, and none of them may ever move the layer away from
# `default`: only a matched EnterLayer bind can.


def test_no_amount_of_i3_mode_traffic_can_enter_a_layer():
    e, pub, _ = engine()
    for name in ("default", "resize", "default", "nav", "default", ""):
        e.set_i3_mode(name)
        assert e.state["layer"] == "default", name
    assert pub.lines == [], "i3 mode traffic alone must publish nothing"


def test_reconciling_holds_can_never_enter_a_layer():
    e, pub, _ = engine()
    e.reconcile_holds(frozenset({"Mod1", "Ctrl", "Shift"}))
    assert e.state == {"layer": "default", "mod": None}
    assert pub.lines == []


def test_a_fresh_engine_publishes_nothing_at_all_before_the_first_key():
    """Cause 2 in the ticket: a state computed before real input is known, then
    served out of the replay buffer. A publisher that was never called cannot
    have a buffer to serve."""
    e, pub, _ = engine()
    e.set_i3_mode("default")
    e.reconcile_holds(frozenset())
    assert pub.lines == []
    assert e.state == {"layer": "default", "mod": None}


# --------------------------------------------------------------------------
# reconciling belief against the server (hwds.27 item 4)
# --------------------------------------------------------------------------
# `_expire_stale_holds` runs only when an event arrives, so a hold the session
# stopped reporting survives an IDLE daemon indefinitely — and an idle daemon is
# exactly what serves the replay buffer to a bar that connects late. The
# reconciler closes that: given what the server says is down RIGHT NOW, it drops
# beliefs the server does not corroborate.
#
# Deliberately RETRACT-ONLY. The server's mask is ground truth about what is
# down, but `_held` is what the engine has actually OBSERVED, and adding a hold
# it never saw pressed would manufacture a sublayer out of a modifier that
# belongs to some other client's gesture.


def test_reconcile_drops_a_hold_the_server_does_not_corroborate():
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Alt_L"))
    assert e.state == {"layer": "nav", "mod": "resize"}
    pub.lines.clear()
    changed = e.reconcile_holds(frozenset())
    assert changed is True
    assert e.state == {"layer": "nav", "mod": None}
    assert pub.lines == [{"layer": "nav", "mod": None}]


def test_reconcile_never_invents_a_hold_the_engine_never_observed():
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    pub.lines.clear()
    changed = e.reconcile_holds(frozenset({"Mod1", "Ctrl"}))
    assert changed is False
    assert e.state == {"layer": "nav", "mod": None}, \
        "a sublayer was manufactured from the server mask alone"
    assert pub.lines == []


def test_reconcile_leaves_a_corroborated_hold_alone():
    e, pub, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    assert e.state["mod"] == "move"
    pub.lines.clear()
    assert e.reconcile_holds(frozenset({"Ctrl"})) is False
    assert e.state["mod"] == "move"
    assert pub.lines == []


def test_reconcile_refreshes_a_corroborated_hold_past_the_guard_window():
    """A modifier genuinely held through a long idle must not be expired by the
    next event's guard check just because no event refreshed it."""
    e, _pub, clock = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    clock.advance(5000)
    e.reconcile_holds(frozenset({"Ctrl"}))
    e.handle(press("h", ["Ctrl"]))
    assert e.state["mod"] == "move", \
        "a reconciled hold was expired anyway on the next event"


def test_reconcile_logs_the_retraction():
    e, _, lines = logged_engine()
    e.handle(xev("press", "o", ["Mod4"], keycode=32, raw_state=0x40))
    e.handle(xev("press", "Alt_L", ["Mod4"], keycode=64, raw_state=0x40))
    lines.clear()
    e.reconcile_holds(frozenset())
    t = transitions(lines)
    assert len(t) == 1, lines
    assert "mod=resize->none" in t[0] and "reconcile" in t[0], t[0]


def test_reconcile_does_not_leave_a_layer():
    """Retracting a modifier belief is not evidence about the LAYER. X has no
    opinion about `nav`, so a reconciler that also dropped the layer would be
    inventing the exact state this ticket is about, from the other side."""
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Alt_L"))
    e.reconcile_holds(frozenset())
    assert e.state["layer"] == "nav"


def test_held_is_exposed_so_the_idle_path_can_skip_the_x_round_trip():
    e, _, _ = engine()
    assert e.held == frozenset()
    e.handle(press("o", ["Mod4"]))
    e.handle(press("Control_L"))
    assert e.held == frozenset({"Ctrl"})


# --------------------------------------------------------------------------
# ONE-SHOT layers (sp020 / dotfiles-hwds.38)
# --------------------------------------------------------------------------
# i3 spelled this as `, mode "default"` appended to EVERY bind in the block.
# That is the layer being one-shot, not a per-bind choice, so it is declared
# once on the Layer — a per-bind flag is a per-bind opportunity to forget it,
# and forgetting it on the system layer leaves the keyboard in a state where a
# bare `r` reboots the machine.

def _oneshot_layers():
    return {"os": B.Layer(binds=[B.Bind("a", B.run("echo a")),
                                 B.Bind("b", "i3-cmd-b")],
                          exit_keys=["q", "Escape"],
                          one_shot=True),
            "sticky": B.Layer(binds=[B.Bind("a", B.run("echo a"))],
                              exit_keys=["q"])}


def _oneshot_binds():
    return [B.Bind("$mod+F1", B.enter_layer("os")),
            B.Bind("$mod+F2", B.enter_layer("sticky"))]


def oneshot_engine(**kw):
    return engine(binds=_oneshot_binds(), layers=_oneshot_layers(), **kw)


def test_a_one_shot_layer_exits_after_a_bind_fires():
    e, _, _ = oneshot_engine()
    e.handle(press("F1", ["Mod4"]))
    assert e.state["layer"] == "os"
    e.handle(press("a"))
    assert e.state["layer"] == "default", \
        "a one-shot layer must return to default after ONE bind"


def test_a_one_shot_layer_still_dispatches_the_action_it_exits_on():
    """The exit must not eat the action. Returning to default INSTEAD of running
    the command would be a mode that silently does nothing."""
    e, _, _ = oneshot_engine()
    e.handle(press("F1", ["Mod4"]))
    out = e.handle(press("b"))
    assert out == ["i3-cmd-b"], out
    assert e.state["layer"] == "default"


def test_a_normal_layer_still_persists_after_a_bind_fires():
    """The negative control: one-shot must be opt-in. nav would be unusable if
    every layer exited after one motion."""
    e, _, _ = oneshot_engine()
    e.handle(press("F2", ["Mod4"]))
    e.handle(press("a"))
    assert e.state["layer"] == "sticky"


def test_a_one_shot_layer_exit_publishes_exactly_one_line():
    """Contract from dotfiles-hwds.2: one published line per state change. The
    action and the exit happen in one event, so this must not cost two."""
    e, pub, _ = oneshot_engine()
    e.handle(press("F1", ["Mod4"]))
    pub.lines.clear()
    e.handle(press("a"))
    assert pub.lines == [{"layer": "default", "mod": None}], pub.lines


def test_a_key_that_matches_nothing_does_not_leave_a_one_shot_layer():
    """Only a FIRED bind is one shot. A stray key that matches no bind is
    swallowed by the layer, exactly as in a persistent one — otherwise a typo
    silently drops you out of the mode you thought you were in."""
    e, _, _ = oneshot_engine()
    e.handle(press("F1", ["Mod4"]))
    e.handle(press("z"))
    assert e.state["layer"] == "os"


def test_the_one_shot_exit_is_logged_as_a_transition():
    e, _, lines = logged_engine(binds=_oneshot_binds(),
                                layers=_oneshot_layers())
    e.handle(xev("press", "F1", ["Mod4"], keycode=67, raw_state=0x40))
    lines.clear()
    e.handle(xev("press", "a", keycode=38, raw_state=0x0))
    t = transitions(lines)
    assert len(t) == 1, lines
    assert "layer=os->default" in t[0] and "trigger=press:a" in t[0], t[0]
