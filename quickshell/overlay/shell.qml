import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls

ShellRoot {
    id: root

    // ── Shared ──

    readonly property string fontFamily: "Iosevka Nerd Font"
    readonly property int fontSize: 16

    property string mode: "" // "launcher" or "switcher"

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

    Process {
        id: windowScanner
        running: false
        command: ["i3-msg", "-t", "get_tree"]
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => {
                try {
                    var tree = JSON.parse(data)
                    var wins = []
                    function walk(node) {
                        if (node.window && node.name && node.type === "con") {
                            wins.push({
                                id: node.id,
                                name: node.name,
                                focused: node.focused,
                                urgent: node.urgent || false,
                                cls: (node.window_properties || {})["class"] || ""
                            })
                        }
                        var children = (node.nodes || []).concat(node.floating_nodes || [])
                        for (var i = 0; i < children.length; i++) walk(children[i])
                    }
                    walk(tree)
                    root.switcherWindows = wins
                    for (var j = 0; j < wins.length; j++) {
                        if (wins[j].focused) {
                            root.switcherIndex = (j + 1) % wins.length
                            break
                        }
                    }
                } catch(e) {}
            }
        }
    }

    Process {
        id: focusProc
        running: false
    }


    function switcherShow() {
        switcherIndex = 0
        windowScanner.running = true
        mode = "switcher"
        overlay.width = 400
        overlay.visible = true
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
            focusProc.command = ["i3-msg", "[con_id=" + win.id + "]", "focus"]
            focusProc.running = true
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

    // ── Single window ──

    ApplicationWindow {
        id: overlay
        visible: false
        width: 480
        height: {
            if (root.mode === "launcher")
                return 32 + Math.min(root.launcherFiltered.length, 8) * 32 + 8
            if (root.mode === "switcher")
                return Math.max(root.switcherWindows.length, 1) * 32 + 8
            return 100
        }
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "#222D31"
        title: root.mode === "switcher" ? "qs-switcher" : "qs-launcher"

        onActiveChanged: {
            if (!active && visible) root.hide()
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

            Keys.onReleased: event => {
                if (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R ||
                    event.key === Qt.Key_Alt || event.key === Qt.Key_Meta) {
                    root.switcherFocus()
                }
            }

            Keys.onEscapePressed: root.hide()
            Keys.onReturnPressed: root.switcherFocus()
            Keys.onEnterPressed: root.switcherFocus()
            Keys.onDownPressed: {
                root.switcherIndex = root.switcherIndex < root.switcherWindows.length - 1
                    ? root.switcherIndex + 1 : 0
            }
            Keys.onUpPressed: {
                root.switcherIndex = root.switcherIndex > 0
                    ? root.switcherIndex - 1 : root.switcherWindows.length - 1
            }
            Keys.onTabPressed: {
                root.switcherIndex = root.switcherIndex < root.switcherWindows.length - 1
                    ? root.switcherIndex + 1 : 0
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

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        spacing: 8

                        Text {
                            text: item.cls
                            color: "#16a085"
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            font.bold: true
                            renderType: Text.NativeRendering
                            width: 80
                            elide: Text.ElideRight
                        }

                        Text {
                            text: item.name
                            color: item.focused ? "#707880" : "#FDF6E3"
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            renderType: Text.NativeRendering
                            width: parent.width - 100
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.switcherIndex = index; root.switcherFocus() }
                    }
                }
            }
        }
    }
}
