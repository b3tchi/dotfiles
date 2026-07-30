package x11

import (
	"encoding/binary"
	"fmt"
)

// XI2 extension request minor opcodes (xinput.xml). The major opcode is
// server-assigned at runtime and learned via QueryExtension("XInputExtension").
const (
	xiMinorSelectEvents        = 46
	xiMinorQueryVersion        = 47
	xiMinorQueryDevice         = 48
	xiMinorPassiveGrabDevice   = 54
	xiMinorPassiveUngrabDevice = 55
)

// Device is the XI2 "wildcard" deviceid pseudo-values (xinput.xml enum
// Device), used with XIQueryDevice to enumerate more than one device at
// once.
const (
	DeviceAll       uint16 = 0
	DeviceAllMaster uint16 = 1
)

// DeviceType values (xinput.xml enum DeviceType).
const (
	DeviceTypeMasterPointer  uint16 = 1
	DeviceTypeMasterKeyboard uint16 = 2
	DeviceTypeSlavePointer   uint16 = 3
	DeviceTypeSlaveKeyboard  uint16 = 4
	DeviceTypeFloatingSlave  uint16 = 5
)

// DeviceClassType values (xinput.xml enum DeviceClassType). This package
// only decodes enough of a DeviceClass to identify and skip it -- device
// attribution (what hotkeyd needs XIQueryDevice for) does not require
// axis/button/valuator payload detail.
const (
	DeviceClassKey      uint16 = 0
	DeviceClassButton   uint16 = 1
	DeviceClassValuator uint16 = 2
	DeviceClassScroll   uint16 = 3
	DeviceClassTouch    uint16 = 8
	DeviceClassGesture  uint16 = 9
)

// GrabType selects what XIPassiveGrabDevice/XIPassiveUngrabDevice grabs on.
// GrabTypeKeycode is 1, NOT 0: 0 is GrabTypeButton, and passing the wrong
// constant here does not error -- it silently grabs a *button* with the
// keycode's numeric value as its button number (poc014's headline gotcha:
// "trust the XML, not prose").
const (
	GrabTypeButton  byte = 0
	GrabTypeKeycode byte = 1
	GrabTypeEnter   byte = 2
	GrabTypeFocusIn byte = 3
)

// GrabMode22 values for XIPassiveGrabDevice's grab_type field (xinput.xml
// enum GrabMode22).
const (
	GrabMode22Sync  byte = 0
	GrabMode22Async byte = 1
)

// GrabMode values for the paired_device_mode field (xinput.xml enum
// GrabMode, shared with the core-protocol grab requests).
const (
	GrabModeSync  byte = 0
	GrabModeAsync byte = 1
)

// Lock-bit modifiers a passive keycode grab must register alongside the
// intended base modifier. NumLock (Mod2) and CapsLock (Lock) change the
// reported modifier STATE without the user having pressed them as part of
// the chord, so a grab registered on the base modifier alone silently stops
// matching the instant either lock is toggled on.
const (
	ModMaskLock uint32 = 0x02
	ModMaskMod2 uint32 = 0x10
)

// GrabModifierVariants returns the four lock-bit variants a single
// XIPassiveGrabDevice call should register for a base modifier mask: the
// base alone, base|Lock, base|Mod2, and base|Lock|Mod2 (sp021's named
// execution scope, carried over from poc015's recommendation).
func GrabModifierVariants(base uint32) []uint32 {
	return []uint32{
		base,
		base | ModMaskLock,
		base | ModMaskMod2,
		base | ModMaskLock | ModMaskMod2,
	}
}

// XIEventMask bits this package names (xinput.xml enum XIEventMask). Only
// the ones hotkeyd actually selects are given names here.
const (
	XIEventMaskDeviceChanged uint32 = 1 << 1
	XIEventMaskKeyPress      uint32 = 1 << 2
	XIEventMaskKeyRelease    uint32 = 1 << 3
	XIEventMaskHierarchy     uint32 = 1 << 11
)

// ---------------------------------------------------------------------
// XIQueryVersion
// ---------------------------------------------------------------------

// XIVersion is XIQueryVersion's decoded reply.
type XIVersion struct {
	Major, Minor uint16
}

// EncodeXIQueryVersion builds an XIQueryVersion request. majorOpcode is the
// XInputExtension major opcode learned from QueryExtension.
func EncodeXIQueryVersion(majorOpcode byte, major, minor uint16) []byte {
	buf := make([]byte, 8)
	putExtRequestHeader(buf, majorOpcode, xiMinorQueryVersion)
	binary.LittleEndian.PutUint16(buf[4:6], major)
	binary.LittleEndian.PutUint16(buf[6:8], minor)
	return buf
}

// DecodeXIQueryVersionReply decodes an XIQueryVersion reply.
func DecodeXIQueryVersionReply(reply []byte) (XIVersion, error) {
	if len(reply) < 12 {
		return XIVersion{}, fmt.Errorf("x11: XIQueryVersion reply too short: %d bytes", len(reply))
	}
	return XIVersion{
		Major: binary.LittleEndian.Uint16(reply[8:10]),
		Minor: binary.LittleEndian.Uint16(reply[10:12]),
	}, nil
}

// XIQueryVersion negotiates the XI2 protocol version with the server.
func (c *Conn) XIQueryVersion(majorOpcode byte, major, minor uint16) (XIVersion, error) {
	reply, err := c.doRequest(EncodeXIQueryVersion(majorOpcode, major, minor))
	if err != nil {
		return XIVersion{}, err
	}
	return DecodeXIQueryVersionReply(reply)
}

// ---------------------------------------------------------------------
// XIQueryDevice
// ---------------------------------------------------------------------

// DeviceClass is the header common to every wire DeviceClass variant:
// enough to identify and skip it. hotkeyd's device attribution only needs
// Type and SourceID, never axis/button/valuator payload detail.
type DeviceClass struct {
	Type     uint16
	SourceID uint16
}

// XIDeviceInfo is one XIQueryDevice reply entry.
type XIDeviceInfo struct {
	DeviceID   uint16
	Type       uint16
	Attachment uint16
	Enabled    bool
	Name       string
	Classes    []DeviceClass
}

// EncodeXIQueryDevice builds an XIQueryDevice request. deviceid may be a
// concrete device id or one of the DeviceAll/DeviceAllMaster wildcards.
func EncodeXIQueryDevice(majorOpcode byte, deviceid uint16) []byte {
	buf := make([]byte, 8)
	putExtRequestHeader(buf, majorOpcode, xiMinorQueryDevice)
	binary.LittleEndian.PutUint16(buf[4:6], deviceid)
	return buf
}

// DecodeXIQueryDeviceReply decodes an XIQueryDevice reply's device list.
func DecodeXIQueryDeviceReply(reply []byte) ([]XIDeviceInfo, error) {
	if len(reply) < 32 {
		return nil, fmt.Errorf("x11: XIQueryDevice reply too short: %d bytes", len(reply))
	}
	numInfos := int(binary.LittleEndian.Uint16(reply[8:10]))
	buf := reply[32:]

	infos := make([]XIDeviceInfo, 0, numInfos)
	off := 0
	for i := 0; i < numInfos; i++ {
		info, n, err := parseXIDeviceInfo(buf[off:])
		if err != nil {
			return nil, fmt.Errorf("x11: XIQueryDevice device %d: %w", i, err)
		}
		infos = append(infos, info)
		off += n
	}
	return infos, nil
}

// parseXIDeviceInfo decodes one XIDeviceInfo entry from the front of buf
// and returns how many bytes it consumed. The wire layout, per xinput.xml:
// fixed 12-byte header (deviceid, type, attachment, num_classes, name_len,
// enabled+1 pad byte), then the name (name_len bytes), then <pad
// align="4"/> (poc014's headline XIQueryDevice gotcha -- every device past
// the first silently corrupts without it), then num_classes DeviceClass
// entries each skipped by its OWN len field at offset+2 within the class
// (the second gotcha).
func parseXIDeviceInfo(buf []byte) (XIDeviceInfo, int, error) {
	const fixedLen = 12
	if len(buf) < fixedLen {
		return XIDeviceInfo{}, 0, fmt.Errorf("XIDeviceInfo fixed fields overrun body: have %d bytes, need %d", len(buf), fixedLen)
	}

	var info XIDeviceInfo
	info.DeviceID = binary.LittleEndian.Uint16(buf[0:2])
	info.Type = binary.LittleEndian.Uint16(buf[2:4])
	info.Attachment = binary.LittleEndian.Uint16(buf[4:6])
	numClasses := int(binary.LittleEndian.Uint16(buf[6:8]))
	nameLen := int(binary.LittleEndian.Uint16(buf[8:10]))
	info.Enabled = buf[10] != 0
	// buf[11] is the explicit 1-byte pad before the name.

	off := fixedLen
	if off+nameLen > len(buf) {
		return XIDeviceInfo{}, 0, fmt.Errorf("XIDeviceInfo name (%d bytes) overruns body: have %d bytes remaining", nameLen, len(buf)-off)
	}
	info.Name = string(buf[off : off+nameLen])
	off += nameLen
	off += pad4(off) // <pad align="4"/> after the name

	info.Classes = make([]DeviceClass, 0, numClasses)
	for i := 0; i < numClasses; i++ {
		const classHeaderLen = 6 // type(2) + len(2) + sourceid(2)
		if off+classHeaderLen > len(buf) {
			return XIDeviceInfo{}, 0, fmt.Errorf("device class %d header overruns body: have %d bytes remaining, need %d", i, len(buf)-off, classHeaderLen)
		}
		classType := binary.LittleEndian.Uint16(buf[off : off+2])
		classLenUnits := binary.LittleEndian.Uint16(buf[off+2 : off+4]) // len at offset+2 within the class
		sourceID := binary.LittleEndian.Uint16(buf[off+4 : off+6])
		classLen := int(classLenUnits) * 4

		if classLen < classHeaderLen || off+classLen > len(buf) {
			return XIDeviceInfo{}, 0, fmt.Errorf(
				"device class %d declares length %d bytes, overrunning the buffer (have %d bytes remaining) -- refusing to guess and silently corrupt the next device",
				i, classLen, len(buf)-off)
		}

		info.Classes = append(info.Classes, DeviceClass{Type: classType, SourceID: sourceID})
		off += classLen // skip by the class's OWN len, never a size computed from its type
	}

	return info, off, nil
}

// XIQueryDevice enumerates devices (or a single device) via the XI2
// extension.
func (c *Conn) XIQueryDevice(majorOpcode byte, deviceid uint16) ([]XIDeviceInfo, error) {
	reply, err := c.doRequest(EncodeXIQueryDevice(majorOpcode, deviceid))
	if err != nil {
		return nil, err
	}
	return DecodeXIQueryDeviceReply(reply)
}

// ---------------------------------------------------------------------
// XIPassiveGrabDevice / XIPassiveUngrabDevice
// ---------------------------------------------------------------------

// GrabModifierResult is one XIPassiveGrabDevice reply entry: the outcome
// (GrabStatus) for one modifier-mask variant.
type GrabModifierResult struct {
	Modifiers uint32
	Status    byte // GrabStatus; 0 = Success
}

// GrabResult is the outcome of one XIPassiveGrabDevice call. A single call
// registers multiple modifier variants (the lock-bit fan-out), so success
// is PER-MODIFIER, not all-or-nothing: Failed lists exactly the variants
// the server refused. AllSucceeded distinguishes a fully successful grab
// from a partially successful one -- reading Failed as a boolean would
// collapse that distinction.
type GrabResult struct {
	Failed []GrabModifierResult
}

// AllSucceeded reports whether every modifier variant in the call
// succeeded.
func (r GrabResult) AllSucceeded() bool { return len(r.Failed) == 0 }

// EncodeXIPassiveGrabDevice builds an XIPassiveGrabDevice request. A single
// call can register several modifier variants (see GrabModifierVariants);
// the reply reports success/failure per variant, not for the call as a
// whole.
func EncodeXIPassiveGrabDevice(majorOpcode byte, grabWindow, cursor, detail uint32, deviceid uint16, modifiers, mask []uint32, grabType, grabMode, pairedDeviceMode byte, ownerEvents bool) []byte {
	maskLen := len(mask)
	numMods := len(modifiers)
	buf := make([]byte, 32+maskLen*4+numMods*4)

	putExtRequestHeader(buf, majorOpcode, xiMinorPassiveGrabDevice)
	binary.LittleEndian.PutUint32(buf[4:8], 0) // time: unused by this request, per xinput.xml
	binary.LittleEndian.PutUint32(buf[8:12], grabWindow)
	binary.LittleEndian.PutUint32(buf[12:16], cursor)
	binary.LittleEndian.PutUint32(buf[16:20], detail)
	binary.LittleEndian.PutUint16(buf[20:22], deviceid)
	binary.LittleEndian.PutUint16(buf[22:24], uint16(numMods))
	binary.LittleEndian.PutUint16(buf[24:26], uint16(maskLen))
	buf[26] = grabType
	buf[27] = grabMode
	buf[28] = pairedDeviceMode
	buf[29] = boolByte(ownerEvents)
	// buf[30:32] pad

	off := 32
	for _, m := range mask {
		binary.LittleEndian.PutUint32(buf[off:], m)
		off += 4
	}
	for _, m := range modifiers {
		binary.LittleEndian.PutUint32(buf[off:], m)
		off += 4
	}
	return buf
}

// DecodeXIPassiveGrabDeviceReply decodes an XIPassiveGrabDevice reply into
// a GrabResult, surfacing per-modifier failures rather than collapsing them
// into an all-or-nothing outcome.
func DecodeXIPassiveGrabDeviceReply(reply []byte) (GrabResult, error) {
	if len(reply) < 32 {
		return GrabResult{}, fmt.Errorf("x11: XIPassiveGrabDevice reply too short: %d bytes", len(reply))
	}
	numMods := int(binary.LittleEndian.Uint16(reply[8:10]))
	buf := reply[32:]
	const entryLen = 8 // modifiers CARD32(4) + status CARD8(1) + pad(3)
	if len(buf) < numMods*entryLen {
		return GrabResult{}, fmt.Errorf("x11: XIPassiveGrabDevice reply declares %d modifier entries but only has %d bytes", numMods, len(buf))
	}

	var result GrabResult
	for i := 0; i < numMods; i++ {
		entry := buf[i*entryLen : i*entryLen+entryLen]
		mods := binary.LittleEndian.Uint32(entry[0:4])
		status := entry[4]
		if status != 0 { // GrabStatus.Success == 0
			result.Failed = append(result.Failed, GrabModifierResult{Modifiers: mods, Status: status})
		}
	}
	return result, nil
}

// XIPassiveGrabDevice registers a passive keycode grab for every modifier
// variant in modifiers on grabWindow, for the given device. Use
// GrabModifierVariants to build the lock-bit fan-out.
func (c *Conn) XIPassiveGrabDevice(majorOpcode byte, grabWindow uint32, deviceid uint16, keycode uint32, modifiers, mask []uint32) (GrabResult, error) {
	req := EncodeXIPassiveGrabDevice(majorOpcode, grabWindow, 0, keycode, deviceid, modifiers, mask, GrabTypeKeycode, GrabMode22Async, GrabModeAsync, false)
	reply, err := c.doRequest(req)
	if err != nil {
		return GrabResult{}, err
	}
	return DecodeXIPassiveGrabDeviceReply(reply)
}

// EncodeXIPassiveUngrabDevice builds an XIPassiveUngrabDevice request.
// This request has no reply on the wire.
func EncodeXIPassiveUngrabDevice(majorOpcode byte, grabWindow, detail uint32, deviceid uint16, modifiers []uint32, grabType byte) []byte {
	buf := make([]byte, 20+len(modifiers)*4)
	putExtRequestHeader(buf, majorOpcode, xiMinorPassiveUngrabDevice)
	binary.LittleEndian.PutUint32(buf[4:8], grabWindow)
	binary.LittleEndian.PutUint32(buf[8:12], detail)
	binary.LittleEndian.PutUint16(buf[12:14], deviceid)
	binary.LittleEndian.PutUint16(buf[14:16], uint16(len(modifiers)))
	buf[16] = grabType
	// buf[17:20] pad

	off := 20
	for _, m := range modifiers {
		binary.LittleEndian.PutUint32(buf[off:], m)
		off += 4
	}
	return buf
}

// XIPassiveUngrabDevice releases a previously-registered passive keycode
// grab for every modifier variant in modifiers.
func (c *Conn) XIPassiveUngrabDevice(majorOpcode byte, grabWindow uint32, deviceid uint16, keycode uint32, modifiers []uint32) error {
	req := EncodeXIPassiveUngrabDevice(majorOpcode, grabWindow, keycode, deviceid, modifiers, GrabTypeKeycode)
	_, err := c.seq.SendUnchecked(req)
	return err
}

// ---------------------------------------------------------------------
// XISelectEvents
// ---------------------------------------------------------------------

// EventMaskEntry is one XISelectEvents mask entry: the events to select
// for one device.
type EventMaskEntry struct {
	DeviceID uint16
	Mask     []uint32 // XIEventMask bits, one CARD32 word per mask_len unit
}

// EncodeXISelectEvents builds an XISelectEvents request. This request has
// no reply on the wire. Each EventMaskEntry's mask_len counts 4-byte CARD32
// words, not bytes.
func EncodeXISelectEvents(majorOpcode byte, window uint32, masks []EventMaskEntry) []byte {
	body := 0
	for _, m := range masks {
		body += 4 + len(m.Mask)*4 // deviceid(2) + mask_len(2) + mask_len CARD32 words
	}
	buf := make([]byte, 12+body)
	putExtRequestHeader(buf, majorOpcode, xiMinorSelectEvents)
	binary.LittleEndian.PutUint32(buf[4:8], window)
	binary.LittleEndian.PutUint16(buf[8:10], uint16(len(masks)))
	// buf[10:12] pad

	off := 12
	for _, m := range masks {
		binary.LittleEndian.PutUint16(buf[off:off+2], m.DeviceID)
		binary.LittleEndian.PutUint16(buf[off+2:off+4], uint16(len(m.Mask)))
		off += 4
		for _, w := range m.Mask {
			binary.LittleEndian.PutUint32(buf[off:], w)
			off += 4
		}
	}
	return buf
}

// XISelectEvents selects XI2 events (e.g. hierarchy change notifications)
// for the given devices on window.
func (c *Conn) XISelectEvents(majorOpcode byte, window uint32, masks []EventMaskEntry) error {
	_, err := c.seq.SendUnchecked(EncodeXISelectEvents(majorOpcode, window, masks))
	return err
}
