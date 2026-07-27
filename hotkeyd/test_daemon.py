"""Daemon core tests (sp020 Task 4, dotfiles-hwds.1).

The X pieces are driven through a fake display that records every grab call, so
the lock-bit and MappingNotify contracts are asserted exactly rather than
inferred from "it seemed to work on my session". The i3 client is tested against
a real unix socket stub, because the property that matters — ONE connection for
the whole run, reconnecting only when i3 actually restarts — is only observable
at the socket.

Live-X behaviour (real XGrabKey, real i3 dispatch, NumLock/CapsLock permutations,
BadAccess against a second grabber) is covered by test-hotkeyd.sh under Xvfb.

Run: pytest hotkeyd/test_daemon.py   (or hotkeyd/test-hotkeyd.sh)
"""
import os
import socket
import struct
import sys
import threading
import time
from pathlib import Path

import pytest

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

import binds as B  # noqa: E402
import hotkeyd as H  # noqa: E402


# --------------------------------------------------------------------------
# fake X
# --------------------------------------------------------------------------

class FakeDisplay:
    """Records grabs. `keymap` maps keysym name -> keycode and can be swapped
    mid-test to simulate the xrdp per-connect keymap reset."""

    def __init__(self, keymap=None, fail_chords=()):
        self.keymap = dict(keymap or {"o": 32, "h": 43, "q": 24, "F10": 76,
                                      "Super_L": 133, "Control_L": 37})
        self.grabs = []          # (keycode, mask)
        self.ungrabs = []
        self.syncs = 0
        self.fail_keycodes = set(fail_chords)
        self.errors = []

    def keysym_to_keycode(self, name):
        return self.keymap.get(name, 0)

    def grab_key(self, keycode, mask):
        if keycode in self.fail_keycodes:
            self.errors.append(("BadAccess", keycode, mask))
            raise H.GrabRefused(f"BadAccess on keycode {keycode}")
        self.grabs.append((keycode, mask))

    def ungrab_key(self, keycode, mask):
        self.ungrabs.append((keycode, mask))

    def sync(self):
        self.syncs += 1


def grabs_for(disp, keycode):
    return sorted(m for kc, m in disp.grabs if kc == keycode)


# --------------------------------------------------------------------------
# lock-bit variants — poc013 proved a bare-mask grab MISSES with NumLock on
# --------------------------------------------------------------------------

def test_every_chord_is_grabbed_with_all_four_lock_variants():
    d = FakeDisplay()
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o"])
    base = H.MOD4
    assert grabs_for(d, 32) == sorted([
        base, base | H.LOCK, base | H.MOD2, base | H.LOCK | H.MOD2])


def test_lock_variants_are_exactly_four_no_duplicates():
    d = FakeDisplay()
    H.GrabManager(d).sync_binds(["Mod4+o"])
    assert len(d.grabs) == 4
    assert len(set(d.grabs)) == 4


def test_a_chord_with_no_modifier_still_gets_the_lock_variants():
    d = FakeDisplay()
    H.GrabManager(d).sync_binds(["F10"])
    assert grabs_for(d, 76) == sorted([0, H.LOCK, H.MOD2, H.LOCK | H.MOD2])


# --------------------------------------------------------------------------
# keysym resolution — keycodes differ per session (poc013)
# --------------------------------------------------------------------------

def test_chords_resolve_through_the_live_keymap_not_hardcoded_codes():
    """Super_L is 133 on :0 and 115 on :10. Whatever the session says wins."""
    d = FakeDisplay(keymap={"o": 99, "Super_L": 115})
    H.GrabManager(d).sync_binds(["Mod4+o"])
    assert {kc for kc, _ in d.grabs} == {99}


def test_a_keysym_absent_from_the_keymap_is_reported_not_crashed():
    d = FakeDisplay(keymap={"o": 32})
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+F10"])
    assert any("F10" in p for p in g.problems), g.problems
    assert d.grabs == [], "must not grab keycode 0"


def test_one_unresolvable_chord_does_not_stop_the_others():
    d = FakeDisplay(keymap={"o": 32})
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+F10", "Mod4+o"])
    assert grabs_for(d, 32), "the resolvable chord must still be grabbed"
    assert len(g.problems) == 1


# --------------------------------------------------------------------------
# BadAccess — the mid-migration double-grab signal (poc013 probe 4)
# --------------------------------------------------------------------------

def test_badaccess_on_one_chord_is_recorded_and_the_rest_keep_working():
    """A chord already grabbed by i3 must degrade to 'that chord is not ours',
    never to a dead daemon — this is exactly the mid-cutover state."""
    d = FakeDisplay(fail_chords={43})       # 'h'
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+h", "Mod4+o"])
    assert any("h" in p for p in g.problems), g.problems
    assert grabs_for(d, 32), "the other chord must still be grabbed"


def test_badaccess_does_not_raise_out_of_sync_binds():
    d = FakeDisplay(fail_chords={32})
    H.GrabManager(d).sync_binds(["Mod4+o"])   # must not raise


# --------------------------------------------------------------------------
# MappingNotify — compare-then-regrab (poc013: spurious events at every startup)
# --------------------------------------------------------------------------

def test_mapping_notify_with_an_unchanged_keymap_does_not_regrab():
    """Two spurious MappingNotify arrive at every daemon startup. Regrabbing
    unconditionally would churn every grab for nothing."""
    d = FakeDisplay()
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o"])
    before = len(d.grabs)
    changed = g.on_mapping_notify()
    assert changed is False
    assert len(d.grabs) == before
    assert d.ungrabs == []


def test_mapping_notify_with_a_changed_keycode_regrabs_the_new_code():
    """The xrdp reconnect case: same keysym, new keycode."""
    d = FakeDisplay()
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o"])
    d.keymap["o"] = 64                      # keymap reset moved the key
    assert g.on_mapping_notify() is True
    assert grabs_for(d, 64), "new keycode not grabbed"
    assert any(kc == 32 for kc, _ in d.ungrabs), "old keycode not released"


def test_mapping_notify_releases_all_four_variants_of_the_old_code():
    d = FakeDisplay()
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o"])
    d.keymap["o"] = 64
    g.on_mapping_notify()
    assert len([1 for kc, _ in d.ungrabs if kc == 32]) == 4


def test_mapping_notify_that_removes_a_key_reports_it_and_keeps_running():
    d = FakeDisplay()
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o", "Mod4+h"])
    del d.keymap["o"]
    g.on_mapping_notify()
    assert any("o" in p for p in g.problems), g.problems


# --------------------------------------------------------------------------
# reload — SIGHUP must not drop a grab that exists in both tables
# --------------------------------------------------------------------------

def test_reload_keeps_grabs_present_in_both_old_and_new_tables():
    d = FakeDisplay()
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o", "Mod4+h"])
    d.grabs.clear()
    d.ungrabs.clear()
    g.sync_binds(["Mod4+o", "Mod4+q"])      # h dropped, q added
    assert not any(kc == 32 for kc, _ in d.ungrabs), "unchanged grab was dropped"
    assert grabs_for(d, 24), "new chord not grabbed"
    assert len([1 for kc, _ in d.ungrabs if kc == 43]) == 4, "removed chord kept"


def test_reload_to_an_identical_table_is_a_no_op():
    d = FakeDisplay()
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o"])
    d.grabs.clear()
    d.ungrabs.clear()
    g.sync_binds(["Mod4+o"])
    assert d.grabs == [] and d.ungrabs == []


# --------------------------------------------------------------------------
# i3 IPC — one connection for the whole run
# --------------------------------------------------------------------------

MAGIC = b"i3-ipc"
HDR = struct.Struct("=6sII")


class FakeI3:
    """A stub i3 IPC server. Counts connections so 'persistent' is measurable."""

    def __init__(self, path):
        self.path = str(path)
        self.connections = 0
        self.commands = []
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(self.path)
        self._srv.listen(4)
        self._stop = threading.Event()
        self._conns = []
        self._t = threading.Thread(target=self._serve, daemon=True)
        self._t.start()

    def _serve(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._srv.accept()
            except OSError:
                return
            self.connections += 1
            self._conns.append(conn)
            threading.Thread(target=self._client, args=(conn,),
                             daemon=True).start()

    def _client(self, conn):
        while not self._stop.is_set():
            try:
                hdr = conn.recv(HDR.size)
            except OSError:
                return
            if not hdr or len(hdr) < HDR.size:
                return
            _, length, mtype = HDR.unpack(hdr)
            payload = conn.recv(length) if length else b""
            self.commands.append(payload.decode())
            body = b'[{"success":true}]'
            try:
                conn.sendall(HDR.pack(MAGIC, len(body), mtype) + body)
            except OSError:
                return

    def close(self):
        self._stop.set()
        # Close ACCEPTED connections too, not just the listener. When i3 really
        # restarts its process dies and every client socket breaks; a fake that
        # leaves them open lets a "reconnect" test pass while the client happily
        # keeps talking to the dead server.
        for c in self._conns:
            try:
                c.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                c.close()
            except OSError:
                pass
        try:
            self._srv.close()
        except OSError:
            pass
        try:
            os.unlink(self.path)
        except OSError:
            pass


@pytest.fixture
def fake_i3(tmp_path):
    srv = FakeI3(tmp_path / "i3.sock")
    yield srv
    srv.close()


def test_one_connection_serves_many_dispatches(fake_i3):
    """Spec: no i3-msg spawn per keystroke, connection survives >=100 dispatches."""
    c = H.I3Client(lambda: fake_i3.path)
    for i in range(120):
        c.command(f"nop {i}")
    time.sleep(0.05)
    assert fake_i3.connections == 1, "reconnected mid-run"
    assert len(fake_i3.commands) == 120
    c.close()


def test_commands_arrive_verbatim(fake_i3):
    c = H.I3Client(lambda: fake_i3.path)
    c.command("focus left")
    time.sleep(0.05)
    assert fake_i3.commands == ["focus left"]
    c.close()


def test_client_reconnects_when_i3_restarts(tmp_path):
    """i3 restart changes the socket path; the daemon must follow rather than
    dying or silently swallowing every later keystroke."""
    first = FakeI3(tmp_path / "i3-a.sock")
    path = {"p": first.path}
    c = H.I3Client(lambda: path["p"])
    c.command("nop one")
    time.sleep(0.05)
    first.close()

    second = FakeI3(tmp_path / "i3-b.sock")
    path["p"] = second.path
    c.command("nop two")                    # must transparently reconnect
    time.sleep(0.05)
    assert second.commands == ["nop two"]
    c.close()
    second.close()


def test_dispatch_failure_is_reported_not_fatal(tmp_path):
    """i3 gone entirely: a keystroke must not take the daemon down with it."""
    c = H.I3Client(lambda: str(tmp_path / "nope.sock"))
    assert c.command("focus left") is False   # reported, no exception


# --------------------------------------------------------------------------
# single instance
# --------------------------------------------------------------------------

def test_second_instance_on_the_same_display_is_refused(tmp_path):
    """Refused, and refused WITHOUT BLOCKING.

    Run on a worker thread with a join timeout: dropping LOCK_NB makes flock
    wait for the holder forever, which does not fail this test — it hangs it,
    and a suite that hangs on a regression tells CI nothing. Found by mutation
    testing, which wedged on exactly that mutant."""
    lock = tmp_path / "hotkeyd-0.lock"
    first = H.SingleInstance(lock)
    outcome = {}

    def attempt():
        try:
            H.SingleInstance(lock)
            outcome["result"] = "acquired"
        except H.AlreadyRunning:
            outcome["result"] = "refused"
        except Exception as e:                      # noqa: BLE001
            outcome["result"] = f"error: {e!r}"

    try:
        t = threading.Thread(target=attempt, daemon=True)
        t.start()
        t.join(timeout=5.0)
        assert not t.is_alive(), "second instance BLOCKED instead of failing"
        assert outcome["result"] == "refused", outcome
    finally:
        first.release()


def test_lock_is_reusable_after_the_holder_exits(tmp_path):
    lock = tmp_path / "hotkeyd-0.lock"
    H.SingleInstance(lock).release()
    second = H.SingleInstance(lock)          # must not raise
    second.release()


def test_different_displays_do_not_collide(tmp_path):
    a = H.SingleInstance(tmp_path / "hotkeyd-0.lock")
    b = H.SingleInstance(tmp_path / "hotkeyd-10.lock")
    a.release()
    b.release()


def test_lock_path_is_per_display(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    assert H.lock_path(":0") == tmp_path / "hotkeyd-0.lock"
    assert H.lock_path(":10.0") == tmp_path / "hotkeyd-10.lock"


# --------------------------------------------------------------------------
# the grab set — X delivers only GRABBED keys
# --------------------------------------------------------------------------

def test_bare_layer_keys_are_not_grabbed_in_the_default_layer():
    """G1 from the T4 audit. Grabbing nav's bare `h`/`Escape`/`Return` at startup
    swallows those keys from EVERY application for as long as the daemon runs —
    measured live: a focused app got the injected `h` 1/1 without the daemon and
    0/1 with it. The layer's keys exist only while the layer does."""
    default_set = H.chords_for(B)
    for key in ("h", "j", "k", "l", "Left", "Escape", "Return", "q"):
        assert key not in default_set, \
            f"{key!r} grabbed in the default layer — eaten from every app"
    assert "$mod+o" in default_set, "the layer entry chord must still be grabbed"


def test_entering_a_layer_grabs_its_bare_keys():
    chords = H.chords_for(B, "nav")
    assert "h" in chords, "bare nav keys not grabbed while nav is active"
    assert "Left" in chords
    assert "$mod+o" in chords, "global binds stay grabbed inside a layer"


def test_a_layer_grabs_the_modifier_keys_its_sublayers_need():
    """G2 from the T4 audit. Modifier PREFIX keys were never grabbed, so a Ctrl
    press inside nav never reached the daemon, `_held` stayed empty, and Ctrl+h
    dispatched `focus left` instead of `move left` — with all unit tests green."""
    chords = H.chords_for(B, "nav")
    for keysym in ("Control_L", "Control_R", "Alt_L", "Alt_R"):
        assert keysym in chords, f"{keysym} not grabbed — sublayer is dead"


def test_modifier_keys_are_not_grabbed_outside_a_layer():
    assert "Control_L" not in H.chords_for(B)


def test_layer_binds_are_in_the_all_chords_report():
    chords = H.all_chords(B)
    assert "h" in chords
    assert "Left" in chords


def test_layer_exit_keys_are_in_the_grab_set():
    """A layer you can enter but not leave is the dotfiles-ux1 failure class."""
    chords = H.chords_for(B, "nav")
    for k in B.LAYERS["nav"].exit_keys:
        assert k in chords, f"exit key {k!r} not grabbed — layer is a trap"


def test_modifier_sublayer_chords_are_grabbed_with_their_modifier():
    chords = H.chords_for(B, "nav")
    assert "Ctrl+h" in chords, "nav move layer not grabbed"
    assert "Mod1+h" in chords, "nav resize layer not grabbed"


def test_global_binds_are_in_the_grab_set():
    chords = H.chords_for(B)
    assert "$mod+o" in chords


def test_the_mod_token_resolves_per_display_at_grab_time():
    """One table, two displays (us019 AC3): the same `$mod+o` chord must grab
    Super on :0 and Alt on the xrdp session, where i3wm.mod is Mod1."""
    native = FakeDisplay(keymap={"o": 32})
    rdp = FakeDisplay(keymap={"o": 32})
    H.GrabManager(native, mod="Mod4").sync_binds(["$mod+o"])
    H.GrabManager(rdp, mod="Mod1").sync_binds(["$mod+o"])
    assert (32, H.MOD4) in native.grabs
    assert (32, H.MOD1) in rdp.grabs
    assert (32, H.MOD4) not in rdp.grabs, "RDP session grabbed Super, not Alt"


def test_mod_defaults_to_mod4_when_the_resource_is_absent():
    assert H.x_resource_mod(None) == "Mod4"


def test_mod_is_read_from_the_i3wm_resource():
    """Same source i3 reads (ft003). xrdp/xinitrc merges `i3wm.mod: Mod1`."""
    xd = FakeXDisplay("")
    xd.path = "i3wm.mod:\tMod1\nXft.dpi:\t96\n"
    assert H.x_resource_mod(xd) == "Mod1"


def test_an_unrelated_resource_database_leaves_the_default():
    xd = FakeXDisplay("")
    xd.path = "Xft.dpi:\t96\nXcursor.theme:\tAdwaita\n"
    assert H.x_resource_mod(xd) == "Mod4"


def test_the_grab_set_is_deduplicated():
    for chords in (H.chords_for(B), H.chords_for(B, "nav"), H.all_chords(B)):
        assert len(chords) == len(set(chords))


# --------------------------------------------------------------------------
# reviewer-battery survivors: multi-modifier masks, keysym_for, Run dispatch
# --------------------------------------------------------------------------

def test_a_two_modifier_chord_grabs_the_combined_mask():
    """M4: mask assembly `|=` -> `=` survived because no test grabbed a chord
    with two modifiers — ~25 shipped chords would have grabbed the wrong mask."""
    d = FakeDisplay(keymap={"1": 10, "Super_L": 133, "Control_L": 37})
    H.GrabManager(d).sync_binds(["Mod4+Ctrl+1"])
    want = H.MOD4 | H.CTRL
    assert grabs_for(d, 10) == sorted([want, want | H.LOCK, want | H.MOD2,
                                       want | H.LOCK | H.MOD2])


def test_a_three_modifier_chord_grabs_every_bit():
    d = FakeDisplay(keymap={"q": 24})
    H.GrabManager(d).sync_binds(["Mod4+Ctrl+Shift+q"])
    want = H.MOD4 | H.CTRL | H.SHIFT
    assert (24, want) in d.grabs


def test_keysym_for_maps_a_grabbed_keycode_back_to_its_name():
    """M1: deleting keysym_for survived, but python-xlib's keysym_to_string
    returns None for arrows and F-keys — so those binds would go dead."""
    d = FakeDisplay()
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o", "F10"])
    assert g.keysym_for(32) == "o"
    assert g.keysym_for(76) == "F10"
    assert g.keysym_for(9999) is None


def test_run_actions_are_spawned_not_sent_to_i3(monkeypatch):
    """M10: the Run branch of _dispatch had zero coverage — deleting it made all
    24 shipped run() workspace binds silently no-op."""
    spawned = []
    monkeypatch.setattr(H.subprocess, "Popen",
                        lambda cmd, **kw: spawned.append(cmd))
    sent = []

    class FakeI3Client:
        def command(self, c):
            sent.append(c)
            return True

    H._dispatch(FakeI3Client(), B.run("ws-switch.nu 3"))
    assert spawned == ["ws-switch.nu 3"]
    assert sent == [], "a run() action must not be sent to i3 as a command"


def test_i3_command_actions_go_to_i3_not_a_shell(monkeypatch):
    spawned = []
    monkeypatch.setattr(H.subprocess, "Popen",
                        lambda cmd, **kw: spawned.append(cmd))
    sent = []

    class FakeI3Client:
        def command(self, c):
            sent.append(c)
            return True

    H._dispatch(FakeI3Client(), "focus left")
    assert sent == ["focus left"]
    assert spawned == []


# --------------------------------------------------------------------------
# event translation
# --------------------------------------------------------------------------

def test_x_state_mask_becomes_canonical_modifier_names():
    ev = H.to_event("press", "h", H.MOD4 | H.CTRL)
    assert ev.kind == "press"
    assert ev.key == "h"
    assert ev.mods == frozenset({"Mod4", "Ctrl"})


def test_lock_bits_are_stripped_from_the_reported_modifiers():
    """NumLock and CapsLock ride in the state mask but are not layer modifiers;
    leaving them in would make Ctrl+h with NumLock on look like a different
    chord than Ctrl+h without it."""
    ev = H.to_event("press", "h", H.CTRL | H.MOD2 | H.LOCK)
    assert ev.mods == frozenset({"Ctrl"})


# --------------------------------------------------------------------------
# i3 socket resolution — must never trust an inherited I3SOCK (dotfiles-hwds.6)
# --------------------------------------------------------------------------

class FakeXDisplay:
    """Just enough X to answer the I3_SOCKET_PATH root-window property."""

    def __init__(self, path):
        self.path = path
        outer = self

        class Prop:
            def __init__(self, v):
                self.value = v.encode()

        class Root:
            def get_full_property(self, atom, kind):
                return Prop(outer.path) if outer.path else None

        class Screen:
            root = Root()

        self._screen = Screen()

    def intern_atom(self, name):
        return 1

    def screen(self):
        return self._screen


def test_socket_path_prefers_the_displays_own_root_property(monkeypatch):
    """i3 exports I3SOCK into every child it execs, so a daemon started for :10
    by :0's i3 inherits :0's socket and dispatches to the WRONG WM — a chord
    pressed in the RDP session moves a window on the native desktop."""
    monkeypatch.setenv("I3SOCK", "/tmp/some-other-session.sock")
    xd = FakeXDisplay("/run/user/1000/i3/ipc-socket.RIGHT")
    assert H.i3_socket_path(xdisp=xd) == "/run/user/1000/i3/ipc-socket.RIGHT"


def test_socket_path_ignores_i3sock_even_with_no_x_display(monkeypatch):
    monkeypatch.setenv("I3SOCK", "/tmp/inherited-and-wrong.sock")
    calls = []

    def fake_run(cmd, **kw):
        calls.append((cmd, kw.get("env", {})))

        class R:
            stdout = "/run/user/1000/i3/ipc-socket.FROM-CLI\n"
        return R()

    monkeypatch.setattr(H.subprocess, "run", fake_run)
    got = H.i3_socket_path(display=":10")
    assert got == "/run/user/1000/i3/ipc-socket.FROM-CLI"
    cmd, env = calls[0]
    assert cmd[:1] == ["i3"]
    assert env.get("DISPLAY") == ":10", "resolver must pin the target display"
    assert "I3SOCK" not in env, "inherited I3SOCK must be scrubbed for the child"


def test_explicit_override_is_honoured(monkeypatch):
    """HOTKEYD_I3SOCK is an explicit operator/test override — unlike I3SOCK it is
    never injected by i3, so trusting it cannot mis-route a session."""
    monkeypatch.setenv("HOTKEYD_I3SOCK", "/tmp/explicit.sock")
    monkeypatch.setenv("I3SOCK", "/tmp/inherited.sock")
    assert H.i3_socket_path() == "/tmp/explicit.sock"


def test_client_follows_the_property_across_an_i3_restart(tmp_path):
    """The production resolver, not an injected lambda: i3 restarting rewrites
    the root property, and the daemon must follow it."""
    first = FakeI3(tmp_path / "i3-1.sock")
    xd = FakeXDisplay(first.path)
    c = H.I3Client(lambda: H.i3_socket_path(xdisp=xd))
    c.command("nop one")
    time.sleep(0.05)
    assert first.commands == ["nop one"]
    first.close()

    second = FakeI3(tmp_path / "i3-2.sock")
    xd.path = second.path                      # i3 restarted, property updated
    c.command("nop two")
    time.sleep(0.05)
    assert second.commands == ["nop two"]
    c.close()
    second.close()


def test_two_daemons_on_two_displays_resolve_different_sockets(tmp_path):
    a = FakeXDisplay(str(tmp_path / "a.sock"))
    b = FakeXDisplay(str(tmp_path / "b.sock"))
    assert H.i3_socket_path(xdisp=a) != H.i3_socket_path(xdisp=b)


# --------------------------------------------------------------------------
# the load path must validate — not just --check (dotfiles-hwds.5)
# --------------------------------------------------------------------------

def write_table(tmp_path, body, name="t.py"):
    f = tmp_path / name
    f.write_text(f"import sys; sys.path.insert(0, {str(HERE)!r})\n"
                 "from binds import Bind, Layer, Mod, run, enter_layer, exit_layer\n"
                 + body)
    return f


def test_load_table_refuses_a_table_that_check_would_reject(tmp_path):
    """us019 AC4 says the bind set is validated BEFORE it is loaded. Validation
    lived only in --check, so a table with a duplicate chord loaded happily —
    and post-T6 the escape-hatch restart takes exactly this path."""
    bad = write_table(tmp_path,
                      "BINDS = [Bind('Mod4+z', 'kill'), Bind('Mod4+z', 'nop')]\n"
                      "LAYERS = {}\n")
    with pytest.raises(H.TableInvalid) as ei:
        H.load_table(str(bad))
    assert "Mod4+z" in str(ei.value)


def test_load_table_refuses_an_un_leavable_layer(tmp_path):
    """The trap binds.py exists to catch: a layer with no exit keys. --check
    refused it; the daemon loaded it."""
    bad = write_table(tmp_path,
                      "BINDS = [Bind('Mod4+o', enter_layer('trap'))]\n"
                      "LAYERS = {'trap': Layer(binds=[Bind('h', 'focus left')],"
                      " exit_keys=[])}\n")
    with pytest.raises(H.TableInvalid) as ei:
        H.load_table(str(bad))
    assert "trap" in str(ei.value)


def test_load_table_accepts_the_shipped_table():
    assert H.load_table(None) is not None


def test_load_table_reports_a_missing_binds_attribute_as_table_invalid(tmp_path):
    """SIGHUP catches TableInvalid to keep the old table. This used to raise
    SystemExit, which escaped the handler and KILLED the daemon."""
    bad = write_table(tmp_path, "LAYERS = {}\n")
    with pytest.raises(H.TableInvalid):
        H.load_table(str(bad))


def test_load_table_reports_a_missing_file_as_table_invalid(tmp_path):
    with pytest.raises(H.TableInvalid):
        H.load_table(str(tmp_path / "nope.py"))


def test_load_table_reports_a_syntax_error_as_table_invalid(tmp_path):
    bad = tmp_path / "broken.py"
    bad.write_text("BINDS = [   # unterminated\n")
    with pytest.raises(H.TableInvalid):
        H.load_table(str(bad))


def test_table_invalid_is_not_a_systemexit():
    """SystemExit inherits BaseException, so `except Exception` does not catch
    it — that is exactly how a bad reload killed the daemon."""
    assert issubclass(H.TableInvalid, Exception)
    assert not issubclass(H.TableInvalid, SystemExit)


def test_reload_keeps_the_old_table_when_the_new_one_is_invalid(tmp_path):
    """The promise the daemon logs. Exercised through the same helper the reload
    path uses, so the two cannot drift."""
    good = write_table(tmp_path, "BINDS = [Bind('Mod4+o', 'nop ok')]\n"
                                 "LAYERS = {}\n", name="good.py")
    table = H.load_table(str(good))
    assert [b.chord for b in table.BINDS] == ["Mod4+o"]
    bad = write_table(tmp_path, "BINDS = [Bind('Mod4+z', ''),]\n"
                                "LAYERS = {}\n", name="bad.py")
    try:
        table = H.load_table(str(bad))
        raise AssertionError("invalid table was accepted")
    except H.TableInvalid:
        pass
    assert [b.chord for b in table.BINDS] == ["Mod4+o"], "old table was lost"


def test_a_table_that_defines_dataclasses_loads(tmp_path):
    """A real bind table is derived from binds.py and defines its own
    dataclasses. Without registering the module in sys.modules before exec,
    dataclasses resolves sys.modules[cls.__module__] to None and the import dies
    with "'NoneType' object has no attribute '__dict__'" — so --binds was broken
    for exactly the tables people would actually write."""
    src = (HERE / "binds.py").read_text()
    f = tmp_path / "derived.py"
    f.write_text(src)
    mod = H.load_table(str(f))
    assert mod.BINDS and mod.LAYERS


# --------------------------------------------------------------------------
# composition wiring — each caught a mutant that passed everything else
# --------------------------------------------------------------------------

def test_engine_matches_the_mod_token_against_the_displays_modifier():
    """M13: LayerEngine._index ignoring self.mod passed all 155 tests while
    making the nav entry chord dead on :10. The per-display test injected mod=
    directly; nothing checked the engine actually USES it."""
    import layers as L                                   # noqa: PLC0415
    binds = [B.Bind("$mod+o", B.enter_layer("nav"))]
    layers = {"nav": B.Layer(binds=[B.Bind("h", "focus left")],
                             exit_keys=["q"])}
    rdp = L.LayerEngine(binds, layers, mod="Mod1")
    rdp.handle(L.Event("press", "o", frozenset({"Mod1"})))
    assert rdp.state["layer"] == "nav", "Alt+o did not enter nav where $mod is Alt"

    rdp2 = L.LayerEngine(binds, layers, mod="Mod1")
    rdp2.handle(L.Event("press", "o", frozenset({"Mod4"})))
    assert rdp2.state["layer"] == "default", "Super+o entered nav where $mod is Alt"


def test_daemon_resolves_the_display_mod_and_hands_it_to_the_grabs():
    """M14: Daemon dropping mod= from GrabManager passed all 155 tests, so the
    grab landed on Mod4 while the engine matched Mod1 — the chord grabbed on the
    wrong modifier on the xrdp session."""

    class XWithResource(FakeDisplay):
        """An X-LIKE display: RESOURCE_MANAGER carrying the xrdp session's
        i3wm.mod, and keysym_to_keycode taking an INTEGER keysym exactly as
        python-xlib does — a fake that is easier to satisfy than X never
        exercises the adapter under test."""

        def __init__(self):
            super().__init__(keymap={"o": 32})

        def keysym_to_keycode(self, keysym):
            from Xlib import XK                           # noqa: PLC0415
            return 32 if keysym == XK.string_to_keysym("o") else 0

        def intern_atom(self, name):
            return 1

        def screen(self):
            outer = self

            class Prop:
                value = b"i3wm.mod:\tMod1\nXft.dpi:\t96\n"

            class Root:
                def get_full_property(self, atom, kind):
                    return Prop()

                def grab_key(self, code, mask, owner, pmode, kmode,
                             onerror=None):
                    outer.grabs.append((code, mask))

                def ungrab_key(self, code, mask):
                    outer.ungrabs.append((code, mask))

            class Screen:
                root = Root()

            return Screen()

    xd = XWithResource()
    table = type("T", (), {"BINDS": [B.Bind("$mod+o", "nop x")], "LAYERS": {}})
    pub = type("P", (), {"publish": lambda self, s: None,
                         "close": lambda self: None,
                         "poll": lambda self: None})()

    class NullI3:
        def command(self, c):
            return True

        def close(self):
            pass

    dae = H.Daemon(table, xd, pub, i3=NullI3(), display=":10")
    assert dae.mod == "Mod1", "daemon did not read i3wm.mod from the display"
    assert (32, H.MOD1) in xd.grabs, "grab did not land on the display's own $mod"
    assert (32, H.MOD4) not in xd.grabs, "grabbed Super where $mod is Alt"


def test_the_production_i3_resolver_pins_its_own_display(monkeypatch):
    """The CLI fallback must not inherit the ambient DISPLAY: a :10 daemon
    started from :0's session would otherwise resolve :0's socket whenever the
    root property is unreadable — the hwds.6 defect by another route."""
    monkeypatch.setenv("DISPLAY", ":0")
    seen = {}

    def fake_run(cmd, **kw):
        seen.update(kw.get("env", {}))

        class R:
            stdout = "/run/user/1000/i3/ipc-socket.X\n"
        return R()

    monkeypatch.setattr(H.subprocess, "run", fake_run)
    H.i3_socket_path(display=":10", xdisp=FakeXDisplay(""))   # empty property
    assert seen.get("DISPLAY") == ":10", \
        f"fallback inherited the ambient display: {seen.get('DISPLAY')!r}"
