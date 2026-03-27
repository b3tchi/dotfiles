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

    // Track i3/sway binding mode (e.g. "resize", "menu")
    property string currentMode: "default"

    // Subscribe to mode events — process stays open, no polling needed
    Process {
        id: modeSubscribe
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

        // Reconnect if i3 restarts
        onExited: running = true
    }

    RowLayout {
        anchors {
            fill: parent
            leftMargin: 10
            rightMargin: 10
        }
        spacing: 6

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
                        font.family: "Iosevka Nerd Font"
                        font.pixelSize: 13
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: I3.dispatch("workspace " + modelData.name)
                    }
                }
            }
        }

        // Mode indicator — visible only when not in default mode
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
                font.family: "Iosevka Nerd Font"
                font.pixelSize: 13
            }
        }

        Item { Layout.fillWidth: true }

        // Clock
        Text {
            id: clock
            color: "#fdf6e3"
            font.family: "Iosevka Nerd Font"
            font.pixelSize: 13

            function update() {
                text = Qt.formatDateTime(new Date(), "HH:mm")
            }

            Component.onCompleted: update()

            Timer {
                interval: 1000
                running: true
                repeat: true
                onTriggered: clock.update()
            }
        }

        Item { width: 4 }
    }
}
