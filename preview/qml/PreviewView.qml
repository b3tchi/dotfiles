// PreviewView.qml — sp022 Task 4: the native Qt Quick client for ft005's
// preview-d daemon. One process per /preview<N> slot: connects the slot's
// websocket, applies the priming frame, and hot-swaps a Loader delegate on
// every {path, type} frame the daemon broadcasts — no process respawn, no
// engine reload, which is the epic's hard requirement (## problem: a cursor
// move across a content-type boundary swaps content inside ONE window).
//
// Native tiers: image, svg, md, code, video, none. html|akm|stl fall back
// to plain text here until Task 5 adds the lazy WebEngineView tier
// (WebTier.qml) — this file must never `import QtWebEngine` itself; that
// import is Task 5's job specifically so its ~240 MiB cost is paid only
// once a web-tier frame actually arrives (poc018).
//
// Launched by the `preview` nu wrapper (Task 6):
//   qml6 PreviewView.qml -- <slot> <port>
// The wrapper sets QT_FORCE_STDERR_LOGGING=1 (d2-view precedent) so
// console.log/warn/error actually reach wv-<N>.log — QML swallows them
// otherwise.
//
// Pan/zoom (image + svg tiers) is modeled on d2-view/BoardView.qml: an
// Image inside a draggable/wheel-zoomable Item, sourceSize rasterised at
// the on-screen pixel size and clamped to 8192, natural size read back from
// the loaded Image once Ready (BoardView instead pre-parses each svg's
// viewBox because it needs sizes before any Image exists, for its board
// list; PreviewView has exactly one image at a time, so it can just wait
// for Image.Ready and re-fit once).
//
// svg live-reload (the .d2 tier) takes BoardView's 1s poll / byte-length
// compare / cache-busting token bump and re-points it from file:// to an
// http GET. The poll SEMANTICS are BoardView's; the TRANSPORT is not, and
// the difference is load-bearing: BoardView issues a *synchronous* XHR,
// which is harmless against file:// (a local read that returns in
// microseconds) but fatal against this relay. preview-d's /file/…?native
// svg path proxies to the d2 router (preview/proxy.go d2SVGRelayTimeout =
// 5s, wrapping d2/router/api.go svgPollDeadline = 3s), so a single GET can
// legitimately block for seconds — and a sync XHR blocks the GUI thread
// while it does. Repeated every 1s that killed the process outright: an
// earlier revision of this file used sync XHR here and the client exited
// rc=0 (window gone) within 1-4s of an svg frame, ~1 time in 3, measured
// 4/12 over two content variants with image/video controls at 0/10.
// Both svg-tier requests are therefore ASYNCHRONOUS, which measured 0
// deaths. Async introduces an out-of-order-response race that the sync
// version could not have, so the poll carries a last-wins url guard — the
// same guard NativeTextView.load() already uses below.

import QtQuick
import QtQuick.Controls
import QtWebSockets

// ---- main window -------------------------------------------------------------

ApplicationWindow {
    id: win
    width: 1280
    height: 860
    color: "#14161d"
    title: argsOk ? "preview " + slotN : "preview"
    visible: argsOk

    property bool argsOk: false
    property int slotN: -1
    property string daemonPort: ""
    property string currentPath: ""
    property string currentType: "none"

    // ---- reusable pan/zoom stage (image + svg tiers) ---------------------------
    // Self-contained: never reaches into the window's ids, only its own
    // declared properties, so both the image and svg delegates below can
    // instantiate it with just an imgUrl. Nested inside the window body
    // (rather than declared at file scope, before/after the root object)
    // because this Qt 6.11 `qml` runtime's parser only accepts the
    // `component Name: Type {}` inline-component form there, not as a
    // top-level sibling of the root object — verified empirically (a
    // file-scope declaration throws a syntax error at the "component" token
    // on this build; the identical declaration nested inside the root loads
    // fine).
    component PannableStage: Item {
        id: stage
        property string imgUrl: ""
        property real natW: 0
        property real natH: 0
        property real zoom: 1
        // fixedNatW/H: when the caller already knows the natural size (the svg
        // delegate parses it from the document's own viewBox — see below), set
        // these and PannableStage NEVER re-derives natW/natH from the Image's
        // own implicitWidth/Height. This matters because svg has no fixed
        // intrinsic pixel size the way a raster image does: Qt's svg image
        // plugin reports implicitWidth/Height as whatever sourceSize was last
        // REQUESTED, so tying sourceSize to a width that is itself derived from
        // implicitWidth creates a live feedback loop — verified: Qt logs
        // "Binding loop detected for property sourceSize.width" and the
        // dimensions oscillate (371 -> 1 -> 482 -> 770 -> 1230 ...) instead of
        // ever settling. A raster image has a real fixed pixel size regardless
        // of what sourceSize asks for, so implicitWidth-driven sync (the
        // fixedNatW/H unset path below) is safe there.
        property real fixedNatW: 0
        property real fixedNatH: 0
        clip: true

        Component.onCompleted: {
            if (fixedNatW > 0 && fixedNatH > 0) {
                natW = fixedNatW
                natH = fixedNatH
                fitStage()
            }
        }
        onFixedNatWChanged: if (fixedNatW > 0 && fixedNatH > 0) { natW = fixedNatW; natH = fixedNatH; fitStage() }
        onFixedNatHChanged: if (fixedNatW > 0 && fixedNatH > 0) { natW = fixedNatW; natH = fixedNatH; fitStage() }

        function apply(k, x, y) {
            zoom = Math.max(0.02, Math.min(16, k))
            content.x = x
            content.y = y
        }
        function fitStage() {
            if (natW <= 0 || natH <= 0 || stage.width <= 0 || stage.height <= 0) return
            var k = Math.min(stage.width / natW, stage.height / natH) * 0.97
            apply(k, (stage.width - natW * k) / 2, (stage.height - natH * k) / 2)
        }
        function actualSize() {
            if (natW <= 0) return
            apply(1, (stage.width - natW) / 2, (stage.height - natH) / 2)
        }
        function zoomAt(factor, cx, cy) {
            if (natW <= 0) return
            var k = Math.max(0.02, Math.min(16, zoom * factor))
            apply(k, cx - (cx - content.x) * (k / zoom), cy - (cy - content.y) * (k / zoom))
        }

        onWidthChanged: fitStage()
        onHeightChanged: fitStage()

        Item {
            id: content
            width: stage.natW * stage.zoom
            height: stage.natH * stage.zoom

            Image {
                id: img
                anchors.fill: parent
                source: stage.imgUrl
                asynchronous: true
                smooth: true
                cache: false
                fillMode: Image.Stretch
                // Rasterise at the on-screen pixel size, clamped to 8192 (the
                // BoardView precedent — sp022 Task 4 edge case: "Image larger
                // than 8192px -> sourceSize clamp") so a large diagram or photo
                // stays crisp at zoom without ever decoding past a sane cap.
                //
                // Bootstrap chicken-and-egg: `width` (via anchors.fill: content)
                // is itself derived from stage.natW, which is only known AFTER
                // this very Image reports its implicit size — so sourceSize
                // can't key off `width` until natW is set at least once.
                // Before that, 0 means "no override" (Qt reverts to the
                // source's own default/intrinsic size) — for a raster image
                // that's its true pixel size regardless of what's requested;
                // for an intrinsically-scalable source (svg) it's the size the
                // document itself declares. Keying the fallback off the
                // stage's on-screen size instead (an earlier attempt) breaks
                // svg specifically: an svg has no fixed pixel size, so
                // implicitWidth just echoes back whatever sourceSize was
                // requested — if the window was unmapped/zero-sized at first
                // load (verified live: a tabbed-container hidden window),
                // natW/natH latch onto that tiny size forever. 0 sidesteps the
                // whole race. Once natW is known, switch to the precise
                // on-screen size for crisp zoom.
                sourceSize.width: stage.natW > 0
                    ? Math.min(8192, Math.max(1, Math.round(width)))
                    : 0
                sourceSize.height: stage.natH > 0
                    ? Math.min(8192, Math.max(1, Math.round(height)))
                    : 0
                // implicitWidth/Height (the source's true natural size for a
                // RASTER image) are driven by their own binding independent of
                // the status signal — reading them synchronously inside
                // onStatusChanged can race and see a stale 0 (verified live:
                // status===Ready fired with implicitWidth/Height still 0), so
                // natural size is captured here instead, on the properties
                // that actually carry it. Never runs when the caller supplied
                // fixedNatW/H (the svg path) — implicitWidth/Height are not a
                // stable signal there (see the fixedNatW/H comment above).
                function syncNaturalSize() {
                    if (stage.fixedNatW > 0 && stage.fixedNatH > 0) return
                    if (implicitWidth > 0 && implicitHeight > 0
                            && (implicitWidth !== stage.natW || implicitHeight !== stage.natH)) {
                        stage.natW = implicitWidth
                        stage.natH = implicitHeight
                        stage.fitStage()
                    }
                }
                onImplicitWidthChanged: syncNaturalSize()
                onImplicitHeightChanged: syncNaturalSize()
            }
        }

        DragHandler { target: content }

        WheelHandler {
            acceptedModifiers: Qt.NoModifier
            onWheel: (ev) => stage.zoomAt(Math.exp(ev.angleDelta.y * 0.0016), ev.x, ev.y)
        }

        TapHandler { onDoubleTapped: stage.actualSize() }

        Shortcut { sequence: "0"; onActivated: stage.actualSize() }
        Shortcut { sequence: "f"; onActivated: stage.fitStage() }
    }

    // ---- reusable native-text view (md + code tiers) ---------------------------
    // Fetches sourceUrl's bytes via XHR and paints them as MarkdownText (md) or
    // RichText (code, monospace). Guards against out-of-order responses — a
    // later sourceUrl change firing before an earlier request completes — by
    // checking the URL is still current when the response lands, so a rapid
    // path1 -> path2 swap can never have path1's slow response overwrite
    // path2's already-applied text (sp022 Task 4 edge case: "last-wins, no
    // stacking" applied to text frames the same way the Loader swap gives it
    // to whole-delegate frames).
    component NativeTextView: Item {
        id: view
        property string sourceUrl: ""
        property bool rich: false
        property string _loadedUrl: ""

        Flickable {
            id: flick
            anchors.fill: parent
            contentWidth: width
            contentHeight: Math.max(height, txt.implicitHeight + 24)
            clip: true
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Text {
                id: txt
                x: 12
                y: 12
                width: flick.width - 24
                wrapMode: Text.Wrap
                textFormat: view.rich ? Text.RichText : Text.MarkdownText
                color: "#e7e9ee"
                font.family: view.rich ? "monospace" : "sans-serif"
                font.pixelSize: 14
                text: "loading…"
            }
        }

        function load() {
            if (view.sourceUrl === "") return
            if (view.sourceUrl === view._loadedUrl) return // idempotent: already showing this
            var url = view.sourceUrl
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                // view is destroyed (Loader swapped delegates) before this
                // response arrived -> nothing left to update, and touching a
                // destroyed QML object throws (sp022 Task 4 edge case: a
                // superseded in-flight request must never crash).
                if (view === null || url !== view.sourceUrl) return
                if (xhr.status === 200) {
                    txt.text = xhr.responseText
                } else {
                    txt.text = "preview: failed to load (" + xhr.status + ")"
                }
                view._loadedUrl = url
            }
            xhr.open("GET", url)
            xhr.send()
        }

        onSourceUrlChanged: load()
        Component.onCompleted: load()
    }

    // CLI: qml6 PreviewView.qml -- <slot> <port>. Filter mirrors
    // d2-view/BoardView.qml's argv filter: drop the runtime's own argv[0],
    // any argument that IS the .qml file path, and the "--" separator qml6
    // inserts before the script's own arguments. Bad args (N non-numeric,
    // port missing/non-numeric) print a usage line to stderr and exit
    // nonzero — no window, no stack trace (sp022 Task 4 success criteria).
    function parseArgs() {
        var argv = Qt.application.arguments.filter(
            (a, i) => i > 0 && !a.endsWith(".qml") && a !== "--")
        var nStr = argv.length > 0 ? argv[0] : ""
        var portStr = argv.length > 1 ? argv[1] : ""
        if (!/^\d+$/.test(nStr) || !/^\d+$/.test(portStr)) {
            console.error("usage: qml6 PreviewView.qml -- <slot-number> <port>")
            Qt.exit(2)
            return false
        }
        slotN = parseInt(nStr, 10)
        daemonPort = portStr
        return true
    }

    function fileUrl(path) {
        var encoded = String(path).split("/").map(encodeURIComponent).join("/")
        return "http://127.0.0.1:" + win.daemonPort + "/file/" + encoded
    }

    // fallbackMessage covers three edge cases at once: no path ever set
    // yet (empty window state), a classified "none" (unrenderable) file,
    // and the not-yet-implemented web tier (html|akm|stl route here until
    // Task 5) — plus any future type string this client doesn't recognise,
    // which must degrade here rather than crash (sp022 Task 4 edge case).
    function fallbackMessage() {
        if (win.currentPath === "") return "preview " + win.slotN + " — waiting for a file…"
        switch (win.currentType) {
        case "html":
        case "akm":
        case "stl":
            return "content type \"" + win.currentType + "\" — web tier not wired up yet\n" + win.currentPath
        case "none":
            return "no preview available for\n" + win.currentPath
        default:
            return "unsupported preview type \"" + win.currentType + "\"\n" + win.currentPath
        }
    }

    // ---- websocket client: connect, prime, hot-swap, reconnect w/ backoff --
    //
    // Priming is server-owned: handlePreviewWS (server.go) sends the slot's
    // current {path, type} immediately on every successful upgrade,
    // including a reconnect after a daemon restart — so this client's only
    // job is to keep reconnecting with backoff and apply whatever frame
    // arrives through the same handleWsMessage path the priming frame and
    // every live broadcast both use (shell app.js behavior preserved: the
    // process itself never exits on a connection loss).

    property int wsDelay: 1000
    readonly property int wsMaxDelay: 30000

    function applyFrame(rawPath, rawType) {
        win.currentPath = typeof rawPath === "string" ? rawPath : ""
        win.currentType = typeof rawType === "string" && rawType !== "" ? rawType : "none"
    }

    function handleWsMessage(message) {
        try {
            var msg = JSON.parse(message)
            win.applyFrame(msg.path, msg.type)
        } catch (e) {
            console.warn("preview: invalid ws payload")
        }
    }

    function scheduleReconnect() {
        if (reconnectTimer.running) return
        sock.active = false
        reconnectTimer.interval = win.wsDelay
        win.wsDelay = Math.min(win.wsDelay * 2, win.wsMaxDelay)
        reconnectTimer.start()
    }

    WebSocket {
        id: sock
        url: "ws://127.0.0.1:" + win.daemonPort + "/preview" + win.slotN
        active: false
        onStatusChanged: (status) => {
            if (status === WebSocket.Open) {
                win.wsDelay = 1000
            } else if (status === WebSocket.Closed || status === WebSocket.Error) {
                win.scheduleReconnect()
            }
        }
        onTextMessageReceived: (message) => win.handleWsMessage(message)
    }

    Timer {
        id: reconnectTimer
        repeat: false
        onTriggered: sock.active = true
    }

    Component.onCompleted: {
        if (!parseArgs()) return
        argsOk = true
        sock.active = true
    }

    // ---- delegates -------------------------------------------------------

    Component {
        id: imageDelegate
        PannableStage { imgUrl: win.fileUrl(win.currentPath) + "?full" }
    }

    Component {
        id: svgDelegate
        Item {
            // Explicit id rather than `parent` for the self-references
            // below. The non-visual Timer at the bottom is not an Item, so
            // it has no `parent` property of its own; a bare `parent` there
            // resolves up the scope chain to THIS Item's parent (the
            // Loader), not to this Item. Naming the object removes the
            // ambiguity for readers and for the QML resolver alike.
            id: svgTier
            property string baseUrl: win.fileUrl(win.currentPath) + "?native"
            property int reloadToken: 0
            property int lastLen: -1
            // The svg's natural size, pre-parsed from its own viewBox
            // BEFORE ever handing the URL to PannableStage's Image — the
            // BoardView precedent (BoardView.qml's readSize), required
            // here because letting Image.implicitWidth/Height drive
            // natural size (as the plain image tier safely does) creates a
            // live feedback loop for svg specifically: verified live, Qt
            // logs "Binding loop detected for property sourceSize.width"
            // and the reported size oscillates instead of settling, since
            // an svg has no fixed intrinsic pixel size — implicitWidth
            // just echoes back whatever sourceSize was last requested.
            property real natW: 0
            property real natH: 0
            // _pendingUrl is the url of the single in-flight GET, "" when
            // idle. It is the anti-pile-up guard the sync version got for
            // free: an async 1s poll against a relay that can take up to 5s
            // would otherwise stack five concurrent requests per slow
            // response. natW/natH are deliberately NOT reset when baseUrl
            // changes — the stage keeps rendering the previous diagram's
            // fit for the few ms until the new document's viewBox lands,
            // rather than collapsing to a 0x0 (blank) content item.
            property string _pendingUrl: ""
            onBaseUrlChanged: { lastLen = -1; poll() }

            // Parses the w/h out of an svg's viewBox attribute (BoardView's
            // readSize regex, unchanged). Returns null when the document
            // has no parseable viewBox (malformed/empty svg) rather than a
            // 0x0 size that would make PannableStage divide by zero.
            function viewBoxSize(text) {
                var m = /viewBox="([\d.\s-]+)"/.exec(text || "")
                if (!m) return null
                var p = m[1].trim().split(/\s+/).map(Number)
                if (p.length < 4 || !(p[2] > 0) || !(p[3] > 0)) return null
                return { w: p[2], h: p[3] }
            }

            // One async GET serving both jobs: the first response for a url
            // establishes the viewBox-derived natural size, every later one
            // is the live-reload byte-length compare. ASYNC IS NOT
            // COSMETIC — see the transport note in the file header: the
            // synchronous form of this exact request killed the process on
            // roughly a third of svg frames, because /file/…?native relays
            // through the d2 router and can block the GUI thread for
            // seconds.
            function poll() {
                var url = svgTier.baseUrl
                if (url === "") return
                // Same url already in flight → let it land; polling again
                // would only queue duplicates behind a slow relay.
                if (svgTier._pendingUrl === url) return
                svgTier._pendingUrl = url
                var xhr = new XMLHttpRequest()
                xhr.onreadystatechange = function () {
                    if (xhr.readyState !== XMLHttpRequest.DONE) return
                    try {
                        // The Loader swapped this delegate away before the
                        // response arrived: nothing left to update, and
                        // touching a destroyed QML object throws.
                        if (svgTier === null) return
                        if (svgTier._pendingUrl === url) svgTier._pendingUrl = ""
                        // LAST-WINS: a newer frame has already moved baseUrl
                        // on (a different .d2 arrived in the same slot), so
                        // this stale body must not overwrite the newer
                        // document's size/length state. The sync version
                        // could not have this race; async can, so it is
                        // guarded exactly the way NativeTextView.load()
                        // guards its own text responses.
                        if (url !== svgTier.baseUrl) return
                        if (xhr.status !== 200) return
                        var text = xhr.responseText || ""
                        var len = text.length
                        var size = svgTier.viewBoxSize(text)
                        if (svgTier.lastLen === -1) {
                            // First response for this url: establish the
                            // natural size, no repaint token (the Image is
                            // already fetching v=0 on its own).
                            if (size) { svgTier.natW = size.w; svgTier.natH = size.h }
                        } else if (len !== svgTier.lastLen) {
                            // The watched .d2 recompiled: bump the
                            // cache-busting token so the Image refetches,
                            // and re-read the viewBox in case the board's
                            // own size shifted, so the fit recomputes and
                            // not just the pixels.
                            svgTier.reloadToken++
                            if (size) { svgTier.natW = size.w; svgTier.natH = size.h }
                        }
                        svgTier.lastLen = len
                    } catch (e) { /* delegate torn down mid-flight; nothing to do */ }
                }
                // Third argument omitted => async. Never pass `false` here.
                xhr.open("GET", url)
                xhr.send()
            }
            Component.onCompleted: poll()

            PannableStage {
                anchors.fill: parent
                imgUrl: svgTier.baseUrl + "&v=" + svgTier.reloadToken
                fixedNatW: svgTier.natW
                fixedNatH: svgTier.natH
            }

            // 1s poll of the watched .d2's compiled svg (sp022 Task 4
            // success criteria: "an edit to the watched .d2 repaints without
            // any window action").
            Timer {
                interval: 1000
                running: true
                repeat: true
                onTriggered: svgTier.poll()
            }
        }
    }

    Component {
        id: mdDelegate
        NativeTextView {
            rich: false
            sourceUrl: win.fileUrl(win.currentPath) + "?native"
        }
    }

    Component {
        id: codeDelegate
        NativeTextView {
            rich: true
            sourceUrl: win.fileUrl(win.currentPath) + "?native"
        }
    }

    Component {
        id: videoDelegate
        Item {
            Image {
                anchors.fill: parent
                source: win.fileUrl(win.currentPath)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
            }
        }
    }

    Component {
        id: fallbackDelegate
        Item {
            Text {
                anchors.centerIn: parent
                width: parent.width * 0.8
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: "#8b93a3"
                font.pixelSize: 16
                text: win.fallbackMessage()
            }
        }
    }

    // delegateFor is the single dispatch point from a classified type
    // string to a Loader component. Every branch not explicitly listed —
    // "none", the not-yet-native "html"/"akm"/"stl" web tier, and any
    // future type string this client has never seen — falls through to
    // fallbackDelegate rather than crashing (sp022 Task 4 edge case: "ws
    // frame with unknown future type string -> fallback delegate, not a
    // crash").
    function delegateFor(type) {
        switch (type) {
        case "image": return imageDelegate
        case "svg": return svgDelegate
        case "md": return mdDelegate
        case "code": return codeDelegate
        case "video": return videoDelegate
        default: return fallbackDelegate
        }
    }

    // The Loader itself is what makes hot-swapping ONE-window/no-respawn:
    // sourceComponent only re-evaluates (and only then destroys/recreates
    // the delegate item) when currentType actually changes; a same-type
    // frame with a different (or identical) path just updates the live
    // delegate's own url properties, never touching the Loader — so a
    // same-path re-broadcast is idempotent (no flicker loop) and a type
    // change is last-wins by construction (Loader never stacks two
    // delegates).
    Loader {
        id: tierLoader
        anchors.fill: parent
        sourceComponent: win.delegateFor(win.currentType)
    }
}
