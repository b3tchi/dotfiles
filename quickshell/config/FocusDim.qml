import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: root
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null
    property bool isProot: false
    // wsl/xrdp: skip the fullscreen dim overlay — every focus change
    // redraws the whole screen, which the RDP encoder turns into a
    // visible blink; picom inactive-dim covers dimming there instead
    property bool isWsl: false

    Process {
        id: probeProc
        running: true
        command: ["sh", "-c", "if [ -d /data/data/com.termux ]; then echo proot; elif grep -qi microsoft /proc/version; then echo wsl; else echo native; fi"]
        stdout: SplitParser { onRead: data => { const v = data.trim(); root.isProot = (v === "proot"); root.isWsl = (v === "wsl") } }
        onExited: { if (!root.isSway && !root.isProot && !root.isWsl) dimProc.running = true }
    }

    Process {
        id: dimProc
        running: false
        // GDK_BACKEND=x11: X11-only branch; stop GTK escaping to a WSLg
        // wayland socket when one exists (wsl)
        command: ["sh", "-c", "exec env GDK_BACKEND=x11 python3 -u $HOME/.dotfiles/quickshell/qs-focus-dim.py"]
        onExited: restartTimer.restart()
    }
    Timer { id: restartTimer; interval: 2000; onTriggered: { if (!root.isSway && !root.isProot && !root.isWsl) dimProc.running = true } }

    Loader {
        active: isSway
        source: "FocusDimWayland.qml"
    }
}
