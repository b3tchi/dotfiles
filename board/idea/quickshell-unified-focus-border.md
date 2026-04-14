# Unified QML Focus Border (Replace Python/GTK)

## Goal

Use the QML layer-shell focus border (FocusBorderWayland.qml) on both X11/i3 and Wayland/sway, eliminating the python/GTK dependency.

## Motivation

Currently two separate implementations:
- **Wayland/sway**: QML PanelWindow overlay (FocusBorderWayland.qml)
- **X11/i3**: Python GTK3/cairo overlay (qs-focus-border.py)

The QML version should work on X11 too — PanelWindow falls back to X11 window hints. This would drop: `qs-focus-border.py`, `python-cairo`, `python-gobject`, `libwnck3`, `gtk3` from dependencies.

## Changes

1. Make FocusBorderWayland.qml use `wmMsg` property instead of hardcoded `swaymsg`
2. Rename to `FocusBorderQml.qml` (platform-agnostic)
3. Update `FocusBorder.qml` to use QML version on both platforms
4. Remove python path from `FocusBorder.qml`
5. Update `quickshell/dot.yaml` — drop python/GTK packages (keep for qs-keymon.py if still needed on X11)
6. Test on both i3/X11 and sway/Wayland

## Risk

- PanelWindow on X11 may behave differently (click-through, stacking order)
- Need to verify `aboveWindows` and empty `Region` mask work on X11
- qs-keymon.py still needs python-xlib on X11 (separate concern)
