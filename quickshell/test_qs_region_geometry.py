"""One-shot synthetic tests for qs-region geometry + contract invariants.

The live region selector (qs-region.py) shapes its window down to a rubber-band
outline and grabs the seat for input. The drawing and the grab need a real X
display, so they are verified by the blink harness + attended runs (sp012
Task 1 test_plan). What IS testable headlessly is the geometry algebra and the
constants the rest of the system keys off — and those carry real bugs:

  - a right-to-left or bottom-to-top drag must normalise to positive w/h,
    because negative geometry reaching `scrot -a` is a hard failure
  - a drag beyond the screen edge must clamp, for the same reason
  - a stray click (sub-threshold) must read as cancel, not a 0x0 PNG
  - the window title is a CONTRACT: i3/picom.conf matches `qs-region` BY NAME
    (sp012 T5). A rename here silently breaks the native :0 excludes.

Run: python3 quickshell/test_qs_region_geometry.py
"""
import importlib.util, pathlib, sys, types

# Stub gi/cairo before import so the GTK code doesn't need a display.
sys.modules.setdefault("gi", type(sys)("gi"))
sys.modules["gi"].require_version = lambda *a, **k: None
gi_repo = types.ModuleType("gi.repository")
gi_repo.Gdk = types.SimpleNamespace(
    WindowTypeHint=types.SimpleNamespace(NOTIFICATION=0, DOCK=1),
    EventMask=types.SimpleNamespace(
        BUTTON_PRESS_MASK=1, BUTTON_RELEASE_MASK=2,
        POINTER_MOTION_MASK=4, KEY_PRESS_MASK=8),
    SeatCapabilities=types.SimpleNamespace(ALL=0),
    KEY_Escape=0xff1b,
    Screen=types.SimpleNamespace(get_default=lambda: None),
    Display=types.SimpleNamespace(get_default=lambda: None),
    Cursor=types.SimpleNamespace(new_from_name=lambda *a: None),
    cairo_region_create_from_surface=lambda s: None,
)
gi_repo.Gtk = types.SimpleNamespace(
    Window=lambda **k: None,
    WindowType=types.SimpleNamespace(POPUP=0),
    main=lambda: None,
    main_quit=lambda: None,
)
gi_repo.GLib = types.SimpleNamespace(idle_add=lambda f, *a: None)
sys.modules["gi.repository"] = gi_repo
sys.modules["cairo"] = types.SimpleNamespace(
    Region=lambda *a: None,
    RectangleInt=lambda *a: None,
    ImageSurface=lambda *a: None,
    Context=lambda *a: None,
    FORMAT_ARGB32=0,
    OPERATOR_CLEAR=0,
    OPERATOR_OVER=1,
)

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("qs_region", HERE / "qs-region.py")
qsr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qsr)

failures = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        failures.append(name)


print("normalise(): a drag is a rectangle regardless of direction")
# left-to-right, top-to-bottom — the easy case
check("l2r/t2b", qsr.normalise(600, 400, 1800, 1000, 2560, 1440) == (600, 400, 1200, 600))
# right-to-left: x1 < x0. Naive (x1-x0) yields -1200 and scrot -a rejects it.
check("r2l", qsr.normalise(1800, 400, 600, 1000, 2560, 1440) == (600, 400, 1200, 600))
# bottom-to-top: y1 < y0
check("b2t", qsr.normalise(600, 1000, 1800, 400, 2560, 1440) == (600, 400, 1200, 600))
# both reversed
check("r2l+b2t", qsr.normalise(1800, 1000, 600, 400, 2560, 1440) == (600, 400, 1200, 600))

print("normalise(): clamps to the screen, never emits negative geometry")
# started/released outside the screen — scrot -a must never see out-of-bounds
check("clamp right/bottom", qsr.normalise(2000, 1200, 9999, 9999, 2560, 1440)
      == (2000, 1200, 560, 240))
check("clamp left/top", qsr.normalise(-500, -500, 300, 200, 2560, 1440)
      == (0, 0, 300, 200))
check("fully offscreen collapses to zero, not negative",
      qsr.normalise(-900, -900, -500, -500, 2560, 1440)[2:] == (0, 0))

print("is_selection(): a stray click is a cancel, not a 0x0 capture")
check("zero area", not qsr.is_selection(0, 0))
check("thin sliver rejected (w ok, h too small)", not qsr.is_selection(500, 1))
check("real drag accepted", qsr.is_selection(1200, 600))
# Pin the boundary from BOTH sides, or an off-by-one in MIN_SEL slips through:
# MIN_SEL=3 means 3 is accepted and 2 is not.
check("just below MIN_SEL rejected", not qsr.is_selection(qsr.MIN_SEL - 1,
                                                          qsr.MIN_SEL - 1))
check("exactly MIN_SEL accepted", qsr.is_selection(qsr.MIN_SEL, qsr.MIN_SEL))

print("contract constants the rest of the system keys off")
# i3/picom.conf matches this literal (sp012 T5, dispatch decision). A rename
# here silently stops picom's focus-exclude matching -> overlay gets
# inactive-dim'd on native :0 with no error. Commit 935e568 hit this trap.
check("window title is exactly 'qs-region'", qsr.TITLE == "qs-region",
      f"got {getattr(qsr, 'TITLE', None)!r}")
# The MODE colour from Bar.qml:576/589 — NOT the #16a085 workspace green.
#
# Assert the TUPLE, because that is what _draw() paints with — asserting on
# ACCENT_HEX alone was tautological: the two constants used to be independent,
# so the painted colour could drift to the forbidden green with this test still
# green. Mutating the painted colour must now fail this.
check("painted outline colour is the mode colour #cb4b16",
      qsr.ACCENT == (0xcb / 255, 0x4b / 255, 0x16 / 255),
      f"got {getattr(qsr, 'ACCENT', None)!r}")
check("ACCENT_HEX agrees with the painted tuple (single source of truth)",
      qsr.ACCENT == tuple(int(qsr.ACCENT_HEX[i:i + 2], 16) / 255
                          for i in (1, 3, 5)),
      f"hex={qsr.ACCENT_HEX!r} tuple={qsr.ACCENT!r}")
# The green this must never be — an explicit negative guard, since the whole
# hazard is silently drifting to the workspace-focused colour.
check("painted colour is NOT the #16a085 workspace green",
      qsr.ACCENT != (0x16 / 255, 0xa0 / 255, 0x85 / 255))

print("shot_path(): matches ft006's api_surface contract")
p = qsr.shot_path("/tmp/xyz")
check("dir honoured + shot_<ts>.png shape",
      p.startswith("/tmp/xyz/shot_") and p.endswith(".png"))
check("timestamp is YYYYmmdd-HHMMSS",
      len(pathlib.Path(p).stem) == len("shot_20260715-142031"), p)

print()
if failures:
    print(f"FAILED: {len(failures)} -> {failures}")
    sys.exit(1)
print("all geometry/contract tests passed")
