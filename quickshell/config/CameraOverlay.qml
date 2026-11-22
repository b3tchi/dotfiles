import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtMultimedia
import LibCamera 1.0

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
        if (!open || snapping) return
        if (cam.error !== "" || cam.size.width === 0) return // nothing streaming
        snapping = true
        cam.capture(photoDir + "/" + Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss") + ".jpg")
    }

    function close() {
        if (!open) return
        open = false
        snapping = false
        Quickshell.execDetached([hotkeyd, "set-layer", "default"])
    }

    CameraSource {
        id: cam
        active: root.open
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

    IpcHandler {
        target: "camera"
        function open(): void { root.show() }
        function snap(): void { root.snap() }
        function close(): void { root.close() }
    }

    PanelWindow {
        visible: root.open
        color: "black"
        anchors { top: true; bottom: true; left: true; right: true }
        // Normal: laid out inside the other panels' exclusive zones, i.e.
        // between the top bar and the bottom (hint) bar; reserves nothing.
        exclusionMode: ExclusionMode.Normal
        exclusiveZone: 0
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

        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            visible: cam.error !== ""
            text: cam.error
            color: "#ff6b6b"
            font.pixelSize: 20
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
