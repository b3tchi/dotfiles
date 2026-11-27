import QtQuick
import "../Common/CameraSwitch.js" as Lens

// Lens switching state for CameraOverlay.qml (sp046 T4, us030 AC 6-7): which
// configured camera is active, the switch in flight and its carry-over. It
// drives `cam` (a CameraSource, or a stub in test-camera-switch.qml)
// imperatively; nothing of cam's camera / focus calibration is bound.
//
// Order matters: CameraSource.setCameraId restarts the stream at once, and
// start() parks the new lens at the CURRENT focusDefault and builds the
// focus ladder from the CURRENT focusDefault / focusSlope. So apply() sets
// the calibration first and the id last; a binding could not promise that.
QtObject {
    id: sw

    required property var cam
    // Session.cameras: [{id, label, focusFar, focusSlope, wbRatio}], the
    // first entry the default.
    property var cameras: []

    readonly property var defaultCam: cameras.length > 0 ? cameras[0] : null
    property string activeId: ""
    property string lastRearId: ""
    // {snap, source, target} from a switch until the new camera's first
    // exposure metadata (setters before it are reset by the module's start).
    property var pending: null
    // A switch the overlay refused itself (target not in libcamera).
    property string switchError: ""
    property real lastDioptres: 0
    readonly property var activeCam: Lens.byId(cameras, activeId)
    // Settling: a second switch waits for the first one's metadata. Only
    // `pending` decides; a non-fatal module error must not open the guard.
    readonly property bool switching: pending !== null

    // Calibration first, id last (see top).
    function apply(entry) {
        cam.focusDefault = entry && entry.focusFar !== undefined ? entry.focusFar : -1
        cam.focusSlope = entry && entry.focusSlope !== undefined ? entry.focusSlope : 12.9
        activeId = entry ? entry.id : ""
        cam.cameraId = activeId
    }

    // Overlay open / close: the default camera, nothing in flight.
    function reset() {
        pending = null
        switchError = ""
        apply(defaultCam)
        lastRearId = activeId
    }

    // One attempt (adr0014): a refused or failed switch leaves its error on
    // screen and the next key press is the retry; nothing is re-issued here.
    // A failed start leaves `cam` on the target, stopped.
    function lens(kind) {
        if (switching) return
        var t = Lens.pick(kind, cameras, cam.cameras, activeId, lastRearId)
        if (t === null) return
        switchError = ""
        if (!Lens.listed(cam.cameras, t.id)) {
            switchError = "camera not found: " + t.id
            return
        }
        pending = {
            snap: Lens.snapshot({
                focusAvailable: cam.focusAvailable, focusDioptres: cam.focusDioptres,
                autoExposure: cam.autoExposure, exposureTime: cam.exposureTime,
                iso: cam.iso, colourGains: cam.colourGains
            }, lastDioptres),
            source: activeCam,
            target: t
        }
        if (Lens.facingOf(cam.cameras, activeId) === "back") lastRearId = activeId
        apply(t) // restarts synchronously: a failed start has set cam.error
        if (Lens.startFailed(cam.error)) pending = null
    }

    // First exposure metadata of the new camera: carry the shot settings
    // over (the colour gains must land inside the AWB hold, sp046).
    function applyPending() {
        if (pending === null || !(cam.exposureTime > 0)) return
        var p = pending
        pending = null
        var steps = Lens.plan(p.snap, p.source, p.target, cam.focusAvailable)
        for (var i = 0; i < steps.length; i++) {
            var s = steps[i]
            if (s.op === "iso") cam.setIso(s.value)
            else if (s.op === "exposureTime") cam.setExposureTime(s.value)
            else if (s.op === "dioptres") cam.focusDioptres = s.value
            else if (s.op === "gains") cam.setColourGains(s.r, s.b)
        }
    }

    property Connections _camWatch: Connections {
        target: sw.cam
        function onExposureChanged() { sw.applyPending() }
        // CameraSource notifies focusDioptres through focusChanged
        function onFocusChanged() {
            if (sw.cam.focusAvailable) sw.lastDioptres = sw.cam.focusDioptres
        }
        // a stream that dies before its first metadata ends the switch too
        function onErrorChanged() {
            if (sw.pending !== null && Lens.startFailed(sw.cam.error)) sw.pending = null
        }
    }
}
