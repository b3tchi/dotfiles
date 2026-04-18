import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import QtQuick.Window

ShellRoot {
    id: root

    // WM detection
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null
    readonly property string wmMsg: isSway ? "swaymsg" : "i3-msg"

    // ── Shared ──

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

    property int launcherIndex: 0
    property string launcherSearch: ""
    property var launcherAllApps: []
    property var _appBuffer: []

    function fuzzyMatch(text, pattern) {
        if (!pattern) return { matched: true, score: 0, indices: [] }
        if (!text) return { matched: false, score: 0, indices: [] }

        var lower = text.toLowerCase()
        var pat = pattern.toLowerCase()
        var ti = 0, pi = 0
        var indices = []
        var score = 0
        var prevMatched = false

        while (ti < lower.length && pi < pat.length) {
            if (lower[ti] === pat[pi]) {
                indices.push(ti)
                if (prevMatched) score += 5
                if (ti === 0 || text[ti - 1] === ' ' || text[ti - 1] === '-')
                    score += 10
                score += 1
                pi++
                prevMatched = true
            } else {
                prevMatched = false
            }
            ti++
        }

        return { matched: pi === pat.length, score: score, indices: indices }
    }

    function highlightMatch(text, indices) {
        if (!indices || indices.length === 0) return text
        var result = ""
        var matchSet = {}
        for (var i = 0; i < indices.length; i++) matchSet[indices[i]] = true
        for (var j = 0; j < text.length; j++) {
            if (matchSet[j])
                result += "<font color='#16a085'><b>" + text[j] + "</b></font>"
            else
                result += text[j]
        }
        return result
    }

    property var launcherFiltered: {
        var result = []
        var search = launcherSearch
        for (var i = 0; i < launcherAllApps.length; i++) {
            var name = launcherAllApps[i]
            var m = fuzzyMatch(name, search)
            if (m.matched)
                result.push({ name: name, score: m.score, indices: m.indices })
        }
        result.sort(function(a, b) {
            if (search) {
                if (b.score !== a.score) return b.score - a.score
            }
            return a.name.localeCompare(b.name)
        })
        return result
    }

    Process {
        id: pathScanner
        running: true
        command: ["sh", "-c",
            "echo $PATH | tr ':' '\\n' | xargs -I{} find {} -maxdepth 1 -executable -type f 2>/dev/null | sed 's|.*/||' | sort -u"]
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
        launcherIndex = 0
        launcherSearch = ""
        launcherInput.text = ""
        mode = "launcher"
        overlay.width = 480
        overlay.visible = true
        launcherInput.forceActiveFocus()
    }

    function launcherLaunch() {
        if (launcherFiltered.length > 0 && launcherIndex < launcherFiltered.length) {
            execProc.command = ["sh", "-c", launcherFiltered[launcherIndex].name + " &"]
            execProc.running = true
        }
        hide()
    }

    // ── Switcher state ──

    property int switcherIndex: 0
    property var switcherWindows: []

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
                    if (node.window && node.name && node.type === "con" &&
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
        running: !root.isSway  // X11 only — python-xlib XI2 events
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

                if (isShift) {
                    root.shiftHeld = (action === "press")
                } else if (isMod && action === "press") {
                    root.modHeld = true
                } else if (isMod && action === "release") {
                    root.modHeld = false
                    if (root.mode === "switcher" && overlay.visible)
                        root.switcherFocus()
                } else if (isSwitcherKey && action === "press" && root.modHeld) {
                    if (root.mode === "switcher") {
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
        mode = "switcher"
        overlay.width = 640
        windowScanner.running = true
        // overlay.visible set in windowScanner.onExited after windows load
    }

    function switcherNext() {
        if (!overlay.visible) overlay.visible = true
        switcherIndex = switcherIndex < switcherWindows.length - 1
            ? switcherIndex + 1 : 0
    }

    function switcherPrev() {
        if (!overlay.visible) overlay.visible = true
        switcherIndex = switcherIndex > 0
            ? switcherIndex - 1 : switcherWindows.length - 1
    }

    function switcherFocus() {
        if (switcherWindows.length > 0 && switcherIndex < switcherWindows.length) {
            var win = switcherWindows[switcherIndex]
            focusProc.command = [root.wmMsg, "[con_id=" + win.id + "]", "focus"]
            focusProc.running = true
        }
        hide()
    }

    // ── Projects state ──

    property int projectsIndex: 0
    property string projectsSearch: ""
    property var projectsAll: []      // [{name, workspaces: ["dotfiles", "dotfiles_1"]}]
    property var _projectsBuffer: ""

    property var projectsFiltered: {
        var result = []
        var search = projectsSearch
        for (var i = 0; i < projectsAll.length; i++) {
            var p = projectsAll[i]
            var m = fuzzyMatch(p.name, search)
            if (m.matched)
                result.push({ name: p.name, workspaces: p.workspaces, score: m.score, indices: m.indices })
        }
        result.sort(function(a, b) {
            if (search) {
                if (b.score !== a.score) return b.score - a.score
            }
            return a.name.localeCompare(b.name)
        })
        return result
    }

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
            projectsInput.forceActiveFocus()
        }
    }

    Process {
        id: projectsWmProc
        running: false
    }

    function projectsShow() {
        _projectsBuffer = ""
        projectsIndex = 0
        projectsSearch = ""
        projectsInput.text = ""
        mode = "projects"
        overlay.width = 480
        projectsScanner.running = true
    }

    function projectsSwitch() {
        if (projectsFiltered.length > 0 && projectsIndex < projectsFiltered.length) {
            var p = projectsFiltered[projectsIndex]
            var wsName = p.workspaces.length > 0 ? p.workspaces[0] : p.name
            projectsWmProc.command = [root.wmMsg, "workspace", wsName]
            projectsWmProc.running = true
        }
        hide()
    }

    function projectsNew() {
        if (projectsFiltered.length > 0 && projectsIndex < projectsFiltered.length) {
            var p = projectsFiltered[projectsIndex]
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
        width: 480
        height: {
            if (root.mode === "launcher")
                return 32 + Math.min(root.launcherFiltered.length, 8) * 32 + 8
            if (root.mode === "switcher")
                return Math.max(root.switcherWindows.length, 1) * 32 + 8
            if (root.mode === "projects")
                return 32 + Math.min(root.projectsFiltered.length, 8) * 32 + 8
            return 100
        }
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "#222D31"
        title: root.mode === "switcher" ? "qs-switcher" : root.mode === "projects" ? "qs-projects" : "qs-launcher"

        // Explicit opaque background. Qt.Window has a `color` property but on
        // quickshell under X11 with FramelessWindowHint it isn't always honored
        // as the opaque clear color, leaving the ListView topMargin/bottomMargin
        // as transparent strips above/below the rows. A full-fill Rectangle is
        // cheap and removes the ambiguity.
        Rectangle {
            anchors.fill: parent
            color: "#222D31"
            z: -1
        }

        onActiveChanged: {
            if (!active && visible && (root.mode === "launcher" || root.mode === "projects")) root.hide()
        }

        // ── Launcher UI ──
        Column {
            anchors.fill: parent
            visible: root.mode === "launcher"

            Rectangle {
                width: parent.width
                height: 32
                color: "#152024"

                TextInput {
                    id: launcherInput
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#FDF6E3"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    clip: true

                    onTextChanged: {
                        root.launcherSearch = text
                        root.launcherIndex = 0
                    }

                    Keys.onEscapePressed: root.hide()
                    Keys.onReturnPressed: root.launcherLaunch()
                    Keys.onEnterPressed: root.launcherLaunch()
                    Keys.onDownPressed: {
                        if (root.launcherIndex < root.launcherFiltered.length - 1)
                            root.launcherIndex++
                    }
                    Keys.onUpPressed: {
                        if (root.launcherIndex > 0)
                            root.launcherIndex--
                    }
                }

                Text {
                    anchors.fill: launcherInput
                    verticalAlignment: Text.AlignVCenter
                    text: "run"
                    color: "#707880"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                    visible: !launcherInput.text
                }
            }

            ListView {
                width: parent.width
                height: Math.min(root.launcherFiltered.length, 8) * 32 + 8
                model: root.launcherFiltered.length
                clip: true
                currentIndex: root.launcherIndex

                delegate: Rectangle {
                    required property int index
                    property var item: root.launcherFiltered[index]
                    property bool isSelected: index === root.launcherIndex

                    width: parent ? parent.width : 0
                    height: 32
                    color: isSelected ? "#152024" : "transparent"

                    Rectangle {
                        visible: isSelected
                        width: 4; height: parent.height
                        color: "#16a085"
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        text: root.highlightMatch(item.name, item.indices)
                        textFormat: Text.RichText
                        color: "#FDF6E3"
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize
                        renderType: Text.NativeRendering
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.launcherIndex = index; root.launcherLaunch() }
                    }
                }
            }
        }

        // ── Switcher UI ──
        Item {
            anchors.fill: parent
            visible: root.mode === "switcher"
            focus: root.mode === "switcher"

            // Tab navigation and mod-release are handled by the global xinput
            // keymon outside Qt focus — do NOT also handle them here or every
            // Tab press after the overlay gains focus fires twice.
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
                }
            }

            ListView {
                anchors.fill: parent
                anchors.topMargin: 4
                anchors.bottomMargin: 4
                model: root.switcherWindows.length
                clip: true
                currentIndex: root.switcherIndex

                delegate: Rectangle {
                    required property int index
                    property var item: root.switcherWindows[index]
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
                        text: item.name
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
                        text: item.ws
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

        // ── Projects UI ──
        Column {
            anchors.fill: parent
            visible: root.mode === "projects"

            Rectangle {
                width: parent.width
                height: 32
                color: "#152024"

                TextInput {
                    id: projectsInput
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#FDF6E3"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    clip: true

                    onTextChanged: {
                        root.projectsSearch = text
                        root.projectsIndex = 0
                    }

                    Keys.onEscapePressed: root.hide()
                    Keys.onPressed: event => {
                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) &&
                            (event.modifiers & Qt.ShiftModifier)) {
                            root.projectsNew()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.projectsSwitch()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Down) {
                            if (root.projectsIndex < root.projectsFiltered.length - 1)
                                root.projectsIndex++
                            event.accepted = true
                        } else if (event.key === Qt.Key_Up) {
                            if (root.projectsIndex > 0)
                                root.projectsIndex--
                            event.accepted = true
                        }
                    }
                }

                Text {
                    anchors.fill: projectsInput
                    verticalAlignment: Text.AlignVCenter
                    text: "project"
                    color: "#707880"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                    visible: !projectsInput.text
                }
            }

            ListView {
                width: parent.width
                height: Math.min(root.projectsFiltered.length, 8) * 32 + 8
                model: root.projectsFiltered.length
                clip: true
                currentIndex: root.projectsIndex

                delegate: Rectangle {
                    required property int index
                    property var item: root.projectsFiltered[index]
                    property bool isSelected: index === root.projectsIndex

                    width: parent ? parent.width : 0
                    height: 32
                    color: isSelected ? "#152024" : "transparent"

                    Rectangle {
                        visible: isSelected
                        width: 4; height: parent.height
                        color: "#16a085"
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        spacing: 8

                        Text {
                            text: root.highlightMatch(item.name, item.indices)
                            textFormat: Text.RichText
                            color: "#FDF6E3"
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            font.bold: true
                            renderType: Text.NativeRendering
                        }

                        Text {
                            text: item.workspaces.length > 0 ? "[" + item.workspaces.join(", ") + "]" : ""
                            color: "#707880"
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            renderType: Text.NativeRendering
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.projectsIndex = index; root.projectsSwitch() }
                    }
                }
            }
        }
    }
}
