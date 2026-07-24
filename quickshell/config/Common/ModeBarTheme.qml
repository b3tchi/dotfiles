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

    // --- hints registry: mode -> [{text, key}], keyed by resolved mode name.
    //     `text` is the full hint word; `key` is the trigger. ModeBar renders
    //     the first occurrence of `key` inside `text` in `highlight` (i3's own
    //     `(l)ock` convention — the key IS the highlighted part of the word).
    //     When `key` is not a substring of `text` (arrow directions, `drag`,
    //     `2-tap`), ModeBar falls back to the classic `key␣text` layout.
    //     Multi-word hints are kebab-cased (no spaces) so the whole word is one
    //     highlightable token. Every mode exits with `q` -> "quit" (bound
    //     alongside Escape in i3 config.common/config + qs-region.py).
    readonly property var hints: ({
        "resize": [
            {text: "←", key: "j"},
            {text: "↓", key: "k"},
            {text: "↑", key: "l"},
            {text: "→", key: ";"},
            {text: "arrows", key: "←↓↑→"},
            {text: "quit", key: "q"}
        ],
        "screenshot": [
            {text: "select-region", key: "drag"},
            {text: "corners", key: "2-tap"},
            {text: "whole-screen", key: "w"},
            {text: "quit", key: "q"}
        ],
        "system": [
            {text: "lock", key: "l"},
            {text: "exit", key: "e"},
            {text: "switch-user", key: "u"},
            {text: "suspend", key: "s"},
            {text: "hibernate", key: "h"},
            {text: "reboot", key: "r"},
            {text: "shutdown", key: "S-s"},
            {text: "quit", key: "q"}
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
    // modes fall back to a single [{text: <raw mode>, key: ""}] row — an empty
    // key highlights nothing, so the raw name renders plain (fg).
    function hintsFor(mode) {
        var key = resolve(mode)
        if (key === "") return [{text: mode, key: ""}]
        return hints[key]
    }
}
