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
        compare(R.focusText(true, 385 + 18.9, 385), "F 1.0 m")
        compare(R.focusText(true, 385 + 18.9 / 0.25, 385), "F 0.25 m")
        compare(R.focusText(true, 385 + 18.9 / 12, 385), "F 12 m")
    }
    function test_exposure() {
        compare(R.exposureText(true, 10000, 2), "AE")
        compare(R.exposureText(false, 10000, 2), "M 1/100 x2.0")
        compare(R.exposureText(false, 33333, 1.5), "M 1/30 x1.5")
        compare(R.exposureText(false, 0, 1), "M")             // no exposure reported yet
    }
    function test_line() {
        compare(R.line("F ∞", "AE", false), "F ∞   AE")
        compare(R.line("F ∞", "AE", true), "F ∞   AE   capturing…")  // a still sits beside the values
        compare(R.line("", "AE", false), "AE")                       // no focus control: no gap
        compare(R.line("", "", true), "capturing…")
        compare(R.line("", "", false), "")                           // hides the label
    }
}
