import QtQuick
import QtTest
import "config/Common/CameraReadout.js" as R

// sp045 T6: readout formatting for CameraOverlay (run by test-camera-readout.sh)
TestCase {
    name: "CameraReadout"
    function test_focus() {
        compare(R.focusText(false, 385, 385), "")            // hidden without focus control
        compare(R.focusText(true, 400, -1), "F -")            // no machine default
        compare(R.focusText(true, 385, 385), "F ∞")           // pos == far
        compare(R.focusText(true, 380, 385), "F ∞")           // beyond far, still infinity
        compare(R.focusText(true, 385 + 12.9, 385), "F 1.0 m")
        compare(R.focusText(true, 385 + 12.9 / 0.25, 385), "F 0.25 m")
        compare(R.focusText(true, 385 + 12.9 / 12, 385), "F 12 m")
        // 2026-11-26 recalibration: chart at 31.5 cm sharpest at lens 426
        compare(R.focusText(true, 426, 385), "F 0.31 m")
    }
    function test_exposure() {
        compare(R.exposureText(true, 10000, 2), "AE")
        compare(R.exposureText(false, 10000, 2), "M 1/100 x2.0")
        compare(R.exposureText(false, 33333, 1.5), "M 1/30 x1.5")
        compare(R.exposureText(false, 0, 1), "M")             // no exposure reported yet
        compare(R.exposureText(true, 10000, 8, 800), "ISO 800") // auto time, fixed gain
        compare(R.exposureText(true, 10000, 8, 0), "AE")
        // manual exposure at a fixed ISO: shutter priority, time only
        compare(R.exposureText(false, 16667, 8, 800), "ISO 800 1/60")
        compare(R.exposureText(false, 0, 8, 800), "ISO 800 M")       // no time reported yet
    }
    function test_line() {
        compare(R.line("F ∞", "AE", false), "F ∞   AE")
        compare(R.line("F ∞", "AE", true), "F ∞   AE   capturing…")  // a still sits beside the values
        compare(R.line("", "AE", false), "AE")                       // no focus control: no gap
        compare(R.line("", "", true), "capturing…")
        compare(R.line("", "", false), "")                           // hides the label
    }
    function test_metresWideSlope() {
        compare(R.metres(520, 250, 270), "1.0 m")             // slope 270: 270/270 m
        compare(R.focusText(true, 520, 250, 270), "F 1.0 m")
    }
    function test_metresUltrawideDefault() {
        compare(R.metres(385 + 12.9, 385), "1.0 m")           // slope omitted: 12.9
        compare(R.metres(426, 385), "0.31 m")
        compare(R.metres(385, 385, 270), "\u221e")
    }
    function test_labelShown() {
        compare(R.labelText("W"), "W")
        compare(R.labelText("UW"), "UW")
        compare(R.labelText("F"), "F")
    }
    function test_labelEmpty() {
        compare(R.labelText(""), "")
        compare(R.labelText(undefined), "")
        compare(R.labelText(null), "")
    }
    function test_camerasNew() {
        var l = R.cameras({ cameras: [
            { id: "a", label: "W", focusFar: 250, focusSlope: 270, wbRatio: [1.55, 1.04], junk: 1 },
            { id: "b", label: "UW", focusFar: 385 },
            { id: "a", label: "dup" },
            { label: "noid" },
            { id: "f", label: "F" } ] })
        compare(l.length, 3)                                  // duplicate id: first wins; no id dropped
        compare(l[0].label, "W")
        compare(l[0].focusSlope, 270)
        compare(l[0].wbRatio[0], 1.55)
        compare(l[0].junk, undefined)                         // unknown keys ignored
        compare(l[1].focusSlope, undefined)                   // ladder default
        compare(R.focusText(true, 400, l[2].focusFar, l[2].focusSlope), "F -")
    }
    function test_camerasOldFormat() {
        var l = R.cameras({ id: "/x/camera@10", focusFar: 1024 })
        compare(l.length, 1)
        compare(l[0].id, "/x/camera@10")
        compare(l[0].focusFar, 1024)
    }
    function test_camerasEmpty() {
        compare(R.cameras(undefined).length, 0)
        compare(R.cameras({}).length, 0)
        compare(R.cameras({ cameras: [] }).length, 0)
        compare(R.cameras({ cameras: "x" }).length, 0)
    }
}
