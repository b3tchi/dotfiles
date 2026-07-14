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

    // Status-bar geometry, forwarded from the running bar by qs-screenshot.sh,
    // so the overlay's mode strip lands exactly on the bar's pill. The bar draws
    // as a pill offset up by QS_BAR_INSET_BOTTOM (with a black chin below);
    // QS_BAR_INSET_AUTO engages that only on a phone-shaped viewport (height >=
    // 2*width — mirrors Session.insetActive). Overlay window is #000000, so the
    // chin area under the strip matches the bar's black chin.
    readonly property var scr: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    function envInt(n, d) { var v = parseInt(Quickshell.env(n)); return isNaN(v) ? d : v }
    readonly property bool insetActive: {
        var auto = Quickshell.env("QS_BAR_INSET_AUTO") === "1"
        return !auto || (scr !== null && scr.height >= 2 * scr.width)
    }
    readonly property int barHeight:  envInt("QS_BAR_HEIGHT", 27)
    readonly property int insetBottom: insetActive ? envInt("QS_BAR_INSET_BOTTOM", 0) : 0
    readonly property int insetTop:    insetActive ? envInt("QS_BAR_INSET_TOP", 0) : 0
    // full bottom footprint of the bar (pill + chin), for lifting things clear
    readonly property int barGap: barHeight + insetBottom + insetTop

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

    // Transient confirmation shown in-overlay (like tmux's display-message) —
    // deliberately NOT a desktop notification, so nothing lands under the bell.
    property string toastText: ""

    function cleanupCmd() { return "rm -f '" + src + "'" }

    function cancel() {
        Quickshell.execDetached(["sh", "-c", cleanupCmd()])
        Qt.quit()
    }

    Timer { id: quitTimer; interval: 1400; onTriggered: Qt.quit() }

    function finish() {
        var w = Math.round(selW())
        var h = Math.round(selH())
        if (dragging && w >= 3 && h >= 3) {
            var x = Math.round(selX())
            var y = Math.round(selY())
            var dir = Quickshell.env("HOME") + "/Pictures/screenshots"
            var f = dir + "/shot_" + Qt.formatDateTime(new Date(), "yyyyMMdd-hhmmss") + ".png"
            var geom = w + "x" + h + "+" + x + "+" + y
            // crop the FROZEN full-screen grab (bright, no dim) to the selection
            // (`magick`, not the deprecated `convert`), then copy the file PATH
            // (text) to the clipboard — like tmux copy — so it can be pasted
            // anywhere; xclip self-backgrounds to hold the selection after we quit.
            var cmd = "mkdir -p '" + dir + "'; " +
                      "magick '" + src + "' -crop " + geom + " +repage '" + f + "' && " +
                      "printf %s '" + f + "' | xclip -selection clipboard; " +
                      cleanupCmd()
            Quickshell.execDetached(["sh", "-c", cmd])
            // show the confirmation briefly on the frozen shot, then close
            toastText = "Copied path  " + f
            quitTimer.start()
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

        // Grab WM activation so keyboard events (Esc) actually reach us — a
        // frameless fullscreen window doesn't always get input focus on its own.
        Component.onCompleted: requestActivate()

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
                    context: Qt.ApplicationShortcut
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

                // instruction bar — styled to match the i3 mode indicator in the
                // status bar (orange "screenshot" label + underline, then
                // key/label hint chips), but drawn here in the overlay itself.
                Rectangle {
                    visible: root.toastText === ""
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: root.insetBottom
                    width: parent.width
                    height: root.barHeight
                    color: "#152024"
                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0

                        Rectangle {
                            width: modeLabel.implicitWidth + 14
                            height: 27
                            color: "#152024"
                            Text {
                                id: modeLabel
                                anchors.centerIn: parent
                                text: "screenshot"
                                color: "#fdf6e3"
                                font.family: "Iosevka Nerd Font"
                                font.pixelSize: 16
                            }
                            Rectangle {
                                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                                height: 3
                                color: "#cb4b16"
                            }
                        }
                        Item { width: 10; height: 27 }

                        Repeater {
                            model: root.clickState === 1
                                   ? [{key: "tap", label: "opposite corner"}, {key: "Esc", label: "cancel"}]
                                   : [{key: "drag", label: "select region"}, {key: "2-tap", label: "corners"}, {key: "Esc", label: "cancel"}]
                            Row {
                                required property var modelData
                                required property int index
                                anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                                Text { text: index > 0 ? "   " : ""; font.pixelSize: 16 }
                                Text {
                                    text: modelData.key; color: "#cb4b16"; font.bold: true
                                    font.family: "Iosevka Nerd Font"; font.pixelSize: 16
                                }
                                Text { text: " "; font.pixelSize: 16 }
                                Text {
                                    text: modelData.label; color: "#fdf6e3"
                                    font.family: "Iosevka Nerd Font"; font.pixelSize: 16
                                }
                            }
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

                // Transient confirmation — a slim bottom strip (like i3's
                // resize-mode indicator), shown for ~1.4s then the overlay
                // closes. Full-screen MouseArea swallows stray input meanwhile.
                MouseArea {
                    anchors.fill: parent
                    visible: root.toastText !== ""
                    enabled: visible
                    Rectangle {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: root.barGap
                        width: parent.width
                        height: strip.implicitHeight + 12
                        color: "#152024"
                        Text {
                            id: strip
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            text: "✓ " + root.toastText
                            color: root.accent
                            font.family: "Iosevka Nerd Font"
                            font.pixelSize: 13
                        }
                    }
                }
            }
        }
    }
}
