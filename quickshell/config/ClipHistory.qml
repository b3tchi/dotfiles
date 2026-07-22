// ClipHistory.qml — the shared-clipboard-history picker (sp014 task 4).
//
// A keyboard-driven list of the copyq history. Type to filter, Enter to put the
// selected entry on the clipboard, Esc to leave. Hosted in the session's normal
// quickshell instance (wired in shell.qml), so there is exactly one picker per
// session and reopening can never leave an orphan window behind.
//
// IT COPIES, IT DOES NOT PASTE. Enter publishes the entry and closes; the user
// then pastes with their own paste key. Nothing here inspects the focused
// window and nothing synthesizes a keystroke — that was built, rejected and
// deliberately removed (sp014 scope change, 2026-07-20), which is also why the
// picker never has to care about keyboard layout, terminals, or held modifiers.
//
// ALL NON-UI LOGIC LIVES IN qs-clip.sh. This file never talks to copyq and
// never talks to clip-set.sh; it runs `qs-clip.sh list` and `qs-clip.sh set`
// and renders the results. That split is deliberate: history parsing and
// display resolution are unit-testable in sh without an X server, and what is
// left here is presentation, which is the part a headless suite can only ever
// observe indirectly.
//
// Rows carry their opaque store id (the filename qs-clip.sh's `list` reports,
// e.g. "000004.clip"), NOT their position in the visible list, and NEVER as a
// parsed/re-stringified number — ids are opaque strings end to end (sp016's
// store contract). The filter reorders/removes nothing else, so `set` is
// always handed the id the history actually uses — a filtered list that
// published the first row's id because the match happened to be first is the
// bug this arrangement exists to prevent, and `parseInt`-ing that id into a
// truncated number was a second, independent instance of the same bug class
// (dotfiles-g5b: "000004.clip" parsed to 4, silently dropping the filename).
//
// Env knobs (all optional, all read by qs-clip.sh except QS_CLIP_SH):
//   QS_CLIP_SH        path to qs-clip.sh (default ~/.dotfiles/quickshell/qs-clip.sh)
//   QS_CLIP_CAP       most rows to offer (default 200)
//   QS_CLIP_PREVIEW   preview width in characters (default 120)
//
// Test: quickshell/test-clip-history.sh (headless, Xvfb + xdotool).
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Window

Scope {
    id: root

    readonly property string fontFamily: "Iosevka Nerd Font"
    readonly property int fontSize: 15
    readonly property int rowHeight: 30
    readonly property int visibleRows: 12

    readonly property string clipSh:
        Quickshell.env("QS_CLIP_SH") ?? (Quickshell.env("HOME") + "/.dotfiles/quickshell/qs-clip.sh")

    // Every row qs-clip.sh offered, newest first: { row: <opaque store id
    // string, e.g. "000004.clip">, preview: <string> }. `row` is ALWAYS the
    // raw string qs-clip.sh emitted — never parsed, never re-stringified.
    property var entries: []
    property var _buffer: []

    property string search: ""
    property int index: 0

    // One-line outcome shown under the list. Set on any failure; cleared on
    // every reopen. A failure NEVER closes the window — see setProc.onExited.
    property string status: ""
    property bool busy: false

    property var filtered: {
        if (search === "") return entries
        var needle = search.toLowerCase()
        var out = []
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].preview.toLowerCase().indexOf(needle) !== -1)
                out.push(entries[i])
        }
        return out
    }

    // ── Backend ──

    // `qs-clip.sh list` emits "<id>\t<preview>" per line. The id is an
    // opaque store filename (e.g. "000004.clip") under the file-store backend
    // (sp016) — carried here as the exact string qs-clip.sh printed, with no
    // numeric parsing of any kind. Do NOT `parseInt` this: it silently
    // truncates "000004.clip" to 4, which was dotfiles-g5b.
    Process {
        id: listProc
        running: false
        command: ["sh", root.clipSh, "list"]
        stdout: SplitParser {
            onRead: data => {
                var tab = data.indexOf("\t")
                if (tab < 0) return
                var id = data.substring(0, tab)
                if (id === "") return
                root._buffer.push({ row: id, preview: data.substring(tab + 1) })
            }
        }
        onExited: (exitCode, exitStatus) => {
            root.entries = root._buffer
            root._buffer = []
            root.index = 0
            if (exitCode !== 0)
                root.status = "clipboard history unavailable (qs-clip.sh list exited " + exitCode + ")"
            picker.visible = true
            searchInput.forceActiveFocus()
        }
    }

    // `qs-clip.sh set <id>` -> clip-set.sh, whose exit code is the contract:
    //   0  the entry is on CLIPBOARD+PRIMARY of every live display
    //   1  a precondition failed and NOTHING was written anywhere
    //   2  a partial write — clipboard state is indeterminate
    // Only 0 closes the picker. 1 and 2 are reported and the window stays up,
    // because both leave the user with a clipboard that is not what they asked
    // for, and a picker that vanished would make that indistinguishable from
    // success. They are reported differently on purpose: after 1 the old
    // clipboard is intact and pressing Enter again is free, after 2 it is not
    // known what is on the clipboard and the user is told to check.
    Process {
        id: setProc
        running: false
        onExited: (exitCode, exitStatus) => {
            root.busy = false
            if (exitCode === 0) {
                root.hide()
            } else if (exitCode === 1) {
                root.status = "not copied — the clipboard is unchanged; Enter to retry"
            } else if (exitCode === 2) {
                root.status = "PARTIAL copy — some displays may hold it, some may not; check before pasting"
            } else {
                root.status = "clip-set.sh failed (exit " + exitCode + ")"
            }
        }
    }

    // ── Actions ──

    function show() {
        root.status = ""
        root.busy = false
        root.search = ""
        searchInput.text = ""
        root.index = 0
        root._buffer = []
        // The window is revealed in listProc.onExited, not here: showing first
        // would flash the previous session's history for as long as the fetch
        // takes, and the picked row would briefly point at stale indices.
        if (!listProc.running) listProc.running = true
    }

    function hide() {
        picker.visible = false
    }

    function accept() {
        // Empty history, or a filter that matches nothing: Enter does nothing
        // at all — no process spawned, no clipboard write, window stays.
        if (root.busy) return
        if (root.filtered.length === 0 || root.index >= root.filtered.length) return
        root.status = ""
        root.busy = true
        // The id travels verbatim: it is already the exact string
        // qs-clip.sh's `list` emitted (see listProc.onRead) — no
        // re-stringification, no format assumption about its shape.
        setProc.command = ["sh", root.clipSh, "set", root.filtered[root.index].row]
        setProc.running = true
    }

    function moveDown() {
        if (root.index < root.filtered.length - 1) root.index++
    }

    function moveUp() {
        if (root.index > 0) root.index--
    }

    // ── IPC (qs-clip.sh toggle) ──

    IpcHandler {
        target: "cliphistory"
        function toggle(): void {
            if (picker.visible) root.hide()
            else root.show()
        }
        function open(): void { if (!picker.visible) root.show() }
        function close(): void { root.hide() }
    }

    // ── Window ──

    Window {
        id: picker
        visible: false
        width: 720
        height: 36 + Math.max(Math.min(root.filtered.length, root.visibleRows), 1) * root.rowHeight
                + (root.status === "" ? 0 : 26) + 8
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "#222D31"
        title: "qs-clip"

        // Explicit opaque fill: under X11 with FramelessWindowHint the Window
        // `color` is not reliably honored as the clear color (same problem
        // Overlay.qml documents), leaving transparent strips around the list.
        Rectangle {
            anchors.fill: parent
            color: "#222D31"
            z: -1
        }

        // Close when the session takes focus elsewhere — but only once the
        // picker has actually held focus, so the not-yet-focused window that
        // exists for a frame between map and focus is not immediately hidden.
        property bool everActive: false
        onActiveChanged: {
            if (active) everActive = true
            else if (everActive && visible) root.hide()
        }
        onVisibleChanged: if (!visible) everActive = false

        Column {
            anchors.fill: parent

            Rectangle {
                width: parent.width
                height: 36
                color: "#152024"

                TextInput {
                    id: searchInput
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#FDF6E3"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    clip: true

                    onTextChanged: {
                        root.search = text
                        root.index = 0
                    }

                    Keys.onEscapePressed: root.hide()
                    Keys.onReturnPressed: root.accept()
                    Keys.onEnterPressed: root.accept()
                    Keys.onDownPressed: root.moveDown()
                    Keys.onUpPressed: root.moveUp()
                    // Ctrl+N / Ctrl+P — the picker is reachable from a terminal
                    // keybind, where arrow keys are the awkward option.
                    Keys.onPressed: event => {
                        if (event.modifiers & Qt.ControlModifier) {
                            if (event.key === Qt.Key_N) { root.moveDown(); event.accepted = true }
                            else if (event.key === Qt.Key_P) { root.moveUp(); event.accepted = true }
                        }
                    }
                }

                Text {
                    anchors.fill: searchInput
                    verticalAlignment: Text.AlignVCenter
                    text: "clipboard history"
                    color: "#707880"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                    visible: !searchInput.text
                }
            }

            // Empty state. Distinguishes "nothing has been copied yet" from
            // "the filter excluded everything", because the fix differs.
            Rectangle {
                width: parent.width
                height: root.rowHeight
                color: "transparent"
                visible: root.filtered.length === 0

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    text: root.entries.length === 0
                          ? "clipboard history is empty"
                          : "no entry matches \"" + root.search + "\""
                    color: "#707880"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                }
            }

            ListView {
                width: parent.width
                height: Math.min(root.filtered.length, root.visibleRows) * root.rowHeight
                model: root.filtered.length
                clip: true
                currentIndex: root.index
                highlightMoveDuration: 0
                // Keep the selected row on screen when the list is longer than
                // the window: without this, arrowing past the twelfth entry
                // selects rows nobody can see.
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                delegate: Rectangle {
                    required property int index
                    property var entry: root.filtered[index]
                    property bool isSelected: index === root.index

                    width: parent ? parent.width : 0
                    height: root.rowHeight
                    color: isSelected ? "#152024" : "transparent"

                    Rectangle {
                        visible: parent.isSelected
                        width: 4; height: parent.height
                        color: "#16a085"
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        text: parent.entry ? parent.entry.preview : ""
                        elide: Text.ElideRight
                        color: "#FDF6E3"
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize
                        renderType: Text.NativeRendering
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.index = parent.index; root.accept() }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 26
                color: "#3B1F1F"
                visible: root.status !== ""

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    text: root.status
                    elide: Text.ElideRight
                    color: "#E8A0A0"
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize - 2
                    renderType: Text.NativeRendering
                }
            }
        }
    }
}
