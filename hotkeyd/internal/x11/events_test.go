package x11

import (
	"encoding/binary"
	"testing"
)

// buildDeviceEventFrame constructs a raw GenericEvent frame carrying an
// XIDeviceEvent (XI_KeyPress/XI_KeyRelease shape) payload, honouring the
// variable-length buttons_len/valuators_len/axisvalues layout.
func buildDeviceEventFrame(t *testing.T, opts struct {
	evtype             uint16
	deviceID           uint16
	time, detail       uint32
	root, event, child uint32
	rootX, rootY       int32 // raw FP1616 wire value
	eventX, eventY     int32
	sourceID           uint16
	flags              uint32
	buttonMask         []uint32
	valuatorMask       []uint32
	axisIntegral       []int32
	axisFrac           []uint32
}) []byte {
	t.Helper()
	extra := 48 + len(opts.buttonMask)*4 + len(opts.valuatorMask)*4 + len(opts.axisIntegral)*8
	if extra%4 != 0 {
		t.Fatalf("test fixture bug: extra=%d not 4-aligned", extra)
	}
	frame := make([]byte, 32+extra)
	frame[0] = genericEventCode
	frame[1] = 131 // extension major opcode
	binary.LittleEndian.PutUint32(frame[4:8], uint32(extra/4))
	binary.LittleEndian.PutUint16(frame[8:10], opts.evtype)
	binary.LittleEndian.PutUint16(frame[10:12], opts.deviceID)
	binary.LittleEndian.PutUint32(frame[12:16], opts.time)
	binary.LittleEndian.PutUint32(frame[16:20], opts.detail)
	binary.LittleEndian.PutUint32(frame[20:24], opts.root)
	binary.LittleEndian.PutUint32(frame[24:28], opts.event)
	binary.LittleEndian.PutUint32(frame[28:32], opts.child)
	binary.LittleEndian.PutUint32(frame[32:36], uint32(opts.rootX))
	binary.LittleEndian.PutUint32(frame[36:40], uint32(opts.rootY))
	binary.LittleEndian.PutUint32(frame[40:44], uint32(opts.eventX))
	binary.LittleEndian.PutUint32(frame[44:48], uint32(opts.eventY))
	binary.LittleEndian.PutUint16(frame[48:50], uint16(len(opts.buttonMask)))
	binary.LittleEndian.PutUint16(frame[50:52], uint16(len(opts.valuatorMask)))
	binary.LittleEndian.PutUint16(frame[52:54], opts.sourceID)
	binary.LittleEndian.PutUint32(frame[56:60], opts.flags)
	// mods (60:76), group (76:80) left zero for these fixtures.

	off := 80
	for _, w := range opts.buttonMask {
		binary.LittleEndian.PutUint32(frame[off:], w)
		off += 4
	}
	for _, w := range opts.valuatorMask {
		binary.LittleEndian.PutUint32(frame[off:], w)
		off += 4
	}
	if len(opts.axisIntegral) != len(opts.axisFrac) {
		t.Fatalf("test fixture bug: axisIntegral/axisFrac length mismatch")
	}
	for i := range opts.axisIntegral {
		binary.LittleEndian.PutUint32(frame[off:], uint32(opts.axisIntegral[i]))
		off += 4
		binary.LittleEndian.PutUint32(frame[off:], opts.axisFrac[i])
		off += 4
	}
	if off != len(frame) {
		t.Fatalf("test fixture bug: built %d bytes, wrote up to offset %d", len(frame), off)
	}
	return frame
}

func TestParseDeviceEvent_BasicKeyPress(t *testing.T) {
	frame := buildDeviceEventFrame(t, struct {
		evtype             uint16
		deviceID           uint16
		time, detail       uint32
		root, event, child uint32
		rootX, rootY       int32
		eventX, eventY     int32
		sourceID           uint16
		flags              uint32
		buttonMask         []uint32
		valuatorMask       []uint32
		axisIntegral       []int32
		axisFrac           []uint32
	}{
		evtype: 2, deviceID: 3, time: 12345, detail: 38,
		root: 0x100, event: 0x200, child: 0,
		rootX: 100 << 16, rootY: 200 << 16, eventX: 50 << 16, eventY: 60 << 16,
		sourceID: 12, flags: 0,
	})

	ev, err := ParseDeviceEvent(frame)
	if err != nil {
		t.Fatalf("ParseDeviceEvent: %v", err)
	}
	if ev.EventType != 2 {
		t.Errorf("EventType = %d, want 2", ev.EventType)
	}
	if ev.DeviceID != 3 {
		t.Errorf("DeviceID = %d, want 3", ev.DeviceID)
	}
	if ev.Detail != 38 {
		t.Errorf("Detail = %d, want 38", ev.Detail)
	}
	if ev.SourceID != 12 {
		t.Errorf("SourceID = %d, want 12 -- attribution must read sourceid, not the header deviceid", ev.SourceID)
	}
	if ev.RootX != 100 {
		t.Errorf("RootX = %v, want 100", ev.RootX)
	}
	if ev.RootY != 200 {
		t.Errorf("RootY = %v, want 200", ev.RootY)
	}
	if ev.Repeat {
		t.Error("Repeat = true, want false (flags=0)")
	}
}

// TestParseDeviceEvent_FP1616Signed_NegativeCoords is poc015's FP1616
// gotcha: casting the raw wire value through uint32 before dividing
// silently discards the sign for a pointer left of or above the primary
// monitor. A mutant using float64(uint32(v))/65536 instead of
// float64(int32(v))/65536 produces a huge positive number here instead of
// -50.
func TestParseDeviceEvent_FP1616Signed_NegativeCoords(t *testing.T) {
	frame := buildDeviceEventFrame(t, struct {
		evtype             uint16
		deviceID           uint16
		time, detail       uint32
		root, event, child uint32
		rootX, rootY       int32
		eventX, eventY     int32
		sourceID           uint16
		flags              uint32
		buttonMask         []uint32
		valuatorMask       []uint32
		axisIntegral       []int32
		axisFrac           []uint32
	}{
		evtype: 2, deviceID: 3,
		rootX: -50 << 16, rootY: -1 << 16, // pointer left of and above the monitor
		eventX: -3 << 16, eventY: 0,
	})

	ev, err := ParseDeviceEvent(frame)
	if err != nil {
		t.Fatalf("ParseDeviceEvent: %v", err)
	}
	if ev.RootX != -50 {
		t.Fatalf("RootX = %v, want -50 -- FP1616 must be treated as SIGNED", ev.RootX)
	}
	if ev.RootY != -1 {
		t.Fatalf("RootY = %v, want -1 -- FP1616 must be treated as SIGNED", ev.RootY)
	}
	if ev.EventX != -3 {
		t.Fatalf("EventX = %v, want -3", ev.EventX)
	}
	// Sanity: a huge positive number (what an unsigned cast would produce)
	// must never appear here.
	if ev.RootX > 0 || ev.RootY > 0 {
		t.Fatalf("RootX/RootY came out positive (%v, %v) -- looks like an unsigned FP1616 cast", ev.RootX, ev.RootY)
	}
}

func TestParseDeviceEvent_XIKeyRepeatFlagSurfaced(t *testing.T) {
	base := func(flags uint32) []byte {
		return buildDeviceEventFrame(t, struct {
			evtype             uint16
			deviceID           uint16
			time, detail       uint32
			root, event, child uint32
			rootX, rootY       int32
			eventX, eventY     int32
			sourceID           uint16
			flags              uint32
			buttonMask         []uint32
			valuatorMask       []uint32
			axisIntegral       []int32
			axisFrac           []uint32
		}{evtype: 2, deviceID: 3, flags: flags})
	}

	notRepeat, err := ParseDeviceEvent(base(0))
	if err != nil {
		t.Fatalf("ParseDeviceEvent: %v", err)
	}
	if notRepeat.Repeat {
		t.Error("Repeat = true for flags=0, want false")
	}

	repeat, err := ParseDeviceEvent(base(XIKeyRepeat))
	if err != nil {
		t.Fatalf("ParseDeviceEvent: %v", err)
	}
	if !repeat.Repeat {
		t.Error("Repeat = false for flags=XIKeyRepeat, want true")
	}
}

// TestParseDeviceEvent_VariableLength_NeverAssume120Bytes is the design's
// headline DeviceEvent edge case: buttons_len/valuators_len drive the
// frame's true length, which varies. A mutant that hardcodes 120 bytes (or
// any fixed size) either truncates a bigger frame or misreads padding as
// data on a smaller one.
func TestParseDeviceEvent_VariableLength_NeverAssume120Bytes(t *testing.T) {
	tests := []struct {
		name         string
		buttonMask   []uint32
		valuatorMask []uint32
		axisIntegral []int32
		axisFrac     []uint32
	}{
		{name: "no_buttons_no_valuators"},
		{name: "one_button_word", buttonMask: []uint32{0x2}},
		{
			name:         "buttons_and_two_axes",
			buttonMask:   []uint32{0x4, 0x0},
			valuatorMask: []uint32{0x3}, // bits 0 and 1 set -> 2 axis values
			axisIntegral: []int32{5, -7},
			axisFrac:     []uint32{0, 0x8000_0000},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			frame := buildDeviceEventFrame(t, struct {
				evtype             uint16
				deviceID           uint16
				time, detail       uint32
				root, event, child uint32
				rootX, rootY       int32
				eventX, eventY     int32
				sourceID           uint16
				flags              uint32
				buttonMask         []uint32
				valuatorMask       []uint32
				axisIntegral       []int32
				axisFrac           []uint32
			}{
				evtype: 2, deviceID: 3,
				buttonMask: tc.buttonMask, valuatorMask: tc.valuatorMask,
				axisIntegral: tc.axisIntegral, axisFrac: tc.axisFrac,
			})

			// This frame is deliberately NOT 120 bytes for two of the three
			// cases -- proving the parser doesn't assume a fixed size.
			if tc.name == "no_buttons_no_valuators" && len(frame) == 120 {
				t.Fatalf("test fixture bug: expected a non-120-byte frame")
			}

			ev, err := ParseDeviceEvent(frame)
			if err != nil {
				t.Fatalf("ParseDeviceEvent: %v", err)
			}
			if len(ev.ButtonMask) != len(tc.buttonMask) {
				t.Fatalf("len(ButtonMask) = %d, want %d", len(ev.ButtonMask), len(tc.buttonMask))
			}
			if len(ev.ValuatorMask) != len(tc.valuatorMask) {
				t.Fatalf("len(ValuatorMask) = %d, want %d", len(ev.ValuatorMask), len(tc.valuatorMask))
			}
			if len(ev.AxisValues) != len(tc.axisIntegral) {
				t.Fatalf("len(AxisValues) = %d, want %d", len(ev.AxisValues), len(tc.axisIntegral))
			}
		})
	}
}

// TestParseDeviceEvent_ButtonsLenValuatorsLen_AreWordCountsNotByteCounts
// proves buttons_len/valuators_len are counted in 4-byte CARD32 words, not
// bytes -- a mutant that reads the mask arrays as N bytes (rather than N
// words = 4N bytes) misparses everything after the first mask word.
func TestParseDeviceEvent_ButtonsLenValuatorsLen_AreWordCountsNotByteCounts(t *testing.T) {
	buttonMask := []uint32{0x1, 0x2, 0x3} // 3 words = 12 bytes, NOT 3 bytes
	frame := buildDeviceEventFrame(t, struct {
		evtype             uint16
		deviceID           uint16
		time, detail       uint32
		root, event, child uint32
		rootX, rootY       int32
		eventX, eventY     int32
		sourceID           uint16
		flags              uint32
		buttonMask         []uint32
		valuatorMask       []uint32
		axisIntegral       []int32
		axisFrac           []uint32
	}{evtype: 2, deviceID: 3, buttonMask: buttonMask})

	ev, err := ParseDeviceEvent(frame)
	if err != nil {
		t.Fatalf("ParseDeviceEvent: %v", err)
	}
	if len(ev.ButtonMask) != 3 {
		t.Fatalf("len(ButtonMask) = %d, want 3", len(ev.ButtonMask))
	}
	for i, want := range buttonMask {
		if ev.ButtonMask[i] != want {
			t.Fatalf("ButtonMask[%d] = %#x, want %#x", i, ev.ButtonMask[i], want)
		}
	}
}

func TestParseDeviceEvent_AxisValues_FP3232Signed(t *testing.T) {
	frame := buildDeviceEventFrame(t, struct {
		evtype             uint16
		deviceID           uint16
		time, detail       uint32
		root, event, child uint32
		rootX, rootY       int32
		eventX, eventY     int32
		sourceID           uint16
		flags              uint32
		buttonMask         []uint32
		valuatorMask       []uint32
		axisIntegral       []int32
		axisFrac           []uint32
	}{
		evtype: 2, deviceID: 3,
		valuatorMask: []uint32{0x1}, // 1 bit set -> 1 axis value
		axisIntegral: []int32{-3},
		axisFrac:     []uint32{0},
	})

	ev, err := ParseDeviceEvent(frame)
	if err != nil {
		t.Fatalf("ParseDeviceEvent: %v", err)
	}
	if len(ev.AxisValues) != 1 {
		t.Fatalf("len(AxisValues) = %d, want 1", len(ev.AxisValues))
	}
	if ev.AxisValues[0] != -3 {
		t.Fatalf("AxisValues[0] = %v, want -3", ev.AxisValues[0])
	}
}

// TestParseDeviceEvent_MaskOverrunsFrame_Errors is the design's edge case
// twin to the DeviceClass overrun case in XIQueryDevice: a frame whose
// declared buttons_len/valuators_len would run past the actual frame data
// must error, never read garbage past the end.
func TestParseDeviceEvent_MaskOverrunsFrame_Errors(t *testing.T) {
	frame := buildDeviceEventFrame(t, struct {
		evtype             uint16
		deviceID           uint16
		time, detail       uint32
		root, event, child uint32
		rootX, rootY       int32
		eventX, eventY     int32
		sourceID           uint16
		flags              uint32
		buttonMask         []uint32
		valuatorMask       []uint32
		axisIntegral       []int32
		axisFrac           []uint32
	}{evtype: 2, deviceID: 3})

	// Lie about buttons_len after the fact: claim 10 words are present when
	// none are.
	binary.LittleEndian.PutUint16(frame[48:50], 10)

	if _, err := ParseDeviceEvent(frame); err == nil {
		t.Fatal("ParseDeviceEvent: want error for buttons_len overrunning the frame, got nil")
	}
}

func TestParseDeviceEvent_TooShort_Errors(t *testing.T) {
	if _, err := ParseDeviceEvent(make([]byte, 40)); err == nil {
		t.Fatal("ParseDeviceEvent: want error for a too-short frame, got nil")
	}
}
