import Quickshell
import Quickshell.Services.Notifications
import QtQuick

PanelWindow {
    id: popup

    required property NotificationServer server

    anchors {
        top: true
        right: true
    }

    exclusiveZone: 0

    implicitWidth: 300
    implicitHeight: notifColumn.implicitHeight > 0 ? notifColumn.implicitHeight : 1

    color: "transparent"

    visible: server.trackedNotifications.values.length > 0

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

                visible: index >= (server.trackedNotifications.values.length - 5)

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

                    Text {
                        width: parent.width
                        text: modelData.summary ?? ""
                        color: modelData.urgency === NotificationUrgency.Critical ? "#CB4B16"
                             : modelData.urgency === NotificationUrgency.Low ? "#707880"
                             : "#FDF6E3"
                        font.family: popup.fontFamily
                        font.pixelSize: 14
                        font.bold: true
                        elide: Text.ElideRight
                        renderType: popup.nativeRender
                    }

                    Text {
                        visible: (modelData.body ?? "") !== ""
                        width: parent.width
                        text: modelData.body ?? ""
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

                    Text {
                        visible: (modelData.appName ?? "") !== ""
                        text: modelData.appName ?? ""
                        color: "#707880"
                        font.family: popup.fontFamily
                        font.pixelSize: 10
                        renderType: popup.nativeRender
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: modelData.dismiss()
                }

                Timer {
                    running: modelData.urgency !== NotificationUrgency.Critical
                    interval: 10000
                    onTriggered: modelData.expire()
                }
            }
        }
    }
}
