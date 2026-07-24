import QtQuick
import "."

// ModeBar (sp018 / ft009) — the reusable i3/sway mode-hint strip: a name-pill
// plus a keyboard-hint row, extracted VERBATIM from config/Bar.qml's inline
// "Mode hints overlay" Row. An Item, never top-level chrome — the host owns the
// bar surface and the mode-subscription i3 IPC watcher; ModeBar is pure render
// driven by `mode` + `fontSize`. Every colour, the font, and the hint data come
// from ModeBarTheme (no hardcoded literals — parity with the pre-refactor
// render is the contract, sp018 AC1). `mode: "default"` renders nothing.
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

                Text {
                    text: index > 0 ? "  " : ""
                    font.family: ModeBarTheme.font
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
                Text {
                    text: " "
                    font.family: ModeBarTheme.font
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
