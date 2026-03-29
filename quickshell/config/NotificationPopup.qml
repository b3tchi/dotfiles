import Quickshell
import Quickshell.Services.Notifications
import QtQuick

FloatingWindow {
    id: popup

    required property NotificationServer server

    title: "quickshell-notifications"

    implicitWidth: 300
    implicitHeight: 80

    color: "#222D31"

    visible: server.trackedNotifications.values.length > 0

    property var latest: server.trackedNotifications.values.length > 0
        ? server.trackedNotifications.values[server.trackedNotifications.values.length - 1]
        : null

    readonly property string fontFamily: "Iosevka Nerd Font"
    readonly property int nativeRender: Text.NativeRendering

    Column {
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
        spacing: 2

        Text {
            width: parent.width
            text: popup.latest ? (popup.latest.summary ?? "") : ""
            color: "#FDF6E3"
            font.family: popup.fontFamily
            font.pixelSize: 14
            font.bold: true
            elide: Text.ElideRight
            renderType: popup.nativeRender
        }

        Text {
            width: parent.width
            text: popup.latest ? ((popup.latest.body ?? "") !== "" ? popup.latest.body : " ") : " "
            color: "#FDF6E3"
            font.family: popup.fontFamily
            font.pixelSize: 11
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
            renderType: popup.nativeRender
        }

        Text {
            text: popup.latest && (popup.latest.appName ?? "") !== "" ? popup.latest.appName : " "
            color: "#707880"
            font.family: popup.fontFamily
            font.pixelSize: 10
            renderType: popup.nativeRender
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: { if (popup.latest) popup.latest.dismiss() }
    }

    Timer {
        running: popup.latest !== null && popup.latest.urgency !== NotificationUrgency.Critical
        interval: 10000
        onTriggered: { if (popup.latest) popup.latest.expire() }
    }
}
