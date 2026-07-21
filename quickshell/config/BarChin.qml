import Quickshell
import QtQuick
import "./Common"

// Bottom rounded-corner clearance for the phone (Razr/xrdp inset path).
// The bar itself lives at the TOP of the screen (see Bar.qml); this strip
// reserves the bottom QS_BAR_INSET_BOTTOM pixels as X11 strut so tiled app
// windows stay clear of the display's physical rounded bottom corners. It is
// painted black (#000000) to blend into the Razr's bezel, matching the old
// inset surround. Engages only while the viewport is phone-shaped
// (Session.insetActive) and a bottom inset is configured — a desktop monitor
// gets nothing (window hidden, no strut).
PanelWindow {
    id: chin

    // `modelData` + `screen` are set by the Variants delegate in shell.qml
    // (one instance per screen), matching Bar.qml.

    readonly property bool insetOn: Session.insetActive(
        screen ? screen.width : 1920, screen ? screen.height : 1080)
    readonly property int chinHeight: insetOn ? Session.insetBottom : 0

    visible: chinHeight > 0
    anchors {
        left: true
        right: true
        bottom: true
    }
    implicitHeight: chinHeight > 0 ? chinHeight : 1
    color: "#000000"
}
