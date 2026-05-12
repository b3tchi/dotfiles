import Quickshell
import QtQuick

Item {
    id: root
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null

    Loader {
        active: isSway
        source: "FocusDimWayland.qml"
    }
}
