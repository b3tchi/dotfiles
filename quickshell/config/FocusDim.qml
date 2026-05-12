import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: root
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null
    property bool isProot: false

    Process {
        id: probeProc
        running: true
        command: ["sh", "-c", "[ -d /data/data/com.termux ] && echo proot || echo native"]
        stdout: SplitParser { onRead: data => root.isProot = (data.trim() === "proot") }
        onExited: { if (!root.isSway && !root.isProot) dimProc.running = true }
    }

    Process {
        id: dimProc
        running: false
        command: ["sh", "-c", "exec python3 -u $HOME/.dotfiles/quickshell/qs-focus-dim.py"]
        onExited: restartTimer.restart()
    }
    Timer { id: restartTimer; interval: 2000; onTriggered: { if (!root.isSway && !root.isProot) dimProc.running = true } }

    Loader {
        active: isSway
        source: "FocusDimWayland.qml"
    }
}
