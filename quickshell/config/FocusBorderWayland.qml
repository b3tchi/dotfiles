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

        property int bw: 2    // border width
        property int br: 4    // border radius
        property color bc: "#16a085"

        // Focused window geometry (screen-relative)
        property int fx: 0
        property int fy: 0
        property int fw: 0
        property int fh: 0
        property bool borderVisible: false

        // Top border
        Rectangle {
            visible: borderOverlay.borderVisible
            x: borderOverlay.fx - borderOverlay.bw
            y: borderOverlay.fy - borderOverlay.bw
            width: borderOverlay.fw + 2 * borderOverlay.bw
            height: borderOverlay.bw
            color: borderOverlay.bc
            radius: borderOverlay.br
        }
        // Bottom border
        Rectangle {
            visible: borderOverlay.borderVisible
            x: borderOverlay.fx - borderOverlay.bw
            y: borderOverlay.fy + borderOverlay.fh
            width: borderOverlay.fw + 2 * borderOverlay.bw
            height: borderOverlay.bw
            color: borderOverlay.bc
            radius: borderOverlay.br
        }
        // Left border
        Rectangle {
            visible: borderOverlay.borderVisible
            x: borderOverlay.fx - borderOverlay.bw
            y: borderOverlay.fy
            width: borderOverlay.bw
            height: borderOverlay.fh
            color: borderOverlay.bc
        }
        // Right border
        Rectangle {
            visible: borderOverlay.borderVisible
            x: borderOverlay.fx + borderOverlay.fw
            y: borderOverlay.fy
            width: borderOverlay.bw
            height: borderOverlay.fh
            color: borderOverlay.bc
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
                        } else if (change === "focus" && e.container) {
                            borderOverlay.applyContainer(e.container)
                        } else if (change === "move" && e.container) {
                            if (e.container.focused) borderOverlay.applyContainer(e.container)
                        } else if (change === "floating" && e.container) {
                            if (e.container.focused) borderOverlay.applyContainer(e.container)
                        } else if (change === "fullscreen_mode" && e.container) {
                            if (e.container.fullscreen_mode > 0)
                                borderOverlay.borderVisible = false
                            else if (e.container.focused)
                                borderOverlay.applyContainer(e.container)
                        } else if (change === "focus" && e.current && !e.container) {
                            // Workspace focus — re-scan for focused window
                            focusScan.running = true
                        }
                    } catch(err) {}
                }
            }
            onExited: running = true
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
