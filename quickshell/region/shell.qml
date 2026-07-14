// Region-screenshot selector overlay (grab-only, freeze-frame).
//
// Launched ephemerally by qs-screenshot.sh (`quickshell -p .../region`),
// bound to $mod+Shift+s. The wrapper first grabs the WHOLE screen to a temp
// PNG (QS_SHOT_SRC) and this overlay shows it fullscreen as an opaque image —
// so it works on the console AND over xrdp with no compositor/alpha needed
// (a translucent live overlay renders black without a compositor). Drag a
// rectangle; on release we crop the frozen PNG to that region → timestamped
// file + clipboard, then quit. No persistent process (the ksnip pain).
//
// visibility: Window.FullScreen asks the WM for real fullscreen (i3 honors
// _NET_WM_STATE_FULLSCREEN), so the image maps 1:1 to screen pixels and the
// selection coords ARE the crop coords. Right-click / Escape cancels.
//
// Single (primary) screen — matches the xrdp / laptop targets.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Window

ShellRoot {
    id: root

    readonly property string src: Quickshell.env("QS_SHOT_SRC") ?? ""
    readonly property string accent: "#16a085"

    property real startX: 0
    property real startY: 0
    property real curX: 0
    property real curY: 0
    property bool dragging: false

    function selX() { return Math.min(startX, curX) }
    function selY() { return Math.min(startY, curY) }
    function selW() { return Math.abs(curX - startX) }
    function selH() { return Math.abs(curY - startY) }

    function cleanupCmd() { return "rm -f '" + src + "'" }

    function cancel() {
        Quickshell.execDetached(["sh", "-c", cleanupCmd()])
        Qt.quit()
    }

    function finish() {
        var w = Math.round(selW())
        var h = Math.round(selH())
        if (dragging && w >= 3 && h >= 3) {
            var x = Math.round(selX())
            var y = Math.round(selY())
            var dir = Quickshell.env("HOME") + "/Pictures/screenshots"
            var f = dir + "/shot_" + Qt.formatDateTime(new Date(), "yyyyMMdd-hhmmss") + ".png"
            var geom = w + "x" + h + "+" + x + "+" + y
            // crop the FROZEN full-screen grab (bright, no dim) to the selection.
            // `magick` (not the deprecated `convert`); xclip serves the clipboard
            // as image/png and self-backgrounds to hold the selection after we quit.
            var cmd = "mkdir -p '" + dir + "'; " +
                      "magick '" + src + "' -crop " + geom + " +repage '" + f + "' && " +
                      "xclip -selection clipboard -t image/png -i '" + f + "' && " +
                      "notify-send 'Screenshot' 'Saved " + f + "  (+ clipboard)'; " +
                      cleanupCmd()
            Quickshell.execDetached(["sh", "-c", cmd])
            Qt.quit()
        } else {
            cancel()
        }
    }

    Window {
        id: win
        visible: true
        visibility: Window.FullScreen
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "#000000"
        title: "qs-region"

        Image {
            id: frozen
            anchors.fill: parent
            source: root.src !== "" ? "file://" + root.src : ""
            fillMode: Image.Stretch
            cache: false
            asynchronous: false

            Item {
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: root.cancel()

                // dim the frozen shot; selection reads brighter (the saved crop
                // comes from the un-dimmed source, so this is just a guide)
                Rectangle { anchors.fill: parent; color: "#000000"; opacity: 0.35 }

                Rectangle {
                    visible: root.dragging
                    x: root.selX(); y: root.selY()
                    width: root.selW(); height: root.selH()
                    color: "#00000000"
                    border.color: root.accent
                    border.width: 2
                }

                Text {
                    visible: root.dragging
                    x: root.selX()
                    y: Math.max(0, root.selY() - 20)
                    text: Math.round(root.selW()) + " × " + Math.round(root.selH())
                    color: "#FDF6E3"
                    font.family: "Iosevka Nerd Font"
                    font.pixelSize: 14
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.CrossCursor
                    onPressed: (m) => {
                        if (m.button === Qt.RightButton) { root.cancel(); return }
                        root.startX = m.x; root.startY = m.y
                        root.curX = m.x; root.curY = m.y
                        root.dragging = true
                    }
                    onPositionChanged: (m) => { root.curX = m.x; root.curY = m.y }
                    onReleased: (m) => { if (m.button === Qt.LeftButton) root.finish() }
                }
            }
        }
    }
}
