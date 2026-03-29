# Quickshell Run Launcher — Rofi Replacement

## Goal

Replace rofi's `run` mode with a native quickshell PopupWindow launcher that matches the existing bar's visual style and integrates into the same process.

## Decision Log

- **Scope:** Run launcher only (no window switcher or custom modes yet)
- **Layout:** Centered overlay, 480px wide, 8 visible rows
- **Data source:** Scan $PATH directories for executables
- **Dismiss:** Escape key + click outside
- **Approach:** PopupWindow anchored to Bar (shared process, instant show)

## Architecture

### Components

```
shell.qml
├── Bar.qml (existing)
└── RunLauncher.qml (new)
    ├── PopupWindow (centered overlay, focus grab)
    │   ├── TextField (search input, auto-focused)
    │   ├── ListView (filtered results, 8 visible rows)
    │   └── Keys handler (Escape, Up/Down, Enter)
    └── Process (scans $PATH for executables on startup)
```

### Triggering

i3 keybind sends a message to a Unix socket served by quickshell:

- `shell.qml` hosts a `SocketServer` on `/tmp/quickshell-launcher.sock`
- i3 config: `bindsym $mod+d exec echo toggle | socat - UNIX-CONNECT:/tmp/quickshell-launcher.sock`
- On receiving "toggle", shell.qml sets `RunLauncher.visible = !RunLauncher.visible`

### Data Flow

1. **Startup:** Process runs `find` across $PATH dirs → populates JS array of executable names
2. **User types:** TextField.onTextChanged filters array with substring match
3. **Navigation:** Up/Down moves ListView.currentIndex, Enter launches selected item
4. **Launch:** Process spawns `sh -c <selected>`, popup hides, input clears
5. **Dismiss:** Escape or click-outside hides popup, clears input

## Visual Design

Matches existing rofi theme and quickshell bar:

| Element | Color |
|---------|-------|
| Background | `#222D31` |
| Input bar bg | `#152024` |
| Text | `#FDF6E3` |
| Selected item bg | `#152024` |
| Selected left border | `#16a085` (4px) |
| Match highlight | bold `#16a085` |
| Font | Iosevka Nerd Font, 14px |

Dimensions: 480px wide, input bar + 8 rows (~27px each = ~240px total height).

## Success Criteria

1. `$mod+d` opens the launcher centered on screen within 50ms (no process spawn)
2. Typing filters executables in real-time
3. Enter launches the selected executable
4. Escape and click-outside dismiss the launcher
5. Visual style matches existing rofi theme exactly
6. Works on X11 (i3) — the primary platform

## Future Extensions (not in scope)

- Window switcher mode (`$mod+Tab`)
- Frecency tracking / history
- Desktop application entries (`.desktop` files)
- Custom modes (project picker, etc.)
