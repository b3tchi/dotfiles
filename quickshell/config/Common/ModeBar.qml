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
        // key in highlight bold, single space, label in fg — all bottom-anchored
        // 1px. Driven by ModeBarTheme.hintsFor(mode) (known modes -> their rows;
        // unknown modes -> one [{key:"", label:<raw mode>}] fallback row).
        Repeater {
            model: root.visible ? ModeBarTheme.hintsFor(root.mode) : []

            Row {
                objectName: "hintRow"
                required property var modelData
                required property int index
                anchors.bottom: parent ? parent.bottom : undefined
                anchors.bottomMargin: 1

                // separator — DEFAULT font (parity with Bar.qml:599); a
                // space's advance differs by font, so Iosevka here would widen
                // the strip. Only pixelSize + NativeRendering, like the source.
                Text {
                    objectName: "hsep"
                    text: index > 0 ? "  " : ""
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                }
                Text {
                    objectName: "hk"
                    text: modelData.key
                    color: ModeBarTheme.highlight
                    font.family: ModeBarTheme.font
                    font.pixelSize: root.fontSize
                    font.bold: true
                    renderType: Text.NativeRendering
                }
                // key/label spacer — DEFAULT font too (parity with Bar.qml:601).
                Text {
                    objectName: "hspace"
                    text: " "
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                }
                Text {
                    objectName: "hl"
                    text: modelData.label
                    color: ModeBarTheme.fg
                    font.family: ModeBarTheme.font
                    font.pixelSize: root.fontSize
                    renderType: Text.NativeRendering
                }
            }
        }
    }
}
