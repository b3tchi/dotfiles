import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: root
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null
    property bool isProot: false

    // Detect proot/Termux — GTK overlay destabilizes X11 connection there
    Process {
        id: probeProc
        running: true
        command: ["sh", "-c", "[ -d /data/data/com.termux ] && echo proot || echo native"]
        stdout: SplitParser { onRead: data => root.isProot = (data.trim() === "proot") }
        onExited: { if (!root.isSway && !root.isProot) borderProc.running = true }
    }

    // X11/i3: python GTK3/cairo overlay (skip on proot)
    Process {
        id: borderProc
        running: false
        command: ["sh", "-c", "exec python3 -u $HOME/.dotfiles/quickshell/qs-focus-border.py"]
        onExited: restartTimer.restart()
    }
    Timer { id: restartTimer; interval: 2000; onTriggered: { if (!root.isSway && !root.isProot) borderProc.running = true } }

    // Wayland/sway: pure QML layer-shell overlay
    Loader {
        active: isSway
        source: "FocusBorderWayland.qml"
    }
}
