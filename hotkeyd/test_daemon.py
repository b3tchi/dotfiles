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
    g.sync_binds(["Mod4+nosuchkey"] if False else ["Mod4+F10"])
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

def test_layer_binds_are_in_the_grab_set():
    """Nothing asserted this, and dropping layer binds from all_chords left the
    whole suite green — while making nav mode completely dead in a real session,
    since X delivers only the keys you actually grabbed."""
    chords = H.all_chords(B)
    assert "h" in chords, "bare nav keys are not grabbed — the layer is dead"
    assert "Left" in chords


def test_layer_exit_keys_are_in_the_grab_set():
    """A layer you can enter but not leave is the dotfiles-ux1 failure class."""
    chords = H.all_chords(B)
    for k in B.LAYERS["nav"].exit_keys:
        assert k in chords, f"exit key {k!r} not grabbed — layer is a trap"


def test_modifier_sublayer_chords_are_grabbed_with_their_modifier():
    chords = H.all_chords(B)
    assert "Ctrl+h" in chords, "nav move layer not grabbed"
    assert "Mod1+h" in chords, "nav resize layer not grabbed"


def test_global_binds_are_in_the_grab_set():
    chords = H.all_chords(B)
    assert "Mod4+o" in chords
    assert "Mod4+1" in chords


def test_the_grab_set_is_deduplicated():
    chords = H.all_chords(B)
    assert len(chords) == len(set(chords))


# --------------------------------------------------------------------------
# event translation
# --------------------------------------------------------------------------

def test_x_state_mask_becomes_canonical_modifier_names():
    ev = H.to_event("press", "h", H.MOD4 | H.CTRL, {"h": 43})
    assert ev.kind == "press"
    assert ev.key == "h"
    assert ev.mods == frozenset({"Mod4", "Ctrl"})


def test_lock_bits_are_stripped_from_the_reported_modifiers():
    """NumLock and CapsLock ride in the state mask but are not layer modifiers;
    leaving them in would make Ctrl+h with NumLock on look like a different
    chord than Ctrl+h without it."""
    ev = H.to_event("press", "h", H.CTRL | H.MOD2 | H.LOCK, {"h": 43})
    assert ev.mods == frozenset({"Ctrl"})
