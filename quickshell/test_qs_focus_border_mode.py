"""One-shot synthetic tests for qs-focus-border i3-mode suppression.

The screenshot selector (quickshell/qs-region.py) is a GDK POPUP window —
override-redirect. i3 emits NO window::new for override-redirect windows, so
a hide keyed off that event NEVER FIRES for the overlay and the focus ring
lands in every live capture. Suppression therefore hangs off the i3 MODE
event, which is the only signal that arrives at all.

WHICH mode is the part this suite got wrong for a while (dotfiles-5quz). The
capture is TWO phases, and 29106e6 split them deliberately:

  "screenshot"       AIMING. The ring stays UP and is RECOLOURED — while you
                     are choosing what to capture, seeing which window is
                     focused is the point. In COLOR_MODES, not SUPPRESS_MODES.
  "screenshot-drag"  DRAWING. A synthetic mode qs-region.py enters from its own
                     `_press` with a direct `i3-msg` (not a bindsym) the moment
                     a region starts being drawn. The ring HIDES here and stays
                     hidden and un-refreshed, so it cannot restack above the
                     live overlay or be baked into the capture.

This suite encoded the pre-29106e6 contract ("screenshot hides") for both
phases and was 8-red on main until dotfiles-5quz re-pointed the suppression
cases at screenshot-drag and added the aiming-phase colour assertions.

Either phase REAPPEARS on the same i3 "mode default" transition, which both
the cancel and the save exit paths funnel through — from this module they are
indistinguishable events, so both are covered rather than one assumed from the
other. Other modes (resize) keep the live-refresh behavior.

Run: python3 quickshell/test_qs_focus_border_mode.py
"""
import importlib.util, json, os, pathlib, sys, threading, types

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
    """The mode qs-screenshot.sh enters while the selector is being AIMED.

    This mode does NOT hide the ring (dotfiles-5quz). Commit 29106e6 moved it
    into COLOR_MODES instead: while you are choosing what to capture, the ring
    stays up in the accent colour so you can see which window is focused.
    Suppression moved to `screenshot-drag` below, which is entered the instant
    a region is actually being drawn.
    """
    qsb.handle_event('{"change":"screenshot", "pango_markup":false}')


def enter_drag_mode():
    """The synthetic mode qs-region.py switches into from its own `_press` the
    moment the user starts drawing — an `i3-msg mode screenshot-drag`, not a
    keybinding. THIS is where the ring must vanish: the capture is about to
    happen and the border would be baked into it.

    The overlay is a GDK POPUP (override-redirect), so i3 emits NO window::new
    for it — a hide keyed off that event would never fire, which is why the
    mode event carries the whole responsibility.
    """
    qsb.handle_event('{"change":"screenshot-drag", "pango_markup":false}')


def leave_mode():
    qsb.handle_event('{"change":"default", "pango_markup":false}')


# Baseline: a refresh with a focused window shows the border.
calls.clear()
qsb.refresh_focused()
check("baseline refresh shows border", "show" in calls)

# A binding whose command enters a SUPPRESS mode must arm suppression BEFORE
# the mode event lands, or a refresh in flight between the two restacks the
# border above the overlay.
#
# RE-POINTED at screenshot-drag (dotfiles-5quz): this used to send the
# `mode "screenshot"` bind, which no longer suppresses anything. Two reasons
# the arm branch is now DEFENSIVE rather than load-bearing, both worth stating
# so nobody deletes it as dead: qs-region.py enters screenshot-drag with a
# direct `i3-msg`, not a bindsym, and $mod+Shift+s left i3 entirely with the
# screenshot group (dotfiles-hwds.39) so i3 emits no binding event for it at
# all. The branch survives because the ordering hazard it guards returns the
# moment anything binds a suppress mode again.
calls.clear()
qsb.handle_event(json.dumps({"change": "run", "binding": {
    "command": 'mode "screenshot-drag"'}}))
check("a suppress-mode binding arms suppression (no redraw)", not calls)
leave_mode()

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

# Half two: "screenshot-drag" — the capture is imminent, the ring must go.
calls.clear()
enter_drag_mode()
check("drag mode enter hides border", calls == ["hide"])
calls.clear()
qsb.refresh_focused()
check("drag mode enter still suppresses refresh", not calls)
leave_mode()

# The two are reached in sequence in real use (aim, then drag), so pin the
# transition rather than only the states: a colour set on the way in must not
# survive a drag that hides the ring, and the drag must suppress even though
# the mode it came FROM was unsuppressed.
calls.clear()
qsb.handle_event('{"change":"screenshot", "pango_markup":false}')
enter_drag_mode()
check("aim -> drag ends hidden and suppressed",
      "hide" in calls and qsb.mode_suppressed is True)
leave_mode()
check("leaving after a drag redraws", qsb.mode_suppressed is False)

# While the DRAG is active, binding/mouse-poll refreshes must do nothing —
# the border stays hidden, it does not get redrawn/restacked above the
# overlay. (Re-pointed from the aiming mode, which no longer suppresses:
# dotfiles-5quz.)
calls.clear()
enter_drag_mode()
calls.clear()
qsb.refresh_focused()
qsb.handle_event('{"change":"run", "binding":{"command":"nop"}}')
check("refresh while suppressed is a no-op", not calls)
leave_mode()

# Mode leave: border comes back for the focused window. This is the CANCEL
# path — Esc (or the launcher's fallback) drives the mode straight back to
# "default" with no intervening window events, since the overlay never
# wrote a file and closed without ever appearing in i3's tree.
calls.clear()
enter_drag_mode()
calls.clear()
leave_mode()
check("cancel path: mode leave redraws border", "show" in calls)

# SAVE path: capture succeeded, but other window/focus noise (e.g. the
# overlay briefly re-focusing its caller, a close event) may arrive before
# the mode-default transition lands. The border must still hide throughout
# and reappear once the mode actually ends — the save path is not
# distinguishable from cancel at the i3-mode level, and must be covered
# too, not assumed to work because cancel does.
calls.clear()
enter_drag_mode()
check("save path: still hidden after drag entry", calls == ["hide"])
calls.clear()
qsb.handle_event(json.dumps({"change": "close", "container": {
    "name": "term", "window_properties": {"class": "Alacritty"}}}))
# close unconditionally re-hides (idempotent, already hidden) but must not
# redraw/restack the border above the live overlay while suppressed.
check("save path: close noise during suppression does not redraw",
      "show" not in calls)
calls.clear()
leave_mode()
check("save path: mode leave redraws border", "show" in calls)

# Edge case: mode entered but the overlay never starts (exec failed, no
# window ever mapped) — the border must still return when the mode ends,
# not stay hidden forever waiting for a window::new that will never come.
calls.clear()
enter_drag_mode()
check("overlay-never-started: border hidden at drag enter", calls == ["hide"])
calls.clear()
leave_mode()
check("overlay-never-started: border returns without ever seeing a window",
      "show" in calls)

# Rapid mode enter/exit: no stuck-hidden or double-shown border.
calls.clear()
enter_drag_mode()
leave_mode()
enter_drag_mode()
leave_mode()
check("rapid enter/exit ends unsuppressed and visible", "show" in calls)
check("rapid enter/exit does not leave border stuck hidden",
      calls[-1] == "show" if calls else False)

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

# --- hotkeyd layer feed (dotfiles-hwds.9) -----------------------------------
# The red "keys are captured" ring used to key off the i3 `nav` mode; nav left
# i3 in the sp020 cutover, so the cue now follows the daemon's layer feed. These
# pin the mapping in isolation, which is where a silent regression would hide.
check("nav is no longer an i3 colouring mode", "nav" not in qsb.COLOR_MODES)
# ...but screenshot still is: it is a mode i3 genuinely still owns, and the ring
# doubles as "this is the window `w` would capture".
check("screenshot is still an i3 colouring mode", "screenshot" in qsb.COLOR_MODES)

qsb.i3_mode_colored = False
qsb.layer_colored = False
qsb.mode_colored = False
qsb._set_layer_colored(True)
check("entering a layer colours the ring", qsb.mode_colored is True)

calls.clear()
qsb._set_layer_colored(True)
check("a repeat of the same layer state does not redraw", calls == [])

qsb._set_layer_colored(False)
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

# A layer name the helper has never heard of still means "keys are captured":
# the daemon only publishes a layer when one is active, so anything that is not
# "default" qualifies. Guards against someone hardcoding {'nav'} here later.
check("any non-default layer counts", qsb.HOTKEYD_COLORS_ANY_LAYER is True)

# --- the two colour sources must not clobber each other ---------------------
# Colour now comes from an i3 mode (screenshot) OR a hotkeyd layer (nav), and
# they are independent: an i3 "mode default" event fires on leaving screenshot,
# and it must not blank a red the layer feed owns. Folding both into ONE flag —
# the shape this file had while COLOR_MODES was empty — regresses exactly here.
qsb.i3_mode_colored = False
qsb.layer_colored = False
qsb.mode_colored = False
qsb._set_layer_colored(True)                       # in a nav layer
qsb.handle_event('{"change":"screenshot"}')        # i3 mode on top of it
check("an i3 colour mode on top of a layer stays red", qsb.mode_colored is True)
qsb.handle_event('{"change":"default"}')           # i3 mode ends; layer persists
check("leaving the i3 mode does not blank the layer's red",
      qsb.mode_colored is True)
qsb._set_layer_colored(False)
check("clearing the layer with no i3 mode left clears the ring",
      qsb.mode_colored is False)

# ...and symmetrically: a layer ending must not blank an i3 mode's red.
qsb.handle_event('{"change":"screenshot"}')
check("an i3 colour mode alone colours the ring", qsb.mode_colored is True)
qsb._set_layer_colored(True)
qsb._set_layer_colored(False)
check("a layer coming and going leaves the i3 mode's red intact",
      qsb.mode_colored is True)
qsb.handle_event('{"change":"default"}')
check("both sources clear -> plain ring", qsb.mode_colored is False)

print()
if failures:
    print("%d failure(s): %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all tests passed")
