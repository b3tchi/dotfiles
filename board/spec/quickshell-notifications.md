# QuickShell Notification System Implementation Plan

> **For Claude:** Use infinifu:plan-executing, infinifu:plan-subagent, or infinifu:plan-scrum-master to implement this plan.

**Goal:** Replace dunst with QuickShell's native `Quickshell.Services.Notifications` module — popup display + bar count indicator.

**Architecture:** NotificationServer lives in shell.qml as a singleton owning the D-Bus `org.freedesktop.Notifications` service. It tracks incoming notifications and exposes them to two consumers: Bar.qml (count indicator) and NotificationPopup.qml (visual popup stack). The server sets `notification.tracked = true` on arrival, starts auto-dismiss timers, and removes notifications on click or timeout. Max 5 visible popups — oldest auto-expire when limit exceeded.

**Tech Stack:** QML, Quickshell 0.2.1, Quickshell.Services.Notifications module

**Key API reference (Quickshell.Services.Notifications):**
- `NotificationServer.trackedNotifications` — `ObjectModel<Notification>` (readonly)
- `NotificationServer.onNotification: notification => {}` — signal on arrival; set `notification.tracked = true` to retain
- `Notification.summary`, `.body`, `.appName`, `.urgency`, `.expireTimeout`
- `Notification.dismiss()` — close with "user dismissed" reason
- `Notification.expire()` — close with "timed out" reason
- `NotificationUrgency.Low`, `.Normal`, `.Critical`
- `NotificationServer.keepOnReload` — survive quickshell reload
- `NotificationServer.bodyMarkupSupported`, `.imageSupported`, `.actionsSupported` — capability flags

---

### Task 1: Create NotificationPopup.qml

The popup overlay window. Renders a vertical stack of up to 5 notifications in the top-right corner.

**Files:**
- Create: `quickshell/config/NotificationPopup.qml`

**Done when:** File exists with valid QML syntax (won't render yet — wired in Task 2).

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
            model: server.trackedNotifications

            Rectangle {
                required property var modelData
                required property int index

                // Hide beyond 5th notification (oldest at index 0)
                visible: index >= (server.trackedNotifications.count - 5)

                width: notifColumn.width
                height: visible ? notifContent.implicitHeight + 16 : 0
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

                    // Summary (title)
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
- Max 5 visible: `visible: index >= (count - 5)` hides oldest when >5 tracked
- `modelData.dismiss()` sends "user dismissed" to the sending app via D-Bus
- `modelData.expire()` sends "timed out" to the sending app via D-Bus
- Auto-dismiss Timer per notification: 10s for low/normal, none for critical
- `implicitHeight` tracks column height — window resizes dynamically
- `renderType: Text.NativeRendering` on all Text (required for X11 color fix)
- No `id:` on Repeater delegate children (avoids collision across instances)

**Edge cases:**
- If >5 notifications arrive, only newest 5 are visible; older ones stay tracked (count in bar reflects all)
- When a notification is dismissed/expired, the Repeater model updates automatically
- Critical notifications never auto-expire — user must click to dismiss
- Empty body: body Text hidden via `visible: modelData.body !== ""`
- Empty appName: app name Text hidden similarly

**Step 2: Commit**

```bash
git add quickshell/config/NotificationPopup.qml
git commit -m "feat(quickshell): add NotificationPopup component"
```

---

### Task 2: Wire NotificationServer in shell.qml and update Bar.qml

Add NotificationServer singleton and update both consumers (Bar + Popup) in one step to avoid broken intermediate state.

**Files:**
- Modify: `quickshell/config/shell.qml`
- Modify: `quickshell/config/Bar.qml`

**Done when:** `killall dunst; killall quickshell; sleep 1; quickshell &` followed by `notify-send "Test" "body"` shows a popup top-right AND bar shows `NOT:1`.

**Step 1: Rewrite shell.qml**

Replace entire contents of `quickshell/config/shell.qml` with:

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
- `onNotification: notification.tracked = true` — all notifications are tracked
- `keepOnReload: true` — notifications survive quickshell reload
- `imageSupported: false`, `actionsSupported: false` — out of scope
- Bar receives `notifServer` as a property to read count
- Single NotificationPopup instance (not per-screen)

**Step 2: Update Bar.qml**

2a. Add import at top of file (after existing imports):

```qml
import Quickshell.Services.Notifications
```

2b. Add required property after `id: root` (line 8):

```qml
    required property NotificationServer notifServer
```

2c. Delete these lines:
- `property string notifVal: "0"` (line 80)
- The `notifProc` Process block (lines 131-137):
  ```qml
  Process {
      id: notifProc
      running: true
      command: ["dunstctl", "count", "waiting"]
      stdout: SplitParser { onRead: data => root.notifVal = data.trim() }
      onExited: notifTimer.restart()
  }
  ```
- The `notifTimer` Timer (line 138):
  ```qml
  Timer { id: notifTimer; interval: 3000; onTriggered: notifProc.running = true }
  ```

2d. Replace the notification display section (3 lines referencing `notifVal`) with:

```qml
            // Notifications
            Text { visible: root.notifServer.trackedNotifications.count > 0; text: "  "; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.notifServer.trackedNotifications.count > 0; text: "NOT:"; color: "#cb4b16"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.notifServer.trackedNotifications.count > 0; text: "" + root.notifServer.trackedNotifications.count; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
```

**Step 3: Verify**

```bash
killall dunst 2>/dev/null; killall quickshell 2>/dev/null; sleep 1; quickshell &
```

Wait 2 seconds for quickshell to start, then:

```bash
notify-send "Test" "Hello from quickshell"
```

Expected:
- Popup appears top-right: "Test" bold white, "Hello from quickshell" below, app name subtle
- Bar shows `NOT:1` in orange
- Click popup → it disappears, bar count hides
- If not clicked, auto-dismisses after 10s

**Step 4: Commit**

```bash
git add quickshell/config/shell.qml quickshell/config/Bar.qml
git commit -m "feat(quickshell): wire NotificationServer, replace dunstctl with native count"
```

---

### Task 3: Test all urgency levels and edge cases

Verify the three urgency levels render correctly and edge cases are handled.

**Files:** None (testing only, fix-and-commit if visual tweaks needed)

**Done when:** All urgency levels render with correct colors, dismiss works, auto-expire works, >5 notifications handled.

**Step 1: Kill dunst and start quickshell**

```bash
killall dunst 2>/dev/null; killall quickshell 2>/dev/null; sleep 1; quickshell &
```

**Step 2: Test urgency levels**

```bash
notify-send --urgency=low "Low Priority" "This should be muted gray (#707880)"
notify-send --urgency=normal "Normal" "This should be white (#FDF6E3) on dark (#222D31)"
notify-send --urgency=critical "Critical" "This should be orange (#CB4B16) on darker (#152024)"
```

Expected:
- Low: `#707880` text on `#222D31` bg, auto-dismisses in 10s
- Normal: `#FDF6E3` text on `#222D31` bg, auto-dismisses in 10s
- Critical: `#CB4B16` text on `#152024` bg, stays until clicked
- Bar shows `NOT:3`, decreases as notifications dismiss

**Step 3: Test dismiss behavior**

- Click each notification — should disappear immediately
- Bar count should decrement with each dismiss
- When all dismissed, bar `NOT:` label should hide

**Step 4: Test >5 notifications**

```bash
for i in $(seq 1 8); do notify-send "Test $i" "Notification body $i"; done
```

Expected:
- Only 5 newest visible in popup
- Bar shows `NOT:8`
- As notifications expire (10s), older ones become visible
- After all expire, bar count hides

**Step 5: Test edge cases**

```bash
# Empty body
notify-send "No Body"

# Long summary (should elide)
notify-send "This is a very long notification summary that should be truncated with ellipsis at the edge"

# Long body (should wrap, max 3 lines)
notify-send "Long Body" "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation."

# Empty summary
notify-send "" "Body only, no summary"
```

**Step 6: Fix and commit if needed**

```bash
git add quickshell/config/
git commit -m "fix(quickshell): notification popup visual adjustments"
```

---

### Task 4: Update i3 config for quickshell notifications

Ensure dunst doesn't conflict. Start quickshell on login. Repurpose dunst keybinding.

**Files:**
- Modify: `i3/config`

**Done when:** After i3 reload, `notify-send "test"` goes to quickshell not dunst. Quickshell starts on login.

**Step 1: Add quickshell startup**

Find the `exec --no-startup-id` section in `i3/config` and add:

```
exec --no-startup-id killall dunst 2>/dev/null; quickshell &
```

This runs once on login: kills dunst if running, starts quickshell.

**Step 2: Update dunst restart keybinding (line 80)**

Change:
```
bindsym $mod+Shift+d --release exec "killall dunst; exec notify-send 'restart dunst'"
```

To:
```
bindsym $mod+Shift+d --release exec "killall quickshell; sleep 1; exec quickshell"
```

This repurposes `$mod+Shift+d` to restart quickshell.

**Step 3: Verify**

Reload i3 (`$mod+Shift+r`), then:

```bash
notify-send "test" "should go to quickshell"
```

Expected: quickshell popup appears, not dunst.

**Step 4: Commit**

```bash
git add i3/config
git commit -m "feat(i3): start quickshell on login, replace dunst keybinding"
```

---

### Task 5: Update quickshell-bar spec

Update the main bar spec to reflect completed notification work.

**Files:**
- Modify: `board/spec/quickshell-bar.md`

**Done when:** Spec accurately reflects current state.

**Step 1: Update feature table**

Add to the features table:
```
| Notification popup | Working | Native NotificationServer, replaces dunst |
| Notification count (bar) | Working | Native binding to trackedNotifications.count |
```

Update existing entry:
```
| Notification count | Working | dunstctl polling (interim, replacing with native) |
```
Change to:
```
| Notification count (bar) | Working | Native binding, no polling |
```

**Step 2: Update next steps**

Remove "Notification system" from next steps. Add follow-ups if discovered during testing.

**Step 3: Commit**

```bash
git add board/spec/quickshell-bar.md
git commit -m "chore: update quickshell-bar spec with notification system status"
```
