import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import "./Common"

// Region screenshot selector for a KWin (Wayland) session: qs-region.py's
// twin, which is X11-only (an X Shape window, scrot, xclip). Same gesture and
// the same look - the live desktop under a 2px #cb4b16 band, no dim - and the
// same keys: drag, or tap two corners, for a region; `w` the focused window,
// `d` the whole screen; Esc / `q` / right-click cancel.
//
// Hosted in the main instance and opened by `qs-screenshot.sh` through
// `qs-overlay.sh region` (IpcHandler "regionshot" below). It signals the same
// hotkeyd layers the X11 pair does, so the bar's hint strip and the focus
// ring follow the gesture: "screenshot" while aiming, "screenshot-drag" once
// a region is started, "default" when it ends - here, since no launcher
// script outlives this one.
//
// The capture is KWin's own ScreenShot2 through kwi3-shot (KWin has no
// wlr-screencopy for grim), taken AFTER the band is gone and the layer is
// cleared, so neither the band nor the hint strip lands in the shot.
Scope {
    id: root

    readonly property color accent: "#cb4b16"   // qs-region.py ACCENT_HEX
    readonly property int bw: 2                 // qs-region.py BW
    readonly property int minSel: 3             // qs-region.py MIN_SEL
    readonly property string hotkeyd: Quickshell.env("HOME") + "/.dotfiles/hotkeyd/hotkeyd"
    readonly property string shot: Quickshell.env("HOME") + "/.local/bin/kwi3-shot"

    property bool open: false
    property bool dragging: false
    property int clicks: 0          // 2-tap mode: 1 = corner A placed
    property var pickScreen: null   // the screen the region is drawn on
    property real x0: 0
    property real y0: 0
    property real x1: 0
    property real y1: 0
    property var pending: null      // [x, y, w, h], global logical px

    // The selection, normalised and clipped to its screen (qs-region.py
    // normalise()).
    readonly property rect sel: {
        var s = pickScreen
        if (!s) return Qt.rect(0, 0, 0, 0)
        var l = Math.max(0, Math.min(x0, x1)), t = Math.max(0, Math.min(y0, y1))
        var r = Math.min(s.width, Math.max(x0, x1)), b = Math.min(s.height, Math.max(y0, y1))
        return Qt.rect(Math.round(l), Math.round(t), Math.max(0, Math.round(r - l)), Math.max(0, Math.round(b - t)))
    }

    function setLayer(name) {
        layerProc.command = [hotkeyd, "set-layer", name]
        layerProc.running = true
    }

    function start() {
        if (open || shotProc.running) return
        dragging = false
        clicks = 0
        pickScreen = null
        pending = null
        open = true
        setLayer("screenshot")
    }

    function finish(area) {
        if (!open) return
        open = false
        dragging = false
        pending = area
        setLayer("default")
        // The band's surface and the hint strip must be off the screen before
        // KWin is asked for pixels.
        if (area) captureDelay.restart()
    }

    function shootRegion(screen) {
        var r = sel
        if (r.width < minSel || r.height < minSel) return false
        finish([screen.x + r.x, screen.y + r.y, r.width, r.height])
        return true
    }

    function shootScreen(screen) {
        finish([screen.x, screen.y, screen.width, screen.height])
    }

    // `w`: the focused window's rect from kwi3's tree, as qs-region.py's
    // focused_window_rect() reads it - this surface is never in that tree.
    function shootWindow() {
        if (!Kwi3Client.available) { finish(null); return }
        Kwi3Client.call("tree.get", undefined, function (err, tree) {
            function walk(n) {
                if (n.focused && n.window) return n
                var kids = (n.nodes || []).concat(n.floating_nodes || [])
                for (var i = 0; i < kids.length; i++) {
                    var f = walk(kids[i])
                    if (f) return f
                }
                return null
            }
            var leaf = err ? null : walk(tree)
            var r = leaf ? leaf.rect : null
            if (!r || !(r.width > 0) || !(r.height > 0)) {
                console.warn("regionshot: no focused window to capture")
                finish(null)
                return
            }
            finish([r.x, r.y, r.width, r.height])
        })
    }

    Process { id: layerProc }

    Timer {
        id: captureDelay
        interval: 150
        onTriggered: {
            var a = root.pending
            root.pending = null
            if (!a) return
            shotProc.command = [root.shot, "-a"].concat(a.map(function (v) { return String(Math.round(v)) }))
            shotProc.running = true
        }
    }

    Process {
        id: shotProc
        stdout: SplitParser { onRead: data => console.log("regionshot: saved " + data) }
        stderr: SplitParser { onRead: data => console.warn("regionshot: " + data) }
    }

    IpcHandler {
        target: "regionshot"
        function open(): void { root.start() }
        function cancel(): void { root.finish(null) }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            visible: root.open
            color: "transparent"
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "qs-region"
            WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            readonly property bool mine: root.pickScreen === modelData

            Rectangle {
                visible: win.mine && root.dragging
                x: root.sel.x
                y: root.sel.y
                width: root.sel.width
                height: root.sel.height
                color: "transparent"
                border.color: root.accent
                border.width: root.bw
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                cursorShape: Qt.CrossCursor
                hoverEnabled: true
                onPressed: mouse => {
                    if (mouse.button !== Qt.LeftButton) { root.finish(null); return }
                    if (root.clicks === 0) {
                        root.pickScreen = win.modelData
                        root.x0 = root.x1 = mouse.x
                        root.y0 = root.y1 = mouse.y
                        root.dragging = true
                        // The ring around the focused window ("this is what
                        // `w` captures") is stale once a region is drawn.
                        root.setLayer("screenshot-drag")
                    } else if (win.mine) {
                        root.x1 = mouse.x
                        root.y1 = mouse.y
                    }
                }
                onPositionChanged: mouse => {
                    if (!root.dragging || !win.mine) return
                    root.x1 = mouse.x
                    root.y1 = mouse.y
                }
                onReleased: mouse => {
                    if (mouse.button !== Qt.LeftButton || !root.dragging || !win.mine) return
                    root.x1 = mouse.x
                    root.y1 = mouse.y
                    if (root.shootRegion(win.modelData)) return
                    if (root.clicks === 0) root.clicks = 1   // a tap: wait for corner B
                    else root.finish(null)
                }
            }

            Item {
                anchors.fill: parent
                focus: true
                Keys.onPressed: event => {
                    var k = event.key
                    if (k === Qt.Key_Escape || k === Qt.Key_Q) root.finish(null)
                    else if (k === Qt.Key_W) root.shootWindow()
                    else if (k === Qt.Key_D) root.shootScreen(win.modelData)
                    event.accepted = true
                }
            }
        }
    }
}
