"""Daemon core tests (sp020 Task 4, dotfiles-hwds.1; XI2 port at Task 11).

The X pieces are driven through a fake display that records every grab call, so
the lock-bit and MappingNotify contracts are asserted exactly rather than
inferred from "it seemed to work on my session". The i3 client is tested against
a real unix socket stub, because the property that matters — ONE connection for
the whole run, reconnecting only when i3 actually restarts — is only observable
at the socket.

The fake display speaks XI2 and REFUSES the core and exclusive grab calls
(`XI2Root`), because after the port those are the two ways of getting the
mechanism wrong: `XGrabKey` costs every event its source device, and
`XIGrabDevice` locks the session when the daemon hangs. A fake that answered
either would let a half-finished port pass this whole file.

Live-X behaviour (real XIGrabKeycode, real i3 dispatch, NumLock/CapsLock
permutations, refusal against a second XI2 grabber, real source attribution
through XTEST) is covered by test-hotkeyd.sh under Xvfb.

Run: pytest hotkeyd/test_daemon.py   (or hotkeyd/test-hotkeyd.sh)
"""
import json
import os
import socket
import struct
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

import binds as B  # noqa: E402
import hotkeyd as H  # noqa: E402
import layers as L  # noqa: E402


# --------------------------------------------------------------------------
# fake X
# --------------------------------------------------------------------------

#: sourceid -> name, the XI2 inventory the fake displays report. Shaped after
#: the measured one: `:0` has the laptop keyboard (12), bluetooth (13) and the
#: XTEST injector (5).
FAKE_DEVICES = {5: "Virtual core XTEST keyboard",
                12: "AT Translated Set 2 keyboard",
                13: "BlueZ 5.86 (MCS)"}


class FakeDisplay:
    """Records grabs. `keymap` maps keysym name -> keycode and can be swapped
    mid-test to simulate the xrdp per-connect keymap reset.

    Also answers the XI2 questions the real adapter asks a display: the
    extension probe, the version, and the device inventory `sourceid` resolves
    against."""

    def __init__(self, keymap=None, fail_chords=(), devices=None, xi2=True):
        self.keymap = dict(keymap or {"o": 32, "h": 43, "q": 24, "F10": 76,
                                      "Super_L": 133, "Control_L": 37})
        self.grabs = []          # (keycode, mask)
        self.ungrabs = []
        self.syncs = 0
        self.fail_keycodes = set(fail_chords)
        self.errors = []
        self.devices = dict(FAKE_DEVICES if devices is None else devices)
        self.xi2 = xi2
        self.device_queries = []

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

    # -- XI2 --------------------------------------------------------------
    def query_extension(self, name):
        if name == "XInputExtension" and self.xi2:
            return SimpleNamespace(major_opcode=131)
        return None

    def xinput_query_version(self):
        if not self.xi2:
            # Deliberately says nothing about the extension by name: the probe
            # must be caught at `query_extension`, and an error message that
            # happened to mention XInput here would let a version-only check
            # pass the "names why" assertion for the wrong reason.
            raise RuntimeError("BadRequest (major 131)")
        return SimpleNamespace(major_version=2, minor_version=0)

    def xinput_query_device(self, deviceid):
        self.device_queries.append(deviceid)
        if deviceid not in self.devices:
            raise ValueError(f"BadDevice {deviceid}")
        return SimpleNamespace(devices=[SimpleNamespace(
            deviceid=deviceid, name=self.devices[deviceid])])


class XI2Root:
    """A root window that speaks XI2 and REFUSES the core / exclusive calls.

    `outer` is the FakeDisplay that records what was grabbed. The refusals are
    the point: a root that still answered `grab_key` would let a half-finished
    port pass, and one that answered `xinput_grab_device` would let an
    exclusive grab through — the failure mode that locks a whole session.
    """

    def __init__(self, outer, prop=None):
        self.outer = outer
        self.prop = prop
        self.selected_events = []
        # What the SERVER says is held right now, and how many times anyone
        # asked. The count is asserted on: the idle reconciliation (hwds.27
        # item 4) is only defensible if it never runs on the key path and never
        # runs at all while the engine believes nothing is held.
        self.pointer_mask = 0
        self.pointer_queries = 0

    def query_pointer(self):
        self.pointer_queries += 1
        return SimpleNamespace(mask=self.pointer_mask)

    def get_full_property(self, atom, kind):
        return self.prop

    def xinput_grab_keycode(self, deviceid, time, keycode, grab_mode,
                            paired_device_mode, owner_events, event_mask,
                            modifiers):
        self.outer.grab_devices.append(deviceid)
        for m in modifiers:
            if keycode in self.outer.fail_keycodes:
                return SimpleNamespace(modifiers=[m])
            self.outer.grabs.append((keycode, m))
        return SimpleNamespace(modifiers=[])

    def xinput_ungrab_keycode(self, deviceid, keycode, modifiers):
        for m in modifiers:
            self.outer.ungrabs.append((keycode, m))

    def xinput_select_events(self, spec):
        self.selected_events.append(spec)
        self.outer.selected_events.append(spec)

    def grab_key(self, *a, **kw):
        raise AssertionError(
            "core XGrabKey: the adapter must grab through XI2, or the event "
            "carries no source device")

    def ungrab_key(self, *a, **kw):
        raise AssertionError(
            "core XUngrabKey: the adapter must ungrab through XI2")

    def xinput_grab_device(self, *a, **kw):
        raise AssertionError(
            "XIGrabDevice: an exclusive grab held by a hung daemon locks the "
            "whole session — grabs must be per chord")


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
# the grab set must not be MONOTONIC (dotfiles-hwds.41)
#
# xrdp reprograms the keymap on every RDP (re)connect, so `:10` sees
# MappingNotify churn a native session never does. While the keymap is being
# rebuilt a keysym can momentarily resolve to keycode 0 — and the old re-grab
# path deleted such a chord from the grab set and re-derived the next set from
# THE SURVIVORS, so the set could only ever shrink and the chord never came
# back. Measured live on :10: `$mod+o` still fired while the whole directional
# group was dead, with no BadAccess and no log line, until the daemon was
# restarted.
#
# The rule these three assert: the wanted set is the TABLE's, never whatever
# happens to still be grabbed.
# --------------------------------------------------------------------------

def test_a_keysym_that_comes_back_gets_its_chord_grabbed_again():
    d = FakeDisplay()
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o", "Mod4+h"])
    del d.keymap["o"]                       # keymap mid-rebuild
    g.on_mapping_notify()
    d.keymap["o"] = 32                      # ...and settled
    d.grabs.clear()
    g.on_mapping_notify()
    assert grabs_for(d, 32), (
        "chord was dropped on a transient keymap and never restored — "
        "the re-grab re-derived from the survivors, not from the table")


def test_a_chord_refused_at_startup_is_retried_on_the_next_notify():
    """A refusal is a moment in time — i3 mid-restart still holding the chord —
    not a property of the chord. The refusal happens at the FIRST sync here on
    purpose: `_grab` returns before recording the chord, so it never reaches
    `_active` at all, and a re-grab driven by the survivors has nothing left to
    ask about. That is the shape that stranded a bind for a whole session.
    """
    d = FakeDisplay(fail_chords={32})       # contested from the start
    g = H.GrabManager(d)
    g.sync_binds(["Mod4+o"])
    assert not grabs_for(d, 32)
    d.fail_keycodes = set()                 # contender let go
    g.on_mapping_notify()
    assert grabs_for(d, 32), "a chord refused at startup was never retried"


def test_a_grab_lost_mid_session_is_reported_when_it_happens():
    """`problems` was printed only at startup, so every mid-session loss was
    discarded unread — which is why the live log showed 59 chords grabbed and
    no error while the chords were already gone."""
    seen = []
    d = FakeDisplay()
    g = H.GrabManager(d, log=seen.append)
    g.sync_binds(["Mod4+o", "Mod4+h"])
    del d.keymap["o"]
    g.on_mapping_notify()
    assert any("o" in m for m in seen), (
        f"grab loss was not reported when it happened: {seen}")


def test_an_unchanged_problem_is_not_reported_twice():
    """MappingNotify arrives in bursts; a chord that stays unresolvable must not
    reprint on every one of them."""
    seen = []
    d = FakeDisplay()
    g = H.GrabManager(d, log=seen.append)
    g.sync_binds(["Mod4+o"])
    del d.keymap["o"]
    g.on_mapping_notify()
    first = len(seen)
    g.on_mapping_notify()
    g.on_mapping_notify()
    assert len(seen) == first, f"same problem reported {len(seen)} times: {seen}"


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
    """A stub i3 IPC server. Counts connections so 'persistent' is measurable.

    Speaks enough of the protocol for the mode-arbitration path: SUBSCRIBE,
    GET_BINDING_STATE, and unsolicited events with the high type bit set —
    including an event delivered in the middle of a command's reply, which is
    the interleaving i3's own docs warn about on a subscribed connection.
    """

    def __init__(self, path, binding_state="default"):
        self.path = str(path)
        self.connections = 0
        self.commands = []
        self.subscriptions = []
        self.binding_state = binding_state
        self.event_before_reply = None
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
            body = b'[{"success":true}]'
            if mtype == 2:                                  # SUBSCRIBE
                self.subscriptions.append(json.loads(payload or b"[]"))
            elif mtype == 12:                               # GET_BINDING_STATE
                body = json.dumps({"name": self.binding_state}).encode()
            else:
                self.commands.append(payload.decode())
                if self.event_before_reply is not None:
                    # i3: "as soon as you subscribe, it is not guaranteed any
                    # longer that requests are processed in order". A client
                    # that treats the next message as its reply desynchronises
                    # for the rest of the session.
                    self.send_event(2, {"change": self.event_before_reply})
                    self.event_before_reply = None
            try:
                conn.sendall(HDR.pack(MAGIC, len(body), mtype) + body)
            except OSError:
                return

    def send_event(self, kind, payload):
        """Push an unsolicited event to every connected client."""
        body = json.dumps(payload).encode()
        head = HDR.pack(MAGIC, len(body), kind | 0x80000000)
        for c in list(self._conns):
            try:
                c.sendall(head + body)
            except OSError:
                pass

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
# i3 `mode` events on that SAME connection (dotfiles-hwds.10)
# --------------------------------------------------------------------------

def test_subscribing_to_mode_events_uses_the_connection_we_already_have(fake_i3):
    """sp020: one persistent i3 connection for the process lifetime. A second
    socket for events, or an `i3-msg -t subscribe` spawn, is the thing the
    convention exists to forbid."""
    c = H.I3Client(lambda: fake_i3.path)
    assert c.subscribe(["mode"]) is True
    for i in range(20):
        c.command(f"nop {i}")
    time.sleep(0.05)
    assert fake_i3.connections == 1, "events opened a second connection"
    assert fake_i3.subscriptions == [["mode"]]
    assert len(fake_i3.commands) == 20
    c.close()


def test_an_event_arriving_before_a_reply_is_not_mistaken_for_it(fake_i3):
    """The desync i3's docs warn about: once subscribed, an event can land
    between a request and its reply. Reading it AS the reply leaves the client
    one message behind forever."""
    seen = []
    c = H.I3Client(lambda: fake_i3.path,
                   on_event=lambda k, d: seen.append((k, d)))
    c.subscribe(["mode"])
    fake_i3.event_before_reply = "resize"
    assert c.command("nop x") is True, "the reply was lost to an event"
    assert seen == [(H.EVENT_MODE, {"change": "resize"})]
    assert c.command("nop y") is True, "connection desynchronised"
    time.sleep(0.05)
    assert fake_i3.commands == ["nop x", "nop y"]
    c.close()


def test_poll_events_reads_a_mode_event_off_the_shared_socket(fake_i3):
    seen = []
    c = H.I3Client(lambda: fake_i3.path,
                   on_event=lambda k, d: seen.append((k, d)))
    c.subscribe(["mode"])
    fake_i3.send_event(2, {"change": "resize"})
    time.sleep(0.05)
    c.poll_events()
    assert seen == [(H.EVENT_MODE, {"change": "resize"})]
    c.close()


def test_poll_events_returns_without_blocking_when_nothing_is_pending(fake_i3):
    """It is called every loop iteration; a blocking read here would freeze the
    key path until i3 happened to say something."""
    c = H.I3Client(lambda: fake_i3.path)
    c.subscribe(["mode"])
    t0 = time.monotonic()
    for _ in range(5):
        c.poll_events()
    assert time.monotonic() - t0 < 0.5
    c.close()


def test_binding_state_reports_the_mode_i3_is_already_in(fake_i3):
    """Startup edge case: the daemon may be launched while i3 already holds a
    mode, and no `mode` event will ever be sent for a mode entered earlier."""
    fake_i3.binding_state = "resize"
    c = H.I3Client(lambda: fake_i3.path)
    assert c.binding_state() == "resize"
    c.close()


def test_binding_state_falls_back_to_default_when_i3_cannot_be_reached(tmp_path):
    c = H.I3Client(lambda: str(tmp_path / "nope.sock"))
    assert c.binding_state() == "default"


def test_the_subscription_is_re_established_after_an_i3_restart(tmp_path):
    """Spec edge case: i3 restarted while a layer is active. A subscription that
    is not renewed leaves the daemon silently un-arbitrated — the worst shape of
    this bug, because everything looks healthy."""
    first = FakeI3(tmp_path / "i3-a.sock")
    path = {"p": first.path}
    seen = []
    c = H.I3Client(lambda: path["p"], on_event=lambda k, d: seen.append((k, d)))
    c.subscribe(["mode"])
    first.close()

    second = FakeI3(tmp_path / "i3-b.sock")
    path["p"] = second.path
    for _ in range(3):
        c._retry_at = 0                   # skip the backoff, not the reconnect
        c.poll_events()
    assert second.subscriptions == [["mode"]], "did not re-subscribe after restart"
    second.send_event(2, {"change": "resize"})
    time.sleep(0.05)
    c.poll_events()
    assert seen == [(H.EVENT_MODE, {"change": "resize"})], \
        "events stopped flowing after the restart"
    c.close()
    second.close()


def test_a_reconnect_is_reported_so_the_daemon_can_re_read_the_mode(tmp_path):
    """i3's mode resets when it restarts, so the daemon must re-read the binding
    state rather than keep believing whatever it last heard."""
    first = FakeI3(tmp_path / "i3-a.sock")
    path = {"p": first.path}
    c = H.I3Client(lambda: path["p"])
    c.subscribe(["mode"])
    assert c.poll_events() is False, "a healthy connection is not a reconnect"
    first.close()
    second = FakeI3(tmp_path / "i3-b.sock")
    path["p"] = second.path
    reconnected = False
    for _ in range(3):
        c._retry_at = 0
        reconnected = c.poll_events() or reconnected
    assert reconnected is True, "reconnect was not reported"
    assert c.poll_events() is False, "reported the same reconnect twice"
    c.close()
    second.close()


def test_reconnect_attempts_are_rate_limited(tmp_path):
    """adr0014: no tight retry loop against a server that is gone. poll_events
    runs every iteration of the key loop."""
    tries = []

    def getter():
        tries.append(time.monotonic())
        raise OSError("no i3")

    c = H.I3Client(getter)
    c.subscribe(["mode"])
    for _ in range(50):
        c.poll_events()
    assert len(tries) <= 2, f"hammered i3's socket {len(tries)} times"


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


def test_exit_keys_are_also_grabbed_with_shift_held():
    """Shift is not a layer modifier, so no active grab routes it to us: a bare
    `q` grab has mask 0 and `Shift+q` arrives with ShiftMask, matching nothing.
    The layer engine would exit fine (it matches exit keys on the keysym alone,
    layers.py:205) — the event just never reaches it, so the key goes to the
    focused window and the layer is stuck. i3's nav mode bound `Shift+q`
    explicitly (i3/config.common:445); parity needs the grab.

    Exit keys only. Grabbing Shift+ variants of the layer's movement binds would
    take chords the daemon has no meaning for, and grabbing Shift_L/R outright
    would swallow every capital letter — fatal on :10, where xrdp synthesises
    Shift around every character it sends.
    """
    chords = H.chords_for(B, "nav")
    for k in B.LAYERS["nav"].exit_keys:
        assert f"Shift+{k}" in chords, (
            f"exit key {k!r} not grabbed with Shift held — "
            f"layer cannot be left one-handed while Shift is down")


def _table(layers):
    return type("T", (), {"BINDS": [B.Bind("$mod+o", B.enter_layer("plain"))],
                          "LAYERS": layers})


PLAIN = {"plain": B.Layer(binds=[B.Bind("h", "focus left")],
                          exit_keys=["q", "Escape"])}


@pytest.mark.parametrize("key", ["q", "Escape"])
@pytest.mark.parametrize("mod", ["Shift", "Ctrl", "Mod1"])
def test_a_layer_with_no_mods_still_grabs_its_exit_keys_held(mod, key):
    """dotfiles-hwds.18. Ctrl/Alt-held exits work in the nav layer only by
    accident of the X ACTIVE grab: nav declares Ctrl and Mod1, so their keysyms
    are grabbed, and holding one routes every following key to the daemon
    whatever the mask says. A layer that declares NO mods gets none of those
    grabs, so `Ctrl+q` arrives with CtrlMask, matches no grab, is never
    delivered — and the layer is a trap in exactly the way hwds.17 described for
    Shift. validate() does not require mods, so such a layer is legal input."""
    chords = H.layer_chords(_table(PLAIN), "plain")
    assert f"{mod}+{key}" in chords, \
        f"{mod}+{key} not grabbed — a mods-less layer cannot be left one-handed"


def test_the_exit_variants_do_not_leak_onto_a_layers_other_binds():
    """Scoped to exit keys, like the Shift fix before it. Widening it would take
    chords the daemon has no meaning for from every application."""
    chords = H.layer_chords(_table(PLAIN), "plain")
    for dead in ("Ctrl+h", "Mod1+h", "Shift+h"):
        assert dead not in chords


def test_a_declared_modifier_is_not_also_grabbed_as_an_exit_variant():
    """The other half of the rule, and the reason it is not simply 'always emit
    every variant': a DECLARED modifier's keysyms are grabbed, which starts the
    active grab that routes the exit key already. Adding a passive `Mod1+q` on
    top would be a grab i3 owns on the xrdp display — `$mod+q` is `split toggle`
    in i3/config.common and `$mod` is Mod1 there — so every nav entry would log
    a BadAccess, breaking the zero-BadAccess assertion this epic runs on."""
    chords = H.chords_for(B, "nav")
    assert "Control_L" in chords, "nav declares Ctrl, so its keysym is grabbed"
    assert "Ctrl+q" not in chords
    assert "Mod1+q" not in chords, "would collide with i3's $mod+q on :10"
    assert "Shift+q" in chords, "Shift is never routed by an active grab"


def test_a_layer_declaring_only_ctrl_still_gets_the_alt_variant():
    """The gap is per MODIFIER, not per layer: declaring Ctrl routes Ctrl-held
    keys and says nothing about Alt."""
    layers = {"plain": B.Layer(
        binds=[B.Bind("h", "focus left")],
        mods={"move": B.Mod("Ctrl", (B.Bind("h", "move left"),))},
        exit_keys=["q"])}
    chords = H.layer_chords(_table(layers), "plain")
    assert "Mod1+q" in chords, "Alt-held exit is undeliverable in this layer"
    assert "Ctrl+q" not in chords, "already routed by the Ctrl active grab"


def test_shift_variants_are_not_added_to_ordinary_layer_binds():
    """The Shift grab is scoped to exit keys. Widening it would silently take
    chords from applications for as long as a layer is active."""
    chords = H.chords_for(B, "nav")
    assert "Shift+h" not in chords
    assert "Ctrl+Shift+h" not in chords


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
# the Daemon side of the arbitration (dotfiles-hwds.10)
# --------------------------------------------------------------------------

class FakeXServer(FakeDisplay):
    """A FakeDisplay that also answers the calls Daemon.__init__ makes: the XI2
    extension probe, a root window to grab on, and an (empty) resource database.

    `keysym_to_keycode` takes an INTEGER keysym exactly as python-xlib does,
    because the Daemon reaches X through the real XAdapter — a fake that accepts
    the keysym NAME would let the adapter be wrong and still pass. Same reason
    the root window speaks `xinput_grab_keycode` and NOT `grab_key`: the adapter
    grabs through XI2 now, and a root that still answered the core call would
    let a half-finished port pass.
    """

    def __init__(self, keymap=None, devices=None, xi2=True, fail_chords=()):
        # Must cover every keysym the SHIPPED table binds: a chord whose keysym
        # is absent here resolves to keycode 0 and lands in grabs.problems, so
        # an incomplete fake keymap reads as a grab failure in tests that are
        # asking about something else entirely. `d` and `p` arrived with the
        # entry-point cutover (dotfiles-hwds.33); the digit row with the
        # workspace-group cutover (dotfiles-hwds.34), keycodes 10-17 as on a
        # standard PC layout; the layout group's letters and `minus` with
        # dotfiles-hwds.36; `Print` with the screenshot group
        # (dotfiles-hwds.39), keycode 107 as on a standard PC layout; `Tab`,
        # `w`, `ISO_Left_Tab` and `space` with the alt-tab switcher
        # (dotfiles-hwds.40) — 23/25/23/65, the codes qs-keymon.py's INTERESTING
        # set carried before the cutover deleted it. ISO_Left_Tab deliberately
        # shares Tab's keycode: it IS the shifted Tab key, which is why the
        # layer's `$mod+Shift+ISO_Left_Tab` grab is a different MASK on the same
        # code rather than a second key. `n` and `v` arrived with the overlay
        # group (dotfiles-hwds.43) — 57/55, standard PC layout. `9`, `m` and
        # `F5` with the apps + session group (dotfiles-hwds.46) — 18/58/71.
        # `9` is not part of the workspace row above: that row stops at 8 and
        # `$mod+0` opens the system layer, so the digit had never been needed.
        super().__init__(keymap=keymap or {"o": 32, "h": 43, "q": 24,
                                           "Tab": 23, "ISO_Left_Tab": 23,
                                           "w": 25, "space": 65,
                                           "1": 10, "2": 11, "3": 12,
                                           "4": 13, "5": 14, "6": 15,
                                           "7": 16, "8": 17, "0": 19,
                                           "minus": 20, "e": 26, "t": 28,
                                           "y": 29, "u": 30, "a": 38,
                                           "s": 39, "z": 52, "b": 56,
                                           "Escape": 9, "Return": 36,
                                           "Left": 113, "Right": 114,
                                           "Up": 111, "Down": 116,
                                           "j": 44, "k": 45, "l": 46,
                                           "d": 40, "p": 33, "Print": 107,
                                           "n": 57, "v": 55,
                                           "9": 18, "m": 58, "F5": 71,
                                           "Super_L": 133, "Control_L": 37,
                                           "Control_R": 105, "Alt_L": 64,
                                           "Alt_R": 108, "Meta_L": 205,
                                           "Meta_R": 206},
                         fail_chords=fail_chords, devices=devices, xi2=xi2)
        self.selected_events = []
        self.grab_devices = []       # deviceid per XIGrabKeycode call
        self._root = XI2Root(self)

    def keysym_to_keycode(self, keysym):
        from Xlib import XK                                  # noqa: PLC0415
        for name, code in self.keymap.items():
            if XK.string_to_keysym(name) == keysym:
                return code
        return 0

    def keycode_to_keysym(self, keycode, index):
        from Xlib import XK                                  # noqa: PLC0415
        for name, code in self.keymap.items():
            if code == keycode:
                return XK.string_to_keysym(name)
        return 0

    def intern_atom(self, name):
        return 1

    def screen(self):
        return SimpleNamespace(root=self._root)


class Lines:
    def __init__(self):
        self.lines = []

    def publish(self, state):
        self.lines.append(state)

    def poll(self):
        pass

    def close(self):
        pass


def xi_event(detail, state=0, kind="press", sourceid=5, deviceid=3,
             flags=0, when=0):
    """One XI2 device event in the shape python-xlib hands the daemon.

    Deliberately NOT a core `KeyPress`: every grab the daemon holds is an
    `XIGrabKeycode`, so a core key event cannot be one of ours, and `key_event`
    refuses it. A fake that still spoke core would let a half-finished port
    pass every test in this file.
    """
    return SimpleNamespace(
        type=H.GENERIC_EVENT,
        evtype=H.XI_KEY_PRESS if kind == "press" else H.XI_KEY_RELEASE,
        data=SimpleNamespace(
            detail=detail, time=when, sourceid=sourceid, deviceid=deviceid,
            flags=flags,
            mods={"base_mods": state, "latched_mods": 0, "locked_mods": 0,
                  "effective_mods": state}))


def key_press(detail, state=0, **kw):
    return xi_event(detail, state, kind="press", **kw)


def arbitration_daemon(fake, table=B):
    """The real Daemon over a fake X server and a real I3Client against the
    stub i3 — the composition under test, not a re-implementation of it."""
    xd = FakeXServer()
    pub = Lines()
    dae = H.Daemon(table, xd, pub, i3=H.I3Client(lambda: fake.path),
                   display=":0")
    return dae, xd, pub


def test_daemon_subscribes_to_mode_on_the_connection_it_already_has(fake_i3):
    dae, _, _ = arbitration_daemon(fake_i3)
    time.sleep(0.05)
    assert fake_i3.subscriptions == [["mode"]]
    assert fake_i3.connections == 1, "the daemon opened a second i3 connection"
    dae.close()


def test_a_daemon_started_while_i3_holds_a_mode_starts_arbitrated(fake_i3):
    """No `mode` event is ever sent for a mode entered before we subscribed."""
    fake_i3.binding_state = "resize"
    dae, _, _ = arbitration_daemon(fake_i3)
    assert dae.engine.i3_mode == "resize"
    dae.close()


def test_a_refused_layer_entry_asks_x_for_no_grabs(fake_i3):
    """The reproduced defect: `i3-msg 'mode "resize"'` then `$mod+o` produced 11
    BadAccess (i3's mode already owns those bare keys) AND a published
    layer=nav. Refusing the transition means the grabs are never requested, so
    there is nothing to be refused."""
    fake_i3.binding_state = "resize"
    dae, xd, pub = arbitration_daemon(fake_i3)
    grabs_before = len(xd.grabs)
    dae.pump(key_press(32, H.MOD4))                 # $mod+o
    assert dae.engine.state["layer"] == "default"
    assert len(xd.grabs) == grabs_before, \
        f"attempted {len(xd.grabs) - grabs_before} grabs i3's mode owns"
    assert "h" not in dae.grabs.chords
    assert pub.lines == [], "published a layer it never took"
    dae.close()


def test_layer_entry_still_works_when_i3_is_in_the_default_mode(fake_i3):
    """The negative control at daemon level: arbitration must not be satisfied
    by refusing every entry."""
    dae, xd, pub = arbitration_daemon(fake_i3)
    dae.pump(key_press(32, H.MOD4))                 # $mod+o
    assert dae.engine.state["layer"] == "nav"
    assert "h" in dae.grabs.chords, "nav's bare keys were not grabbed"
    assert pub.lines == [{"layer": "nav", "mod": None}]
    assert not dae.grabs.problems, f"BadAccess on entry: {dae.grabs.problems}"
    dae.close()


def test_an_i3_mode_event_exits_the_layer_and_releases_its_grabs(fake_i3):
    """The other direction: i3 takes a mode while the daemon holds a layer. The
    layer must be dropped AND its grabs given back, or the daemon keeps eating
    keys for a layer it no longer claims."""
    dae, xd, pub = arbitration_daemon(fake_i3)
    dae.pump(key_press(32, H.MOD4))
    assert "h" in dae.grabs.chords
    pub.lines.clear()
    xd.ungrabs.clear()

    fake_i3.send_event(2, {"change": "resize"})
    time.sleep(0.05)
    dae.pump_i3()

    assert dae.engine.state["layer"] == "default"
    assert "h" not in dae.grabs.chords, "kept the layer's grabs after yielding"
    assert xd.ungrabs, "grabs were never released"
    assert pub.lines == [{"layer": "default", "mod": None}]
    dae.close()


def test_the_daemon_re_reads_the_binding_state_after_i3_restarts(tmp_path):
    """i3's mode resets on restart. A daemon that keeps believing the last mode
    it heard would refuse every layer entry for the rest of the session."""
    first = FakeI3(tmp_path / "i3-a.sock", binding_state="resize")
    path = {"p": first.path}
    xd, pub = FakeXServer(), Lines()
    dae = H.Daemon(B, xd, pub, i3=H.I3Client(lambda: path["p"]), display=":0")
    assert dae.engine.i3_mode == "resize"
    first.close()

    second = FakeI3(tmp_path / "i3-b.sock", binding_state="default")
    path["p"] = second.path
    for _ in range(3):
        dae.i3._retry_at = 0
        dae.pump_i3()
    assert dae.engine.i3_mode == "default", \
        "stayed latched on a mode the restarted i3 no longer has"
    dae.pump(key_press(32, H.MOD4))
    assert dae.engine.state["layer"] == "nav"
    dae.close()
    second.close()


def test_an_i3_stub_without_event_support_leaves_the_daemon_usable():
    """live_check.py drives the real Daemon with a minimal NullI3. Event support
    is optional wiring, not a new requirement on every injected client."""

    class NullI3:
        def command(self, cmd):
            return True

        def close(self):
            pass

    xd, pub = FakeXServer(), Lines()
    dae = H.Daemon(B, xd, pub, i3=NullI3(), display=":0")
    dae.pump_i3()                                   # must not raise
    dae.pump(key_press(32, H.MOD4))
    assert dae.engine.state["layer"] == "nav"
    dae.close()


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
            self.grab_devices = []
            self.selected_events = []
            self._root = XI2Root(self, prop=SimpleNamespace(
                value=b"i3wm.mod:\tMod1\nXft.dpi:\t96\n"))

        def keysym_to_keycode(self, keysym):
            from Xlib import XK                           # noqa: PLC0415
            return 32 if keysym == XK.string_to_keysym("o") else 0

        def intern_atom(self, name):
            return 1

        def screen(self):
            return SimpleNamespace(root=self._root)

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


def test_the_daemons_own_resolver_pins_its_display(monkeypatch):
    """Exercises the LAMBDA the Daemon actually builds, not the function it
    wraps. Testing i3_socket_path directly left the wiring unguarded: dropping
    `display=` from that lambda passed the whole suite while reintroducing
    hwds.6 — a :10 daemon resolving :0's socket whenever the root property is
    unreadable."""
    monkeypatch.setenv("DISPLAY", ":0")            # the ambient, wrong one
    seen = {}

    def fake_run(cmd, **kw):
        seen.update(kw.get("env", {}))

        class R:
            stdout = "/run/user/1000/i3/ipc-socket.X\n"
        return R()

    monkeypatch.setattr(H.subprocess, "run", fake_run)

    class XNoProperty(FakeDisplay):
        """A display whose I3_SOCKET_PATH is absent, forcing the CLI fallback."""

        def __init__(self):
            super().__init__()
            self.grab_devices = []
            self.selected_events = []
            self._root = XI2Root(self)

        def intern_atom(self, name):
            return 1

        def screen(self):
            return SimpleNamespace(root=self._root)

    table = type("T", (), {"BINDS": [], "LAYERS": {}})
    pub = type("P", (), {"publish": lambda self, s: None,
                         "close": lambda self: None,
                         "poll": lambda self: None})()
    dae = H.Daemon(table, XNoProperty(), pub, display=":10")
    dae.i3._path_getter()                          # the wiring under test
    assert seen.get("DISPLAY") == ":10", \
        f"daemon resolver used the ambient display: {seen.get('DISPLAY')!r}"


# ==========================================================================
# XI2 port (sp020 Task 11, dotfiles-hwds.13)
#
# Core `KeyPress` carries no device identity, so the daemon could not tell one
# keyboard from another — or a real keystroke from an injected one — and
# injection shares the display with real input. Everything below is about the
# one thing that changes: grabs go through `XIGrabKeycode` and every dispatched
# event carries the SOURCE device that produced it.
# ==========================================================================


class _NullI3:
    """An i3 with no event support at all — `wire_i3_mode` degrades to 'never
    arbitrates', which is the embedder case the daemon documents."""

    def __init__(self):
        self.cmds = []

    def command(self, cmd):
        self.cmds.append(cmd)
        return True

    def close(self):
        pass


def xi2_daemon(table, xd=None, i3=None, pub=None):
    """The real Daemon over the XI2 fake server — the composition under test."""
    xd = xd or FakeXServer()
    pub = pub or Lines()
    i3 = i3 or _NullI3()
    return H.Daemon(table, xd, pub, i3=i3, display=":0"), xd, pub, i3


def table_of(binds, layers=None, ignore=()):
    return type("T", (), {"BINDS": list(binds),
                          "LAYERS": dict(layers or {}),
                          "IGNORE_DEVICES": list(ignore)})


# -- the grab mechanism ----------------------------------------------------

def test_the_all_master_devices_constant_is_the_protocols():
    """Pinned against the LIBRARY's value, not against itself: asserting that
    the grabs used `H.XI_ALL_MASTER_DEVICES` says nothing if that constant is
    wrong, and `XIAllDevices` (0) — the neighbouring value — would grab from
    floating slaves too and deliver the same press twice."""
    from Xlib.ext import xinput                             # noqa: PLC0415
    assert H.XI_ALL_MASTER_DEVICES == xinput.AllMasterDevices == 1
    assert H.XI_ALL_MASTER_DEVICES != xinput.AllDevices


def test_the_key_repeat_flag_constant_is_the_protocols():
    """Same pin as the constant above, for the same reason and one that bit:
    every auto-repeat unit test FEEDS `H.XI_KEY_REPEAT` as the event's flags, so
    all of them agree with each other no matter what the value is. Mutating it
    to `1 << 15` survived the whole pytest suite and was caught only by the live
    stage — which is the machinery that replaced the deleted core coalescer, so
    it is the last thing that should rest on a live run alone."""
    from Xlib.ext import xinput                             # noqa: PLC0415
    assert H.XI_KEY_REPEAT == xinput.KeyRepeat == 1 << 16


def test_grabs_go_through_xi2_against_all_master_devices():
    """`XIGrabKeycode` per chord against `XIAllMasterDevices` — the grab that
    carries a sourceid. XI2Root raises on the core call, so a port that left
    `XGrabKey` in place cannot reach this assertion."""
    xd = FakeXServer()
    H.GrabManager(H.XAdapter(xd, xd.screen().root)).sync_binds(["Mod4+o"])
    assert xd.grab_devices, "no XIGrabKeycode was issued at all"
    assert set(xd.grab_devices) == {1}, xd.grab_devices    # XIAllMasterDevices


def test_the_four_lock_variants_survive_the_xi2_port():
    """poc013 measured a bare-mask grab firing 0/3 with NumLock on. The bits
    ride in the event state under XI2 exactly as they did under core."""
    xd = FakeXServer()
    H.GrabManager(H.XAdapter(xd, xd.screen().root)).sync_binds(["Mod4+o"])
    base = H.MOD4
    assert grabs_for(xd, 32) == sorted([
        base, base | H.LOCK, base | H.MOD2, base | H.LOCK | H.MOD2])


def test_a_refused_xi2_grab_is_reported_per_chord_not_raised():
    """XI2 reports a refusal in the REPLY (a per-modifier failure list) rather
    than as an async X error. The degradation contract is unchanged: that chord
    is not ours, every other chord keeps working."""
    xd = FakeXServer(fail_chords={43})              # 'h'
    g = H.GrabManager(H.XAdapter(xd, xd.screen().root))
    g.sync_binds(["Mod4+h", "Mod4+o"])
    assert any("h" in p for p in g.problems), g.problems
    assert any("BadAccess" in p for p in g.problems), g.problems
    assert "Mod4+h" not in g.chords
    assert grabs_for(xd, 32), "the other chord must still be grabbed"


def test_ungrab_goes_through_xi2_too():
    xd = FakeXServer()
    g = H.GrabManager(H.XAdapter(xd, xd.screen().root))
    g.sync_binds(["Mod4+o"])
    g.sync_binds([])
    assert len([1 for kc, _ in xd.ungrabs if kc == 32]) == 4, xd.ungrabs


def test_the_daemon_asks_for_xi2_device_change_events_and_only_those():
    """Hierarchy / device-changed is how a keyboard appearing or disappearing
    invalidates the name cache.

    KeyPress must NOT be in that mask. A root-wide XI2 key selection would
    deliver EVERY keystroke in the session to the daemon — passwords included —
    where a passive grab delivers only the chords it registered."""
    from Xlib.ext import xinput                             # noqa: PLC0415
    dae, xd, _, _ = xi2_daemon(B)
    assert xd.selected_events, "the daemon selected no XI2 device events"
    masks = [m for spec in xd.selected_events for _, m in spec]
    assert all(m & xinput.HierarchyChangedMask for m in masks), masks
    assert not any(m & (xinput.KeyPressMask | xinput.KeyReleaseMask)
                   for m in masks), \
        "selected key events on the ROOT — that is every keystroke, not ours"
    dae.close()


def test_xi2_missing_fails_fast_with_a_named_error():
    """An XI2-less display must NOT degrade to core grabs: that would leave the
    daemon running with no device attribution and nothing saying so."""
    xd = FakeXServer(xi2=False)
    with pytest.raises(H.XI2Unavailable) as e:
        H.XAdapter(xd, xd.screen().root)
    assert "no XInputExtension" in str(e.value), str(e.value)
    assert xd.grabs == [], "asked for a grab on a display it cannot grab on"


def test_xi2_too_old_fails_fast_naming_the_version():
    class OldXI(FakeXServer):
        def xinput_query_version(self):
            return SimpleNamespace(major_version=1, minor_version=5)

    xd = OldXI()
    with pytest.raises(H.XI2Unavailable) as e:
        H.XAdapter(xd, xd.screen().root)
    assert "1.5" in str(e.value) and "XI2" in str(e.value)


def test_main_reports_an_xi2_less_display_as_a_named_non_zero_exit(
        monkeypatch, capsys):
    """The operator-visible contract: a named message and a distinct code, not
    a traceback (adr0014 fail-fast, and the launcher reads the code)."""
    def boom(table, display):
        raise H.XI2Unavailable("this display has no XInputExtension")

    monkeypatch.setattr(H, "run_daemon", boom)
    monkeypatch.setattr(sys, "argv", ["hotkeyd"])
    rc = H.main()
    err = capsys.readouterr().err
    assert rc == 5, rc
    assert "XI2 unavailable" in err and "XInputExtension" in err
    assert "Traceback" not in err


# -- the event normaliser --------------------------------------------------

def test_key_event_reads_detail_state_and_sourceid_off_an_xi2_event():
    k = H.key_event(xi_event(43, state=H.CTRL | H.MOD2, sourceid=12,
                             deviceid=3, when=1234))
    assert (k.kind, k.detail, k.state, k.time) == ("press", 43,
                                                   H.CTRL | H.MOD2, 1234)
    assert k.sourceid == 12 and k.deviceid == 3
    assert k.repeat is False


def test_key_event_reads_the_effective_modifier_mask():
    """Effective, not base: it folds in the LOCKED bits, which is what made the
    core `state` field equal to it — and `to_event` strips those bits later."""
    ev = xi_event(43)
    ev.data.mods = {"base_mods": 0, "latched_mods": 0,
                    "locked_mods": H.MOD2, "effective_mods": H.MOD2}
    assert H.key_event(ev).state == H.MOD2


def test_key_event_marks_an_auto_repeat_press():
    assert H.key_event(xi_event(43, flags=H.XI_KEY_REPEAT)).repeat is True


def test_key_event_refuses_a_core_key_event():
    """A core `KeyPress` cannot be one of ours — every grab is an XI2 grab — and
    accepting one would dispatch an event with no resolvable source device,
    which is the blind spot this port removes."""
    from Xlib import X                                       # noqa: PLC0415
    core = SimpleNamespace(type=X.KeyPress, detail=43, state=0, time=0)
    assert H.key_event(core) is None


def test_key_event_ignores_a_non_key_generic_event():
    assert H.key_event(SimpleNamespace(
        type=H.GENERIC_EVENT, evtype=H.XI_HIERARCHY_CHANGED, data=None)) is None


# -- device attribution ----------------------------------------------------

def test_every_dispatched_event_carries_its_source_device():
    """The positive half. Asserted on what the ENGINE received, because that is
    where a `device=` predicate is judged."""
    seen = []
    table = table_of([B.Bind("$mod+o", lambda ev: seen.append(ev))])
    dae, _, _, _ = xi2_daemon(table)
    dae.pump(key_press(32, H.MOD4, sourceid=12))
    assert len(seen) == 1, seen
    assert seen[0].device_id == 12
    assert seen[0].device == "AT Translated Set 2 keyboard"
    dae.close()


def test_attribution_reads_the_source_slave_not_the_master_in_the_header():
    """XI2 puts the master in `deviceid` and the physical slave in `sourceid`.
    Reading the header would make every keyboard on a display report as
    `Virtual core keyboard` and the whole predicate would be a no-op."""
    seen = []
    table = table_of([B.Bind("$mod+o", lambda ev: seen.append(ev))])
    dae, xd, _, _ = xi2_daemon(table)
    xd.devices[3] = "Virtual core keyboard"
    dae.pump(key_press(32, H.MOD4, sourceid=13, deviceid=3))
    assert seen[0].device == "BlueZ 5.86 (MCS)", seen[0]
    assert 3 not in xd.device_queries, "resolved the MASTER, not the source"
    dae.close()


def test_a_device_scoped_bind_fires_for_its_own_source():
    table = table_of([B.Bind("$mod+o", "nop laptop",
                             device="AT Translated Set 2 keyboard")])
    dae, _, _, i3 = xi2_daemon(table)
    assert dae.pump(key_press(32, H.MOD4, sourceid=12)) == ["nop laptop"]
    assert i3.cmds == ["nop laptop"]
    dae.close()


def test_a_device_scoped_bind_is_inert_for_another_source():
    """The negative half, and the one that matters: a positive-only test passes
    against an implementation that ignores `device=` entirely."""
    table = table_of([B.Bind("$mod+o", "nop laptop",
                             device="AT Translated Set 2 keyboard")])
    dae, _, _, i3 = xi2_daemon(table)
    assert dae.pump(key_press(32, H.MOD4, sourceid=13)) == []   # BlueZ
    dae.pump(xi_event(32, H.MOD4, kind="release", sourceid=13))
    assert dae.pump(key_press(32, H.MOD4, sourceid=5)) == []    # XTEST
    assert i3.cmds == []
    dae.close()


def test_two_binds_on_one_chord_split_by_source_device():
    """What `device=` is FOR: one chord, two meanings, resolved by who typed
    it. Also the reason the validator does not call these a duplicate."""
    table = table_of([B.Bind("$mod+o", "nop laptop",
                             device="AT Translated Set 2 keyboard"),
                      B.Bind("$mod+o", "nop bluetooth",
                             device="BlueZ 5.86 (MCS)")])
    assert B.validate(table.BINDS, table.LAYERS) == []
    dae, _, _, _ = xi2_daemon(table)
    assert dae.pump(key_press(32, H.MOD4, sourceid=12)) == ["nop laptop"]
    dae.pump(xi_event(32, H.MOD4, kind="release", sourceid=12))
    assert dae.pump(key_press(32, H.MOD4, sourceid=13)) == ["nop bluetooth"]
    dae.close()


def test_an_unscoped_bind_still_fires_for_every_source():
    """Parity: the whole shipped table is unscoped and must behave exactly as it
    did before device identity existed."""
    table = table_of([B.Bind("$mod+o", "nop any")])
    dae, _, _, _ = xi2_daemon(table)
    for src in (5, 12, 13):
        assert dae.pump(key_press(32, H.MOD4, sourceid=src)) == ["nop any"]
        dae.pump(xi_event(32, H.MOD4, kind="release", sourceid=src))
    dae.close()


def test_a_scoped_bind_does_not_fire_for_an_unattributable_source():
    """A device that vanished between the press and the lookup answers
    BadDevice. The key still dispatches — but it cannot satisfy a predicate
    whose entire purpose is attribution."""
    table = table_of([B.Bind("$mod+o", "nop laptop",
                             device="AT Translated Set 2 keyboard"),
                      B.Bind("$mod+h", "nop any")])
    dae, xd, _, _ = xi2_daemon(table)
    assert dae.pump(key_press(32, H.MOD4, sourceid=99)) == []
    assert dae.pump(key_press(43, H.MOD4, sourceid=99)) == ["nop any"]
    assert xd.device_queries.count(99) >= 1
    dae.close()


def test_ignore_devices_drops_that_source_entirely():
    table = table_of([B.Bind("$mod+o", "nop any")],
                     ignore=["Virtual core XTEST keyboard"])
    dae, _, _, i3 = xi2_daemon(table)
    assert dae.pump(key_press(32, H.MOD4, sourceid=5)) == []
    assert i3.cmds == []
    assert dae.pump(key_press(32, H.MOD4, sourceid=12)) == ["nop any"]
    dae.close()


def test_ignore_devices_is_read_off_the_current_table_so_a_reload_changes_it():
    table = table_of([B.Bind("$mod+o", "nop any")])
    dae, _, _, _ = xi2_daemon(table)
    assert dae.pump(key_press(32, H.MOD4, sourceid=5)) == ["nop any"]
    dae.table = table_of([B.Bind("$mod+o", "nop any")],
                         ignore=["Virtual core XTEST keyboard"])
    assert dae.pump(key_press(32, H.MOD4, sourceid=5)) == []
    dae.close()


def test_the_default_shipped_table_ignores_nothing():
    """Dropping XTEST by default would silently kill every xdotool-driven bind
    and every harness in this repo — and whether xrdp's synthesised Shift is
    XTEST-sourced is UNMEASURED (sp020 Task 15), so nothing is ignored yet."""
    assert list(B.IGNORE_DEVICES) == []


# -- the device-name cache -------------------------------------------------

def test_a_device_name_is_resolved_once_and_then_cached():
    reg = H.DeviceRegistry(FakeXServer())
    assert reg.name(12) == "AT Translated Set 2 keyboard"
    assert reg.name(12) == "AT Translated Set 2 keyboard"
    assert reg.d.device_queries == [12], "queried X twice for one device"


def test_a_hierarchy_change_invalidates_the_cache():
    """A bluetooth keyboard powering off, or one plugged in after startup: ids
    are reused, so a stale name would attribute one keyboard's keys to
    another."""
    dae, xd, _, _ = xi2_daemon(B)
    dae.pump(key_press(32, H.MOD4, sourceid=13))
    assert dae.devices.name(13) == "BlueZ 5.86 (MCS)"
    xd.devices[13] = "Some Other Keyboard"
    assert dae.devices.name(13) == "BlueZ 5.86 (MCS)", "cache not in play"
    dae.pump(SimpleNamespace(type=H.GENERIC_EVENT,
                             evtype=H.XI_HIERARCHY_CHANGED, data=None))
    assert dae.devices.name(13) == "Some Other Keyboard"
    dae.close()


def test_a_failed_lookup_is_re_queried_so_a_later_device_resolves():
    """An id absent now may exist after the next hierarchy change — a bluetooth
    keyboard powering back on — so a miss must never become permanent."""
    reg = H.DeviceRegistry(FakeXServer())
    assert reg.name(99) is None
    reg.d.devices[99] = "Late Arrival Keyboard"
    assert reg.name(99) == "Late Arrival Keyboard"
    assert reg.d.device_queries.count(99) == 2, reg.d.device_queries


def test_a_vanished_device_does_not_crash_the_pump():
    table = table_of([B.Bind("$mod+o", "nop any")])
    dae, _, _, _ = xi2_daemon(table)
    assert dae.pump(key_press(32, H.MOD4, sourceid=404)) == ["nop any"]
    dae.close()


# -- auto-repeat under XI2 -------------------------------------------------

def test_an_auto_repeat_flagged_press_dispatches_nothing():
    """XI2 sets XIKeyRepeat on the press and sends no synthetic release, so the
    flag — not a timestamp pair — is the discriminator after the port."""
    table = table_of([B.Bind("$mod+o", "nop any")])
    dae, _, _, i3 = xi2_daemon(table)
    assert dae.pump(key_press(32, H.MOD4)) == ["nop any"]
    for _ in range(5):
        assert dae.pump(key_press(32, H.MOD4, flags=H.XI_KEY_REPEAT)) == []
    assert i3.cmds == ["nop any"]
    dae.close()


def test_the_repeat_flag_is_checked_independently_of_the_engines_wedge():
    """The engine also suppresses repeats, but only inside KEY_WEDGE_MS. A
    repeat arriving after a stall must still not fire, so the flag has to be
    judged in the daemon rather than left to that window."""
    table = table_of([B.Bind("$mod+o", "nop any")])
    dae, _, _, _ = xi2_daemon(table)
    clock = [1000.0]
    dae.engine.clock = lambda: clock[0]
    assert dae.pump(key_press(32, H.MOD4)) == ["nop any"]
    clock[0] += (L.KEY_WEDGE_MS / 1000.0) + 5      # far past the wedge
    assert dae.pump(key_press(32, H.MOD4, flags=H.XI_KEY_REPEAT)) == []
    dae.close()


def test_an_unflagged_repeat_press_of_one_key_still_fires_twice():
    """Fairness: the guard must eat auto-repeat and nothing else. A genuine
    double-tap arrives as two unflagged presses with a release between."""
    table = table_of([B.Bind("$mod+o", "nop any")])
    dae, _, _, _ = xi2_daemon(table)
    assert dae.pump(key_press(32, H.MOD4, when=100)) == ["nop any"]
    dae.pump(xi_event(32, H.MOD4, kind="release", when=105))
    assert dae.pump(key_press(32, H.MOD4, when=110)) == ["nop any"]
    dae.close()


# ==========================================================================
# hwds.27 — the daemon must be able to SAY why it changed layer
# ==========================================================================
# The live :10 daemon replayed `{"layer":"nav","mod":"resize"}` to the first bar
# that connected, ~30 s after it started, with nothing pressed. It logged
# nothing, so the recurrence would have been just as uninformative.
#
# The engine owns the log format (test_layers.py); what is asserted HERE is that
# the daemon actually FILLS it — a log whose keycode, mask and sourceid are all
# `none` in production is a log that cannot discriminate between the ticket's
# candidate causes, and every one of those three values is only available on
# this side of `to_event`.


def logging_daemon(table, xd=None):
    lines = []
    dae, xd, pub, i3 = xi2_daemon(table, xd=xd)
    dae.engine.log = lines.append
    return dae, xd, pub, lines


def transition_lines(lines):
    return [ln for ln in lines if ln.startswith("transition ")]


def test_pump_fills_the_transition_log_with_the_real_keycode_mask_and_source():
    """The whole diagnostic value of the log is these three fields. `state` here
    is Mod4 with CapsLock also on, because that is what the mask looks like in a
    real session and the log must show what the SERVER sent, not the cleaned-up
    version the matcher used."""
    table = table_of([B.Bind("$mod+o", B.enter_layer("nav"))],
                     {"nav": B.Layer(binds=[B.Bind("h", "focus left")],
                                     exit_keys=["q"])})
    dae, _, _, lines = logging_daemon(table)
    dae.pump(key_press(32, H.MOD4 | H.LOCK, sourceid=12))
    t = transition_lines(lines)
    assert len(t) == 1, lines
    line = t[0]
    assert "layer=default->nav" in line, line
    assert "keycode=32" in line, line
    assert f"mask=0x{H.MOD4 | H.LOCK:04x}" in line, line
    assert "mods=Mod4" in line, f"lock bits must not become a chord modifier: {line}"
    assert "sourceid=12" in line, line
    assert "AT Translated Set 2 keyboard" in line, line
    dae.close()


def test_an_injected_chord_is_logged_as_coming_from_the_xtest_device():
    """The discriminator the ticket needs. `binds.IGNORE_DEVICES` ships EMPTY,
    so an XTEST-injected `$mod+o` enters nav exactly like a typed one — the log
    is the only thing that can tell the two apart after the fact."""
    table = table_of([B.Bind("$mod+o", B.enter_layer("nav"))],
                     {"nav": B.Layer(binds=[B.Bind("h", "focus left")],
                                     exit_keys=["q"])})
    dae, _, _, lines = logging_daemon(table)
    dae.pump(key_press(32, H.MOD4, sourceid=5))     # 5 = the XTEST injector
    line = transition_lines(lines)[0]
    assert "sourceid=5" in line and "XTEST" in line, line
    dae.close()


def test_leaving_a_layer_through_the_daemon_is_logged_with_its_keycode():
    table = table_of([B.Bind("$mod+o", B.enter_layer("nav"))],
                     {"nav": B.Layer(binds=[B.Bind("h", "focus left")],
                                     exit_keys=["q"])})
    dae, _, _, lines = logging_daemon(table)
    dae.pump(key_press(32, H.MOD4))
    lines.clear()
    dae.pump(key_press(24))                         # q
    t = transition_lines(lines)
    assert len(t) == 1, lines
    assert "layer=nav->default" in t[0] and "keycode=24" in t[0], t[0]
    dae.close()


# -- ruling out cause 2: startup state served out of the replay buffer -----

def test_a_freshly_started_daemon_replays_nothing_to_a_client(tmp_path):
    """Cause 2 says the daemon may publish or compute an initial layer before it
    has read real modifier state, with the replay buffer then serving it. Driven
    through the REAL StatePublisher and a REAL socket client, because the claim
    is about what a connecting bar receives, not about engine state."""
    sock = tmp_path / "hotkeyd-test.sock"
    pub = L.StatePublisher(sock)
    xd = FakeXServer()
    dae = H.Daemon(B, xd, pub, i3=_NullI3(), display=":0")
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.connect(str(sock))
        pub.poll()
        c.settimeout(0.2)
        with pytest.raises((socket.timeout, TimeoutError, BlockingIOError)):
            c.recv(64)
        c.close()
    finally:
        dae.close()


def test_constructing_the_daemon_publishes_nothing_at_all():
    xd = FakeXServer()
    pub = Lines()
    dae = H.Daemon(B, xd, pub, i3=_NullI3(), display=":0")
    assert pub.lines == []
    assert dae.engine.state == {"layer": "default", "mod": None}
    dae.close()


# -- ruling out cause 3: an i3 restart putting the daemon into a layer -----

def test_no_i3_reconnect_or_mode_traffic_can_enter_a_layer():
    """Cause 3 is an artifact of the i3 restart that first spawned the daemon.
    `pump_i3` is the only thing that restart reaches, and it must be incapable
    of ENTERING a layer — it may only ever force one shut."""
    xd = FakeXServer()
    pub = Lines()

    class Restarting:
        """An i3 that reports a fresh connection on every poll, i.e. the worst
        case of a restarting window manager."""

        def __init__(self):
            self.modes = ["default", "resize", "default"]
            self.cmds = []

        def subscribe(self, events):
            return True

        def binding_state(self):
            return self.modes.pop(0) if self.modes else "default"

        def poll_events(self):
            return True

        def fileno(self):
            return None

        def command(self, cmd):
            self.cmds.append(cmd)
            return True

        def close(self):
            pass

    dae = H.Daemon(B, xd, pub, i3=Restarting(), display=":0")
    for _ in range(3):
        dae.pump_i3()
        assert dae.engine.state["layer"] == "default"
    assert all(line["layer"] == "default" for line in pub.lines), pub.lines
    dae.close()


# -- item 4: reconciling held-modifier belief against the server ------------

def test_the_idle_reconcile_costs_no_x_round_trip_when_nothing_is_held():
    """The invariant is only defensible if it is free in the common case. An
    unconditional `query_pointer` four times a second for the life of the
    session buys nothing while `_held` is empty — there is no belief to check."""
    dae, xd, _, _ = xi2_daemon(B)
    for _ in range(10):
        assert dae.reconcile_mods() is False
    assert xd.screen().root.pointer_queries == 0
    dae.close()


def test_the_daemon_retracts_a_modifier_the_server_says_is_not_down():
    """The observed state was `{"layer":"nav","mod":"resize"}` with a root
    query_pointer reporting mask 0x0. That contradiction is checkable, and the
    idle path is where it costs nothing to check it."""
    dae, xd, pub, _ = xi2_daemon(B)
    dae.pump(key_press(32, H.MOD4))                 # $mod+o -> nav
    dae.pump(key_press(64))                         # Alt_L held
    assert dae.engine.state == {"layer": "nav", "mod": "resize"}
    xd.screen().root.pointer_mask = 0               # the server disagrees
    pub.lines.clear()
    assert dae.reconcile_mods() is True
    assert dae.engine.state == {"layer": "nav", "mod": None}
    assert pub.lines == [{"layer": "nav", "mod": None}]
    assert xd.screen().root.pointer_queries == 1
    dae.close()


def test_the_daemon_keeps_a_modifier_the_server_confirms_is_down():
    dae, xd, pub, _ = xi2_daemon(B)
    dae.pump(key_press(32, H.MOD4))
    dae.pump(key_press(64))
    xd.screen().root.pointer_mask = H.MOD1 | H.LOCK  # lock bits are not layers
    pub.lines.clear()
    assert dae.reconcile_mods() is False
    assert dae.engine.state == {"layer": "nav", "mod": "resize"}
    assert pub.lines == []
    dae.close()


def test_the_reconcile_never_takes_the_layer_away():
    """X has no opinion about `nav`. A reconciler that dropped the layer on a
    mask mismatch would be inventing state from the other direction — and would
    silently cancel a legitimate nav the user is standing in."""
    dae, xd, _, _ = xi2_daemon(B)
    dae.pump(key_press(32, H.MOD4))
    dae.pump(key_press(64))
    xd.screen().root.pointer_mask = 0
    dae.reconcile_mods()
    assert dae.engine.state["layer"] == "nav"
    dae.close()


def test_a_failing_pointer_query_does_not_take_the_daemon_down():
    """adr0014: the idle path must not turn a transient X answer into a crash
    on a daemon that is otherwise serving the keyboard fine."""
    dae, xd, _, _ = xi2_daemon(B)
    dae.pump(key_press(32, H.MOD4))
    dae.pump(key_press(64))

    def boom():
        raise RuntimeError("BadWindow")

    xd.screen().root.query_pointer = boom
    assert dae.reconcile_mods() is False
    assert dae.engine.state == {"layer": "nav", "mod": "resize"}
    dae.close()


# --------------------------------------------------------------------------
# is this daemon SERVING? (dotfiles-hwds.28)
# --------------------------------------------------------------------------
#
# The defect this covers is a liveness check that cannot observe death. Before
# hwds.28 the only question `hotkeyd.sh` could ask was "does a process match
# --display :N", which is answered identically by a daemon serving the keyboard
# and by one frozen mid-loop. An operator who needs the real answer therefore has
# to reach for something outside the launcher — the live matrix reached for
# `xdpyinfo`, which was not installed on that machine, read the 127 as "the X
# server is gone", and filed a healthy :0 daemon as a zombie.
#
# So the probe has TWO hard requirements, and both are asserted below:
#   1. it must distinguish "alive" from "serving" — hence the heartbeat, which
#      is the only evidence that the run loop is actually turning;
#   2. it must not depend on a binary that may not be installed. A liveness
#      check that reports death when its own tool is missing is worse than no
#      check at all, which is the whole hwds.19/.21 lesson and, here, the
#      proximate cause of the bad report.

def test_the_lock_file_carries_a_heartbeat(tmp_path):
    """The loop's proof of life. flock alone cannot carry it: the kernel holds
    the lock for a process that is frozen, SIGSTOPped or spinning on a wedged
    syscall exactly as firmly as for one that is serving."""
    inst = H.SingleInstance(tmp_path / "hb.lock")
    try:
        before = (tmp_path / "hb.lock").stat().st_mtime
        os.utime(tmp_path / "hb.lock", (before - 60, before - 60))
        inst.beat(now=time.monotonic() + 3600)
        after = (tmp_path / "hb.lock").stat().st_mtime
        assert after > before - 60
    finally:
        inst.release()


def test_the_heartbeat_is_rate_limited_so_the_key_path_pays_nothing(tmp_path):
    """Called from the top of the run loop, which turns ~4x a second while idle
    and once per event otherwise. One utime per beat there would put a syscall
    on the key path for no gain, so beats are on a clock."""
    inst = H.SingleInstance(tmp_path / "hb.lock")
    try:
        calls = []
        inst._utime = lambda: calls.append(1)
        # Anchored past the beat the constructor already took, so this measures
        # the rate limiter rather than racing the startup beat.
        t0 = time.monotonic() + 10 * H.HEARTBEAT_PERIOD_S
        inst.beat(now=t0)
        inst.beat(now=t0 + 0.1)
        inst.beat(now=t0 + 0.2)
        assert len(calls) == 1, "a beat per loop turn is a syscall per keystroke"
        inst.beat(now=t0 + H.HEARTBEAT_PERIOD_S + 0.01)
        assert len(calls) == 2, "the heartbeat stopped beating"
    finally:
        inst.release()


def test_health_says_not_serving_when_no_daemon_ever_ran(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    rc, msg = H.health(":77", probe_display=lambda _n: None)
    assert rc == H.HEALTH_NOT_SERVING
    assert "no daemon" in msg.lower(), msg


def test_health_says_not_serving_when_the_heartbeat_has_stopped(
        tmp_path, monkeypatch):
    """A frozen daemon: the process is there, the flock is held, the state
    socket still accepts connections out of the listen backlog — and nothing
    turns. This is the shape the :0 report described, and pgrep calls it
    healthy."""
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    lock = H.lock_path(":77")
    lock.write_text("12345\n")
    old = time.time() - (H.HEARTBEAT_STALE_S * 4)
    os.utime(lock, (old, old))
    rc, msg = H.health(":77", probe_display=lambda _n: None)
    assert rc == H.HEALTH_NOT_SERVING
    assert "heartbeat" in msg.lower(), msg


def test_health_says_not_serving_when_the_display_is_unreachable(
        tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    lock = H.lock_path(":77")
    lock.write_text("12345\n")

    def gone(_name):
        return "cannot connect"

    rc, msg = H.health(":77", probe_display=gone)
    assert rc != H.HEALTH_OK
    assert ":77" in msg and "cannot connect" in msg, msg


def test_an_unreachable_display_is_not_the_code_start_reaps_on(
        tmp_path, monkeypatch):
    """The safety boundary. "Its loop stopped" is the daemon's own evidence
    about itself and is reapable; "the display did not answer ME" is the
    caller's evidence about the caller, and a `status` run from a tmux pane with
    no XAUTHORITY produces it against a daemon that is serving the session
    perfectly. Reaping on that would be this bug's own root cause — a missing
    credential read as a dead server — rebuilt into the recovery path."""
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    H.lock_path(":77").write_text("12345\n")
    unreachable, _ = H.health(":77", probe_display=lambda _n: "no protocol")
    assert unreachable == H.HEALTH_DISPLAY_UNREACHABLE
    assert unreachable != H.HEALTH_NOT_SERVING

    stale = H.lock_path(":78")
    stale.write_text("12345\n")
    old = time.time() - (H.HEARTBEAT_STALE_S * 4)
    os.utime(stale, (old, old))
    dead, _ = H.health(":78", probe_display=lambda _n: None)
    assert dead == H.HEALTH_NOT_SERVING


def test_health_says_serving_when_the_loop_beats_and_the_display_answers(
        tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    H.lock_path(":77").write_text("12345\n")
    rc, msg = H.health(":77", probe_display=lambda _n: None)
    assert rc == H.HEALTH_OK, msg
    assert "serving" in msg.lower(), msg


def test_health_never_shells_out(tmp_path, monkeypatch):
    """The root cause of the bad hwds.28 report. `xdpyinfo` was not installed,
    exited 127, and the 127 was read as a dead X server. Nothing on this path may
    depend on a binary being present — python-xlib is already a hard runtime
    dependency of the daemon itself, so the probe cannot be missing where the
    daemon can run."""
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    monkeypatch.setenv("PATH", "")
    H.lock_path(":77").write_text("12345\n")

    def forbidden(*a, **kw):
        raise AssertionError(f"health shelled out: {a!r}")

    monkeypatch.setattr(H.subprocess, "run", forbidden)
    monkeypatch.setattr(H.subprocess, "Popen", forbidden)
    rc, _ = H.health(":77", probe_display=lambda _n: None)
    assert rc == H.HEALTH_OK


def test_the_real_display_probe_reports_a_display_that_is_not_there():
    """The probe's own contract, against a display number nothing serves. Its
    counterpart — a reachable display answering None — runs under Xvfb in
    test-launcher.sh, where there is a real X server to answer."""
    assert H.probe_display(":99") is not None


def test_probe_display_needs_no_bind_table():
    """--health has to work on a daemon whose table is the reason it is sick,
    so the health path must not load or validate binds.py first."""
    rc = H.main_argv(["--health", "--display", ":99"])
    assert rc != H.HEALTH_OK


def test_the_display_probe_gives_up_instead_of_blocking(monkeypatch):
    """A HUNG X server never closes the connection, so python-xlib sits in
    `select(..., timeout=None)` inside the handshake forever. `hotkeyd.sh start`
    runs from i3's `exec_always`, so an unbounded probe there does not merely
    delay a diagnostic — it stalls the session's startup, on the very path that
    exists to get a keyboard back."""
    import Xlib.display                             # noqa: PLC0415

    def never_answers(_name):
        time.sleep(30)

    monkeypatch.setattr(H, "PROBE_TIMEOUT_S", 0.3)
    monkeypatch.setattr(Xlib.display, "Display", never_answers)
    t0 = time.monotonic()
    why = H.probe_display(":99")
    took = time.monotonic() - t0
    assert took < 5, f"probe blocked for {took:.1f}s"
    assert why is not None and "hung" in why.lower(), why


def test_the_probe_leaves_no_alarm_armed_behind_it(monkeypatch):
    """It arms SIGALRM. Anything left armed would fire later, inside whatever
    the caller does next."""
    import signal as sig                            # noqa: PLC0415
    H.probe_display(":99")
    assert sig.getitimer(sig.ITIMER_REAL) == (0.0, 0.0)
    assert sig.getsignal(sig.SIGALRM) in (sig.SIG_DFL, sig.SIG_IGN)


# --------------------------------------------------------------------------
# the alt-tab switcher: a HOLD layer (dotfiles-hwds.40)
# --------------------------------------------------------------------------
# The switcher is the first layer whose modifier is already DOWN when the layer
# is entered ($mod+Tab enters it). Everything below follows from that one fact,
# and every one of these assertions is about a way the feature can be shipped
# green and dead on a real display.

SW = "switcher"


def test_the_switcher_layer_grabs_its_keys_with_the_hold_modifier_masked():
    """A passive grab on a bare key has mask 0, and every key pressed inside
    this layer arrives with $mod in the mask, because $mod is what holds the
    layer open. Bare-only grabs would deliver nothing after the entry chord."""
    chords = H.chords_for(B, SW)
    for k in ("Tab", "w", "space", "Escape", "Return"):
        assert f"Mod4+{k}" in chords, \
            f"{k} undeliverable while $mod is held — the layer would be inert"


def test_the_switcher_layer_still_grabs_its_keys_bare():
    """The floor. If the layer is somehow up with nothing held — the
    release-before-grab race — the bare exit key is what ends it."""
    chords = H.chords_for(B, SW)
    assert "q" in chords, "the exit-key floor is undeliverable with nothing held"


def test_the_switcher_layer_does_not_grab_the_hold_modifiers_own_keysyms():
    """A passive grab installed on a key that is ALREADY HELD never activates,
    so grabbing Super_L here would deliver neither the press nor the release —
    it would only add a grab that does nothing. The release is observed by
    asking the server instead (LayerEngine.reconcile_hold_layer)."""
    chords = H.chords_for(B, SW)
    for keysym in ("Super_L", "Super_R", "Alt_L", "Alt_R"):
        assert keysym not in chords, \
            f"{keysym} grabbed for a hold layer — it can never fire"


def test_the_switcher_layer_never_grabs_the_shift_variant_of_its_exit_key():
    """`$mod+Shift+q` is i3's `kill` (i3/config.common:47). Grabbing it would
    log a BadAccess on every single switcher entry."""
    for mod in ("Mod4", "Mod1"):
        chords = H.chords_for(B, SW, mod=mod)
        assert f"{mod}+Shift+q" not in chords
        assert "$mod+Shift+q" not in chords


def test_the_switcher_grabs_shift_tab_as_iso_left_tab_and_not_as_tab():
    """Both spellings are the same (keycode, mask) — one physical key at two
    shift levels — so grabbing both would make the daemon's answer to 'what key
    was that' depend on grab-table order, and cycle-backwards would silently
    cycle forwards."""
    chords = H.chords_for(B, SW)
    assert "Mod4+Shift+ISO_Left_Tab" in chords, "Shift+Tab cannot reach us"
    assert "Mod4+Shift+Tab" not in chords, \
        "the same grab under the forward-cycling name would shadow it"


def test_the_hold_modifier_is_masked_per_display():
    """One table, two displays: the layer's own grabs are computed from the
    canonical modifier name, which `$mod` only resolves to per display."""
    native = set(H.chords_for(B, SW, mod="Mod4"))
    rdp = set(H.chords_for(B, SW, mod="Mod1"))
    assert "Mod4+Escape" in native and "Mod1+Escape" not in native
    assert "Mod1+Escape" in rdp and "Mod4+Escape" not in rdp


def test_iso_left_tab_is_resolvable_at_all():
    """python-xlib preloads latin1 + miscellany ONLY. Before the xkb group is
    loaded `string_to_keysym("ISO_Left_Tab")` is 0, which GrabManager reports as
    'not on the current keymap' — a bind that validates, reports no problem in
    --check, and is dead on every display."""
    assert H.keysym_by_name("ISO_Left_Tab") != 0
    assert H.keysym_by_name("Tab") != 0


def test_two_chords_on_one_keycode_and_mask_are_grabbed_once():
    """Asking X for the same passive grab twice is a BadAccess against
    ourselves, reported as 'already grabbed by another client?' — a lie about
    our own duplicate. Tab and ISO_Left_Tab are the shipped instance."""
    d = FakeDisplay(keymap={"Tab": 23, "ISO_Left_Tab": 23})
    g = H.GrabManager(d, mod="Mod4")
    g.sync_binds(["Tab", "ISO_Left_Tab"])
    assert g.problems == [], g.problems
    assert d.grabs.count((23, 0)) == 1, d.grabs


def test_a_shifted_keycode_resolves_to_the_shifted_keysym():
    """The reverse lookup, which is what names an incoming event. Code-only, it
    answers 'Tab' for both and prev is dead."""
    d = FakeDisplay(keymap={"Tab": 23, "ISO_Left_Tab": 23})
    g = H.GrabManager(d, mod="Mod4")
    g.sync_binds(["$mod+Tab", "$mod+Shift+ISO_Left_Tab"])
    assert g.keysym_for(23, H.MOD4) == "Tab"
    assert g.keysym_for(23, H.MOD4 | H.SHIFT) == "ISO_Left_Tab"


def test_an_unmasked_lookup_still_answers_as_it_always_did():
    """The fallback: a caller with no state, and a keycode nothing matches on
    mask, gets the code-only answer rather than None."""
    d = FakeDisplay(keymap={"o": 32})
    g = H.GrabManager(d, mod="Mod4")
    g.sync_binds(["$mod+o"])
    assert g.keysym_for(32) == "o"
    assert g.keysym_for(32, 0) == "o"


# -- the daemon end of the hold release -------------------------------------

def _switcher_daemon(fake):
    dae, xd, pub = arbitration_daemon(fake)
    dae.pump(key_press(23, H.MOD4))                 # $mod+Tab
    return dae, xd, pub


def test_the_entry_chord_opens_the_overlay_and_takes_the_layer(fake_i3):
    dae, _, _ = _switcher_daemon(fake_i3)
    assert dae.engine.state["layer"] == SW
    dae.close()


def test_reconcile_asks_the_server_even_with_no_held_belief(fake_i3):
    """$mod goes down BEFORE the layer is entered, so the engine never saw the
    press and `held` is empty. The short-circuit that skips the round-trip when
    nothing is believed held would skip it in exactly this state."""
    dae, xd, _ = _switcher_daemon(fake_i3)
    assert dae.engine.held == frozenset(), dae.engine.held
    xd.screen().root.pointer_mask = 0               # server: nothing is down
    assert dae.reconcile_mods() is True
    assert dae.engine.state["layer"] == "default"
    dae.close()


def test_the_server_still_holding_the_modifier_keeps_the_layer(fake_i3):
    dae, xd, _ = _switcher_daemon(fake_i3)
    xd.screen().root.pointer_mask = H.MOD4
    assert dae.reconcile_mods() is False
    assert dae.engine.state["layer"] == SW
    dae.close()


def test_the_reconciled_commit_is_dispatched_and_the_grabs_are_dropped(fake_i3):
    """Ending the layer has to do BOTH: run the commit, and hand the layer's
    keys back to applications. A commit with the grabs still installed leaves
    Tab/Escape/Return eaten session-wide."""
    dae, xd, _ = _switcher_daemon(fake_i3)
    assert "Tab" in dae.grabs.chords
    xd.screen().root.pointer_mask = 0
    dae.reconcile_mods()
    assert "Tab" not in dae.grabs.chords, "layer grabs outlived the layer"
    dae.close()


def test_the_idle_timeout_tightens_while_a_hold_layer_is_up(fake_i3):
    """The select timeout IS the commit latency for a hold layer: no key event
    can end it, so the poll is the only thing that will. 250 ms of lag on every
    alt-tab release is what this exists to avoid."""
    dae, _, _ = arbitration_daemon(fake_i3)
    assert H.idle_timeout(dae) == H.IDLE_TIMEOUT_S
    dae.pump(key_press(23, H.MOD4))
    assert H.idle_timeout(dae) == H.HOLD_TIMEOUT_S
    assert H.HOLD_TIMEOUT_S < H.IDLE_TIMEOUT_S
    dae.close()


def test_a_layer_without_a_hold_does_not_tighten_the_timeout(fake_i3):
    """The negative control: nav is stood in for as long as the user likes, and
    polling it at 50 Hz would be a round-trip per 20 ms for nothing."""
    dae, _, _ = arbitration_daemon(fake_i3)
    dae.pump(key_press(32, H.MOD4))                 # $mod+o -> nav
    assert dae.engine.state["layer"] == "nav"
    assert H.idle_timeout(dae) == H.IDLE_TIMEOUT_S
    dae.close()


def _key_release(detail, state=0, **kw):
    return xi_event(detail, state, kind="release", **kw)


def _cmds(actions):
    return [getattr(a, "cmd", a) for a in actions]


def test_tab_inside_the_layer_cycles_forwards(fake_i3):
    """The second press of the gesture, arriving with $mod in the mask because
    $mod is what is holding the layer open."""
    dae, _, _ = _switcher_daemon(fake_i3)
    dae.pump(_key_release(23, H.MOD4))
    out = _cmds(dae.pump(key_press(23, H.MOD4)))
    assert any(c.endswith("qs-overlay.sh switcher") for c in out), out
    dae.close()


def test_shift_tab_inside_the_layer_cycles_backwards(fake_i3):
    """The end-to-end version of the keysym question: X delivers keycode 23
    with ShiftMask, and everything downstream has to call that ISO_Left_Tab.
    Resolve it as `Tab` anywhere along the way and the switcher cycles the
    WRONG WAY with nothing logged."""
    dae, _, _ = _switcher_daemon(fake_i3)
    dae.pump(_key_release(23, H.MOD4))
    out = _cmds(dae.pump(key_press(23, H.MOD4 | H.SHIFT)))
    assert any(c.endswith("switcher-prev") for c in out), out
    dae.close()


def test_escape_inside_the_layer_cancels_and_leaves(fake_i3):
    """Escape cannot be an exit_key: those are matched before any bind and
    dispatch nothing, so the layer would end with the overlay still up."""
    dae, _, _ = _switcher_daemon(fake_i3)
    out = _cmds(dae.pump(key_press(9, H.MOD4)))
    assert any(c.endswith("switcher-cancel") for c in out), out
    assert dae.engine.state["layer"] == "default"
    dae.close()


def test_space_inside_the_layer_hands_off_to_the_overlay(fake_i3):
    """Search means typing, and typing means releasing $mod — which would
    commit instantly and end the search before its first character. Leaving the
    layer hands every following key to the focused overlay, which is what the
    pre-cutover behaviour did by gating keymon's search branch to `switcher`."""
    dae, _, _ = _switcher_daemon(fake_i3)
    out = _cmds(dae.pump(key_press(65, H.MOD4)))
    assert any(c.endswith("switcher-search") for c in out), out
    assert dae.engine.state["layer"] == "default", \
        "still holding the layer: the next $mod release would commit over search"
    dae.close()


def test_the_exit_key_floor_dispatches_nothing(fake_i3):
    """`q` is the escape hatch, not a gesture: it drops the layer and leaves the
    overlay alone, which is what makes the overlay's own Escape work again."""
    dae, _, _ = _switcher_daemon(fake_i3)
    assert _cmds(dae.pump(key_press(24, H.MOD4))) == []
    assert dae.engine.state["layer"] == "default"
    dae.close()


def test_the_hold_modifiers_release_cannot_arrive_as_an_event(fake_i3):
    """WHY THE POLL EXISTS, pinned at daemon level rather than argued in a
    comment. The engine commits on an OBSERVED release (test_layers.py) — this
    daemon simply never observes one, for two independent reasons:

    - no grab. A passive grab installed on a key that is already held never
      activates, so grabbing Super_L would deliver neither edge; the layer
      therefore does not ask for it.
    - no name. Even fed the event directly, `_keysym_name` resolves a keycode
      through `XK.keysym_to_string`, which maps printable latin-1 and returns
      None for every modifier keysym — so the daemon could not say WHICH
      modifier came up.

    A future change that grabs the modifier anyway will find this test, not a
    silently inert commit path.
    """
    dae, _, _ = _switcher_daemon(fake_i3)
    for keysym in ("Super_L", "Alt_L"):
        assert keysym not in dae.grabs.chords
    assert H._keysym_name(FakeXServer(), 133) is None
    assert _cmds(dae.pump(_key_release(133, H.MOD4))) == []
    assert dae.engine.state["layer"] == SW, "only the server poll ends it"
    dae.close()
