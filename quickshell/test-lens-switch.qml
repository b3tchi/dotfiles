import QtQuick
import QtTest
import "config/Camera"

// sp046 T4: LensSwitch.qml against a stub CameraSource (run by
// test-camera-switch.sh). The stub mirrors the module where it matters:
// setting cameraId restarts the stream synchronously, so the calibration it
// sees in onCameraIdChanged is what the new lens is parked / laddered with.
TestCase {
    name: "LensSwitch"

    readonly property var wide: ({id: "W", label: "W", focusFar: 250, focusSlope: 20, wbRatio: [1.55, 1.04]})
    readonly property var uw: ({id: "UW", label: "UW", focusFar: 385, focusSlope: 12.9, wbRatio: [1, 1]})
    readonly property var front: ({id: "F", label: "F"})

    QtObject {
        id: stub
        property var cameras: [{id: "W", facing: "back"}, {id: "UW", facing: "back"}, {id: "F", facing: "front"}]
        property string cameraId: ""
        property int focusDefault: -1
        property real focusSlope: 12.9
        property bool focusAvailable: true
        property real focusDioptres: 0
        property bool autoExposure: true
        property int exposureTime: 0
        property int iso: 0
        property var colourGains: [2, 1.5]
        property string error: ""
        signal exposureChanged()
        signal focusChanged()

        // test knobs + records
        property string startError: ""          // what the next start sets
        property var starts: []                 // "id:focusDefault/focusSlope"
        property var calls: []

        onCameraIdChanged: {
            starts = starts.concat([cameraId + ":" + focusDefault + "/" + focusSlope])
            exposureTime = 0                    // start resets exposure
            error = startError
        }
        function setIso(v) { calls = calls.concat(["iso " + v]) }
        function setExposureTime(v) { calls = calls.concat(["time " + v]) }
        function setColourGains(r, b) { calls = calls.concat(["gains " + r.toFixed(3) + " " + b.toFixed(3)]) }
        function frame(t) { exposureTime = t; exposureChanged() }
    }

    LensSwitch { id: sw; cam: stub }

    function init() {
        stub.startError = ""
        stub.error = ""
        stub.cameraId = ""
        stub.exposureTime = 0
        stub.focusAvailable = true
        sw.cameras = [wide, uw, front]
        sw.reset()
        stub.starts = []
        stub.calls = []
    }

    // RED when cameraId lands before focusDefault / focusSlope (a binding or a
    // reordered apply): the new camera then starts on the old calibration.
    function test_calibrationBeforeId() {
        sw.lens("rear")
        stub.frame(10000)
        sw.lens("rear")
        stub.frame(10000)
        compare(stub.starts, ["UW:385/12.9", "W:250/20"])
        compare(stub.cameraId, "W")
    }
    function test_resetAppliesDefaultCalibration() {
        sw.lens("rear")
        stub.frame(10000)
        stub.starts = []
        sw.reset()
        compare(stub.starts, ["W:250/20"])
        compare(sw.activeId, "W")
        compare(sw.lastRearId, "W")
    }
    function test_frontWithoutCalibrationGetsDefaults() {
        sw.lens("front")
        compare(stub.starts, ["F:-1/12.9"])
    }

    function test_secondPressWhileSettlingIgnored() {
        sw.lens("rear")
        verify(sw.switching)
        sw.lens("rear")
        sw.lens("front")
        compare(stub.starts, ["UW:385/12.9"])
        stub.frame(10000)
        verify(!sw.switching)
        sw.lens("rear")
        compare(stub.starts, ["UW:385/12.9", "W:250/20"])
    }
    // A camera without manual exposure starts fine but leaves a non-fatal
    // error; the settling guard must hold anyway.
    function test_guardHoldsOverNonFatalError() {
        stub.startError = "camera lacks AeEnable / ExposureTime / AnalogueGain: manual exposure off"
        sw.lens("rear")
        verify(sw.switching)
        sw.lens("rear")
        compare(stub.starts, ["UW:385/12.9"])
    }
    // A failed start ends the switch: no carry-over waits, the next press is
    // the (manual) retry and nothing is re-issued by itself.
    function test_failedStartClearsPending() {
        stub.startError = "camera busy"
        sw.lens("rear")
        verify(!sw.switching)
        compare(sw.pending, null)
        compare(stub.starts, ["UW:385/12.9"])
        stub.startError = ""
        sw.lens("rear")                         // the retry: UW -> W
        compare(stub.starts, ["UW:385/12.9", "W:250/20"])
        verify(sw.switching)
    }
    function test_errorBeforeFirstMetadataClearsPending() {
        sw.lens("rear")
        stub.error = "queue request failed (-5)"
        verify(!sw.switching)
        stub.frame(10000)
        compare(stub.calls, [])                 // nothing applied after failure
    }
    function test_carryOverOnFirstMetadata() {
        stub.autoExposure = false
        stub.exposureTime = 20000
        stub.iso = 400
        sw.lens("rear")                         // W -> UW, ratio 1/1.55, 1/1.04
        stub.exposureChanged()                  // exposureTime 0: not metadata yet
        compare(stub.calls, [])
        stub.frame(5000)
        compare(stub.calls, ["iso 400", "time 20000", "gains " + (2 / 1.55).toFixed(3) + " " + (1.5 / 1.04).toFixed(3)])
        stub.autoExposure = true
    }
    // CameraSource has no focusDioptresChanged: focusDioptres notifies
    // through focusChanged (as does focusAvailable).
    function test_lastDioptresFollowsFocusChanged() {
        stub.focusAvailable = false
        stub.focusDioptres = 2.5
        stub.focusAvailable = true
        stub.focusChanged()
        compare(sw.lastDioptres, 2.5)
        stub.focusAvailable = false
        stub.focusDioptres = 0
        stub.focusChanged()
        compare(sw.lastDioptres, 2.5)
    }
    function test_unlistedTargetRefused() {
        stub.cameras = [{id: "UW", facing: "back"}, {id: "W2", facing: "back"}]
        sw.cameras = [wide, uw]
        sw.lens("default")                      // activeId W... is the default
        compare(stub.starts, [])
        sw.activeId = "UW"
        sw.lens("default")
        compare(sw.switchError, "camera not found: W")
        compare(stub.starts, [])
        verify(!sw.switching)
        stub.cameras = [{id: "W", facing: "back"}, {id: "UW", facing: "back"}, {id: "F", facing: "front"}]
    }
}
