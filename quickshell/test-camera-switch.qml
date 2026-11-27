import QtQuick
import QtTest
import "config/Common/CameraSwitch.js" as S

// sp046 T4: lens selection + carry-over plan (run by test-camera-switch.sh)
TestCase {
    name: "CameraSwitch"

    readonly property var wide: ({id: "W", label: "W", focusFar: 250, focusSlope: 270, wbRatio: [1.55, 1.04]})
    readonly property var uw: ({id: "UW", label: "UW", focusFar: 385, focusSlope: 12.9, wbRatio: [1, 1]})
    readonly property var front: ({id: "F", label: "F"})
    readonly property var list: [wide, uw, front]
    readonly property var lib: [{id: "W", facing: "back"}, {id: "UW", facing: "back"}, {id: "F", facing: "front"}]

    function id(e) { return e ? e.id : null }

    function test_rearToggles() {
        compare(id(S.pick("rear", list, lib, "W", "W")), "UW")
        compare(id(S.pick("rear", list, lib, "UW", "UW")), "W")
    }
    function test_rearFromFrontGoesToLastRear() {
        compare(id(S.pick("rear", list, lib, "F", "UW")), "UW")
        compare(id(S.pick("rear", list, lib, "F", "")), "W")
    }
    function test_rearNeedsTwoRear() {
        compare(S.pick("rear", [wide, front], lib, "W", "W"), null)
        compare(S.pick("rear", list, [lib[0], lib[2]], "W", "W"), null) // UW not in libcamera
    }
    function test_frontToggles() {
        compare(id(S.pick("front", list, lib, "UW", "UW")), "F")
        compare(id(S.pick("front", list, lib, "F", "UW")), "UW")
        compare(id(S.pick("front", list, lib, "F", "")), "W")
    }
    function test_frontAbsent() {
        compare(S.pick("front", [wide, uw], lib, "W", "W"), null)
        compare(S.pick("front", list, lib.slice(0, 2), "W", "W"), null)
    }
    function test_default() {
        compare(id(S.pick("default", list, lib, "UW", "UW")), "W")
        compare(id(S.pick("default", list, lib, "F", "UW")), "W")
        compare(S.pick("default", list, lib, "W", "W"), null)   // already there
        compare(S.pick("default", [], lib, "", ""), null)
        // default missing from libcamera: still the target (overlay shows error)
        compare(id(S.pick("default", list, lib.slice(1), "UW", "UW")), "W")
        compare(S.listed(lib.slice(1), "W"), false)
        compare(S.listed(lib, "W"), true)
    }
    function test_unknownKind() {
        compare(S.pick("sideways", list, lib, "W", "W"), null)
    }

    function snap(over) {
        var s = {focusDioptres: 2, autoExposure: true, exposureTime: 10000, iso: 0, colourGains: [2, 1.5]}
        for (var k in over) s[k] = over[k]
        return s
    }
    function ops(plan) { return plan.map(function (p) { return p.op }) }

    function test_planAutoWithLens() {
        var p = S.plan(snap({}), uw, wide, true)
        compare(ops(p), ["iso", "dioptres", "gains"])
        compare(p[0].value, 0)
        compare(p[1].value, 2)
        // wide / ultrawide ratio: [1.55/1, 1.04/1]
        verify(Math.abs(p[2].r - 2 * 1.55) < 1e-9)
        verify(Math.abs(p[2].b - 1.5 * 1.04) < 1e-9)
    }
    function test_planManualOrder() {
        var p = S.plan(snap({autoExposure: false, iso: 400}), wide, uw, true)
        compare(ops(p), ["iso", "exposureTime", "dioptres", "gains"])
        compare(p[0].value, 400)
        compare(p[1].value, 10000)
        verify(Math.abs(p[3].r - 2 / 1.55) < 1e-9)
        verify(Math.abs(p[3].b - 1.5 / 1.04) < 1e-9)
    }
    function test_planNoLensNoFocus() {
        compare(ops(S.plan(snap({}), wide, front, false)), ["iso", "gains"])
    }
    function test_planRawGainsWithoutRatio() {
        var p = S.plan(snap({}), uw, front, false)
        compare(p[1].r, 2); compare(p[1].b, 1.5)           // front has no wbRatio
        p = S.plan(snap({}), front, uw, true)
        compare(p[2].r, 2); compare(p[2].b, 1.5)           // source has none
    }
    function test_planNoGains() {
        compare(ops(S.plan(snap({colourGains: []}), uw, wide, true)), ["iso", "dioptres"])
        compare(ops(S.plan(snap({colourGains: [0, 0]}), uw, wide, true)), ["iso", "dioptres"])
        compare(ops(S.plan(snap({colourGains: undefined}), uw, wide, true)), ["iso", "dioptres"])
    }
    function test_planManualWithoutTimeSkipsExposure() {
        compare(ops(S.plan(snap({autoExposure: false, exposureTime: 0}), uw, wide, true)),
                ["iso", "dioptres", "gains"])
    }
    function test_planNoDioptresKnown() {
        compare(ops(S.plan(snap({focusDioptres: undefined}), uw, wide, true)), ["iso", "gains"])
    }

    function test_snapshotKeepsLastDioptresWithoutLens() {
        var st = {focusDioptres: 0, focusAvailable: false, autoExposure: true, exposureTime: 1, iso: 0, colourGains: [1, 1]}
        compare(S.snapshot(st, 3).focusDioptres, 3)         // front: keep last known
        st.focusAvailable = true; st.focusDioptres = 1.5
        compare(S.snapshot(st, 3).focusDioptres, 1.5)
    }
    function test_startFailed() {
        compare(S.startFailed(""), false)
        compare(S.startFailed("camera lacks AeEnable / ExposureTime / AnalogueGain: manual exposure off"), false)
        compare(S.startFailed("camera busy"), true)
        compare(S.startFailed("unknown camera: UW"), true)
    }
    function test_byId() {
        compare(id(S.byId(list, "UW")), "UW")
        compare(S.byId(list, "nope"), null)
    }
}
