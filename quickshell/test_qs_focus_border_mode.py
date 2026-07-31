"""One-shot synthetic tests for qs-focus-border colour + suppression.

The screenshot capture is TWO phases, and since sp023 (dotfiles-1m4t.6) they
arrive on TWO DIFFERENT CHANNELS:

  "screenshot"       AIMING. A real i3 MODE, entered by qs-screenshot.sh. The
                     ring stays UP and is RECOLOURED — while you are choosing
                     what to capture, seeing which window is focused is the
                     point. In COLOR_MODES. i3 still owns this mode and sp023
                     did not touch it.
  "screenshot-drag"  DRAWING. A hotkeyd EXTERNAL LAYER, raised by qs-region.py
                     from its own `_press` (`hotkeyd set-layer screenshot-drag`)
                     the moment a region starts being drawn, and cleared by
                     qs-screenshot.sh on every exit path. The ring HIDES here
                     and stays hidden and un-refreshed, so it cannot restack
                     above the live overlay or be baked into the capture.
                     In SUPPRESS_LAYERS.

WHY THE DRAG PHASE LEFT i3. It used to be a synthetic i3 mode (`i3-msg mode
screenshot-drag` plus a real `mode "screenshot-drag" {}` block in
i3/config.common) for one reason only: qs-focus-border.py is a separate process
from qs-region.py with no shared in-memory state, and i3's mode-change IPC event
was the only channel already wired to both. hotkeyd's state socket is that
channel now — it already carried the layer name to this file for the colour cue
— so sp023 retired the i3 mode and the signal rides the feed instead
([[us019]] AC1: state read from a feed, not inferred from mode/bind side
effects; one state-feed pattern instead of two).

WHAT THAT MEANS FOR THIS SUITE. The aiming-phase block below is UNCHANGED from
the dotfiles-5quz revision — it drives the real i3 mode and must keep passing
verbatim, which is the behaviour-preservation half of the change. The
drag-phase cases are re-pointed at the layer feed: they hand a layer NAME to
the main-thread entry point the reader thread calls, which is where colour AND
suppression are now both decided.

Either phase ENDS on its own channel's "default": the i3 mode goes back to
"default" and the layer goes back to "default" — two subprocess calls from the
same qs-screenshot.sh cleanup, with nothing ordering them. So BOTH ORDERS are
pinned rather than one assumed from the other. Cancel and save are likewise
indistinguishable from this module, so both are covered.

Run: python3 quickshell/test_qs_focus_border_mode.py
"""
import importlib.util, json, os, pathlib, socket, sys, tempfile, threading, time, types

calls = []


class FakeWin:
    def __init__(self, **k): pass
    def set_title(self, *a): pass
    def set_keep_above(self, *a): pass
    def set_accept_focus(self, *a): pass
    def set_type_hint(self, *a): pass
    def get_screen(self):
        return types.SimpleNamespace(get_rgba_visual=lambda: None)
    def set_visual(self, *a): pass
    def set_app_paintable(self, *a): pass
    def connect(self, *a): pass
    def move(self, *a): calls.append("move")
    def resize(self, *a): calls.append("resize")
    def get_realized(self): return False
    def get_window(self): return None
    def show_all(self): calls.append("show")
    def queue_draw(self): pass
    def hide(self): calls.append("hide")


# Stub gi/cairo before import so the GTK code doesn't try to draw.
sys.modules.setdefault("gi", type(sys)("gi"))
sys.modules["gi"].require_version = lambda *a, **k: None
gi_repo = types.ModuleType("gi.repository")
gi_repo.Gdk = types.SimpleNamespace(
    WindowTypeHint=types.SimpleNamespace(NOTIFICATION=0),
)
gi_repo.Gtk = types.SimpleNamespace(
    Window=lambda **k: FakeWin(),
    WindowType=types.SimpleNamespace(POPUP=0),
    main=lambda: None,
)
gi_repo.GLib = types.SimpleNamespace(
    idle_add=lambda f, *a: (f(*a), False)[1],  # run immediately
    timeout_add=lambda *a, **k: None,
)
sys.modules["gi.repository"] = gi_repo
sys.modules["cairo"] = types.SimpleNamespace(
    Region=lambda *a: None,
    RectangleInt=lambda *a: None,
    OPERATOR_SOURCE=0,
    OPERATOR_OVER=1,
)

# Run refresh threads synchronously; never start the subscribe/mouse threads.
_RealThread = threading.Thread


class SelectiveThread:
    def __init__(self, target=None, daemon=None, args=()):
        self._target = target
    def start(self):
        if self._target and getattr(self._target, "__name__", "") == "_do_refresh":
            self._target()


threading.Thread = SelectiveThread

# Canned i3 tree: one focused terminal window. Mutated per-test to add the
# overlay dock.
TREE = {
    "name": "root",
    "nodes": [{
        "name": "term",
        "window": 123,
        "focused": True,
        "window_properties": {"class": "Alacritty", "instance": "Alacritty"},
        "rect": {"x": 10, "y": 20, "width": 300, "height": 200},
        "deco_rect": {"height": 0},
        "nodes": [], "floating_nodes": [],
    }],
    "floating_nodes": [],
}

import subprocess
subprocess.check_output = lambda *a, **k: json.dumps(TREE).encode()

# Fake display so the per-display lock doesn't collide with a live helper.
os.environ["DISPLAY"] = ":99-qsb-test"
# ...and our own runtime dir, for the same reason one level down: the WIRE
# section at the bottom binds a REAL unix socket at the path
# hotkeyd_layer_monitor computes, and that must not be a path a live daemon on
# this machine is already serving (nor may the module's lock file collide).
_RUNTIME = tempfile.mkdtemp(prefix="qsb-test-")
os.environ["XDG_RUNTIME_DIR"] = _RUNTIME

spec = importlib.util.spec_from_file_location(
    "qsb", pathlib.Path(__file__).parent / "qs-focus-border.py"
)
qsb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qsb)

threading.Thread = _RealThread

failures = []


def check(name, cond):
    if cond:
        print("PASS", name)
    else:
        failures.append(name)
        print("FAIL", name)


def enter_screenshot_mode():
    """The i3 MODE qs-screenshot.sh enters while the selector is being AIMED.

    This mode does NOT hide the ring (dotfiles-5quz). Commit 29106e6 moved it
    into COLOR_MODES instead: while you are choosing what to capture, the ring
    stays up in the accent colour so you can see which window is focused.
    Suppression lives on the `screenshot-drag` LAYER below, raised the instant
    a region is actually being drawn. i3 still owns this mode; sp023 did not
    touch it, which is why every assertion in the aiming block is verbatim from
    the pre-sp023 revision of this file.
    """
    qsb.handle_event('{"change":"screenshot", "pango_markup":false}')


def leave_mode():
    """i3 mode back to "default" — qs-screenshot.sh, on every exit path."""
    qsb.handle_event('{"change":"default", "pango_markup":false}')


def drive_layer(name):
    """One layer name off hotkeyd's state feed, delivered as the reader does.

    The reader thread parses `{"layer": ...}` and hands the NAME to this
    main-thread entry point, which is where colour AND suppression are now both
    decided (sp023). Driving that function directly is the same in-process
    style the rest of this suite uses; the WIRE section at the bottom
    additionally drives the REAL reader over a REAL socket, so the JSON shape,
    replay-on-connect and the parse guard are covered rather than assumed.

    Tolerates the entry point being absent so a RED run reports WHICH contract
    broke, by name, instead of dying on an AttributeError at the first drag
    case. Its existence is asserted separately below — this fallback can never
    make the suite green on a file that lacks it.
    """
    fn = getattr(qsb, "_set_layer_state", None)
    if fn is None:
        return
    fn(name)


def enter_drag_layer():
    drive_layer("screenshot-drag")


def leave_layer():
    drive_layer("default")


def reset_state():
    """Both channels back to idle, all three colour flags cleared."""
    drive_layer("default")
    qsb.handle_event('{"change":"default", "pango_markup":false}')
    qsb.i3_mode_colored = False
    qsb.layer_colored = False
    qsb.mode_colored = False
    qsb.mode_suppressed = False


# Baseline: a refresh with a focused window shows the border.
calls.clear()
qsb.refresh_focused()
check("baseline refresh shows border", "show" in calls)

# === AIMING PHASE — the real i3 mode, UNCHANGED by sp023 =====================
# Every assertion in this block is verbatim from the pre-sp023 revision. The
# drag phase moved to the layer feed; the aiming phase did not move at all, and
# these must pass identically before and after the change.

# THE CURRENT CONTRACT, half one: entering "screenshot" (aiming) does NOT hide
# the ring — it RECOLOURS it. 29106e6 made the ring show which window is
# focused while you choose what to capture.
calls.clear()
qsb.handle_event('{"change":"screenshot", "pango_markup":false}')
check("screenshot mode enter does NOT hide the border", "hide" not in calls)
check("screenshot mode enter colours the ring", qsb.mode_colored is True)
check("screenshot mode enter leaves refreshes working",
      qsb.mode_suppressed is False)
leave_mode()
check("leaving screenshot clears the colour", qsb.mode_colored is False)

# Non-suppress modes (resize) keep the live-refresh behavior — guards
# against over-broad suppression leaking into unrelated modes.
calls.clear()
qsb.handle_event('{"change":"resize", "pango_markup":false}')
check("resize mode still refreshes", "show" in calls)
calls.clear()
qsb.refresh_focused()
check("refresh during resize mode still redraws", "show" in calls)
qsb.handle_event('{"change":"default", "pango_markup":false}')

# Bar restart: a plain quickshell window::new (default name "quickshell",
# e.g. the bar process restarting) outside any mode still hides then
# restores via the follow-up refresh. Unrelated to the screenshot overlay
# (which never fires window::new) but a real, still-live code path this
# change must not regress.
calls.clear()
qsb.handle_event(json.dumps({"change": "new", "container": {"name": "quickshell"}}))
check("bar window::new hides then restores", "hide" in calls and "show" in calls
      and calls.index("hide") < calls.index("show"))

# nav is no longer an i3 colouring mode...
check("nav is no longer an i3 colouring mode", "nav" not in qsb.COLOR_MODES)
# ...but screenshot still is: it is a mode i3 genuinely still owns, and the ring
# doubles as "this is the window `w` would capture". sp023 retired the DRAG
# mode, not this one.
check("screenshot is still an i3 colouring mode", "screenshot" in qsb.COLOR_MODES)

# === i3-SIDE DRAG MACHINERY RETIRED (sp023) ==================================
# The i3 mode block, the SUPPRESS_MODES set and the binding-event pre-arm
# branch all go. These assert the retirement is a DELETION rather than a
# bypass: a leftover set nothing writes would still match a stale event, and a
# leftover pre-arm branch would arm a flag nothing can now disarm.
check("SUPPRESS_MODES is retired, not merely emptied",
      not hasattr(qsb, "SUPPRESS_MODES"))
check("the layer feed has a name-carrying main-thread entry point",
      hasattr(qsb, "_set_layer_state"))
check("screenshot-drag is declared a suppress LAYER",
      "screenshot-drag" in getattr(qsb, "SUPPRESS_LAYERS", set()))

# A half-updated estate still running the old i3 config would emit a
# screenshot-drag MODE event. The name is in no i3-mode set any more, so it
# must be treated as any other unknown mode: no suppression, no colour, and the
# refresh that every non-colouring mode gets.
reset_state()
calls.clear()
qsb.handle_event('{"change":"screenshot-drag", "pango_markup":false}')
check("a stale screenshot-drag i3 MODE event does not suppress",
      qsb.mode_suppressed is False)
check("a stale screenshot-drag i3 MODE event does not colour",
      qsb.mode_colored is False)
check("a stale screenshot-drag i3 MODE event still refreshes", "show" in calls)
leave_mode()

# The binding-event pre-arm branch goes with the mode. A binding whose command
# names the old mode is now just a binding: it refreshes like any other and
# must NOT arm suppression — nothing would ever disarm it, because the disarm
# moved to the layer feed.
reset_state()
calls.clear()
qsb.handle_event(json.dumps({"change": "run", "binding": {
    "command": 'mode "screenshot-drag"'}}))
check("a screenshot-drag binding no longer arms suppression",
      qsb.mode_suppressed is False)
check("a screenshot-drag binding refreshes like any other", "show" in calls)

# === DRAG PHASE — the hotkeyd layer feed =====================================
reset_state()
calls.clear()
enter_drag_layer()
check("drag layer hides border", calls == ["hide"])
check("drag layer arms suppression", qsb.mode_suppressed is True)
calls.clear()
qsb.refresh_focused()
check("drag layer still suppresses refresh", not calls)
leave_layer()

# Suppression WINS over colour. Every other non-default, non-silent layer
# paints the ring red; a suppress layer must not, because there is no ring to
# paint and a flag left standing would survive into the redraw that follows the
# layer clearing.
reset_state()
check("a suppress layer never colours the ring",
      qsb.layer_colours_ring("screenshot-drag") is False)
enter_drag_layer()
check("entering the drag layer leaves the ring uncoloured",
      qsb.mode_colored is False)
leave_layer()

# Suppress arrives while a refresh is already in flight: the geometry apply
# lands AFTER the layer armed suppression, and apply_geom's own re-check is
# what stops it restacking the border above the live overlay.
reset_state()
enter_drag_layer()
calls.clear()
qsb.apply_geom(TREE["nodes"][0], [])
check("an in-flight geometry apply is dropped once the layer armed suppression",
      not calls)
leave_layer()

# While the DRAG is active, binding/mouse-poll refreshes must do nothing — the
# border stays hidden, it does not get redrawn/restacked above the overlay.
reset_state()
enter_drag_layer()
calls.clear()
qsb.refresh_focused()
qsb.handle_event('{"change":"run", "binding":{"command":"nop"}}')
check("refresh while layer-suppressed is a no-op", not calls)
leave_layer()

# Layer clear: border comes back for the focused window. This is the CANCEL
# path — Esc (or the dead-overlay fallback) drives qs-screenshot.sh straight to
# its cleanup with no intervening window events, since the overlay never wrote
# a file and closed without ever appearing in i3's tree.
reset_state()
enter_drag_layer()
calls.clear()
leave_layer()
check("cancel path: layer clear redraws border", "show" in calls)
check("cancel path: layer clear unsuppresses", qsb.mode_suppressed is False)

# SAVE path: capture succeeded, but other window/focus noise (e.g. the overlay
# briefly re-focusing its caller, a close event) may arrive before the layer
# clear lands. The border must still hide throughout and reappear once the
# layer actually clears — the save path is not distinguishable from cancel at
# this level, and must be covered too, not assumed to work because cancel does.
reset_state()
calls.clear()
enter_drag_layer()
check("save path: still hidden after drag entry", calls == ["hide"])
calls.clear()
qsb.handle_event(json.dumps({"change": "close", "container": {
    "name": "term", "window_properties": {"class": "Alacritty"}}}))
# close unconditionally re-hides (idempotent, already hidden) but must not
# redraw/restack the border above the live overlay while suppressed.
check("save path: close noise during suppression does not redraw",
      "show" not in calls)
calls.clear()
leave_layer()
check("save path: layer clear redraws border", "show" in calls)

# Edge case: layer raised but the overlay never starts (exec failed, no window
# ever mapped) — the border must still return when the layer clears, not stay
# hidden forever waiting for a window::new that will never come.
reset_state()
calls.clear()
enter_drag_layer()
check("overlay-never-started: border hidden at drag entry", calls == ["hide"])
calls.clear()
leave_layer()
check("overlay-never-started: border returns without ever seeing a window",
      "show" in calls)

# Rapid raise/clear: no stuck-hidden or double-shown border.
reset_state()
calls.clear()
enter_drag_layer()
leave_layer()
enter_drag_layer()
leave_layer()
check("rapid raise/clear ends unsuppressed and visible", "show" in calls)
check("rapid raise/clear does not leave border stuck hidden",
      calls[-1] == "show" if calls else False)

# === THE TWO CHANNELS BRACKET THE GESTURE — BOTH ORDERS ======================
# One capture drives both channels: qs-screenshot.sh enters the i3 mode, the
# overlay raises the layer, and on exit the SAME script clears both. Nothing
# orders those two clears — they are two subprocess calls from one shell, one
# through i3 IPC and one through hotkeyd's control socket — so the final state
# must be identical whichever lands first. Asserting one order and inferring
# the other is exactly how a stuck-hidden border ships.

# Order A: the i3 mode clears FIRST, the layer second.
reset_state()
enter_screenshot_mode()
check("order A: aiming colours the ring", qsb.mode_colored is True)
calls.clear()
enter_drag_layer()
check("order A: drag hides and suppresses",
      "hide" in calls and qsb.mode_suppressed is True)
calls.clear()
leave_mode()
# THE LOAD-BEARING ONE. Suppression is the LAYER's to clear now. An i3 mode
# event that still disarmed it would un-hide the border while the overlay is
# demonstrably still up — the very frame this whole mechanism exists to keep
# out of the capture.
check("order A: the i3 mode clearing first does NOT unsuppress",
      qsb.mode_suppressed is True)
check("order A: no redraw while the layer is still up", "show" not in calls)
calls.clear()
leave_layer()
check("order A: final state unsuppressed", qsb.mode_suppressed is False)
check("order A: final state uncoloured", qsb.mode_colored is False)
check("order A: final state border refreshed", "show" in calls)

# Order B: the layer clears FIRST, the i3 mode second.
reset_state()
enter_screenshot_mode()
enter_drag_layer()
check("order B: drag suppresses", qsb.mode_suppressed is True)
calls.clear()
leave_layer()
check("order B: the layer clearing first unsuppresses",
      qsb.mode_suppressed is False)
check("order B: the layer clearing first redraws", "show" in calls)
calls.clear()
leave_mode()
check("order B: final state unsuppressed", qsb.mode_suppressed is False)
check("order B: final state uncoloured", qsb.mode_colored is False)
check("order B: final state border refreshed", "show" in calls)

# === LAYER COLOUR MAPPING (dotfiles-hwds.9) ==================================
# The red "keys are captured" ring used to key off the i3 `nav` mode; nav left
# i3 in the sp020 cutover, so the cue follows the daemon's layer feed. These
# pin the mapping in isolation, which is where a silent regression would hide.
reset_state()
drive_layer("nav")
check("entering a layer colours the ring", qsb.mode_colored is True)

calls.clear()
drive_layer("nav")
check("a repeat of the same layer state does not redraw", calls == [])

drive_layer("default")
check("leaving the layer clears the colour", qsb.mode_colored is False)

# --- SILENT layers (dotfiles-hwds.44) ---------------------------------------
# "Anything that is not default captures keys, so colour the ring" was true
# while every layer was modal. The alt-tab switcher is not: it is a held-modifier
# gesture with its own full-screen overlay, and $mod+w has to feel like $mod+d
# and $mod+p — open a thing, change nothing else. The red ring is a WARNING that
# bare letters are now WM commands; firing it for a gesture that already shows
# what it does is noise, and it trained the eye to ignore the real warning.
#
# Mirrors ModeBarTheme.silentModes, which suppresses the bar strip for the same
# set. Two files because two languages; the comment in each names the other.
check("the switcher layer does NOT colour the ring",
      qsb.layer_colours_ring("switcher") is False)
check("switcher is declared silent, not merely unhandled",
      "switcher" in qsb.SILENT_LAYERS)
check("a modal layer still colours the ring", qsb.layer_colours_ring("nav") is True)
check("default never colours the ring", qsb.layer_colours_ring("default") is False)
# An unknown future layer colours the ring: silence must be opted INTO, so a
# layer nobody classified is treated as modal (the safe direction — a spurious
# warning beats a missing one).
check("an unclassified layer still colours the ring",
      qsb.layer_colours_ring("somefuture") is True)
# Suppression is opted into from the OTHER side, and for the mirrored reason: a
# layer nobody classified must never be able to hide the ring, because a hidden
# ring has nothing left to warn with.
reset_state()
calls.clear()
drive_layer("somefuture")
check("an unclassified layer does not suppress the border",
      qsb.mode_suppressed is False)

# A layer name the helper has never heard of still means "keys are captured":
# the daemon only publishes a layer when one is active, so anything that is not
# "default" qualifies. Guards against someone hardcoding {'nav'} here later.
check("any non-default layer counts", qsb.HOTKEYD_COLORS_ANY_LAYER is True)

# --- the two colour sources must not clobber each other ---------------------
# Colour comes from an i3 mode (screenshot) OR a hotkeyd layer (nav), and they
# are independent: an i3 "mode default" event fires on leaving screenshot, and
# it must not blank a red the layer feed owns. Folding both into ONE flag — the
# shape this file had while COLOR_MODES was empty — regresses exactly here.
reset_state()
drive_layer("nav")                                 # in a nav layer
qsb.handle_event('{"change":"screenshot"}')        # i3 mode on top of it
check("an i3 colour mode on top of a layer stays red", qsb.mode_colored is True)
qsb.handle_event('{"change":"default"}')           # i3 mode ends; layer persists
check("leaving the i3 mode does not blank the layer's red",
      qsb.mode_colored is True)
drive_layer("default")
check("clearing the layer with no i3 mode left clears the ring",
      qsb.mode_colored is False)

# ...and symmetrically: a layer ending must not blank an i3 mode's red.
qsb.handle_event('{"change":"screenshot"}')
check("an i3 colour mode alone colours the ring", qsb.mode_colored is True)
drive_layer("nav")
drive_layer("default")
check("a layer coming and going leaves the i3 mode's red intact",
      qsb.mode_colored is True)
qsb.handle_event('{"change":"default"}')
check("both sources clear -> plain ring", qsb.mode_colored is False)

# === THE WIRE: the real reader against a real socket =========================
# Everything above drives the main-thread entry point directly. This block runs
# hotkeyd_layer_monitor ITSELF against a real AF_UNIX socket at the path it
# computes from DISPLAY + XDG_RUNTIME_DIR, so three things that exist only on
# the wire are covered rather than assumed: the {"layer": ...} JSON shape,
# replay-on-connect, and the parse guard, which must swallow a malformed line
# WITHOUT touching suppression.
reset_state()

_SOCK = os.path.join(_RUNTIME, "hotkeyd-99-qsb-test.sock")
_srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
_srv.bind(_SOCK)
_srv.listen(1)
_conn_box = []


def _accept_once():
    conn, _ = _srv.accept()
    # REPLAY-ON-CONNECT: hotkeyd's state socket sends current state as the
    # FIRST line to every new client. A border helper (re)started mid-drag —
    # quickshell restarting it, or the user restarting the bar — therefore
    # learns it is mid-drag before it draws anything, and there is no window in
    # which it restacks above the live overlay.
    conn.sendall(b'{"layer":"screenshot-drag","mod":null}\n')
    _conn_box.append(conn)


_acceptor = threading.Thread(target=_accept_once, daemon=True)
_acceptor.start()


def wait_for(pred, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.01)
    return pred()


_reader = threading.Thread(target=qsb.hotkeyd_layer_monitor, daemon=True)
_reader.start()

check("replay-on-connect: a helper started mid-drag starts suppressed",
      wait_for(lambda: qsb.mode_suppressed is True))
check("replay-on-connect: it starts uncoloured too", qsb.mode_colored is False)

# Malformed line mid-drag: skipped by the parse guard, suppression untouched.
# A reader that reset state on garbage would un-hide the border into the middle
# of a live capture.
_acceptor.join(5)
_conn = _conn_box[0]
_conn.sendall(b'{not json at all\n')
_conn.sendall(b'\n')
time.sleep(0.2)
check("a malformed feed line mid-drag leaves suppression armed",
      qsb.mode_suppressed is True)

# ...and a well-formed line after it proves the stream did not desync behind
# the garbage — the guard skips one LINE, not the rest of the feed.
_conn.sendall(b'{"layer":"nav","mod":null}\n')
check("the feed keeps working after a malformed line",
      wait_for(lambda: qsb.mode_suppressed is False))
check("the layer after the malformed line is the one that was sent",
      qsb.mode_colored is True)

# FEED LOSS WHILE SUPPRESSED: the daemon dies mid-drag. Both suppression and
# colour must clear on the socket-loss fallback. This is the worst outcome the
# design can produce if it is wrong — a border hidden forever, with the one
# channel that could ever bring it back now dead.
_conn.sendall(b'{"layer":"screenshot-drag","mod":null}\n')
check("feed loss: suppressed again before the kill",
      wait_for(lambda: qsb.mode_suppressed is True))
_conn.close()
_srv.close()
os.unlink(_SOCK)
check("feed loss while suppressed unsuppresses the border",
      wait_for(lambda: qsb.mode_suppressed is False))
check("feed loss while suppressed also clears the colour",
      qsb.mode_colored is False)

print()
if failures:
    print("%d failure(s): %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all tests passed")
