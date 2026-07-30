package x11

import (
	"encoding/binary"
	"fmt"
	"math/bits"
)

// KeyEventFlags bits (xinput.xml enum KeyEventFlags).
const XIKeyRepeat uint32 = 1 << 16

// ModifierState mirrors the wire ModifierInfo struct (4 CARD32 fields).
type ModifierState struct {
	Base, Latched, Locked, Effective uint32
}

// GroupState mirrors the wire GroupInfo struct (4 CARD8 fields).
type GroupState struct {
	Base, Latched, Locked, Effective byte
}

// DeviceEvent is a parsed XIDeviceEvent GenericEvent payload -- the shape
// shared by XI_KeyPress/XI_KeyRelease (and the pointer/touch events, though
// hotkeyd only ever dispatches key events). EventType carries the GE
// evtype (2=KeyPress, 3=KeyRelease) so callers can tell them apart.
type DeviceEvent struct {
	EventType uint16
	DeviceID  uint16
	Time      uint32
	Detail    uint32 // keycode for key events
	Root      uint32
	Event     uint32
	Child     uint32
	RootX     float64 // FP1616, SIGNED
	RootY     float64
	EventX    float64
	EventY    float64
	// SourceID is the physical SLAVE device that generated this event.
	// Attribution must read this field, never the header's DeviceID (the
	// MASTER) -- reading DeviceID reports every keyboard as "Virtual core
	// keyboard" (ft011).
	SourceID     uint16
	Flags        uint32
	Repeat       bool // XIKeyRepeat flag surfaced
	Mods         ModifierState
	Group        GroupState
	ButtonMask   []uint32
	ValuatorMask []uint32
	AxisValues   []float64 // FP3232, SIGNED; one per set bit in ValuatorMask
}

// fp1616 converts a raw wire CARD32 to a signed 16.16 fixed-point value.
// Casting through uint32 before dividing silently discards the sign for
// negative coordinates (e.g. a pointer left of or above the primary
// monitor) -- poc015's gotcha. The cast to int32 must happen FIRST.
func fp1616(raw uint32) float64 {
	return float64(int32(raw)) / 65536.0
}

// fp3232 converts a raw wire (integral INT32, frac CARD32) pair to a signed
// value.
func fp3232(integral int32, frac uint32) float64 {
	return float64(integral) + float64(frac)/4294967296.0
}

// popcountWords returns the total number of set bits across words --
// axisvalues has exactly popcount(valuator_mask) entries per xinput.xml.
func popcountWords(words []uint32) int {
	n := 0
	for _, w := range words {
		n += bits.OnesCount32(w)
	}
	return n
}

// ParseDeviceEvent decodes a GenericEvent's XIDeviceEvent payload from raw,
// the full wire frame (32-byte GE header + extra data) as delivered by the
// read loop (see read.go's readFrame, which already handles the
// length*4-byte extension poc014 needed). The frame's true length is
// variable via buttons_len/valuators_len -- this parser never assumes a
// fixed size (poc015 measured 120 bytes for ONE particular case, not a
// universal constant). The walk is verified by arrival: off must land
// exactly on len(raw), or this returns an error rather than trusting a
// misaligned parse.
func ParseDeviceEvent(raw []byte) (DeviceEvent, error) {
	const fixedLen = 80 // through the end of GroupInfo (offset 32..79), before the variable lists
	if len(raw) < fixedLen {
		return DeviceEvent{}, fmt.Errorf("x11: DeviceEvent frame too short: %d bytes, need at least %d", len(raw), fixedLen)
	}

	var ev DeviceEvent
	ev.EventType = binary.LittleEndian.Uint16(raw[8:10])
	ev.DeviceID = binary.LittleEndian.Uint16(raw[10:12])
	ev.Time = binary.LittleEndian.Uint32(raw[12:16])
	ev.Detail = binary.LittleEndian.Uint32(raw[16:20])
	ev.Root = binary.LittleEndian.Uint32(raw[20:24])
	ev.Event = binary.LittleEndian.Uint32(raw[24:28])
	ev.Child = binary.LittleEndian.Uint32(raw[28:32])
	ev.RootX = fp1616(binary.LittleEndian.Uint32(raw[32:36]))
	ev.RootY = fp1616(binary.LittleEndian.Uint32(raw[36:40]))
	ev.EventX = fp1616(binary.LittleEndian.Uint32(raw[40:44]))
	ev.EventY = fp1616(binary.LittleEndian.Uint32(raw[44:48]))
	buttonsLen := int(binary.LittleEndian.Uint16(raw[48:50]))   // count of CARD32 WORDS, not bytes
	valuatorsLen := int(binary.LittleEndian.Uint16(raw[50:52])) // count of CARD32 WORDS, not bytes
	ev.SourceID = binary.LittleEndian.Uint16(raw[52:54])
	// raw[54:56] pad
	ev.Flags = binary.LittleEndian.Uint32(raw[56:60])
	ev.Repeat = ev.Flags&XIKeyRepeat != 0
	ev.Mods = ModifierState{
		Base:      binary.LittleEndian.Uint32(raw[60:64]),
		Latched:   binary.LittleEndian.Uint32(raw[64:68]),
		Locked:    binary.LittleEndian.Uint32(raw[68:72]),
		Effective: binary.LittleEndian.Uint32(raw[72:76]),
	}
	ev.Group = GroupState{
		Base:      raw[76],
		Latched:   raw[77],
		Locked:    raw[78],
		Effective: raw[79],
	}

	off := fixedLen

	buttonMaskBytes := buttonsLen * 4
	if off+buttonMaskBytes > len(raw) {
		return DeviceEvent{}, fmt.Errorf("x11: DeviceEvent button_mask (%d words) overruns frame: have %d bytes remaining, need %d", buttonsLen, len(raw)-off, buttonMaskBytes)
	}
	ev.ButtonMask = make([]uint32, buttonsLen)
	for i := 0; i < buttonsLen; i++ {
		ev.ButtonMask[i] = binary.LittleEndian.Uint32(raw[off+i*4:])
	}
	off += buttonMaskBytes

	valuatorMaskBytes := valuatorsLen * 4
	if off+valuatorMaskBytes > len(raw) {
		return DeviceEvent{}, fmt.Errorf("x11: DeviceEvent valuator_mask (%d words) overruns frame: have %d bytes remaining, need %d", valuatorsLen, len(raw)-off, valuatorMaskBytes)
	}
	ev.ValuatorMask = make([]uint32, valuatorsLen)
	for i := 0; i < valuatorsLen; i++ {
		ev.ValuatorMask[i] = binary.LittleEndian.Uint32(raw[off+i*4:])
	}
	off += valuatorMaskBytes

	numAxes := popcountWords(ev.ValuatorMask)
	axisBytes := numAxes * 8 // FP3232 is 8 bytes: INT32 integral + CARD32 frac
	if off+axisBytes > len(raw) {
		return DeviceEvent{}, fmt.Errorf("x11: DeviceEvent axisvalues (%d values) overruns frame: have %d bytes remaining, need %d", numAxes, len(raw)-off, axisBytes)
	}
	ev.AxisValues = make([]float64, numAxes)
	for i := 0; i < numAxes; i++ {
		integral := int32(binary.LittleEndian.Uint32(raw[off+i*8:]))
		frac := binary.LittleEndian.Uint32(raw[off+i*8+4:])
		ev.AxisValues[i] = fp3232(integral, frac)
	}
	off += axisBytes

	if off != len(raw) {
		return DeviceEvent{}, fmt.Errorf("x11: DeviceEvent parse consumed %d bytes but frame is %d bytes -- refusing to trust a misaligned parse", off, len(raw))
	}

	return ev, nil
}
