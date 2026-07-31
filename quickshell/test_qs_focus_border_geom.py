"""One-shot synthetic tests for qs-focus-border FRAME GEOMETRY (dotfiles-5wod).

The ring must land on the window's outer frame — title bar included, nothing
more. Getting there from an i3 tree node is not "rect minus the decoration
height", because WHERE the title bar sits relative to `rect` is not constant.
i3 reports that in `window_rect.y`, the client area's offset INSIDE `rect`:

  window_rect.y == 0        The title is drawn ABOVE `rect`. The strip belongs
                            to the parent (a tabbed container's tab bar), so
                            `rect` covers the client only and MUST be extended
                            upward by deco_h to reach the frame top.
  window_rect.y == deco_h   The title is already INSIDE `rect` — a leaf in a
                            plain split, where `rect` spans title + client.
                            Extending upward here OVERSHOOTS by deco_h: the
                            ring floats above the window and runs long at the
                            bottom.

Before dotfiles-5wod only the first shape was handled, so every window that was
not inside a tabbed container got a ring 24px too high and 24px too tall. The
numbers in the plain-split case below are captured verbatim from a live i3
(workspace copacks, lazygit window 48234501, ring overlay measured at
1280,7 1276x1429 = the computed frame plus the 2px outset).

A third shape has to keep working: a leaf inside a splith/splitv that is itself
inside a tabbed container. i3 reports deco_h=24 for that leaf even though no
per-leaf title is rendered — the tab strip belongs to the intermediate split,
not to this leaf — so it must not be extended either.

Run: python3 quickshell/test_qs_focus_border_geom.py
"""
import importlib.util, json, os, pathlib, sys, threading, types


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
    def move(self, *a): pass
    def resize(self, *a): pass
    def get_realized(self): return False
    def get_window(self): return None
    def show_all(self): pass
    def queue_draw(self): pass
    def hide(self): pass


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
    idle_add=lambda f, *a: (f(*a), False)[1],
    timeout_add=lambda *a, **k: None,
)
sys.modules["gi.repository"] = gi_repo
sys.modules["cairo"] = types.SimpleNamespace(
    Region=lambda *a: None,
    RectangleInt=lambda *a: None,
    OPERATOR_SOURCE=0,
    OPERATOR_OVER=1,
)


class NoThread:
    """Never start the subscribe/mouse/refresh threads — apply_geom is called
    directly here, so nothing in this suite needs a live i3."""

    def __init__(self, target=None, daemon=None, args=()): pass
    def start(self): pass


_RealThread = threading.Thread
threading.Thread = NoThread

import subprocess
subprocess.check_output = lambda *a, **k: json.dumps({"name": "root"}).encode()

os.environ["DISPLAY"] = ":99-qsb-geom-test"

spec = importlib.util.spec_from_file_location(
    "qsb_geom", pathlib.Path(__file__).parent / "qs-focus-border.py"
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


geoms = []
qsb.border.update = lambda x, y, w, h: geoms.append((x, y, w, h))


def frame_for(rect, deco_h, window_rect_y, parent_layouts):
    """Run apply_geom on a synthetic leaf and return the frame it asked for."""
    del geoms[:]
    leaf = {
        "name": "term",
        "window": 123,
        "window_properties": {"class": "Alacritty", "instance": "Alacritty"},
        "rect": rect,
        "deco_rect": {"height": deco_h},
        "window_rect": {"x": 4, "y": window_rect_y,
                        "width": rect["width"] - 8, "height": rect["height"] - 4},
    }
    qsb.apply_geom(leaf, [{"layout": l} for l in parent_layouts])
    return geoms[-1] if geoms else None


# --- the regression: a leaf in a plain split owns its own title bar ----------
# Verbatim from a live i3 — lazygit, direct child of a splith, no tabbed
# ancestor anywhere in the chain. The frame IS rect; nothing to extend.
plain = frame_for(
    rect={"x": 1282, "y": 33, "width": 1272, "height": 1401},
    deco_h=24, window_rect_y=24,
    parent_layouts=["splith", "output", "splith", "splith", "splith"],
)
check("plain-split leaf: frame is rect, not rect shifted up",
      plain == (1282, 33, 1272, 1401))
check("plain-split leaf: top edge is not lifted above the window",
      plain is not None and plain[1] == 33)
check("plain-split leaf: height does not run long past the window bottom",
      plain is not None and plain[3] == 1401)

# --- still correct: a tab strip lives ABOVE the leaf's rect ------------------
# Same workspace, the tabbed sibling. rect covers the client only, so the ring
# has to grow upward by deco_h to swallow the tab strip.
tabbed = frame_for(
    rect={"x": 6, "y": 57, "width": 1272, "height": 1377},
    deco_h=24, window_rect_y=0,
    parent_layouts=["splith", "output", "splith", "splith", "splith", "tabbed"],
)
check("tabbed leaf: frame grows upward over the tab strip",
      tabbed == (6, 33, 1272, 1401))

# --- still correct: deco_h reported for a title i3 never renders -------------
# Leaf inside a splith that is itself inside a tabbed container. The strip
# belongs to the intermediate split, so this leaf must not be extended.
nested = frame_for(
    rect={"x": 6, "y": 57, "width": 636, "height": 1377},
    deco_h=24, window_rect_y=0,
    parent_layouts=["splith", "output", "splith", "tabbed", "splith"],
)
check("leaf under split-under-tabbed: unrendered title is not swallowed",
      nested == (6, 57, 636, 1377))

# --- a borderless leaf has no decoration to reason about ---------------------
bare = frame_for(
    rect={"x": 10, "y": 20, "width": 300, "height": 200},
    deco_h=0, window_rect_y=0,
    parent_layouts=["splith"],
)
check("deco_h=0 leaf: frame is rect untouched", bare == (10, 20, 300, 200))

print()
if failures:
    print("%d FAILED: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all geometry checks passed")
