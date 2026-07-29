// d2-view — native QML viewer for a folder of d2-rendered .svg boards.
//
// Why QML and not a web page: the diagrams are 5000-7000px wide, so the whole
// interaction is pan and zoom. In a browser that means transform maths plus
// fighting native text-drag; here QtSvg rasterises the vector at whatever
// scale we ask for, and DragHandler/WheelHandler/PinchHandler are native.
//
// Launched by the `d2-view` nu wrapper:  qml6 BoardView.qml -- <dir>
// The wrapper also keeps <board>.svg fresh from <board>.d2 while this runs.
//
// Interaction: wheel = zoom at cursor · drag = pan · 0 = 1:1 · f = fit
//              1-9 = board · arrows = pan (shift = coarse) · r = reload
//
// Pass --debug to print geometry (natural size, zoom, content rect, image
// status) on every rescan/apply — QML swallows console.log unless
// QT_FORCE_STDERR_LOGGING=1, which the wrapper sets.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.folderlistmodel

ApplicationWindow {
    id: win
    visible: true
    width: 1400
    height: 900
    title: current ? current.name + " — d2-view" : "d2-view"
    color: "#14161d"

    // ---- inputs -------------------------------------------------------------

    // CLI: qml6 BoardView.qml -- <dir> [board-name] [--debug]
    readonly property var argv: Qt.application.arguments.filter(
        (a, i) => i > 0 && !a.endsWith(".qml") && !a.startsWith("-"))
    readonly property string dir: argv.length > 0 ? argv[0] : "."
    readonly property string wanted: argv.length > 1 ? argv[1] : ""

    property var boards: []            // [{file, name, w, h}]
    property int index: 0
    property bool picked: false
    readonly property var current: index >= 0 && index < boards.length
                                   ? boards[index] : null

    // Per-board view state, so switching tabs and coming back keeps your place.
    // `zoom` is a plain property, NOT derived from the map: mutating a JS map
    // and reassigning the same reference emits no change signal, so a derived
    // binding silently keeps its old value (content then sits at 1:1 while the
    // pan offsets assume the new scale — i.e. an apparently empty window).
    property var saved: ({})
    property real zoom: 1

    function defaults() { return {k: 1, x: 0, y: 0} }

    function viewOf(file) {
        if (!saved[file]) saved[file] = defaults()
        return saved[file]
    }

    function commit(v) {
        saved[current.file] = v
        zoom = v.k
        content.x = v.x
        content.y = v.y
    }

    // ---- board discovery ----------------------------------------------------

    FolderListModel {
        id: folder
        folder: "file://" + win.dir
        nameFilters: ["*.svg"]
        showDirs: false
        sortField: FolderListModel.Name
        onCountChanged: win.rescan()
    }

    // Read each svg's viewBox for its natural size. XHR over file:// is the
    // only way to see inside the file from pure QML; it is also how we notice
    // a re-render (the text changes) without a filesystem watcher.
    function readSize(path) {
        const xhr = new XMLHttpRequest()
        try {
            xhr.open("GET", "file://" + path, false)
            xhr.send()
            const m = /viewBox="([\d.\s-]+)"/.exec(xhr.responseText || "")
            if (m) {
                const p = m[1].trim().split(/\s+/).map(Number)
                return {w: p[2], h: p[3]}
            }
        } catch (e) { /* unreadable — fall through */ }
        return {w: 1000, h: 1000}
    }

    function rescan() {
        const found = []
        for (let i = 0; i < folder.count; i++) {
            const file = String(folder.get(i, "fileName"))
            if (file.startsWith("_")) continue           // _style.svg etc
            const path = win.dir + "/" + file
            const size = readSize(path)
            found.push({file: file, path: path,
                        name: file.replace(/\.svg$/, ""),
                        w: size.w, h: size.h})
        }
        boards = found
        if (index >= boards.length) index = 0
        // only once boards exist — the first rescan runs before the folder
        // model has counted, and would otherwise burn the one-shot flag
        if (wanted !== "" && !picked && boards.length > 0) {
            const i = boards.findIndex(b => b.name === wanted)
            if (i >= 0) index = i
            picked = true
        }
        log("rescan")
        if (current) fit()
    }

    Component.onCompleted: rescan()

    // ---- zoom / pan ---------------------------------------------------------

    readonly property bool debug: Qt.application.arguments.indexOf("--debug") >= 0

    function log(where) {
        if (!debug) return
        console.log(where + ": boards=" + boards.length
            + " idx=" + index
            + (current ? " board=" + current.name + " nat=" + current.w + "x" + current.h : " board=none")
            + " zoom=" + zoom.toFixed(3)
            + " content=" + Math.round(content.width) + "x" + Math.round(content.height)
            + " at=" + Math.round(content.x) + "," + Math.round(content.y)
            + " stage=" + Math.round(stage.width) + "x" + Math.round(stage.height)
            + " imgStatus=" + board.status + " painted="
            + Math.round(board.paintedWidth) + "x" + Math.round(board.paintedHeight))
    }

    function apply(k, x, y) {
        if (!current) return
        commit({k: Math.max(0.02, Math.min(16, k)), x: x, y: y})
        log("apply")
    }

    function actual() {                                   // 1:1
        if (!current) return
        apply(1, Math.min(24, (stage.width - current.w) / 2),
                 Math.min(24, (stage.height - current.h) / 2))
    }

    function fit() {
        if (!current) return
        const k = Math.min(stage.width / current.w, stage.height / current.h) * 0.97
        apply(k, (stage.width - current.w * k) / 2,
                 (stage.height - current.h * k) / 2)
    }

    function zoomAt(factor, cx, cy) {
        if (!current) return
        const v = viewOf(current.file)
        const k = Math.max(0.02, Math.min(16, v.k * factor))
        apply(k, cx - (cx - v.x) * (k / v.k), cy - (cy - v.y) * (k / v.k))
    }

    function nudge(dx, dy) {
        if (!current) return
        const v = viewOf(current.file)
        apply(v.k, v.x + dx, v.y + dy)
    }

    function select(i) {
        if (i < 0 || i >= boards.length) return
        index = i
        const v = viewOf(current.file)
        if (v.k === 1 && v.x === 0 && v.y === 0) fit()
        else commit(v)
    }

    // ---- chrome -------------------------------------------------------------

    header: ToolBar {
        background: Rectangle {
            color: "#0f1116"
            Rectangle { anchors.bottom: parent.bottom; width: parent.width
                        height: 1; color: "#262b36" }
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 6

            Label {
                text: "d2-view"
                color: "#e7e9ee"
                font.bold: true
                font.pixelSize: 14
                rightPadding: 8
            }

            Repeater {
                model: win.boards
                delegate: Button {
                    required property int index
                    required property var modelData
                    text: (index + 1) + " " + modelData.name.replace(/^\d+-/, "")
                    checkable: true
                    checked: win.index === index
                    font.pixelSize: 13
                    onClicked: win.select(index)
                    background: Rectangle {
                        radius: 6
                        color: parent.checked ? "#22304d" : "#1b1f28"
                        border.color: parent.checked ? "#6f9dff" : "#2c323f"
                    }
                    contentItem: Label {
                        text: parent.text
                        color: parent.checked ? "#ffffff" : "#c9cedb"
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            Rectangle { width: 1; height: 20; color: "#2c323f" }

            Button {
                text: "100%"
                font.pixelSize: 13
                onClicked: win.actual()
                background: Rectangle { radius: 6; color: "#1b1f28"
                                        border.color: "#2c323f" }
                contentItem: Label { text: parent.text; color: "#c9cedb"
                                     font: parent.font }
            }
            Button {
                text: "fit"
                font.pixelSize: 13
                onClicked: win.fit()
                background: Rectangle { radius: 6; color: "#1b1f28"
                                        border.color: "#2c323f" }
                contentItem: Label { text: parent.text; color: "#c9cedb"
                                     font: parent.font }
            }
            Label {
                text: Math.round(win.zoom * 100) + "%"
                color: "#aab3c0"
                font.pixelSize: 13
                Layout.minimumWidth: 46
            }

            Rectangle { width: 1; height: 20; color: "#2c323f" }

            Rectangle {
                width: 9; height: 9; radius: 5
                color: reloadFlash.running ? "#f2ca6b" : "#5fd08a"
            }
            Label {
                text: current ? current.w + "×" + current.h : ""
                color: "#7f8798"
                font.pixelSize: 12
            }

            Item { Layout.fillWidth: true }

            Label {
                text: "wheel zoom · drag pan · 0 = 1:1 · f = fit · 1-9 board"
                color: "#7f8798"
                font.pixelSize: 12
            }
        }
    }

    // ---- stage --------------------------------------------------------------

    Item {
        id: stage
        anchors.fill: parent
        clip: true

        Item {
            id: content
            width: current ? current.w * win.zoom : 0
            height: current ? current.h * win.zoom : 0

            Image {
                id: board
                anchors.fill: parent
                source: current ? "file://" + current.path + "?v=" + reloadToken : ""
                // rasterise the vector at the displayed size, so text stays
                // crisp instead of scaling a fixed-size bitmap
                sourceSize.width: Math.min(8192, Math.round(width))
                sourceSize.height: Math.min(8192, Math.round(height))
                cache: false
                smooth: true
                asynchronous: true
            }
        }

        DragHandler {
            target: content
            onActiveChanged: {
                if (!active && current) {
                    const v = viewOf(current.file)
                    win.apply(v.k, content.x, content.y)
                }
            }
        }

        WheelHandler {
            acceptedModifiers: Qt.NoModifier
            onWheel: (ev) => win.zoomAt(Math.exp(ev.angleDelta.y * 0.0016),
                                        ev.x, ev.y)
        }

        PinchHandler {
            target: null
            onActiveScaleChanged: win.zoomAt(activeScale > 1 ? 1.03 : 0.97,
                                             centroid.position.x,
                                             centroid.position.y)
        }

        TapHandler {
            onDoubleTapped: win.actual()
        }

        onWidthChanged: if (current) win.fit()
    }

    // ---- live reload --------------------------------------------------------
    // Poll the current board's svg; when its byte length changes the wrapper
    // has re-rendered it, so bump the token to force Image to re-read.

    property int reloadToken: 0
    property int lastLen: 0

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            if (!current) return
            const xhr = new XMLHttpRequest()
            try {
                xhr.open("GET", "file://" + current.path, false)
                xhr.send()
                const len = (xhr.responseText || "").length
                if (lastLen !== 0 && len !== lastLen) {
                    win.rescan()                 // viewBox may have changed too
                    reloadToken++
                    reloadFlash.restart()
                }
                lastLen = len
            } catch (e) { /* mid-write; try again next tick */ }
        }
    }

    Timer { id: reloadFlash; interval: 700 }

    // ---- keys ---------------------------------------------------------------

    Shortcut { sequence: "0"; onActivated: win.actual() }
    Shortcut { sequence: "f"; onActivated: win.fit() }
    Shortcut { sequence: "r"; onActivated: { win.rescan(); win.reloadToken++ } }
    Shortcut { sequence: "Ctrl+W"; onActivated: Qt.quit() }
    Shortcut { sequence: "Ctrl+Q"; onActivated: Qt.quit() }
    Shortcut { sequence: "Left";  onActivated: win.nudge(80, 0) }
    Shortcut { sequence: "Right"; onActivated: win.nudge(-80, 0) }
    Shortcut { sequence: "Up";    onActivated: win.nudge(0, 80) }
    Shortcut { sequence: "Down";  onActivated: win.nudge(0, -80) }
    Shortcut { sequence: "Shift+Left";  onActivated: win.nudge(400, 0) }
    Shortcut { sequence: "Shift+Right"; onActivated: win.nudge(-400, 0) }
    Shortcut { sequence: "Shift+Up";    onActivated: win.nudge(0, 400) }
    Shortcut { sequence: "Shift+Down";  onActivated: win.nudge(0, -400) }
    Shortcut { sequence: "["; onActivated: win.select(win.index - 1) }
    Shortcut { sequence: "]"; onActivated: win.select(win.index + 1) }

    Repeater {
        model: 9
        delegate: Item {
            required property int index
            Shortcut {
                sequence: String(index + 1)
                onActivated: win.select(index)
            }
        }
    }
}
