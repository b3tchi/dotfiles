.pragma library

// Lens switching for CameraOverlay.qml (sp046 T4, us030 AC 6-7). Pure
// functions, tested headless by test-camera-switch.sh. `list` is
// Session.cameras ({id, label, focusFar, focusSlope, wbRatio}), `lib` the
// module's `cameras` ({id, facing, ...}).

function byId(list, id) {
    for (var i = 0; i < list.length; i++)
        if (list[i].id === id) return list[i]
    return null
}

function listed(lib, id) { return byId(lib || [], id) !== null }

function facingOf(lib, id) {
    var c = byId(lib || [], id)
    return c ? c.facing : ""
}

// Target entry of a switch, or null for a no-op. kind: "rear" | "front" |
// "default". Configured entries libcamera does not list are skipped for
// rear / front (the first back entries, the front entry); "default" is the
// first entry even when unlisted, so the overlay can show the error.
function pick(kind, list, lib, currentId, lastRearId) {
    list = list || []
    var rears = [], front = null
    for (var i = 0; i < list.length; i++) {
        var f = facingOf(lib, list[i].id)
        if (f === "back") rears.push(list[i])
        else if (f === "front" && front === null) front = list[i]
    }
    var lastRear = byId(rears, lastRearId) || rears[0] || null
    if (kind === "rear") {
        if (rears.length < 2) return null
        if (currentId === rears[0].id) return rears[1]
        if (currentId === rears[1].id) return rears[0]
        return lastRear
    }
    if (kind === "front") {
        if (front === null) return null
        return currentId === front.id ? lastRear : front
    }
    if (kind === "default") {
        if (list.length === 0 || list[0].id === currentId) return null
        return list[0]
    }
    return null
}

// What to carry from the camera being left. `st` holds the module's current
// values; a camera without a lens keeps the last known dioptres.
function snapshot(st, lastDioptres) {
    return {
        focusDioptres: st.focusAvailable ? st.focusDioptres : lastDioptres,
        autoExposure: st.autoExposure,
        exposureTime: st.exposureTime,
        iso: st.iso,
        colourGains: st.colourGains
    }
}

// Ordered steps to apply after the new camera's first exposure metadata:
// ISO, exposure time (only when the snapshot was manual), dioptres (only
// with a lens), colour gains scaled by target.wbRatio / source.wbRatio (raw
// when either has no ratio). Each step {op, ...}.
function plan(snap, source, target, focusAvailable) {
    var out = [{op: "iso", value: snap.iso > 0 ? snap.iso : 0}]
    if (snap.autoExposure === false && snap.exposureTime > 0)
        out.push({op: "exposureTime", value: snap.exposureTime})
    if (focusAvailable && typeof snap.focusDioptres === "number" && isFinite(snap.focusDioptres))
        out.push({op: "dioptres", value: snap.focusDioptres})
    var g = snap.colourGains
    if (g && g.length === 2 && g[0] > 0 && g[1] > 0) {
        var r = g[0], b = g[1]
        var s = source && source.wbRatio, t = target && target.wbRatio
        if (s && t && s[0] > 0 && s[1] > 0) {
            r = r * t[0] / s[0]
            b = b * t[1] / s[1]
        }
        out.push({op: "gains", r: r, b: b})
    }
    return out
}

// Whether the module's `error` means the stream is down. CameraSource sets
// one non-fatal note on a successful start of a camera without manual
// exposure; every other non-empty error is a failure (adr0014: no retry).
var MANUAL_OFF = "camera lacks AeEnable / ExposureTime / AnalogueGain"
function startFailed(error) {
    return typeof error === "string" && error !== "" && error.indexOf(MANUAL_OFF) !== 0
}
