pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Per-session and per-machine bar configuration, resolved once per
// quickshell instance. Each session (desktop :0, xrdp :2/:10, phone)
// launches its own instance with its own env, so everything here varies per
// session while the QML stays shared.
//
// Every bar setting is looked up in this order, first hit wins:
//   1. its env var below (a session's own override)
//   2. the machine file's "screens" entry for the bar's screen
//   3. the machine file's top level
//   4. the built-in default
//
// THE MACHINE FILE: $QS_MACHINE_CONFIG, else
// ${XDG_CONFIG_HOME:-~/.config}/quickshell-machine.json - JSON, one per
// machine, linked by quickshell/dot.yaml from quickshell/machines/
// <hostname>.json. No file (or a file that does not parse) means built-in
// defaults. Keys, all optional:
//
//   {
//     "split": true,             // QS_BAR_SPLIT
//     "density": "compact",      // QS_BAR_DENSITY
//     "height": 27,              // QS_BAR_HEIGHT \ not under kwi3: there the
//     "font": 16,                // QS_BAR_FONT   / bar is one titlebar row
//     "insetTop": 0, "insetSide": 0, "insetBottom": 0,   // QS_BAR_INSET_*
//     "insetAuto": false,        // QS_BAR_INSET_AUTO
//     "screens": {               // per screen, by Quickshell's screen name
//       "DSI-1": { "density": "compact" }
//     }
//   }
//
// Env knobs:
//   QS_RDP=1              RDP session — software render, no focus fx
//   QS_PHONE=1            sxmo/phone — floating pill via layer-shell margins
//   QS_MACHINE_CONFIG     path of the machine file (above)
//   QS_BAR_INSET_*        X11 inset pill (bottom/side/top), pixels
//   QS_BAR_INSET_AUTO=1   apply insets only while the viewport is taller
//                         than 2:1 — identifies a phone client (Razr
//                         768x1804 ~ 2.35:1; rounded corners + chin) while
//                         a monitor client, even a rotated one (1080x1920
//                         = 1.78:1), keeps a flush bar; xrdp resizes the
//                         display per client, so the ratio tracks the client
//   QS_BAR_HEIGHT=N       bar height override (default 24 sway / 27 i3)
//   QS_BAR_FONT=N         font pixel size override (default 14 sway / 16 i3)
//   QS_BAR_SPLIT=1        workspace tabs + mode strip in a second bar at the
//                         bottom of the screen (the phone)
//   QS_BAR_DENSITY=x      full | compact | minimal | auto (default auto:
//                         picked from the screen width per monitor)
Singleton {
    id: session

    // --- flags ---
    readonly property bool isRdp:   Quickshell.env("QS_RDP") === "1"
    readonly property bool isPhone: Quickshell.env("QS_PHONE") === "1"
    readonly property bool isSway:  Quickshell.env("SWAYSOCK") !== null

    // --- the machine file ---
    readonly property string machinePath: {
        var p = Quickshell.env("QS_MACHINE_CONFIG")
        if (p) return p
        var x = Quickshell.env("XDG_CONFIG_HOME")
        return (x ? x : Quickshell.env("HOME") + "/.config") + "/quickshell-machine.json"
    }
    FileView {
        id: machineFile
        path: session.machinePath
        blockLoading: true
        printErrors: false
    }
    readonly property var machine: {
        var t = machineFile.text()
        if (!t) return {}
        try {
            var m = JSON.parse(t)
            return (m && typeof m === "object") ? m : {}
        } catch (e) {
            console.warn("Session: " + machinePath + ": " + e)
            return {}
        }
    }

    // The machine file's value for `key` on `screenName` ("" for none), or
    // undefined.
    function machineOpt(screenName, key) {
        var s = machine.screens
        if (screenName && s && s[screenName] && s[screenName][key] !== undefined)
            return s[screenName][key]
        return machine[key]
    }
    function optInt(screenName, env, key, fallback) {
        var v = parseInt(Quickshell.env(env) ?? "")
        if (!isNaN(v)) return v
        v = parseInt(machineOpt(screenName, key))
        return isNaN(v) ? fallback : v
    }
    function optBool(screenName, env, key) {
        var e = Quickshell.env(env)
        if (e !== null && e !== "") return e === "1"
        return machineOpt(screenName, key) === true
    }
    function optStr(screenName, env, key, fallback) {
        var e = Quickshell.env(env)
        if (e !== null && e !== "") return e
        var v = machineOpt(screenName, key)
        return (typeof v === "string" && v !== "") ? v : fallback
    }

    // --- per screen ---
    // QS_BAR_SPLIT / "split": the bar's left part (workspace tabs, mode
    // strip) moves to a second bar at the BOTTOM of the screen - the phone,
    // where one row across 675 logical px holds both halves only cramped.
    function splitFor(screenName)  { return optBool(screenName, "QS_BAR_SPLIT", "split") }
    function heightFor(screenName) { return optInt(screenName, "QS_BAR_HEIGHT", "height", isSway ? 24 : 27) }
    function fontFor(screenName)   { return optInt(screenName, "QS_BAR_FONT", "font", isSway ? 14 : 16) }
    function insetFor(screenName, side) {   // side: "Top" | "Side" | "Bottom"
        return optInt(screenName, "QS_BAR_INSET_" + side.toUpperCase(), "inset" + side, 0)
    }
    // With QS_BAR_INSET_AUTO=1 insets engage only when the viewport is
    // phone-shaped: taller than 2:1. Screen dims come from the Bar's own
    // screen so a reconnect that resizes the display re-evaluates this
    // live via RANDR.
    function insetActive(screenName, screenWidth, screenHeight) {
        return !optBool(screenName, "QS_BAR_INSET_AUTO", "insetAuto")
            || screenHeight >= 2 * screenWidth
    }

    // --- widget density ---
    // full: everything; compact: drop NET + HDD; minimal: also drop CPU + RAM
    // (never with a split bar).
    // Auto-tiers by the bar's own screen width, so a narrow xrdp viewport or
    // a small monitor sheds the wide stats block while a desktop keeps it.
    function densityFor(screenName, screenWidth) {
        var d = optStr(screenName, "QS_BAR_DENSITY", "density", "auto")
        if (d !== "auto") return d
        if (screenWidth >= 1400) return "full"
        if (screenWidth >= 1000) return "compact"
        // split: the top bar holds only the stats, so CPU + RAM fit
        if (splitFor(screenName)) return "compact"
        return "minimal"
    }
}
