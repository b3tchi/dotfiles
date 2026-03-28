# QuickShell Notification System — Design

## Goal

Replace dunst with QuickShell's native `Quickshell.Services.Notifications` module.
Single notification daemon for X11 (proot) and Wayland (pmOS phone).

## Architecture

```
shell.qml
├── NotificationServer (singleton, owns D-Bus)
├── Variants → Bar (per screen)
│   └── reads server.trackedNotifications.length for count
└── NotificationPopup (single instance, top-right)
    └── reads server.trackedNotifications for popup stack
```

- NotificationServer lives in shell.qml as the D-Bus notification owner
- Bar gets native count binding (replaces dunstctl Process+Timer polling)
- NotificationPopup is its own PanelWindow rendering a vertical stack

## Popup Styling

| Property | X11 (proot) | Wayland (phone) |
|---|---|---|
| Position | top-right, 20px right, 60px top | top-right, 20px right, 60px top |
| Width | 300px | 300px |
| Corner radius | 0 (sharp) | 8px (rounded) |
| Max visible | 5 | 5 |
| Gap between | 4px | 4px |
| Font | Iosevka 11pt | Iosevka 11pt |

### Urgency Colors (matching dunst)

| Urgency | Background | Foreground |
|---|---|---|
| Low | `#222D31` | `#707880` |
| Normal | `#222D31` | `#FDF6E3` |
| Critical | `#152024` | `#CB4B16` |

### Timeouts

- Low/Normal: 10s auto-dismiss
- Critical: stays until clicked

### Interaction

- Click anywhere on notification to dismiss
- No action buttons (follow-up)

## Bar Integration

- Remove dunstctl Process + Timer + notifVal property
- Bind `notifCount` to `server.trackedNotifications.length`
- `NOT:` label in `#cb4b16` visible when count > 0
- Count displayed in `#fdf6e3`

## CLI History (follow-up)

Expose via QuickShell IPC: `qs ipc call notifications list`
Nushell wrapper: `qs ipc call notifications list | from json | table`

## Files

```
quickshell/config/
├── shell.qml                  # Add NotificationServer, expose to Bar + Popup
├── Bar.qml                    # Replace dunstctl with native count binding
└── NotificationPopup.qml      # New: popup overlay, top-right stack
```

## Prerequisite

Stop dunst before launching quickshell — only one daemon can own
`org.freedesktop.Notifications` on D-Bus. Add `killall dunst` to
quickshell startup or i3 exec.

## Out of Scope (follow-up)

- IPC endpoint for CLI history
- Actions/reply buttons
- DND mode toggle from bar
- Phone-specific width adaptation beyond corner radius
