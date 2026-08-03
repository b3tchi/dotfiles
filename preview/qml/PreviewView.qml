// PreviewView.qml — sp022 Task 4: the native Qt Quick client for ft005's
// preview-d daemon. One process per /preview<N> slot: connects the slot's
// websocket, applies the priming frame, and hot-swaps a Loader delegate on
// every {path, type} frame the daemon broadcasts — no process respawn, no
// engine reload, which is the epic's hard requirement (## problem: a cursor
// move across a content-type boundary swaps content inside ONE window).
//
// Native tiers: image, svg, md, code, video, none. html|akm|stl route to
// the lazy WebEngineView tier (WebTier.qml, Task 5) — this file must
// never `import QtWebEngine` itself; that import lives ONLY in
// WebTier.qml so its ~240 MiB cost (poc018, deduped child-walk PSS) is
// paid only once a web-tier frame actually arrives, and only once for the
// life of the process (see webLoader below: sourceComponent is assigned
// exactly once, at the first web frame, and never cleared — a later
// native visit hides it, it does not destroy it).
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
        // deferSource: hold the Image sourceless while the caller is still
        // deciding what fixedNatW/H will be. fixedNatW/H CANNOT carry that
        // themselves — they are 0 at delegate-creation time on the svg path
        // too (the viewBox has not been fetched yet), which is exactly the
        // window in which the unwanted full-resolution decode is issued, so
        // a `fixedNatW > 0` test is inert precisely when it is needed.
        // Measured that way round first: the gate changed nothing, 3 of 4
        // svg visits still logged the 728x7561 decode.
        property bool deferSource: false
        // fitted latches true the first time fitStage() actually computes a
        // fit — i.e. once natW/natH AND zoom AND the stage's own on-screen
        // size are all consistent. On the fixedNatW/H (svg) path the Image's
        // `source` is withheld until then, which is what bounds
        // dotfiles-63rd; see the source binding below for the measurement.
        // Deliberately NOT reset by later fitStage() calls: it is a
        // one-way bootstrap latch, not a "has been re-fitted" flag.
        property bool fitted: false
        // Zoom is a scale transform on an already-decoded pixmap; the decode
        // is refreshed on a debounce into whichever of two Images is hidden,
        // and they swap only once the new one is Ready.
        //
        // Before this, sourceSize was bound straight to the on-screen size:
        // every wheel tick changed it, Qt dropped the pixmap and re-decoded,
        // and the item painted EMPTY until the decode finished — one blank
        // frame per tick, seen as the viewer blinking while zooming. With
        // `cache: false` (kept — see the retention note on `source`) even
        // returning to a previous zoom re-decoded.
        //
        // rasterScale is in diagram pixels per source pixel; 0 means "no
        // override", the bootstrap request a raster tier needs to learn its
        // own natural size.
        property real rasterScale: 0
        property real pendingScale: 0
        property bool showA: true
        readonly property var frontImg: showA ? imgA : imgB
        readonly property var backImg: showA ? imgB : imgA
        // ~60 Mpx of ARGB ≈ 240 MB; past this the pixmap is smooth-scaled up
        // rather than decoded larger.
        readonly property real pixelBudget: 60e6
        clip: true

        Timer {
            id: rasterTimer
            interval: 200
            onTriggered: stage.refreshRaster()
        }

        // The existing gate: hold every request until the caller has settled
        // fixedNatW/H and the stage has an on-screen size, so the only decode
        // ever issued is an on-screen-sized one (dotfiles-63rd).
        function sourceGateOpen() {
            return !(deferSource || (fixedNatW > 0 && fixedNatH > 0 && !fitted))
        }

        function targetScale(k) {
            var budget = Math.sqrt(pixelBudget / Math.max(1, natW * natH))
            return Math.min(16, budget, Math.max(0.02, k))
        }

        function setSize(img, scale) {
            if (scale > 0 && natW > 0) {
                img.sourceSize.width = Math.min(8192, Math.max(1, Math.round(natW * scale)))
                img.sourceSize.height = Math.min(8192, Math.max(1, Math.round(natH * scale)))
            } else {
                img.sourceSize.width = 0
                img.sourceSize.height = 0
            }
        }

        function loadFront(scale) {
            showA = true
            rasterScale = scale
            pendingScale = scale
            imgB.source = ""
            setSize(imgA, scale)
            imgA.source = sourceGateOpen() ? imgUrl : ""
        }

        function refreshRaster() {
            if (!sourceGateOpen() || natW <= 0 || imgUrl === "") return
            // 1:1 is the floor — never trade detail away just because the
            // current framing is zoomed out; that is what made zooming in
            // look like progressive sharpening.
            var k = Math.max(zoom, 1)
            if (rasterScale > 0 && k <= rasterScale && k > rasterScale / 3) return
            var target = targetScale(k)
            if (rasterScale > 0 && Math.abs(target - rasterScale) < 0.01) return
            pendingScale = target
            var back = backImg
            setSize(back, target)
            back.source = imgUrl
            if (back.status === Image.Ready) swapBuffers()
        }

        function swapBuffers() {
            rasterScale = pendingScale
            showA = !showA
        }

        function bootstrapLoad() {
            userAdjusted = false
            if (fixedNatW > 0 && fixedNatH > 0) {
                natW = fixedNatW
                natH = fixedNatH
                initialView()
            } else {
                loadFront(0)          // raster tier: decode once at intrinsic size
            }
        }
        onImgUrlChanged: bootstrapLoad()

        // `source` used to be a binding, so it re-evaluated by itself the
        // moment the gate opened (deferSource cleared, or fitted latched).
        // Driving it imperatively means those transitions have to be watched
        // explicitly — without this the svg tier never issues its request at
        // all, because the gate is still shut when fixedNatW/H land.
        function maybeLoad() {
            if (!sourceGateOpen() || imgUrl === "") return
            if (frontImg.source != "") return
            loadFront(natW > 0 ? targetScale(zoom) : 0)
        }
        onDeferSourceChanged: maybeLoad()
        onFittedChanged: maybeLoad()

        Component.onCompleted: bootstrapLoad()
        onFixedNatWChanged: if (fixedNatW > 0 && fixedNatH > 0) { natW = fixedNatW; natH = fixedNatH; initialView() }
        onFixedNatHChanged: if (fixedNatW > 0 && fixedNatH > 0) { natW = fixedNatW; natH = fixedNatH; initialView() }

        function apply(k, x, y) {
            zoom = Math.max(0.02, Math.min(16, k))
            content.x = x
            content.y = y
            rasterTimer.restart()
        }
        // userAdjusted latches on the first deliberate zoom/pan, after which
        // a resize must not yank the view back to the initial framing.
        property bool userAdjusted: false

        // Opening view: framed to fit, but decoded at 100% detail. Framing
        // and raster quality are separate concerns — fitting the FRAME is
        // what you want to see, decoding at the FIT scale is not: that first
        // pixmap is downscaled, and every zoom-in supersedes it, which reads
        // as the picture progressively sharpening. Decoding at 1:1 up front
        // means zooming to 100% needs no new decode at all.
        function initialView() {
            if (natW <= 0 || natH <= 0 || stage.width <= 0 || stage.height <= 0) return
            var k = Math.min(stage.width / natW, stage.height / natH) * 0.97
            apply(k, (stage.width - natW * k) / 2, (stage.height - natH * k) / 2)
            fitted = true
            if (frontImg.source == "") loadFront(targetScale(1))
            else rasterTimer.restart()
        }

        function fitStage() {
            if (natW <= 0 || natH <= 0 || stage.width <= 0 || stage.height <= 0) return
            var k = Math.min(stage.width / natW, stage.height / natH) * 0.97
            apply(k, (stage.width - natW * k) / 2, (stage.height - natH * k) / 2)
            // Last, never before apply(): everything the sourceSize binding
            // reads (natW/natH via content's width/height, and zoom) is
            // settled at this point, so the Image's first request on the
            // fixedNatW/H path is already the on-screen-sized one.
            fitted = true
            // First fit is what opens the gate on the svg path: issue the
            // one on-screen-sized request here. Later fits (resize) only
            // nudge the debounce, so a drag-resize does not thrash decodes.
            if (frontImg.source == "") loadFront(natW > 0 ? targetScale(zoom) : 0)
            else rasterTimer.restart()
        }
        function actualSize() {
            if (natW <= 0) return
            userAdjusted = true
            apply(1, (stage.width - natW) / 2, (stage.height - natH) / 2)
        }
        function zoomAt(factor, cx, cy) {
            if (natW <= 0) return
            userAdjusted = true
            var k = Math.max(0.02, Math.min(16, zoom * factor))
            apply(k, cx - (cx - content.x) * (k / zoom), cy - (cy - content.y) * (k / zoom))
        }

        onWidthChanged: if (!userAdjusted) initialView()
        onHeightChanged: if (!userAdjusted) initialView()

        Item {
            id: content
            width: stage.natW * stage.zoom
            height: stage.natH * stage.zoom

            // The pixmap lives at natural size and is SCALED to the zoom; only
            // the debounced re-decode changes sourceSize, and it lands in the
            // hidden buffer. See the rasterScale note on the stage above.
            Item {
                id: sheet
                width: stage.natW
                height: stage.natH
                transformOrigin: Item.TopLeft
                scale: stage.zoom

                Image {
                    id: imgA
                    anchors.fill: parent
                    visible: stage.showA
                    asynchronous: true
                    smooth: true
                    // kept: each full-resolution decode of an svg retains one
                    // ARGB raster for the life of the process (dotfiles-63rd),
                    // and a cache cannot bound growth that is linear in
                    // decodes of ONE url. The gate + the debounce are what
                    // keep the decode count down now.
                    cache: false
                    fillMode: Image.Stretch
                    onStatusChanged: if (status === Image.Ready && !stage.showA
                                         && stage.pendingScale !== stage.rasterScale)
                                         stage.swapBuffers()

                    // Raster tiers have no other way to learn their natural
                    // size than decoding once at intrinsic size — that is the
                    // rasterScale === 0 bootstrap. Once a scale is in force,
                    // implicitWidth just echoes the requested size, so syncing
                    // from it then would corrupt natW/natH.
                    function syncNaturalSize() {
                        if (stage.fixedNatW > 0 && stage.fixedNatH > 0) return
                        if (stage.rasterScale > 0) return
                        if (implicitWidth > 0 && implicitHeight > 0
                                && (implicitWidth !== stage.natW || implicitHeight !== stage.natH)) {
                            stage.natW = implicitWidth
                            stage.natH = implicitHeight
                            stage.initialView()
                        }
                    }
                    onImplicitWidthChanged: syncNaturalSize()
                    onImplicitHeightChanged: syncNaturalSize()
                }

                Image {
                    id: imgB
                    anchors.fill: parent
                    visible: !stage.showA
                    asynchronous: true
                    smooth: true
                    cache: false
                    fillMode: Image.Stretch
                    onStatusChanged: if (status === Image.Ready && stage.showA
                                         && stage.pendingScale !== stage.rasterScale)
                                         stage.swapBuffers()
                }
            }
        }

        DragHandler { target: content }

        WheelHandler {
            acceptedModifiers: Qt.NoModifier
            onWheel: (ev) => stage.zoomAt(Math.exp(ev.angleDelta.y * 0.0016), ev.x, ev.y)
        }

        TapHandler { onDoubleTapped: stage.actualSize() }

        Shortcut { sequence: "0"; onActivated: stage.actualSize() }
        Shortcut { sequence: "f"; onActivated: { stage.userAdjusted = true; stage.fitStage() } }
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

    // The three web-tier types, and the exact URL each needs — verified
    // against preview-d's actual routing (server.go/proxy.go/render_stl.go):
    //   html -> ?native is the ONLY way to get the raw file back; without
    //           it .html falls through to chroma's own lexer and renders
    //           as highlighted code instead (render.go's isHTMLExt must
    //           run before lexers.Match).
    //   stl  -> the bare path IS the kept orbit-viewer page (?native is a
    //           no-op for stl; ?full would instead stream raw model
    //           bytes, which is NOT what the web tier wants here).
    //   akm  -> ?slot=<N> is what lets the returned cross-origin iframe
    //           (adr0009) carry the slot down to akm-graph-d, which is
    //           what makes the adr0007 reverse-channel open-in-nvim and
    //           the sp011 highlight flow slot-aware.
    readonly property var webTypes: ["html", "akm", "stl"]
    function isWebType(t) { return win.webTypes.indexOf(t) !== -1 }

    function webUrlFor(path, type) {
        switch (type) {
        case "html": return win.fileUrl(path) + "?native"
        case "stl": return win.fileUrl(path)
        case "akm": return win.fileUrl(path) + "?slot=" + win.slotN
        default: return ""
        }
    }

    // fallbackMessage covers the native Loader's own fallback cases: no
    // path ever set yet (empty window state), a classified "none"
    // (unrenderable) file, and any future type string this client
    // doesn't recognise — which must degrade here rather than crash
    // (sp022 Task 4 edge case). html|akm|stl never reach this: they are
    // routed to webLoader below, not nativeLoader, so they never consult
    // nativeDelegateFor's default branch.
    function fallbackMessage() {
        if (win.currentPath === "") return "preview " + win.slotN + " — waiting for a file…"
        switch (win.currentType) {
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
            // sizeSettled: false until the FIRST response for the current
            // baseUrl has come back — whatever it said. While it is false
            // the stage holds its Image sourceless (PannableStage's
            // deferSource), which is what keeps the svg tier from ever
            // issuing the sourceSize-0 request whose decoded raster is
            // retained for the life of the process (dotfiles-63rd; the
            // numbers are on PannableStage's `source` binding).
            //
            // It flips on ANY completed response, not only on a parseable
            // viewBox, so the degenerate paths keep exactly the behaviour
            // they have today: a non-200, or a document with no usable
            // viewBox, leaves natW/natH at 0, so fixedNatW/H stay 0 and the
            // stage falls back to its implicitWidth-driven sizing with the
            // url handed over as before. The gate must never be able to
            // strand a tier blank.
            property bool sizeSettled: false
            onBaseUrlChanged: { lastLen = -1; sizeSettled = false; poll() }

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
                        if (xhr.status !== 200) { svgTier.sizeSettled = true; return }
                        var text = xhr.responseText || ""
                        var len = text.length
                        var size = svgTier.viewBoxSize(text)
                        if (svgTier.lastLen === -1) {
                            // First response for this url: establish the
                            // natural size, no repaint token — the Image
                            // has not fetched anything yet (it is held by
                            // deferSource until sizeSettled below), so v=0
                            // is still the right token and bumping it would
                            // only add a redundant round trip.
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
                        // LAST, after natW/natH: releasing the stage's
                        // Image before the sizes are in would put it back
                        // in the sourceSize-0 state this exists to avoid.
                        // By here fixedNatW/H have propagated and
                        // fitStage() has already run, so the one request
                        // that goes out is the on-screen-sized one.
                        svgTier.sizeSettled = true
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
                // Only for the bootstrap of each new document. Once
                // sizeSettled latches, a live-reload token bump repaints
                // immediately with no extra round trip — the poll's own
                // response is what bumped it, so the size is already known.
                deferSource: !svgTier.sizeSettled
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

    // nativeDelegateFor is the dispatch point from a classified type
    // string to a NATIVE Loader component. Web types (html/akm/stl) are
    // deliberately absent from this switch — they are routed to webLoader
    // below, never here — so "none" and any future type string this
    // client has never seen are the only branches that fall through to
    // fallbackDelegate rather than crashing (sp022 Task 4 edge case: "ws
    // frame with unknown future type string -> fallback delegate, not a
    // crash").
    function nativeDelegateFor(type) {
        switch (type) {
        case "image": return imageDelegate
        case "svg": return svgDelegate
        case "md": return mdDelegate
        case "code": return codeDelegate
        case "video": return videoDelegate
        default: return fallbackDelegate
        }
    }

    // webDelegate wraps WebTier.qml (Task 5) — the file that carries the
    // `import QtWebEngine` this file must never carry. WebTier resolves
    // as a type here purely from being a sibling .qml file in the same
    // directory (QML's implicit directory import), no explicit `import`
    // statement needed or wanted: an explicit import would still only
    // pull in the WebTier.qml *type declaration*, and QtWebEngine's own
    // module import inside that file only executes when this Component is
    // actually instantiated — i.e. at webLoader.sourceComponent
    // assignment below, not at this file's parse time. sourceUrl is a
    // live binding against win.currentPath/currentType, so switching
    // between web types (html -> akm -> stl) while this delegate is
    // already alive is just WebTier's own url property changing — no new
    // Component, no new engine.
    Component {
        id: webDelegate
        WebTier { sourceUrl: win.webUrlFor(win.currentPath, win.currentType) }
    }

    // onCurrentTypeChanged (currentType is win's own property, declared
    // near the top of this file) is where the lazy assignment happens:
    // webLoader.sourceComponent is set to webDelegate the FIRST time
    // currentType becomes a web type, and the `=== null` guard means it
    // is never reassigned after that — so every later web visit reuses
    // the same WebEngineView instance/process instead of paying the
    // ~240 MiB engine cost again (poc018).
    onCurrentTypeChanged: {
        if (win.isWebType(win.currentType) && webLoader.sourceComponent === null) {
            webLoader.sourceComponent = webDelegate
        }
    }

    // Two Loaders, never both visible, is what gives the native and web
    // tiers independent lifetimes while still living in ONE window:
    //
    // - nativeLoader: sourceComponent only re-evaluates when currentType
    //   actually changes (Loader semantics), and is explicitly nulled
    //   out while a web type is current — so it never wastes a
    //   fallbackDelegate instantiation behind an invisible web view, and
    //   its native delegate is freed the moment the frame goes web (same
    //   already-proven Task 4 hot-swap: no process respawn, last-wins by
    //   construction, no stacked delegates).
    // - webLoader: sourceComponent is assigned AT MOST ONCE (see
    //   onCurrentTypeChanged above) and is NEVER nulled back out — this
    //   is what makes the engine "stay warm": a native visit only flips
    //   `visible` to false, it never destroys the WebEngineView, so an
    //   akm -> md -> akm sweep reloads WebTier's url property (a plain
    //   navigation), never spins up a new render process.
    Loader {
        id: nativeLoader
        anchors.fill: parent
        visible: !win.isWebType(win.currentType)
        sourceComponent: win.isWebType(win.currentType) ? null : win.nativeDelegateFor(win.currentType)
    }

    Loader {
        id: webLoader
        anchors.fill: parent
        visible: win.isWebType(win.currentType)
        // sourceComponent starts unset (Loader.status === Loader.Null,
        // no QtWebEngine module load, no engine cost) — assigned lazily
        // by onCurrentTypeChanged above.
    }
}
