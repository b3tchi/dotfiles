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

        // Fullscreen dim — Task 6 replaces this with 4-rect cut-out
        Rectangle {
            anchors.fill: parent
            color: "#4D000000"   // 30% black
        }
    }
}
