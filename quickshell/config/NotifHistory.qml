// NotifHistory.qml — the notification-history browser (sp019 task 6,
// dotfiles-c5fd.6). Mirrors ClipHistory.qml (sp014/sp017) line for line: same
// shared Combo host, same everActive focus-loss-close pattern, same
// fetch-on-show, same +26px one-line failure status bar, same RichText
// injection guard. Hosted in the MAIN quickshell instance beside ClipHistory
// (wired in shell.qml), so `qs-notif.sh toggle` finds exactly one browser per
// session and reopening can never leave an orphan window behind.
//
// VIEW + DISMISS ONLY (adr0010 posture). This file never publishes a
// pasteboard selection and never activates a notification action:
// `actionsSupported` stays false upstream in the daemon (task 2), and
// nothing here shells out to a selection-setting tool or calls an
// action-activation entry point. The suite greps this file for that whole
// forbidden surface (see test-notif-history.sh's adr0010 contract scenario)
// so a future edit that reaches for either cannot land silently.
//
// ALL NON-UI LOGIC LIVES IN qs-notif.sh. This file runs `qs-notif.sh list`
// and `qs-notif.sh dismiss <id>` and renders the results — it never touches
// the notif store or the daemon's FIFO directly.
//
// DISMISS STAYS OPEN — the one behavior delta from ClipHistory's publish.
// ClipHistory's `set` closes the picker on success (the clipboard is a
// single value, so there is nothing left to browse). Dismissing a
// notification removes ONE entry from a list that may still hold others, so
// a successful dismiss re-runs `list` IN PLACE and the window stays up —
// the user can keep clearing entries without reopening. Enter and Del both
// funnel through the same `dismiss(row)` function below, so both dismiss
// triggers share one busy gate, one status-bar failure path, and one
// re-list-in-place success path.
//
// DEL-DISMISS, CALLER-SIDE ONLY (refinement delta 2; no config/Common/
// edits). Combo's TextInput natively claims a bare Delete key press: when
// the filter input has real keyboard focus (which it does whenever the
// browser is open — same as ClipHistory), Qt's own TextInput implementation
// accepts Key_Delete unconditionally on PRESS (it is a native editing key,
// "delete forward"), even when there is nothing to delete. That acceptance
// happens *before* the event would ever reach an ancestor's Keys.onPressed,
// a Shortcut item at any context, or Keys.onShortcutOverride — none of
// those get a turn (verified empirically: an ancestor Keys.onPressed /
// Keys.onShortcutOverride / a Window-level Shortcut on "Del" all stay silent
// while the input has focus, for both WindowShortcut and ApplicationShortcut
// contexts). Qt does NOT similarly pre-claim the matching KEY RELEASE,
// though: Keys.onReleased on an ancestor (the Column below) reliably
// receives Key_Delete's release regardless of what the paired press did.
// This file uses exactly that: `_priorSearchEmpty` snapshots
// `combo.search === ""` at the END of every release handler invocation, so
// at the START of the NEXT key's release it always holds the search value
// from *before* that key's own press-time edit — the same semantics as
// gating on "was the filter empty when this key was struck", not on
// whatever the filter happens to read after the edit. On a Delete release
// with that snapshot true, the selected row is read off Combo's own public
// `filtered`/`index` (both part of the ft008 api_surface) and handed to the
// same `dismiss()` Enter uses. With filter text present, the snapshot is
// false, nothing fires, and Delete's native forward-delete behavior (already
// applied at press time, before this handler ever runs) is the only effect —
// the filter loses a character and re-filters, exactly like typing.
//
// Rows carry their opaque store id (e.g. "000004.notif"), NEVER a position,
// and NEVER parsed/re-stringified — the same id-stability discipline
// ClipHistory documents (dotfiles-g5b: parseInt-ing a filename id silently
// truncates it). `onConfirm` hands back the SELECTED ROW OBJECT and this
// file reads `row.row` off it — never `filtered[0]`, never an index.
//
// Env knobs (all optional; QS_NOTIF_* below are read by qs-notif.sh itself,
// not this file):
//   QS_NOTIF_SH   path to qs-notif.sh (default ~/.dotfiles/quickshell/qs-notif.sh)
//
// Test: quickshell/test-notif-history.sh (PHASE 2, headless Xvfb + xdotool).
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Window
import "Common"

Scope {
    id: root

    readonly property string notifSh:
        Quickshell.env("QS_NOTIF_SH") ?? (Quickshell.env("HOME") + "/.dotfiles/quickshell/qs-notif.sh")

    // Every row qs-notif.sh's `list` offered, newest first: { row: <opaque
    // store id string, e.g. "000004.notif">, preview: <string> }. `row` is
    // ALWAYS the raw string qs-notif.sh emitted — never parsed, never
    // re-stringified.
    property var entries: []
    property var _buffer: []

    // One-line outcome shown under the list. Set on any dismiss failure;
    // cleared on every reopen. A failure NEVER closes the window and NEVER
    // silently drops the row — see dismissProc.onExited.
    property string status: ""
    property bool busy: false

    // True only while the NEXT listProc exit should reveal the window and
    // reset the filter (a genuine (re)open). A re-list triggered by a
    // successful dismiss leaves this false, so the window stays exactly as
    // it was — visible, same filter text, same scroll position modulo the
    // vanished row (parity with ClipHistory's fetch-on-show: a notification
    // arriving while the picker is open does NOT live-refresh either way).
    property bool _pendingShow: false

    // Del-dismiss gate (see the file header for why this has to be a
    // release-time snapshot rather than a live read of combo.search).
    // Starts true: the filter is empty before the first keystroke.
    property bool _priorSearchEmpty: true

    // Caller-side filter (Combo filterMode "external"). Preserves the
    // newest-first `entries` order — Combo passes this array through
    // untouched — while scoring via Fuzzy subsequence match. Each surviving
    // row carries its own `matchIndices` for the RichText highlight (external
    // mode zeroes Combo's own indices, so the delegate reads them off the row
    // object here). Empty query -> every entry survives, original order.
    readonly property var filtered: {
        var q = combo.search
        var out = []
        for (var i = 0; i < entries.length; i++) {
            var m = Fuzzy.match(entries[i].preview, q)
            if (m.matched)
                out.push({ row: entries[i].row,
                           preview: entries[i].preview,
                           matchIndices: m.indices })
        }
        return out
    }

    // ── Backend ──

    // `qs-notif.sh list` emits "<id>\t<preview>" per line, newest first. The
    // id is an opaque store filename (e.g. "000004.notif") — carried here as
    // the exact string qs-notif.sh printed, no numeric parsing of any kind.
    Process {
        id: listProc
        running: false
        command: ["sh", root.notifSh, "list"]
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
            if (exitCode !== 0)
                root.status = "notification history unavailable (qs-notif.sh list exited " + exitCode + ")"
            if (root._pendingShow) {
                root._pendingShow = false
                picker.visible = true
                // Clears the filter text + index and takes focus — doubles
                // as the reopen reset so a rapid close/reopen shows no stale
                // filter/index. A re-list after a successful dismiss does
                // NOT go through this branch, so it never resets the filter.
                combo.forceFocus()
                // forceFocus() clears the search PROGRAMMATICALLY (a direct
                // property set, not a real keystroke), so it never runs
                // through the Column's Keys.onReleased below — the one place
                // that normally keeps _priorSearchEmpty in sync. Without this
                // line it would carry over stale from whatever the LAST
                // session's last keypress left it as. Reset it explicitly
                // here: forceFocus() guarantees the search is genuinely empty
                // at this exact moment.
                root._priorSearchEmpty = true
            }
        }
    }

    // `qs-notif.sh dismiss <id>` -> the daemon's FIFO, whose exit code is the
    // contract:
    //   0  the daemon accepted the dismiss (or the entry had already
    //      vanished on an age-prune race — either way this script's job,
    //      writing the FIFO line, succeeded)
    //   1  no daemon listening (dead) or a malformed id — nothing changed
    // Only 0 re-lists. 1 keeps the row and reports the failure, because a
    // row that silently vanished from a failed dismiss would be
    // indistinguishable from a successful one.
    Process {
        id: dismissProc
        running: false
        onExited: (exitCode, exitStatus) => {
            root.busy = false
            if (exitCode === 0) {
                root.status = ""
                root._pendingShow = false
                if (!listProc.running) listProc.running = true
            } else {
                root.status = "dismiss failed — entry kept (qs-notif.sh dismiss exited " + exitCode + ")"
            }
        }
    }

    // ── Actions ──

    function show() {
        root.status = ""
        root.busy = false
        root._buffer = []
        root._pendingShow = true
        // The window is revealed in listProc.onExited, not here: showing
        // first would flash the previous session's history for as long as
        // the fetch takes.
        if (!listProc.running) listProc.running = true
    }

    function hide() {
        picker.visible = false
    }

    // Shared by Enter (Combo's onConfirm) and Del (the release-time
    // intercept below). `row` is the SELECTED row object — dismiss its own
    // opaque id (row.row), verbatim (adr0010 id-stability). The busy gate
    // swallows a re-trigger while a dismiss is already in flight.
    function dismiss(row) {
        if (root.busy) return
        root.status = ""
        root.busy = true
        dismissProc.command = ["sh", root.notifSh, "dismiss", row.row]
        dismissProc.running = true
    }

    // ── IPC (qs-notif.sh toggle) ──

    IpcHandler {
        target: "notifhistory"
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
        width: combo.implicitWidth
        // Combo owns the parity height (input bar + rows + pad, all from
        // DialogTheme, floor of 1 visible row via minVisibleRows). The only
        // notif-specific term is the one-line status bar (+26) shown on
        // dismiss failure.
        height: combo.implicitHeight + (root.status === "" ? 0 : 26)
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: DialogTheme.bodyBg
        title: "qs-notif"

        // Explicit opaque fill: under X11 with FramelessWindowHint the
        // Window `color` is not reliably honored as the clear color.
        Rectangle {
            anchors.fill: parent
            color: DialogTheme.bodyBg
            z: -1
        }

        // Close when the session takes focus elsewhere — but only once the
        // picker has actually held focus (the ClipHistory everActive
        // pattern), so the not-yet-focused window that exists for a frame
        // between map and focus is not immediately hidden.
        property bool everActive: false
        onActiveChanged: {
            if (active) everActive = true
            else if (everActive && visible) root.hide()
        }
        onVisibleChanged: if (!visible) everActive = false

        Column {
            anchors.fill: parent

            // Del-dismiss intercept — see the file header for the full
            // rationale. Attached to this Column (an ANCESTOR of Combo,
            // never Combo itself or anything under Common/): Key_Delete's
            // PRESS is unconditionally claimed by Combo's focused TextInput,
            // but the matching RELEASE bubbles here freely regardless.
            Keys.onReleased: (event) => {
                if (event.key === Qt.Key_Delete && root._priorSearchEmpty) {
                    var idx = combo.index
                    if (idx >= 0 && idx < combo.filtered.length)
                        root.dismiss(combo.filtered[idx].row)
                }
                // Resync for the NEXT key's release, capturing this key's
                // own effect (if any) on the filter text.
                root._priorSearchEmpty = (combo.search === "")
            }

            Combo {
                id: combo
                width: parent.width
                height: combo.implicitHeight

                // External filter (owned by root.filtered) so the
                // newest-first order survives; a floor of one visible row
                // keeps the empty-history placeholder on screen.
                model: root.filtered
                filterMode: "external"
                minVisibleRows: 1
                placeholder: "notification history"
                // Two distinct empty states — the fix differs, so the text
                // does: an empty history needs no action, a filter matching
                // nothing needs the filter cleared or changed.
                emptyText: root.entries.length === 0
                           ? "notification history is empty"
                           : "no entry matches \"" + combo.search + "\""

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
                            anchors.right: parent.right
                            anchors.rightMargin: DialogTheme.textLeftMargin
                            // RichText over arbitrary notification bytes:
                            // Fuzzy.highlight HTML-escapes &/</> before
                            // wrapping the matched chars, so a preview
                            // containing markup (a notification body with
                            // HTML) renders literally instead of injecting
                            // into the row.
                            text: Fuzzy.highlight(row.preview, row.matchIndices)
                            textFormat: Text.RichText
                            elide: Text.ElideRight
                            color: DialogTheme.fg
                            font.family: DialogTheme.font
                            font.pixelSize: DialogTheme.fontSize
                            font.bold: isSelected
                            renderType: Text.NativeRendering
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: { combo.setIndex(index); combo.confirmCurrent() }
                        }
                    }
                }

                onConfirm: (row) => root.dismiss(row)
                onCancel: () => root.hide()
            }

            // One-line failure status. Notif-only chrome layered under the
            // shared control; the accompanying +26 is added to the window
            // height above.
            Rectangle {
                width: parent.width
                height: 26
                color: "#3B1F1F"
                visible: root.status !== ""

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: DialogTheme.textLeftMargin
                    anchors.right: parent.right
                    anchors.rightMargin: DialogTheme.textLeftMargin
                    text: root.status
                    elide: Text.ElideRight
                    color: "#E8A0A0"
                    font.family: DialogTheme.font
                    font.pixelSize: DialogTheme.fontSize - 2
                    renderType: Text.NativeRendering
                }
            }
        }
    }
}
