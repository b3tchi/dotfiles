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

Item {
    id: root
    property string sourceUrl: ""

    // _crashCount tracks renderer terminations for the CURRENT sourceUrl
    // only — reset whenever a new frame arrives (a genuinely new URL), so a
    // crash on an old, already-superseded document can never poison the
    // next one. _failed flips permanently for this url once the one allowed
    // auto-reload also crashes; the Text fallback below is what makes
    // that state visible rather than a dead/blank window (task edge case:
    // "Engine crash (renderer OOM) -> renderProcessTerminated -> reload
    // once, else fallback text, never a dead window").
    //
    // The counter is ALSO reset by a load that then stays up — but only
    // after it has stayed up for stableTimer.interval, never on the
    // LoadSucceededStatus signal itself. That distinction is the whole of
    // dotfiles-f532: a renderer that OOMs *after* the page loads always
    // emits LoadSucceeded first, so resetting there made _crashCount
    // oscillate 0 -> 1 -> 0 forever, _failed unreachable, and the window an
    // endless reload loop (measured against a page that loads and then grows
    // ~640 MB of live JS: 10 terminations in 45 s with a fresh renderer pid
    // each time and no end in sight — 59 and climbing on the reviewer's rig
    // — fallback text never shown, and it resumed after a window restart
    // because preview-d restores the slot's last URL). Requiring the page
    // to survive a while before the crash budget is refunded keeps both
    // behaviours: a genuine one-off crash still gets its free reload and
    // then a clean slate, while a crash-on-a-timer trips the fallback on
    // the second termination and stops.
    readonly property int _stableMs: 10000
    property int _crashCount: 0
    property bool _failed: false

    onSourceUrlChanged: {
        stableTimer.stop()
        root._crashCount = 0
        root._failed = false
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
            console.warn("preview: web tier renderer terminated (status="
                + terminationStatus + " code=" + exitCode + ") url="
                + root.sourceUrl)
            // This load did not survive its probation, so it must not
            // refund the crash budget a moment from now (dotfiles-f532).
            stableTimer.stop()
            root._crashCount++
            if (root._crashCount <= 1) {
                // Deferred to the next event-loop turn rather than
                // reloading inline from inside the crash signal itself:
                // Qt WebEngine's own guidance is that the view may not
                // have finished tearing down the dead render process yet
                // when this signal fires, so an inline reload() call here
                // is unreliable. A 0-length single-shot timer is the
                // standard defer-to-next-turn idiom.
                reloadTimer.start()
            } else {
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
    // long earns its crash budget back (dotfiles-f532). Comfortably longer
    // than the measured OOM-after-load cycle (~4.5 s at the wrapper's 256 MB
    // ceiling, i.e. load + regrow + die) and far shorter than any session
    // where a second, unrelated crash would deserve its own free reload
    // (verified both ways: two terminations 4.5 s apart trip the fallback,
    // two SIGKILLs 10+ s apart each get their reload and recover).
    Timer {
        id: stableTimer
        interval: root._stableMs
        onTriggered: root._crashCount = 0
    }

    Text {
        anchors.centerIn: parent
        width: parent.width * 0.8
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: "#8b93a3"
        font.pixelSize: 16
        visible: root._failed
        text: "preview: web content crashed and did not recover after one reload\n" + root.sourceUrl
    }
}
