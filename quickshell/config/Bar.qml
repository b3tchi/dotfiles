import Quickshell
import Quickshell.I3
import Quickshell.Io
import Quickshell.Services.SystemTray
import QtQuick
import QtQuick.Layouts

PanelWindow {
    id: root

    property int notifCount: 0
    property string notifText: ""
    property int notifSeq: 0
    property bool hasCritical: false
    signal dismissNotif()

    // Ticker state
    property bool tickerActive: false

    onNotifSeqChanged: {
        if (notifText !== "") {
            tickerAnim.stop()
            tickerText.x = tickerArea.width > 0 ? tickerArea.width : 500
            tickerActive = true
            tickerAnim.restart()
        }
    }

    // Both polybar and waybar use bottom position
    anchors {
        left: true
        right: true
        bottom: true
    }

    implicitHeight: 27

    // Phone (Wayland): floating with margins; desktop (X11): full-width
    readonly property bool isWayland: Qt.platform.pluginName.startsWith("wayland")
    margins {
        bottom: isWayland ? 20 : 0
        left:   isWayland ? 40 : 0
        right:  isWayland ? 40 : 0
    }

    color: currentMode !== "default" ? "#152024" : "#222d31"

    readonly property string fontFamily: "Iosevka Nerd Font"
    readonly property int fontSize: 16
    readonly property int nativeRender: Text.NativeRendering

    // Workspaces sorted: numbered first (by number), then named (alphabetical)
    // I3.workspaces is an ObjectModel; .values gives a JS array snapshot.
    // Bind on .count so the property re-evaluates when workspaces change.
    // Workspaces in display order from i3 IPC (matches ws-switch.nu)
    // I3.workspaces is used for reactive properties (focused/urgent),
    // but the canonical order comes from i3-msg sorted by num.
    property var wsOrder: []   // ordered workspace names from i3
    readonly property int _wsCount: I3.workspaces.count

    property var sortedWorkspaces: {
        void root._wsCount
        void root.wsOrder
        // Build a rank map from wsOrder
        var rank = {}
        for (var r = 0; r < wsOrder.length; r++)
            rank[wsOrder[r]] = r
        var list = []
        var vals = I3.workspaces.values
        if (!vals) return list
        for (var i = 0; i < vals.length; i++) {
            var w = vals[i]
            list.push({name: w.name, number: w.number, focused: w.focused, active: w.active, urgent: w.urgent, wsId: w.id})
        }
        list.sort(function(a, b) {
            var ra = rank[a.name] !== undefined ? rank[a.name] : 99999
            var rb = rank[b.name] !== undefined ? rank[b.name] : 99999
            return ra - rb
        })
        return list
    }

    // Fetch workspace order from i3 IPC (stable sort by num)
    Process {
        id: wsOrderProc
        running: true
        command: ["sh", "-c", "i3-msg -t get_workspaces | python3 -c \"import json,sys; ws=json.load(sys.stdin); ws.sort(key=lambda w:w['num']); [print(w['name']) for w in ws]\""]
        stdout: SplitParser {
            property var buf: []
            onRead: data => { var v = data.trim(); if (v) buf.push(v) }
        }
        onExited: { root.wsOrder = wsOrderProc.stdout.buf; wsOrderProc.stdout.buf = []; wsOrderTimer.restart() }
    }
    Timer { id: wsOrderTimer; interval: 2000; onTriggered: wsOrderProc.running = true }

    // Also refresh on workspace events
    Process {
        id: wsEventSub
        running: true
        command: ["i3-msg", "-t", "subscribe", "-m", '["workspace"]']
        stdout: SplitParser {
            onRead: data => wsOrderProc.running = true
        }
        onExited: running = true
    }

    // --- Mode tracking ---
    property string currentMode: "default"

    // Mode hint definitions: [{key, label}]
    function modeHints(mode) {
        if (mode === "resize")
            return [
                {key: "j", label: "←"},
                {key: "k", label: "↓"},
                {key: "l", label: "↑"},
                {key: ";", label: "→"},
                {key: "←↓↑→", label: "arrows"},
                {key: "Esc", label: "exit"}
            ]
        if (mode.indexOf("(l)ock") !== -1)
            return [
                {key: "l", label: "lock"},
                {key: "e", label: "exit"},
                {key: "u", label: "switch user"},
                {key: "s", label: "suspend"},
                {key: "h", label: "hibernate"},
                {key: "r", label: "reboot"},
                {key: "S-s", label: "shutdown"},
                {key: "Esc", label: "cancel"}
            ]
        return [{key: "", label: mode}]
    }

    Process {
        command: ["i3-msg", "-t", "subscribe", "-m", '["mode"]']
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    var e = JSON.parse(data)
                    if (e.change !== undefined) root.currentMode = e.change
                } catch(err) {}
            }
        }
        onExited: running = true
    }

    // --- System stats ---
    // proot/Termux: qs-stats-helper.sh writes /tmp/qs-stats; native Linux: read /proc directly
    readonly property string statsFile: "/tmp/qs-stats"
    property string cpuVal:  "?"
    property string ramVal:  "?"
    property string diskVal: "?"
    property string netVal:  ""
    property string volVal:  ""
    property bool volMuted: false
    property string batVal:  ""
    property string batStatus: ""

    Process {
        id: statsProc
        running: true
        command: ["sh", "-c",
            "if [ -f " + root.statsFile + " ]; then cat " + root.statsFile + "; else " +
            "read _ a1 b1 c1 d1 e1 f1 g1 _ < /proc/stat; sleep 1; " +
            "read _ a2 b2 c2 d2 e2 f2 g2 _ < /proc/stat; " +
            "t1=$((a1+b1+c1+d1+e1+f1+g1)); t2=$((a2+b2+c2+d2+e2+f2+g2)); " +
            "dt=$((t2-t1)); di=$((d2-d1)); " +
            "echo $(( dt > 0 ? (dt-di)*100/dt : 0 )); " +
            "awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf \"%.0f\\n\", (t-a)/t*100}' /proc/meminfo; " +
            "df / | awk 'NR==2{gsub(/%/,\"\",$5); print $5}'; fi"]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: data => {
                var v = data.trim()
                if (lineNum === 0) root.cpuVal = v + "%"
                else if (lineNum === 1) root.ramVal = v + "%"
                else if (lineNum === 2) root.diskVal = v + "%"
                lineNum++
            }
        }
        onExited: { statsProc.stdout.lineNum = 0; statsTimer.restart() }
    }
    Timer { id: statsTimer; interval: 3000; onTriggered: statsProc.running = true }

    Process {
        id: netProc
        running: true
        command: ["sh", "-c",
            "iwgetid -r 2>/dev/null && exit; ip -brief addr | awk '!/^lo /{if($2==\"UP\") print $1; exit}'"]
        stdout: SplitParser { onRead: data => root.netVal = data.trim() }
        onExited: netTimer.restart()
    }
    Timer { id: netTimer; interval: 10000; onTriggered: netProc.running = true }

    Process {
        id: volProc
        running: true
        command: ["sh", "-c",
            "pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\\d+(?=%)' | head -1; " +
            "pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -oP '(yes|no)'"]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: data => {
                if (lineNum === 0) root.volVal = data.trim()
                else if (lineNum === 1) root.volMuted = (data.trim() === "yes")
                lineNum++
            }
        }
        onExited: { volProc.stdout.lineNum = 0; volTimer.restart() }
    }
    Timer { id: volTimer; interval: 5000; onTriggered: volProc.running = true }

    Process { id: volToggleMute; command: ["pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle"]; onExited: volProc.running = true }
    Process { id: volUp; command: ["sh", "-c", "cur=$(pactl get-sink-volume @DEFAULT_SINK@ | grep -oP '\\d+(?=%)' | head -1); [ \"$cur\" -lt 100 ] && pactl set-sink-volume @DEFAULT_SINK@ +5%"]; onExited: volProc.running = true }
    Process { id: volDown; command: ["pactl", "set-sink-volume", "@DEFAULT_SINK@", "-5%"]; onExited: volProc.running = true }

    Process {
        id: batProc
        running: true
        command: ["sh", "-c",
            "cat /sys/class/power_supply/BAT0/capacity 2>/dev/null; cat /sys/class/power_supply/BAT0/status 2>/dev/null"]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: data => {
                if (lineNum === 0) root.batVal = data.trim()
                else if (lineNum === 1) root.batStatus = data.trim()
                lineNum++
            }
        }
        onExited: { batProc.stdout.lineNum = 0; batTimer.restart() }
    }
    Timer { id: batTimer; interval: 10000; onTriggered: batProc.running = true }


    // --- Layout (using Row, not RowLayout — RowLayout leaks Text.color) ---
    Item {
        anchors.fill: parent

        // Left: workspaces + mode
        Row {
            id: leftSide
            visible: root.currentMode === "default"
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; leftMargin: 4 }
            spacing: 0

            Repeater {
                model: root.sortedWorkspaces

                Rectangle {
                    required property var modelData
                    width: wsText.implicitWidth + 14
                    height: leftSide.height
                    color: modelData.urgent  ? "#cb4b16"
                         : modelData.focused ? "#152024"
                         : "transparent"

                    Text {
                        id: wsText
                        anchors.centerIn: parent
                        text: modelData.name
                        color: "#fdf6e3"
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize
                        renderType: root.nativeRender
                    }

                    Rectangle {
                        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                        height: 3
                        color: modelData.focused                    ? "#16a085"
                             : (modelData.active && !modelData.focused) ? "#454948"
                             : "transparent"
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: I3.dispatch("workspace " + modelData.name)
                    }
                }
            }

            // Mode indicator
            Rectangle {
                visible: root.currentMode !== "default"
                width: modeText.implicitWidth + 14
                height: leftSide.height
                color: "#152024"

                Text {
                    id: modeText
                    anchors.centerIn: parent
                    text: root.currentMode
                    color: "#fdf6e3"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    renderType: root.nativeRender
                }

                Rectangle {
                    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                    height: 3
                    color: "#cb4b16"
                }
            }
        }

        // Mode hints overlay (whole bar, left-aligned)
        Row {
            visible: root.currentMode !== "default"
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; leftMargin: 4 }
            spacing: 0

            Rectangle {
                width: modeNameText.implicitWidth + 14
                height: 27
                color: "#152024"

                Text {
                    id: modeNameText
                    anchors.centerIn: parent
                    text: root.currentMode === "resize" ? "resize" : "system"
                    color: "#fdf6e3"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    renderType: root.nativeRender
                }

                Rectangle {
                    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                    height: 3
                    color: "#cb4b16"
                }
            }
            Item { width: 4; height: parent.height }

            Repeater {
                model: root.currentMode !== "default" ? root.modeHints(root.currentMode) : []

                Row {
                    required property var modelData
                    required property int index
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                    Text { text: index > 0 ? "  " : ""; font.pixelSize: root.fontSize; renderType: root.nativeRender }
                    Text { text: modelData.key; color: "#cb4b16"; font.family: root.fontFamily; font.pixelSize: root.fontSize; font.bold: true; renderType: root.nativeRender; Rectangle { anchors.fill: parent; color: "#152024"; z: -1 } }
                    Text { text: " "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
                    Text { text: modelData.label; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
                }
            }
        }

        // Notification ticker — between workspaces and bell/date
        Item {
            id: tickerArea
            visible: root.currentMode === "default" && root.tickerActive
            anchors { left: leftSide.right; right: rightSide.left; verticalCenter: parent.verticalCenter; leftMargin: 8; rightMargin: 4 }
            clip: true
            height: parent.height
            z: -1

            Text {
                id: tickerText
                text: root.notifText
                color: "#fdf6e3"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
                y: (parent.height - height) / 2
            }

            NumberAnimation {
                id: tickerAnim
                target: tickerText
                property: "x"
                from: tickerArea.width > 0 ? tickerArea.width : 500
                to: -tickerText.implicitWidth
                duration: Math.max(((tickerArea.width > 0 ? tickerArea.width : 500) + tickerText.implicitWidth) * 12, 3000)
                onFinished: root.tickerActive = false
            }
        }

        // Right side: stats + bell + date
        Row {
            id: rightSide
            visible: root.currentMode === "default"
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 4 }
            spacing: 0

            // Stats (hidden during ticker)
            Text { visible: !root.tickerActive && root.netVal !== ""; text: "NET:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive && root.netVal !== ""; text: root.netVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive && root.netVal !== ""; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { visible: !root.tickerActive; text: "CPU:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive; text: root.cpuVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { visible: !root.tickerActive; text: "RAM:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive; text: root.ramVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { visible: !root.tickerActive; text: "HDD:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive; text: root.diskVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { visible: !root.tickerActive && root.volVal !== ""; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Item {
                visible: !root.tickerActive && root.volVal !== ""
                width: volLabel.implicitWidth + volValue.implicitWidth
                height: parent.height
                Text { id: volLabel; text: (root.volMuted || root.volVal === "0") ? "" : "VOL:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                Text { id: volValue; anchors.left: volLabel.right; text: (root.volMuted || root.volVal === "0") ? "MUTED" : root.volVal + "%"; color: (root.volMuted || root.volVal === "0") ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    onClicked: volToggleMute.running = true
                    onWheel: wheel => { if (wheel.angleDelta.y > 0) volUp.running = true; else volDown.running = true }
                }
            }

            Text { visible: !root.tickerActive && root.batVal !== ""; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive && root.batVal !== "" && root.batVal !== "100"; text: (root.batStatus === "Charging" ? "CHR:" : "BAT:"); color: "#16a085"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive && root.batVal !== "" && root.batVal !== "100"; text: root.batVal + "%"; color: root.batStatus === "Discharging" && parseInt(root.batVal) <= 20 ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive && root.batVal === "100"; text: "CHARGED"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // System tray (StatusNotifierItem / SNI). Legacy XEmbed apps
            // (nm-applet, pamac-tray) will not appear without an XEmbed→SNI
            // bridge like xembedsniproxy. Modern apps (Firefox, Telegram,
            // Element, Steam, KeePassXC, …) show up automatically.
            Repeater {
                model: SystemTray.items
                delegate: Item {
                    required property var modelData
                    visible: !root.tickerActive
                    width: visible ? 18 : 0
                    height: parent.height
                    Image {
                        anchors.centerIn: parent
                        width: 14; height: 14
                        sourceSize: Qt.size(14, 14)
                        source: modelData.icon
                        smooth: false
                    }
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        onClicked: mouse => {
                            if (mouse.button === Qt.LeftButton) modelData.activate(0, 0)
                            else if (mouse.button === Qt.MiddleButton) modelData.secondaryActivate(0, 0)
                        }
                    }
                }
            }

            Text {
                visible: !root.tickerActive && SystemTray.items.length > 0
                text: "  "
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
            }

            // Bell — always visible, click to replay ticker
            Item {
                width: bellIcon.width + (root.notifCount > 0 ? bellCount.implicitWidth : 0)
                height: 14
                Image {
                    id: bellIcon
                    width: 14; height: 14
                    y: 2
                    sourceSize: Qt.size(14, 14)
                    source: "data:image/svg+xml," + encodeURIComponent(
                        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="' + (root.hasCritical ? '#cb4b16' : root.notifCount > 0 ? '#fdf6e3' : '#707880') + '">' +
                        '<path d="M12 2C10.9 2 10 2.9 10 4V4.3C7.7 5.1 6 7.3 6 10V16L4 18V19H20V18L18 16V10C18 7.3 16.3 5.1 14 4.3V4C14 2.9 13.1 2 12 2ZM10 20C10 21.1 10.9 22 12 22S14 21.1 14 20H10Z"/>' +
                        '</svg>')
                }
                Text { id: bellCount; visible: root.notifCount > 0; anchors.left: bellIcon.right; text: root.notifCount; color: root.hasCritical ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; font.bold: true; renderType: root.nativeRender }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.dismissNotif()
                }
            }

            Text { text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // Date
            Text {
                property bool showSeconds: false
                text: Qt.formatDateTime(new Date(), showSeconds ? "HH:mm:ss" : "HH:mm")
                color: "#707880"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
                Timer { interval: parent.showSeconds ? 1000 : 60000; running: true; repeat: true; onTriggered: parent.text = Qt.formatDateTime(new Date(), parent.showSeconds ? "HH:mm:ss" : "HH:mm") }
                MouseArea { anchors.fill: parent; onClicked: { parent.showSeconds = !parent.showSeconds; parent.text = Qt.formatDateTime(new Date(), parent.showSeconds ? "HH:mm:ss" : "HH:mm") } }
            }
            Text { text: " "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text {
                text: Qt.formatDateTime(new Date(), "yyyy-MM-dd")
                color: "#fdf6e3"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
                Timer { interval: 60000; running: true; repeat: true; onTriggered: parent.text = Qt.formatDateTime(new Date(), "yyyy-MM-dd") }
            }
        }
    }
}
