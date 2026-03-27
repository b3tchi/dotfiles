import Quickshell
import Quickshell.I3
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
    // Rounded corners on phone, square on desktop
    // (border-radius not directly on PanelWindow; handled via inner Rectangle if needed)

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
