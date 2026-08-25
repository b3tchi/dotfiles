pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Per-project claude-agent counts (ft012 / `agent-census`), resolved once per
// quickshell instance and shared by every consumer.
//
// A SINGLETON rather than a member of Bar.qml, and that is the whole point:
// shell.qml builds Bars through `Variants { model: Quickshell.screens }`, so a
// poller living inside Bar runs once PER SCREEN. That is not merely wasteful on
// a multi-monitor desk — i3 on this xrdp session reports an inactive `xroot-0`
// output alongside the real one, so a per-Bar poller ran the census twice on a
// single-monitor box. The census is machine-wide data; nothing about it varies
// per screen, so exactly one probe should ever be in flight.
//
// (Contrast Session.qml, the other singleton here: also one per quickshell
// instance, but because its env knobs are per-SESSION. Same shape, different
// reason.)
Singleton {
    id: census

    // Overridable for the reason QS_LAYER_FEED / QS_NOTIF_FILE are: a harness
    // must be able to point this at a fixture emitter in its own tree instead
    // of whatever is checked out at ~/.dotfiles.
    readonly property string cmd: Quickshell.env("QS_CENSUS_CMD")
        || (Quickshell.env("HOME") + "/.dotfiles/nushell/actions/agent-census")

    // Poll cadence, ms. Overridable so a slow or battery-bound session can back
    // off without an edit.
    readonly property int intervalMs:
        parseInt(Quickshell.env("QS_CENSUS_INTERVAL") || "1000", 10) || 1000

    // project name -> census row. Empty until the first successful probe, so a
    // missing or failed census renders exactly like "no agents".
    property var byProject: ({})

    // Total agents for a project, and the colour that total is worth.
    //
    // Priority is blocked > working > idle: a project with one blocked agent
    // and four idle ones is one that needs you, and averaging that into a calm
    // grey would bury the single row that matters. `other` (a bucket the census
    // has never seen) counts toward the total but never claims a colour — an
    // unknown state is not evidence of urgency.
    function totalFor(project) {
        var r = census.byProject[project]
        return r ? r.total : 0
    }
    function colorFor(project) {
        var r = census.byProject[project]
        if (!r) return "transparent"
        if (r.blocked > 0) return "#cb4b16"   // same orange as an urgent tab
        if (r.working > 0) return "#16a085"   // same teal as the focused underline
        return "#707880"                      // idle: the dim-tab grey
    }

    // --fast reads the accounts' state files instead of spawning the claude
    // CLI once per account: ~1.55 CPU-s per run becomes ~0.1, which is what
    // makes a 1s cadence defensible at all. It depends on an internal layout,
    // and tests/agent-census/probe-cases.nu holds a parity case against the CLI
    // so a reshaped layout fails loudly there rather than silently blanking
    // every badge.
    //
    // Polled, not tailed: the census is a completes-and-exits action (adr0001).
    // The timer restarts in onExited rather than free-running, so probes can
    // never stack — the real cycle is intervalMs PLUS however long the census
    // took, and a slow census stretches the gap instead of piling up processes.
    //
    // Deliberately NOT chained to workspace events: agent state changes with no
    // i3 event at all, which is exactly the blindness us022 exists to fix.
    Process {
        id: proc
        running: true
        command: [census.cmd, "--fast", "--json"]
        stdout: SplitParser {
            property string buf: ""
            onRead: data => { proc.stdout.buf += data }
        }
        onExited: {
            try {
                var rows = JSON.parse(proc.stdout.buf)
                var m = {}
                for (var i = 0; i < rows.length; i++) m[rows[i].project] = rows[i]
                census.byProject = m
            } catch (err) {
                // A non-zero exit, a half-written pipe, or nu missing on this
                // box: keep the LAST good map rather than blanking every badge
                // on one bad sample. A genuinely dead census freezes the badges,
                // which the retry below corrects as soon as it works again.
            }
            proc.stdout.buf = ""
            timer.restart()
        }
    }
    Timer { id: timer; interval: census.intervalMs; onTriggered: proc.running = true }
}
