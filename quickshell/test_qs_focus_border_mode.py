"""One-shot synthetic tests for qs-focus-border i3-mode suppression.

The screenshot selector is a quickshell dock layer entered via an i3 mode.
The border (keep-above notification window) must NOT redraw/restack while
that mode is active, must hide when the overlay dock actually maps
(window::new — not at mode enter, which is ~0.5s before the overlay covers
the screen), and must come back when the mode ends. Other modes (resize)
keep the live-refresh behavior.

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


# Baseline: a refresh with a focused window shows the border.
calls.clear()
qsb.refresh_focused()
check("baseline refresh shows border", "show" in calls)

# The binding that enters the screenshot mode arrives BEFORE the mode event
# and must already arm suppression instead of refreshing.
calls.clear()
qsb.handle_event(json.dumps({"change": "run", "binding": {
    "command": 'mode "screenshot"; exec --no-startup-id ~/x/qs-screenshot.sh'}}))
check("mode-enter binding arms suppression (no redraw)", not calls)

# Mode enter ("screenshot"): border must stay up — no hide (the overlay
# takes ~0.5s to map; hiding now blinks), no redraw.
calls.clear()
qsb.handle_event('{"change":"screenshot", "pango_markup":false}')
check("screenshot mode enter does not hide", "hide" not in calls)
check("screenshot mode enter does not redraw", "show" not in calls)

# While the mode is active, binding/mouse-poll refreshes must do nothing.
calls.clear()
qsb.refresh_focused()
qsb.handle_event('{"change":"run", "binding":{"command":"nop"}}')
check("refresh while suppressed is a no-op", not calls)

# Overlay dock maps: window::new (PanelWindow default name "quickshell")
# hides the border; the follow-up refresh is a no-op while suppressed.
calls.clear()
qsb.handle_event(json.dumps({"change": "new", "container": {"name": "quickshell"}}))
check("overlay window::new hides border", "hide" in calls)
check("overlay window::new does not redraw", "show" not in calls)

# Mode leave: border comes back for the focused window.
calls.clear()
qsb.handle_event('{"change":"default", "pango_markup":false}')
check("mode leave redraws border", "show" in calls)

# Non-suppress modes (resize) keep the live-refresh behavior.
calls.clear()
qsb.handle_event('{"change":"resize", "pango_markup":false}')
check("resize mode still refreshes", "show" in calls)
calls.clear()
qsb.refresh_focused()
check("refresh during resize mode still redraws", "show" in calls)
qsb.handle_event('{"change":"default", "pango_markup":false}')

# Bar restart: window::new (name "quickshell") outside any mode hides, then
# the follow-up refresh restores the border (no overlay in the tree).
calls.clear()
qsb.handle_event(json.dumps({"change": "new", "container": {"name": "quickshell"}}))
check("bar window::new hides then restores", "hide" in calls and "show" in calls
      and calls.index("hide") < calls.index("show"))

print()
if failures:
    print("%d failure(s): %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all tests passed")
