import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: root
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null

    // X11 platforms (native/wsl/proot): dimming is picom's job —
    // inactive-dim in i3/picom.conf. The qs-focus-dim.py overlay is
    // retired there: it double-dimmed on top of picom and lagged behind
    // mouse-driven focus changes (and on wsl/xrdp every focus change
    // redrew the whole screen — a visible blink over RDP).
    Loader {
        active: isSway
        source: "FocusDimWayland.qml"
    }
}
