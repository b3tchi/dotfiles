# Focus Dim Overlay

Dim the rest of the screen outside the focused window frame. Sibling to the existing focus border.

## Goal

Highlight the focused window by darkening everything outside it at ~30% black, mirroring the lifecycle of the existing focus border across X11/i3 and Wayland/sway.

## Success Criteria

- 30% black dim covers screen area outside the focused window's rect
- Bar and quickshell overlays stay at full brightness (dim sits below them)
- Click-through (no input capture)
- Hides on fullscreen, ignored classes (quickshell, Rofi), and when no focused window
- Updates on focus/move/resize/workspace/binding events with no visible lag
- Multi-monitor: cut-out only on monitor containing focused window; other monitors fully dimmed
- Works on X11/i3 (native + proot) and Wayland/sway (WSL)

## Architecture

Sibling component to `FocusBorder.qml`. New `FocusDim.qml` in `quickshell/config/` dispatches platform-specific implementation the same way:

- **X11/i3 (native + proot):** Python GTK3 cairo overlay — `qs-focus-dim.py`
- **Wayland/sway (WSL):** pure QML layer-shell — `FocusDimWayland.qml`

Mounted from `shell.qml` alongside `FocusBorder`.

## X11 Path (`qs-focus-dim.py`)

Single fullscreen GTK popup window per monitor. RGBA visual, app-paintable, click-through via empty input shape region. Cairo draw paints 4 rectangles outside the focused window:

```
top:    (0,     0,     screen_w,      y)
bottom: (0,     y+h,   screen_w,      screen_h-(y+h))
left:   (0,     y,     x,             h)
right:  (x+w,   y,     screen_w-(x+w), h)
color:  rgba(0, 0, 0, 0.3)
```

Reuses i3 IPC subscribe + tree walk from `qs-focus-border.py`. Both components consume the same focus/move/resize/workspace/binding events.

Single-instance lock at `$XDG_RUNTIME_DIR/qs-focus-dim.lock`. Same `IGNORE_CLASSES` set as the border (quickshell, Rofi). Hide on fullscreen.

## Wayland Path (`FocusDimWayland.qml`)

`PanelWindow` per screen, layer=`top` (below bar at `overlay`). Anchored full-screen. 4 `Rectangle` children positioned around focused window rect. `color: "#4D000000"` (30% black). Subscribes to sway IPC `window` / `workspace` events, mirroring `FocusBorderWayland.qml`.

## Z-Order

Dim sits below quickshell bar/overlays, above normal windows.

- **X11:** GTK `WindowTypeHint.NOTIFICATION` + `set_keep_above(True)`. Bar uses dock/strut and stacks higher.
- **Wayland:** dim at layer=`top`; bar/overlays stay at layer=`overlay`.

## Lifecycle

Mirror `qs-focus-border.py`:

- Show on focus / move / floating / binding events
- Hide on close / fullscreen
- Hide on ignored classes
- Hide when no focused window
- Multi-monitor: only the monitor containing the focused window draws the cut-out; others draw a full-screen dim

## Files

```
quickshell/
  config/
    FocusDim.qml          (new)
    FocusDimWayland.qml   (new)
    shell.qml             (modified: mount FocusDim {})
  qs-focus-dim.py         (new)
```

## Out of Scope

- No keybind toggle (always-on with focus border)
- No idle trigger
- No per-app override
- No animated fade
- No configurable opacity (hardcoded 30% — revisit later if needed)
