pragma Singleton
import Quickshell
import QtQuick
import "."

// Shared geometry + colors for the i3 dialog family (launcher, switcher,
// projects, clip picker). Single source for the constants that used to be
// hardcoded and drifting across config/Overlay.qml and ClipHistory.qml.
// Values are lifted VERBATIM from config/Overlay.qml (sp017 AC1) — do not
// retune them here without matching the pre-refactor render.
//
// sp004 Task 14 (kwi3-234.14, ft008 kwi3-grid-feed): under a real kwi3
// session (Kwi3Grid.active) font/rowHeight/inputHeight/width/pad are derived
// from kwi3's own character-cell grid instead of these literals, so the
// dialogs line up with the tiles sharing the screen. Kwi3Grid.active stays
// false forever under i3/sway — Kwi3Client never even attempts a connection
// without $KWI3SOCK (see Kwi3Client.qml's own header) — so every property
// below falls straight back to the AC1 literal on that path, unchanged.
//
// The whole-cell derivation: Kwi3Grid's HEADER (core/defaults.js) equals
// MODULE_H exactly (one titlebar row IS one module row), so rowHeight is
// already a whole module on its own; width and pad are rounded to the
// nearest whole number of modules via Kwi3Grid.cells() (never zero cells —
// cells() floors at 1), which is what keeps total height a whole multiple of
// moduleH for any row count: (1 + n)*moduleH [input + n rows] + pad, and pad
// is itself k*moduleH.
Singleton {
    id: theme

    // WM detection — mirrors config/Overlay.qml `isSway` so fontSize tracks
    // the compositor (sway renders one px smaller than i3, historically).
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null

    // --- AC1 parity constants (config/Overlay.qml) — the i3/sway fallback,
    // and the base a kwi3 session's whole-cell values are derived FROM (the
    // 480/8 launcher width and the 8px pad are pre-existing choices; kwi3
    // just rounds them onto its own grid rather than replacing them with new
    // numbers of their own). ---
    readonly property int _fallbackWidth: 480       // overlay.width launcher/projects
    readonly property int _fallbackRowHeight: 32    // list delegate height
    readonly property int _fallbackPad: 8           // list vertical padding (+8)
    readonly property string _fallbackFont: "Iosevka Nerd Font"
    readonly property int _fallbackFontSize: isSway ? 14 : 16

    readonly property int width: Kwi3Grid.active
        ? Kwi3Grid.cells(_fallbackWidth, Kwi3Grid.moduleW) * Kwi3Grid.moduleW
        : _fallbackWidth
    readonly property int rowHeight: Kwi3Grid.active ? Kwi3Grid.rowHeight : _fallbackRowHeight
    readonly property int inputHeight: rowHeight
    readonly property int pad: Kwi3Grid.active
        ? Kwi3Grid.cells(_fallbackPad, Kwi3Grid.moduleH) * Kwi3Grid.moduleH
        : _fallbackPad
    readonly property string font: Kwi3Grid.active ? Kwi3Grid.fontFamily : _fallbackFont
    readonly property int fontSize: Kwi3Grid.active ? Kwi3Grid.fontPixelSize : _fallbackFontSize

    readonly property string inputBg: "#152024"
    readonly property int maxRows: 8          // Math.min(n, 8) visible cap
    readonly property string bodyBg: "#222D31"
    readonly property string fg: "#FDF6E3"

    // --- shared accent / muted / urgent + spacing ---
    readonly property string accent: "#16a085"   // selection bar + match hi
    readonly property string muted: "#707880"    // placeholder / ws / focused
    readonly property string urgent: "#CB4B16"   // urgent-window accent
    readonly property int textLeftMargin: 12      // row/input left inset
}
