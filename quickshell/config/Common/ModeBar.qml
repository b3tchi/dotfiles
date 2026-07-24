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

    visible: mode !== "default"
    implicitWidth: strip.implicitWidth
    implicitHeight: strip.implicitHeight

    Row {
        id: strip
        objectName: "strip"
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        spacing: 0

        // name-pill: pillBg background, 2px highlight underline, bold fg label
        // bottom-anchored 1px; pill width = label implicitWidth + 14.
        Rectangle {
            objectName: "pill"
            width: pillLabel.implicitWidth + 14
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

            Rectangle {
                objectName: "underline"
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: 2
                color: ModeBarTheme.highlight
            }
        }

        // 4px gap between the pill and the hint strip.
        Item { objectName: "gap"; width: 4; height: parent.height }

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
