import Quickshell
import Quickshell.Io
import QtQuick

// Full-screen transparent overlay that draws a green border around the
// focused window on sway/Wayland.  Uses layer-shell (PanelWindow) on the
// overlay layer, fully click-through.  Position comes from sway IPC.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: borderOverlay
        required property var modelData
        screen: modelData

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        aboveWindows: true
        exclusiveZone: 0
        focusable: false
        color: "transparent"

        mask: Region {}   // empty = fully click-through

        property int bw: 2    // border width (matches xborders)
        property int br: 4    // border radius
        property color bc: "#16a085"

        // Focused window geometry (screen-relative)
        property int fx: 0
        property int fy: 0
        property int fw: 0
        property int fh: 0
        property bool borderVisible: false

        // Border via Rectangle with rounded corners — immediate rendering
        // (Canvas defers to next paint cycle, adding visible delay)
        // Offset inward by 2px to overlay sway's native border
        property int inset: 2
        Rectangle {
            visible: borderOverlay.borderVisible
            x: borderOverlay.fx - borderOverlay.bw + borderOverlay.inset
            y: borderOverlay.fy - borderOverlay.bw + borderOverlay.inset
            width: borderOverlay.fw + 2 * borderOverlay.bw - 2 * borderOverlay.inset
            height: borderOverlay.fh + 2 * borderOverlay.bw - 2 * borderOverlay.inset
            color: "transparent"
            border.color: borderOverlay.bc
            border.width: borderOverlay.bw
            radius: borderOverlay.br
        }

        // Subscribe to sway window/workspace events
        Process {
            id: swaySubscribe
            running: true
            command: ["swaymsg", "-t", "subscribe", "-m", "[\"window\",\"workspace\"]"]
            stdout: SplitParser {
                onRead: data => {
                    try {
                        var e = JSON.parse(data)
                        var change = e.change
                        if (change === "close") {
                            borderOverlay.borderVisible = false
                        } else if (change === "fullscreen_mode" && e.container) {
                            if (e.container.fullscreen_mode > 0)
                                borderOverlay.borderVisible = false
                            else if (e.container.focused)
                                borderOverlay.applyContainer(e.container)
                        } else if (e.container && e.container.focused) {
                            // Instant update from event data (focus, move, floating)
                            borderOverlay.applyContainer(e.container)
                        } else {
                            // Workspace switch or event without container — rescan
                            focusScan.running = true
                        }
                    } catch(err) {}
                }
            }
            onExited: running = true
        }

        // Track sway resize/move mode to poll geometry during interactive ops
        Process {
            id: modeSubscribe
            running: true
            command: ["swaymsg", "-t", "subscribe", "-m", "[\"mode\"]"]
            stdout: SplitParser {
                onRead: data => {
                    try {
                        var e = JSON.parse(data)
                        if (e.change === "resize")
                            resizePoller.running = true
                        else
                            resizePoller.running = false
                    } catch(err) {}
                }
            }
            onExited: running = true
        }

        // Poll during keyboard resize mode
        Timer {
            id: resizePoller
            interval: 20
            repeat: true
            onTriggered: focusScan.running = true
        }

        // Continuous light poll to catch mouse drag/resize (no sway events during these)
        // Only runs while border is visible; stops when geometry is stable for 1s
        property int lastFx: 0
        property int lastFy: 0
        property int lastFw: 0
        property int lastFh: 0
        property int stableCount: 0

        Timer {
            id: dragPoller
            interval: 100
            repeat: true
            running: borderOverlay.borderVisible
            onTriggered: {
                if (borderOverlay.fx === borderOverlay.lastFx &&
                    borderOverlay.fy === borderOverlay.lastFy &&
                    borderOverlay.fw === borderOverlay.lastFw &&
                    borderOverlay.fh === borderOverlay.lastFh) {
                    borderOverlay.stableCount++
                    // Geometry stable for 1s — slow down to save resources
                    if (borderOverlay.stableCount > 10)
                        dragPoller.interval = 1000
                } else {
                    borderOverlay.stableCount = 0
                    dragPoller.interval = 100
                    borderOverlay.lastFx = borderOverlay.fx
                    borderOverlay.lastFy = borderOverlay.fy
                    borderOverlay.lastFw = borderOverlay.fw
                    borderOverlay.lastFh = borderOverlay.fh
                }
                focusScan.running = true
            }
        }


        // Scan tree for currently focused window (startup + workspace switch)
        Process {
            id: focusScan
            running: true
            property string buf: ""
            command: ["swaymsg", "-t", "get_tree"]
            stdout: SplitParser {
                onRead: data => { focusScan.buf += data }
            }
            onExited: {
                try {
                    var tree = JSON.parse(focusScan.buf)
                    var found = false
                    function walk(node) {
                        if (found) return
                        if (node.focused && node.pid) {
                            borderOverlay.applyContainer(node)
                            found = true
                            return
                        }
                        var children = (node.nodes || []).concat(node.floating_nodes || [])
                        for (var i = 0; i < children.length; i++) walk(children[i])
                    }
                    walk(tree)
                    if (!found) borderOverlay.borderVisible = false
                } catch(err) {}
                focusScan.buf = ""
            }
        }

        readonly property var ignoreAppIds: ["quickshell", "rofi"]

        function applyContainer(c) {
            var appId = c.app_id || ""
            var title = c.name || ""
            if (ignoreAppIds.indexOf(appId) >= 0 || title.startsWith("qs-"))  {
                borderVisible = false
                return
            }
            if (c.fullscreen_mode > 0) {
                borderVisible = false
                return
            }
            var r = c.rect || {}
            var decoH = (c.deco_rect || {}).height || 0
            fx = r.x || 0
            fy = (r.y || 0) - decoH
            fw = r.width || 0
            fh = (r.height || 0) + decoH
            borderVisible = (fw > 0 && fh > 0)
        }
    }
}
