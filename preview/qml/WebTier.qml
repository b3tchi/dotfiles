// WebTier.qml — sp022 Task 5: the lazy web tier for PreviewView.qml.
//
// Serves html|akm|stl frames through ONE WebEngineView, all three routed
// by URL alone (PreviewView.qml's webUrlFor computes the right one per
// type — see that file):
//   html -> /file/<path>?native      (raw file, served verbatim)
//   stl  -> /file/<path>             (kept orbit-viewer page +
//                                      /static/stl-viewer.js)
//   akm  -> /file/<path>?slot=<N>    (kept cross-origin iframe embed of
//                                      akm-graph-d — adr0009 narrowed
//                                      form: peers embed inside the web
//                                      tier only. The iframe's own page
//                                      carries the adr0007 reverse channel
//                                      and sp011 highlight flow; this file
//                                      never reaches into that iframe —
//                                      ft004 is consumed strictly through
//                                      its existing HTTP/WS surface, not
//                                      re-implemented here.)
//
// `import QtWebEngine` lives ONLY in this file, never in PreviewView.qml
// — that is the entire point of Task 5. poc018 proved the module
// tolerates arriving at Loader-instantiation time (no top-level import
// anywhere in the app, no explicit QtWebEngineQuick::initialize() call):
// qml6 logged Loader.status=1 (Ready) and WebEngineView
// loadStatus=2 (LoadSucceededStatus) with this exact shape. The ~240 MiB
// engine cost (poc018, deduped child-walk PSS over the qml6 process and
// its descendants) is paid exactly once, at whatever moment
// PreviewView.qml's webLoader.sourceComponent is first assigned — see
// that file's "stays warm" Loader comment for why a native<->web sweep
// does not pay this cost twice.
//
// Switching type WITHIN the web tier (html -> akm -> stl and back) is a
// plain WebEngineView.url navigation once this item exists — never a new
// engine, never a new process. sourceUrl is a live binding in the caller
// (PreviewView.qml's webDelegate Component), so this file has no swap
// logic of its own beyond reacting to that one property changing.
//
// MEMORY, and why there is deliberately no history/lifecycle handling here
// (dotfiles-j5kq / sp022 T10 — full numbers in preview/README.md's
// "Web-tier memory ceiling"): one long-lived view means one long-lived
// renderer process, and each akm navigation leaves ~40 MB of dead JS that V8
// keeps until its own old-space limit. The filed suspicion was retained
// navigation history / back-forward cache, i.e. something this file would
// have to clear per navigation. It is not: across 60 same-URL cycles the
// browser process (which owns the navigation-entry store) stayed flat at
// ~176 MB while the renderer went 136 MB -> 1266 MB, all of it in V8's own
// pools — and capping V8's heap alone flattens the whole curve. So the fix
// lives in the nu wrapper's QTWEBENGINE_CHROMIUM_FLAGS
// (--js-flags=--max-old-space-size), NOT here: no history.clear() (would
// break Back/Forward for nothing), no lifecycleState=Discarded (would
// recycle the renderer process and break sp022's stable-engine-identity
// requirement), no view recreation (would re-pay the ~240 MiB engine cost).

import QtQuick
import QtWebEngine
import "CrashPolicy.js" as CrashPolicy

Item {
    id: root
    property string sourceUrl: ""

    // WHAT HAPPENS WHEN THE RENDERER DIES lives in CrashPolicy.js — a pure
    // reducer over (terminated / probation-elapsed / new-url) events, so the
    // decision is table-testable without a renderer, a display, or a 20 s
    // wait (preview-test test 33). Read that file for the measured
    // termination-status table, the three budgets, and where the line
    // between "still recovers" and "gives up" sits. This file only wires the
    // Qt signals to it and owns the two timers, because timers are the part
    // that cannot be pure.
    //
    // The short version: state is per-URL and cleared on a genuinely new
    // sourceUrl (a crash on a superseded document can never poison the next
    // one). sp022 T10's one free reload is refunded only after a load has
    // STOOD for _stableMs, never on the LoadSucceededStatus signal itself —
    // an OOM *after* load always follows a LoadSucceeded, so refunding there
    // made the guard loop forever (dotfiles-f532). On top of that, a
    // self-inflicted OOM (Chromium's own KilledTerminationStatus, measured
    // as status=3 code=5 — an external SIGKILL is status=2 code=9) is never
    // refunded at all, which is what stops the SLOW loop that survived T10:
    // a page that idles past probation and only then exhausts the heap got
    // its budget back before every OOM and ran at ~1 termination per 18 s
    // indefinitely.
    readonly property int _stableMs: 10000
    property var _policy: CrashPolicy.newState()
    property bool _failed: false
    property string _failReason: ""

    onSourceUrlChanged: {
        stableTimer.stop()
        reloadTimer.stop()
        root._policy = CrashPolicy.newState()
        root._failed = false
        root._failReason = ""
    }

    WebEngineView {
        id: view
        anchors.fill: parent
        url: root.sourceUrl
        visible: !root._failed

        onLoadingChanged: (loadInfo) => {
            if (loadInfo.status === WebEngineView.LoadSucceededStatus) {
                // Arm, don't refund: the budget comes back only if this
                // load is still standing _stableMs later (see above).
                stableTimer.restart()
            }
        }

        // terminationStatus/exitCode come from WebEngineView's own
        // signal signature (Qt WebEngine API) — logged so a real crash
        // is visible in wv-<N>.log (the QT_FORCE_STDERR_LOGGING path the
        // nu wrapper sets, per PreviewView.qml's file header) rather than
        // only inferred from the fallback text appearing.
        onRenderProcessTerminated: (terminationStatus, exitCode) => {
            // This load did not survive its probation, so it must not
            // refund the crash budget a moment from now (dotfiles-f532).
            stableTimer.stop()
            const decision = CrashPolicy.onTerminated(
                root._policy, terminationStatus, exitCode)
            root._policy = decision.state
            console.warn("preview: web tier renderer terminated (status="
                + terminationStatus + " code=" + exitCode + ") "
                + decision.action
                + (decision.action === "reload"
                    ? " in " + decision.delayMs + "ms"
                    : " (" + decision.reason + ")")
                + " transient=" + decision.state.transient
                + " oom=" + decision.state.oom
                + " lifetime=" + decision.state.lifetime
                + " url=" + root.sourceUrl)
            if (decision.action === "reload") {
                // Deferred to a timer rather than reloading inline from
                // inside the crash signal itself: Qt WebEngine's own
                // guidance is that the view may not have finished tearing
                // down the dead render process yet when this signal fires,
                // so an inline reload() call here is unreliable. A
                // 0-length single-shot timer is the standard
                // defer-to-next-turn idiom, and a longer one is the policy's
                // backoff.
                reloadTimer.interval = decision.delayMs
                reloadTimer.restart()
            } else {
                root._failReason = decision.reason
                root._failed = true
            }
        }
    }

    Timer {
        id: reloadTimer
        interval: 0
        onTriggered: view.reload()
    }

    // Probation for the current load: only a page that has been up this
    // long earns its TRANSIENT crash budget back (dotfiles-f532; the OOM and
    // lifetime budgets are never refunded — see CrashPolicy.js). Comfortably
    // longer than the measured OOM-after-load cycle (~4.5 s at the wrapper's
    // 256 MB ceiling, i.e. load + regrow + die) and far shorter than any
    // session where a second, unrelated crash would deserve its own free
    // reload (verified both ways: two terminations 4.5 s apart trip the
    // fallback, four SIGKILLs 14 s apart each get their reload and recover).
    Timer {
        id: stableTimer
        interval: root._stableMs
        onTriggered: root._policy = CrashPolicy.onProbationElapsed(root._policy)
    }

    Text {
        anchors.centerIn: parent
        width: parent.width * 0.8
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: "#8b93a3"
        font.pixelSize: 16
        visible: root._failed
        text: CrashPolicy.failText(root._failReason, root.sourceUrl)
    }
}
