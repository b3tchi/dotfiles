# Quickshell Sway Compatibility

## Goal

Extend quickshell (bar, overlay, notifications) to work on sway/WSL while keeping full i3/X11 compatibility.

## Context

Quickshell currently works on i3/X11 (native Linux, proot). Sway (used on WSL) runs waybar + rofi instead. Since Quickshell.I3 module natively supports sway's i3-compatible IPC, the gap is smaller than expected — mostly hardcoded `i3-msg` calls and X11 assumptions.

## Design Decisions

### WM Command Abstraction (Runtime Detection)

Detect WM at QML startup via `$SWAYSOCK` environment variable:

```qml
readonly property bool isSway: Qt.getenv("SWAYSOCK") !== ""
readonly property string wmMsg: isSway ? "swaymsg" : "i3-msg"
```

- All `i3-msg` calls become `root.wmMsg`
- Drop `i3 --get-socketpath` — both tools find their socket automatically
- `Quickshell.I3` module stays as-is (works with sway natively)

Applies to: Bar.qml, overlay/shell.qml

### Window Class Extraction

Sway uses `app_id` for Wayland-native apps, `window_properties.class` for Xwayland only. Fix overlay switcher to try both:

```qml
cls: node.app_id || (node.window_properties || {})["class"] || ""
```

### Bar Style (Phone vs Desktop)

Replace `isWayland` heuristic with explicit `QS_PHONE` env var:

```qml
readonly property bool isPhone: Qt.getenv("QS_PHONE") === "1"
margins {
    bottom: isPhone ? 20 : 0
    left:   isPhone ? 40 : 0
    right:  isPhone ? 40 : 0
}
```

- Full-width bar everywhere by default (i3, sway/WSL)
- Future sxmo/phone sets `QS_PHONE=1` before launching quickshell
- `isWayland` property removed entirely

### Sway Config Wiring

In `sway/config.d/default`:

- Remove `exec waybar`
- Replace `set $menu rofi -show run` with quickshell IPC launcher
- Add quickshell process launches:
  ```
  exec quickshell -c ~/.config/quickshell
  exec quickshell -c ~/.config/quickshell-overlay
  ```
- Add IPC keybindings (launcher toggle, switcher, projects)
- Add `for_window [app_id="quickshell"] floating enable, border none`
- Remove rofi-based project-picker bindings (overlay replaces them)

i3 config unchanged.

### Overlay Windows

Use sway `for_window` rules for overlay positioning (app_id matching). No QML window type changes needed — `ApplicationWindow` with X11 hints works under Xwayland, and sway rules handle the rest.

Future option: migrate to Quickshell native `FloatingWindow` if issues arise.

### Rotz Integration

- **meta-wsl/dot.yaml**: Add `quickshell` to depends
- **sway/dot.yaml**: Remove waybar links and packages
- **quickshell/dot.yaml**: Ensure overlay config linked to `~/.config/quickshell-overlay`

## What Doesn't Change

- i3 config (untouched)
- Quickshell.I3 module import (works on both WMs)
- Notification system (already WM-agnostic)
- Existing X11/i3 behavior

## Success Criteria

1. Quickshell bar + overlay works on sway/WSL with full-width bar
2. i3/X11 setups (native Linux, proot) continue working unchanged
3. Future phone/sxmo can enable floating pill via `QS_PHONE=1`
