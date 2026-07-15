"""One-shot synthetic tests for qs-focus-border i3-mode suppression.

The screenshot selector (quickshell/qs-region.py) is a GDK POPUP window —
override-redirect. i3 emits NO window::new for override-redirect windows, so
a hide keyed off that event (the old contract this suite used to encode)
NEVER FIRES for the new overlay, and the focus ring lands in every live
capture. The correct contract: the border (keep-above notification window)
HIDES the moment the "screenshot" i3 MODE is entered, stays hidden and
un-refreshed for the whole mode (so it can't restack above the live overlay),
and REAPPEARS when the mode ends — on both the cancel and the save exit
paths, which both funnel through the same i3 "mode default" transition, so
from this module's perspective they are indistinguishable events and must
both be covered. Other modes (resize) keep the live-refresh behavior.

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
    """Simulate the two IPC events i3 actually emits for
    `bindsym $mod+Shift+s mode "screenshot"; exec ...`: the binding event
    first (arms suppression pre-emptively so an in-flight refresh can't
    restack), then the mode-change event (the actual mode-enter signal that
    must hide the border)."""
    qsb.handle_event(json.dumps({"change": "run", "binding": {
        "command": 'mode "screenshot"; exec --no-startup-id ~/x/qs-screenshot.sh'}}))
    qsb.handle_event('{"change":"screenshot", "pango_markup":false}')


def leave_mode():
    qsb.handle_event('{"change":"default", "pango_markup":false}')


# Baseline: a refresh with a focused window shows the border.
calls.clear()
qsb.refresh_focused()
check("baseline refresh shows border", "show" in calls)

# The binding that enters the screenshot mode arrives BEFORE the mode event
# and must already arm suppression instead of refreshing (no hide yet either
# — the mode event, not the binding, is the mode-enter signal).
calls.clear()
qsb.handle_event(json.dumps({"change": "run", "binding": {
    "command": 'mode "screenshot"; exec --no-startup-id ~/x/qs-screenshot.sh'}}))
check("mode-enter binding arms suppression (no redraw)", not calls)

# THE BUG THIS TASK FIXES: mode enter ("screenshot") must hide the border
# immediately. The overlay is a GDK POPUP (override-redirect) — i3 emits NO
# window::new for it, so a hide keyed off that event (the old contract)
# never fires and the border would be captured live in every shot.
calls.clear()
qsb.handle_event('{"change":"screenshot", "pango_markup":false}')
check("screenshot mode enter hides border", calls == ["hide"])
leave_mode()

# Isolate the mode branch's OWN responsibility for arming suppression —
# send ONLY the mode event, with no preceding binding-arm event (which sets
# mode_suppressed=True on its own and would otherwise mask this code path
# via leftover module-global state from a prior test). Without the mode
# branch's own "mode_suppressed = True", a refresh right after mode-enter
# would slip through and restack the border above the live overlay.
calls.clear()
qsb.handle_event('{"change":"screenshot", "pango_markup":false}')
check("mode-only entry (no binding) hides border", calls == ["hide"])
calls.clear()
qsb.refresh_focused()
check("mode-only entry (no binding) still suppresses refresh", not calls)
leave_mode()

# While the mode is active, binding/mouse-poll refreshes must do nothing —
# the border stays hidden, it does not get redrawn/restacked above the
# overlay.
calls.clear()
enter_screenshot_mode()
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
enter_screenshot_mode()
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
enter_screenshot_mode()
check("save path: still hidden after mode entry", calls == ["hide"])
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
enter_screenshot_mode()
check("overlay-never-started: border hidden at mode enter", calls == ["hide"])
calls.clear()
leave_mode()
check("overlay-never-started: border returns without ever seeing a window",
      "show" in calls)

# Rapid mode enter/exit: no stuck-hidden or double-shown border.
calls.clear()
enter_screenshot_mode()
leave_mode()
enter_screenshot_mode()
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

print()
if failures:
    print("%d failure(s): %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all tests passed")
