pragma Singleton
import Quickshell
import QtQuick

// Shared geometry + colors for the i3 dialog family (launcher, switcher,
// projects, clip picker). Single source for the constants that used to be
// hardcoded and drifting across config/Overlay.qml and ClipHistory.qml.
// Values are lifted VERBATIM from config/Overlay.qml (sp017 AC1) — do not
// retune them here without matching the pre-refactor render.
Singleton {
    id: theme

    // WM detection — mirrors config/Overlay.qml `isSway` so fontSize tracks
    // the compositor (sway renders one px smaller than i3, historically).
    readonly property bool isSway: Quickshell.env("SWAYSOCK") !== null

    // --- AC1 parity constants (config/Overlay.qml) ---
    readonly property int width: 480          // overlay.width launcher/projects
    readonly property int inputHeight: 32     // input bar Rectangle height
    readonly property string inputBg: "#152024"
    readonly property int rowHeight: 32       // list delegate height
    readonly property int maxRows: 8          // Math.min(n, 8) visible cap
    readonly property string bodyBg: "#222D31"
    readonly property string fg: "#FDF6E3"
    readonly property string font: "Iosevka Nerd Font"

    // --- shared accent / muted / urgent + spacing ---
    readonly property string accent: "#16a085"   // selection bar + match hi
    readonly property string muted: "#707880"    // placeholder / ws / focused
    readonly property string urgent: "#CB4B16"   // urgent-window accent
    readonly property int pad: 8                  // list vertical padding (+8)
    readonly property int textLeftMargin: 12      // row/input left inset
    readonly property int fontSize: isSway ? 14 : 16
}
