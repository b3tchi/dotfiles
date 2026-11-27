.pragma library

// Readout text for CameraOverlay.qml (sp045 T6, us030 AC 3). Pure functions,
// tested headless by test-camera-readout.sh.

// Calibration of the phone's focus actuator: metres = CALIB / (pos - far),
// where `far` is the position that focuses at infinity. poc030 gave 18.9;
// re-measured 2026-11-26 (chart at 31.5 cm sharpest at lens 426, far 385,
// a wall picture >1 m sharpest at <=395): 12.9.
var CALIB = 12.9

// `slope` is the camera's own calibration (wide 270); CALIB when omitted.
function metres(pos, far, slope) {
    var d = pos - far
    if (!(d > 0)) return "∞"
    var m = (slope > 0 ? slope : CALIB) / d
    if (m >= 10) return Math.round(m) + " m"
    if (m >= 1) return m.toFixed(1) + " m"
    return (Math.round(m * 100) / 100) + " m"
}

// "" when the lens has no focus control; "F -" without a machine default.
function focusText(available, pos, far, slope) {
    if (!available) return ""
    if (!(far >= 0)) return "F -"
    return "F " + metres(pos, far, slope)
}

// The readout's camera part: "W" / "UW" / "F"; "" without a label.
function labelText(label) {
    return (typeof label === "string") ? label : ""
}

// Normalises the machine file's "camera" object (sp046) to a list of
// {id, label, focusFar, focusSlope, wbRatio}. `cameras` wins; the old
// {id, focusFar} form becomes one entry; nothing usable gives []. Entries
// without an id are dropped, a repeated id keeps its first entry, unknown
// keys are ignored.
function cameras(cam) {
    if (!cam || typeof cam !== "object") return []
    var src = Array.isArray(cam.cameras) ? cam.cameras
            : (typeof cam.id === "string" ? [cam] : [])
    var seen = {}, out = []
    for (var i = 0; i < src.length; i++) {
        var c = src[i]
        if (!c || typeof c.id !== "string" || c.id === "" || seen[c.id]) continue
        seen[c.id] = true
        out.push({
            id: c.id,
            label: labelText(c.label),
            focusFar: typeof c.focusFar === "number" ? c.focusFar : undefined,
            focusSlope: typeof c.focusSlope === "number" ? c.focusSlope : undefined,
            wbRatio: (Array.isArray(c.wbRatio) && c.wbRatio.length === 2) ? c.wbRatio : undefined
        })
    }
    return out
}

// "AE"; "ISO <n>" for auto exposure at a fixed ISO (iso > 0); manual
// exposure: "M 1/<s> x<gain>", or "ISO <n> 1/<s>" at a fixed ISO (time-only
// steps, shutter priority). exposureTime in us.
function exposureText(auto, expUs, gain, iso) {
    if (auto) return iso > 0 ? "ISO " + iso : "AE"
    if (iso > 0) return "ISO " + iso + (expUs > 0 ? " 1/" + Math.round(1e6 / expUs) : " M")
    if (!(expUs > 0)) return "M"
    return "M 1/" + Math.round(1e6 / expUs) + " x" + Number(gain).toFixed(1)
}

// The one readout label over the picture: focus, exposure and, during a
// still, "capturing…" beside them (user 2026-11-24). Empty parts leave no
// gap; "" hides the label.
function line(focus, exposure, capturing) {
    return [focus, exposure, capturing ? "capturing…" : ""].filter(function (t) { return t !== "" }).join("   ")
}
