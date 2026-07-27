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
        c.close()                       # gone, unread data in flight
        for i in range(50):
            p.publish({"layer": "nav", "mod": f"x{i}"})
        p.poll()
        survivor = connect(sockpath)
        p.poll()
        assert read_lines(survivor, 1)  # still serving
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
    from the inside; it must die and let the layer above decide."""
    missing = sockpath.parent / "gone" / "hotkeyd.sock"
    with pytest.raises(L.ChannelUnavailable):
        L.StatePublisher(missing)


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
