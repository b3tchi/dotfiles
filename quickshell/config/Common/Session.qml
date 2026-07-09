pragma Singleton
import Quickshell
import QtQuick

// Per-session bar configuration, resolved once per quickshell instance.
// Each session (desktop :0, xrdp :2/:10, phone) launches its own instance
// with its own env (set in that session's i3/sway config), so everything
// here naturally varies per session while the QML stays shared.
//
// Env knobs:
//   QS_RDP=1              RDP session — software render, no focus fx
//   QS_PHONE=1            sxmo/phone — floating pill via layer-shell margins
//   QS_BAR_INSET_*        X11 inset pill (bottom/side/top), pixels
//   QS_BAR_HEIGHT=N       bar height override (default 24 sway / 27 i3)
//   QS_BAR_FONT=N         font pixel size override (default 14 sway / 16 i3)
//   QS_BAR_DENSITY=x      full | compact | minimal | auto (default auto:
//                         picked from the screen width per monitor)
Singleton {
    id: session

    // --- flags ---
    readonly property bool isRdp:   Quickshell.env("QS_RDP") === "1"
    readonly property bool isPhone: Quickshell.env("QS_PHONE") === "1"
    readonly property bool isSway:  Quickshell.env("SWAYSOCK") !== null

    function envInt(name, fallback) {
        var v = parseInt(Quickshell.env(name) ?? "")
        return isNaN(v) ? fallback : v
    }
    function envStr(name, fallback) {
        var v = Quickshell.env(name)
        return (v === null || v === "") ? fallback : v
    }

    // --- geometry ---
    readonly property int insetBottom: envInt("QS_BAR_INSET_BOTTOM", 0)
    readonly property int insetSide:   envInt("QS_BAR_INSET_SIDE", 0)
    readonly property int insetTop:    envInt("QS_BAR_INSET_TOP", 0)
    readonly property int barHeight:   envInt("QS_BAR_HEIGHT", isSway ? 24 : 27)
    readonly property int fontSize:    envInt("QS_BAR_FONT",   isSway ? 14 : 16)

    // --- widget density ---
    // full: everything; compact: drop NET + HDD; minimal: also drop CPU + RAM.
    // Auto-tiers by the bar's own screen width, so a narrow xrdp viewport or
    // a small monitor sheds the wide stats block while a desktop keeps it.
    readonly property string densityOverride: envStr("QS_BAR_DENSITY", "auto")
    function densityFor(screenWidth) {
        if (densityOverride !== "auto") return densityOverride
        if (screenWidth >= 1400) return "full"
        if (screenWidth >= 1000) return "compact"
        return "minimal"
    }
}
