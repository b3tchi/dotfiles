// ClipHistory.qml — the shared-clipboard-history picker (sp014 task 4;
// refactored onto the shared Combo control in sp017 task 5 / dotfiles-evnv.5).
//
// A keyboard-driven list of the copyq history. Type to fuzzy-filter, Enter to
// put the selected entry on the clipboard, Esc to leave. Hosted in the
// session's normal quickshell instance (wired in shell.qml), so there is
// exactly one picker per session and reopening can never leave an orphan
// window behind.
//
// IT COPIES, IT DOES NOT PASTE. Enter publishes the entry and closes; the user
// then pastes with their own paste key. Nothing here inspects the focused
// window and nothing synthesizes a keystroke — that was built, rejected and
// deliberately removed (sp014 scope change, 2026-07-20), which is also why the
// picker never has to care about keyboard layout, terminals, or held modifiers.
// The publish carries the SELECTED row's OWN opaque store id (adr0010,
// id-stability): Combo hands the confirmed ROW OBJECT back to onConfirm and we
// pick `row.row` off it — never a positional index, never `filtered[0]`.
//
// ALL NON-UI LOGIC LIVES IN qs-clip.sh. This file never talks to copyq and
// never talks to clip-set.sh; it runs `qs-clip.sh list` and `qs-clip.sh set`
// and renders the results. That split is deliberate: history parsing and
// display resolution are unit-testable in sh without an X server, and what is
// left here is presentation, which is the part a headless suite can only ever
// observe indirectly.
//
// CHROME + FILTER come from Common/ now (sp017): the input bar, row list,
// arrow/Ctrl-N-P navigation, Enter-confirm / Esc-cancel and every parity
// dimension (480 wide, 32px input bar, 32px rows, max 8 visible, dark body,
// light text) live in Combo + DialogTheme — this file no longer hardcodes any
// of those colors or numbers (DialogTheme is their single source, which is why
// the suite can assert this file contains zero copies of the input-bar color).
// The clip-only extras layered on top of the shared control: a floor of one
// visible row so an empty history still shows its placeholder, the one-line
// failure status bar (+26px), and the busy gate around an in-flight `set`.
//
// FILTER MODE is Combo `external`, NOT `fuzzy` — the caller-side filter below
// (Fuzzy.match per entry) keeps the history in NEWEST-FIRST order, whereas
// Combo's built-in fuzzy sort re-orders (empty query → alphabetical). Newest
// first is the whole point of a clipboard history and is what the end-to-end
// suite's Down-navigation assumes, so we own the filter and hand Combo an
// already-ordered model with per-row match indices for the highlight. The
// upgrade over the old plain-substring filter is real (subsequence matching:
// "skg" finds "ssh-keygen"), and previews render as RichText through
// Fuzzy.highlight, which HTML-escapes arbitrary clipboard bytes so a preview
// containing markup cannot inject into the row renderer.
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
// IMAGE ROWS: an id ending ".img" is clip-store.sh's other entry kind —
// always real PNG bytes on disk (see clip-store.sh's IMAGES section), never
// text. Kind is told apart purely from the id's extension (never by peeking
// at file content), rendered at two sizes for two different purposes:
//   * a small square thumbnail INLINE in the row (glance-while-scrolling —
//     every visible row decodes its own, cheap at row-height via Image's
//     own sourceSize downscale) next to the "[image]" label qs-clip.sh's
//     `list` emits for that kind
//   * a bigger panel BELOW the list showing only whichever entry currently
//     has keyboard focus, sized to actually read the image — decoding a
//     full-size render for every row at once would not scale to a
//     200-entry history, so only the focused one ever does
// Both read the same file via QML's own Image element (decode + downscale
// native to it) — no separate thumbnail-generation step anywhere in this
// path. The path is derived independently (storeDir + id) rather than
// added to the wire protocol — "<id>\t<preview>" stays two fields for both
// kinds.
//
// Env knobs (all optional, all read by qs-clip.sh except QS_CLIP_SH):
//   QS_CLIP_SH        path to qs-clip.sh (default ~/.dotfiles/quickshell/qs-clip.sh)
//   QS_CLIP_CAP       most rows to offer (default 200)
//   QS_CLIP_PREVIEW   preview width in characters (default 120)
//
// Test: quickshell/test-clip-history.sh (headless, Xvfb + xdotool), and
//       quickshell/test-overlay-grab.sh for the focus-loss-close half
//       (dotfiles-hwds.31) — that one needs a REAL i3, because the probe
//       below only arms once the window has actually held focus.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Window
import QtQuick.Effects
import "Common"

Scope {
    id: root

    readonly property string clipSh:
        Quickshell.env("QS_CLIP_SH") ?? (Quickshell.env("HOME") + "/.dotfiles/quickshell/qs-clip.sh")

    // Store dir for THIS session, computed the same way qs-clip.sh's
    // store_dir() does (bare display — ":0.0" -> ":0" — under
    // $XDG_RUNTIME_DIR/clip-store/). This process's own $DISPLAY IS the
    // session qs-clip.sh already resolved `list`'s ids against, so no
    // separate derivation is needed — only used to build an ".img" row's
    // thumbnail path, never to re-decide which store `list`/`set` read.
    readonly property string storeDir: {
        var d = Quickshell.env("DISPLAY") ?? ""
        var bare = d.replace(/\.\d+$/, "")
        return (Quickshell.env("XDG_RUNTIME_DIR") ?? "") + "/clip-store/" + bare
    }

    // Clip-only chrome (not a DialogTheme constant — this panel exists only
    // here, same reasoning as the status bar's own local "26" below).
    readonly property int imgPreviewHeight: 220

    // Every row qs-clip.sh offered, newest first: { row: <opaque store id
    // string, e.g. "000004.clip">, preview: <string> }. `row` is ALWAYS the
    // raw string qs-clip.sh emitted — never parsed, never re-stringified.
    property var entries: []
    property var _buffer: []

    // One-line outcome shown under the list. Set on any failure; cleared on
    // every reopen. A failure NEVER closes the window — see setProc.onExited.
    property string status: ""
    property bool busy: false

    // Caller-side filter (Combo filterMode "external"). Preserves the
    // newest-first `entries` order — Combo passes this array through untouched
    // — while upgrading the match from plain-substring to Fuzzy subsequence.
    // Each surviving row carries its own `matchIndices` for the RichText
    // highlight (external mode zeroes Combo's own indices, so the delegate
    // reads them off the row object here). Empty query → every entry survives
    // (Fuzzy.match of an empty pattern matches, no indices) in original order.
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

    // The entry whose row currently has keyboard focus (arrow-key navigable,
    // same `combo.index` everything else in Combo reads) — drives the image
    // preview panel below the list. `root.filtered` is exactly what Combo
    // was handed as `model` (filterMode "external" passes it through
    // untouched; see Combo.qml), so indexing it directly here needs no
    // separate lookup into Combo's own wrapped copy.
    readonly property var selectedRow:
        (combo.index >= 0 && combo.index < filtered.length) ? filtered[combo.index] : null
    readonly property bool selectedIsImage:
        selectedRow !== null && selectedRow.row.endsWith(".img")

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
            if (exitCode !== 0)
                root.status = "clipboard history unavailable (qs-clip.sh list exited " + exitCode + ")"
            picker.visible = true
            // Clears the filter text + index and takes focus — doubles as the
            // reopen reset so a rapid close/reopen shows no stale filter/index.
            combo.forceFocus()
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

    // ── Is the picker really out of focus, or is a grab active? ──
    //
    // Armed by the window going inactive (see picker.onActiveChanged) and
    // disarmed by it coming back. `triggeredOnStart` makes the first probe
    // fire immediately, so a REAL focus change closes the picker within one
    // process spawn — the repeat only exists for the grab case, where the
    // window stays inactive for as long as the key is held and must be
    // re-examined until either it re-activates or the session genuinely
    // moves on underneath the grab.
    Timer {
        id: blurProbe
        interval: 150
        repeat: true
        running: false
        triggeredOnStart: true
        onTriggered: {
            if (activeWinProc.running) return
            root._activeTitle = ""
            activeWinProc.running = true
        }
    }

    // First line of `qs-clip.sh active-window`, held between the read and the
    // exit (the exit code is what says whether the line means anything).
    property string _activeTitle: ""

    Process {
        id: activeWinProc
        running: false
        command: ["sh", root.clipSh, "active-window"]
        stdout: SplitParser {
            onRead: data => { if (root._activeTitle === "") root._activeTitle = data }
        }
        onExited: (exitCode, exitStatus) => {
            var seen = root._activeTitle
            root._activeTitle = ""
            // Non-zero is "cannot tell" — no window manager, no xdotool, the
            // active window vanished mid-read. Never hide on that: a picker
            // that lingers costs one Escape, a picker that dismisses itself
            // is the bug (dotfiles-hwds.31). Stop rather than re-ask, so a
            // display that can never answer costs ONE probe per deactivation
            // instead of an unbounded spawn loop; the next deactivation
            // re-arms it.
            if (exitCode !== 0) { blurProbe.stop(); return }
            // Re-activated (the grab ended) or already gone while the probe
            // was in flight: nothing to decide.
            if (picker.active || !picker.visible) return
            // Still the active window as far as the WM is concerned, so the
            // deactivation was a grab, not the user moving on.
            if (seen === picker.title) return
            blurProbe.stop()
            root.hide()
        }
    }

    // ── Actions ──

    function show() {
        root.status = ""
        root.busy = false
        root._buffer = []
        // The window is revealed in listProc.onExited, not here: showing first
        // would flash the previous session's history for as long as the fetch
        // takes, and the picked row would briefly point at stale indices.
        if (!listProc.running) listProc.running = true
    }

    function hide() {
        picker.visible = false
    }

    // Combo confirm handler. `row` is the SELECTED row object — publish its own
    // opaque id (row.row), verbatim (adr0010). The busy gate swallows a re-Enter
    // while a `set` is already in flight; empty history / filter-matches-nothing
    // never reaches here because Combo.confirmCurrent no-ops on an empty list.
    function publish(row) {
        if (root.busy) return
        root.status = ""
        root.busy = true
        // The id travels verbatim: it is already the exact string
        // qs-clip.sh's `list` emitted (see listProc.onRead) — no
        // re-stringification, no format assumption about its shape.
        setProc.command = ["sh", root.clipSh, "set", row.row]
        setProc.running = true
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
        width: combo.implicitWidth
        // Combo owns the parity height (input bar + rows + pad, all from
        // DialogTheme, floor of 1 visible row via minVisibleRows). Clip-only
        // terms added on top: the one-line status bar (+26, shown on
        // failure) and the image preview panel (shown only when the
        // currently-focused entry is an image).
        height: combo.implicitHeight
                + (root.status === "" ? 0 : 26)
                + (root.selectedIsImage ? root.imgPreviewHeight : 0)
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: DialogTheme.bodyBg
        title: "qs-clip"

        // Explicit opaque fill: under X11 with FramelessWindowHint the Window
        // `color` is not reliably honored as the clear color (same problem
        // Overlay.qml documents), leaving transparent strips around the list.
        Rectangle {
            anchors.fill: parent
            color: DialogTheme.bodyBg
            z: -1
        }

        // Close when the session takes focus elsewhere — but only once the
        // picker has actually held focus, so the not-yet-focused window that
        // exists for a frame between map and focus is not immediately hidden.
        //
        // A Qt DEACTIVATION IS NOT A FOCUS CHANGE (dotfiles-hwds.31). Any X
        // client holding a passive grab on a key — hotkeyd's per-chord XI2
        // grabs ([[ft011]]), i3's own binds, xbindkeys — puts the server into
        // an implicit ACTIVE grab for as long as that key is HELD, and X then
        // sends FocusOut(mode=NotifyGrab) to the focused window. Qt turns that
        // into `active === false` about 100 ms later even though this window
        // never lost the input focus, and re-activates it by itself the
        // instant the key comes back up. Hiding straight off `active` is what
        // made the picker dismiss itself seconds after opening.
        //
        // So `active === false` only ARMS the check; blurProbe/activeWinProc
        // below ask the window manager who it thinks is active, and the hide
        // happens only if the answer is somebody else. See qs-clip.sh's
        // `active-window` for why that is the discriminator and why no
        // timeout could be one.
        property bool everActive: false
        onActiveChanged: {
            if (active) {
                everActive = true
                blurProbe.stop()
            } else if (everActive && visible) {
                blurProbe.restart()
            }
        }
        onVisibleChanged: if (!visible) {
            everActive = false
            blurProbe.stop()
        }

        Column {
            anchors.fill: parent

            Combo {
                id: combo
                width: parent.width
                height: combo.implicitHeight

                // External filter (owned by root.filtered) so the newest-first
                // order survives; a floor of one visible row keeps the empty
                // history's placeholder on screen.
                model: root.filtered
                filterMode: "external"
                minVisibleRows: 1
                placeholder: "clipboard history"
                // Two distinct empty states — the fix differs, so the text does.
                emptyText: root.entries.length === 0
                           ? "clipboard history is empty"
                           : "no entry matches \"" + combo.search + "\""

                delegate: Component {
                    Rectangle {
                        anchors.fill: parent
                        color: isSelected ? DialogTheme.inputBg : "transparent"
                        // Kind is read off the id's own extension — never by
                        // opening the file — mirroring every backend script's
                        // own rule (see the file header's IMAGE ROWS note).
                        readonly property bool isImage: row.row.endsWith(".img")

                        Rectangle {
                            visible: isSelected
                            width: 4; height: parent.height
                            color: DialogTheme.accent
                        }

                        // Label first, thumbnail after it — "[image]" (or the
                        // fuzzy-highlighted text preview) always leads the
                        // row, same reading order as every other row.
                        Text {
                            id: label
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: DialogTheme.textLeftMargin
                            // Image rows: no right anchor — the label sizes to
                            // its own short "[image]" text so the thumbnail
                            // can sit directly after it, not off at the far
                            // right edge. Text rows: unchanged, stretches to
                            // elide long content against the row's right edge.
                            anchors.right: isImage ? undefined : parent.right
                            anchors.rightMargin: isImage ? 0 : DialogTheme.textLeftMargin
                            // RichText over arbitrary clipboard bytes: Fuzzy.highlight
                            // HTML-escapes &/</> before wrapping the matched chars,
                            // so a preview containing markup renders literally
                            // instead of injecting into the row (matchIndices read
                            // off the row — external mode zeroes Combo's own set).
                            // An image row's `preview` is qs-clip.sh's plain
                            // "[image]" label, with the thumbnail right after it.
                            text: Fuzzy.highlight(row.preview, row.matchIndices)
                            textFormat: Text.RichText
                            elide: Text.ElideRight
                            color: DialogTheme.fg
                            font.family: DialogTheme.font
                            font.pixelSize: DialogTheme.fontSize
                            font.bold: isSelected
                            renderType: Text.NativeRendering
                        }

                        // Glance-while-scrolling thumbnail, right after the
                        // "[image]" label — square, clipped to the row's own
                        // height, never resized up past it. The bigger,
                        // actually-readable render of this SAME file lives
                        // in the preview panel below, driven off keyboard
                        // focus rather than every row at once (decoding one
                        // full-size image per row would not scale to a
                        // 200-entry history). Grayscale for every row except
                        // the focused one — a column of full-color
                        // thumbnails competes with the accent bar for
                        // attention; full color is reserved for the one row
                        // that's actually selected right now.
                        Image {
                            id: thumb
                            visible: isImage
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: label.right
                            anchors.leftMargin: DialogTheme.pad
                            height: parent.height - 6
                            width: height
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.height: parent.height - 6
                            source: isImage ? ("file://" + root.storeDir + "/" + row.row) : ""
                            layer.enabled: isImage
                            layer.effect: MultiEffect {
                                saturation: isSelected ? 0 : -1
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: { combo.setIndex(index); combo.confirmCurrent() }
                        }
                    }
                }

                onConfirm: (row) => root.publish(row)
                onCancel: () => root.hide()
            }

            // Bigger preview panel for whichever entry currently has keyboard
            // focus (arrow keys move it, same as everywhere else in Combo) —
            // shown only when that entry is an image, big enough to actually
            // read rather than the row's own 32px height. `combo.filtered[i]`
            // wraps THIS file's own row object untouched (external filterMode;
            // see Combo.qml), so `.row.row` is still the plain opaque id.
            Rectangle {
                width: parent.width
                height: root.imgPreviewHeight
                visible: root.selectedIsImage
                color: DialogTheme.inputBg

                Image {
                    anchors.fill: parent
                    anchors.margins: 8
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    // sourceSize bounds decode cost to the panel's own size
                    // regardless of the source image's actual resolution.
                    sourceSize.height: root.imgPreviewHeight
                    source: root.selectedIsImage
                            ? ("file://" + root.storeDir + "/" + root.selectedRow.row) : ""
                }
            }

            // One-line failure status. Clip-only chrome layered under the shared
            // control; the accompanying +26 is added to the window height above.
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
