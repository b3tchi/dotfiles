// Region-screenshot selector — a quickshell PanelWindow *layer*, not an
// i3-managed fullscreen window. Because it's a layer (dock) it never triggers
// an i3 fullscreen enter/exit, so there's no window-jump/flash on open or
// close, and it doesn't steal i3 keyboard focus (no keyboard-block).
//
// Launched by qs-screenshot.sh (`quickshell -p .../region`) after the wrapper
// grabs the whole screen to QS_SHOT_SRC and enters the i3 "screenshot" mode.
// The status bar stays visible on top and shows that mode (like resize), so
// NO hint strip is drawn here. This overlay only does the MOUSE selection:
// drag or tap-two-corners → crop to a file + path on the clipboard. The
// keyboard actions (Esc cancel, w whole-screen) are i3 mode bindings, since a
// dock layer doesn't reliably receive arbitrary keys.
import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    readonly property string src: Quickshell.env("QS_SHOT_SRC") ?? ""
    readonly property string accent: "#16a085"
    readonly property string wmMsg: Quickshell.env("SWAYSOCK") ? "swaymsg" : "i3-msg"

    // Bar footprint, so the confirmation strip sits above the (still-visible) bar.
    readonly property var scr: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    function envInt(n, d) { var v = parseInt(Quickshell.env(n)); return isNaN(v) ? d : v }
    readonly property bool insetActive: {
        var auto = Quickshell.env("QS_BAR_INSET_AUTO") === "1"
        return !auto || (scr !== null && scr.height >= 2 * scr.width)
    }
    readonly property int barGap: envInt("QS_BAR_HEIGHT", 27)
                                  + (insetActive ? envInt("QS_BAR_INSET_BOTTOM", 0) : 0)
                                  + (insetActive ? envInt("QS_BAR_INSET_TOP", 0) : 0)

    property real startX: 0
    property real startY: 0
    property real curX: 0
    property real curY: 0
    property bool dragging: false

    // drag OR two-tap (touch-friendly over RDP). clickState 1 = corner A placed.
    property int clickState: 0
    property real downX: 0
    property real downY: 0
    property bool moved: false
    readonly property int moveThresh: 8

    property string toastText: ""

    function selX() { return Math.min(startX, curX) }
    function selY() { return Math.min(startY, curY) }
    function selW() { return Math.abs(curX - startX) }
    function selH() { return Math.abs(curY - startY) }

    // Leave the i3/sway "screenshot" mode (returns the bar to normal), then quit.
    function exitMode() {
        Quickshell.execDetached(["sh", "-c", wmMsg + " mode default >/dev/null 2>&1"])
    }
    Timer { id: closeTimer; interval: 60; onTriggered: Qt.quit() }
    Timer { id: quitTimer; interval: 1400; onTriggered: Qt.quit() }

    function cancel() {
        Quickshell.execDetached(["sh", "-c", "rm -f '" + src + "'"])
        exitMode()
        closeTimer.start()
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
            // crop the FROZEN grab; copy the file PATH (text) to the clipboard.
            var cmd = "mkdir -p '" + dir + "'; " +
                      "magick '" + src + "' -crop " + geom + " +repage '" + f + "' && " +
                      "printf %s '" + f + "' | xclip -selection clipboard; " +
                      "rm -f '" + src + "'"
            Quickshell.execDetached(["sh", "-c", cmd])
            dragging = false
            clickState = 0
            exitMode()                 // bar back to normal now
            toastText = "Copied path  " + f
            quitTimer.start()          // keep the confirmation up briefly, then close
        } else {
            cancel()
        }
    }

    PanelWindow {
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "#000000"

        Image {
            id: frozen
            anchors.fill: parent
            source: root.src !== "" ? "file://" + root.src : ""
            fillMode: Image.Stretch
            cache: false
            asynchronous: false

            // dim the whole frozen shot
            Rectangle { anchors.fill: parent; color: "#000000"; opacity: 0.35 }

            // bright hole over the selection (un-dimmed)
            Item {
                visible: root.dragging && root.selW() > 0 && root.selH() > 0
                x: root.selX(); y: root.selY()
                width: root.selW(); height: root.selH()
                clip: true
                Image {
                    source: frozen.source
                    x: -parent.x; y: -parent.y
                    width: frozen.width; height: frozen.height
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

            // corner-A marker for two-tap mode
            Rectangle {
                visible: root.clickState === 1
                x: root.startX - 6; y: root.startY - 6
                width: 12; height: 12; radius: 6
                color: "#00000000"
                border.color: root.accent; border.width: 2
            }

            MouseArea {
                anchors.fill: parent
                enabled: root.toastText === ""
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.CrossCursor
                hoverEnabled: true
                onPressed: (m) => {
                    if (m.button === Qt.RightButton) { root.cancel(); return }
                    root.downX = m.x; root.downY = m.y
                    root.moved = false
                    if (root.clickState === 0) {
                        root.startX = m.x; root.startY = m.y
                        root.curX = m.x; root.curY = m.y
                        root.dragging = true
                    } else {
                        root.curX = m.x; root.curY = m.y
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
                    if (root.moved) root.finish()
                    else if (root.clickState === 0) root.clickState = 1
                    else { root.curX = m.x; root.curY = m.y; root.finish() }
                }
            }

            // transient "Copied path" confirmation, above the (visible) bar
            Rectangle {
                visible: root.toastText !== ""
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
