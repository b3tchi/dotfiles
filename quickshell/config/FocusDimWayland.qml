import Quickshell
import Quickshell.Io
import QtQuick

Variants {
    model: Quickshell.screens

    PanelWindow {
        id: dimOverlay
        required property var modelData
        screen: modelData

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        aboveWindows: true
        exclusiveZone: 0
        focusable: false
        color: "transparent"

        mask: Region {}   // empty = fully click-through

        property int fx: 0
        property int fy: 0
        property int fw: 0
        property int fh: 0
        property bool hasFocus: false
        readonly property string dimColor: "#4D000000"   // 30% black

        // Top — full width; collapses to zero when hasFocus and fy==0
        Rectangle {
            color: dimOverlay.dimColor
            x: 0; y: 0
            width: parent.width
            height: dimOverlay.hasFocus ? Math.max(0, dimOverlay.fy) : parent.height
        }
        // Bottom — hidden when no focused window
        Rectangle {
            visible: dimOverlay.hasFocus
            color: dimOverlay.dimColor
            x: 0
            y: dimOverlay.fy + dimOverlay.fh
            width: parent.width
            height: Math.max(0, parent.height - (dimOverlay.fy + dimOverlay.fh))
        }
        // Left — hidden when no focused window
        Rectangle {
            visible: dimOverlay.hasFocus
            color: dimOverlay.dimColor
            x: 0
            y: dimOverlay.fy
            width: Math.max(0, dimOverlay.fx)
            height: dimOverlay.fh
        }
        // Right — hidden when no focused window
        Rectangle {
            visible: dimOverlay.hasFocus
            color: dimOverlay.dimColor
            x: dimOverlay.fx + dimOverlay.fw
            y: dimOverlay.fy
            width: Math.max(0, parent.width - (dimOverlay.fx + dimOverlay.fw))
            height: dimOverlay.fh
        }
    }
}
