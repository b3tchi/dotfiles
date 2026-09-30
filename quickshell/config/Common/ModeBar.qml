import QtQuick
import "."

// ModeBar (sp018 / ft009) — the reusable i3/sway mode-hint strip: a name-pill
// plus a keyboard-hint row, reproducing config/Bar.qml's inline "Mode hints
// overlay" Row pixel-for-pixel (sp018 AC1). An Item, never top-level chrome —
// the host owns the bar surface and the mode-subscription i3 IPC watcher;
// ModeBar is pure render driven by `mode` + `fontSize`. Colours, the label
// font, and the hint data come from ModeBarTheme (no hardcoded literals —
// parity with the pre-refactor render is the contract). `mode: "default"`
// renders nothing.
//
// Parity notes vs Bar.qml: the pure-whitespace Texts (the hint separator and
// the key/label spacer) deliberately keep the DEFAULT font, NOT ModeBarTheme's
// Iosevka — matching Bar.qml:599/601, because a space's advance width differs
// by font (Iosevka nearly doubles it) and would widen the strip. Only the
// coloured Texts (pill label, hint key, hint label) carry ModeBarTheme.font.
// The one omission is Bar.qml's transparent `z:-1` Rectangle behind each key —
// a true no-op (fully transparent, no layout effect), dropped as dead cruft.
Item {
    id: root

    // ── ft009 api_surface — exactly these two props ─────────────────────────
    // mode: the current i3/sway mode string ("default" => invisible). fontSize:
    // the host's compositor-aware size (sway/phone differ from desktop).
    property string mode: "default"
    property int fontSize: 0

    // dotfiles-puoh: kwi3's character-cell width (Kwi3Grid.moduleW; 0 on i3 /
    // Wayland where Kwi3Grid never activates). >0 => the strip is sized in
    // whole cells like the workspace tabs (adr0007 / ft008): pill = label
    // rounded UP to cells + one cell of pad each side, gap = one cell, each
    // hint row rounded UP to cells with cell-wide separators. 0 => today's
    // pixel-identical look. Overridable so the headless suite can exercise a
    // grid (Kwi3Grid itself is a real singleton fed by Kwi3Client). Not part
    // of ft009's two-prop api_surface for hosts: they leave it at the default.
    property int cellW: Kwi3Grid.moduleW
    readonly property bool onGrid: cellW > 0

    // "default" => nothing to announce. A mode on ModeBarTheme.silentModes =>
    // deliberately not announced (dotfiles-hwds.44): the switcher's own overlay
    // already says what it is. Invisible AND zero-width — an empty strip would
    // still reserve space and push the host's other widgets around.
    visible: mode !== "default" && !ModeBarTheme.silent(mode)
    implicitWidth: strip.implicitWidth
    implicitHeight: strip.implicitHeight

    // kwi3-55l.27 (Jan, 3392, verbatim): "green line above should have mode
    // to turn orange and display only above first label" - the bar's own
    // ring-highlight companion window (kwi3-55l.20, retargeted to the mode
    // segment by kwi3-55l.24) now follows only the PILL - the mode's own
    // name label, "the first label" - not the whole strip (pill + gap +
    // hints). Exposed here, not re-derived in Bar.qml, for the same reason
    // implicitWidth/height already are: the pill Rectangle is this
    // component's own geometry, and a second computation of it in the host
    // would drift the moment padding here changes.
    readonly property alias pillWidth: pill.width

    Row {
        id: strip
        objectName: "strip"
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        spacing: 0

        // name-pill: pillBg background, bold fg label bottom-anchored 1px;
        // pill width = label implicitWidth + 14.
        //
        // kwi3-55l.27 (Jan, 3392): "in mode green should be hidden and orange
        // line should be at same height as is the green line" / "green line
        // above should have mode to turn orange and display only above first
        // label" - the 2px highlight underline that used to be drawn HERE,
        // inside the bar, at the pill's own top edge, is gone (like
        // kwi3-55l.20 removed the workspace tab's equivalent in-bar stripe).
        // The bar's companion ring window now draws that highlight OUTSIDE
        // the bar, in the half-gap band above it, at the SAME rows the
        // workspace ring uses at rest (Bar.qml modeSegmentScreenRect /
        // ringColor) - one line, not two, per pill and per tab.
        Rectangle {
            id: pill
            objectName: "pill"
            width: root.onGrid
                   ? Math.ceil(pillLabel.implicitWidth / root.cellW) * root.cellW + 2 * root.cellW
                   : pillLabel.implicitWidth + 14
            height: parent.height
            color: ModeBarTheme.pillBg

            Text {
                id: pillLabel
                objectName: "pillLabel"
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 1
                text: ModeBarTheme.displayName(root.mode)
                color: ModeBarTheme.fg
                font.family: ModeBarTheme.font
                font.pixelSize: root.fontSize
                font.bold: true
                renderType: Text.NativeRendering
            }
        }

        // 4px gap between the pill and the hint strip.
        // One cell on kwi3 (dotfiles-puoh) - a cell keeps every hint row
        // starting on the grid; 0 would butt the pill against the first hint.
        Item { objectName: "gap"; width: root.onGrid ? root.cellW : 4; height: parent.height }

        // hint rows: two-space separator before every entry after the first,
        // then the hint itself. ft009 extension (sp018 follow-up) — the key is
        // the HIGHLIGHTED part of the word: when `key` occurs inside `text`,
        // render pre(fg) + key(highlight bold) + post(fg) so e.g. "Escape"
        // shows as **Esc**ape. When `key` is not a substring (arrows, `drag`,
        // `2-tap`), fall back to the classic key(highlight bold) + space + text.
        //
        // A single 5-span layout serves both orderings by toggling which spans
        // carry content: [pre][key][post][space][tail].
        //   inline   : pre=text[0..hlAt)  key=key  post=text[hlAt+len..]  space="" tail=""
        //   fallback : pre=""             key=key  post=""                space=" " tail=text
        Repeater {
            model: root.visible ? ModeBarTheme.hintsFor(root.mode) : []

            Row {
                objectName: "hintRow"
                required property var modelData
                required property int index
                anchors.bottom: parent ? parent.bottom : undefined
                anchors.bottomMargin: 1
                // kwi3 (dotfiles-puoh): the row's width is its content rounded
                // UP to whole cells (never Kwi3Grid.cells(), which rounds and
                // can clip the last glyph). Not on kwi3: implicitWidth, i.e.
                // exactly what a bare Row does.
                width: root.onGrid ? Math.ceil(implicitWidth / root.cellW) * root.cellW
                                   : implicitWidth

                readonly property string kkey: modelData.key
                readonly property string ktext: modelData.text
                // first occurrence of the key inside the word (-1 => fallback).
                // An empty key never matches -> unknown-mode raw name renders
                // plain via the fallback path (space+tail, key span empty).
                readonly property int hlAt: kkey.length > 0 ? ktext.indexOf(kkey) : -1
                readonly property bool inl: hlAt >= 0

                // separator — DEFAULT font (parity with Bar.qml:599); a
                // space's advance differs by font, so Iosevka here would widen
                // the strip. Only pixelSize + NativeRendering, like the source.
                Text {
                    objectName: "hsep"
                    text: index > 0 ? "  " : ""
                    // kwi3: two whole cells regardless of the font's space.
                    width: root.onGrid ? (index > 0 ? 2 * root.cellW : 0) : implicitWidth
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                }
                // pre — word chars before the highlighted key (inline only).
                Text {
                    objectName: "hpre"
                    text: inl ? ktext.substring(0, hlAt) : ""
                    color: ModeBarTheme.fg
                    font.family: ModeBarTheme.font
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                }
                // key — the highlighted trigger, in both orderings.
                Text {
                    objectName: "hk"
                    text: kkey
                    color: ModeBarTheme.highlight
                    font.family: ModeBarTheme.font
                    font.pixelSize: root.fontSize
                    font.bold: true
                    renderType: Text.NativeRendering
                }
                // post — word chars after the highlighted key (inline only).
                Text {
                    objectName: "hpost"
                    text: inl ? ktext.substring(hlAt + kkey.length) : ""
                    color: ModeBarTheme.fg
                    font.family: ModeBarTheme.font
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                }
                // key/label spacer — DEFAULT font (parity with Bar.qml:601);
                // fallback layout only.
                Text {
                    objectName: "hspace"
                    text: inl ? "" : " "
                    // kwi3: one whole cell between key and label.
                    width: root.onGrid ? (inl ? 0 : root.cellW) : implicitWidth
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                }
                // tail — the whole word, fallback layout only (key not in word).
                Text {
                    objectName: "hl"
                    text: inl ? "" : ktext
                    color: ModeBarTheme.fg
                    font.family: ModeBarTheme.font
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                }
            }
        }
    }
}
