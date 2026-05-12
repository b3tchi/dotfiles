import Quickshell
import Quickshell.Io
import QtQuick

// Full-screen transparent overlay that dims everything outside the focused
// window on sway/Wayland.  Uses layer-shell (PanelWindow) on the overlay
// layer, fully click-through.  Position comes from sway IPC.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: dimOverlay
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

        property int fx: 0
        property int fy: 0
        property int fw: 0
        property int fh: 0
        property bool hasFocus: false
        readonly property string dimColor: "#4D000000"   // 30% black

        // Top — full width; collapses to zero when hasFocus and fy==0
        Rectangle {
            color: dimOverlay.dimColor
            x: 0; y: 0
            width: parent.width
            height: dimOverlay.hasFocus ? Math.max(0, dimOverlay.fy) : parent.height
        }
        // Bottom — hidden when no focused window
        Rectangle {
            visible: dimOverlay.hasFocus
            color: dimOverlay.dimColor
            x: 0
            y: dimOverlay.fy + dimOverlay.fh
            width: parent.width
            height: Math.max(0, parent.height - (dimOverlay.fy + dimOverlay.fh))
        }
        // Left — hidden when no focused window
        Rectangle {
            visible: dimOverlay.hasFocus
            color: dimOverlay.dimColor
            x: 0
            y: dimOverlay.fy
            width: Math.max(0, dimOverlay.fx)
            height: dimOverlay.fh
        }
        // Right — hidden when no focused window
        Rectangle {
            visible: dimOverlay.hasFocus
            color: dimOverlay.dimColor
            x: dimOverlay.fx + dimOverlay.fw
            y: dimOverlay.fy
            width: Math.max(0, parent.width - (dimOverlay.fx + dimOverlay.fw))
            height: dimOverlay.fh
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
                            // Always recalc on close. The closed window may
                            // not be the one the dim is drawn around, and
                            // even if it is, sway moves focus to the next
                            // window — focusScan finds it. Unconditional hide
                            // killed the dim on switcher-close races and
                            // left a dead dim between focus events here.
                            focusScan.running = true
                        } else if (change === "fullscreen_mode" && e.container) {
                            if (e.container.fullscreen_mode > 0)
                                dimOverlay.hasFocus = false
                            else
                                focusScan.running = true
                        } else if (change === "floating") {
                            // Tiled↔floating toggle — re-walk tree to propagate in_floating
                            focusScan.running = true
                        } else if (e.container && e.container.focused) {
                            // Re-walk tree so in_floating is correctly propagated
                            focusScan.running = true
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
        // Only runs while dim is visible; stops when geometry is stable for 1s
        property int lastFx: 0
        property int lastFy: 0
        property int lastFw: 0
        property int lastFh: 0
        property int stableCount: 0

        Timer {
            id: dragPoller
            interval: 100
            repeat: true
            running: dimOverlay.hasFocus
            onTriggered: {
                if (dimOverlay.fx === dimOverlay.lastFx &&
                    dimOverlay.fy === dimOverlay.lastFy &&
                    dimOverlay.fw === dimOverlay.lastFw &&
                    dimOverlay.fh === dimOverlay.lastFh) {
                    dimOverlay.stableCount++
                    // Geometry stable for 1s — slow down to save resources
                    if (dimOverlay.stableCount > 10)
                        dragPoller.interval = 1000
                } else {
                    dimOverlay.stableCount = 0
                    dragPoller.interval = 100
                    dimOverlay.lastFx = dimOverlay.fx
                    dimOverlay.lastFy = dimOverlay.fy
                    dimOverlay.lastFw = dimOverlay.fw
                    dimOverlay.lastFh = dimOverlay.fh
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
                    function walk(node, in_floating) {
                        if (found) return
                        if (node.focused && node.pid) {
                            dimOverlay.applyContainer(node, in_floating)
                            found = true
                            return
                        }
                        var tiled = node.nodes || []
                        for (var i = 0; i < tiled.length; i++) walk(tiled[i], in_floating)
                        var floating = node.floating_nodes || []
                        for (var j = 0; j < floating.length; j++) walk(floating[j], true)
                    }
                    walk(tree, false)
                    if (!found) dimOverlay.hasFocus = false
                } catch(err) {}
                focusScan.buf = ""
            }
        }

        readonly property var ignoreAppIds: ["quickshell"]

        function applyContainer(c, in_floating) {
            var appId = c.app_id || ""
            var cls = (c.window_properties || {}).class || ""
            var title = c.name || ""

            if (c.fullscreen_mode > 0) {
                hasFocus = false
                return
            }
            // Floating windows and qs- titled windows bypass class-based ignore
            if (!in_floating && !title.startsWith("qs-")) {
                if (ignoreAppIds.indexOf(appId) >= 0 || ignoreAppIds.indexOf(cls) >= 0) {
                    hasFocus = false
                    return
                }
            }
            var r = c.rect || {}
            var decoH = (c.deco_rect || {}).height || 0
            fx = r.x || 0
            fy = (r.y || 0) - decoH
            fw = r.width || 0
            fh = (r.height || 0) + decoH
            hasFocus = (fw > 0 && fh > 0)
        }
    }
}
