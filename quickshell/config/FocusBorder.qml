import Quickshell
import Quickshell.Io
import QtQuick

Item {
    // X11/i3 only — python script uses GTK3/cairo overlay (no Wayland equivalent)
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null

    Process {
        id: borderProc
        running: !isSway
        command: ["sh", "-c", "exec python3 -u $HOME/.dotfiles/quickshell/qs-focus-border.py"]
        onExited: restartTimer.restart()
    }
    Timer { id: restartTimer; interval: 2000; onTriggered: { if (!isSway) borderProc.running = true } }
}
