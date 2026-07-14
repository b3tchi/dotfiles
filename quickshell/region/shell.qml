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

    // Two interaction modes so it works with mouse-simulated touch over RDP,
    // where a press→move→release drag often doesn't register cleanly:
    //   • drag  — press, move, release (mouse)
    //   • two-tap — tap corner A, tap corner B (touch-friendly)
    // clickState: 0 = idle, 1 = corner A placed (waiting for corner B).
    property int clickState: 0
    property real downX: 0
    property real downY: 0
    property bool moved: false
    readonly property int moveThresh: 8

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
                // Keys.onEscapePressed only fires with active focus, which a
                // frameless window may not reliably hold — back it with a
                // Shortcut (focus-independent) and grab focus on load.
                Component.onCompleted: forceActiveFocus()
                Shortcut {
                    sequences: ["Escape"]
                    onActivated: root.cancel()
                }

                // dim the whole frozen shot
                Rectangle { anchors.fill: parent; color: "#000000"; opacity: 0.35 }

                // …then punch a bright hole: a clipped copy of the frozen image
                // over the selection, at full brightness, so the selected part
                // shows un-dimmed (the crop still comes from the source file).
                Item {
                    visible: root.dragging && root.selW() > 0 && root.selH() > 0
                    x: root.selX(); y: root.selY()
                    width: root.selW(); height: root.selH()
                    clip: true
                    Image {
                        source: frozen.source
                        x: -parent.x; y: -parent.y
                        width: win.width; height: win.height
                        fillMode: Image.Stretch
                        cache: false
                    }
                }

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

                // corner-A marker for two-tap mode (touch has no hover preview)
                Rectangle {
                    visible: root.clickState === 1
                    x: root.startX - 6; y: root.startY - 6
                    width: 12; height: 12; radius: 6
                    color: "#00000000"
                    border.color: root.accent; border.width: 2
                }

                // instruction panel (top-center)
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 20
                    width: infoCol.width + 28
                    height: infoCol.height + 20
                    radius: 6
                    color: "#152024"
                    border.color: root.accent
                    border.width: 1

                    Column {
                        id: infoCol
                        anchors.centerIn: parent
                        spacing: 3
                        Text {
                            text: "Pick screenshot region"
                            color: root.accent
                            font.family: "Iosevka Nerd Font"
                            font.pixelSize: 16
                            font.bold: true
                        }
                        Text {
                            text: root.clickState === 1
                                  ? "Now tap the OPPOSITE corner to capture"
                                  : "Drag a box, or tap two opposite corners"
                            color: "#FDF6E3"
                            font.family: "Iosevka Nerd Font"
                            font.pixelSize: 14
                        }
                        Text {
                            text: "Saved to ~/Pictures/screenshots + clipboard  ·  Esc / Cancel to abort"
                            color: "#9BB0B5"
                            font.family: "Iosevka Nerd Font"
                            font.pixelSize: 12
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.CrossCursor
                    hoverEnabled: true
                    onPressed: (m) => {
                        if (m.button === Qt.RightButton) { root.cancel(); return }
                        root.downX = m.x; root.downY = m.y
                        root.moved = false
                        if (root.clickState === 0) {
                            // begin a fresh selection (drag start OR corner A)
                            root.startX = m.x; root.startY = m.y
                            root.curX = m.x; root.curY = m.y
                            root.dragging = true
                        } else {
                            root.curX = m.x; root.curY = m.y  // aiming corner B
                        }
                    }
                    onPositionChanged: (m) => {
                        root.curX = m.x; root.curY = m.y
                        if (Math.abs(m.x - root.downX) > root.moveThresh
                            || Math.abs(m.y - root.downY) > root.moveThresh)
                            root.moved = true
                    }
                    onReleased: (m) => {
                        if (m.button !== Qt.LeftButton) return
                        if (root.moved) {
                            // real drag → capture
                            root.finish()
                        } else if (root.clickState === 0) {
                            // a tap placed corner A; wait for corner B
                            root.clickState = 1
                        } else {
                            // corner B tapped → capture
                            root.curX = m.x; root.curY = m.y
                            root.finish()
                        }
                    }
                }

                // Cancel button (top-right) — declared last so it sits above the
                // selection MouseArea and consumes its own taps (touch-abort,
                // since right-click / Esc aren't available on a touchscreen).
                Rectangle {
                    id: cancelBtn
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: 20
                    width: cancelRow.width + 28
                    height: 44
                    radius: 6
                    color: cancelMa.pressed ? "#c0392b" : "#152024"
                    border.color: "#c0392b"
                    border.width: 2

                    Row {
                        id: cancelRow
                        anchors.centerIn: parent
                        spacing: 8
                        Text { text: "✕"; color: "#FDF6E3"
                               font.family: "Iosevka Nerd Font"; font.pixelSize: 18 }
                        Text { text: "Cancel"; color: "#FDF6E3"
                               font.family: "Iosevka Nerd Font"; font.pixelSize: 16 }
                    }

                    MouseArea {
                        id: cancelMa
                        anchors.fill: parent
                        onClicked: root.cancel()
                    }
                }
            }
        }
    }
}
