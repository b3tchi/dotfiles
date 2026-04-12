import Quickshell
import Quickshell.Io
import QtQuick

Item {
    Process {
        id: borderProc
        running: true
        command: ["sh", "-c", "exec python3 -u $HOME/.dotfiles/quickshell/qs-focus-border.py"]
        onExited: restartTimer.restart()
    }
    Timer { id: restartTimer; interval: 2000; onTriggered: borderProc.running = true }
}
