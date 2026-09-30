import Quickshell
import Quickshell.I3
import Quickshell.Io
import Quickshell.Services.SystemTray
import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import "./Common"

PanelWindow {
    id: root

    // ---------------------------------------------------------- notifications ---
    // Read-only consumer of the notif-service daemon's live-state file
    // (sp019 Task 4, dotfiles-c5fd.4). The daemon
    // (quickshell/notif/shell.qml, Task 2) is the ONLY NotificationServer
    // left in this repo — every bar just tails its state file, the same
    // daemonMode source-model already used for qs-stats below. relativeTime
    // moved here from the old per-bar shell.qml host (it belongs wherever
    // the epoch -> "-Ns"/"-Nm"/"HH:MM" text is actually rendered).
    property int notifCount: 0
    property string notifText: ""
    property int notifSeq: 0
    property bool hasCritical: false

    function relativeTime(ms) {
        var s = Math.floor((Date.now() - ms) / 1000)
        if (s < 60) return "-" + s + "s"
        var m = Math.floor(s / 60)
        if (m < 60) return "-" + m + "m"
        var d = new Date(ms)
        return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
    }

    readonly property string notifFile: Quickshell.env("QS_NOTIF_FILE")
        || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/qs-notif.state")
    readonly property string notifFifo: Quickshell.env("QS_NOTIF_FIFO")
        || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/qs-notif.cmd")

    // Fields for the state-file rewrite CURRENTLY being read: the daemon
    // always writes count/critical/seq/last as four separate lines in that
    // fixed order (qs-notif-store.sh's `state` verb), but `-F` delivers
    // them to this Process as four separate reads. Committing notifSeq and
    // notifText together only once the LAST line arrives (always "last",
    // always the final line the store writes) means the seq-bump check
    // right below always sees THIS rewrite's own new text, never the
    // previous one's — count/critical have no such ordering hazard (they
    // gate nothing) and are set immediately, idempotently, per line.
    property int _notifPendingSeq: 0

    // No daemon probe/retry here (unlike qs-stats' daemonMode): an absent
    // state file simply feeds nothing and the bar boots clean — count 0,
    // no ticker, muted-grey bell.
    Process {
        id: notifFeedProc
        running: true
        // -F follows across the daemon's atomic tmp+rename swaps and
        // re-emits the whole (complete-state) file each time; every set
        // below is idempotent, so a mid-swap re-read is harmless.
        command: ["sh", "-c", "exec tail -n +1 -F " + root.notifFile + " 2>/dev/null"]
        stdout: SplitParser {
            onRead: data => {
                var line = data.trim()
                var sp = line.indexOf(" ")
                if (sp < 0) return
                var key = line.substring(0, sp)
                var rest = line.substring(sp + 1)
                if (key === "count") {
                    root.notifCount = parseInt(rest, 10) || 0
                } else if (key === "critical") {
                    root.hasCritical = (rest.trim() === "1")
                } else if (key === "seq") {
                    root._notifPendingSeq = parseInt(rest, 10) || 0
                } else if (key === "last") {
                    // Only the FIRST tab splits epoch from text — a stray
                    // literal tab further into the text stays part of it.
                    var tab = rest.indexOf("\t")
                    if (tab < 0) return
                    var epoch = parseInt(rest.substring(0, tab), 10)
                    var text = rest.substring(tab + 1)
                    var newText = isNaN(epoch) ? text : (root.relativeTime(epoch * 1000) + "  " + text)
                    var seqChanged = root._notifPendingSeq !== root.notifSeq

                    root.notifText = newText
                    root.notifSeq = root._notifPendingSeq

                    // Only a CHANGED seq restarts the ticker — a
                    // dismiss/staterefresh rewrite that keeps the same seq
                    // re-asserts the same properties without a second
                    // animation (seq-gate-no-double-ticker).
                    if (seqChanged && newText !== "") {
                        tickerAnim.stop()
                        root.tickerActive = true
                        tickerStartDelay.restart()
                    }
                }
            }
        }
        onExited: notifFeedRestart.restart()
    }
    Timer { id: notifFeedRestart; interval: 2000; onTriggered: notifFeedProc.running = true }

    // Ticker click and bell click both ask the daemon to drop the newest
    // tracked notification — a one-shot fire-and-forget FIFO write (the
    // volToggleMute pattern further down). `timeout` bounds the open+write
    // so a dead daemon (no FIFO reader) never hangs this Process; the bell
    // count only decrements once the daemon's own state rewrite comes back
    // around through notifFeedProc above, never optimistically here.
    Process {
        id: notifDismiss
        command: ["timeout", "2", "sh", "-c",
            "printf '%s\\n' 'dismiss latest' > \"$1\" 2>/dev/null", "_", root.notifFifo]
    }
    function requestDismiss() { notifDismiss.running = true }

    // WM detection — sway uses same IPC as i3
    readonly property bool isSway: Session.isSway
    readonly property string wmMsg: isSway ? "swaymsg" : "i3-msg"

    // Per-session + per-screen widget density (Session.qml): gates the wide
    // stats block so a narrow xrdp viewport / small monitor stays uncluttered.
    readonly property string density: Session.densityFor(screen ? screen.width : 1920)
    readonly property bool showNet:  density === "full"
    readonly property bool showDisk: density === "full"
    readonly property bool showCpu:  density !== "minimal"
    readonly property bool showRam:  density !== "minimal"

    // Ticker state
    property bool tickerActive: false

    Timer {
        id: tickerStartDelay
        interval: 0
        onTriggered: {
            tickerText.x = tickerArea.width
            tickerAnim.restart()
        }
    }

    // Bar sits at the top on every session type (desktop + phone).
    anchors {
        left: true
        right: true
        top: true
    }

    // X11 inset pill (rounded display corners): PanelWindow margins are a
    // Wayland/layer-shell feature and a NO-OP on X11, so instead the window
    // grows by the inset and the bar is drawn as an inset pill inside it.
    // The bar is anchored at the TOP; the bottom rounded-corner clearance
    // (Razr chin) is a separate strut-reserving panel — see BarChin.qml — so
    // app windows stay clear of the physical bottom corners while the bar
    // lives at the top. Only side/top insets shape the bar itself here.
    // Tunable via env: QS_BAR_INSET_SIDE / QS_BAR_INSET_TOP (bottom clearance
    // via QS_BAR_INSET_BOTTOM is consumed by BarChin). With QS_BAR_INSET_AUTO=1
    // the inset engages only while the viewport is phone-shaped (taller than
    // 2:1) — reactive to screen size, so an xrdp reconnect from a monitor
    // client flattens everything without a restart.
    readonly property bool insetOn: Session.insetActive(
        screen ? screen.width : 1920, screen ? screen.height : 1080)
    readonly property int insetSide:   insetOn ? Session.insetSide : 0
    readonly property int insetTop:    insetOn ? Session.insetTop : 0
    readonly property bool inset: insetSide > 0 || insetTop > 0

    // sp004 Task 13 (kwi3-234.13; ft008 kwi3-grid-feed): under kwi3 the bar's
    // own height, band and exclusive zone come off Kwi3Grid instead of
    // Session's literals — Kwi3Grid.active stays false for every session
    // this spec does not touch (no $KWI3SOCK), so Session.barHeight is still
    // exactly what renders there (AC3).
    implicitHeight: (Kwi3Grid.active ? Kwi3Grid.rowHeight : Session.barHeight) + insetTop

    // Phone (sxmo, sway/Wayland): floating pill at the top via real
    // layer-shell margins; desktop (i3/sway): full-width top bar. On X11 use
    // QS_BAR_INSET_* instead.
    //
    // kwi3 (kwi3-55l.17, Jan: "1/2 gap then bar then 1/2 gap"): the bar is
    // the vertical exception to the tile gap rule - half the visible tile
    // gap above it, the bar, the other half below it, then the first
    // titlebar. kwi3 serves the top half as grid.get's `edgeMargin` (the
    // spare pixel of an odd module goes above), and Quickshell's X11
    // PanelWindow places the window that far down (it did for i3kwin/bar,
    // kwi3-12f, and bar-follows-focus-x11-e2e.sh reads the y back off the
    // server). The strut stays exclusiveZone = `reserve` below, measured
    // from the screen edge, so the tiles do not move; the bottom half is
    // simply what is left between the bar and kwi3's own top margin.
    readonly property bool isPhone: Session.isPhone
    margins {
        top:   isPhone ? 20 : (Kwi3Grid.active ? Kwi3Grid.edgeMargin : 0)
        left:  isPhone ? 40 : 0
        right: isPhone ? 40 : 0
    }

    // kwi3's own reserve already counts its margin band on top of the bar's
    // row (kwi3-at2's `reserve` field) — reusing it here rather than adding
    // the two ourselves keeps this bar and every tile agreeing with the same
    // one number kwi3 serves. -1 is PanelWindow's own "auto" (matches
    // implicitHeight), which is what every non-kwi3 session already got
    // before this property existed.
    exclusiveZone: Kwi3Grid.active ? Kwi3Grid.reserve : -1

    readonly property color barColor: "#000000"
    // Black surround: blends into the Razr's bezel/chin so the pill reads as
    // floating on the hardware edge rather than on a colored strip.
    color: inset ? "#000000" : barColor

    readonly property string fontFamily: Kwi3Grid.active ? Kwi3Grid.fontFamily : "Iosevka Nerd Font"
    readonly property int fontSize: Kwi3Grid.active ? Kwi3Grid.fontPixelSize : Session.fontSize
    // kwi3-55l.18: was Text.NativeRendering. Jan (3392, real use): "the
    // bar's font looks slightly bigger than the other fonts (kwi3 window
    // titlebars, terminal)". Both sides already share font.family/
    // font.pixelSize verbatim (core/defaults.js FONT_FAMILY/FONT_PIXEL_SIZE,
    // no point/pixel conversion anywhere) and paint the SAME logical
    // contentWidth either way — this was purely a rasterizer choice, and
    // i3kwin/chrome/Decoration.qml's titlebar text sets no renderType at
    // all (QtQuick's own default, Text.QtRendering). Measured (not
    // guessed): rendering the identical string/family/pixelSize/colour/
    // weight pair through a real X11 (xcb) backend and diffing the painted
    // pixels showed NativeRendering paints measurably more ink than
    // QtRendering on Jan's own focused palette (#fdf6e3 on #152024, bold) —
    // see test-bar-font-render.sh. Matching the chrome's implicit default
    // here is what makes the two agree.
    readonly property int nativeRender: Text.QtRendering

    // dotfiles-rlnv: kwi3's character cell (Kwi3Grid.moduleW x moduleH; 0 off
    // kwi3 where Kwi3Grid never activates). cellW > 0 => the right side (stats,
    // VOL/KBL, tray, bell, clock/date) is laid out in whole cells, like the
    // workspace tabs and the mode strip (dotfiles-puoh). 0 => today's pixel
    // sizes. Overridable so test-bar-grid.sh can exercise a grid: Kwi3Grid
    // itself is a real singleton fed by Kwi3Client. trayModel likewise: a
    // headless test has no StatusNotifierWatcher to populate SystemTray.items.
    property int cellW: Kwi3Grid.active ? Kwi3Grid.moduleW : 0
    property int cellH: Kwi3Grid.active ? Kwi3Grid.moduleH : 0
    readonly property bool onGrid: cellW > 0 && cellH > 0
    property var trayModel: SystemTray.items
    // Icons are the titlebar icon's size, moduleH - 2 (1 px margin each side,
    // as the titlebar has vertically), packed at pitch moduleH. Whole-cell
    // rounding is over the WHOLE tray block, not per icon (Jan, 2026-09-30),
    // so neighbours stay close: block = ceil(n * pitch / cellW) * cellW, the
    // spare split to its two ends. Off kwi3: 18 px slots, 14 px icons.
    readonly property int iconSlot: onGrid ? cellH : 18
    readonly property int iconSide: onGrid ? cellH - 2 : 14
    readonly property int trayCount: root.tickerActive ? 0 : root.trayModel.length
    readonly property int trayBlockW: onGrid ? (trayCount > 0 ? Math.ceil(trayCount * iconSlot / cellW) * cellW : 0)
                                             : trayRow.width
    // A content width rounded UP to whole cells (never Kwi3Grid.cells(), which
    // rounds and can clip the last glyph); the content's own width off kwi3.
    function gw(w) { return onGrid ? Math.ceil(w / cellW - 0.001) * cellW : w }
    // A "  " / " " separator: n whole cells on kwi3, the font's own space off it.
    function gsep(n, w) { return onGrid ? n * cellW : w }

    // Workspaces sourced directly from i3 IPC (authoritative). Quickshell's
    // I3.workspaces ObjectModel was previously used as the data source, but it
    // does not always track `rename`/`empty`/`init` events fired by wm-state
    // restore — leaving stale entries (e.g. ghost `dotfiles-old`) in the bar
    // until quickshell restarts. Reading get_workspaces directly via i3-msg on
    // every workspace event matches what i3 actually has.
    property var sortedWorkspaces: []

    // Fetch full workspace records from i3 IPC. Re-runs on every workspace
    // event (subscribe stream below) plus a 2s safety-net timer.
    //
    // NOT under kwi3 (kwi3-234.18): the i3 feed - this, wsEventSub and the
    // mode subscription below - runs only while Kwi3Client.configured is
    // false, i.e. on i3/sway. Since sp004 Task 18 a kwi3 display has no i3
    // IPC socket, so every i3-msg these start there fails at once, and
    // wsEventSub's and the mode feed's `onExited: running = true` then
    // respawned i3-msg in a tight loop for the life of the bar (found by
    // sp004 T15 with $I3SOCK unset). `configured` ($KWI3SOCK set), not
    // `available`, because the socket being down - before the first connect,
    // or across a kwi3 restart - is exactly when these would spin. It is a
    // constant for the process's life, so the imperative restarts in
    // onExited below cannot drop a binding the way Overlay's windowSubscriber
    // once did (kwi3-234.14); each still asks the same question it starts on.
    Process {
        id: wsListProc
        running: !Kwi3Client.configured
        command: ["sh", "-c", root.wmMsg + " -t get_workspaces"]
        stdout: SplitParser {
            property string buf: ""
            onRead: data => { wsListProc.stdout.buf += data }
        }
        onExited: {
            try {
                var arr = JSON.parse(wsListProc.stdout.buf)
                arr.sort(function(a, b) { return a.num - b.num })
                var out = []
                for (var i = 0; i < arr.length; i++) {
                    var w = arr[i]
                    out.push({
                        name: w.name,
                        number: w.num,
                        focused: w.focused,
                        active: w.visible,
                        urgent: w.urgent,
                        wsId: w.id
                    })
                }
                root.sortedWorkspaces = out
            } catch (err) {}
            wsListProc.stdout.buf = ""
            if (!Kwi3Client.configured) { wsListTimer.restart() }
        }
    }
    Timer { id: wsListTimer; interval: 2000; onTriggered: wsListProc.running = !Kwi3Client.configured }

    // Refresh on every workspace event (init, focus, empty, urgent, rename, move, restored, reload)
    Process {
        id: wsEventSub
        running: !Kwi3Client.configured
        command: [root.wmMsg, "-t", "subscribe", "-m", '["workspace"]']
        stdout: SplitParser {
            onRead: data => wsListProc.running = true
        }
        onExited: running = !Kwi3Client.configured
    }

    // ---- kwi3 backend (sp004 Task 13, kwi3-234.13; ft008/ft010) -------------
    // Under Kwi3Client.available, workspace.list + events.subscribe replace
    // the i3-msg Processes above as the source of root.sortedWorkspaces.
    // Those Processes do not run at all on a kwi3 session (gated on
    // Kwi3Client.configured since kwi3-234.18, see wsListProc) and run
    // exactly as before on i3/sway (AC3, "the i3/sway path is untouched").
    // Same row shape either way ({name, number, focused, active, urgent,
    // wsId}) so the Repeater below reads one field set from either feed.
    function _kwi3Rows(list) {
        var out = []
        for (var i = 0; i < list.length; i++) {
            var w = list[i]
            out.push({
                name: w.name, number: w.num, focused: !!w.focused,
                active: !!w.visible, urgent: !!w.urgent, wsId: w.id
            })
        }
        out.sort(function (a, b) { return a.number - b.number })
        return out
    }

    function _kwi3Refresh() {
        Kwi3Client.call("workspace.list", undefined, function (err, res) {
            if (err || !res) { return }
            root.sortedWorkspaces = root._kwi3Rows(res)
        })
    }

    Connections {
        target: Kwi3Client
        function onAvailableChanged() {
            if (Kwi3Client.available) { root._kwi3Refresh() }
        }
    }

    Component.onCompleted: {
        // Deltas per ft010 (`workspace.focused/created/destroyed/urgent`):
        // any of them re-lists rather than patching in place, same policy
        // the i3-msg side takes with its own blunter "workspace" event.
        // `workspace.urgent` (kwi3-11m) is the fix for a real gap: before
        // this event existed, a workspace going urgent painted nothing here
        // until the next focus/create/destroy happened to re-list -
        // sometimes never, on a session sitting on one workspace.
        Kwi3Client.on("workspace.focused",   function () { root._kwi3Refresh() })
        Kwi3Client.on("workspace.created",   function () { root._kwi3Refresh() })
        Kwi3Client.on("workspace.destroyed", function () { root._kwi3Refresh() })
        Kwi3Client.on("workspace.urgent",    function () { root._kwi3Refresh() })
        if (Kwi3Client.available) { root._kwi3Refresh() }
    }

    // ---- kwi3 whole-module tab sizing (kwi3-9ut rule) ------------------------
    // Every workspace tab is a whole number of module cells wide, and each
    // tab gets the cells its OWN label wants (see tabCellPlan below).
    //
    // kwi3-55l.16: kwi3-234.13 originally ported i3kwin/core/solver.js's
    // shareEqualCells here and divided sum(wants) equally among the tabs.
    // That equal-share rule belongs to kwi3's chrome (a tab GROUP's children
    // all share one tile's content width, and the chrome runs solver.js, not
    // this file); the bar has no fixed width to fill, so averaging handed a
    // short numeric workspace ("1") and a longer project name ("asahi") each
    // the MEAN of their wants, eliding the longer one (Jan, 3392). The
    // equal-share helper was removed with that fix - nothing here divides a
    // fixed total any more.

    // Cells one tab's own label wants: its rendered width, PLUS the census
    // badge beside it if one will actually show (kwi3-55l.16 - a real live
    // symptom, not a guess: a project's tab went from "…" elided to
    // showing ONLY its agent-count badge, e.g. a workspace named "asahi"
    // painting as "2", once that project had a live claude agent making
    // wsBadge visible. The delegate's own wsText.width formula already
    // subtracts `wsBadge.implicitWidth + wsLabel.spacing` from what it
    // hands the name - measuring only the raw name here and never
    // reserving that space up front is what let a NAME text collapse to a
    // width of zero the moment a badge appeared, at which point the name
    // paints nothing at all and the badge is the only thing left in the
    // tab), PLUS one module of padding each side (i3kwin/bar/shell.qml's
    // tabWidth(), same idea), capped at 40% of the bar's own width — same
    // cap shell.qml uses, converted to whole cells — so one long workspace
    // name cannot take over the bar (edge case: "a workspace name wider
    // than the bar").
    function _tabWantCells(text) {
        var raw = kwi3TabMetrics.advanceWidth(text)
        var count = Census.totalFor(text)
        if (count > 0) {
            var badgeText = count > 1 ? ("●" + count) : "●"
            raw += kwi3TabMetrics.advanceWidth(badgeText) + 4 // wsLabel.spacing
        }
        var want = Math.max(1, Math.ceil(raw / Kwi3Grid.moduleW)) + 2
        var cap = Math.max(1, Math.floor((root.width * 0.4) / Kwi3Grid.moduleW))
        return Math.min(want, cap)
    }

    FontMetrics {
        id: kwi3TabMetrics
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
    }

    // The plan every tab Rectangle below reads its width from: `cells[i]` is
    // one entry per row of root.sortedWorkspaces, in the SAME order —
    // index-aligned (the Repeater's own `index`), not name-keyed.
    //
    // kwi3-55l.16: `cells` IS `wants` — every tab gets exactly what its own
    // label needs (already in whole modules, already padded, already capped
    // at 40% of the bar by _tabWantCells), never less. There is no fixed
    // total to divide among tabs here (unlike the chrome's tab GROUP, where
    // every child shares one tile's content width) — sharing sum(wants)
    // equally among n tabs was the bug (see the section header above):
    // it silently elided any tab whose own want was above the average while
    // handing unused space to every tab below it. `wants` is kept as its own
    // array (not folded into `cells`) purely so a test hook can read what
    // each tab asked for without re-measuring text itself, and so the two
    // stay easy to compare directly. null, not an object with empty arrays,
    // when kwi3 is not the backend, so the pre-existing content-sized width
    // is untouched (AC3); empty arrays for zero workspaces (edge case: "0
    // workspaces reported" — the Repeater then simply has nothing to draw).
    readonly property var tabCellPlan: {
        if (!Kwi3Grid.active) { return null }
        var n = root.sortedWorkspaces.length
        if (n === 0) { return { wants: [], cells: [] } }
        var wants = []
        for (var i = 0; i < n; i++) {
            wants.push(root._tabWantCells(root.sortedWorkspaces[i].name))
        }
        return { wants: wants, cells: wants.slice() }
    }

    // ---- focused-tab / mode-segment highlight, drawn OUTSIDE this window
    // (kwi3-55l.20, extended kwi3-55l.24) ----
    // Jan, 3392 (.20): "bar workspace highlight should be above bar same as
    // is window highlight" / "workspace tab should be only top border" — NOT
    // a full ring (no side/bottom, no radius: a single top line has no
    // corners to round), a top border only, in the half-gap band above the
    // bar (kwi3-55l.17's 11px), spanning the focused tab's width. Mirrors a
    // window's own focus treatment: the titlebar keeps its own focused
    // colour (wsTab's existing "#152024" fill, unchanged) and the RING moves
    // outside the rect it decorates, exactly like core/solver.js draws a
    // tiled window's ring outside the tile rather than inside it.
    //
    // Jan, 3392 (.24): "good highlight and name of workspace looks good one
    // issue it is visible in resize/screenshot all this modes also these
    // modes should have similar highlight of to top". While a hotkeyd
    // mode/layer is up, `leftSide` (the workspace tabs, focusedTabScreenRect
    // included) is INVISIBLE (see `visible: root.currentMode === "default"`
    // above the Repeater) and ModeBar takes its place — but the ring window
    // below used to keep rendering over the now-hidden tab's old position
    // regardless, which is exactly the bug: a highlight floating over
    // nothing while the real content underneath it had moved to ModeBar.
    // `ringScreenRect` picks whichever of the two is the thing actually on
    // screen, and the Window below just follows it — one companion window,
    // never two.
    //
    // Absolute SCREEN coordinates, not an Item's local ones: the strip has
    // to occupy the gap ABOVE this window's own rect, which no Item inside
    // this window could ever paint into — see wsFocusHighlight below, a
    // second, override-redirect top-level window.
    function _ringOrigin() {
        // root.screen.geometry.x/y (QScreen's OWN geometry - its absolute
        // position on the virtual desktop; the attached `Screen` type's
        // virtualX/virtualY are a DIFFERENT, Item-only API and do not exist
        // on a plain Window.screen, which read back as NaN/null here the
        // first time this was measured) anchor this to the right monitor;
        // marginsTop is worked out from the SAME inputs the `margins {
        // top: ... }` group above uses, not read back off root.y/
        // root.margins.top - this PanelWindow positions itself through the
        // anchors/margins/exclusiveZone strut machinery, and on this X11
        // back-end neither of those properties tracks the actual placement
        // (found the hard way - the ring landed at the screen's absolute
        // top, 11px too high, every time this was measured against a real
        // host, margins.top included).
        var screenX = (root.screen && root.screen.geometry) ? root.screen.geometry.x : 0
        var screenY = (root.screen && root.screen.geometry) ? root.screen.geometry.y : 0
        var contentX = root.inset ? (root.insetSide + 10) : 0
        var marginsTop = root.isPhone ? 20 : (Kwi3Grid.active ? Kwi3Grid.edgeMargin : 0)
        return { x: screenX + contentX, y: screenY + marginsTop + root.insetTop }
    }

    readonly property var focusedTabScreenRect: {
        if (!Kwi3Grid.active) { return null }
        var plan = root.tabCellPlan
        if (!plan || !plan.cells || plan.cells.length === 0) { return null }
        var idx = -1
        for (var i = 0; i < root.sortedWorkspaces.length; i++) {
            if (root.sortedWorkspaces[i].focused) { idx = i; break }
        }
        if (idx < 0 || idx >= plan.cells.length) { return null }
        var xOff = 0
        for (var j = 0; j < idx; j++) { xOff += plan.cells[j] * Kwi3Grid.moduleW }
        // Same offsets leftSide/the content Item itself use to place the
        // first tab (root.inset's pill margin, root.insetTop) — worked out
        // here rather than read back off the Item, so this stays a plain
        // reactive property instead of an imperative mapToGlobal() call that
        // would not re-run when the tab layout changes under it.
        var origin = root._ringOrigin()
        return {
            x: origin.x + Kwi3Grid.contentLeft + xOff,
            y: origin.y,
            w: plan.cells[idx] * Kwi3Grid.moduleW
        }
    }

    // kwi3-55l.24: the mode segment's own screen rect, same band. Unlike the
    // tab case above, ModeBar (`mb` below) is a single real Item rather than
    // a Repeater of cells with a hand-tracked plan, so its own `x` (anchored,
    // kept in sync by the engine) is read directly rather than re-derived —
    // there is no separate "plan" to duplicate here the way tabCellPlan
    // exists for the workspace tabs.
    //
    // kwi3-55l.27 (Jan, 3392, verbatim): "green line above should have mode
    // to turn orange and display only above first label" — narrowed from
    // ModeBar's WHOLE rendered width (`mb.implicitWidth`, pill + gap + hints,
    // kwi3-55l.24's own span) to just the mode PILL — "the first label" —
    // `mb.pillWidth`, the pill Rectangle's own width exposed by ModeBar
    // itself (never re-measured here, for the same reason `mb.x` isn't).
    readonly property var modeSegmentScreenRect: {
        if (!Kwi3Grid.active) { return null }
        if (root.currentMode === "default" || !mb.visible) { return null }
        var origin = root._ringOrigin()
        return { x: origin.x + mb.x, y: origin.y, w: mb.pillWidth }
    }

    // Whichever of the two is the thing actually rendered where `leftSide`
    // used to be: the workspace tab at rest, the mode segment while a
    // hotkeyd layer/i3 mode is up. Never both — leftSide and ModeBar are
    // already mutually exclusive on `currentMode`, and this just follows.
    readonly property var ringScreenRect: root.currentMode === "default"
        ? root.focusedTabScreenRect : root.modeSegmentScreenRect

    // kwi3-55l.27 (Jan, 3392, verbatim): "in mode green should be hidden and
    // orange line should be at same height as is the green line" — same
    // single companion window (wsFocusHighlight below), same rows, but its
    // FILL now follows which of the two rects above is showing: the
    // workspace ring's own frame colour at rest, the mode pill's own accent
    // (ModeBarTheme.highlight, "the pill's own colour... exactly the colour
    // ModeBar uses for that stripe today" per this task) while a mode/layer
    // is up — never both, and never kwi3's window-focus-ring colour
    // (Kwi3Grid.frameColor / kwi3-55l.25's per-mode frame, a DIFFERENT ring
    // this task must stay independent of, per that task's own note). Read
    // directly off ModeBarTheme rather than duplicated as a literal here —
    // if ModeBar ever varies the accent per mode, this follows it for free.
    readonly property color ringColor: root.currentMode === "default"
        ? Kwi3Grid.frameColor : ModeBarTheme.highlight

    // ------------------------------------------------------- agent census ---
    // Per-project claude-agent counts (ft012 / `agent-census`), rendered as a
    // badge on the workspace tab that carries the same name. Workspace names
    // ARE project names here — tmux-start/i3 name a workspace after the
    // project — so the join is by name and nothing else; a workspace with no
    // matching census row simply gets no badge rather than a fabricated zero.
    //
    // The probe itself lives in the Census singleton (Common/Census.qml), NOT
    // here: shell.qml builds one Bar per screen, so a poller in this file ran
    // the census once per screen — twice on this single-monitor session, which
    // reports an inactive `xroot-0` output alongside the real one.

    // --- Mode tracking ---
    // `currentMode` is derived further down, from the i3 mode plus hotkeyd's
    // layer feed — there is no writable mode property any more.

    // i3 modes only — the ones i3 STILL owns after the sp020 T6 cutover:
    // `resize`, `screenshot`, and the `$mode_system` power menu. `binding` is
    // gone from the subscription because nothing reads it any more: the nav
    // layer left i3 entirely and reports its own state (see the layer feed
    // below).
    property string i3Mode: "default"
    // Not under kwi3 - kwi3 has no i3 binding modes and no i3 socket to ask
    // (see wsListProc for why this is `configured`, not `available`).
    Process {
        command: [root.wmMsg, "-t", "subscribe", "-m", '["mode"]']
        running: !Kwi3Client.configured
        stdout: SplitParser {
            onRead: data => {
                try {
                    var e = JSON.parse(data)
                    if (e.change !== undefined) root.i3Mode = e.change
                } catch(err) {}
            }
        }
        onExited: running = !Kwi3Client.configured
    }

    // --- Layer feed from hotkeyd (sp020 T7, ft011) ---
    //
    // What this replaces: the bar used to RECONSTRUCT the nav layer from side
    // effects of i3 binds. i3 cannot report a held modifier, so the mode bound
    // the raw Ctrl and Alt keycodes to `nop nav-move-on/off` markers purely to
    // make a binding event fire, and this file string-matched those commands,
    // corroborated them against the `mods` of ordinary binds, and ran a 120 ms
    // timer to guess when a release had been missed. Three mechanisms to answer
    // one question the WM could not be asked.
    //
    // Now the daemon owns the keys and simply says what state it is in, one JSON
    // line per change: {"layer":"nav","mod":"move"}. `mod` is "move", "resize"
    // or null. The 120 ms release guard still exists — xrdp's per-character
    // Shift synthesis did not go away — but it lives in the daemon, next to the
    // events it guards, instead of here.
    //
    // The reader is a tiny helper rather than socat (absent on this host) and it
    // EXITS when the socket goes away, per [[adr0014]]: this Process's restart
    // timer is the bounded respawn, so a missing daemon costs one process per
    // interval rather than a fork storm.
    property string daemonLayer: "default"
    property string daemonMod: ""

    // Overridable for the same reason QS_NOTIF_FILE / QS_STATS_FILE are: a
    // harness has to drive the reader in ITS OWN tree, not whatever happens to
    // be checked out at ~/.dotfiles. Without this the suite's layer assertions
    // silently read "default" — not because the bar is wrong, but because the
    // thing it spawned did not exist.
    //
    // QS_LAYER_FEED NAMES AN EXECUTABLE, NOT A SCRIPT (dotfiles-ylmp.16). It
    // used to be a path handed to a hardcoded `python3`; hotkeyd is Go now and
    // the reader is a subcommand of the daemon binary itself
    // (`hotkeyd state-tail`, cmd/hotkeyd/statetail.go — a drop-in for the
    // deleted state-tail.py, same argv contract, same one-line-per-change
    // output, same exit-when-the-socket-goes behaviour).
    //
    // The override therefore substitutes a BINARY and still receives
    // `state-tail` as argv[1], which is what lets quickshell/test-mode-bar.sh
    // point it at a counting shim that execs the real thing. Dropping the
    // interpreter from the command array is the whole point: with `python3`
    // hardcoded, no value of QS_LAYER_FEED could have named a compiled reader.
    readonly property string layerFeedCmd: Quickshell.env("QS_LAYER_FEED")
        || (Quickshell.env("HOME") + "/.dotfiles/hotkeyd/hotkeyd")

    Process {
        id: layerFeed
        command: [root.layerFeedCmd, "state-tail"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    var s = JSON.parse(data)
                    root.daemonLayer = s.layer ? String(s.layer) : "default"
                    root.daemonMod = s.mod ? String(s.mod) : ""
                } catch(err) {}
            }
        }
        onExited: {
            // No daemon (or it died): fall back to a plain bar rather than
            // freezing on the last layer we were told about.
            root.daemonLayer = "default"
            root.daemonMod = ""
            layerFeedRetry.restart()
        }
    }
    Timer { id: layerFeedRetry; interval: 1000; onTriggered: layerFeed.running = true }

    // The mode the bar PAINTS: a daemon layer wins when one is active, otherwise
    // whatever i3 mode is up. The two cannot both be meaningful — a chord
    // belongs to exactly one grabber — and if they ever disagree, the daemon's
    // layer is the one whose keys are live under your fingers.
    readonly property string activeMode: daemonLayer !== "default" ? daemonLayer
                                       : i3Mode

    // SILENT LAYERS READ AS "default" HERE (dotfiles-hwds.44), which is what
    // makes them cost the bar nothing. `currentMode` is not only the ModeBar's
    // input — the workspace strip, the notification ticker and the tray are all
    // gated on it being "default", so a layer that merely rendered an invisible
    // ModeBar would still blank half the bar for the length of the gesture.
    // $mod+w has to behave like $mod+d and $mod+p: open an overlay, leave the
    // bar alone.
    readonly property string currentMode: ModeBarTheme.silent(activeMode)
                                        ? "default" : activeMode
    readonly property bool inNavMode: daemonLayer === "nav"

    // Rendered layer name, straight from the feed. No sticky timer here: the
    // daemon publishes on CHANGE only and already absorbs the stray release, so
    // there is nothing left for the bar to debounce.
    readonly property string navLayerSticky: daemonMod === "move" ? "nav-move"
                                           : daemonMod === "resize" ? "nav-resize"
                                           : "nav"

    // --- System stats ---
    // Two modes:
    //   1. daemonMode (Termux/proot, native Linux with daemon): one machine-wide
    //      qs-stats-daemon rewrites a state file atomically; every session's bar
    //      (local + xrdp concurrently) follows it with `tail -F`. Lines are
    //      `cpu N`, `ram N`, `disk N`, `bat N STATUS`, `net IFACE [SSID]`,
    //      `vol N MUTE`. One fork total, no polling timers.
    //   2. fallback: existing per-widget Process+Timer polling chain.
    // daemonMode is decided at startup by daemonProbe (a few retries so a
    // daemon that's still booting isn't mistaken for absent); the polling
    // chains are gated on !daemonMode to silence them when the daemon is up.
    readonly property string statsFile: "/tmp/qs-stats"
    readonly property string daemonFile: Quickshell.env("QS_STATS_FILE") || "/tmp/qs-stats.state"
    property bool daemonMode: false
    property bool daemonProbed: false
    property int daemonProbeTries: 0
    property string cpuVal:  "?"
    property string ramVal:  "?"
    property string diskVal: "?"
    property string netVal:  ""
    property string volVal:  ""
    property bool volMuted: false
    property string batVal:  ""
    property string batStatus: ""

    Process {
        id: daemonProbe
        running: true
        command: ["sh", "-c", "[ -s " + root.daemonFile + " ] && echo yes || echo no"]
        stdout: SplitParser {
            onRead: data => {
                if (data.trim() === "yes") {
                    root.daemonMode = true
                    root.daemonProbed = true
                } else if (root.daemonProbeTries < 5) {
                    root.daemonProbeTries++
                    daemonProbeRetry.restart()
                } else {
                    root.daemonProbed = true   // no daemon — polling fallback
                }
            }
        }
    }
    Timer { id: daemonProbeRetry; interval: 2000; onTriggered: daemonProbe.running = true }

    Process {
        id: feedProc
        running: root.daemonMode
        // -F follows across the daemon's atomic tmp+rename swaps and re-emits
        // the whole (complete-state) file each time; sets below are idempotent
        command: ["sh", "-c", "exec tail -n +1 -F " + root.daemonFile + " 2>/dev/null"]
        stdout: SplitParser {
            onRead: data => {
                var line = data.trim()
                var sp = line.indexOf(" ")
                if (sp < 0) return
                var key = line.substring(0, sp)
                var rest = line.substring(sp + 1)
                if (key === "cpu") {
                    root.cpuVal = rest + "%"
                } else if (key === "ram") {
                    root.ramVal = rest + "%"
                } else if (key === "disk") {
                    root.diskVal = rest + "%"
                } else if (key === "bat") {
                    var bs = rest.indexOf(" ")
                    if (bs < 0) { root.batVal = rest; root.batStatus = "" }
                    else { root.batVal = rest.substring(0, bs); root.batStatus = rest.substring(bs + 1) }
                } else if (key === "net") {
                    root.netVal = (rest === "none") ? "" : rest
                } else if (key === "vol") {
                    var vs = rest.indexOf(" ")
                    if (vs < 0) { root.volVal = rest; root.volMuted = false }
                    else {
                        root.volVal = rest.substring(0, vs)
                        root.volMuted = (rest.substring(vs + 1).trim() === "yes")
                    }
                }
            }
        }
        onExited: { if (root.daemonMode) feedRestart.restart() }
    }
    Timer { id: feedRestart; interval: 2000; onTriggered: feedProc.running = root.daemonMode }

    Process {
        id: statsProc
        running: !root.daemonMode
        command: ["sh", "-c",
            "if [ -f " + root.statsFile + " ]; then cat " + root.statsFile + "; else " +
            "read _ a1 b1 c1 d1 e1 f1 g1 _ < /proc/stat; sleep 1; " +
            "read _ a2 b2 c2 d2 e2 f2 g2 _ < /proc/stat; " +
            "t1=$((a1+b1+c1+d1+e1+f1+g1)); t2=$((a2+b2+c2+d2+e2+f2+g2)); " +
            "dt=$((t2-t1)); di=$((d2-d1)); " +
            "echo $(( dt > 0 ? (dt-di)*100/dt : 0 )); " +
            "awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf \"%.0f\\n\", (t-a)/t*100}' /proc/meminfo; " +
            "df / | awk 'NR==2{gsub(/%/,\"\",$5); print $5}'; fi"]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: data => {
                var v = data.trim()
                if (lineNum === 0) root.cpuVal = v + "%"
                else if (lineNum === 1) root.ramVal = v + "%"
                else if (lineNum === 2) root.diskVal = v + "%"
                lineNum++
            }
        }
        onExited: { statsProc.stdout.lineNum = 0; if (!root.daemonMode) statsTimer.restart() }
    }
    Timer { id: statsTimer; interval: 3000; onTriggered: if (!root.daemonMode) statsProc.running = true }

    Process {
        id: netProc
        running: !root.daemonMode
        command: ["sh", "-c",
            "iwgetid -r 2>/dev/null && exit; ip -brief addr | awk '!/^lo /{if($2==\"UP\") print $1; exit}'"]
        stdout: SplitParser { onRead: data => root.netVal = data.trim() }
        onExited: { if (!root.daemonMode) netTimer.restart() }
    }
    Timer { id: netTimer; interval: 10000; onTriggered: if (!root.daemonMode) netProc.running = true }

    Process {
        id: volProc
        running: !root.daemonMode
        command: ["sh", "-c",
            "pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\\d+(?=%)' | head -1; " +
            "pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -oP '(yes|no)'"]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: data => {
                if (lineNum === 0) root.volVal = data.trim()
                else if (lineNum === 1) root.volMuted = (data.trim() === "yes")
                lineNum++
            }
        }
        onExited: { volProc.stdout.lineNum = 0; if (!root.daemonMode) volTimer.restart() }
    }
    Timer { id: volTimer; interval: 5000; onTriggered: if (!root.daemonMode) volProc.running = true }

    // Click-driven controls — kept regardless of mode. The daemon will pick
    // up the state change via pactl subscribe and emit a fresh `vol` line.
    Process { id: volToggleMute; command: ["pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle"]; onExited: { if (!root.daemonMode) volProc.running = true } }
    Process { id: volUp; command: ["sh", "-c", "cur=$(pactl get-sink-volume @DEFAULT_SINK@ | grep -oP '\\d+(?=%)' | head -1); [ \"$cur\" -lt 100 ] && pactl set-sink-volume @DEFAULT_SINK@ +5%"]; onExited: { if (!root.daemonMode) volProc.running = true } }
    Process { id: volDown; command: ["pactl", "set-sink-volume", "@DEFAULT_SINK@", "-5%"]; onExited: { if (!root.daemonMode) volProc.running = true } }

    Process {
        id: batProc
        running: !root.daemonMode
        command: ["sh", "-c",
            "cat /sys/class/power_supply/BAT0/capacity 2>/dev/null; cat /sys/class/power_supply/BAT0/status 2>/dev/null"]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: data => {
                if (lineNum === 0) root.batVal = data.trim()
                else if (lineNum === 1) root.batStatus = data.trim()
                lineNum++
            }
        }
        onExited: { batProc.stdout.lineNum = 0; if (!root.daemonMode) batTimer.restart() }
    }
    Timer { id: batTimer; interval: 10000; onTriggered: if (!root.daemonMode) batProc.running = true }

    // --- Keyboard layout (sway only — no per-input IPC on i3) ---
    // Track only real keyboards. Virtual keyboards (browsers, foot, etc.)
    // appear and disappear constantly and start with the default layout, so
    // taking the first input from get_inputs or reacting to every input event
    // makes the indicator flicker back to QWT unpredictably.
    property string kbdLayout: "us"

    function _setKbdFromName(name) {
        var s = (name || "").toLowerCase()
        root.kbdLayout = s.indexOf("dvorak") >= 0 ? "dvorak" : "us"
    }

    Process {
        id: kbdQueryProc
        running: root.isSway
        command: ["swaymsg", "-t", "get_inputs"]
        property string buf: ""
        stdout: SplitParser { onRead: data => { kbdQueryProc.buf += data } }
        onExited: {
            try {
                var arr = JSON.parse(kbdQueryProc.buf)
                for (var i = 0; i < arr.length; i++) {
                    var inp = arr[i]
                    if (inp.type === "keyboard" && inp.xkb_active_layout_name) {
                        root._setKbdFromName(inp.xkb_active_layout_name)
                        break
                    }
                }
            } catch(err) {}
            kbdQueryProc.buf = ""
        }
    }

    // Indicator owned by user click. xkb_layout events from sway fire on
    // every Shift press/release under WSLg/RDP — flickers — so we predict
    // locally instead of subscribing to xkb events.
    //
    // Absolute index (not `next`) + type:keyboard (not `*`) — under WSLg,
    // virtual keyboards spawn/despawn on focus changes and start at index 0,
    // so a `next` toggle on `*` would race the new keyboard and revert.
    Process { id: kbdApplyProc }
    function _applyKbdLayout() {
        // Under WSLg, sway's `xkb_switch_layout` flips its internal group
        // but clients don't re-render the keymap — they keep typing the
        // old layout. Replacing xkb_layout/xkb_variant outright forces sway
        // to emit a brand new keymap on wl_keyboard.keymap, which clients
        // do honor. The desired layout goes first so active index 0 (the
        // default on keymap regeneration) is the one we want. Both
        // entries remain `us` so sway-side keybinds keep working.
        //
        // The single-quoted argument is required because swaymsg's command
        // parser treats `,` as a chain separator unless the layout list is
        // double-quoted inside the command string.
        var variant = root.kbdLayout === "dvorak" ? "dvorak," : ",dvorak"
        var cmd =
            "swaymsg 'input type:keyboard xkb_layout \"us,us\"' && " +
            "swaymsg 'input type:keyboard xkb_variant \"" + variant + "\"'"
        kbdApplyProc.command = ["sh", "-c", cmd]
        kbdApplyProc.running = false
        kbdApplyProc.running = true
    }

    // Re-apply the user's chosen layout whenever a new keyboard appears.
    // Without this, focusing a Windows-host window spawns a fresh virtual
    // keyboard at layout 0, which becomes the active input source and
    // silently reverts the layout despite the indicator staying correct.
    Process {
        id: inputEventSub
        running: root.isSway
        command: ["swaymsg", "-t", "subscribe", "-m", '["input"]']
        stdout: SplitParser {
            onRead: data => {
                try {
                    var e = JSON.parse(data)
                    if (e.change === "added" && e.input && e.input.type === "keyboard") {
                        root._applyKbdLayout()
                    }
                } catch(err) {}
            }
        }
        onExited: running = true
    }

    // Window focus also resets layout under WSLg — new windows can pull a
    // fresh wlroots virtual keyboard at group 0 without firing an `input
    // added` event quickshell sees in time. Re-apply on every focus change.
    Process {
        id: windowEventSub
        running: root.isSway
        command: ["swaymsg", "-t", "subscribe", "-m", '["window"]']
        stdout: SplitParser {
            onRead: data => {
                try {
                    var e = JSON.parse(data)
                    if (e.change === "focus" || e.change === "new") {
                        root._applyKbdLayout()
                    }
                } catch(err) {}
            }
        }
        onExited: running = true
    }


    // Inset-pill background (X11 phone mode; invisible when inset is 0)
    Rectangle {
        visible: root.inset
        anchors.fill: parent
        anchors.leftMargin: root.insetSide
        anchors.rightMargin: root.insetSide
        anchors.topMargin: root.insetTop
        // Pill look only when inset from the sides; otherwise a flat top bar.
        radius: root.insetSide > 0 ? 12 : 0
        color: root.barColor
    }

    // --- Layout (using Row, not RowLayout — RowLayout leaks Text.color) ---
    Item {
        anchors.fill: parent
        anchors.leftMargin: root.inset ? root.insetSide + 10 : 0
        anchors.rightMargin: root.inset ? root.insetSide + 10 : 0
        anchors.topMargin: root.insetTop

        // Left: workspaces + mode
        Row {
            id: leftSide
            visible: root.currentMode === "default"
            // kwi3-2zj (carried from i3kwin/bar/shell.qml): the first tab
            // starts where the tiles' own titlebars do.
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                      leftMargin: Kwi3Grid.active ? Kwi3Grid.contentLeft : 8 }
            spacing: 0

            Repeater {
                model: root.sortedWorkspaces

                Rectangle {
                    id: wsTab
                    required property var modelData
                    required property int index
                    // objectName purely for test introspection (test-kwi3-
                    // backend.sh PHASE 6), same convention as wsAgentBadge/
                    // notifTickerText below.
                    objectName: "wsTab"
                    // Under kwi3 the tab's width is the plan's, not its
                    // label's, so a label can be wider than its tab (a long
                    // name capped at 40% of the bar by _tabWantCells).
                    // wsText below elides to fit; the clip is the backstop so
                    // nothing - the badge included - ever paints onto the
                    // next tab. Off under i3/sway, where the tab is sized
                    // from its label and nothing can overflow (AC3).
                    clip: root.tabCellPlan !== null
                    width: (root.tabCellPlan && root.tabCellPlan.cells
                            && index < root.tabCellPlan.cells.length)
                         ? root.tabCellPlan.cells[index] * Kwi3Grid.moduleW
                         : (wsLabel.implicitWidth + 14)
                    height: leftSide.height
                    // Focused tab uses the same highlight as the mod+d launcher
                    // input/selection (#152024, Overlay.qml).
                    color: modelData.urgent  ? "#cb4b16"
                         : modelData.focused ? "#152024"
                         : "transparent"

                    // Name + agent badge share one baseline-aligned Row, so the
                    // tab widens by exactly the badge and the name stays put.
                    Row {
                        id: wsLabel
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 1
                        spacing: 4

                        Text {
                            id: wsText
                            objectName: "wsTabText"
                            text: modelData.name
                            // kwi3 only: at most the tab's whole-module width
                            // less one module of padding each side (the same
                            // +2 cells _tabWantCells adds) and less the agent
                            // badge if it shows, elided at the right. Under
                            // i3/sway this is exactly implicitWidth, i.e. the
                            // Text's own default, so nothing changes there.
                            width: root.tabCellPlan
                                 ? Math.min(implicitWidth, Math.max(0,
                                       wsTab.width - 2 * Kwi3Grid.moduleW
                                       - (wsBadge.visible ? wsBadge.implicitWidth + wsLabel.spacing : 0)))
                                 : implicitWidth
                            elide: root.tabCellPlan ? Text.ElideRight : Text.ElideNone
                            // Focused/urgent tab bright; other project tabs dimmed.
                            color: (modelData.focused || modelData.urgent) ? "#fdf6e3" : "#707880"
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            font.bold: modelData.focused
                            renderType: root.nativeRender
                        }

                        // Live-agent badge for the project this tab is named
                        // after: a dot, plus a digit ONLY once there is more
                        // than one agent. The dot carries the state (which is
                        // what you scan the bar for) and the digit carries the
                        // count (which you only need when it is not the obvious
                        // one) — a bare "1" on every busy tab is the same
                        // information as the dot, printed twice.
                        //
                        // Hidden at zero rather than rendered as "0": a
                        // permanent 0 on every tab trains the eye to skip the
                        // column the badge exists to draw it to.
                        Text {
                            id: wsBadge
                            objectName: "wsAgentBadge"
                            visible: Census.totalFor(modelData.name) > 0
                            text: Census.totalFor(modelData.name) > 1
                                ? "●" + Census.totalFor(modelData.name)
                                : "●"
                            // Colour is the census's own priority (blocked >
                            // working > idle) and ignores focus/urgency, so the
                            // badge means the same thing on every tab.
                            color: Census.colorFor(modelData.name)
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            font.bold: true
                            renderType: root.nativeRender
                        }
                    }

                    // kwi3-55l.20 (Jan, 3392: "bar workspace highlight should
                    // be above bar same as is window highlight" / "workspace
                    // tab should be only top border"): the FOCUSED tab's own
                    // top-border ring moved OUTSIDE this window entirely, into
                    // the half-gap band above the bar - see wsFocusHighlight
                    // below, an override-redirect popup no Item inside this
                    // window could paint into. This strip now only marks a
                    // tab that is visible on another output but not focused
                    // here (unrelated to the ring).
                    Rectangle {
                        anchors { top: parent.top; left: parent.left; right: parent.right }
                        height: 2
                        color: (modelData.active && !modelData.focused) ? "#454948" : "transparent"
                    }

                    MouseArea {
                        // objectName: same test-introspection convention as
                        // the Rectangle's own wsTab above — lets PHASE 6
                        // invoke .clicked() directly, through the real
                        // handler, without a synthetic pointer event.
                        objectName: "wsTabClick"
                        anchors.fill: parent
                        onClicked: {
                            if (Kwi3Client.available) {
                                Kwi3Client.call("workspace.focus", { num: modelData.number })
                            } else {
                                I3.dispatch("workspace " + modelData.name)
                            }
                        }
                    }
                }
            }
        }

        // Mode-hint strip (name-pill + keyboard hints), extracted to the shared
        // ModeBar (sp018 / ft009). Same anchors + leftMargin as the old inline
        // overlay Row; the host keeps the mode-subscription Process above and
        // just feeds it root.currentMode.
        // "nav-move"/"nav-resize" are REGISTRY KEYS, not states anyone enters:
        // the daemon stays in layer "nav" for the whole gesture and reports the
        // held modifier alongside it. Swapping the string fed to ModeBar is how
        // each modifier's face becomes visible without widening ft009's
        // two-prop api_surface — the registry carries all three rows.
        ModeBar {
            // id (kwi3-55l.24): read directly by modeSegmentScreenRect above
            // (`mb.x`/`mb.implicitWidth`) — the mode-highlight window needs
            // to know exactly where this renders, the same way the tab
            // Repeater's own geometry feeds focusedTabScreenRect.
            id: mb
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                      leftMargin: Kwi3Grid.active ? Kwi3Grid.contentLeft : 8 }
            mode: root.inNavMode ? root.navLayerSticky : root.currentMode
            fontSize: root.fontSize
        }

        // Notification ticker — between workspaces and bell/date
        Rectangle {
            id: tickerArea
            visible: root.currentMode === "default" && root.tickerActive
            anchors { left: leftSide.right; right: rightSide.left; verticalCenter: parent.verticalCenter; leftMargin: 8; rightMargin: 4 }
            clip: true
            height: parent.height
            z: -1
            color: "#152024"

            Text {
                id: tickerText
                // objectName purely for test introspection (the ModeBar
                // pillLabel precedent, test-mode-bar.sh) -- lets a harness
                // walk the render tree and read the animation's live x
                // position without widening any public API.
                objectName: "notifTickerText"
                text: root.notifText
                color: "#fdf6e3"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
                y: parent.height - height - 1
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    tickerAnim.stop()
                    root.tickerActive = false
                    root.requestDismiss()
                }
            }

            NumberAnimation {
                id: tickerAnim
                target: tickerText
                property: "x"
                from: tickerArea.width
                to: -tickerText.implicitWidth
                duration: Math.max((tickerArea.width + tickerText.implicitWidth) * 12, 3000)
                onFinished: { root.tickerActive = false }
            }
        }

        // Right side: stats + bell + date
        Row {
            id: rightSide
            objectName: "rightSide"
            // Stats/tray/bell hide in a mode; the clock+date (clockDate Row
            // below) stay pinned right, so the mode strip only replaces the
            // left/workspace side. Anchored to clockDate.left so the two
            // right-side blocks never overlap.
            visible: root.currentMode === "default"
            anchors { right: clockDate.left; bottom: parent.bottom; bottomMargin: 1 }
            spacing: 0

            // Stats (hidden during ticker)
            Text { width: root.gw(implicitWidth); visible: root.showNet && !root.tickerActive && root.netVal !== ""; text: "NET:"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gw(implicitWidth); visible: root.showNet && !root.tickerActive && root.netVal !== ""; text: root.netVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gsep(2, implicitWidth); visible: root.showNet && !root.tickerActive && root.netVal !== ""; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // CPU hidden when daemon couldn't read /proc/stat (proot/Termux on
            // Android — values masked for unprivileged → cpuVal stays "?").
            Text { width: root.gw(implicitWidth); visible: root.showCpu && !root.tickerActive && root.cpuVal !== "?"; text: "CPU:"; color: parseInt(root.cpuVal) >= 90 ? "#cb4b16" : "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gw(implicitWidth); visible: root.showCpu && !root.tickerActive && root.cpuVal !== "?"; text: root.cpuVal; color: parseInt(root.cpuVal) >= 90 ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gsep(2, implicitWidth); visible: root.showCpu && !root.tickerActive && root.cpuVal !== "?"; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { width: root.gw(implicitWidth); visible: root.showRam && !root.tickerActive && root.ramVal !== "?"; text: "RAM:"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gw(implicitWidth); visible: root.showRam && !root.tickerActive && root.ramVal !== "?"; text: root.ramVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gsep(2, implicitWidth); visible: root.showRam && !root.tickerActive && root.ramVal !== "?"; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { width: root.gw(implicitWidth); visible: root.showDisk && !root.tickerActive && root.diskVal !== "?"; text: "HDD:"; color: parseInt(root.diskVal) >= 90 ? "#cb4b16" : "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gw(implicitWidth); visible: root.showDisk && !root.tickerActive && root.diskVal !== "?"; text: root.diskVal; color: parseInt(root.diskVal) >= 90 ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { width: root.gsep(2, implicitWidth); visible: !root.tickerActive && root.volVal !== ""; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Item {
                objectName: "volSeg"
                visible: !root.tickerActive && root.volVal !== ""
                width: volLabel.width + volValue.width
                height: parent.height
                Text { id: volLabel; objectName: "volLabel"; width: root.gw(implicitWidth); text: (root.volMuted || root.volVal === "0") ? "" : "VOL:"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                Text { id: volValue; objectName: "volValue"; width: root.gw(implicitWidth); anchors.left: volLabel.right; text: (root.volMuted || root.volVal === "0") ? "MUTED" : root.volVal + "%"; color: (root.volMuted || root.volVal === "0") ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    onClicked: volToggleMute.running = true
                    onWheel: wheel => { if (wheel.angleDelta.y > 0) volUp.running = true; else volDown.running = true }
                }
            }

            Text { width: root.gsep(2, implicitWidth); visible: !root.tickerActive && root.batVal !== ""; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gw(implicitWidth); visible: !root.tickerActive && root.batVal !== "" && root.batVal !== "100"; text: (root.batStatus === "Charging" ? "CHR:" : "BAT:"); color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gw(implicitWidth); visible: !root.tickerActive && root.batVal !== "" && root.batVal !== "100"; text: root.batVal + "%"; color: root.batStatus === "Discharging" && parseInt(root.batVal) <= 20 ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { width: root.gw(implicitWidth); visible: !root.tickerActive && root.batVal === "100"; text: "CHARGED"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // Keyboard layout indicator (sway only). Click cycles us↔dvorak.
            Text { width: root.gsep(2, implicitWidth); visible: root.isSway && !root.tickerActive; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Item {
                objectName: "kbdSeg"
                visible: root.isSway && !root.tickerActive
                width: visible ? kbdLabel.width + kbdValue.width : 0
                height: parent.height
                Text { id: kbdLabel; objectName: "kbdLabel"; width: root.gw(implicitWidth); text: "KBL:"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                Text { id: kbdValue; objectName: "kbdValue"; width: root.gw(implicitWidth); anchors.left: kbdLabel.right; text: root.kbdLayout === "dvorak" ? "DVK" : "QWT"; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.kbdLayout = root.kbdLayout === "dvorak" ? "us" : "dvorak"
                        root._applyKbdLayout()
                    }
                }
            }

            Text { width: root.gsep(2, implicitWidth); text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // System tray (StatusNotifierItem / SNI). Legacy XEmbed apps
            // (nm-applet, pamac-tray) will not appear without an XEmbed→SNI
            // bridge like xembedsniproxy. Modern apps (Firefox, Telegram,
            // Element, Steam, KeePassXC, …) show up automatically.
            Item {
              id: trayBlock
              objectName: "trayBlock"
              width: root.trayBlockW
              height: parent.height
              Row {
                id: trayRow
                objectName: "trayRow"
                height: parent.height
                // spare cells split to the two ends: floor to the left
                x: root.onGrid ? Math.floor((root.trayBlockW - root.trayCount * root.iconSlot) / 2) : 0
                Repeater {
                model: root.trayModel
                delegate: Item {
                    objectName: "traySlot"
                    required property var modelData
                    visible: !root.tickerActive
                    width: visible ? root.iconSlot : 0
                    height: trayRow.height
                    Image {
                        objectName: "trayIcon"
                        anchors.centerIn: parent
                        width: root.iconSide; height: root.iconSide
                        sourceSize: Qt.size(root.iconSide, root.iconSide)
                        source: modelData.icon
                        smooth: false
                    }
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        onClicked: mouse => {
                            if (mouse.button === Qt.LeftButton) modelData.activate(0, 0)
                            else if (mouse.button === Qt.MiddleButton) modelData.secondaryActivate(0, 0)
                        }
                    }
                }
            }
              }
            }

            Text {
                visible: !root.tickerActive && root.trayModel.length > 0
                text: "  "
                width: root.gsep(2, implicitWidth)
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
            }

            // Bell — always visible, click to replay ticker
            Item {
                objectName: "bellSlot"
                // kwi3: its own segment - the icon (moduleH - 2, at pitch
                // moduleH) plus the count, the whole segment rounded UP to
                // cells; no "+ 4" (the icon's own 1 px margin is the gap).
                width: root.onGrid ? Math.ceil((root.iconSlot + (root.notifCount > 0 ? bellCount.implicitWidth : 0)) / root.cellW) * root.cellW
                                   : bellIcon.width + (root.notifCount > 0 ? bellCount.implicitWidth + 4 : 0)
                height: parent.height
                Image {
                    id: bellIcon
                    objectName: "bellIcon"
                    width: root.iconSide; height: root.iconSide
                    x: root.onGrid ? (root.iconSlot - root.iconSide) / 2 : 0
                    anchors.verticalCenter: parent.verticalCenter
                    sourceSize: Qt.size(root.iconSide, root.iconSide)
                    source: "data:image/svg+xml," + encodeURIComponent(
                        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="' + (root.hasCritical ? '#cb4b16' : root.notifCount > 0 ? '#fdf6e3' : '#707880') + '">' +
                        '<path d="M12 2C10.9 2 10 2.9 10 4V4.3C7.7 5.1 6 7.3 6 10V16L4 18V19H20V18L18 16V10C18 7.3 16.3 5.1 14 4.3V4C14 2.9 13.1 2 12 2ZM10 20C10 21.1 10.9 22 12 22S14 21.1 14 20H10Z"/>' +
                        '</svg>')
                }
                Text { id: bellCount; objectName: "bellCount"; visible: root.notifCount > 0; x: root.onGrid ? root.iconSlot : bellIcon.width; anchors.verticalCenter: parent.verticalCenter; text: root.notifCount; color: root.hasCritical ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; font.bold: true; renderType: root.nativeRender }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (root.tickerActive && root.notifCount === 0) {
                            tickerAnim.stop()
                            root.tickerActive = false
                        } else {
                            root.requestDismiss()
                        }
                    }
                }
            }

        }

        // Clock + date — always visible, kept on the right even while a mode
        // strip is shown. Split out of rightSide so the mode gate only hides
        // the stats/tray/bell, never the time.
        Row {
            id: clockDate
            objectName: "clockDate"
            anchors { right: parent.right; bottom: parent.bottom; bottomMargin: 1
                      rightMargin: root.onGrid ? root.cellW : 8 }
            spacing: 0

            Text { width: root.gsep(2, implicitWidth); text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // Time — sync to second/minute boundary so updates aren't delayed
            Text {
                id: clockText
                width: root.gw(implicitWidth)
                property bool showSeconds: false
                text: Qt.formatDateTime(new Date(), showSeconds ? "HH:mm:ss" : "HH:mm")
                color: "#707880"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
                function refresh() { text = Qt.formatDateTime(new Date(), showSeconds ? "HH:mm:ss" : "HH:mm") }
                Timer {
                    id: clockTimer
                    running: true; repeat: true
                    interval: clockText.showSeconds ? 1000 : 1000
                    onTriggered: {
                        clockText.refresh()
                        if (!clockText.showSeconds) {
                            var ms = 60000 - (Date.now() % 60000)
                            interval = ms < 1000 ? ms + 60000 : ms
                        }
                    }
                }
                MouseArea { anchors.fill: parent; onClicked: { parent.showSeconds = !parent.showSeconds; parent.refresh(); clockTimer.interval = 1000; clockTimer.restart() } }
            }
            Text { width: root.gsep(1, implicitWidth); text: " "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text {
                width: root.gw(implicitWidth)
                text: Qt.formatDateTime(new Date(), "yyyy-MM-dd")
                color: "#fdf6e3"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
                Timer { interval: 60000; running: true; repeat: true; onTriggered: parent.text = Qt.formatDateTime(new Date(), "yyyy-MM-dd") }
            }
        }
    }

    // kwi3-55l.20 (extended kwi3-55l.24): the focused-tab / mode-segment ring
    // itself. A DIRECT child of this PanelWindow (a second top-level window,
    // not an Item in the tree above) because it must occupy the gap ABOVE
    // this window's own rect. Qt.BypassWindowManagerHint makes the X11 QPA
    // back-end create it override_redirect - invisible to kwi3's tiling
    // entirely (adapters/x11 wm.cpp/window.cpp treat override_redirect as
    // untouchable, the same guarantee kwi3's own chrome relies on) - so it
    // never gets a titlebar, never steals focus and is never a con a runner
    // rule or the default new-window policy has to know about. Only
    // instantiated under kwi3 (Loader gated on Kwi3Grid.active): a plain
    // i3/sway session creates no extra window at all.
    //
    // ONE companion window, not two (kwi3-55l.24's own preference over a
    // second override-redirect popup): `rect` follows `ringScreenRect`,
    // which already picked the workspace tab or the mode segment above, so
    // this Window neither knows nor cares which one it is currently over.
    Loader {
        active: Kwi3Grid.active
        sourceComponent: Component {
            Window {
                id: wsFocusHighlight
                readonly property var rect: root.ringScreenRect
                readonly property int thickness: Kwi3Grid.frameThickness
                // Off entirely when the window ring itself is off
                // (focusFrame: false) or there is nothing to mark (no focused
                // tab at rest, no visible mode segment while a layer is up) -
                // "unfocused tabs have none" generalised to "none at all
                // fires none".
                //
                // kwi3-55l.30: frameEnabled gates the AT-REST (workspace)
                // ring only. grid.get's frame.enabled is now EFFECTIVE - false
                // while kwi3's modeFrame hides the window ring for the current
                // mode (Jan's config.js: '*': 'none' for system/switcher/...)
                // - and the stripe over the mode pill is the pill's own
                // accent, independent of the window ring (kwi3-55l.27), so a
                // mode that hides the window ring must not also take the
                // pill's highlight away.
                visible: (root.currentMode === "default" ? Kwi3Grid.frameEnabled : true)
                         && rect !== null && thickness > 0
                x: rect ? rect.x : 0
                y: rect ? rect.y - thickness : 0
                width: rect ? Math.max(1, rect.w) : 1
                height: Math.max(1, thickness)
                flags: Qt.FramelessWindowHint | Qt.BypassWindowManagerHint
                title: "kwi3-bar-focus-ring"
                color: "transparent"

                // An opaque fill Rectangle, not this Window's own `color`:
                // Overlay.qml's own note applies here too - a Window's
                // `color` is not always honoured as the opaque clear colour
                // under X11/FramelessWindowHint, which would leave this
                // strip showing through to whatever the compositor-less
                // "transparent" actually renders as. Square ends (no
                // radius): a single top line has no corners to round.
                //
                // kwi3-55l.27: root.ringColor, not Kwi3Grid.frameColor
                // directly - the workspace ring's own green at rest, the
                // mode pill's own accent while a mode is up (see
                // ringColor's own comment above for why it is not
                // Kwi3Grid.frameColor unconditionally).
                Rectangle {
                    anchors.fill: parent
                    color: root.ringColor
                }
            }
        }
    }
}
