# QuickShell Notification System Implementation Plan

> **For Claude:** Use infinifu:plan-executing, infinifu:plan-subagent, or infinifu:plan-scrum-master to implement this plan.

**Goal:** Replace dunst with QuickShell's native `Quickshell.Services.Notifications` module — popup display + bar count indicator.

**Architecture:** NotificationServer lives in shell.qml as a singleton owning the D-Bus `org.freedesktop.Notifications` service. It tracks incoming notifications and exposes them to two consumers: Bar.qml (count indicator) and NotificationPopup.qml (visual popup stack). The server sets `notification.tracked = true` on arrival, starts auto-dismiss timers, and removes notifications on click or timeout.

**Tech Stack:** QML, Quickshell 0.2.1, Quickshell.Services.Notifications module

---

### Task 1: Create NotificationPopup.qml

The popup overlay window. Renders a vertical stack of notifications in the top-right corner.

**Files:**
- Create: `quickshell/config/NotificationPopup.qml`

**Done when:** File exists, quickshell loads without errors (even if no notifications are shown yet — the server isn't wired up until Task 2).

**Step 1: Write the popup component**

```qml
import Quickshell
import Quickshell.Services.Notifications
import QtQuick

PanelWindow {
    id: popup

    // Required: notification server instance from shell.qml
    required property NotificationServer server

    anchors {
        top: true
        right: true
    }

    // Offset from screen edge (matches dunst: origin top-right, offset 20x60)
    margins {
        top: 60
        right: 20
    }

    // Size: fixed width, dynamic height based on notification count
    implicitWidth: 300
    implicitHeight: notifColumn.implicitHeight

    // Transparent background — each notification draws its own bg
    color: "transparent"

    // Hide when no notifications
    visible: server.trackedNotifications.count > 0

    readonly property bool isWayland: Qt.platform.pluginName.startsWith("wayland")
    readonly property int cornerRadius: isWayland ? 8 : 0
    readonly property string fontFamily: "Iosevka Nerd Font"
    readonly property int nativeRender: Text.NativeRendering

    Column {
        id: notifColumn
        anchors { left: parent.left; right: parent.right }
        spacing: 4

        Repeater {
            // Show max 5, newest first (last in model = newest)
            model: server.trackedNotifications

            Rectangle {
                id: notifRect
                required property var modelData
                required property int index

                width: notifColumn.width
                height: notifContent.implicitHeight + 16
                radius: popup.cornerRadius

                color: modelData.urgency === NotificationUrgency.Critical ? "#152024"
                     : "#222D31"

                Column {
                    id: notifContent
                    anchors {
                        left: parent.left; right: parent.right
                        top: parent.top
                        margins: 8
                    }
                    spacing: 2

                    // App name + summary on one line
                    Text {
                        width: parent.width
                        text: modelData.summary
                        color: modelData.urgency === NotificationUrgency.Critical ? "#CB4B16"
                             : modelData.urgency === NotificationUrgency.Low ? "#707880"
                             : "#FDF6E3"
                        font.family: popup.fontFamily
                        font.pixelSize: 14
                        font.bold: true
                        elide: Text.ElideRight
                        renderType: popup.nativeRender
                    }

                    // Body text
                    Text {
                        visible: modelData.body !== ""
                        width: parent.width
                        text: modelData.body
                        color: modelData.urgency === NotificationUrgency.Critical ? "#CB4B16"
                             : modelData.urgency === NotificationUrgency.Low ? "#707880"
                             : "#FDF6E3"
                        font.family: popup.fontFamily
                        font.pixelSize: 11
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        renderType: popup.nativeRender
                    }

                    // App name (subtle)
                    Text {
                        visible: modelData.appName !== ""
                        text: modelData.appName
                        color: "#707880"
                        font.family: popup.fontFamily
                        font.pixelSize: 10
                        renderType: popup.nativeRender
                    }
                }

                // Click to dismiss
                MouseArea {
                    anchors.fill: parent
                    onClicked: modelData.dismiss()
                }

                // Auto-dismiss timer (critical: no auto-dismiss)
                Timer {
                    running: modelData.urgency !== NotificationUrgency.Critical
                    interval: 10000
                    onTriggered: modelData.expire()
                }
            }
        }
    }
}
```

**Key decisions:**
- `visible` bound to `trackedNotifications.count > 0` — PanelWindow hides when empty
- `modelData.dismiss()` sends "user dismissed" to the sending app
- `modelData.expire()` sends "timed out" to the sending app
- Auto-dismiss Timer per notification: 10s for low/normal, none for critical
- `implicitHeight` tracks column height — window resizes dynamically
- `renderType: Text.NativeRendering` on all Text (required for X11 color fix)

**Step 2: Verify file is valid QML**

Run: `killall quickshell 2>/dev/null; sleep 1; quickshell &`
Expected: quickshell starts without errors (popup won't show yet — not wired in shell.qml)

**Step 3: Commit**

```bash
git add quickshell/config/NotificationPopup.qml
git commit -m "feat(quickshell): add NotificationPopup component"
```

---

### Task 2: Wire NotificationServer in shell.qml

Add the NotificationServer singleton and connect it to both Bar and NotificationPopup.

**Files:**
- Modify: `quickshell/config/shell.qml`

**Current content of shell.qml:**
```qml
import Quickshell

ShellRoot {
    Variants {
        model: Quickshell.screens
        Bar {
            required property var modelData
            screen: modelData
        }
    }
}
```

**Step 1: Rewrite shell.qml with NotificationServer**

```qml
import Quickshell
import Quickshell.Services.Notifications

ShellRoot {
    NotificationServer {
        id: notifServer
        keepOnReload: true
        bodyMarkupSupported: true
        imageSupported: false
        actionsSupported: false
        persistenceSupported: false

        onNotification: notification => {
            notification.tracked = true
        }
    }

    Variants {
        model: Quickshell.screens
        Bar {
            required property var modelData
            screen: modelData
            notifServer: notifServer
        }
    }

    NotificationPopup {
        server: notifServer
    }
}
```

**Key decisions:**
- `onNotification: notification.tracked = true` — all notifications are tracked (displayed)
- `keepOnReload: true` — notifications survive quickshell reload
- `imageSupported: false` — keeping it simple, no image rendering
- `actionsSupported: false` — out of scope per design
- Bar receives `notifServer` as a property to read count
- Single NotificationPopup instance (not per-screen — notifications go to primary)

**Step 2: Verify quickshell loads**

Run: `killall quickshell 2>/dev/null; sleep 1; quickshell &`
Expected: quickshell starts. Bar may error because it doesn't have `notifServer` property yet — that's fixed in Task 3.

**Step 3: Commit**

```bash
git add quickshell/config/shell.qml
git commit -m "feat(quickshell): add NotificationServer to shell.qml"
```

---

### Task 3: Update Bar.qml to use native notification count

Replace the dunstctl Process+Timer polling with a direct binding to the NotificationServer.

**Files:**
- Modify: `quickshell/config/Bar.qml`

**Step 1: Add notifServer property**

At the top of PanelWindow (after `id: root`), add:

```qml
    // Notification server passed from shell.qml
    required property NotificationServer notifServer
```

Add the import at the top of the file:

```qml
import Quickshell.Services.Notifications
```

**Step 2: Remove dunstctl polling**

Delete these lines from Bar.qml:

- `property string notifVal: "0"` (line 80)
- The `notifProc` Process block (lines 131-137)
- The `notifTimer` Timer (line 138)

**Step 3: Update notification display in the right-side stats**

Replace the notification section (lines 286-289) that references `notifVal` with:

```qml
            // Notifications
            Text { visible: root.notifServer.trackedNotifications.count > 0; text: "  "; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.notifServer.trackedNotifications.count > 0; text: "NOT:"; color: "#cb4b16"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.notifServer.trackedNotifications.count > 0; text: "" + root.notifServer.trackedNotifications.count; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
```

**Step 4: Verify everything works together**

Run: `killall dunst 2>/dev/null; killall quickshell 2>/dev/null; sleep 1; quickshell &`
Then: `notify-send "Test" "Hello from quickshell"`
Expected:
- Popup appears top-right with "Test" summary and "Hello from quickshell" body
- Bar shows `NOT:1`
- Click popup to dismiss — both popup and bar count update
- After 10s, notification auto-dismisses if not clicked

**Step 5: Commit**

```bash
git add quickshell/config/Bar.qml
git commit -m "feat(quickshell): replace dunstctl polling with native notification count"
```

---

### Task 4: Test all urgency levels

Verify the three urgency levels render correctly.

**Files:** None (testing only)

**Step 1: Kill dunst and start quickshell**

```bash
killall dunst 2>/dev/null; killall quickshell 2>/dev/null; sleep 1; quickshell &
```

**Step 2: Send test notifications**

```bash
notify-send --urgency=low "Low Priority" "This should be muted gray"
notify-send --urgency=normal "Normal" "This should be white on dark"
notify-send --urgency=critical "Critical" "This should be orange on darker bg"
```

Expected:
- Low: `#707880` text on `#222D31` bg, auto-dismisses in 10s
- Normal: `#FDF6E3` text on `#222D31` bg, auto-dismisses in 10s
- Critical: `#CB4B16` text on `#152024` bg, stays until clicked
- Bar shows `NOT:3`, decreases as notifications dismiss
- Notifications stack vertically with 4px gap

**Step 3: Test dismiss behavior**

- Click each notification — should disappear immediately
- Bar count should decrement with each dismiss
- When all dismissed, bar `NOT:` label should hide

**Step 4: Commit test results to spec**

If any visual tweaks are needed, fix them and commit:

```bash
git add quickshell/config/
git commit -m "fix(quickshell): notification popup visual adjustments"
```

---

### Task 5: Update i3 config to stop dunst on quickshell start

Ensure dunst doesn't conflict with quickshell's notification server.

**Files:**
- Modify: `i3/config:80` — update the dunst restart keybinding

**Step 1: Update i3 config**

Change line 80 from:
```
bindsym $mod+Shift+d --release exec "killall dunst; exec notify-send 'restart dunst'"
```

To:
```
bindsym $mod+Shift+d --release exec "killall quickshell; sleep 1; quickshell &"
```

This repurposes the keybinding to restart quickshell (which owns notifications now).

**Step 2: Add exec_always to kill dunst on i3 reload**

Add after the existing exec lines (search for `exec --no-startup-id` section):

```
exec_always --no-startup-id killall dunst 2>/dev/null
```

**Step 3: Verify**

Reload i3 (`$mod+Shift+r`), then `notify-send "test"` — should go to quickshell, not dunst.

**Step 4: Commit**

```bash
git add i3/config
git commit -m "feat(i3): replace dunst with quickshell for notifications"
```

---

### Task 6: Update quickshell-bar spec

Update the spec to reflect completed notification work.

**Files:**
- Modify: `board/spec/quickshell-bar.md`

**Step 1: Update feature table**

Add/update in the features table:
- `Notification popup | Working | Native NotificationServer, replaces dunst`
- `Notification count (bar) | Working | Native binding, no polling`

Remove or mark as done:
- The dunstctl-based notification count entry

**Step 2: Update next steps**

Remove "Notification system" from next steps, add any discovered follow-up items.

**Step 3: Commit**

```bash
git add board/spec/quickshell-bar.md
git commit -m "chore: update quickshell-bar spec with notification system status"
```
