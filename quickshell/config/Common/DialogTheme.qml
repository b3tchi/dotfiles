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
    // kwi3-55l.19: the pre-kwi3 AC1 literal for the row/input left inset —
    // never derived from any grid, i3/sway has none to derive it from. It
    // is NOT a whole multiple of the fallback dialogs' own font metrics
    // either; it was simply the pixel value that looked right under i3.
    readonly property int _fallbackTextLeftMargin: 12

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

    // kwi3-55l.19: row/input left inset. Every other whole-cell property
    // above (width/rowHeight/pad) was already re-derived from Kwi3Grid when
    // a kwi3 session is live (sp004 T14) — this was the one left as the
    // bare _fallbackTextLeftMargin (12px) even under Kwi3Grid.active, so the
    // dialog's own first glyph column (Overlay.qml/Combo.qml anchor every
    // Text/TextInput's left edge off this) landed 12px in against a module
    // that is only 8px on Jan's session (12 is 1.5 cells) — bigger than one
    // module AND off the grid by a half cell, rather than aligned with the
    // tab/titlebar text one module in that this dialog sits beside. One
    // whole module (Kwi3Grid.moduleW) is exactly what the other dialog
    // insets already use as their unit (Kwi3Grid.cells() rounds width/pad
    // onto it) — this is the same rule applied to the one property that had
    // been left out. i3/sway (Kwi3Grid.active never true there) keeps the
    // unchanged 12px fallback.
    readonly property int textLeftMargin: Kwi3Grid.active ? Kwi3Grid.moduleW : _fallbackTextLeftMargin
}
