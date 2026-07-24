pragma Singleton
import Quickshell
import QtQuick

// Colors + hint data for the i3/sway mode-hint bar (name-pill + keyboard-hint
// strip shown while in `resize`, `screenshot`, or the system mode). Single
// source for the constants and the mode->hints map that used to be hardcoded
// inline in config/Bar.qml (sp018 smells 2 + 3). Values are lifted VERBATIM
// from config/Bar.qml's modeHints() and the pill display-name ternary
// (sp018 AC1/AC4) — do not retune them here without matching the pre-refactor
// render. Hex is UPPERCASE to match DialogTheme; QML color parsing is
// case-insensitive so the render is identical to Bar.qml's lowercase literals.
Singleton {
    id: theme

    // --- AC1 parity constants ---
    readonly property string highlight: "#CB4B16"  // key text + pill underline
    readonly property string pillBg: "#152024"     // name-pill background
    readonly property string fg: "#FDF6E3"          // pill label + hint labels
    readonly property string muted: "#707880"       // reserved (bar-muted tone)
    readonly property string font: "Iosevka Nerd Font"

    // --- hints registry: mode -> [{key, label}], keyed by resolved mode name.
    //     Rows are byte-identical to config/Bar.qml's pre-refactor modeHints().
    readonly property var hints: ({
        "resize": [
            {key: "j", label: "←"},
            {key: "k", label: "↓"},
            {key: "l", label: "↑"},
            {key: ";", label: "→"},
            {key: "←↓↑→", label: "arrows"},
            {key: "Esc", label: "exit"}
        ],
        "screenshot": [
            {key: "drag", label: "select region"},
            {key: "2-tap", label: "corners"},
            {key: "w", label: "whole screen"},
            {key: "Esc", label: "cancel"}
        ],
        "system": [
            {key: "l", label: "lock"},
            {key: "e", label: "exit"},
            {key: "u", label: "switch user"},
            {key: "s", label: "suspend"},
            {key: "h", label: "hibernate"},
            {key: "r", label: "reboot"},
            {key: "S-s", label: "shutdown"},
            {key: "Esc", label: "cancel"}
        ]
    })

    // Map a raw i3/sway mode string to its registry key, or "" if unknown.
    // The system mode's IPC name is the full `$mode_system` string
    // (`(l)ock, (e)xit, ...`, i3/config.common:255), matched via
    // indexOf("(l)ock") — NOT equality (sp018 AC4 edge case).
    function resolve(mode) {
        if (mode === "resize") return "resize"
        if (mode === "screenshot") return "screenshot"
        if (mode.indexOf("(l)ock") !== -1) return "system"
        return ""
    }

    // Pill label — verbatim from Bar.qml's display-name ternary: resize and
    // screenshot show their own name, everything else (incl. the long system
    // string and unknown/future modes) shows "system".
    function displayName(mode) {
        return mode === "resize" ? "resize"
             : mode === "screenshot" ? "screenshot" : "system"
    }

    // Hint rows for a mode. Known modes return their registry rows; unknown
    // modes fall back to a single [{key: "", label: <raw mode>}] row —
    // verbatim from Bar.qml's modeHints() `return [{key:"", label:mode}]`.
    function hintsFor(mode) {
        var key = resolve(mode)
        if (key === "") return [{key: "", label: mode}]
        return hints[key]
    }
}
