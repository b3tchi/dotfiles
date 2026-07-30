package x11

import (
	"fmt"
	"os/exec"
	"testing"
	"time"
)

// eventCounts tallies what the flood test observed. malformed and
// asyncErrors are the two anomaly buckets the design targets ("0
// malformed, 0 unknown responses"): malformed is a GenericEvent frame that
// failed to parse as a DeviceEvent, asyncErrors is an XError frame that
// never found a checked-request waiter (conn.go's readLoop pushes those
// onto Events with Code==0 rather than dropping them). otherCoreEvents
// tallies ordinary core-protocol events the X server broadcasts to every
// client regardless of selection (e.g. MappingNotify) -- legitimate noise,
// not evidence of a stream desync, so it is logged but never asserted
// against.
type eventCounts struct {
	press, release, malformed, asyncErrors, otherCoreEvents int
}

// drainDeviceEvents classifies raw events until stop is closed, then keeps
// draining for a short grace window (events already in flight when the
// injector's process exits) before reporting the final tally on done.
func drainDeviceEvents(conn *Conn, stop <-chan struct{}, done chan<- eventCounts) {
	var c eventCounts
	classify := func(ev Event) {
		if ev.Code == 0 {
			// conn.go's readLoop only assigns Code==0 to an Error frame
			// that never found a waiter -- an async/spurious error.
			c.asyncErrors++
			return
		}
		if ev.Code != genericEventCode {
			// A legitimate core-protocol event this test didn't select
			// for (MappingNotify and friends are broadcast to every
			// client unconditionally).
			c.otherCoreEvents++
			return
		}
		dev, err := ParseDeviceEvent(ev.Raw)
		if err != nil {
			c.malformed++
			return
		}
		switch dev.EventType {
		case 2:
			c.press++
		case 3:
			c.release++
		default:
			c.otherCoreEvents++
		}
	}

	for {
		select {
		case ev := <-conn.Events:
			classify(ev)
		case <-stop:
			grace := time.After(750 * time.Millisecond)
			for {
				select {
				case ev := <-conn.Events:
					classify(ev)
				case <-grace:
					done <- c
					return
				}
			}
		}
	}
}

// resolveKeycodeForKeysym scans a keyboard mapping for the keycode row
// containing the given keysym.
func resolveKeycodeForKeysym(t *testing.T, mapping KeyboardMapping, minKeycode, maxKeycode byte, keysym uint32) byte {
	t.Helper()
	for kc := int(minKeycode); kc <= int(maxKeycode); kc++ {
		for _, s := range mapping.KeysymsForKeycode(byte(kc)) {
			if s == keysym {
				return byte(kc)
			}
		}
	}
	t.Fatalf("keysym %#x not found in keyboard mapping (keycodes %d..%d)", keysym, minKeycode, maxKeycode)
	return 0
}

// TestXI2_GrabFloodUngrab_Xvfb replicates poc015's flood criterion end to
// end: connect, resolve the XInputExtension, negotiate XI2, find the
// master keyboard and the keycode for 'a', register a passive grab across
// all four lock-bit modifier variants, inject a flood of chords via
// xdotool, and assert the event stream is coherent (0 malformed, 0
// unknown-response frames) -- then ungrab and prove nothing more arrives.
func TestXI2_GrabFloodUngrab_Xvfb(t *testing.T) {
	requireBinary(t, "Xvfb")
	requireBinary(t, "xdotool")

	dispNum := pickFreeDisplay(t)
	cleanup := startXvfb(t, dispNum)
	defer cleanup()

	display := fmt.Sprintf(":%d", dispNum)
	conn, info, err := Open(display)
	if err != nil {
		t.Fatalf("Open(%s): %v", display, err)
	}
	defer conn.Close()

	ext, err := conn.QueryExtension("XInputExtension")
	if err != nil {
		t.Fatalf("QueryExtension: %v", err)
	}
	if !ext.Present {
		t.Fatal("XInputExtension not present on this Xvfb -- cannot test XI2")
	}
	t.Logf("XInputExtension: major_opcode=%d first_event=%d first_error=%d", ext.MajorOpcode, ext.FirstEvent, ext.FirstError)

	ver, err := conn.XIQueryVersion(ext.MajorOpcode, 2, 3)
	if err != nil {
		t.Fatalf("XIQueryVersion: %v", err)
	}
	t.Logf("XI2 version negotiated: %d.%d", ver.Major, ver.Minor)

	devices, err := conn.XIQueryDevice(ext.MajorOpcode, DeviceAll)
	if err != nil {
		t.Fatalf("XIQueryDevice: %v", err)
	}
	if len(devices) == 0 {
		t.Fatal("XIQueryDevice returned no devices")
	}
	var masterKeyboard *XIDeviceInfo
	for i := range devices {
		t.Logf("device: id=%d type=%d name=%q", devices[i].DeviceID, devices[i].Type, devices[i].Name)
		if devices[i].Type == DeviceTypeMasterKeyboard {
			masterKeyboard = &devices[i]
		}
	}
	if masterKeyboard == nil {
		t.Fatal("no MasterKeyboard device found")
	}

	count := int(info.MaxKeycode) - int(info.MinKeycode) + 1
	if count <= 0 || count > 255 {
		t.Fatalf("implausible keycode range: min=%d max=%d", info.MinKeycode, info.MaxKeycode)
	}
	mapping, err := conn.GetKeyboardMapping(info.MinKeycode, byte(count))
	if err != nil {
		t.Fatalf("GetKeyboardMapping: %v", err)
	}
	t.Logf("keysyms_per_keycode = %d", mapping.KeysymsPerKeycode)

	const keysymLowerA = 0x0061 // XK_a
	keycodeA := resolveKeycodeForKeysym(t, mapping, info.MinKeycode, info.MaxKeycode, keysymLowerA)
	t.Logf("keycode for 'a' = %d", keycodeA)

	if len(info.Screens) == 0 {
		t.Fatal("setup response has no screens")
	}
	root := info.Screens[0].Root

	const mod4 = 0x40
	mods := GrabModifierVariants(mod4)
	mask := []uint32{XIEventMaskKeyPress | XIEventMaskKeyRelease}

	grabResult, err := conn.XIPassiveGrabDevice(ext.MajorOpcode, root, masterKeyboard.DeviceID, uint32(keycodeA), mods, mask)
	if err != nil {
		t.Fatalf("XIPassiveGrabDevice: %v", err)
	}
	if !grabResult.AllSucceeded() {
		t.Fatalf("XIPassiveGrabDevice: partial failure, want all four modifier variants to succeed: %+v", grabResult.Failed)
	}

	stop := make(chan struct{})
	done := make(chan eventCounts, 1)
	go drainDeviceEvents(conn, stop, done)

	const chords = 600
	injectChords(t, display, chords)

	// Give the read loop time to catch up with the flood before asking it
	// to wind down.
	time.Sleep(500 * time.Millisecond)
	close(stop)
	got := <-done

	t.Logf("flood result: press=%d release=%d malformed=%d asyncErrors=%d otherCoreEvents=%d total(press+release)=%d",
		got.press, got.release, got.malformed, got.asyncErrors, got.otherCoreEvents, got.press+got.release)

	if got.malformed != 0 {
		t.Errorf("malformed events = %d, want 0", got.malformed)
	}
	if got.asyncErrors != 0 {
		t.Errorf("async/spurious error frames = %d, want 0 (an undelivered X error means a checked request's waiter never saw its response, or the stream desynced)", got.asyncErrors)
	}
	if got.press != chords {
		t.Errorf("press events = %d, want %d (one per injected chord)", got.press, chords)
	}
	// poc015 measured a fixed, reproducible multiplier of release events
	// per press across 4 runs on this exact xdotool/Xvfb pairing (600
	// press + 1200 release = a 2:1 ratio, from xdotool's synthetic
	// modifier-release behavior). Assert the ratio is a whole, consistent
	// multiple rather than a hardcoded constant, since the multiplier is a
	// property of the injection rig, not of this package's parser -- what
	// this package must prove is that every event the rig actually sent
	// was received once, coherently, and none were dropped or duplicated.
	if got.release == 0 {
		t.Fatal("release events = 0, want > 0")
	}
	if got.release%chords != 0 {
		t.Errorf("release events = %d, not an even multiple of %d chords -- suggests dropped or duplicated events", got.release, chords)
	}
	total := got.press + got.release
	if total < chords*2 {
		t.Errorf("total events = %d, want at least %d (>= 1 press + 1 release per chord)", total, chords*2)
	}

	// Ungrab, then prove further chords are NOT delivered.
	if err := conn.XIPassiveUngrabDevice(ext.MajorOpcode, root, masterKeyboard.DeviceID, uint32(keycodeA), mods); err != nil {
		t.Fatalf("XIPassiveUngrabDevice: %v", err)
	}

	stop2 := make(chan struct{})
	done2 := make(chan eventCounts, 1)
	go drainDeviceEvents(conn, stop2, done2)
	injectChords(t, display, 3)
	time.Sleep(300 * time.Millisecond)
	close(stop2)
	afterUngrab := <-done2
	if afterUngrab.press != 0 || afterUngrab.release != 0 {
		t.Errorf("after ungrab: press=%d release=%d, want 0/0 -- ungrab did not take effect", afterUngrab.press, afterUngrab.release)
	}

	// Round-trip coherency after the flood: a few more request/reply
	// shapes must still resolve correctly (poc015's post-flood check).
	if _, err := conn.XIQueryVersion(ext.MajorOpcode, 2, 3); err != nil {
		t.Errorf("post-flood XIQueryVersion: %v", err)
	}
	if _, err := conn.XIQueryDevice(ext.MajorOpcode, DeviceAll); err != nil {
		t.Errorf("post-flood XIQueryDevice: %v", err)
	}
	if _, err := conn.QueryPointer(root); err != nil {
		t.Errorf("post-flood QueryPointer: %v", err)
	}
}

// injectChords uses xdotool to synthesize `count` Super+a chords on
// display.
func injectChords(t *testing.T, display string, count int) {
	t.Helper()
	cmd := exec.Command("xdotool", "key", "--clearmodifiers", "--repeat", fmt.Sprintf("%d", count), "--delay", "1", "super+a")
	cmd.Env = append(cmd.Environ(), "DISPLAY="+display)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("xdotool key --repeat %d super+a: %v: %s", count, err, out)
	}
}
