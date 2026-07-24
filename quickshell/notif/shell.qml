// quickshell/notif/shell.qml -- the single notification-service daemon
// (sp019 task 2, dotfiles-c5fd.2). Headless profile: NO Window/PanelWindow
// anywhere in this file -- it hosts the ONE NotificationServer for
// org.freedesktop.Notifications and is the ONLY intended appender to
// qs-notif-store.sh's append/state verbs (single-writer discipline --
// refinement delta 4, docs/notes/spec/sp019.md). Presentation stays in the
// bars (Task 4 rips the server out of config/shell.qml); this file never
// renders anything.
//
// Launched (Task 3) as `quickshell -p ~/.dotfiles/quickshell/notif` behind a
// user-level flock -- exactly one instance is ever the live bus owner
// regardless of how many sessions (local + xrdp, adr0004) are up. A second
// instance starting on the same bus simply never receives a Notify() call
// (the platform's own D-Bus name-singleton guarantee) -- see the
// owns-bus-name scenario in test-notif-daemon.sh.
//
// Contract with qs-notif-store.sh (Task 1, unmodified -- this file's only
// dependency):
//   append <epoch> <urgency> <app> <summary>   (BODY ON STDIN, never argv)
//   dismiss <id|latest>
//   state   <count> <critical:0|1> <seq> <epoch> <text>
//
// Owns the FIFO ${QS_NOTIF_FIFO:-$XDG_RUNTIME_DIR/qs-notif.cmd}, 0600,
// read line-wise for "dismiss <id|latest>" commands (malformed lines are
// ignored without crashing the reader).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

ShellRoot {
    id: root

    // ---------------------------------------------------------- configuration ---
    // QS_NOTIF_STORE_SCRIPT is a TEST-ONLY override (not part of the spec's
    // published contract vars) so test-notif-daemon.sh can point this daemon
    // at the WORKTREE's own copy of the script instead of whatever happens to
    // be linked at a real ~/.dotfiles clone. Production deployment (Task 3's
    // qs-start.sh) never sets it, so it always falls through to the real path.
    readonly property string storeScript: Quickshell.env("QS_NOTIF_STORE_SCRIPT")
        || (Quickshell.env("HOME") + "/.dotfiles/quickshell/qs-notif-store.sh")

    readonly property string fifoPath: {
        var override = Quickshell.env("QS_NOTIF_FIFO")
        if (override) return override
        var rt = Quickshell.env("XDG_RUNTIME_DIR")
        return rt ? (rt + "/qs-notif.cmd") : ""
    }

    // Mirrors qs-notif-store.sh's OWN store_dir() resolution exactly (Task 1
    // header) -- needed here only so the daemon can predict the store's next
    // filename at startup (see seqInitProc below), never to bypass the script.
    readonly property string storeDir: {
        var stateHome = Quickshell.env("XDG_STATE_HOME")
        if (stateHome) return stateHome + "/qs-notif"
        var home = Quickshell.env("HOME")
        return home ? (home + "/.local/state/qs-notif") : ""
    }

    // ---------------------------------------------------------- bookkeeping ---
    // Plain JS state, not reactive -- exists purely to correlate the store's
    // opaque filename ids with the D-Bus notification ids the live
    // NotificationServer tracks, so a FIFO "dismiss <storeId>" command can
    // find (and .dismiss()) the matching LIVE notification, if any.
    property var _storeIdByDbusId: ({})
    property var _dbusIdByStoreId: ({})
    property int _storeSeq: 0
    property int _lastSeq: 0
    property int _lastEpoch: 0
    property string _lastText: ""
    property var _jobQueue: []
    property bool _busy: false

    function _pad6(n) {
        var s = String(n)
        while (s.length < 6) s = "0" + s
        return s
    }

    function _urgencyStr(u) {
        if (u === NotificationUrgency.Critical) return "critical"
        if (u === NotificationUrgency.Low) return "low"
        return "normal"
    }

    // The exact ticker-text construction the bars have always used (today's
    // config/shell.qml onNotification handler, byte-for-byte): HTML-stripped,
    // newline-folded. Only this DERIVED text ever goes to the `state` verb --
    // the raw summary/body handed to `append` are never touched by it, so the
    // store's history keeps the notification's real markup byte-exact
    // (markup-folded-state-raw-store).
    function _tickerText(summary, body) {
        var text = (summary || "").replace(/\n/g, " ")
        var strippedBody = (body || "").replace(/\n/g, " ").replace(/<[^>]*>/g, "")
        if (strippedBody !== "") text += " — " + strippedBody
        return text
    }

    // The highest store id still correlated to a live/known notification.
    // Computed by scan (not a cached scalar) so a SECOND "dismiss latest" in a
    // row -- after the true latest was already removed -- still resolves to
    // whatever is now newest, rather than going stale after one dismissal.
    function _resolveLatestStoreId() {
        var keys = Object.keys(root._dbusIdByStoreId)
        if (keys.length === 0) return ""
        keys.sort()
        return keys[keys.length - 1]
    }

    function _findTracked(dbusId) {
        var vals = notifSrv.trackedNotifications.values
        for (var i = 0; i < vals.length; i++) {
            if (vals[i].id === dbusId) return vals[i]
        }
        return null
    }

    // count = the daemon's live TRACKED count (refinement delta 3): every
    // notification currently in trackedNotifications, dismissed or not.
    // Deliberately NOT the store's history size, and NOT the old per-bar
    // "pending until superseded by a newer arrival" scheme -- the daemon has
    // no ticker to defer against, so this is simply "how many are live right
    // now". This also makes burst-10-monotonic (10 arrivals, none dismissed,
    // final count 10) and the replace-id case (the platform's own
    // trackedNotifications never grows for a `notify-send -r` reusing an
    // existing id -- verified empirically; onNotification does not even
    // re-fire) trivially correct without any extra bookkeeping here.
    function _trackedSnapshot() {
        var vals = notifSrv.trackedNotifications.values
        var hasCritical = false
        for (var i = 0; i < vals.length; i++) {
            if (vals[i].urgency === NotificationUrgency.Critical) { hasCritical = true; break }
        }
        return { count: vals.length, critical: hasCritical ? 1 : 0 }
    }

    // ------------------------------------------------------------- settle tick ---
    // trackedNotifications.values does NOT update synchronously within the
    // same tick as `notification.tracked = true` or `.dismiss()` -- confirmed
    // empirically against the real quickshell binary (a bare read in the
    // onNotification handler observes the PRE-arrival count; a zero-interval
    // Timer afterward observes the correct post-arrival count). Every state
    // write that depends on the live count/critical snapshot goes through
    // this one settle tick first, so it never races the model under load --
    // the exact hazard the "no wall-clock/scheduler races" rule warns about.
    Timer {
        id: settleTimer
        interval: 0
        property var _cb: null
        onTriggered: { var cb = _cb; _cb = null; if (cb) cb() }
    }
    function _afterSettle(cb) {
        settleTimer._cb = cb
        settleTimer.restart()
    }

    // --------------------------------------------------------------- job queue ---
    // Every store-mutating action (append+state on a fresh arrival,
    // dismiss+state on a FIFO command, or a bare state refresh after a
    // natural close/expiry) is serialized through this queue so two events
    // can never invoke the store script concurrently FROM THIS PROCESS --
    // single-writer discipline extends to the daemon's own internal
    // ordering, not just cross-process safety. A burst of arrivals queues up
    // and drains one at a time; each append reads the CURRENT `_storeSeq` at
    // the moment it actually runs, so the assigned filenames stay strictly
    // monotonic regardless of arrival jitter.
    function _enqueue(job) {
        root._jobQueue.push(job)
        _pump()
    }
    function _pump() {
        if (root._busy || root._jobQueue.length === 0) return
        root._busy = true
        var job = root._jobQueue.shift()
        if (job.type === "notify") _runNotifyJob(job)
        else if (job.type === "dismiss") _runDismissJob(job)
        else if (job.type === "staterefresh") _runStateRefresh()
        else _finishJob()
    }
    function _finishJob() {
        root._busy = false
        _pump()
    }

    function _runNotifyJob(job) {
        root._storeSeq += 1
        var storeId = root._pad6(root._storeSeq) + ".notif"
        root._storeIdByDbusId[job.dbusId] = storeId
        root._dbusIdByStoreId[storeId] = job.dbusId
        root._lastSeq = job.dbusId
        root._lastEpoch = job.epoch
        root._lastText = job.text

        appendProc._pendingBody = job.body
        appendProc._onDone = function() {
            root._afterSettle(function() { _writeState(job.epoch, job.text) })
        }
        appendProc.command = [root.storeScript, "append", String(job.epoch), job.urgency, job.app, job.summary]
        appendProc.running = true
    }

    function _runDismissJob(job) {
        var targetStoreId = (job.arg === "latest") ? root._resolveLatestStoreId() : job.arg
        var dbusId = (targetStoreId !== "") ? root._dbusIdByStoreId[targetStoreId] : undefined

        dismissProc._onDone = function() {
            if (dbusId !== undefined) {
                var live = root._findTracked(dbusId)
                if (live) live.dismiss()
                delete root._dbusIdByStoreId[targetStoreId]
                delete root._storeIdByDbusId[dbusId]
            }
            root._afterSettle(function() {
                _writeState(root._lastEpoch, root._lastText)
            })
        }
        // The literal arg (including "latest") is passed straight through --
        // the STORE side resolves "latest" itself against the actual
        // directory, which is authoritative regardless of this daemon's own
        // (best-effort) live-notification correlation above.
        dismissProc.command = [root.storeScript, "dismiss", job.arg]
        dismissProc.running = true
    }

    function _runStateRefresh() {
        root._afterSettle(function() {
            _writeState(root._lastEpoch, root._lastText)
        })
    }

    // seq stays at whatever the last genuinely-new arrival's D-Bus id was --
    // dismiss/staterefresh writes never bump it, so a consumer that restarts
    // its ticker ONLY on a CHANGED seq (Task 4) correctly does not restart
    // for a mere dismiss or a replace-driven property update.
    function _writeState(epoch, text) {
        var snap = root._trackedSnapshot()
        stateProc._onDone = function() { _finishJob() }
        stateProc.command = [root.storeScript, "state",
            String(snap.count), String(snap.critical), String(root._lastSeq), String(epoch), text]
        stateProc.running = true
    }

    // ------------------------------------------------------------------ procs ---
    Process {
        id: appendProc
        stdinEnabled: true
        property var _onDone: null
        property string _pendingBody: ""
        onStarted: { write(_pendingBody); stdinEnabled = false }
        onExited: (code, status) => {
            stdinEnabled = true   // reset for the NEXT reused invocation
            var cb = _onDone; _onDone = null
            if (cb) cb(); else root._finishJob()
        }
    }
    Process {
        id: dismissProc
        property var _onDone: null
        onExited: (code, status) => {
            var cb = _onDone; _onDone = null
            if (cb) cb(); else root._finishJob()
        }
    }
    Process {
        id: stateProc
        property var _onDone: null
        onExited: (code, status) => {
            var cb = _onDone; _onDone = null
            if (cb) cb(); else root._finishJob()
        }
    }

    // ----------------------------------------------------- seq-continuation scan ---
    // Predicts the next store filename by replicating qs-notif-store.sh's OWN
    // store_write() algorithm (highest existing NNNNNN.notif + 1). Safe
    // because this daemon is the store's ONLY writer (single-writer
    // discipline) -- no other process ever appends concurrently, so this
    // local counter and the script's own directory-scan-based numbering never
    // drift apart.
    Process {
        id: seqInitProc
        command: ["sh", "-c",
            "D=\"$1\"; ls -1 \"$D\" 2>/dev/null | grep -E '^[0-9]{6}\\.notif$' | sort | tail -1",
            "_", root.storeDir]
        stdout: SplitParser {
            onRead: data => {
                var t = data.trim()
                if (/^[0-9]{6}\.notif$/.test(t)) root._storeSeq = parseInt(t.substring(0, 6), 10)
            }
        }
        onExited: (code, status) => { readyProc.running = true }
    }
    // Touches a ready marker once startup bookkeeping (the seq scan above)
    // has completed, so a test harness can poll for it deterministically
    // instead of guessing how long QML/D-Bus startup takes. QS_NOTIF_READY_FILE
    // is test-only, like QS_NOTIF_STORE_SCRIPT; production never sets it and
    // this Process becomes a harmless no-op.
    Process {
        id: readyProc
        command: ["sh", "-c", "[ -n \"$1\" ] && : > \"$1\" || true", "_", Quickshell.env("QS_NOTIF_READY_FILE") || ""]
    }

    // ------------------------------------------------------------- FIFO reader ---
    // Owns ${QS_NOTIF_FIFO:-$XDG_RUNTIME_DIR/qs-notif.cmd}: created 0600, read
    // line-wise. `timeout 2` bounds each `cat` invocation so an externally
    // deleted FIFO is noticed and recreated within ~2s worst case -- verified
    // empirically that a bare `cat` blocked on an unlinked-but-still-open
    // FIFO inode never notices the deletion on its own; only a bounded
    // timeout forces the reconnect-and-recreate cycle. onExited is a pure
    // safety net (the shell loop is normally infinite -- `while :; do ...
    // done` never falls through on its own); fifoRestartTimer just avoids a
    // tight respawn loop in the unlikely case the shell itself dies.
    Process {
        id: fifoReader
        running: root.fifoPath !== ""
        command: ["sh", "-c",
            "FIFO=\"$1\"; while :; do " +
            "[ -p \"$FIFO\" ] || { rm -f \"$FIFO\" 2>/dev/null; mkfifo -m 0600 \"$FIFO\" 2>/dev/null; }; " +
            "timeout 2 cat \"$FIFO\"; " +
            "done",
            "_", root.fifoPath]
        stdout: SplitParser {
            onRead: data => root._handleFifoLine(data)
        }
        onExited: fifoRestartTimer.restart()
    }
    Timer {
        id: fifoRestartTimer
        interval: 500
        onTriggered: fifoReader.running = (root.fifoPath !== "")
    }

    // Malformed lines (wrong verb, missing/extra fields, a non-shape-matching
    // id) are ignored silently -- the reader loop is never crashed by bad
    // input, it just drops the line and keeps reading.
    function _handleFifoLine(line) {
        var trimmed = (line || "").trim()
        if (trimmed === "") return
        var parts = trimmed.split(/\s+/)
        if (parts.length !== 2 || parts[0] !== "dismiss") return
        var arg = parts[1]
        // Shape-check BEFORE any use, mirroring the store script's own
        // discipline -- an id is an opaque string, checked for shape only.
        if (arg !== "latest" && !/^[0-9]{6}\.notif$/.test(arg)) return
        root._enqueue({ type: "dismiss", arg: arg })
    }

    // --------------------------------------------------------------- the server ---
    // Flags replicate today's config/shell.qml server byte-for-byte (AC1/AC4
    // posture) -- this IS the single owner of org.freedesktop.Notifications;
    // no bar/overlay instance may ever host one again ([[adr0012]]). No
    // Window/PanelWindow anywhere in this file -- headless service only.
    NotificationServer {
        id: notifSrv
        keepOnReload: true
        bodyMarkupSupported: true
        imageSupported: false
        actionsSupported: false
        persistenceSupported: false

        onNotification: notification => {
            notification.tracked = true

            var dbusId = notification.id
            var epoch = Math.floor(Date.now() / 1000)
            var urgency = root._urgencyStr(notification.urgency)
            var app = notification.appName || ""
            var summary = notification.summary || ""
            var body = notification.body || ""
            var text = root._tickerText(summary, body)

            notification.closed.connect(function(reason) {
                var sid = root._storeIdByDbusId[dbusId]
                if (sid !== undefined) {
                    delete root._storeIdByDbusId[dbusId]
                    delete root._dbusIdByStoreId[sid]
                }
                // The persistent store is NEVER touched here -- a natural
                // expiry/close is not a history-deletion event; only an
                // explicit FIFO `dismiss` command removes a store entry.
                root._enqueue({ type: "staterefresh" })
            })

            root._enqueue({
                type: "notify",
                epoch: epoch, urgency: urgency, app: app,
                summary: summary, body: body, text: text, dbusId: dbusId
            })
        }
    }

    Component.onCompleted: {
        if (root.storeDir !== "") seqInitProc.running = true
        else readyProc.running = true
    }
}
