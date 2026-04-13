import Quickshell
import Quickshell.Io
import QtQuick

Item {
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null

    // X11/i3: python GTK3/cairo overlay
    Process {
        id: borderProc
        running: !isSway
        command: ["sh", "-c", "exec python3 -u $HOME/.dotfiles/quickshell/qs-focus-border.py"]
        onExited: restartTimer.restart()
    }
    Timer { id: restartTimer; interval: 2000; onTriggered: { if (!isSway) borderProc.running = true } }

    // Wayland/sway: pure QML layer-shell overlay
    Loader {
        active: isSway
        source: "FocusBorderWayland.qml"
    }
}
