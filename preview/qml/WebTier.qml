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

import QtQuick
import QtWebEngine

Item {
    id: root
    property string sourceUrl: ""

    // _crashCount tracks renderer terminations for the CURRENT sourceUrl
    // only — reset whenever a new frame arrives (a genuinely new URL) or
    // the current one finishes loading successfully, so a crash on an
    // old, already-superseded document can never poison the next one.
    // _failed flips permanently for this url once the one allowed
    // auto-reload also crashes; the Text fallback below is what makes
    // that state visible rather than a dead/blank window (task edge case:
    // "Engine crash (renderer OOM) -> renderProcessTerminated -> reload
    // once, else fallback text, never a dead window").
    property int _crashCount: 0
    property bool _failed: false

    onSourceUrlChanged: {
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
                root._crashCount = 0
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
