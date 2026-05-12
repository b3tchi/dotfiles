"""One-shot synthetic walk tests for qs-focus-dim dialog handling.
Run: python3 quickshell/test_qs_focus_dim_dialogs.py
"""
import importlib.util, pathlib, sys, types

# Stub gi/cairo before import so the GTK overlay code doesn't try to draw.
sys.modules.setdefault("gi", type(sys)("gi"))
sys.modules["gi"].require_version = lambda *a, **k: None
gi_repo = types.ModuleType("gi.repository")

# Gdk stub: Display.get_default() returns a mock display with n_monitors=0
_mock_display = types.SimpleNamespace(
    get_n_monitors=lambda: 0,
    get_monitor=lambda i: types.SimpleNamespace(get_geometry=lambda: types.SimpleNamespace(x=0, y=0, width=1920, height=1080)),
)
_mock_gdk = types.SimpleNamespace(
    Display=types.SimpleNamespace(get_default=lambda: _mock_display),
    WindowTypeHint=types.SimpleNamespace(NOTIFICATION=0),
)
gi_repo.Gdk = _mock_gdk
gi_repo.Gtk = types.SimpleNamespace(
    Window=lambda **k: None,
    WindowType=types.SimpleNamespace(POPUP=0),
    main=lambda: None,
)
gi_repo.GLib = types.SimpleNamespace(
    idle_add=lambda *a, **k: None,
    timeout_add=lambda *a, **k: None,
)
sys.modules["gi.repository"] = gi_repo
sys.modules["cairo"] = types.SimpleNamespace(
    Region=lambda *a: None,
    RectangleInt=lambda *a: None,
    OPERATOR_SOURCE=0,
    OPERATOR_OVER=1,
)

spec = importlib.util.spec_from_file_location(
    "qsd", pathlib.Path(__file__).parent / "qs-focus-dim.py"
)
qsd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qsd)


def make_leaf(cls="", title="", fullscreen=0):
    return {
        "focused": True,
        "window": 1,
        "window_properties": {"class": cls, "instance": cls},
        "name": title,
        "rect": {"x": 100, "y": 100, "width": 800, "height": 600},
        "deco_rect": {"height": 0},
        "fullscreen_mode": fullscreen,
        "nodes": [],
        "floating_nodes": [],
    }


def wrap_floating(leaf):
    return {"nodes": [], "floating_nodes": [
        {"nodes": [leaf], "floating_nodes": []}
    ]}


def wrap_tiled(leaf):
    return {"nodes": [leaf], "floating_nodes": []}


def run():
    # Case 1: regular tiled window — focusable
    qsd.focus_rect = None
    qsd._compute_focus_rect(wrap_tiled(make_leaf(cls="Firefox", title="example.com - Mozilla Firefox")))
    assert qsd.focus_rect is not None, "regular tiled window should produce focus_rect"

    # Case 2: floating qs- dialog — focusable
    qsd.focus_rect = None
    qsd._compute_focus_rect(wrap_floating(make_leaf(cls="quickshell", title="qs-overlay-projects")))
    assert qsd.focus_rect is not None, "floating qs- dialog must be focusable"

    # Case 3: floating Rofi — focusable (rofi removed from IGNORE_CLASSES)
    qsd.focus_rect = None
    qsd._compute_focus_rect(wrap_floating(make_leaf(cls="Rofi", title="rofi")))
    assert qsd.focus_rect is not None, "floating rofi must be focusable now"

    # Case 4: bar (class quickshell, tiled, no qs- title) — IGNORED
    qsd.focus_rect = "PLACEHOLDER"
    qsd._compute_focus_rect(wrap_tiled(make_leaf(cls="quickshell", title="")))
    assert qsd.focus_rect is None, "tiled quickshell bar must remain ignored"

    # Case 5: qs- titled tiled window — focusable via title prefix
    qsd.focus_rect = None
    qsd._compute_focus_rect(wrap_tiled(make_leaf(cls="anything", title="qs-anything")))
    assert qsd.focus_rect is not None, "qs- titled tiled window should be focusable"

    # Case 6: fullscreen wins over focusable
    qsd.focus_rect = "PLACEHOLDER"
    qsd._compute_focus_rect(wrap_floating(make_leaf(cls="quickshell", title="qs-foo", fullscreen=1)))
    assert qsd.focus_rect is None, "fullscreen wins over focusable"

    # Case 7: no focused window — full dim
    qsd.focus_rect = "PLACEHOLDER"
    qsd._compute_focus_rect({"nodes": [], "floating_nodes": []})
    assert qsd.focus_rect is None, "no focus → full dim"

    print("All 7 synthetic walk cases passed.")


if __name__ == "__main__":
    run()
