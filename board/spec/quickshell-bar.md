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
| Label colors (CPU:, RAM:, etc.) | `#16a085` green | **BROKEN** | No |
| Value colors | `#FDF6E3` white | All same color | No |
| Separator | `"  "` in `#707880` | `"  "` | Yes |
| Date format | `HH:MM YYYY-MM-DD` | `HH:mm yyyy-MM-dd` | Yes |

## Blocking Issue: Text.color Broken on X11

### Symptom

All `Text` items in a `PanelWindow` render with the SAME color — the first
Text item's color propagates to every other Text in the window.

### Confirmed Behavior

- `Rectangle.color` works independently per element (underlines show correct colors)
- `Text.color` does NOT work independently — all text in a window shares one color
- Happens with both `Row` and `RowLayout` containers
- Happens with both inline and component-loaded (`Variants`) PanelWindows
- Happens with both `font.pixelSize` and `font.pointSize`
- Happens with both static text and dynamic property bindings
- Happens with named colors ("red") and hex colors ("#16a085")

### What Works

A single `PanelWindow` with ONLY `Row` + `Text` children (no Process, no Timer,
no other objects) initially appeared to show different colors, but subsequent tests
showed the same single-color behavior. This needs more investigation.

### Root Cause Hypothesis

Quickshell's X11 panel rendering uses a single foreground color for all text
in the window. On Wayland (layershell), each text element may get independent
color rendering. This would explain why the phone (Wayland) had working colors.

### Potential Workarounds (Not Yet Tested)

1. **Render text as colored rectangles** — draw text via `Canvas` element
2. **Multiple overlapping PanelWindows** — one per color region
3. **Use `Image` with pre-rendered text**
4. **File a Quickshell bug** — this may be a regression or X11 backend limitation
5. **Use `QtQuick.Controls.Label`** instead of `QtQuick.Text`
6. **Set `layer.enabled: true`** on individual Text items
7. **Investigate `Quickshell.Widgets`** for alternative text rendering

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

## Next Steps

1. **Solve text color issue** — try workarounds listed above
2. **Restore shell.qml** — currently in test state, needs to be restored to Variants + Bar
3. **Commit current state** — Bar.qml has all features except working colors
4. **Phone config** — once X11 colors solved, test on Wayland (phone)
5. **Add to meta packages** — after both devices confirmed working
6. **IPC launcher** — the sxmo sway config uses `qs ipc call launcher toggle` for rofi replacement
