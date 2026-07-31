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
            {text: "←", key: "h"},
            {text: "↓", key: "j"},
            {text: "↑", key: "k"},
            {text: "→", key: "l"},
            {text: "arrows", key: "←↓↑→"},
            {text: "quit", key: "q"}
        ],
        "screenshot": [
            {text: "region", key: "drag/tap"},
            {text: "window", key: "w"},
            {text: "desktop", key: "d"},
            {text: "quit", key: "q"}
        ],
        // nav / nav-move (dotfiles-5u6m) — the sticky-hjkl mode's two faces.
        // i3 has ONE mode here ("nav": hjkl focus, Ctrl+hjkl move, Alt+hjkl
        // resize); it never enters "nav-move" or "nav-resize". Those names are
        // SYNTHETIC: Bar.qml swaps one in while its modifier is down, so the
        // strip shows which role the keys are currently playing.
        // The modifier is CTRL, not Shift, because xrdp synthesises Shift
        // around every character it sends — a held Shift is unobservable on
        // that session, so the cue could not be honest (see the nav block in
        // i3/config.common). Keep these keys in sync with that block.
        "nav": [
            {text: "←", key: "h"},
            {text: "↓", key: "j"},
            {text: "↑", key: "k"},
            {text: "→", key: "l"},
            {text: "ctrl-to-move", key: "^"},
            {text: "quit", key: "q"}
        ],
        "nav-move": [
            {text: "move-←", key: "h"},
            {text: "move-↓", key: "j"},
            {text: "move-↑", key: "k"},
            {text: "move-→", key: "l"},
            {text: "moving", key: "^"},
            {text: "quit", key: "q"}
        ],
        // Third layer: Alt held. Directions mirror the standalone resize mode
        // (h/l width, k/j height), so the words describe the RESULT rather
        // than the direction — "wider" reads better than "→" when the same
        // arrow means "move right" one layer up.
        "nav-resize": [
            {text: "narrower", key: "h"},
            {text: "taller", key: "j"},
            {text: "shorter", key: "k"},
            {text: "wider", key: "l"},
            {text: "resizing", key: "⎇"},
            {text: "quit", key: "q"}
        ],
        "system": [
            {text: "lock", key: "l"},
            {text: "exit", key: "e"},
            {text: "switch-user", key: "u"},
            {text: "suspend", key: "s"},
            {text: "hibernate", key: "h"},
            {text: "reboot", key: "r"},
            {text: "poweroff", key: "p"},
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
        // "screenshot-drag" is now a hotkeyd LAYER NAME, not an i3 mode
        // (sp023, dotfiles-1m4t.6). It used to be a synthetic i3 mode declared
        // in i3/config.common purely so the drag phase had a channel; that
        // block is deleted and qs-region.py raises the layer instead
        // (`hotkeyd set-layer screenshot-drag`). The name reaches this
        // function unchanged because Bar.qml's `activeMode` PREFERS a
        // non-default `daemonLayer` over the i3 mode — so during the drag it
        // resolves the layer, and during the aiming phase before it, the real
        // i3 "screenshot" mode above.
        //
        // KEEPING BOTH ARMS ON ONE REGISTRY KEY is the whole point: the strip
        // must not flicker to a different pill (or to the raw-name fallback)
        // half way through one gesture. i3 mode "screenshot" → layer
        // "screenshot-drag" → back to default renders one unbroken
        // "screenshot" strip from first keypress to saved capture.
        if (mode === "screenshot-drag") return "screenshot"
        if (mode === "nav") return "nav"
        if (mode === "nav-move") return "nav-move"       // synthetic (see hints)
        if (mode === "nav-resize") return "nav-resize"   // synthetic
        // The system surface reaches this function under TWO names, and both
        // have to keep working:
        //   "system"  — the daemon's layer name, published on the state socket
        //               since the cutover (sp020 / dotfiles-hwds.38).
        //   "(l)ock, (e)xit, ..." — i3's mode name, which is the whole label
        //               string. Still live: `hotkeyd-panic.sh panic` hands the
        //               block back to i3 verbatim, and the mode event is what
        //               the bar sees then.
        // Dropping the substring arm would blank the hints in exactly the
        // situation panic exists for. Matching on indexOf rather than equality
        // is sp018 AC4's edge case.
        if (mode === "system") return "system"
        if (mode.indexOf("(l)ock") !== -1) return "system"
        return ""
    }

    // Pill label. Derived from `resolve` so a mode cannot be registered in one
    // place and missing from the other — that split is what produced
    // dotfiles-hwds.44: the switcher layer had hints resolving to "" AND a pill
    // reading "system", and the two failures together printed a strip that
    // named the wrong mode confidently.
    //
    // AN UNKNOWN MODE NAMES ITSELF. The ternary this replaces ended in a
    // hardcoded `: "system"`, so every future layer arrived pre-mislabelled.
    // "system" is not a harmless default: it is the mode with reboot, poweroff
    // and hibernate on single letters, so a strip claiming to be it invites a
    // keystroke that ends the session. The raw name may be ugly; it is never a
    // lie, and it says exactly what to add to this registry.
    //
    // The long `$mode_system` string still lands on "system" through `resolve`
    // — that is i3's own name for the mode and what the bar sees while panicked.
    // The nav pair keeps its bespoke labels (dotfiles-5u6m): the pill is where
    // the held modifier becomes visible, so nav-move reads "nav MOVE" — a
    // different WORD, not just a different hint row.
    function displayName(mode) {
        if (mode === "nav-move") return "nav MOVE"
        if (mode === "nav-resize") return "nav RESIZE"
        var key = resolve(mode)
        return key !== "" ? key : mode
    }

    // Modes the bar must NOT paint at all (dotfiles-hwds.44). The registry's
    // third answer, beside "known" and "unknown".
    //
    // A mode strip exists to say which keys are live under your fingers while
    // the keyboard is in a state you cannot see. The alt-tab switcher is not
    // that: it puts a full-screen overlay on the display listing exactly what
    // it will do, so a second announcement in the bar tells you nothing and
    // costs the workspace row for the length of every gesture. $mod+w and
    // $mod+Tab should feel like $mod+d and $mod+p — open a thing, leave the
    // bar alone — and they did before the cutover, when the whole gesture ran
    // outside the mode channel in qs-keymon.py.
    //
    // Silence is a rendering decision, NOT a publishing one: hotkeyd still
    // emits layer=switcher on the state socket, and other consumers still read
    // it. Only the bar declines to draw it.
    readonly property var silentModes: ["switcher"]

    function silent(mode) {
        return silentModes.indexOf(mode) !== -1
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
