import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls

ShellRoot {
    id: root

    property int selectedIndex: 0
    property string searchText: ""
    property var allApps: []

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
            if (matchSet[j]) {
                result += "<font color='#16a085'><b>" + text[j] + "</b></font>"
            } else {
                result += text[j]
            }
        }
        return result
    }

    property var filteredApps: {
        var result = []
        var search = searchText
        for (var i = 0; i < allApps.length; i++) {
            var name = allApps[i]
            var m = fuzzyMatch(name, search)
            if (m.matched) {
                result.push({ name: name, score: m.score, indices: m.indices })
            }
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
                if (trimmed !== "") {
                    var apps = root.allApps.slice()
                    apps.push(trimmed)
                    root.allApps = apps
                }
            }
        }
    }

    Process {
        id: execProc
        running: false
    }

    function launch() {
        if (filteredApps.length > 0 && selectedIndex < filteredApps.length) {
            execProc.command = ["sh", "-c", filteredApps[selectedIndex].name + " &"]
            execProc.running = true
        }
        hide()
    }

    function show() {
        selectedIndex = 0
        searchText = ""
        launcher.visible = true
        searchInput.text = ""
        searchInput.forceActiveFocus()
    }

    function hide() {
        launcher.visible = false
        searchText = ""
        selectedIndex = 0
    }

    IpcHandler {
        target: "launcher"

        function toggle() {
            if (launcher.visible) root.hide()
            else root.show()
        }
    }

    ApplicationWindow {
        id: launcher
        visible: false
        width: 480
        height: 32 + Math.min(root.filteredApps.length, 8) * 32 + 8
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "#222D31"
        title: "qs-launcher"

        onActiveChanged: {
            if (!active && visible) root.hide()
        }

        Column {
            anchors.fill: parent

            Rectangle {
                width: parent.width
                height: 32
                color: "#152024"

                TextInput {
                    id: searchInput
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#FDF6E3"
                    font.family: "Iosevka Nerd Font"
                    font.pixelSize: 16
                    clip: true

                    onTextChanged: {
                        root.searchText = text
                        root.selectedIndex = 0
                    }

                    Keys.onEscapePressed: root.hide()
                    Keys.onReturnPressed: root.launch()
                    Keys.onEnterPressed: root.launch()

                    Keys.onDownPressed: {
                        if (root.selectedIndex < root.filteredApps.length - 1)
                            root.selectedIndex++
                    }

                    Keys.onUpPressed: {
                        if (root.selectedIndex > 0)
                            root.selectedIndex--
                    }
                }

                Text {
                    anchors.fill: searchInput
                    verticalAlignment: Text.AlignVCenter
                    text: "run"
                    color: "#707880"
                    font.family: "Iosevka Nerd Font"
                    font.pixelSize: 16
                    renderType: Text.NativeRendering
                    visible: !searchInput.text
                }
            }

            ListView {
                id: listView
                width: parent.width
                height: Math.min(root.filteredApps.length, 8) * 32 + 8
                model: root.filteredApps.length
                clip: true
                currentIndex: root.selectedIndex

                delegate: Rectangle {
                    required property int index
                    property var item: root.filteredApps[index]
                    property bool isSelected: index === root.selectedIndex

                    width: listView.width
                    height: 32
                    color: isSelected ? "#152024" : "transparent"

                    Rectangle {
                        visible: isSelected
                        width: 4
                        height: parent.height
                        color: "#16a085"
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        text: root.highlightMatch(item.name, item.indices)
                        textFormat: Text.RichText
                        color: "#FDF6E3"
                        font.family: "Iosevka Nerd Font"
                        font.pixelSize: 16
                        renderType: Text.NativeRendering
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.selectedIndex = index
                            root.launch()
                        }
                    }
                }
            }
        }
    }
}
