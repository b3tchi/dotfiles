import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtMultimedia
import LibCamera 1.0
import "./Common"
import "./Common/CameraReadout.js" as Readout

// Phone camera overlay (dotfiles sp041 Task 6, ft019): the back camera's
// live preview in a layer-shell panel that fills the space BETWEEN the bars
// - below the top bar, which covers the cutout row (adr0038), and above the
// bottom bar, which carries the hint strip (ft009) - so the camera layer's
// keys stay readable. hotkeyd owns those keys (ft011: Alt+f enters the
// `camera` layer and drives this over IPC), so the panel never takes
// keyboard focus.
//
//   quickshell ipc call camera open    show + start streaming
//   quickshell ipc call camera snap    photo -> ~/Pictures/camera/<stamp>.jpg,
//                                      clipboard (image/png), notify, close
//   quickshell ipc call camera close   close, nothing saved
//   quickshell ipc call camera near|far|refocus|auto|brighter|darker|isoUp|isoDown|isoAuto|aeAuto
//                                      focus / exposure steps (sp045, adr0041):
//                                      no-ops while closed or capturing; the
//                                      overlay never clears the hotkeyd layer
//                                      for them, only close() does
//
// Every close path hands the keyboard back (`hotkeyd set-layer default`)
// and releases the camera. A failed open shows the error and stays put;
// it is never retried (adr0014). Loaded by shell.qml through a Loader, so
// a host without the LibCamera module only loses this file, not the bar.
Scope {
    id: root

    property bool open: false
    property bool snapping: false

    // Same resolution as RegionShot.qml: the session's own hotkeyd.
    readonly property string hotkeyd: Quickshell.env("QS_LAYER_FEED") || (Quickshell.env("HOME") + "/.dotfiles/hotkeyd/hotkeyd")
    readonly property string photoDir: Quickshell.env("HOME") + "/Pictures/camera"

    function show() {
        if (open) return
        snapping = false
        open = true
    }

    function snap() {
        // `snapping` covers the whole still (capture -> captured), so a
        // second snap while the module is `capturing` is a no-op (sp042)
        if (!open || snapping) return
        if (cam.error !== "" || cam.size.width === 0) return // nothing streaming
        snapping = true
        cam.capture(photoDir + "/" + Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss") + ".jpg")
    }

    // A step needs a streaming, idle overlay: closed or `capturing` (the
    // still pauses the pipeline) -> ignored, as snap is.
    readonly property bool stepOk: open && !snapping && !cam.capturing

    function near()     { if (stepOk && cam.focusAvailable) cam.focusNear() }
    function far()      { if (stepOk && cam.focusAvailable) cam.focusFar() }
    function refocus()  { if (stepOk && cam.focusAvailable) cam.focusReset() }
    function auto()     { if (stepOk) cam.autoExposure = !cam.autoExposure }
    function brighter() { if (stepOk) cam.brighter() }
    function darker()   { if (stepOk) cam.darker() }
    function isoUp()    { if (stepOk) cam.isoUp() }
    function isoDown()  { if (stepOk) cam.isoDown() }
    function isoAuto()  { if (stepOk) cam.isoAuto() }
    function aeAuto()   { if (stepOk) cam.autoExposure = true }

    function close() {
        if (!open) return
        open = false
        snapping = false
        Quickshell.execDetached([hotkeyd, "set-layer", "default"])
        releaseRing()
    }

    // kwi3's focus ring is a KWin-internal window drawn above every
    // layer-shell surface, so the preview cannot cover it. kwi3 hides it in
    // any non-default mode (kwi3/config.js modeFrame '*': 'none'). hotkeyd
    // does NOT tell kwi3 "default" when the camera layer ends (its
    // kwi3HandOffLayers, sp045): the preview is still up for the photo, so
    // this overlay owns kwi3's mode until it closes and sends "default"
    // itself (ft010 mode.set). If the ring comes back anyway while the
    // preview is up (hotkeyd restarted, an older hotkeyd), it is put away
    // again by setting "camera".
    function holdRing() {
        if (!open || !Kwi3Grid.active || !Kwi3Grid.frameEnabled) return
        Kwi3Client.call("mode.set", {name: "camera"}, function () {})
    }
    function releaseRing() {
        if (Kwi3Grid.active)
            Kwi3Client.call("mode.set", {name: "default"}, function () {})
    }
    Connections {
        target: Kwi3Grid
        function onFrameEnabledChanged() { root.holdRing() }
    }

    CameraSource {
        id: cam
        active: root.open
        // machine file camera.focusFar (the infinity position), -1 if absent
        focusDefault: {
            var c = Session.machine.camera
            var v = c ? parseInt(c.focusFar) : NaN
            return isNaN(v) ? -1 : v
        }
        videoSink: preview.videoSink
        onCaptured: (path, ok) => {
            // closed while the JPEG was being written: the file exists, but
            // the user cancelled - no clipboard, no notification
            if (!root.open) return
            if (ok) {
                cam.copyToClipboard()
                Quickshell.execDetached(["notify-send", "-a", "camera", "-i", path, "Photo saved + copied", path])
                root.close()
            } else {
                root.snapping = false // error is on screen; snap again or close
            }
        }
    }

    // hotkeyd restarted or died with the preview up (2026-11-24: a deploy
    // restarted it mid-preview; the new daemon starts in default, so the
    // preview stayed with no camera keys to close it). While open, follow
    // hotkeyd's state feed like Bar.qml does; `state-tail` exits when the
    // daemon's socket goes, and then the preview is closed at once instead
    // of waiting for the auto-close below.
    Process {
        id: daemonWatch
        command: [root.hotkeyd, "state-tail"]
        running: root.open
        stdout: SplitParser { onRead: data => {} }
        onExited: if (root.open) root.close()
    }

    // Safety net for an involuntary exit: hotkeyd's camera layer has no
    // on-exit close (it would race a snap, sp041 T7), so if hotkeyd dies
    // with the preview up - the session kills it when the screen locks -
    // nothing else would ever close it. A preview left open this long is
    // closed and the camera released.
    Timer {
        interval: 120000
        running: root.open
        onTriggered: root.close()
    }

    // The bar shows the camera strip for as long as the preview is up,
    // though hotkeyd already left the layer at the snap / quit key (adr0041).
    Binding {
        target: ModeBarTheme
        property: "cameraActive"
        value: root.open
    }

    IpcHandler {
        target: "camera"
        function open(): void { root.show() }
        function snap(): void { root.snap() }
        function close(): void { root.close() }
        function near(): void { root.near() }
        function far(): void { root.far() }
        function refocus(): void { root.refocus() }
        function auto(): void { root.auto() }
        function brighter(): void { root.brighter() }
        function darker(): void { root.darker() }
        function isoUp(): void { root.isoUp() }
        function isoDown(): void { root.isoDown() }
        function isoAuto(): void { root.isoAuto() }
        function aeAuto(): void { root.aeAuto() }
    }

    PanelWindow {
        visible: root.open
        color: "black"
        anchors { top: true; bottom: true; left: true; right: true }
        // Normal: laid out inside the other panels' exclusive zones, i.e.
        // between the top bar and the bottom (hint) bar; reserves nothing.
        exclusionMode: ExclusionMode.Normal
        exclusiveZone: 0
        // The top bar's exclusive zone is deliberately smaller than the bar
        // (Bar.qml subtracts its margin band), so the work area starts under
        // the bar's lower edge; kwi3 starts its tiles `reserve` lower. Start
        // where the tiles do: the bar stays whole, the tab row is covered.
        margins.top: Kwi3Grid.active ? Kwi3Grid.reserve : 0
        // Overlay, as RegionShot.qml: KWin stacks a fullscreen window above
        // the Top layer, and the camera layer's keys must never be live
        // behind a hidden preview. Exclusive zones still apply, so the panel
        // stays between the bars.
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-camera"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        VideoOutput {
            id: preview
            anchors.fill: parent
            orientation: cam.rotation
        }

        // us030 AC 3: focus distance + exposure, bottom-left, bound to the
        // module's properties so it follows a change within a frame. A full
        // still pauses the preview for ~1 s (sp042); "capturing…" shows in
        // the same label, beside the values.
        Rectangle {
            readonly property string txt: Readout.line(
                Readout.focusText(cam.focusAvailable, cam.focusPosition, cam.focusDefault),
                Readout.exposureText(cam.autoExposure, cam.exposureTime, cam.analogueGain, cam.iso),
                cam.capturing)
            visible: txt !== ""
            anchors { left: parent.left; bottom: parent.bottom; leftMargin: 16; bottomMargin: 16 }
            width: roLabel.implicitWidth + 32
            height: roLabel.implicitHeight + 16
            radius: 8
            color: "#c0000000"
            Text { id: roLabel; anchors.centerIn: parent; text: parent.txt; color: "white"; font.family: DialogTheme.font; font.pixelSize: DialogTheme.fontSize }
        }

        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            visible: cam.error !== ""
            text: cam.error
            color: "#ff6b6b"
            font.family: DialogTheme.font
            font.pixelSize: DialogTheme.fontSize
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
