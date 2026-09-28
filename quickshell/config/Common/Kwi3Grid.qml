pragma Singleton
import Quickshell
import QtQuick
import "."

// Kwi3Grid (sp004 Task 12, kwi3-234.12; ft008 kwi3-grid-feed) — the one place
// the dotfiles' bar and runners read kwi3's character-cell grid from, over
// Kwi3Client's `grid.get`. Consumers: Bar (Task 13), the runners (Task 14).
//
// Under a real i3/sway session `Kwi3Client.available` stays false forever,
// `active` never becomes true, and every numeric property keeps its zero
// default — a consumer's OWN pre-existing default (today's `Session.qml` /
// `DialogTheme.qml` literals) is what actually renders. This singleton never
// invents a fallback grid of its own; that would be a second place kwi3's
// numbers could drift from, which is the exact thing ft008 exists to avoid.
Singleton {
    id: grid

    // ---- ft008 api_surface ------------------------------------------
    readonly property bool active: _loaded

    property int moduleW: 0
    property int moduleH: 0
    property int rowHeight: 0        // one titlebar row (core/defaults.js's HEADER)
    property int edgeMargin: 0
    property int reserve: 0
    property int contentLeft: 0
    property string fontFamily: ""
    property int fontPixelSize: 0
    property var colors: ({})
    // kwi3-55l.20: the window focus ring's own config (core/defaults.js
    // FRAME_THICKNESS/FRAME_RADIUS/FRAME_COLOR/FRAME, grid.get's `frame`
    // field) - so a consumer that mirrors the ring (Bar's focused-tab
    // highlight) never carries its own literal and stays off exactly when
    // the window ring is off (focusFrame: false).
    property int frameThickness: 0
    property int frameRadius: 0
    property string frameColor: "#000000"
    property bool frameEnabled: false

    // Whole-module sizing for a client's own width AND height: the same
    // function serves both axes because the caller passes the axis's own
    // cell size (`moduleW` for a width, `moduleH` for a height) as `cell`;
    // it defaults to `moduleW` so a bare `cells(px)` still does something
    // sane before a caller picks an axis. Never rounds down to zero cells.
    function cells(px, cell) {
        var c = (cell === undefined) ? grid.moduleW : cell
        if (!(c > 0)) { return 0 }
        return Math.max(1, Math.round(px / c))
    }

    // ---- internal state -----------------------------------------------
    property bool _loaded: false
    property bool _retryPending: false

    // ft008: "retried until kwi3 answers". A `grid.get` can fail transiently
    // (the request raced a connection that dropped right after `available`
    // flipped true) without kwi3 itself being gone — that gets one more try
    // shortly, not a permanent give-up; a real "gone" is Kwi3Client's own
    // reconnect loop, which flips `available` false and is handled below.
    function refresh() {
        if (!Kwi3Client.available) { return }
        Kwi3Client.call("grid.get", undefined, function (err, result) {
            if (err || !result) {
                if (!grid._retryPending) {
                    grid._retryPending = true
                    _retryTimer.restart()
                }
                return
            }
            grid.moduleW = result.module.w
            grid.moduleH = result.module.h
            grid.rowHeight = result.row
            grid.edgeMargin = result.edgeMargin
            grid.reserve = result.reserve
            grid.contentLeft = result.contentLeft
            grid.fontFamily = result.font.family
            grid.fontPixelSize = result.font.pixelSize
            grid.colors = result.colors
            // `frame` is guarded (not just destructured) so an older kwi3
            // that has not yet grown this field still loads the rest of the
            // grid instead of throwing out of this callback.
            if (result.frame) {
                grid.frameThickness = result.frame.thickness
                grid.frameRadius = result.frame.radius
                grid.frameColor = result.frame.color
                grid.frameEnabled = result.frame.enabled
            }
            grid._loaded = true
        })
    }

    Timer {
        id: _retryTimer
        interval: 500
        repeat: false
        onTriggered: {
            grid._retryPending = false
            grid.refresh()
        }
    }

    Connections {
        target: Kwi3Client
        function onAvailableChanged() {
            if (Kwi3Client.available) {
                grid.refresh()
            } else {
                // A dropped connection invalidates the last answer — a stale
                // grid.active==true with numbers from a server that is gone
                // would be worse than an honest "not active yet".
                grid._loaded = false
            }
        }
    }

    Component.onCompleted: {
        // `grid.changed` is emitted by core/rpc.js's rpcGridDiff()
        // (kwi3-234.19) whenever what grid.get answers changes, e.g. a
        // configure() re-run. Kwi3Client re-subscribes it on every
        // reconnect. test-kwi3-backend.sh PHASE 5 drives this end to end.
        Kwi3Client.on("grid.changed", function () { grid.refresh() })
        if (Kwi3Client.available) { grid.refresh() }
    }
}
