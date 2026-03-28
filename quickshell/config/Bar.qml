import Quickshell
import Quickshell.I3
import Quickshell.Io
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts

PanelWindow {
    id: root

    // Notification server passed from shell.qml
    required property NotificationServer notifServer

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
    readonly property int nativeRender: Text.NativeRendering

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
    property string cpuVal:  "?"
    property string ramVal:  "?"
    property string diskVal: "?"
    property string netVal:  ""
    property string volVal:  ""

    Process {
        id: cpuProc
        running: true
        command: ["sh", "-c",
            "awk 'NR==1{t=$2+$3+$4+$5+$6+$7+$8+$9; idle=$5+$6; printf \"%.0f%%\", (1-idle/t)*100}' /proc/stat"]
        stdout: SplitParser { onRead: data => root.cpuVal = data.trim() }
        onExited: cpuTimer.restart()
    }
    Timer { id: cpuTimer; interval: 3000; onTriggered: cpuProc.running = true }

    Process {
        id: ramProc
        running: true
        command: ["sh", "-c",
            "awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf \"%.0f%%\", (t-a)/t*100}' /proc/meminfo"]
        stdout: SplitParser { onRead: data => root.ramVal = data.trim() }
        onExited: ramTimer.restart()
    }
    Timer { id: ramTimer; interval: 5000; onTriggered: ramProc.running = true }

    Process {
        id: diskProc
        running: true
        command: ["sh", "-c", "df / | awk 'NR==2{print $5}'"]
        stdout: SplitParser { onRead: data => root.diskVal = data.trim() }
        onExited: diskTimer.restart()
    }
    Timer { id: diskTimer; interval: 30000; onTriggered: diskProc.running = true }

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
            "pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\\d+(?=%)' | head -1"]
        stdout: SplitParser { onRead: data => root.volVal = data.trim() }
        onExited: volTimer.restart()
    }
    Timer { id: volTimer; interval: 5000; onTriggered: volProc.running = true }

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
                model: I3.workspaces

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
                        font.pixelSize: 14
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
                    font.pixelSize: 14
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
                    font.pixelSize: 14
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
                    Text { text: index > 0 ? "  " : ""; font.pixelSize: 14; renderType: root.nativeRender }
                    Text { text: modelData.key; color: "#cb4b16"; font.family: root.fontFamily; font.pixelSize: 14; font.bold: true; renderType: root.nativeRender; Rectangle { anchors.fill: parent; color: "#152024"; z: -1 } }
                    Text { text: " "; font.pixelSize: 14; renderType: root.nativeRender }
                    Text { text: modelData.label; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
                }
            }
        }

        // Right: stats
        Row {
            visible: root.currentMode === "default"
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 4 }
            spacing: 0

            // Network
            Text { visible: root.netVal !== ""; text: "NET:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.netVal !== ""; text: root.netVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.netVal !== ""; text: "  "; font.pixelSize: 14; renderType: root.nativeRender }

            // CPU
            Text { text: "CPU:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { text: root.cpuVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { text: "  "; font.pixelSize: 14; renderType: root.nativeRender }

            // RAM
            Text { text: "RAM:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { text: root.ramVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { text: "  "; font.pixelSize: 14; renderType: root.nativeRender }

            // Disk
            Text { text: "HDD:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { text: root.diskVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }

            // Volume
            Text { visible: root.volVal !== ""; text: "  "; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.volVal !== ""; text: "VOL:"; color: "#16a085"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.volVal !== ""; text: root.volVal + "%"; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }

            // Notifications
            Text { visible: root.notifServer.trackedNotifications.count > 0; text: "  "; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.notifServer.trackedNotifications.count > 0; text: "NOT:"; color: "#cb4b16"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }
            Text { visible: root.notifServer.trackedNotifications.count > 0; text: "" + root.notifServer.trackedNotifications.count; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: 14; renderType: root.nativeRender }

            Text { text: "  "; font.pixelSize: 14; renderType: root.nativeRender }

            // Date
            Text {
                property bool showSeconds: false
                text: Qt.formatDateTime(new Date(), showSeconds ? "HH:mm:ss" : "HH:mm")
                color: "#707880"
                font.family: root.fontFamily
                font.pixelSize: 14
                renderType: root.nativeRender
                Timer { interval: showSeconds ? 1000 : 60000; running: true; repeat: true; onTriggered: parent.text = Qt.formatDateTime(new Date(), parent.showSeconds ? "HH:mm:ss" : "HH:mm") }
                MouseArea { anchors.fill: parent; onClicked: { parent.showSeconds = !parent.showSeconds; parent.text = Qt.formatDateTime(new Date(), parent.showSeconds ? "HH:mm:ss" : "HH:mm") } }
            }
            Text { text: " "; font.pixelSize: 14; renderType: root.nativeRender }
            Text {
                text: Qt.formatDateTime(new Date(), "yyyy-MM-dd")
                color: "#fdf6e3"
                font.family: root.fontFamily
                font.pixelSize: 14
                renderType: root.nativeRender
                Timer { interval: 60000; running: true; repeat: true; onTriggered: parent.text = Qt.formatDateTime(new Date(), "yyyy-MM-dd") }
            }
        }
    }
}
