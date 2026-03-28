import Quickshell
import Quickshell.I3
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

PanelWindow {
    id: root

    // X11 (i3, desktop): top full-width bar
    // Wayland (sway, phone): bottom floating bar
    readonly property bool isWayland: Qt.platform.pluginName.startsWith("wayland")

    anchors {
        left: true
        right: true
        top: !isWayland
        bottom: isWayland
    }

    implicitHeight: 35

    margins {
        bottom: isWayland ? 20 : 0
        left:   isWayland ? 40 : 0
        right:  isWayland ? 40 : 0
    }

    color: "#222d31"

    readonly property string fontFamily: "Iosevka Nerd Font"
    readonly property int fontSize: 13

    // Render LABEL:value with colored label
    function stat(label, value) {
        return "<font color='#16a085'>" + label + ":</font>"
             + "<font color='#fdf6e3'>" + value + "</font>"
    }

    // --- Mode tracking ---
    property string currentMode: "default"

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

    // --- Layout ---
    RowLayout {
        anchors {
            fill: parent
            leftMargin: 10
            rightMargin: 10
        }
        spacing: 0

        // Workspaces
        RowLayout {
            spacing: 2
            Repeater {
                model: I3.workspaces
                Rectangle {
                    required property var modelData
                    implicitWidth: wsText.implicitWidth + 16
                    implicitHeight: 26
                    radius: 4
                    color: modelData.focused ? "#152024" : "transparent"
                    border.color: modelData.urgent ? "#cb4b16" : "transparent"
                    border.width: 2
                    Text {
                        id: wsText
                        anchors.centerIn: parent
                        text: modelData.name
                        color: modelData.focused ? "#fdf6e3" : "#707880"
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: I3.dispatch("workspace " + modelData.name)
                    }
                }
            }
        }

        // Mode indicator
        Rectangle {
            visible: root.currentMode !== "default"
            implicitWidth: modeText.implicitWidth + 16
            implicitHeight: 26
            radius: 4
            color: "#152024"
            border.color: "#cb4b16"
            border.width: 2
            Text {
                id: modeText
                anchors.centerIn: parent
                text: root.currentMode
                color: "#fdf6e3"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
            }
        }

        Item { Layout.fillWidth: true }

        // Network
        Text {
            visible: root.netVal !== ""
            textFormat: Text.RichText
            text: root.stat("NET", root.netVal)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
        }
        Text { visible: root.netVal !== ""; text: "  "; color: "#707880"; font.pixelSize: root.fontSize }

        // CPU
        Text {
            textFormat: Text.RichText
            text: root.stat("CPU", root.cpuVal)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
        }
        Text { text: "  "; color: "#707880"; font.pixelSize: root.fontSize }

        // RAM
        Text {
            textFormat: Text.RichText
            text: root.stat("RAM", root.ramVal)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
        }
        Text { text: "  "; color: "#707880"; font.pixelSize: root.fontSize }

        // Disk
        Text {
            textFormat: Text.RichText
            text: root.stat("HDD", root.diskVal)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
        }

        // Volume
        Text {
            visible: root.volVal !== ""
            text: "  "
            color: "#707880"
            font.pixelSize: root.fontSize
        }
        Text {
            visible: root.volVal !== ""
            textFormat: Text.RichText
            text: root.stat("VOL", root.volVal + "%")
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
        }

        Text { text: "  "; color: "#707880"; font.pixelSize: root.fontSize }

        // Date
        Text {
            id: dateClock
            textFormat: Text.RichText
            font.family: root.fontFamily
            font.pixelSize: root.fontSize

            function update() {
                var now = new Date()
                text = "<font color='#707880'>" + Qt.formatDateTime(now, "HH:mm") + "</font>"
                    + " <font color='#fdf6e3'>" + Qt.formatDateTime(now, "yyyy-MM-dd") + "</font>"
            }

            Component.onCompleted: update()
            Timer {
                interval: 1000
                running: true
                repeat: true
                onTriggered: dateClock.update()
            }
        }

        Item { width: 4 }
    }
}
