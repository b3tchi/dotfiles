package x11

import (
	"encoding/binary"
	"fmt"
)

// Core X11 request opcodes this package uses (xproto.xml).
const (
	opGetProperty        = 20
	opQueryPointer       = 38
	opQueryExtension     = 98
	opGetKeyboardMapping = 101
)

// AnyPropertyType is the wildcard GetProperty type value (GetPropertyType.Any).
const AnyPropertyType uint32 = 0

// boolByte encodes a Go bool as the X11 wire BOOL (1 byte: 0 or 1).
func boolByte(b bool) byte {
	if b {
		return 1
	}
	return 0
}

// putRequestHeader writes the standard 4-byte request header -- opcode,
// one data byte, and the request length in 4-byte units derived from
// len(buf) -- into the front of buf. buf must already be sized to its
// final (4-byte padded) length.
func putRequestHeader(buf []byte, opcode, data1 byte) {
	buf[0] = opcode
	buf[1] = data1
	binary.LittleEndian.PutUint16(buf[2:4], uint16(len(buf)/4))
}

// putExtRequestHeader is putRequestHeader's extension-request twin: byte 0
// is the extension's major opcode (learned from QueryExtension), byte 1 is
// the extension-specific minor opcode.
func putExtRequestHeader(buf []byte, majorOpcode, minorOpcode byte) {
	buf[0] = majorOpcode
	buf[1] = minorOpcode
	binary.LittleEndian.PutUint16(buf[2:4], uint16(len(buf)/4))
}

// doRequest sends req as a checked (sequence-correlated) request and blocks
// for its reply or error.
func (c *Conn) doRequest(req []byte) ([]byte, error) {
	_, waiter, err := c.seq.SendChecked(req)
	if err != nil {
		return nil, err
	}
	res := <-waiter
	if res.err != nil {
		// The connection died before the server answered (see
		// Sequencer.failAll) — a named failure, not a hang.
		return nil, res.err
	}
	if res.isError {
		return nil, res.xerr
	}
	return res.reply, nil
}

// ---------------------------------------------------------------------
// QueryExtension
// ---------------------------------------------------------------------

// ExtensionInfo is QueryExtension's decoded reply.
type ExtensionInfo struct {
	Present     bool
	MajorOpcode byte
	FirstEvent  byte
	FirstError  byte
}

// EncodeQueryExtension builds a QueryExtension request for the named
// extension (e.g. "XInputExtension").
func EncodeQueryExtension(name string) []byte {
	nameLen := len(name)
	buf := make([]byte, 8+nameLen+pad4(nameLen))
	putRequestHeader(buf, opQueryExtension, 0)
	binary.LittleEndian.PutUint16(buf[4:6], uint16(nameLen))
	copy(buf[8:], name)
	return buf
}

// DecodeQueryExtensionReply decodes a QueryExtension reply frame.
func DecodeQueryExtensionReply(reply []byte) (ExtensionInfo, error) {
	if len(reply) < 12 {
		return ExtensionInfo{}, fmt.Errorf("x11: QueryExtension reply too short: %d bytes", len(reply))
	}
	return ExtensionInfo{
		Present:     reply[8] != 0,
		MajorOpcode: reply[9],
		FirstEvent:  reply[10],
		FirstError:  reply[11],
	}, nil
}

// QueryExtension asks the server whether the named extension is present and,
// if so, its assigned major opcode and event/error base codes.
func (c *Conn) QueryExtension(name string) (ExtensionInfo, error) {
	reply, err := c.doRequest(EncodeQueryExtension(name))
	if err != nil {
		return ExtensionInfo{}, err
	}
	return DecodeQueryExtensionReply(reply)
}

// ---------------------------------------------------------------------
// GetKeyboardMapping
// ---------------------------------------------------------------------

// KeyboardMapping is GetKeyboardMapping's decoded reply: a flat keysym
// table, KeysymsPerKeycode wide per row. keysyms_per_keycode is NOT a fixed
// stride across servers -- Xvfb, native :0, and xrdp :10 sessions have
// measured 7, 10, and 15 respectively -- so it must always be read off the
// reply itself, never assumed.
type KeyboardMapping struct {
	KeysymsPerKeycode byte
	FirstKeycode      byte
	Keysyms           []uint32 // flat; row i (0-based) is Keysyms[i*KeysymsPerKeycode:(i+1)*KeysymsPerKeycode]
}

// KeysymsForKeycode returns the keysym row for the given keycode, or nil if
// keycode falls outside the range this mapping covers.
func (m KeyboardMapping) KeysymsForKeycode(keycode byte) []uint32 {
	if m.KeysymsPerKeycode == 0 {
		return nil
	}
	idx := int(keycode) - int(m.FirstKeycode)
	if idx < 0 {
		return nil
	}
	start := idx * int(m.KeysymsPerKeycode)
	end := start + int(m.KeysymsPerKeycode)
	if start < 0 || end > len(m.Keysyms) {
		return nil
	}
	return m.Keysyms[start:end]
}

// EncodeGetKeyboardMapping builds a GetKeyboardMapping request for `count`
// keycodes starting at firstKeycode.
func EncodeGetKeyboardMapping(firstKeycode, count byte) []byte {
	buf := make([]byte, 8)
	putRequestHeader(buf, opGetKeyboardMapping, 0)
	buf[4] = firstKeycode
	buf[5] = count
	return buf
}

// DecodeGetKeyboardMappingReply decodes a GetKeyboardMapping reply. The
// keysym count comes off the reply's own length field (KEYSYM is 4 bytes,
// so the length-in-4-byte-units field IS the keysym count) -- never off a
// stride computed from the request's `count` and an assumed
// keysyms_per_keycode.
func DecodeGetKeyboardMappingReply(reply []byte, firstKeycode byte) (KeyboardMapping, error) {
	if len(reply) < 32 {
		return KeyboardMapping{}, fmt.Errorf("x11: GetKeyboardMapping reply too short: %d bytes", len(reply))
	}
	keysymsPerKeycode := reply[1]
	numKeysyms := int(binary.LittleEndian.Uint32(reply[4:8]))
	need := 32 + numKeysyms*4
	if len(reply) < need {
		return KeyboardMapping{}, fmt.Errorf("x11: GetKeyboardMapping reply declares %d keysyms (%d bytes) but only has %d bytes total", numKeysyms, numKeysyms*4, len(reply)-32)
	}
	keysyms := make([]uint32, numKeysyms)
	for i := 0; i < numKeysyms; i++ {
		keysyms[i] = binary.LittleEndian.Uint32(reply[32+i*4:])
	}
	return KeyboardMapping{
		KeysymsPerKeycode: keysymsPerKeycode,
		FirstKeycode:      firstKeycode,
		Keysyms:           keysyms,
	}, nil
}

// GetKeyboardMapping fetches the keysym table for `count` keycodes starting
// at firstKeycode.
func (c *Conn) GetKeyboardMapping(firstKeycode, count byte) (KeyboardMapping, error) {
	reply, err := c.doRequest(EncodeGetKeyboardMapping(firstKeycode, count))
	if err != nil {
		return KeyboardMapping{}, err
	}
	return DecodeGetKeyboardMappingReply(reply, firstKeycode)
}

// ---------------------------------------------------------------------
// GetProperty
// ---------------------------------------------------------------------

// PropertyReply is GetProperty's decoded reply.
type PropertyReply struct {
	Format     byte // 0 (no property), 8, 16, or 32
	Type       uint32
	BytesAfter uint32
	Value      []byte // raw bytes, length == value_len (FORMAT units) * (Format/8)
}

// EncodeGetProperty builds a GetProperty request. longOffset and
// longLength are both in 4-byte units, per the X11 wire protocol,
// regardless of the property's format.
func EncodeGetProperty(deleteProp bool, window, property, propertyType uint32, longOffset, longLength uint32) []byte {
	buf := make([]byte, 24)
	putRequestHeader(buf, opGetProperty, boolByte(deleteProp))
	binary.LittleEndian.PutUint32(buf[4:8], window)
	binary.LittleEndian.PutUint32(buf[8:12], property)
	binary.LittleEndian.PutUint32(buf[12:16], propertyType)
	binary.LittleEndian.PutUint32(buf[16:20], longOffset)
	binary.LittleEndian.PutUint32(buf[20:24], longLength)
	return buf
}

// DecodeGetPropertyReply decodes a GetProperty reply. value_len is in
// FORMAT UNITS (8/16/32-bit quantities), not bytes -- for format=8 the two
// coincide, which hides the bug until a 32-bit property is read (poc015
// gotcha 6).
func DecodeGetPropertyReply(reply []byte) (PropertyReply, error) {
	if len(reply) < 32 {
		return PropertyReply{}, fmt.Errorf("x11: GetProperty reply too short: %d bytes", len(reply))
	}
	format := reply[1]
	typ := binary.LittleEndian.Uint32(reply[8:12])
	bytesAfter := binary.LittleEndian.Uint32(reply[12:16])
	valueLenUnits := binary.LittleEndian.Uint32(reply[16:20])

	var valueBytes int
	if format != 0 {
		valueBytes = int(valueLenUnits) * (int(format) / 8)
	}
	if 32+valueBytes > len(reply) {
		return PropertyReply{}, fmt.Errorf("x11: GetProperty reply declares %d value bytes (value_len=%d units, format=%d) but only has %d bytes total", valueBytes, valueLenUnits, format, len(reply)-32)
	}
	value := make([]byte, valueBytes)
	copy(value, reply[32:32+valueBytes])

	return PropertyReply{Format: format, Type: typ, BytesAfter: bytesAfter, Value: value}, nil
}

// GetProperty performs a single GetProperty round trip. Callers that need
// the whole property regardless of size should use GetPropertyAll instead,
// which loops on BytesAfter.
func (c *Conn) GetProperty(deleteProp bool, window, property, propertyType uint32, longOffset, longLength uint32) (PropertyReply, error) {
	reply, err := c.doRequest(EncodeGetProperty(deleteProp, window, property, propertyType, longOffset, longLength))
	if err != nil {
		return PropertyReply{}, err
	}
	return DecodeGetPropertyReply(reply)
}

// getPropertyChunkUnits is the long_length (in 4-byte units) requested per
// round trip -- generous enough that most properties (RESOURCE_MANAGER
// included) resolve in one call, while the loop below still handles the
// case where they don't.
const getPropertyChunkUnits = 0x10000

// propertyFetcher matches Conn.GetProperty's shape; a seam so the
// BytesAfter loop is unit-testable without a live connection.
type propertyFetcher func(longOffset, longLength uint32) (PropertyReply, error)

// getPropertyAll loops on BytesAfter, advancing long_offset in 4-byte
// units, until the whole property has been retrieved. A property spanning
// more than one reply (RESOURCE_MANAGER on a populated xrdb database is the
// measured case, poc015 gotcha 7) is otherwise silently truncated by a
// single-shot GetProperty.
func getPropertyAll(fetch propertyFetcher, propertyType uint32) (format byte, typ uint32, value []byte, err error) {
	var offset uint32
	for {
		rep, err := fetch(offset, getPropertyChunkUnits)
		if err != nil {
			return 0, 0, nil, err
		}
		format = rep.Format
		typ = rep.Type
		value = append(value, rep.Value...)
		if rep.BytesAfter == 0 {
			return format, typ, value, nil
		}
		unitsRead := uint32(len(rep.Value)+3) / 4
		if unitsRead == 0 {
			return 0, 0, nil, fmt.Errorf("x11: GetProperty BytesAfter=%d but zero bytes returned this round -- refusing to loop forever", rep.BytesAfter)
		}
		offset += unitsRead
	}
}

// GetPropertyAll fetches the entire property value, looping over multiple
// GetProperty round trips if the server reports BytesAfter > 0.
func (c *Conn) GetPropertyAll(window, property, propertyType uint32) (format byte, typ uint32, value []byte, err error) {
	return getPropertyAll(func(offset, length uint32) (PropertyReply, error) {
		return c.GetProperty(false, window, property, propertyType, offset, length)
	}, propertyType)
}

// ---------------------------------------------------------------------
// QueryPointer
// ---------------------------------------------------------------------

// PointerInfo is QueryPointer's decoded reply.
type PointerInfo struct {
	SameScreen   bool
	Root, Child  uint32
	RootX, RootY int16
	WinX, WinY   int16
	Mask         uint16
}

// EncodeQueryPointer builds a QueryPointer request against window.
func EncodeQueryPointer(window uint32) []byte {
	buf := make([]byte, 8)
	putRequestHeader(buf, opQueryPointer, 0)
	binary.LittleEndian.PutUint32(buf[4:8], window)
	return buf
}

// DecodeQueryPointerReply decodes a QueryPointer reply. root_x/root_y/
// win_x/win_y are core-protocol INT16 (already signed on the wire, unlike
// XI2's FP1616), so a straight int16 cast is correct here.
func DecodeQueryPointerReply(reply []byte) (PointerInfo, error) {
	if len(reply) < 26 {
		return PointerInfo{}, fmt.Errorf("x11: QueryPointer reply too short: %d bytes", len(reply))
	}
	return PointerInfo{
		SameScreen: reply[1] != 0,
		Root:       binary.LittleEndian.Uint32(reply[8:12]),
		Child:      binary.LittleEndian.Uint32(reply[12:16]),
		RootX:      int16(binary.LittleEndian.Uint16(reply[16:18])),
		RootY:      int16(binary.LittleEndian.Uint16(reply[18:20])),
		WinX:       int16(binary.LittleEndian.Uint16(reply[20:22])),
		WinY:       int16(binary.LittleEndian.Uint16(reply[22:24])),
		Mask:       binary.LittleEndian.Uint16(reply[24:26]),
	}, nil
}

// QueryPointer returns the pointer's current position relative to window.
func (c *Conn) QueryPointer(window uint32) (PointerInfo, error) {
	reply, err := c.doRequest(EncodeQueryPointer(window))
	if err != nil {
		return PointerInfo{}, err
	}
	return DecodeQueryPointerReply(reply)
}
