import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Io
import QtQuick

ShellRoot {
    NotificationServer {
        id: notifSrv
        keepOnReload: true
        bodyMarkupSupported: true
        imageSupported: false
        actionsSupported: false
        persistenceSupported: false

        onNotification: notification => {
            notification.tracked = true
            ipcUpdate.running = true
        }
    }

    // Send count to bar process via IPC
    Process {
        id: ipcUpdate
        command: ["quickshell", "ipc", "call", "notif", "setCount", "" + notifSrv.trackedNotifications.values.length]
    }

    // Also update on expire/dismiss (poll since no direct signal)
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: ipcUpdate.running = true
    }

    FloatingWindow {
        id: popup

        title: "quickshell-notifications"

        implicitWidth: 300
        implicitHeight: 400

        color: "transparent"

        visible: notifSrv.trackedNotifications.values.length > 0

        readonly property string fontFamily: "Iosevka Nerd Font"
        readonly property int nativeRender: Text.NativeRendering

        Column {
            id: notifColumn
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4

            Repeater {
                model: notifSrv.trackedNotifications

                Rectangle {
                    required property var modelData
                    required property int index

                    visible: index >= (notifSrv.trackedNotifications.values.length - 5)

                    width: notifColumn.width
                    height: visible ? Math.max(notifContent.implicitHeight + 16, 40) : 0

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
                            width: parent.width
                            text: (modelData.body ?? "") !== "" ? modelData.body : " "
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
}
