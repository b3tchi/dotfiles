# Focus Dim Overlay Implementation Plan

> **For Claude:** Use infinifu:plan-scrum-master (automated) or infinifu:plan-supervised (user reviews each batch) to implement this plan.

**Epic:** `dotfiles-0xd`
**Tasks:** `dotfiles-0xd.1` … `dotfiles-0xd.9` (one per Task section below)

**Goal:** Add a 30%-black dim overlay covering everything outside the focused window, mirroring the lifecycle of the existing focus border, on both X11/i3 and Wayland/sway.

**Architecture:** Sibling component to `FocusBorder`. `FocusDim.qml` dispatcher detects platform → spawns `qs-focus-dim.py` (X11 GTK3 cairo overlay) or loads `FocusDimWayland.qml` (Quickshell PanelWindow layer-shell). Both implementations subscribe to the same IPC stream as the border, compute the focused-window rectangle, and paint 4 rectangles outside it at `rgba(0,0,0,0.3)`. Bar/quickshell overlays sit at a higher layer and stay bright.

**Tech Stack:** Quickshell QML, Python 3 + GTK3 + cairo (X11), `i3-msg` / `swaymsg` IPC.

---

## Conventions

- Quickshell config files live in `quickshell/config/`, symlinked to `~/.config/quickshell` via rotz.
- Helper scripts live in `quickshell/` directly and are invoked from QML by absolute path (`$HOME/.dotfiles/quickshell/...`). Do **not** add new entries to `quickshell/dot.yaml` for them.
- No automated test framework exists for the quickshell layer. Verification is **manual run + visual confirmation**. Each task lists explicit `expected: ...` observations and a verification command/keybind.
- Commits use Conventional Commits: `feat(quickshell): ...`, `fix(quickshell): ...`.
- Follow the existing style in `qs-focus-border.py` (single-instance lockfile, RGBA visual, click-through via empty input shape region, GLib.idle_add for cross-thread UI updates).
- `IGNORE_CLASSES` and `ignoreAppIds` must match the border's set: `quickshell`, `Rofi` / `rofi`, plus titles starting with `qs-`.

## Anti-patterns

- ❌ Do **not** swallow exceptions silently in `qs-focus-dim.py`. The border script does this and it hides crashes in production. New code in this spec must `print(..., file=sys.stderr, flush=True)` inside the `except Exception` branches before falling through.
- ❌ Do **not** import `Xlib` at module top-level — keep it inside `mouse_monitor` so the script still runs (without drag polling) when `python-xlib` is absent.
- ❌ Do **not** assume `Gdk.Display.get_default()` returns non-`None`. If `None`, log to stderr and `sys.exit(1)` — never construct overlays with no display.
- ❌ Do **not** add a `--no-verify` to any commit. Pre-commit hooks must pass.
- ❌ Do **not** ship a `TODO` without a follow-up bd task referenced in the same commit message.
- ❌ Do **not** copy-paste from `FocusBorderWayland.qml` without removing the border-only properties (`bw`, `br`, `bc`, `inset`) — leaving them in is dead code.
- ❌ Do **not** introduce a `Component.onCompleted` that hardcodes focus state without removing it in the same task's final step.

## Known limitations (inherited from focus border)

The existing `qs-focus-border.py` and `FocusBorderWayland.qml` have two unaddressed limitations. The dim overlay inherits both and **does not fix them in this epic**. File follow-up bd issues if either matters on the target host:

1. **HiDPI / fractional scaling.** i3 and sway report rects in root coords without DPI normalization; GTK/QML render in logical pixels. On non-100% scale outputs the focused-window cut-out may be off by a few pixels. Verify on the actual target host; file a follow-up if visible.
2. **Wayland multi-monitor coords.** `FocusBorderWayland.qml` uses sway-reported root coords directly inside a per-output `PanelWindow`. With monitors at different x/y offsets the cut-out positions are wrong on every output except the primary. WSL is single-output today so this is latent.

## File tree

```
quickshell/
├── config/
│   ├── FocusDim.qml          (new — dispatcher, sibling to FocusBorder.qml)
│   ├── FocusDimWayland.qml   (new — Wayland layer-shell impl)
│   └── shell.qml             (modified — mount FocusDim {})
└── qs-focus-dim.py           (new — X11 GTK overlay)
```

---

## Task 1: X11 overlay skeleton — fullscreen 30% black, no cut-out

Stand up the GTK process on its own first. Confirm it draws, is click-through, and uses the right visual hint.

**Files:**
- Create: `quickshell/qs-focus-dim.py`

**Step 1: Write the script**

```python
#!/usr/bin/env python3
"""Minimal i3 focus dim — sibling to qs-focus-border.py.
Draws a 30% black overlay covering everything outside the focused window.
Started and managed by quickshell (config/FocusDim.qml)."""
import gi, signal, sys, fcntl, os
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk
import cairo

_lock_path = os.path.join(
    os.environ.get('XDG_RUNTIME_DIR', '/tmp'), 'qs-focus-dim.lock'
)
_lock_fp = open(_lock_path, 'w')
try:
    fcntl.flock(_lock_fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
_lock_fp.write(str(os.getpid()))
_lock_fp.flush()

DIM_ALPHA = 0.3


class DimOverlay:
    def __init__(self, monitor):
        self.monitor = monitor
        self.win = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.win.set_title('qs-focus-dim')
        self.win.set_keep_above(True)
        self.win.set_accept_focus(False)
        self.win.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        visual = self.win.get_screen().get_rgba_visual()
        if visual:
            self.win.set_visual(visual)
        self.win.set_app_paintable(True)
        self.win.connect('draw', self._draw)
        self.win.connect('realize', lambda w: self._passthrough())
        g = monitor.get_geometry()
        self.win.move(g.x, g.y)
        self.win.resize(g.width, g.height)
        self.win.show_all()

    def _passthrough(self):
        if self.win.get_realized():
            region = cairo.Region(cairo.RectangleInt(0, 0, 0, 0))
            self.win.get_window().input_shape_combine_region(region, 0, 0)

    def _draw(self, widget, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        a = widget.get_allocation()
        cr.set_source_rgba(0, 0, 0, DIM_ALPHA)
        cr.rectangle(0, 0, a.width, a.height)
        cr.fill()


display = Gdk.Display.get_default()
overlays = [DimOverlay(display.get_monitor(i))
            for i in range(display.get_n_monitors())]

signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
signal.signal(signal.SIGINT, lambda *a: sys.exit(0))

Gtk.main()
```

Notes:
- `Gdk.Display.get_default()` may return `None` if no DISPLAY is set. Add an explicit check after the `display = ...` line: `if display is None: print("qs-focus-dim: no display", file=sys.stderr); sys.exit(1)`.
- The `except OSError` on the flock falls through to `sys.exit(0)` silently — that path is fine (a second instance is meant to be a no-op).

**Step 2: Make it executable + run standalone**

```bash
chmod +x quickshell/qs-focus-dim.py
python3 -u $HOME/.dotfiles/quickshell/qs-focus-dim.py &
DIMPID=$!
```

**Success criteria (must all pass):**
- [ ] Every monitor visibly ~30% darker (compare with monitor unaffected by toggling kill / restart)
- [ ] Click on a window underneath still focuses it (no input capture)
- [ ] No flicker, tearing, or scanline artefacts during 5 seconds of idle observation
- [ ] `pgrep -af qs-focus-dim.py` shows exactly one process
- [ ] Starting a second instance: it exits immediately (flock works); first instance unaffected

**Step 3: Kill it**

```bash
kill $DIMPID
```

Expected: dim disappears within 1 frame (≤16 ms). Lockfile released — re-running the script succeeds.

**Step 4: Commit**

```bash
git add quickshell/qs-focus-dim.py
git commit -m "feat(quickshell): add focus dim X11 overlay skeleton"
```

---

## Task 2: X11 overlay — cut-out around focused window

Replace the fullscreen black rect with 4 rects forming a hollow frame. For this task hardcode a fake focused rect so we can confirm the cairo math before wiring i3.

**Files:**
- Modify: `quickshell/qs-focus-dim.py`

**Step 1: Replace `_draw` with cut-out math**

Above `class DimOverlay`, add:

```python
# Test geometry — replaced by i3 IPC in Task 3
TEST_FOCUS = (400, 200, 800, 600)  # x, y, w, h
```

Replace `_draw` method body with:

```python
    def _draw(self, widget, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        a = widget.get_allocation()
        fx, fy, fw, fh = TEST_FOCUS
        # Translate focus rect into this monitor's local coords
        g = self.monitor.get_geometry()
        fx -= g.x
        fy -= g.y
        cr.set_source_rgba(0, 0, 0, DIM_ALPHA)
        # If focus rect doesn't intersect this monitor, dim entire monitor
        if fx + fw <= 0 or fy + fh <= 0 or fx >= a.width or fy >= a.height:
            cr.rectangle(0, 0, a.width, a.height)
            cr.fill()
            return
        # Clip to monitor bounds
        cx = max(0, fx); cy = max(0, fy)
        cw = min(a.width, fx + fw) - cx
        ch = min(a.height, fy + fh) - cy
        # 4 rects outside focus
        cr.rectangle(0, 0, a.width, cy)                          # top
        cr.rectangle(0, cy + ch, a.width, a.height - (cy + ch))  # bottom
        cr.rectangle(0, cy, cx, ch)                              # left
        cr.rectangle(cx + cw, cy, a.width - (cx + cw), ch)       # right
        cr.fill()
```

**Step 2: Run and verify cut-out**

```bash
python3 -u $HOME/.dotfiles/quickshell/qs-focus-dim.py
```

**Success criteria (must all pass):**
- [ ] Bright rectangular hole at screen coords (400, 200) sized exactly 800×600
- [ ] Pixels at the focus rect's corners (e.g. (400,200), (1199,799)) are at full brightness (not dimmed by ~1px overlap)
- [ ] Pixels just outside the focus rect (e.g. (399,200), (1200,799)) are dimmed
- [ ] Multi-monitor: if the test rect lies entirely on monitor 0, monitor 1 (if present) is **fully** dimmed (no partial cut-out)
- [ ] No double-painted edges (would look like a darker ring around the cut-out)

Ctrl+C to stop.

**Step 3: Commit**

```bash
git add quickshell/qs-focus-dim.py
git commit -m "feat(quickshell): draw cut-out around hardcoded focus rect"
```

---

## Task 3: X11 overlay — wire i3 IPC for live focused-window rect

Replace `TEST_FOCUS` with the real focused-window geometry from i3, subscribing to the same events as `qs-focus-border.py`.

**Files:**
- Modify: `quickshell/qs-focus-dim.py`

**Step 1: Import additional modules**

At the top of the file (alongside existing imports):

```python
import json, subprocess, threading
from gi.repository import GLib
```

**Step 2: Remove the test constant; add focus state and walk logic**

Replace `TEST_FOCUS = (400, 200, 800, 600)` with:

```python
IGNORE_CLASSES = {'quickshell', 'Rofi', 'rofi'}

# Current focused-window rect in root (screen) coords; None means hide cut-out
focus_rect = None


def should_ignore(c):
    props = c.get('window_properties', {})
    cls = props.get('class', '')
    instance = props.get('instance', '')
    title = c.get('name', '')
    if cls in IGNORE_CLASSES or instance in IGNORE_CLASSES:
        return True
    if title.startswith('qs-'):
        return True
    return False


def refresh_focused():
    def _do():
        try:
            tree = json.loads(
                subprocess.check_output(
                    ['i3-msg', '-t', 'get_tree'], timeout=2
                ).decode()
            )

            def walk(node, parents):
                if node.get('focused') and node.get('window'):
                    return node, parents
                for child in node.get('nodes', []) + node.get('floating_nodes', []):
                    r = walk(child, parents + [node])
                    if r:
                        return r
                return None

            result = walk(tree, [])
            global focus_rect
            if not result:
                focus_rect = None
            else:
                leaf, parents = result
                if should_ignore(leaf) or leaf.get('fullscreen_mode', 0) > 0:
                    focus_rect = None
                else:
                    r = leaf.get('rect', {})
                    deco_h = leaf.get('deco_rect', {}).get('height', 0)
                    in_tabbed = any(p.get('layout') in ('tabbed', 'stacked') for p in parents)
                    direct_in_tabbed = parents and parents[-1].get('layout') in ('tabbed', 'stacked')
                    if in_tabbed and not direct_in_tabbed:
                        deco_h = 0
                    focus_rect = (
                        r.get('x', 0),
                        r.get('y', 0) - deco_h,
                        r.get('width', 0),
                        r.get('height', 0) + deco_h,
                    )
            GLib.idle_add(_redraw_all)
        except Exception as exc:
            print(f"qs-focus-dim: refresh_focused: {exc}",
                  file=sys.stderr, flush=True)
    threading.Thread(target=_do, daemon=True).start()


def _redraw_all():
    for o in overlays:
        o.win.queue_draw()
    return False


def subscribe():
    import time
    while True:
        try:
            proc = subprocess.Popen(
                ['i3-msg', '-t', 'subscribe', '-m',
                 '["window","workspace","binding"]'],
                stdout=subprocess.PIPE, text=True
            )
            for _ in proc.stdout:
                refresh_focused()
            proc.wait()
        except Exception as exc:
            print(f"qs-focus-dim: subscribe: {exc}",
                  file=sys.stderr, flush=True)
        time.sleep(1)
```

**Step 3: Rewrite `_draw` to consume `focus_rect` instead of `TEST_FOCUS`**

Replace the cairo body in `_draw` so it reads the module-level `focus_rect`:

```python
    def _draw(self, widget, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        a = widget.get_allocation()
        cr.set_source_rgba(0, 0, 0, DIM_ALPHA)
        if focus_rect is None:
            cr.rectangle(0, 0, a.width, a.height)
            cr.fill()
            return
        fx, fy, fw, fh = focus_rect
        g = self.monitor.get_geometry()
        fx -= g.x; fy -= g.y
        if fx + fw <= 0 or fy + fh <= 0 or fx >= a.width or fy >= a.height:
            cr.rectangle(0, 0, a.width, a.height)
            cr.fill()
            return
        cx = max(0, fx); cy = max(0, fy)
        cw = min(a.width, fx + fw) - cx
        ch = min(a.height, fy + fh) - cy
        cr.rectangle(0, 0, a.width, cy)
        cr.rectangle(0, cy + ch, a.width, a.height - (cy + ch))
        cr.rectangle(0, cy, cx, ch)
        cr.rectangle(cx + cw, cy, a.width - (cx + cw), ch)
        cr.fill()
```

**Step 4: Start the subscriber + initial refresh**

Just before `Gtk.main()`, add:

```python
GLib.idle_add(refresh_focused)
threading.Thread(target=subscribe, daemon=True).start()
```

**Step 5: Run + verify live tracking**

```bash
python3 -u $HOME/.dotfiles/quickshell/qs-focus-dim.py &
```

Expected behaviours:
- Cut-out tracks the focused window when you focus another window with `$mod+j/k` (or whatever the i3 bind is)
- Cut-out moves with `$mod+Shift+arrow` window moves
- Workspace switch repositions cut-out around the new focused window
- Fullscreen (`$mod+f`) hides the cut-out → entire screen dimmed
- Rofi (`$mod+d`) → cut-out hidden while rofi visible (focus = rofi → ignored)

Kill the process when done:
```bash
pkill -f qs-focus-dim.py
```

**Success criteria (must all pass):**
- [ ] Focus a different window with `$mod+j/k` → cut-out moves to it within ~100 ms
- [ ] Move window with `$mod+Shift+arrow` → cut-out follows
- [ ] Workspace switch (`$mod+2`) → cut-out repositions around the new workspace's focused window
- [ ] Fullscreen toggle (`$mod+f`) → cut-out disappears (whole monitor dimmed); exit fullscreen → cut-out returns
- [ ] Open rofi (`$mod+d`) → cut-out hidden while rofi visible; close rofi → cut-out returns on previously focused window
- [ ] `i3-msg` errors visible in stderr (artificially break: `chmod -x $(which i3-msg)` briefly) — no silent failure
- [ ] Tabbed/stacked container leaf — cut-out covers leaf body only, not the parent strip's title bar area

**Step 6: Commit**

```bash
git add quickshell/qs-focus-dim.py
git commit -m "feat(quickshell): track focused window via i3 IPC in dim overlay"
```

---

## Task 4: X11 overlay — mouse drag polling

Mirror the border script: poll geometry while left mouse button is held to follow drag-resize/move smoothly.

**Files:**
- Modify: `quickshell/qs-focus-dim.py`

**Step 1: Add `mouse_monitor` and `mouse_poll` adapted from `qs-focus-border.py`**

Add the following near the bottom, before the `signal.signal` lines:

```python
mouse_held = False
mouse_poll_id = None


def mouse_poll():
    global mouse_held, mouse_poll_id
    if not mouse_held:
        mouse_poll_id = None
        refresh_focused()
        return False
    refresh_focused()
    return True


def mouse_monitor():
    import struct
    try:
        from Xlib import display as xdisplay
        from Xlib.ext import xinput
    except ImportError:
        print("qs-focus-dim: python-xlib not installed; "
              "mouse-drag polling disabled", file=sys.stderr, flush=True)
        return
    d = xdisplay.Display()
    if not d.has_extension("XInputExtension"):
        return
    root = d.screen().root
    root.xinput_select_events([
        (xinput.AllMasterDevices,
         xinput.RawButtonPressMask | xinput.RawButtonReleaseMask),
    ])
    d.sync()
    hdr = struct.Struct("<HII")
    global mouse_held, mouse_poll_id
    while True:
        event = d.next_event()
        evtype = getattr(event, "evtype", None)
        data = getattr(event, "data", None)
        if not isinstance(data, (bytes, bytearray)) or len(data) < hdr.size:
            continue
        _, _, button = hdr.unpack_from(data, 0)
        if button != 1:
            continue
        if evtype == xinput.RawButtonPress:
            mouse_held = True
            if mouse_poll_id is None:
                mouse_poll_id = GLib.timeout_add(100, mouse_poll)
        elif evtype == xinput.RawButtonRelease:
            mouse_held = False
```

Then start the thread alongside the `subscribe` thread:

```python
threading.Thread(target=mouse_monitor, daemon=True).start()
```

**Step 2: Run + verify**

```bash
python3 -u $HOME/.dotfiles/quickshell/qs-focus-dim.py &
```

**Success criteria (must all pass):**
- [ ] Drag-resize a floating window with the mouse → cut-out follows at ~10 fps during the drag
- [ ] On mouse release the cut-out snaps to the final geometry within one frame
- [ ] Right-click and middle-click drags do **not** trigger polling (only button 1)
- [ ] Verified: `pip uninstall python-xlib` (or temporarily rename the module) → script continues to run with i3-IPC tracking; stderr shows the warning; no crash
- [ ] Verified `pkill -f qs-focus-dim.py` cleanly terminates (no zombie threads — `pgrep` returns nothing after 1 s)

Restore python-xlib if you uninstalled it. Kill the test process:

```bash
pkill -f qs-focus-dim.py
```

**Step 3: Commit**

```bash
git add quickshell/qs-focus-dim.py
git commit -m "feat(quickshell): poll dim cut-out during mouse drag"
```

---

## Task 5: Wayland overlay — fullscreen 30% black, no cut-out

**Files:**
- Create: `quickshell/config/FocusDimWayland.qml`
- Create: `quickshell/config/FocusDim.qml`
- Modify: `quickshell/config/shell.qml`

**Step 1: Write minimal layer-shell PanelWindow**

`quickshell/config/FocusDimWayland.qml`:

```qml
import Quickshell
import Quickshell.Io
import QtQuick

Variants {
    model: Quickshell.screens

    PanelWindow {
        id: dimOverlay
        required property var modelData
        screen: modelData

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        aboveWindows: true
        exclusiveZone: 0
        focusable: false
        color: "transparent"

        mask: Region {}   // empty = fully click-through

        // Fullscreen dim — Task 6 replaces this with 4-rect cut-out
        Rectangle {
            anchors.fill: parent
            color: "#4D000000"   // 30% black
        }
    }
}
```

**Step 2: Create the dispatcher (mount-only stub; Task 8 adds X11 spawn)**

`quickshell/config/FocusDim.qml`:

```qml
import Quickshell
import QtQuick

Item {
    id: root
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null

    Loader {
        active: isSway
        source: "FocusDimWayland.qml"
    }
}
```

**Step 3: Mount in shell.qml**

In `quickshell/config/shell.qml`, add `FocusDim {}` directly after `FocusBorder {}` (around line 81):

```qml
FocusBorder {}
FocusDim {}
```

**Step 4: Restart quickshell on sway and verify**

```bash
pkill -x quickshell; sleep 1; $HOME/.dotfiles/quickshell/qs-start.sh &
```

**Success criteria (must all pass):**
- [ ] Every monitor uniformly ~30% darker
- [ ] **Bar stays at full brightness** — this is the critical z-order check. If the bar appears dimmed, the dim PanelWindow is on the same/higher layer as the bar. To fix: ensure `FocusDim {}` is mounted in `shell.qml` **before** the bar's `Variants { ... Bar {} }`, so the bar's surface is committed after dim and stays on top within the same layer. If that still doesn't work, demote dim to a lower layer (Quickshell exposes `aboveWindows` as boolean only — workaround is to drop `aboveWindows: true` so the surface goes to the default `top` minus one step, or render dim above wallpaper only).
- [ ] Notifications, tray icons, ticker still readable
- [ ] Clicks pass through to windows under the dim (test: open a terminal, click a button on a webpage in another window)
- [ ] (No cut-out yet — Task 6 adds it.)

**Step 5: Commit**

```bash
git add quickshell/config/FocusDim.qml quickshell/config/FocusDimWayland.qml quickshell/config/shell.qml
git commit -m "feat(quickshell): add focus dim Wayland overlay skeleton"
```

---

## Task 6: Wayland overlay — focused-window cut-out

Add 4 Rectangles positioned around `fx,fy,fw,fh` so the focused window is the cut-out.

**Files:**
- Modify: `quickshell/config/FocusDimWayland.qml`

**Step 1: Add focus-rect properties and 4 dim rects**

Replace the single `Rectangle { anchors.fill: parent }` with:

```qml
property int fx: 0
property int fy: 0
property int fw: 0
property int fh: 0
property bool hasFocus: false
readonly property string dimColor: "#4D000000"   // 30% black

// Top
Rectangle {
    color: dimOverlay.dimColor
    x: 0; y: 0
    width: parent.width
    height: dimOverlay.hasFocus ? Math.max(0, dimOverlay.fy) : parent.height
}
// Bottom
Rectangle {
    visible: dimOverlay.hasFocus
    color: dimOverlay.dimColor
    x: 0
    y: dimOverlay.fy + dimOverlay.fh
    width: parent.width
    height: Math.max(0, parent.height - (dimOverlay.fy + dimOverlay.fh))
}
// Left
Rectangle {
    visible: dimOverlay.hasFocus
    color: dimOverlay.dimColor
    x: 0
    y: dimOverlay.fy
    width: Math.max(0, dimOverlay.fx)
    height: dimOverlay.fh
}
// Right
Rectangle {
    visible: dimOverlay.hasFocus
    color: dimOverlay.dimColor
    x: dimOverlay.fx + dimOverlay.fw
    y: dimOverlay.fy
    width: Math.max(0, parent.width - (dimOverlay.fx + dimOverlay.fw))
    height: dimOverlay.fh
}
```

**Step 2: Reload quickshell with a hardcoded focus for visual check**

Temporarily add after the property block (remove before committing):

```qml
Component.onCompleted: { fx = 200; fy = 100; fw = 800; fh = 500; hasFocus = true; }
```

Restart:

```bash
pkill -x quickshell; sleep 1; $HOME/.dotfiles/quickshell/qs-start.sh &
```

**Success criteria (must all pass):**
- [ ] Bright rectangle visible at (200, 100) size 800×500
- [ ] Outside the rectangle: 30% black dim
- [ ] The four `Rectangle` siblings touch with no visible gap and no double-overlap (gap = bright line; overlap = darker line)
- [ ] Bar still bright (re-verify the z-order check from Task 5)

Remove the `Component.onCompleted` line before continuing — leaving it in is a Task-5 anti-pattern (hardcoded focus state).

**Step 3: Commit**

```bash
git add quickshell/config/FocusDimWayland.qml
git commit -m "feat(quickshell): draw cut-out around focus rect on Wayland"
```

---

## Task 7: Wayland overlay — sway IPC subscription

Mirror `FocusBorderWayland.qml`: subscribe to sway window/workspace/mode events, scan tree for focused window on startup/workspace-switch, poll during keyboard resize and mouse drag.

**Files:**
- Modify: `quickshell/config/FocusDimWayland.qml`

**Step 1: Add `applyContainer`, ignore list, fullscreen handling**

Inside `PanelWindow`, add:

```qml
readonly property var ignoreAppIds: ["quickshell", "rofi"]

function applyContainer(c) {
    var appId = c.app_id || ""
    var title = c.name || ""
    if (ignoreAppIds.indexOf(appId) >= 0 || title.startsWith("qs-")) {
        hasFocus = false
        return
    }
    if (c.fullscreen_mode > 0) {
        hasFocus = false
        return
    }
    var r = c.rect || {}
    var decoH = (c.deco_rect || {}).height || 0
    fx = r.x || 0
    fy = (r.y || 0) - decoH
    fw = r.width || 0
    fh = (r.height || 0) + decoH
    hasFocus = (fw > 0 && fh > 0)
}
```

**Step 2: Subscribe to sway events and scan the tree**

Add `swaySubscribe` / `modeSubscribe` / `resizePoller` / `dragPoller` / `focusScan` blocks inside the same `PanelWindow`. Copy the structure verbatim from `FocusBorderWayland.qml` lines 58–183 with these substitutions:

- `borderOverlay` → `dimOverlay`
- `borderVisible` → `hasFocus`
- Remove the border-only properties (`bw`, `br`, `bc`, `inset`) — they don't exist on the dim overlay
- Keep all the close-race / fullscreen-toggle / workspace-switch / drag-poll-stop-when-stable logic intact

The `focusScan.onExited` `walk` function should call `dimOverlay.applyContainer(node)` and set `dimOverlay.hasFocus = false` on the no-result branch.

**Step 3: Reload quickshell and verify**

```bash
pkill -x quickshell; sleep 1; $HOME/.dotfiles/quickshell/qs-start.sh &
```

**Success criteria (must all pass, on WSL/sway):**
- [ ] Cut-out follows focused window through `$mod+arrow` focus changes within ~100 ms
- [ ] Cut-out tracks `$mod+Shift+arrow` window moves
- [ ] Cut-out tracks floating window drag with the mouse (uses `dragPoller`)
- [ ] Keyboard resize mode (`$mod+r` then arrow keys) → cut-out updates continuously (uses `resizePoller`)
- [ ] Fullscreen (`$mod+f`) → cut-out hides; exit fullscreen → cut-out returns
- [ ] Open rofi → cut-out hides; close rofi → cut-out returns
- [ ] Close the focused window → cut-out repositions to sway's newly focused window (no orphaned cut-out at the closed window's old position)
- [ ] No console errors in `pkill -x quickshell; quickshell 2>&1 | tee /tmp/qs.log` during 30 s of normal use

**Step 4: Commit**

```bash
git add quickshell/config/FocusDimWayland.qml
git commit -m "feat(quickshell): track focused window via sway IPC in dim overlay"
```

---

## Task 8: Dispatcher — gate X11 path on proot detection + spawn helper

Extend `FocusDim.qml` to spawn `qs-focus-dim.py` on X11/i3 (skip on proot, identical to `FocusBorder.qml`).

**Files:**
- Modify: `quickshell/config/FocusDim.qml`

**Step 1: Replace contents**

```qml
import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: root
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null
    property bool isProot: false

    Process {
        id: probeProc
        running: true
        command: ["sh", "-c", "[ -d /data/data/com.termux ] && echo proot || echo native"]
        stdout: SplitParser { onRead: data => root.isProot = (data.trim() === "proot") }
        onExited: { if (!root.isSway && !root.isProot) dimProc.running = true }
    }

    Process {
        id: dimProc
        running: false
        command: ["sh", "-c", "exec python3 -u $HOME/.dotfiles/quickshell/qs-focus-dim.py"]
        onExited: restartTimer.restart()
    }
    Timer { id: restartTimer; interval: 2000; onTriggered: { if (!root.isSway && !root.isProot) dimProc.running = true } }

    Loader {
        active: isSway
        source: "FocusDimWayland.qml"
    }
}
```

**Step 2: Restart quickshell on i3 and verify dim spawns**

```bash
pkill -x quickshell; sleep 1; $HOME/.dotfiles/quickshell/qs-start.sh &
pgrep -af qs-focus-dim.py
```

**Success criteria (must all pass):**
- [ ] On X11/i3 native: exactly one `qs-focus-dim.py` process running (`pgrep -af qs-focus-dim.py | wc -l` = 1); dim visible; tracks focus
- [ ] On proot/Termux: **zero** `qs-focus-dim.py` processes (`probeProc` detects proot and gates spawn); no overlay rendered
- [ ] On Wayland/sway: zero `qs-focus-dim.py` processes (Wayland branch via `Loader`); dim still visible via QML overlay
- [ ] Kill the dim helper manually (`pkill -f qs-focus-dim.py`) → `restartTimer` respawns it within 2 s; only one process after respawn
- [ ] No leaked `restartTimer` if the helper exits cleanly (Quickshell `Process.onExited` fires exactly once per exit)

**Step 3: Commit**

```bash
git add quickshell/config/FocusDim.qml
git commit -m "feat(quickshell): dispatcher spawns dim helper on X11"
```

---

## Task 9: End-to-end verification matrix

No code changes. Walk through every platform actually available on this host and tick the table. File a follow-up note for any failure (no in-band fixes — that's a separate bug fix loop).

**Files:** none (notes only, if failures found)

**Step 1: Restart quickshell**

```bash
pkill -x quickshell; sleep 1; $HOME/.dotfiles/quickshell/qs-start.sh &
```

**Step 2: Verify the matrix**

Fill each cell with `✓` (passes), `✗` (fails, file follow-up bd issue), or `~` (host doesn't have this platform — leave verification to whoever does).

| Platform | Border + dim both on focus change | Hide on fullscreen | Hide on rofi | Multi-monitor: dim on non-focused monitors | Click-through | Bar stays bright |
|---|---|---|---|---|---|---|
| X11 / native i3 | ~ | ~ | ~ | ~ | ~ | ~ |
| Wayland / WSL sway | ~ | ~ | ~ | ~ | ~ | ~ |
| proot / Termux i3 | n/a (skipped) | n/a | n/a | n/a | n/a | n/a |

For any cell marked `✗`: append a "Known issues" section to this spec with the failure description **and** file a follow-up bd task (`bd create --title "focus-dim: <failure>" --type bug --priority 2`). Do not patch the failure in this same epic.

**Verification status as of T9 closure:** all behavioral cells deferred to user (agent has no interactive display). Mechanical checks (file existence, syntax, mount order, anti-pattern absence) all pass — see bd notes for evidence.

**Step 3: Commit verification notes (only if anything failed)**

```bash
git add board/spec/focus-dim.md
git commit -m "docs(focus-dim): record verification notes"
```

---

## Out of Scope (deferred)

- Keybind toggle (always-on with border)
- Idle/timeout trigger
- Per-app override list
- Animated fade
- Configurable opacity (hardcoded at 30%)
- Automated/headless tests for the overlay (no test harness for quickshell)
