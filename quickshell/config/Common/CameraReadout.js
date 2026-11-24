.pragma library

// Readout text for CameraOverlay.qml (sp045 T6, us030 AC 3). Pure functions,
// tested headless by test-camera-readout.sh.

// Calibration of the phone's focus actuator (poc030): metres = 18.9 /
// (pos - far), where `far` is the position that focuses at infinity.
var CALIB = 18.9

function metres(pos, far) {
    var d = pos - far
    if (!(d > 0)) return "∞"
    var m = CALIB / d
    if (m >= 10) return Math.round(m) + " m"
    if (m >= 1) return m.toFixed(1) + " m"
    return (Math.round(m * 100) / 100) + " m"
}

// "" when the lens has no focus control; "F -" without a machine default.
function focusText(available, pos, far) {
    if (!available) return ""
    if (!(far >= 0)) return "F -"
    return "F " + metres(pos, far)
}

// "AE", or "M 1/<s> x<gain>" for manual exposure (exposureTime in us).
function exposureText(auto, expUs, gain) {
    if (auto) return "AE"
    if (!(expUs > 0)) return "M"
    return "M 1/" + Math.round(1e6 / expUs) + " x" + Number(gain).toFixed(1)
}

// The one readout label over the picture: focus, exposure and, during a
// still, "capturing…" beside them (user 2026-11-24). Empty parts leave no
// gap; "" hides the label.
function line(focus, exposure, capturing) {
    return [focus, exposure, capturing ? "capturing…" : ""].filter(function (t) { return t !== "" }).join("   ")
}
