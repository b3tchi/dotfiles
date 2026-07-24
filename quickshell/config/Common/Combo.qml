import Quickshell
import QtQuick
import "."

// The shared i3-dialog combobox control (sp017 / ft008). An Item (NOT a
// Window): every dialog keeps its own Window chrome and binds that window's
// height to this control's `implicitHeight`. Owns only the interaction
// contract — input bar, type-to-filter, arrow-nav row list, Enter-confirm /
// Esc-cancel — and the shared chrome sourced from DialogTheme. Each consumer
// supplies its own model, row renderer (delegate), and confirm action.
//
// The contract below is the ft008 api_surface as widened in sp017 `## plan`.
// Reproduces the launcher / switcher / projects / clip dialogs' behaviour;
// see the four consumer height formulas the `implicitHeight` reproduces.
Item {
    id: root

    // ── core ───────────────────────────────────────────────────────────────
    // model: the caller's rows (opaque objects; Combo never inspects fields
    // beyond textOf()). delegate: the caller's row renderer, which receives
    // `row` (the caller's row object), `isSelected`, and `matchIndices`.
    // confirm/confirmAlt hand back the SELECTED ROW OBJECT — never a positional
    // index or filtered[0] (adr0010 id-stability). cancel carries nothing.
    property var model: []
    property Component delegate: null
    signal confirm(var row)
    signal confirmAlt(var row)
    signal cancel()

    // ── knobs (defaults reproduce the four existing dialogs) ────────────────
    // textOf: row -> display string used for fuzzy scoring (default row.name).
    property var textOf: (function(row) { return row.name })
    // filterMode "fuzzy": Combo scores via Fuzzy over textOf(row).
    // filterMode "external": caller pre-filters/scores (e.g. switcher's
    // dual-field name-OR-ws), Combo passes `model` through untouched and the
    // delegate reads the caller's own highlight index sets off the row.
    property string filterMode: "fuzzy"
    property string placeholder: ""
    property bool inputVisible: true
    // maxVisibleRows: -1 => unbounded (no visible-row cap).
    property int maxVisibleRows: DialogTheme.maxRows
    property int minVisibleRows: 0
    property int comboWidth: DialogTheme.width
    property string emptyText: ""
    // altConfirmEnabled true: Shift+Enter fires confirmAlt(row). false:
    // Shift+Enter behaves as a plain Enter (fires confirm(row)).
    property bool altConfirmEnabled: false

    // ── selection state ─────────────────────────────────────────────────────
    property int index: 0
    readonly property alias search: input.text

    // filtered: readonly, internal shape [{ row, matchIndices }] in display
    // order. fuzzy mode scores + sorts via Fuzzy; external mode wraps the
    // caller's already-ordered model with empty matchIndices (the caller's
    // delegate highlights off the row's own fields).
    readonly property var filtered: {
        var src = model || []
        if (filterMode === "external") {
            var ext = []
            for (var e = 0; e < src.length; e++)
                ext.push({ row: src[e], matchIndices: [] })
            return ext
        }
        var q = input.text
        var out = []
        for (var i = 0; i < src.length; i++) {
            var r = src[i]
            var t = root.textOf(r)
            var m = Fuzzy.match(t, q)
            if (m.matched)
                out.push({ row: r, matchIndices: m.indices, _score: m.score, _name: t })
        }
        out.sort(function(a, b) {
            if (q && b._score !== a._score) return b._score - a._score
            return String(a._name).localeCompare(String(b._name))
        })
        return out
    }

    // Visible-row count feeding both the ListView height and implicitHeight.
    // max(min(n, cap), minVisibleRows); cap is filtered.length when unbounded.
    readonly property int _visibleRows: {
        var n = filtered.length
        var cap = maxVisibleRows < 0 ? n : maxVisibleRows
        var v = Math.min(n, cap)
        if (v < minVisibleRows) v = minVisibleRows
        return v
    }

    implicitWidth: comboWidth
    // (inputVisible ? inputHeight : 0) + visibleRows*rowHeight + pad —
    // reproduces launcher (32+min(n,8)*32+8), switcher plain (max(n,1)*32+8),
    // switcher-search/clip (floor-1 variants). All constants from DialogTheme.
    implicitHeight: (inputVisible ? DialogTheme.inputHeight : 0)
                    + _visibleRows * DialogTheme.rowHeight
                    + DialogTheme.pad
    width: implicitWidth

    // Keep index in bounds whenever the list shape changes (model swap,
    // refilter, shrink). Clamp — never reset to 0, never leave it past the
    // last row. An empty list parks index at 0 (confirmCurrent no-ops on it).
    onFilteredChanged: _clampIndex()
    function _clampIndex() {
        if (filtered.length === 0) { index = 0; return }
        if (index < 0) index = 0
        else if (index > filtered.length - 1) index = filtered.length - 1
    }

    // ── imperative API ──────────────────────────────────────────────────────
    // next()/prev() WRAP around both ends — the switcher alt-tab cycle drives
    // these (sp017 T4). Keyboard Down/Up/Ctrl+N/Ctrl+P CLAMP instead, via the
    // private _stepClamped (sp017 T2) — deliberately distinct from the cycle.
    function next() {
        var n = filtered.length
        if (n === 0) return
        index = index < n - 1 ? index + 1 : 0
    }
    function prev() {
        var n = filtered.length
        if (n === 0) return
        index = index > 0 ? index - 1 : n - 1
    }
    function _stepClamped(delta) {
        var n = filtered.length
        if (n === 0) return
        var ni = index + delta
        if (ni < 0) ni = 0
        else if (ni > n - 1) ni = n - 1
        index = ni
    }
    function setIndex(i) {
        var n = filtered.length
        if (n === 0) { index = 0; return }
        if (i < 0) i = 0
        else if (i > n - 1) i = n - 1
        index = i
    }
    // Confirm the selected row. No-op (fires nothing) when filtered is empty —
    // an empty list + Enter must publish nothing (sp017 T2 empty-enter-noop).
    function confirmCurrent() {
        if (index >= 0 && index < filtered.length)
            root.confirm(filtered[index].row)
    }
    function _confirmAltCurrent() {
        if (index >= 0 && index < filtered.length)
            root.confirmAlt(filtered[index].row)
    }
    // Reset transient state (search text + selection) and focus the control.
    // Doubles as the reopen reset so a rapid close/reopen shows no stale filter
    // or index (sp017 T2 edge). Callers wanting a preselect (switcher MRU) call
    // setIndex(i) AFTER forceFocus().
    function forceFocus() {
        input.text = ""
        index = 0
        if (inputVisible) input.forceActiveFocus()
        else scope.forceActiveFocus()
    }

    // ── key handling ────────────────────────────────────────────────────────
    // Central handler used both by the visible TextInput and by the FocusScope
    // (so keys still work when inputVisible is false). Printable chars are left
    // unaccepted so they fall through to the TextInput as typed text.
    function _onKey(event) {
        if (event.key === Qt.Key_Escape) {
            root.cancel(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if ((event.modifiers & Qt.ShiftModifier) && root.altConfirmEnabled)
                root._confirmAltCurrent()
            else
                root.confirmCurrent()
            event.accepted = true; return
        }
        if (event.key === Qt.Key_Down ||
            (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier))) {
            root._stepClamped(1); event.accepted = true; return
        }
        if (event.key === Qt.Key_Up ||
            (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier))) {
            root._stepClamped(-1); event.accepted = true; return
        }
        // any other key (printable text) falls through to the TextInput
    }

    FocusScope {
        id: scope
        anchors.fill: parent
        Keys.onPressed: event => root._onKey(event)

        Column {
            anchors.fill: parent

            Rectangle {
                id: inputBar
                width: parent.width
                height: root.inputVisible ? DialogTheme.inputHeight : 0
                visible: root.inputVisible
                color: DialogTheme.inputBg

                TextInput {
                    id: input
                    anchors.fill: parent
                    anchors.leftMargin: DialogTheme.textLeftMargin
                    anchors.rightMargin: DialogTheme.textLeftMargin
                    verticalAlignment: TextInput.AlignVCenter
                    color: DialogTheme.fg
                    font.family: DialogTheme.font
                    font.pixelSize: DialogTheme.fontSize
                    clip: true
                    renderType: Text.NativeRendering

                    Keys.onPressed: event => root._onKey(event)
                }

                Text {
                    anchors.fill: input
                    verticalAlignment: Text.AlignVCenter
                    text: root.placeholder
                    color: DialogTheme.muted
                    font.family: DialogTheme.font
                    font.pixelSize: DialogTheme.fontSize
                    renderType: Text.NativeRendering
                    visible: root.inputVisible && !input.text
                }
            }

            ListView {
                id: list
                width: parent.width
                height: root._visibleRows * DialogTheme.rowHeight + DialogTheme.pad
                model: root.filtered
                clip: true
                currentIndex: root.index

                // Wrapper delegate: forwards row / isSelected / matchIndices to
                // the caller's delegate (the loaded component reads them as bare
                // context names — the ft008 delegate contract).
                delegate: Loader {
                    required property int index
                    required property var modelData
                    width: ListView.view ? ListView.view.width : 0
                    height: DialogTheme.rowHeight
                    sourceComponent: root.delegate
                    property var row: modelData.row
                    property bool isSelected: index === root.index
                    property var matchIndices: modelData.matchIndices
                }

                // Empty-state label — never a real row, so Enter over it fires
                // nothing. Only shown when there is genuinely nothing to list
                // and the caller supplied emptyText.
                Text {
                    anchors.centerIn: parent
                    visible: root.filtered.length === 0 && root.emptyText !== ""
                    text: root.emptyText
                    color: DialogTheme.muted
                    font.family: DialogTheme.font
                    font.pixelSize: DialogTheme.fontSize
                    renderType: Text.NativeRendering
                }
            }
        }
    }
}
