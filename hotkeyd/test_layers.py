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


def engine(binds=None, layers=None, clock=None, pub=None):
    clock = clock or FakeClock()
    pub = pub if pub is not None else Recorder()
    binds = B.BINDS if binds is None else binds
    layers = B.LAYERS if layers is None else layers
    return L.LayerEngine(binds, layers, publisher=pub, clock=clock), pub, clock


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


@pytest.mark.parametrize("key", ["q", "Escape", "Return"])
def test_every_declared_exit_key_leaves_the_layer(key):
    e, _, _ = engine()
    e.handle(press("o", ["Mod4"]))
    e.handle(press(key))
    assert e.state["layer"] == "default"


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
