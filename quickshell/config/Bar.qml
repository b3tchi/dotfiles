import Quickshell
import Quickshell.I3
import Quickshell.Io
import Quickshell.Services.SystemTray
import QtQuick
import QtQuick.Layouts
import "./Common"

PanelWindow {
    id: root

    property int notifCount: 0
    property string notifText: ""
    property int notifSeq: 0
    property bool hasCritical: false
    signal dismissNotif()
    signal dismissNotifSilent()
    signal tickerFinished()

    // WM detection — sway uses same IPC as i3
    readonly property bool isSway: Session.isSway
    readonly property string wmMsg: isSway ? "swaymsg" : "i3-msg"

    // Per-session + per-screen widget density (Session.qml): gates the wide
    // stats block so a narrow xrdp viewport / small monitor stays uncluttered.
    readonly property string density: Session.densityFor(screen ? screen.width : 1920)
    readonly property bool showNet:  density === "full"
    readonly property bool showDisk: density === "full"
    readonly property bool showCpu:  density !== "minimal"
    readonly property bool showRam:  density !== "minimal"

    // Ticker state
    property bool tickerActive: false

    onNotifSeqChanged: {
        if (notifText !== "") {
            tickerAnim.stop()
            tickerActive = true
            tickerStartDelay.restart()
        }
    }
    Timer {
        id: tickerStartDelay
        interval: 0
        onTriggered: {
            tickerText.x = tickerArea.width
            tickerAnim.restart()
        }
    }

    // Bar sits at the top on every session type (desktop + phone).
    anchors {
        left: true
        right: true
        top: true
    }

    // X11 inset pill (rounded display corners): PanelWindow margins are a
    // Wayland/layer-shell feature and a NO-OP on X11, so instead the window
    // grows by the inset and the bar is drawn as an inset pill inside it.
    // The bar is anchored at the TOP; the bottom rounded-corner clearance
    // (Razr chin) is a separate strut-reserving panel — see BarChin.qml — so
    // app windows stay clear of the physical bottom corners while the bar
    // lives at the top. Only side/top insets shape the bar itself here.
    // Tunable via env: QS_BAR_INSET_SIDE / QS_BAR_INSET_TOP (bottom clearance
    // via QS_BAR_INSET_BOTTOM is consumed by BarChin). With QS_BAR_INSET_AUTO=1
    // the inset engages only while the viewport is phone-shaped (taller than
    // 2:1) — reactive to screen size, so an xrdp reconnect from a monitor
    // client flattens everything without a restart.
    readonly property bool insetOn: Session.insetActive(
        screen ? screen.width : 1920, screen ? screen.height : 1080)
    readonly property int insetSide:   insetOn ? Session.insetSide : 0
    readonly property int insetTop:    insetOn ? Session.insetTop : 0
    readonly property bool inset: insetSide > 0 || insetTop > 0

    implicitHeight: Session.barHeight + insetTop

    // Phone (sxmo, sway/Wayland): floating pill at the top via real
    // layer-shell margins; desktop (i3/sway): full-width top bar. On X11 use
    // QS_BAR_INSET_* instead.
    readonly property bool isPhone: Session.isPhone
    margins {
        top:   isPhone ? 20 : 0
        left:  isPhone ? 40 : 0
        right: isPhone ? 40 : 0
    }

    readonly property color barColor: "#000000"
    // Black surround: blends into the Razr's bezel/chin so the pill reads as
    // floating on the hardware edge rather than on a colored strip.
    color: inset ? "#000000" : barColor

    readonly property string fontFamily: "Iosevka Nerd Font"
    readonly property int fontSize: Session.fontSize
    readonly property int nativeRender: Text.NativeRendering

    // Workspaces sourced directly from i3 IPC (authoritative). Quickshell's
    // I3.workspaces ObjectModel was previously used as the data source, but it
    // does not always track `rename`/`empty`/`init` events fired by wm-state
    // restore — leaving stale entries (e.g. ghost `dotfiles-old`) in the bar
    // until quickshell restarts. Reading get_workspaces directly via i3-msg on
    // every workspace event matches what i3 actually has.
    property var sortedWorkspaces: []

    // Fetch full workspace records from i3 IPC. Re-runs on every workspace
    // event (subscribe stream below) plus a 2s safety-net timer.
    Process {
        id: wsListProc
        running: true
        command: ["sh", "-c", root.wmMsg + " -t get_workspaces"]
        stdout: SplitParser {
            property string buf: ""
            onRead: data => { wsListProc.stdout.buf += data }
        }
        onExited: {
            try {
                var arr = JSON.parse(wsListProc.stdout.buf)
                arr.sort(function(a, b) { return a.num - b.num })
                var out = []
                for (var i = 0; i < arr.length; i++) {
                    var w = arr[i]
                    out.push({
                        name: w.name,
                        number: w.num,
                        focused: w.focused,
                        active: w.visible,
                        urgent: w.urgent,
                        wsId: w.id
                    })
                }
                root.sortedWorkspaces = out
            } catch (err) {}
            wsListProc.stdout.buf = ""
            wsListTimer.restart()
        }
    }
    Timer { id: wsListTimer; interval: 2000; onTriggered: wsListProc.running = true }

    // Refresh on every workspace event (init, focus, empty, urgent, rename, move, restored, reload)
    Process {
        id: wsEventSub
        running: true
        command: [root.wmMsg, "-t", "subscribe", "-m", '["workspace"]']
        stdout: SplitParser {
            onRead: data => wsListProc.running = true
        }
        onExited: running = true
    }

    // --- Mode tracking ---
    property string currentMode: "default"

    Process {
        command: [root.wmMsg, "-t", "subscribe", "-m", '["mode"]']
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    var e = JSON.parse(data)
                    if (e.change !== undefined) root.currentMode = e.change
                } catch(err) {}
            }
        }
        onExited: running = true
    }

    // --- System stats ---
    // Two modes:
    //   1. daemonMode (Termux/proot, native Linux with daemon): one machine-wide
    //      qs-stats-daemon rewrites a state file atomically; every session's bar
    //      (local + xrdp concurrently) follows it with `tail -F`. Lines are
    //      `cpu N`, `ram N`, `disk N`, `bat N STATUS`, `net IFACE [SSID]`,
    //      `vol N MUTE`. One fork total, no polling timers.
    //   2. fallback: existing per-widget Process+Timer polling chain.
    // daemonMode is decided at startup by daemonProbe (a few retries so a
    // daemon that's still booting isn't mistaken for absent); the polling
    // chains are gated on !daemonMode to silence them when the daemon is up.
    readonly property string statsFile: "/tmp/qs-stats"
    readonly property string daemonFile: Quickshell.env("QS_STATS_FILE") || "/tmp/qs-stats.state"
    property bool daemonMode: false
    property bool daemonProbed: false
    property int daemonProbeTries: 0
    property string cpuVal:  "?"
    property string ramVal:  "?"
    property string diskVal: "?"
    property string netVal:  ""
    property string volVal:  ""
    property bool volMuted: false
    property string batVal:  ""
    property string batStatus: ""

    Process {
        id: daemonProbe
        running: true
        command: ["sh", "-c", "[ -s " + root.daemonFile + " ] && echo yes || echo no"]
        stdout: SplitParser {
            onRead: data => {
                if (data.trim() === "yes") {
                    root.daemonMode = true
                    root.daemonProbed = true
                } else if (root.daemonProbeTries < 5) {
                    root.daemonProbeTries++
                    daemonProbeRetry.restart()
                } else {
                    root.daemonProbed = true   // no daemon — polling fallback
                }
            }
        }
    }
    Timer { id: daemonProbeRetry; interval: 2000; onTriggered: daemonProbe.running = true }

    Process {
        id: feedProc
        running: root.daemonMode
        // -F follows across the daemon's atomic tmp+rename swaps and re-emits
        // the whole (complete-state) file each time; sets below are idempotent
        command: ["sh", "-c", "exec tail -n +1 -F " + root.daemonFile + " 2>/dev/null"]
        stdout: SplitParser {
            onRead: data => {
                var line = data.trim()
                var sp = line.indexOf(" ")
                if (sp < 0) return
                var key = line.substring(0, sp)
                var rest = line.substring(sp + 1)
                if (key === "cpu") {
                    root.cpuVal = rest + "%"
                } else if (key === "ram") {
                    root.ramVal = rest + "%"
                } else if (key === "disk") {
                    root.diskVal = rest + "%"
                } else if (key === "bat") {
                    var bs = rest.indexOf(" ")
                    if (bs < 0) { root.batVal = rest; root.batStatus = "" }
                    else { root.batVal = rest.substring(0, bs); root.batStatus = rest.substring(bs + 1) }
                } else if (key === "net") {
                    root.netVal = (rest === "none") ? "" : rest
                } else if (key === "vol") {
                    var vs = rest.indexOf(" ")
                    if (vs < 0) { root.volVal = rest; root.volMuted = false }
                    else {
                        root.volVal = rest.substring(0, vs)
                        root.volMuted = (rest.substring(vs + 1).trim() === "yes")
                    }
                }
            }
        }
        onExited: { if (root.daemonMode) feedRestart.restart() }
    }
    Timer { id: feedRestart; interval: 2000; onTriggered: feedProc.running = root.daemonMode }

    Process {
        id: statsProc
        running: !root.daemonMode
        command: ["sh", "-c",
            "if [ -f " + root.statsFile + " ]; then cat " + root.statsFile + "; else " +
            "read _ a1 b1 c1 d1 e1 f1 g1 _ < /proc/stat; sleep 1; " +
            "read _ a2 b2 c2 d2 e2 f2 g2 _ < /proc/stat; " +
            "t1=$((a1+b1+c1+d1+e1+f1+g1)); t2=$((a2+b2+c2+d2+e2+f2+g2)); " +
            "dt=$((t2-t1)); di=$((d2-d1)); " +
            "echo $(( dt > 0 ? (dt-di)*100/dt : 0 )); " +
            "awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf \"%.0f\\n\", (t-a)/t*100}' /proc/meminfo; " +
            "df / | awk 'NR==2{gsub(/%/,\"\",$5); print $5}'; fi"]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: data => {
                var v = data.trim()
                if (lineNum === 0) root.cpuVal = v + "%"
                else if (lineNum === 1) root.ramVal = v + "%"
                else if (lineNum === 2) root.diskVal = v + "%"
                lineNum++
            }
        }
        onExited: { statsProc.stdout.lineNum = 0; if (!root.daemonMode) statsTimer.restart() }
    }
    Timer { id: statsTimer; interval: 3000; onTriggered: if (!root.daemonMode) statsProc.running = true }

    Process {
        id: netProc
        running: !root.daemonMode
        command: ["sh", "-c",
            "iwgetid -r 2>/dev/null && exit; ip -brief addr | awk '!/^lo /{if($2==\"UP\") print $1; exit}'"]
        stdout: SplitParser { onRead: data => root.netVal = data.trim() }
        onExited: { if (!root.daemonMode) netTimer.restart() }
    }
    Timer { id: netTimer; interval: 10000; onTriggered: if (!root.daemonMode) netProc.running = true }

    Process {
        id: volProc
        running: !root.daemonMode
        command: ["sh", "-c",
            "pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\\d+(?=%)' | head -1; " +
            "pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -oP '(yes|no)'"]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: data => {
                if (lineNum === 0) root.volVal = data.trim()
                else if (lineNum === 1) root.volMuted = (data.trim() === "yes")
                lineNum++
            }
        }
        onExited: { volProc.stdout.lineNum = 0; if (!root.daemonMode) volTimer.restart() }
    }
    Timer { id: volTimer; interval: 5000; onTriggered: if (!root.daemonMode) volProc.running = true }

    // Click-driven controls — kept regardless of mode. The daemon will pick
    // up the state change via pactl subscribe and emit a fresh `vol` line.
    Process { id: volToggleMute; command: ["pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle"]; onExited: { if (!root.daemonMode) volProc.running = true } }
    Process { id: volUp; command: ["sh", "-c", "cur=$(pactl get-sink-volume @DEFAULT_SINK@ | grep -oP '\\d+(?=%)' | head -1); [ \"$cur\" -lt 100 ] && pactl set-sink-volume @DEFAULT_SINK@ +5%"]; onExited: { if (!root.daemonMode) volProc.running = true } }
    Process { id: volDown; command: ["pactl", "set-sink-volume", "@DEFAULT_SINK@", "-5%"]; onExited: { if (!root.daemonMode) volProc.running = true } }

    Process {
        id: batProc
        running: !root.daemonMode
        command: ["sh", "-c",
            "cat /sys/class/power_supply/BAT0/capacity 2>/dev/null; cat /sys/class/power_supply/BAT0/status 2>/dev/null"]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: data => {
                if (lineNum === 0) root.batVal = data.trim()
                else if (lineNum === 1) root.batStatus = data.trim()
                lineNum++
            }
        }
        onExited: { batProc.stdout.lineNum = 0; if (!root.daemonMode) batTimer.restart() }
    }
    Timer { id: batTimer; interval: 10000; onTriggered: if (!root.daemonMode) batProc.running = true }

    // --- Keyboard layout (sway only — no per-input IPC on i3) ---
    // Track only real keyboards. Virtual keyboards (browsers, foot, etc.)
    // appear and disappear constantly and start with the default layout, so
    // taking the first input from get_inputs or reacting to every input event
    // makes the indicator flicker back to QWT unpredictably.
    property string kbdLayout: "us"

    function _setKbdFromName(name) {
        var s = (name || "").toLowerCase()
        root.kbdLayout = s.indexOf("dvorak") >= 0 ? "dvorak" : "us"
    }

    Process {
        id: kbdQueryProc
        running: root.isSway
        command: ["swaymsg", "-t", "get_inputs"]
        property string buf: ""
        stdout: SplitParser { onRead: data => { kbdQueryProc.buf += data } }
        onExited: {
            try {
                var arr = JSON.parse(kbdQueryProc.buf)
                for (var i = 0; i < arr.length; i++) {
                    var inp = arr[i]
                    if (inp.type === "keyboard" && inp.xkb_active_layout_name) {
                        root._setKbdFromName(inp.xkb_active_layout_name)
                        break
                    }
                }
            } catch(err) {}
            kbdQueryProc.buf = ""
        }
    }

    // Indicator owned by user click. xkb_layout events from sway fire on
    // every Shift press/release under WSLg/RDP — flickers — so we predict
    // locally instead of subscribing to xkb events.
    //
    // Absolute index (not `next`) + type:keyboard (not `*`) — under WSLg,
    // virtual keyboards spawn/despawn on focus changes and start at index 0,
    // so a `next` toggle on `*` would race the new keyboard and revert.
    Process { id: kbdApplyProc }
    function _applyKbdLayout() {
        // Under WSLg, sway's `xkb_switch_layout` flips its internal group
        // but clients don't re-render the keymap — they keep typing the
        // old layout. Replacing xkb_layout/xkb_variant outright forces sway
        // to emit a brand new keymap on wl_keyboard.keymap, which clients
        // do honor. The desired layout goes first so active index 0 (the
        // default on keymap regeneration) is the one we want. Both
        // entries remain `us` so sway-side keybinds keep working.
        //
        // The single-quoted argument is required because swaymsg's command
        // parser treats `,` as a chain separator unless the layout list is
        // double-quoted inside the command string.
        var variant = root.kbdLayout === "dvorak" ? "dvorak," : ",dvorak"
        var cmd =
            "swaymsg 'input type:keyboard xkb_layout \"us,us\"' && " +
            "swaymsg 'input type:keyboard xkb_variant \"" + variant + "\"'"
        kbdApplyProc.command = ["sh", "-c", cmd]
        kbdApplyProc.running = false
        kbdApplyProc.running = true
    }

    // Re-apply the user's chosen layout whenever a new keyboard appears.
    // Without this, focusing a Windows-host window spawns a fresh virtual
    // keyboard at layout 0, which becomes the active input source and
    // silently reverts the layout despite the indicator staying correct.
    Process {
        id: inputEventSub
        running: root.isSway
        command: ["swaymsg", "-t", "subscribe", "-m", '["input"]']
        stdout: SplitParser {
            onRead: data => {
                try {
                    var e = JSON.parse(data)
                    if (e.change === "added" && e.input && e.input.type === "keyboard") {
                        root._applyKbdLayout()
                    }
                } catch(err) {}
            }
        }
        onExited: running = true
    }

    // Window focus also resets layout under WSLg — new windows can pull a
    // fresh wlroots virtual keyboard at group 0 without firing an `input
    // added` event quickshell sees in time. Re-apply on every focus change.
    Process {
        id: windowEventSub
        running: root.isSway
        command: ["swaymsg", "-t", "subscribe", "-m", '["window"]']
        stdout: SplitParser {
            onRead: data => {
                try {
                    var e = JSON.parse(data)
                    if (e.change === "focus" || e.change === "new") {
                        root._applyKbdLayout()
                    }
                } catch(err) {}
            }
        }
        onExited: running = true
    }


    // Inset-pill background (X11 phone mode; invisible when inset is 0)
    Rectangle {
        visible: root.inset
        anchors.fill: parent
        anchors.leftMargin: root.insetSide
        anchors.rightMargin: root.insetSide
        anchors.topMargin: root.insetTop
        // Pill look only when inset from the sides; otherwise a flat top bar.
        radius: root.insetSide > 0 ? 12 : 0
        color: root.barColor
    }

    // --- Layout (using Row, not RowLayout — RowLayout leaks Text.color) ---
    Item {
        anchors.fill: parent
        anchors.leftMargin: root.inset ? root.insetSide + 10 : 0
        anchors.rightMargin: root.inset ? root.insetSide + 10 : 0
        anchors.topMargin: root.insetTop

        // Left: workspaces + mode
        Row {
            id: leftSide
            visible: root.currentMode === "default"
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; leftMargin: 8 }
            spacing: 0

            Repeater {
                model: root.sortedWorkspaces

                Rectangle {
                    required property var modelData
                    width: wsText.implicitWidth + 14
                    height: leftSide.height
                    // Focused tab uses the same highlight as the mod+d launcher
                    // input/selection (#152024, Overlay.qml).
                    color: modelData.urgent  ? "#cb4b16"
                         : modelData.focused ? "#152024"
                         : "transparent"

                    Text {
                        id: wsText
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 1
                        text: modelData.name
                        // Focused/urgent tab bright; other project tabs dimmed.
                        color: (modelData.focused || modelData.urgent) ? "#fdf6e3" : "#707880"
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize
                        font.bold: modelData.focused
                        renderType: root.nativeRender
                    }

                    Rectangle {
                        anchors { top: parent.top; left: parent.left; right: parent.right }
                        height: 2
                        color: modelData.focused                    ? "#16a085"
                             : (modelData.active && !modelData.focused) ? "#454948"
                             : "transparent"
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: I3.dispatch("workspace " + modelData.name)
                    }
                }
            }
        }

        // Mode-hint strip (name-pill + keyboard hints), extracted to the shared
        // ModeBar (sp018 / ft009). Same anchors + leftMargin as the old inline
        // overlay Row; the host keeps the mode-subscription Process above and
        // just feeds it root.currentMode.
        ModeBar {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; leftMargin: 8 }
            mode: root.currentMode
            fontSize: root.fontSize
        }

        // Notification ticker — between workspaces and bell/date
        Rectangle {
            id: tickerArea
            visible: root.currentMode === "default" && root.tickerActive
            anchors { left: leftSide.right; right: rightSide.left; verticalCenter: parent.verticalCenter; leftMargin: 8; rightMargin: 4 }
            clip: true
            height: parent.height
            z: -1
            color: "#152024"

            Text {
                id: tickerText
                text: root.notifText
                color: "#fdf6e3"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
                y: parent.height - height - 1
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    tickerAnim.stop()
                    root.tickerActive = false
                    root.dismissNotifSilent()
                }
            }

            NumberAnimation {
                id: tickerAnim
                target: tickerText
                property: "x"
                from: tickerArea.width
                to: -tickerText.implicitWidth
                duration: Math.max((tickerArea.width + tickerText.implicitWidth) * 12, 3000)
                onFinished: { root.tickerActive = false; root.tickerFinished() }
            }
        }

        // Right side: stats + bell + date
        Row {
            id: rightSide
            visible: root.currentMode === "default"
            anchors { right: parent.right; bottom: parent.bottom; bottomMargin: 1; rightMargin: 8 }
            spacing: 0

            // Stats (hidden during ticker)
            Text { visible: root.showNet && !root.tickerActive && root.netVal !== ""; text: "NET:"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: root.showNet && !root.tickerActive && root.netVal !== ""; text: root.netVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: root.showNet && !root.tickerActive && root.netVal !== ""; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // CPU hidden when daemon couldn't read /proc/stat (proot/Termux on
            // Android — values masked for unprivileged → cpuVal stays "?").
            Text { visible: root.showCpu && !root.tickerActive && root.cpuVal !== "?"; text: "CPU:"; color: parseInt(root.cpuVal) >= 90 ? "#cb4b16" : "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: root.showCpu && !root.tickerActive && root.cpuVal !== "?"; text: root.cpuVal; color: parseInt(root.cpuVal) >= 90 ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: root.showCpu && !root.tickerActive && root.cpuVal !== "?"; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { visible: root.showRam && !root.tickerActive && root.ramVal !== "?"; text: "RAM:"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: root.showRam && !root.tickerActive && root.ramVal !== "?"; text: root.ramVal; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: root.showRam && !root.tickerActive && root.ramVal !== "?"; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { visible: root.showDisk && !root.tickerActive && root.diskVal !== "?"; text: "HDD:"; color: parseInt(root.diskVal) >= 90 ? "#cb4b16" : "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: root.showDisk && !root.tickerActive && root.diskVal !== "?"; text: root.diskVal; color: parseInt(root.diskVal) >= 90 ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            Text { visible: !root.tickerActive && root.volVal !== ""; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Item {
                visible: !root.tickerActive && root.volVal !== ""
                width: volLabel.implicitWidth + volValue.implicitWidth
                height: parent.height
                Text { id: volLabel; text: (root.volMuted || root.volVal === "0") ? "" : "VOL:"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                Text { id: volValue; anchors.left: volLabel.right; text: (root.volMuted || root.volVal === "0") ? "MUTED" : root.volVal + "%"; color: (root.volMuted || root.volVal === "0") ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    onClicked: volToggleMute.running = true
                    onWheel: wheel => { if (wheel.angleDelta.y > 0) volUp.running = true; else volDown.running = true }
                }
            }

            Text { visible: !root.tickerActive && root.batVal !== ""; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive && root.batVal !== "" && root.batVal !== "100"; text: (root.batStatus === "Charging" ? "CHR:" : "BAT:"); color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive && root.batVal !== "" && root.batVal !== "100"; text: root.batVal + "%"; color: root.batStatus === "Discharging" && parseInt(root.batVal) <= 20 ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text { visible: !root.tickerActive && root.batVal === "100"; text: "CHARGED"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // Keyboard layout indicator (sway only). Click cycles us↔dvorak.
            Text { visible: root.isSway && !root.tickerActive; text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Item {
                visible: root.isSway && !root.tickerActive
                width: visible ? kbdLabel.implicitWidth + kbdValue.implicitWidth : 0
                height: parent.height
                Text { id: kbdLabel; text: "KBL:"; color: "#707880"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                Text { id: kbdValue; anchors.left: kbdLabel.right; text: root.kbdLayout === "dvorak" ? "DVK" : "QWT"; color: "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; renderType: root.nativeRender; anchors.verticalCenter: parent.verticalCenter }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.kbdLayout = root.kbdLayout === "dvorak" ? "us" : "dvorak"
                        root._applyKbdLayout()
                    }
                }
            }

            Text { text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // System tray (StatusNotifierItem / SNI). Legacy XEmbed apps
            // (nm-applet, pamac-tray) will not appear without an XEmbed→SNI
            // bridge like xembedsniproxy. Modern apps (Firefox, Telegram,
            // Element, Steam, KeePassXC, …) show up automatically.
            Repeater {
                model: SystemTray.items
                delegate: Item {
                    required property var modelData
                    visible: !root.tickerActive
                    width: visible ? 18 : 0
                    height: parent.height
                    Image {
                        anchors.centerIn: parent
                        width: 14; height: 14
                        sourceSize: Qt.size(14, 14)
                        source: modelData.icon
                        smooth: false
                    }
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        onClicked: mouse => {
                            if (mouse.button === Qt.LeftButton) modelData.activate(0, 0)
                            else if (mouse.button === Qt.MiddleButton) modelData.secondaryActivate(0, 0)
                        }
                    }
                }
            }

            Text {
                visible: !root.tickerActive && SystemTray.items.length > 0
                text: "  "
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
            }

            // Bell — always visible, click to replay ticker
            Item {
                width: bellIcon.width + (root.notifCount > 0 ? bellCount.implicitWidth + 4 : 0)
                height: parent.height
                Image {
                    id: bellIcon
                    width: 14; height: 14
                    anchors.verticalCenter: parent.verticalCenter
                    sourceSize: Qt.size(14, 14)
                    source: "data:image/svg+xml," + encodeURIComponent(
                        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="' + (root.hasCritical ? '#cb4b16' : root.notifCount > 0 ? '#fdf6e3' : '#707880') + '">' +
                        '<path d="M12 2C10.9 2 10 2.9 10 4V4.3C7.7 5.1 6 7.3 6 10V16L4 18V19H20V18L18 16V10C18 7.3 16.3 5.1 14 4.3V4C14 2.9 13.1 2 12 2ZM10 20C10 21.1 10.9 22 12 22S14 21.1 14 20H10Z"/>' +
                        '</svg>')
                }
                Text { id: bellCount; visible: root.notifCount > 0; anchors.left: bellIcon.right; anchors.verticalCenter: parent.verticalCenter; text: root.notifCount; color: root.hasCritical ? "#cb4b16" : "#fdf6e3"; font.family: root.fontFamily; font.pixelSize: root.fontSize; font.bold: true; renderType: root.nativeRender }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (root.tickerActive && root.notifCount === 0) {
                            tickerAnim.stop()
                            root.tickerActive = false
                        } else {
                            root.dismissNotif()
                        }
                    }
                }
            }

            Text { text: "  "; font.pixelSize: root.fontSize; renderType: root.nativeRender }

            // Date — sync to second/minute boundary so updates aren't delayed
            Text {
                id: clockText
                property bool showSeconds: false
                text: Qt.formatDateTime(new Date(), showSeconds ? "HH:mm:ss" : "HH:mm")
                color: "#707880"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
                function refresh() { text = Qt.formatDateTime(new Date(), showSeconds ? "HH:mm:ss" : "HH:mm") }
                Timer {
                    id: clockTimer
                    running: true; repeat: true
                    interval: clockText.showSeconds ? 1000 : 1000
                    onTriggered: {
                        clockText.refresh()
                        if (!clockText.showSeconds) {
                            var ms = 60000 - (Date.now() % 60000)
                            interval = ms < 1000 ? ms + 60000 : ms
                        }
                    }
                }
                MouseArea { anchors.fill: parent; onClicked: { parent.showSeconds = !parent.showSeconds; parent.refresh(); clockTimer.interval = 1000; clockTimer.restart() } }
            }
            Text { text: " "; font.pixelSize: root.fontSize; renderType: root.nativeRender }
            Text {
                text: Qt.formatDateTime(new Date(), "yyyy-MM-dd")
                color: "#fdf6e3"
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
                renderType: root.nativeRender
                Timer { interval: 60000; running: true; repeat: true; onTriggered: parent.text = Qt.formatDateTime(new Date(), "yyyy-MM-dd") }
            }
        }
    }
}
