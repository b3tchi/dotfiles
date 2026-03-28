# Quickshell Bar — Status & Spec

## Goal

Replace polybar (desktop/i3) and waybar (phone/sway) with a single quickshell config
that adapts per device via `Qt.platform.pluginName` detection.

## Devices

| Device | Display | WM | Bar Position | Status |
|---|---|---|---|---|
| proot Arch ARM (Android) | X11 via Termux:X11 | i3 | bottom, full-width | In progress |
| Nothing Phone 1 (pmOS) | Wayland | sway | bottom, floating pill | Not started |

## Current State

### Installed & Working

- `quickshell 0.2.1` from `extra` repo on Arch ARM aarch64
- Dotfiles structure: `quickshell/dot.yaml` + `quickshell/config/{shell.qml, Bar.qml}`
- Rotz link: `quickshell/config` → `~/.config/quickshell`
- Not yet added to any `meta-*` package (user requested waiting)

### Bar Features Implemented

| Feature | Status | Implementation |
|---|---|---|
| i3/sway workspaces | Working | `Quickshell.I3` singleton, `I3.workspaces` |
| Workspace click-to-switch | Working | `I3.dispatch("workspace " + name)` |
| Focused workspace highlight | Working | bg `#152024` + green underline `#16a085` |
| Urgent workspace | Working | bg `#cb4b16` |
| Visible workspace (other monitor) | Working | secondary underline `#454948` |
| Mode indicator (resize, etc.) | Working | `i3-msg -t subscribe -m '["mode"]'` via Process |
| CPU % | Working | Poll `/proc/stat` every 3s |
| RAM % | Working | Poll `/proc/meminfo` every 5s |
| Disk % | Working | Poll `df /` every 30s |
| Volume % | Working | Poll `pactl` every 5s (hidden if unavailable) |
| Network | Working | `iwgetid -r` or `ip -brief addr`, every 10s |
| Clock | Working | `HH:mm` muted + `yyyy-MM-dd` white, 1s interval |
| Wayland/X11 detection | Working | `Qt.platform.pluginName.startsWith("wayland")` |
| Floating margins (phone) | Coded | margins bottom/left/right when Wayland |
| Mode hints overlay | Working | Full-bar key hint display on resize/system mode |
| Clock seconds toggle | Working | Click time to toggle HH:mm ↔ HH:mm:ss |
| Notification count | Working | dunstctl polling (interim, replacing with native) |
| Text color (X11) | Fixed | renderType: Text.NativeRendering on all Text |

### Styling (Polybar Parity)

Target: match polybar config at `~/.config/polybar/config.ini`

| Property | Polybar | Quickshell | Match? |
|---|---|---|---|
| Position | bottom | bottom | Yes |
| Height | 20pt (~27px) | 27px | Yes |
| Background | `#222D31` | `#222D31` | Yes |
| Font | Iosevka 11pt | Iosevka 14px | Close |
| Workspace bg (focused) | `#152024` | `#152024` | Yes |
| Workspace underline (focused) | `#16a085` 3px | `#16a085` 3px | Yes |
| Workspace underline (visible) | `#454948` | `#454948` | Yes |
| Urgent bg | `#CB4B16` | `#CB4B16` | Yes |
| Mode underline | `#CB4B16` | `#CB4B16` | Yes |
| Label colors (CPU:, RAM:, etc.) | `#16a085` green | `#16a085` green | Yes |
| Value colors | `#FDF6E3` white | `#FDF6E3` white | Yes |
| Separator | `"  "` in `#707880` | `"  "` | Yes |
| Date format | `HH:MM YYYY-MM-DD` | `HH:mm yyyy-MM-dd` | Yes |

## Resolved: Text.color on X11

**Fix:** `renderType: Text.NativeRendering` on all Text elements. The default
Qt Quick scene graph renderer shares a single foreground color for all text
in an X11 PanelWindow. NativeRendering bypasses this by using X11-native text
rendering, which respects per-element color. Label (QtQuick.Controls) did NOT
fix it — only renderType works.

## Color Reference (Shared Across All UI)

| Name | Hex | Usage |
|---|---|---|
| background | `#222D31` | Bar bg, bemenu bg |
| background-alt | `#152024` | Focused workspace, mode indicator |
| foreground | `#FDF6E3` | Primary text |
| primary | `#16a085` | Accent: labels, underlines |
| secondary | `#454948` | Visible workspace underline |
| alert | `#CB4B16` | Urgent, mode underline |
| disabled | `#707880` | Muted text, clock time |

## Phone (pmOS) Styling Target

From `nothing-pmos` repo waybar config:

- Position: bottom, floating (margins: 20px bottom, 40px sides)
- Height: 35px
- Background: `rgba(34, 45, 49, 0.9)` semi-transparent
- Border radius: 20px (pill shape)
- Modules: workspaces, mode | volume, network, battery, clock
- Labels: `VOL:`, `NET:`, `BAT:`, `CHR:`, `CHD:` in `#16a085`
- Font: Iosevka Nerd Font 14pt

## Files

```
quickshell/
├── dot.yaml                    # rotz config (link + install)
└── config/
    ├── shell.qml               # ShellRoot entry point (currently test state)
    └── Bar.qml                 # Full bar component (Row-based layout)
```

## Key Technical Decisions

1. **I3 singleton** — `I3` is a QML singleton, not instantiatable. Use `I3.workspaces`, `I3.dispatch()` directly.
2. **Mode tracking** — `i3-msg -t subscribe -m '["mode"]'` via long-running Process. The I3 singleton's `rawEvent` does NOT fire for mode events.
3. **System stats** — Process + SplitParser + Timer chain. Process runs, stdout parsed, onExited restarts Timer, Timer restarts Process.
4. **Row not RowLayout** — RowLayout propagates Text.color across all children. Use `Row` or `Item` with anchored children.
5. **Restart delay** — Need delay between `killall quickshell` and next `quickshell` launch (X11 cleanup).

## Notification System (Replaces Dunst)

### Goal

Replace dunst with QuickShell's native `Quickshell.Services.Notifications` module.
Single notification daemon for both X11 (proot) and Wayland (pmOS phone).

### Module: `Quickshell.Services.Notifications`

| Type | Purpose |
|---|---|
| `NotificationServer` | D-Bus notification daemon (replaces dunst) |
| `Notification` | Individual notification object |
| `NotificationAction` | Action buttons on notifications |
| `NotificationUrgency` | low / normal / critical |
| `NotificationCloseReason` | dismissed / expired / closed / undefined |

### Architecture

```
NotificationServer (singleton in shell.qml)
  → trackedNotifications list (live-updating)
  → Bar: bind count for indicator
  → NotificationPopup: overlay PanelWindow for popups
```

### Bar Integration

- Replace `dunstctl` Process+Timer with `NotificationServer.trackedNotifications.length`
- `NOT:` label shows count when > 0 (same as current, but native binding)
- Click `NOT:` to toggle dunst-style pause (DND mode)

### Popup Requirements

| Property | Value | Notes |
|---|---|---|
| Position | top-right | Standard notification position |
| Max visible | 5 | Stack vertically, newest on top |
| Auto-dismiss | 5s normal, 10s critical | `expireTimeout` from notification or default |
| Styling | Match bar colors | bg `#222D31`, text `#FDF6E3`, accent `#16a085` |
| Urgency colors | normal: `#16a085`, critical: `#CB4B16` | Left border or accent |
| Click | Dismiss | Close notification on click |
| Actions | Show as text buttons | If notification has actions |
| Width | 300px | Fixed width, variable height |
| Font | Iosevka Nerd Font 12px | Slightly smaller than bar |

### Files

```
quickshell/config/
├── shell.qml               # ShellRoot: add NotificationServer singleton
├── Bar.qml                 # Bar: native notification count
└── NotificationPopup.qml   # New: popup overlay window
```

### Implementation Steps

1. Create `NotificationPopup.qml` — popup overlay with notification stack
2. Add `NotificationServer` to `shell.qml` — singleton, expose to Bar and Popup
3. Replace dunstctl polling in Bar.qml with native `trackedNotifications.length`
4. Stop dunst service, test with `notify-send`
5. Add DND toggle (click notification count in bar)

### Prerequisite

Stop dunst before running quickshell with NotificationServer — only one daemon
can own `org.freedesktop.Notifications` on D-Bus at a time.

## Next Steps

1. ~~Solve text color issue~~ — Fixed: `renderType: Text.NativeRendering`
2. **Notification system** — replace dunst with native quickshell notifications
3. **Phone config** — test on Wayland (pmOS), add battery module
4. **Add to meta packages** — after both devices confirmed working
5. **IPC launcher** — `qs ipc call launcher toggle` for rofi replacement
