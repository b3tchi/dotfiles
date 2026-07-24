import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import QtQuick.Window
import "./Common"

Scope {
    id: root

    // WM detection
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null
    readonly property string wmMsg: isSway ? "swaymsg" : "i3-msg"

    // ── Shared ──
    // NOTE: fontFamily/fontSize are retained ONLY for the switcher UI, which
    // stays hand-rolled in this task (T4 refactors it onto Combo). Launcher and
    // projects now source every constant from DialogTheme via Combo/delegate.

    readonly property string fontFamily: "Iosevka Nerd Font"
    readonly property int fontSize: isSway ? 14 : 16

    property string mode: "" // "launcher", "switcher", or "projects"

    Process {
        id: execProc
        running: false
    }

    function hide() {
        overlay.visible = false
        mode = ""
    }

    // ── Launcher state ──
    // The launcher is a Combo (Common/Combo.qml) over the flat list of $PATH
    // executable basenames. Combo owns the search text, the fuzzy filtering
    // (via Common/Fuzzy.qml), the selection index, and the keyboard contract;
    // this scope only feeds the model and handles confirm (exec) / cancel.

    property var launcherAllApps: []
    property var _appBuffer: []

    Process {
        id: pathScanner
        running: true
        // find -L follows symlinks so rotz-linked bins in ~/.local/bin (which
        // are symlinks) appear; -type f on the RESOLVED target keeps broken
        // symlinks out (their target does not stat, so they never match -type
        // f, and find's warning is swallowed by 2>/dev/null). Without -L the
        // symlink itself is type 'l', so every symlinked bin is invisible — the
        // drift the overlay/shell.qml copy carried and config/Overlay.qml did
        // not.
        command: ["sh", "-c",
            "echo $PATH | tr ':' '\\n' | xargs -I{} find -L {} -maxdepth 1 -executable -type f 2>/dev/null | sed 's|.*/||' | sort -u"]
        stdout: SplitParser {
            onRead: data => {
                var trimmed = data.trim()
                if (trimmed !== "") root._appBuffer.push(trimmed)
            }
        }
        onExited: {
            root.launcherAllApps = root._appBuffer
            root._appBuffer = []
        }
    }

    function launcherShow() {
        mode = "launcher"
        overlay.width = DialogTheme.width
        overlay.visible = true
        Qt.callLater(function() { launcherCombo.forceFocus() })
        // Rescan $PATH executables so newly installed bins appear without quickshell restart.
        if (!pathScanner.running) {
            root._appBuffer = []
            pathScanner.running = true
        }
    }

    // Confirm handler — receives the selected ROW OBJECT from Combo, which for
    // the launcher is the bin-name string itself (adr0010: never a position).
    function launcherLaunch(name) {
        if (name) {
            execProc.command = ["sh", "-c", "setsid -f " + name + " >/dev/null 2>&1 </dev/null"]
            execProc.running = true
        }
        hide()
    }

    // ── Switcher state ──
    // Left hand-rolled in this task; T4 moves it onto Combo (filterMode
    // "external", dual-field name-OR-ws scoring stays caller-side). The only
    // change here is mechanical: the scored match + match-char highlight now
    // come from Common/Fuzzy.qml (the local bodies were deleted with the
    // launcher/projects refactor).

    property int switcherIndex: 0
    property var switcherWindows: []
    property string switcherSearch: ""

    property var switcherFiltered: {
        if (switcherSearch === "") return switcherWindows
        var result = []
        for (var i = 0; i < switcherWindows.length; i++) {
            var w = switcherWindows[i]
            var nameMatch = Fuzzy.match(w.name, switcherSearch)
            var wsMatch = Fuzzy.match(w.ws, switcherSearch)
            var best = nameMatch.score >= wsMatch.score ? nameMatch : wsMatch
            if (nameMatch.matched || wsMatch.matched)
                result.push({
                    id: w.id, name: w.name, focused: w.focused,
                    urgent: w.urgent, cls: w.cls, ws: w.ws,
                    score: best.score,
                    nameIndices: nameMatch.matched ? nameMatch.indices : [],
                    wsIndices: wsMatch.matched ? wsMatch.indices : []
                })
        }
        result.sort(function(a, b) { return b.score - a.score })
        return result
    }

    // MRU focus history — list of i3 container ids, most-recent first.
    // Maintained by windowSubscriber from live i3 window::focus events.
    property var focusHistory: []

    Process {
        id: windowSubscriber
        running: true
        command: [root.wmMsg, "-t", "subscribe", "-m", '["window"]']
        stdout: SplitParser {
            onRead: data => {
                try {
                    var e = JSON.parse(data)
                    if (!e.change || !e.container) return
                    var id = e.container.id
                    if (e.change === "focus") {
                        var h = root.focusHistory.slice()
                        var idx = h.indexOf(id)
                        if (idx >= 0) h.splice(idx, 1)
                        h.unshift(id)
                        if (h.length > 50) h.length = 50
                        root.focusHistory = h
                    } else if (e.change === "close") {
                        var h2 = root.focusHistory.slice()
                        var idx2 = h2.indexOf(id)
                        if (idx2 >= 0) {
                            h2.splice(idx2, 1)
                            root.focusHistory = h2
                        }
                    }
                } catch(err) {}
            }
        }
        onExited: running = true
    }

    // Window scanner — collects JSON then parses
    property string _scanBuffer: ""

    Process {
        id: windowScanner
        running: false
        command: ["sh", "-c", root.wmMsg + " -t get_tree"]
        stdout: SplitParser {
            onRead: data => { root._scanBuffer += data }
        }
        onExited: {
            try {
                var tree = JSON.parse(root._scanBuffer)
                var wins = []
                function walk(node, wsName) {
                    if (node.type === "workspace") wsName = node.name || wsName
                    // i3 / Xwayland clients carry an X11 window id in `window`;
                    // sway's native Wayland clients leave it null and expose
                    // `app_id` instead. Accept either so the switcher works on
                    // both compositors.
                    var isWindow = (node.type === "con" || node.type === "floating_con") &&
                                   (node.window || node.app_id) && node.name
                    if (isWindow &&
                        node.name !== "quickshell" && node.name !== "qs-switcher" && node.name !== "qs-launcher" && node.name !== "qs-projects") {
                        wins.push({
                            id: node.id,
                            name: node.name,
                            focused: node.focused,
                            urgent: node.urgent || false,
                            cls: node.app_id || (node.window_properties || {})["class"] || "",
                            ws: wsName || ""
                        })
                    }
                    var children = (node.nodes || []).concat(node.floating_nodes || [])
                    for (var i = 0; i < children.length; i++) walk(children[i], wsName)
                }
                walk(tree)
                // Sort by MRU: currently focused always first, then focusHistory
                // order, then any windows we haven't seen focused yet (rank 9999).
                var rank = {}
                for (var r = 0; r < root.focusHistory.length; r++)
                    rank[root.focusHistory[r]] = r
                wins.sort(function(a, b) {
                    if (a.focused) return -1
                    if (b.focused) return 1
                    var ra = rank[a.id] !== undefined ? rank[a.id] : 9999
                    var rb = rank[b.id] !== undefined ? rank[b.id] : 9999
                    return ra - rb
                })
                root.switcherWindows = wins
                // Pre-select the previous MRU window (classic alt-tab toggle).
                root.switcherIndex = wins.length > 1 ? 1 : 0
                // Now show
                overlay.visible = true
            } catch(e) {}
            root._scanBuffer = ""
        }
    }

    Process {
        id: focusProc
        running: false
    }

    // ── Global key monitor via XI2 raw events ──
    // Tracks Super/Alt/Tab press+release from the X server directly, bypassing
    // Qt focus — necessary because when i3 fires the switcher the overlay window
    // doesn't exist yet, so its Keys.onReleased never sees the Super release.
    // Uses a Python helper with python-xlib that calls XISelectEvents on the
    // root window for XI_RawKeyPress/Release; does NOT create a client window
    // (the earlier `xinput test-xi2` approach did, leaving a 1115x1013 empty
    // frame in the i3 tree).

    property bool modHeld: false
    property bool shiftHeld: false

    Process {
        id: keyMonitor
        // X11 only (python-xlib XI2 events). QS_NO_KEYMON=1 suppresses the
        // respawn entirely on headless test displays, where the python helper
        // would churn against a keyboard-less Xvfb.
        running: !root.isSway && Quickshell.env("QS_NO_KEYMON") !== "1"
        command: ["sh", "-c", "exec python3 -u $HOME/.dotfiles/quickshell/qs-keymon.py"]
        stdout: SplitParser {
            onRead: data => {
                var parts = data.trim().split(" ")
                if (parts.length !== 2) return
                var action = parts[0]  // "press" or "release"
                var code = parseInt(parts[1])

                // 64=Alt_L, 108=Alt_R, 133=Super_L, 134=Super_R
                var isMod = (code === 64 || code === 108 || code === 133 || code === 134)
                // 23=Tab, 25=W — both trigger the switcher
                var isSwitcherKey = (code === 23 || code === 25)
                // 50=Shift_L, 62=Shift_R
                var isShift = (code === 50 || code === 62)

                // 65=Space
                var isSpace = (code === 65)

                if (isShift) {
                    root.shiftHeld = (action === "press")
                } else if (isMod && action === "press") {
                    root.modHeld = true
                } else if (isMod && action === "release") {
                    root.modHeld = false
                    if (root.mode === "switcher" && overlay.visible)
                        root.switcherFocus()
                } else if (isSpace && action === "press" && root.modHeld && root.mode === "switcher") {
                    root.switcherSearchMode()
                } else if (isSwitcherKey && action === "press" && root.modHeld) {
                    if (root.mode === "switcher" || root.mode === "switcher-search") {
                        if (root.shiftHeld) root.switcherPrev()
                        else root.switcherNext()
                    } else {
                        root.switcherShow()
                    }
                }
            }
        }
        onExited: running = true  // restart if it dies
    }

    function switcherShow() {
        _scanBuffer = ""
        switcherSearch = ""
        mode = "switcher"
        overlay.width = 640
        windowScanner.running = true
        // overlay.visible set in windowScanner.onExited after windows load
    }

    function switcherSearchMode() {
        mode = "switcher-search"
        switcherSearch = ""
        switcherIndex = 0
        switcherSearchInput.text = ""
        switcherSearchInput.forceActiveFocus()
        // Clear the space that triggered search mode (arrives after focus)
        Qt.callLater(function() { switcherSearchInput.text = ""; switcherSearch = "" })
    }

    function switcherNext() {
        if (!overlay.visible) overlay.visible = true
        var list = switcherFiltered
        switcherIndex = switcherIndex < list.length - 1
            ? switcherIndex + 1 : 0
    }

    function switcherPrev() {
        if (!overlay.visible) overlay.visible = true
        var list = switcherFiltered
        switcherIndex = switcherIndex > 0
            ? switcherIndex - 1 : list.length - 1
    }

    function switcherFocus() {
        var list = switcherFiltered
        if (list.length > 0 && switcherIndex < list.length) {
            var win = list[switcherIndex]
            focusProc.command = [root.wmMsg, "[con_id=" + win.id + "]", "focus"]
            focusProc.running = true
        }
        hide()
    }

    // ── Projects state ──
    // A Combo over the project registry (projects.yaml × current workspaces).
    // Enter switches to the project's workspace (confirm); Shift+Enter creates
    // the next indexed workspace, renaming the bare one first (confirmAlt →
    // projectsNew). Combo owns filter/index/keys; this scope feeds the model
    // (projectsAll, from projectsScanner) and the two confirm actions.

    property var projectsAll: []      // [{name, workspaces: ["dotfiles", "dotfiles_1"]}]
    property var _projectsBuffer: ""

    // Scans projects.yaml + current workspaces, outputs JSON
    Process {
        id: projectsScanner
        running: false
        command: ["sh", "-c",
            "PROJECTS=$(grep -E '^  [a-zA-Z]' ~/.config/project/projects.yaml 2>/dev/null | sed 's/^ *//;s/:.*//' | tr '\\n' ' '); " +
            "WS_JSON=$(" + root.wmMsg + " -t get_workspaces 2>/dev/null || echo '[]'); " +
            "FOCUSED=$(echo \"$WS_JSON\" | sed 's/},{/}\\n{/g' | grep '\"focused\":true' | sed 's/.*\"name\":\"\\([^\"]*\\)\".*/\\1/'); " +
            "WS_NAMES=$(echo \"$WS_JSON\" | sed 's/},{/}\\n{/g' | sed -n 's/.*\"name\":\"\\([^\"]*\\)\".*/\\1/p'); " +
            "printf '{\"projects\":['; SEP=''; " +
            "for p in $PROJECTS; do " +
            "  MATCHED=$(echo \"$WS_NAMES\" | grep -E \"^${p}$|^${p}_[0-9]+$\" | sed 's/.*/\"&\"/' | tr '\\n' ',' | sed 's/,$//'); " +
            "  printf '%s{\"name\":\"%s\",\"workspaces\":[%s]}' \"$SEP\" \"$p\" \"$MATCHED\"; SEP=','; " +
            "done; " +
            "printf '],\"focused\":\"%s\"}' \"$FOCUSED\""
        ]
        stdout: SplitParser {
            onRead: data => { root._projectsBuffer += data }
        }
        onExited: {
            try {
                var data = JSON.parse(root._projectsBuffer)
                // Determine focused project to filter out
                var focused = data.focused || ""
                var focusedProject = ""
                for (var i = 0; i < data.projects.length; i++) {
                    var p = data.projects[i]
                    if (focused === p.name) { focusedProject = p.name; break }
                    for (var j = 0; j < p.workspaces.length; j++) {
                        if (p.workspaces[j] === focused) { focusedProject = p.name; break }
                    }
                    if (focusedProject) break
                }
                // Filter out current project
                var filtered = []
                for (var k = 0; k < data.projects.length; k++) {
                    if (data.projects[k].name !== focusedProject)
                        filtered.push(data.projects[k])
                }
                root.projectsAll = filtered
            } catch(e) {
                root.projectsAll = []
            }
            root._projectsBuffer = ""
            overlay.visible = true
            Qt.callLater(function() { projectsCombo.forceFocus() })
        }
    }

    Process {
        id: projectsWmProc
        running: false
    }

    function projectsShow() {
        _projectsBuffer = ""
        mode = "projects"
        overlay.width = DialogTheme.width
        projectsScanner.running = true
    }

    // Confirm handler — receives the selected project ROW OBJECT from Combo.
    function projectsSwitch(p) {
        if (p) {
            var wsName = p.workspaces.length > 0 ? p.workspaces[0] : p.name
            projectsWmProc.command = [root.wmMsg, "workspace", wsName]
            projectsWmProc.running = true
        }
        hide()
    }

    // Alt-confirm handler (Shift+Enter) — receives the selected project ROW.
    function projectsNew(p) {
        if (p) {
            if (p.workspaces.length === 0) {
                projectsWmProc.command = [root.wmMsg, "workspace", p.name]
            } else {
                // Rename bare name to _1 if needed, then create next index
                var cmds = []
                var hasBare = false
                var maxIdx = 0
                for (var i = 0; i < p.workspaces.length; i++) {
                    if (p.workspaces[i] === p.name) hasBare = true
                    var m = p.workspaces[i].match(new RegExp("^" + p.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + "_(\\d+)$"))
                    if (m) { var n = parseInt(m[1]); if (n > maxIdx) maxIdx = n }
                }
                if (hasBare) {
                    cmds.push(root.wmMsg + " rename workspace \\\"" + p.name + "\\\" to \\\"" + p.name + "_1\\\"")

                    if (maxIdx < 1) maxIdx = 1
                }
                var next = maxIdx + 1
                cmds.push(root.wmMsg + " workspace " + p.name + "_" + next)
                projectsWmProc.command = ["sh", "-c", cmds.join(" && ")]
            }
            projectsWmProc.running = true
        }
        hide()
    }

    // ── IPC ──

    IpcHandler {
        target: "launcher"
        function toggle() {
            if (overlay.visible && root.mode === "launcher") root.hide()
            else root.launcherShow()
        }
    }

    IpcHandler {
        target: "switcher"
        function toggle() {
            if (overlay.visible && root.mode === "switcher") root.hide()
            else root.switcherShow()
        }
        function next() {
            if (root.mode === "switcher") {
                root.switcherNext()
            } else {
                root.switcherShow()
            }
        }
        function prev() {
            if (root.mode === "switcher") {
                root.switcherPrev()
            } else {
                root.switcherShow()
            }
        }
        function confirm() {
            root.switcherFocus()
        }
        function cancel() {
            root.hide()
        }
        function search() {
            // Sway path: Alt+Space is captured by the Windows host on WSLg
            // before sway sees it, so we expose a separate IPC entry that
            // a different bindsym (e.g. $mod+slash) can invoke to drop into
            // switcher-search.
            if (root.mode === "switcher" || root.mode === "switcher-search") {
                root.switcherSearchMode()
            } else {
                root.switcherShow()
                root.switcherSearchMode()
            }
        }
    }

    IpcHandler {
        target: "projects"
        function toggle() {
            if (overlay.visible && root.mode === "projects") root.hide()
            else root.projectsShow()
        }
    }

    // ── Single window ──

    Window {
        id: overlay
        visible: false
        width: DialogTheme.width
        height: {
            if (root.mode === "launcher")
                return launcherCombo.implicitHeight
            if (root.mode === "switcher")
                return Math.max(root.switcherFiltered.length, 1) * 32 + 8
            if (root.mode === "switcher-search")
                return 32 + Math.min(root.switcherFiltered.length, 8) * 32 + 8
            if (root.mode === "projects")
                return projectsCombo.implicitHeight
            return 100
        }
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: DialogTheme.bodyBg
        title: root.mode === "switcher" ? "qs-switcher" : root.mode === "projects" ? "qs-projects" : "qs-launcher"

        // Explicit opaque background. Qt.Window has a `color` property but on
        // quickshell under X11 with FramelessWindowHint it isn't always honored
        // as the opaque clear color, leaving the ListView topMargin/bottomMargin
        // as transparent strips above/below the rows. A full-fill Rectangle is
        // cheap and removes the ambiguity.
        Rectangle {
            anchors.fill: parent
            color: DialogTheme.bodyBg
            z: -1
        }

        onActiveChanged: {
            if (!active && visible && (root.mode === "launcher" || root.mode === "projects")) root.hide()
        }

        // ── Launcher UI (Combo) ──
        Combo {
            id: launcherCombo
            anchors.fill: parent
            visible: root.mode === "launcher"
            model: root.launcherAllApps
            textOf: (function(r) { return r })   // rows are bare bin-name strings
            placeholder: "run"

            onConfirm: (row) => root.launcherLaunch(row)
            onCancel: () => root.hide()

            delegate: Component {
                Rectangle {
                    anchors.fill: parent
                    color: isSelected ? DialogTheme.inputBg : "transparent"

                    Rectangle {
                        visible: isSelected
                        width: 4; height: parent.height
                        color: DialogTheme.accent
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: DialogTheme.textLeftMargin
                        text: Fuzzy.highlight(row, matchIndices)
                        textFormat: Text.RichText
                        color: DialogTheme.fg
                        font.family: DialogTheme.font
                        font.pixelSize: DialogTheme.fontSize
                        renderType: Text.NativeRendering
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.launcherLaunch(row)
                    }
                }
            }
        }

        // ── Switcher UI (also used for switcher-search) ──
        // Hand-rolled; T4 moves it onto Combo. Only the match-highlight call
        // (now Fuzzy.highlight) changed here.
        Column {
            anchors.fill: parent
            visible: root.mode === "switcher" || root.mode === "switcher-search"

            // Search bar (only in search mode)
            Rectangle {
                visible: root.mode === "switcher-search"
                width: parent.width
                height: 32
                color: "#152024"

                TextInput {
                    id: switcherSearchInput
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#FDF6E3"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    clip: true

                    onTextChanged: {
                        root.switcherSearch = text
                        root.switcherIndex = 0
                    }

                    Keys.onEscapePressed: root.hide()
                    Keys.onReturnPressed: root.switcherFocus()
                    Keys.onEnterPressed: root.switcherFocus()
                    Keys.onDownPressed: root.switcherNext()
                    Keys.onUpPressed: root.switcherPrev()
                }

                Text {
                    anchors.fill: switcherSearchInput
                    verticalAlignment: Text.AlignVCenter
                    text: "search windows"
                    color: "#707880"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                    visible: !switcherSearchInput.text
                }
            }

            // Window list
            Item {
                width: parent.width
                height: parent.height - (root.mode === "switcher-search" ? 32 : 0)
                focus: root.mode === "switcher"

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Down) {
                        root.switcherNext()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Up) {
                        root.switcherPrev()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.switcherFocus()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Escape) {
                        root.hide()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Space) {
                        // Mirror X11 keyMonitor behaviour: while modifier is
                        // held in switcher mode, Space drops into search.
                        root.switcherSearchMode()
                        event.accepted = true
                    }
                }
                // Sway path: when the user releases the modifier (Alt, the sway
                // $mod) while the switcher is up, commit the selection. On X11
                // the keyMonitor (XI2 raw events) handles this globally; under
                // Wayland the compositor delivers the modifier release to the
                // focused surface, so Qt's Keys.onReleased fires here directly.
                Keys.onReleased: event => {
                    if (!root.isSway) return
                    if (event.key === Qt.Key_Alt || event.key === Qt.Key_AltGr ||
                        event.key === Qt.Key_Meta ||
                        event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R) {
                        if (root.mode === "switcher" && overlay.visible)
                            root.switcherFocus()
                        event.accepted = true
                    }
                }

                ListView {
                    anchors.fill: parent
                    anchors.topMargin: 4
                    anchors.bottomMargin: 4
                    model: root.switcherFiltered.length
                    clip: true
                    currentIndex: root.switcherIndex

                    delegate: Rectangle {
                        required property int index
                        property var item: root.switcherFiltered[index]
                        property bool isSelected: index === root.switcherIndex

                        width: parent ? parent.width : 0
                        height: 32
                        color: isSelected ? "#152024" : "transparent"

                        Rectangle {
                            visible: isSelected
                            width: 4; height: parent.height
                            color: item.urgent ? "#CB4B16" : "#16a085"
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.right: clsText.left
                            anchors.rightMargin: 8
                            text: (root.mode === "switcher-search" && item.nameIndices && item.nameIndices.length > 0) ? Fuzzy.highlight(item.name, item.nameIndices) : item.name
                            textFormat: root.mode === "switcher-search" ? Text.RichText : Text.PlainText
                            color: item.focused ? "#707880" : "#FDF6E3"
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            renderType: Text.NativeRendering
                            elide: Text.ElideRight
                        }

                        Text {
                            id: clsText
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            text: (root.mode === "switcher-search" && item.wsIndices && item.wsIndices.length > 0) ? Fuzzy.highlight(item.ws, item.wsIndices) : item.ws
                            textFormat: root.mode === "switcher-search" ? Text.RichText : Text.PlainText
                            color: "#707880"
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            renderType: Text.NativeRendering
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: { root.switcherIndex = index; root.switcherFocus() }
                        }
                    }
                }
            }
        }

        // ── Projects UI (Combo) ──
        Combo {
            id: projectsCombo
            anchors.fill: parent
            visible: root.mode === "projects"
            model: root.projectsAll
            altConfirmEnabled: true               // Shift+Enter → projectsNew
            placeholder: "project"

            onConfirm: (row) => root.projectsSwitch(row)
            onConfirmAlt: (row) => root.projectsNew(row)
            onCancel: () => root.hide()

            delegate: Component {
                Rectangle {
                    anchors.fill: parent
                    color: isSelected ? DialogTheme.inputBg : "transparent"

                    Rectangle {
                        visible: isSelected
                        width: 4; height: parent.height
                        color: DialogTheme.accent
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: DialogTheme.textLeftMargin
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        spacing: 8

                        Text {
                            text: Fuzzy.highlight(row.name, matchIndices)
                            textFormat: Text.RichText
                            color: DialogTheme.fg
                            font.family: DialogTheme.font
                            font.pixelSize: DialogTheme.fontSize
                            font.bold: false
                            renderType: Text.NativeRendering
                        }

                        Text {
                            text: row.workspaces.length > 0 ? "[" + row.workspaces.join(", ") + "]" : ""
                            color: DialogTheme.muted
                            font.family: DialogTheme.font
                            font.pixelSize: DialogTheme.fontSize
                            renderType: Text.NativeRendering
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.projectsSwitch(row)
                    }
                }
            }
        }
    }
}
