"""One-shot synthetic tests for qs-focus-border colour + suppression.

The screenshot capture is TWO phases, and since sp024 (dotfiles-0tv1.2) BOTH
arrive on ONE channel — hotkeyd's layer feed:

  "screenshot"       AIMING. An External LAYER, raised by qs-screenshot.sh
                     (`hotkeyd set-layer screenshot`) before it starts the
                     selector. The ring stays UP and is RECOLOURED — while you
                     are choosing what to capture, seeing which window is
                     focused is the point.
  "screenshot-drag"  DRAWING. An External LAYER, raised by qs-region.py from
                     its own `_press` the moment a region starts being drawn.
                     The ring HIDES here and stays hidden and un-refreshed, so
                     it cannot restack above the live overlay or be baked into
                     the capture. In SUPPRESS_LAYERS.

Both are cleared by the SAME single unconditional `set-layer default` in
qs-screenshot.sh's cleanup, whichever of the two happens to be up.

WHY BOTH PHASES LEFT i3. Each used to be a real i3 mode (`i3-msg mode <name>`
against a `mode "<name>" {}` block in i3/config.common) for one reason only:
qs-focus-border.py is a separate process from qs-region.py with no shared
in-memory state, and i3's mode-change IPC event was the only channel already
wired to both. hotkeyd's state socket is that channel now — it already carried
the layer name to this file for the colour cue — so sp023 retired the drag mode
and sp024 the aiming mode ([[us019]] AC1: state read from a feed, not inferred
from mode/bind side effects; one state-feed pattern instead of two).

WHAT THAT MEANS FOR THIS SUITE. There is no second colour source left to guard
against: COLOR_MODES, `i3_mode_colored` and the `_recompute_colored` OR-fold
are RETIRED, and `layer_colored` is the sole flag Border._draw reads. The
aiming cases below drive the FEED, and they carry the load-bearing evidence for
that deletion — the i3-mode branch they replace also called refresh_focused(),
so `_set_layer_state` must be SHOWN to do the same (refresh AND queue_draw, on
the enter and on the clear), never assumed to.

A mode-shaped event reaching handle_event — an unreloaded i3 still emitting
them on a half-updated estate — is now FULLY INERT: no colour, no suppression,
and no refresh either. Asserted rather than left to chance, because a
half-updated estate is exactly where a signal in two channels would resurface.

Cancel and save are indistinguishable from this module, so both are covered.

Run: python3 quickshell/test_qs_focus_border_mode.py
"""
import importlib.util, json, os, pathlib, socket, sys, tempfile, threading, time, types

calls = []
# queue_draw is recorded SEPARATELY rather than into `calls`, because folding
# it in would perturb every existing ordering assertion — border.update()
# queues a draw of its own (qs-focus-border.py:188).
#
# It is the second half of constraint 2's evidence: _set_layer_state's
# EXPLICIT queue_draw. That call is load-bearing because refresh_focused is
# ASYNC and can decline to repaint at all — it returns early while
# mode_suppressed, and its worker bails on _refresh_lock contention or when
# _has_overlay_present hides the border instead. In each of those cases the
# synchronous draw is the only repaint the colour flip gets.
#
# An earlier version of this comment justified it by claiming refresh_focused
# "skips the GTK draw when the geometry is identical". There is no such
# geometry short-circuit anywhere in qs-focus-border.py — apply_geom calls
# border.update() unconditionally. The claim predates sp024 (it was inherited
# verbatim from main) and is corrected here rather than propagated.
#
# NOTE ON ASSERTING THIS: `draws != []` alone does NOT pin the explicit call.
# Any refresh that reaches apply_geom populates `draws` via update()'s own
# queue_draw, so the bare assertion passes even with the explicit call deleted
# (mutation-verified, dotfiles-0tv1.4). Use explicit_draws_from() below, which
# removes that second source.
draws = []


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
    def queue_draw(self): draws.append("queue_draw")
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


def enter_aiming_layer():
    """The AIMING layer qs-screenshot.sh raises before starting the selector.

    It does NOT hide the ring (dotfiles-5quz): while you are choosing what to
    capture, the ring stays up in the accent colour so you can see which window
    is focused. Suppression belongs to the `screenshot-drag` layer, raised the
    instant a region is actually being drawn.

    This was a real i3 MODE until sp024 — and every assertion in the aiming
    block below is the pre-sp024 one with the CHANNEL swapped, which is the
    behaviour-preservation half of that cutover.
    """
    drive_layer("screenshot")


def enter_drag_layer():
    drive_layer("screenshot-drag")


def leave_layer():
    drive_layer("default")


def stale_mode_event(name):
    """A mode-shaped i3 event: only 'change', no container/current/binding.

    No i3 mode drives anything in this file any more, so these exist purely to
    pin that the shape is inert on a half-updated estate.
    """
    qsb.handle_event('{"change":"%s", "pango_markup":false}' % name)


def reset_state():
    """Back to idle: layer cleared, both flags down."""
    drive_layer("default")
    qsb.layer_colored = False
    qsb.mode_suppressed = False


def explicit_draws_from(transition):
    """Run `transition` with refresh_focused neutered; return what it drew.

    ISOLATES _set_layer_state's own queue_draw. There are two sources of
    `draws` in production: the explicit call in _set_layer_state, and
    border.update()'s trailing queue_draw (qs-focus-border.py:188) reached via
    refresh_focused -> apply_geom. Asserting `draws != []` therefore cannot
    tell them apart, and passes even when the explicit call is deleted.
    Stubbing refresh_focused removes the second source, so anything recorded
    here can only be the first.

    Deliberately a SECOND run of the transition rather than a replacement for
    the real one: the real run still asserts the refresh happened ("show" in
    calls). Both halves of the pair need pinning, and each needs the other's
    source removed to be seen.
    """
    real = qsb.refresh_focused
    qsb.refresh_focused = lambda *a, **k: None
    try:
        draws.clear()
        transition()
        return list(draws)
    finally:
        qsb.refresh_focused = real


# Baseline: a refresh with a focused window shows the border.
calls.clear()
qsb.refresh_focused()
check("baseline refresh shows border", "show" in calls)

# === AIMING PHASE — the hotkeyd layer feed (sp024) ===========================
# These are the pre-sp024 aiming assertions with the CHANNEL swapped: what the
# aiming phase DOES to the border is unchanged (colour, no hide, refreshes keep
# working), only what carries the signal moved. That is the
# behaviour-preservation half of the cutover ([[us019]] AC6).

# THE CURRENT CONTRACT, half one: entering "screenshot" (aiming) does NOT hide
# the ring — it RECOLOURS it. 29106e6 made the ring show which window is
# focused while you choose what to capture.
reset_state()
calls.clear()
draws.clear()
enter_aiming_layer()
check("aiming-enter: does NOT hide the border", "hide" not in calls)
check("aiming-enter: colours the ring", qsb.layer_colored is True)
check("aiming-enter: leaves refreshes working", qsb.mode_suppressed is False)

# CONSTRAINT 2's EVIDENCE, half one. The deleted i3-mode branch called
# refresh_focused() on every mode event and queue_draw() whenever the colour
# flipped. _set_layer_state must be SHOWN to carry both — a colour flip with
# unchanged geometry needs the explicit redraw, because refresh_focused skips
# the GTK draw when the geometry is identical. Assumed rather than shown, this
# is a ring that turns red only on the next unrelated window event.
check("aiming-enter: refreshes the focused window", "show" in calls)
# ISOLATED: refresh_focused stubbed, so this can only be _set_layer_state's own
# queue_draw — see explicit_draws_from's docstring for why `draws != []` after
# a plain run proves nothing.
reset_state()
check("aiming-enter: queues an EXPLICIT redraw for the colour flip",
      explicit_draws_from(enter_aiming_layer) != [])

reset_state()
calls.clear()
draws.clear()
enter_aiming_layer()
calls.clear()
draws.clear()
leave_layer()
check("aiming-clear: clears the colour", qsb.layer_colored is False)
# ...and half two: the clear needs the same pair. Leaving the aiming phase is
# also a pure colour flip (the overlay never emitted a focus event of its own),
# so nothing else would repaint the ring back to plain.
check("aiming-clear: refreshes the focused window", "show" in calls)
# ISOLATED, same reasoning as the enter case above.
reset_state()
enter_aiming_layer()
check("aiming-clear: queues an EXPLICIT redraw",
      explicit_draws_from(leave_layer) != [])

# Bar restart: a plain quickshell window::new (default name "quickshell",
# e.g. the bar process restarting) outside any layer still hides then
# restores via the follow-up refresh. Unrelated to the screenshot overlay
# (which never fires window::new) but a real, still-live code path this
# change must not regress.
calls.clear()
qsb.handle_event(json.dumps({"change": "new", "container": {"name": "quickshell"}}))
check("bar window::new hides then restores", "hide" in calls and "show" in calls
      and calls.index("hide") < calls.index("show"))

# === THE i3-MODE COLOUR HALF IS RETIRED (sp024) ==============================
# COLOR_MODES, `i3_mode_colored` and the `_recompute_colored` OR-fold go with
# the i3 mode blocks, exactly as SUPPRESS_MODES went at sp023. These assert the
# retirement is a DELETION rather than a bypass: a leftover set that nothing
# writes would still match a stale event, and a leftover second colour flag
# would be a source nothing can now clear.
check("COLOR_MODES is retired, not merely emptied",
      not hasattr(qsb, "COLOR_MODES"))
check("the i3 half of the colour state is retired",
      not hasattr(qsb, "i3_mode_colored"))
check("the two-source OR-fold is retired", not hasattr(qsb, "_recompute_colored"))
check("the derived mode_colored flag is retired",
      not hasattr(qsb, "mode_colored"))
check("layer_colored is the sole colour flag", hasattr(qsb, "layer_colored"))
check("SUPPRESS_MODES is still retired (sp023), not merely emptied",
      not hasattr(qsb, "SUPPRESS_MODES"))
check("the layer feed has a name-carrying main-thread entry point",
      hasattr(qsb, "_set_layer_state"))
check("screenshot-drag is declared a suppress LAYER",
      "screenshot-drag" in getattr(qsb, "SUPPRESS_LAYERS", set()))

# A half-updated estate — an i3 that has not reloaded since the mode blocks
# were deleted — can still emit mode events for BOTH names. With no i3-mode
# branch left they fall through the container-less path and are FULLY INERT:
# no suppression, no colour, and (this is the assertion that INVERTED at sp024)
# no refresh either. A second channel that still moved the border would be the
# double-fire class this migration exists to kill.
for _stale in ("screenshot", "screenshot-drag", "resize", "default"):
    reset_state()
    calls.clear()
    draws.clear()
    stale_mode_event(_stale)
    check("a stale %r i3 MODE event does not suppress" % _stale,
          qsb.mode_suppressed is False)
    check("a stale %r i3 MODE event does not colour" % _stale,
          qsb.layer_colored is False)
    check("a stale %r i3 MODE event does not even refresh" % _stale,
          calls == [] and draws == [])

# ...and it cannot CLOBBER a live layer either: the aiming layer is up, a stale
# mode event arrives, and the ring must stay red. This is the failure the old
# two-flag fold existed to prevent; with one source it is structural, and this
# pins that it stayed structural.
reset_state()
enter_aiming_layer()
calls.clear()
draws.clear()
stale_mode_event("default")
check("a stale i3 mode event cannot blank a live layer's red",
      qsb.layer_colored is True)
check("a stale i3 mode event cannot redraw over a live layer",
      calls == [] and draws == [])
leave_layer()

# The binding-event pre-arm branch went at sp023. A binding whose command names
# an old mode is now just a binding: it refreshes like any other and must NOT
# arm suppression — nothing would ever disarm it, because the disarm lives on
# the layer feed.
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
      qsb.layer_colored is False)
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

# === ONE GESTURE, ONE CHANNEL: THE aiming -> drag -> clear HANDOFF ===========
# The whole capture is now three lines on ONE feed, in a guaranteed order:
# qs-screenshot.sh raises "screenshot", qs-region.py hands off to
# "screenshot-drag" at mouse-press, and the launcher's single unconditional
# `set-layer default` clears whichever is up. The engine permits that
# external -> external handoff and publishes both lines in order (pinned in Go
# by internal/layer's TestExternalToExternalHandoff); what THIS asserts is what
# the border does across it — colour, then suppress, then restore.
#
# There used to be a BOTH-ORDERS block here instead, because the two phases
# rode two channels (i3 IPC and the state socket) whose two "default" events
# were unordered, and either landing first had to produce the same end state.
# sp024 removed the second channel, so the ordering hazard is gone rather than
# merely untested — the inertness cases above are what now stands in for it.
reset_state()
calls.clear()
draws.clear()
enter_aiming_layer()
check("handoff: aiming colours the ring", qsb.layer_colored is True)
check("handoff: aiming does not hide", "hide" not in calls)

calls.clear()
enter_drag_layer()
check("handoff: the drag layer hides and suppresses",
      "hide" in calls and qsb.mode_suppressed is True)
check("handoff: the drag layer takes the colour back down",
      qsb.layer_colored is False)
calls.clear()
qsb.refresh_focused()
check("handoff: no redraw survives into the drag phase", calls == [])

calls.clear()
draws.clear()
leave_layer()
check("handoff: the clear unsuppresses", qsb.mode_suppressed is False)
check("handoff: the clear leaves the ring uncoloured", qsb.layer_colored is False)
check("handoff: the clear brings the border back", "show" in calls)
# ISOLATED. This one leaves a SUPPRESSED layer, so it exercises the
# was_suppressed arm of _set_layer_state rather than the colour-flip arm — and
# that arm is where the explicit draw matters most: refresh_focused returns
# immediately while mode_suppressed is still set on entry to the transition.
reset_state()
enter_aiming_layer()
enter_drag_layer()
check("handoff: the clear queues an EXPLICIT redraw",
      explicit_draws_from(leave_layer) != [])

# The reverse trip is real too: Esc during AIMING never reaches the drag layer,
# so the clear arrives straight from "screenshot". The launcher does not know
# which one is up and does not check — one unconditional clear covers both.
reset_state()
enter_aiming_layer()
calls.clear()
leave_layer()
check("aiming-only cancel: the same clear restores from the aiming layer",
      qsb.layer_colored is False and qsb.mode_suppressed is False
      and "show" in calls)

# === LAYER COLOUR MAPPING (dotfiles-hwds.9) ==================================
# The red "keys are captured" ring used to key off the i3 `nav` mode; nav left
# i3 in the sp020 cutover, so the cue follows the daemon's layer feed. These
# pin the mapping in isolation, which is where a silent regression would hide.
reset_state()
drive_layer("nav")
check("entering a layer colours the ring", qsb.layer_colored is True)

calls.clear()
draws.clear()
drive_layer("nav")
check("a repeat of the same layer state does not redraw",
      calls == [] and draws == [])

drive_layer("default")
check("leaving the layer clears the colour", qsb.layer_colored is False)

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

# --- ONE colour source, and it is the feed ----------------------------------
# Colour used to come from an i3 mode (screenshot) OR a hotkeyd layer (nav),
# kept in two flags folded by _recompute_colored precisely so an i3 "mode
# default" on leaving screenshot could not blank a red the layer feed owned.
# sp024 removed the i3 source, so the fold went too: the feed's own layer name
# is the single input, and the whole clobber class is structural rather than
# defended. These pin the remaining source end to end, and that nothing else
# can move it.
reset_state()
drive_layer("nav")
stale_mode_event("screenshot")
check("a mode event cannot add colour on top of a layer",
      qsb.layer_colored is True)
stale_mode_event("default")
check("a mode event cannot blank the layer's red", qsb.layer_colored is True)
drive_layer("default")
check("only the feed clears the ring", qsb.layer_colored is False)

# ...and with no layer up, a colouring-mode-shaped event colours NOTHING. The
# i3 side is a dead input, not a quiet one.
stale_mode_event("screenshot")
check("a mode-shaped event is not a colour source at all",
      qsb.layer_colored is False)
drive_layer("nav")
drive_layer("default")
check("a layer coming and going leaves the ring plain",
      qsb.layer_colored is False)

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
check("replay-on-connect: it starts uncoloured too", qsb.layer_colored is False)

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
      qsb.layer_colored is True)

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
      qsb.layer_colored is False)

print()
if failures:
    print("%d failure(s): %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all tests passed")
