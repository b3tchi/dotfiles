package x11

import (
	"encoding/binary"
	"testing"
)

// --- XIQueryVersion ---

func TestEncodeXIQueryVersion_WireBytes(t *testing.T) {
	buf := EncodeXIQueryVersion(131, 2, 3)
	if buf[0] != 131 {
		t.Fatalf("major_opcode (byte0) = %d, want 131", buf[0])
	}
	if buf[1] != xiMinorQueryVersion {
		t.Fatalf("minor_opcode (byte1) = %d, want %d", buf[1], xiMinorQueryVersion)
	}
	if got := binary.LittleEndian.Uint16(buf[4:6]); got != 2 {
		t.Fatalf("major_version = %d, want 2", got)
	}
	if got := binary.LittleEndian.Uint16(buf[6:8]); got != 3 {
		t.Fatalf("minor_version = %d, want 3", got)
	}
	if len(buf) != 8 {
		t.Fatalf("total request length = %d, want 8", len(buf))
	}
}

func TestDecodeXIQueryVersionReply(t *testing.T) {
	reply := make([]byte, 32)
	reply[0] = 1
	binary.LittleEndian.PutUint16(reply[8:10], 2)
	binary.LittleEndian.PutUint16(reply[10:12], 3)

	v, err := DecodeXIQueryVersionReply(reply)
	if err != nil {
		t.Fatalf("DecodeXIQueryVersionReply: %v", err)
	}
	if v.Major != 2 || v.Minor != 3 {
		t.Fatalf("version = %d.%d, want 2.3", v.Major, v.Minor)
	}
}

// --- XIQueryDevice ---

// buildDeviceClassBytes builds one DeviceClass entry: type, len (in 4-byte
// units, len*4 == total bytes of this class including its own header), and
// sourceid, padded with `extra` filler bytes so len*4 is honoured exactly.
func buildDeviceClassBytes(classType, sourceID uint16, extra int) []byte {
	total := 6 + extra
	total += (4 - total%4) % 4 // classes are 4-byte aligned as a whole
	buf := make([]byte, total)
	binary.LittleEndian.PutUint16(buf[0:2], classType)
	binary.LittleEndian.PutUint16(buf[2:4], uint16(total/4))
	binary.LittleEndian.PutUint16(buf[4:6], sourceID)
	return buf
}

// buildXIDeviceInfoBytes builds one XIDeviceInfo entry with the given name
// and classes, honouring the <pad align="4"/> after the name.
func buildXIDeviceInfoBytes(deviceID, devType, attachment uint16, name string, classes [][]byte) []byte {
	nameLen := len(name)
	namePad := pad4(nameLen)
	body := 12 + nameLen + namePad
	for _, c := range classes {
		body += len(c)
	}
	buf := make([]byte, body)
	binary.LittleEndian.PutUint16(buf[0:2], deviceID)
	binary.LittleEndian.PutUint16(buf[2:4], devType)
	binary.LittleEndian.PutUint16(buf[4:6], attachment)
	binary.LittleEndian.PutUint16(buf[6:8], uint16(len(classes)))
	binary.LittleEndian.PutUint16(buf[8:10], uint16(nameLen))
	buf[10] = 1 // enabled

	off := 12
	copy(buf[off:], name)
	off += nameLen + namePad
	for _, c := range classes {
		copy(buf[off:], c)
		off += len(c)
	}
	if off != len(buf) {
		panic("buildXIDeviceInfoBytes: internal size mismatch")
	}
	return buf
}

func buildXIQueryDeviceReply(devices [][]byte) []byte {
	body := 0
	for _, d := range devices {
		body += len(d)
	}
	reply := make([]byte, 32+body)
	reply[0] = 1
	binary.LittleEndian.PutUint16(reply[8:10], uint16(len(devices)))
	binary.LittleEndian.PutUint32(reply[4:8], uint32(body/4))
	off := 32
	for _, d := range devices {
		copy(reply[off:], d)
		off += len(d)
	}
	return reply
}

// TestXIQueryDevice_NamePadAlign4_SecondDeviceSurvives is poc014's headline
// XIQueryDevice gotcha: XIDeviceInfo needs <pad align="4"/> after the name.
// A name whose length is NOT a multiple of 4 (5 here) exercises the pad; a
// mutant that omits it decodes the second device at the wrong offset --
// this test asserts the SECOND device's fields, not just that parsing
// doesn't error.
func TestXIQueryDevice_NamePadAlign4_SecondDeviceSurvives(t *testing.T) {
	dev1 := buildXIDeviceInfoBytes(3, DeviceTypeMasterKeyboard, 2, "abcde" /* 5 bytes: needs 3 pad */, nil)
	dev2 := buildXIDeviceInfoBytes(5, DeviceTypeSlaveKeyboard, 3, "XTEST slave", nil)
	reply := buildXIQueryDeviceReply([][]byte{dev1, dev2})

	infos, err := DecodeXIQueryDeviceReply(reply)
	if err != nil {
		t.Fatalf("DecodeXIQueryDeviceReply: %v", err)
	}
	if len(infos) != 2 {
		t.Fatalf("len(infos) = %d, want 2", len(infos))
	}
	if infos[0].DeviceID != 3 || infos[0].Name != "abcde" {
		t.Fatalf("infos[0] = %+v, want deviceid=3 name=abcde", infos[0])
	}
	if infos[1].DeviceID != 5 || infos[1].Name != "XTEST slave" || infos[1].Type != DeviceTypeSlaveKeyboard {
		t.Fatalf("infos[1] = %+v, want deviceid=5 name=%q type=%d -- a missing name pad misaligns this device", infos[1], "XTEST slave", DeviceTypeSlaveKeyboard)
	}
}

// TestXIQueryDevice_DeviceClassSkipByOwnLen is poc014's second gotcha: each
// DeviceClass is skipped by its OWN len field (at offset+2 within the
// class), not by a size computed from its type. A device with an
// odd-length class followed by a second device proves the skip lands
// exactly.
func TestXIQueryDevice_DeviceClassSkipByOwnLen(t *testing.T) {
	class1 := buildDeviceClassBytes(DeviceClassKey, 5, 10) // odd extra payload
	class2 := buildDeviceClassBytes(DeviceClassValuator, 5, 3)
	dev1 := buildXIDeviceInfoBytes(3, DeviceTypeMasterKeyboard, 2, "kbd", [][]byte{class1, class2})
	dev2 := buildXIDeviceInfoBytes(6, DeviceTypeSlavePointer, 1, "mouse", nil)
	reply := buildXIQueryDeviceReply([][]byte{dev1, dev2})

	infos, err := DecodeXIQueryDeviceReply(reply)
	if err != nil {
		t.Fatalf("DecodeXIQueryDeviceReply: %v", err)
	}
	if len(infos) != 2 {
		t.Fatalf("len(infos) = %d, want 2", len(infos))
	}
	if len(infos[0].Classes) != 2 {
		t.Fatalf("len(infos[0].Classes) = %d, want 2", len(infos[0].Classes))
	}
	if infos[0].Classes[0].Type != DeviceClassKey || infos[0].Classes[0].SourceID != 5 {
		t.Fatalf("infos[0].Classes[0] = %+v, want type=%d sourceid=5", infos[0].Classes[0], DeviceClassKey)
	}
	if infos[0].Classes[1].Type != DeviceClassValuator {
		t.Fatalf("infos[0].Classes[1] = %+v, want type=%d", infos[0].Classes[1], DeviceClassValuator)
	}
	if infos[1].DeviceID != 6 || infos[1].Name != "mouse" {
		t.Fatalf("infos[1] = %+v, want deviceid=6 name=mouse -- a wrong class skip misaligns this device", infos[1])
	}
}

// TestXIQueryDevice_ClassOverrun_ErrorsRatherThanCorrupting is the design's
// named edge case: a device whose class list would overrun the buffer must
// error, never silently corrupt the next device's parse.
func TestXIQueryDevice_ClassOverrun_ErrorsRatherThanCorrupting(t *testing.T) {
	dev := buildXIDeviceInfoBytes(3, DeviceTypeMasterKeyboard, 2, "kbd", nil)
	// Hand-craft a bogus device: num_classes=1 but no class bytes follow.
	buf := make([]byte, 12+4) // fixed header + "kbd\0"-ish name of len 0 rounded... simplify: name_len=0
	binary.LittleEndian.PutUint16(buf[0:2], 3)
	binary.LittleEndian.PutUint16(buf[2:4], DeviceTypeMasterKeyboard)
	binary.LittleEndian.PutUint16(buf[4:6], 2)
	binary.LittleEndian.PutUint16(buf[6:8], 1)  // num_classes = 1
	binary.LittleEndian.PutUint16(buf[8:10], 0) // name_len = 0
	buf[10] = 1
	// buf[12:16] would be the class header, but we deliberately only
	// allocated 4 bytes here -- not enough for even the class header,
	// let alone a len-driven body.
	binary.LittleEndian.PutUint16(buf[12:14], DeviceClassKey)
	binary.LittleEndian.PutUint16(buf[14:16], 100) // len=100 units (400 bytes) -- wildly overruns

	reply := buildXIQueryDeviceReply([][]byte{dev, buf})
	if _, err := DecodeXIQueryDeviceReply(reply); err == nil {
		t.Fatal("DecodeXIQueryDeviceReply: want error for a device class overrunning the buffer, got nil")
	}
}

func TestEncodeXIQueryDevice_WireBytes(t *testing.T) {
	buf := EncodeXIQueryDevice(131, DeviceAll)
	if buf[0] != 131 || buf[1] != xiMinorQueryDevice {
		t.Fatalf("header = %d,%d want 131,%d", buf[0], buf[1], xiMinorQueryDevice)
	}
	if got := binary.LittleEndian.Uint16(buf[4:6]); got != DeviceAll {
		t.Fatalf("deviceid = %d, want %d", got, DeviceAll)
	}
}

// --- GrabType / lock-bit variants ---

// TestGrabTypeKeycode_WireByte is poc014's headline gotcha: GrabType.Keycode
// is 1, not 0 -- 0 is GrabType.Button. Grabbing with the wrong constant
// silently grabs a *button* instead of a keycode. This test asserts the
// literal wire byte a mutant using GrabTypeKeycode=0 would fail.
func TestGrabTypeKeycode_WireByte(t *testing.T) {
	if GrabTypeKeycode != 1 {
		t.Fatalf("GrabTypeKeycode = %d, want 1", GrabTypeKeycode)
	}
	if GrabTypeButton != 0 {
		t.Fatalf("GrabTypeButton = %d, want 0", GrabTypeButton)
	}

	req := EncodeXIPassiveGrabDevice(131, 0x100, 0, 38, 3, []uint32{0x40}, nil, GrabTypeKeycode, GrabMode22Async, GrabModeAsync, false)
	// offset 26 = header(4) + time(4)+grab_window(4)+cursor(4)+detail(4)+deviceid(2)+num_modifiers(2)+mask_len(2)
	const grabTypeOffset = 26
	if req[grabTypeOffset] != 1 {
		t.Fatalf("wire grab_type byte (offset %d) = %d, want 1 (Keycode) -- 0 would grab a BUTTON instead", grabTypeOffset, req[grabTypeOffset])
	}
}

func TestGrabModifierVariants_FourLockBitCombinations(t *testing.T) {
	const mod4 = 0x40
	const lock = 0x02
	const mod2 = 0x10

	got := GrabModifierVariants(mod4)
	want := []uint32{mod4, mod4 | lock, mod4 | mod2, mod4 | lock | mod2}
	if len(got) != 4 {
		t.Fatalf("len(GrabModifierVariants) = %d, want 4", len(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("GrabModifierVariants(%#x)[%d] = %#x, want %#x", mod4, i, got[i], want[i])
		}
	}
}

// --- XIPassiveGrabDevice ---

func TestEncodeXIPassiveGrabDevice_WireBytes(t *testing.T) {
	mods := GrabModifierVariants(0x40)
	req := EncodeXIPassiveGrabDevice(131, 0x100, 0, 38, 3, mods, []uint32{0xC}, GrabTypeKeycode, GrabMode22Async, GrabModeAsync, false)

	if req[0] != 131 || req[1] != xiMinorPassiveGrabDevice {
		t.Fatalf("header = %d,%d want 131,%d", req[0], req[1], xiMinorPassiveGrabDevice)
	}
	if got := binary.LittleEndian.Uint32(req[8:12]); got != 0x100 {
		t.Fatalf("grab_window = %#x, want %#x", got, 0x100)
	}
	if got := binary.LittleEndian.Uint32(req[16:20]); got != 38 {
		t.Fatalf("detail = %d, want 38", got)
	}
	if got := binary.LittleEndian.Uint16(req[20:22]); got != 3 {
		t.Fatalf("deviceid = %d, want 3", got)
	}
	if got := binary.LittleEndian.Uint16(req[22:24]); got != 4 {
		t.Fatalf("num_modifiers = %d, want 4 (the lock-bit fan-out)", got)
	}
	if got := binary.LittleEndian.Uint16(req[24:26]); got != 1 {
		t.Fatalf("mask_len = %d, want 1 (one CARD32 mask word)", got)
	}
	if req[26] != GrabTypeKeycode {
		t.Fatalf("grab_type = %d, want %d", req[26], GrabTypeKeycode)
	}
	// mask list (1 word) starts at offset 32.
	if got := binary.LittleEndian.Uint32(req[32:36]); got != 0xC {
		t.Fatalf("mask[0] = %#x, want %#x", got, 0xC)
	}
	// modifiers list (4 words, the lock-bit fan-out) starts right after.
	for i, m := range mods {
		off := 36 + i*4
		if got := binary.LittleEndian.Uint32(req[off : off+4]); got != m {
			t.Fatalf("modifiers[%d] = %#x, want %#x", i, got, m)
		}
	}
}

// TestDecodeXIPassiveGrabDeviceReply_PartialFailure is the design's core
// requirement: a reply where exactly one of four modifier variants fails
// must be distinguishable from total success -- a partial failure is not
// "grab succeeded" nor "grab failed", it is its own named outcome.
func TestDecodeXIPassiveGrabDeviceReply_PartialFailure(t *testing.T) {
	mods := []uint32{0x40, 0x42, 0x50, 0x52}
	reply := make([]byte, 32+len(mods)*8)
	reply[0] = 1
	binary.LittleEndian.PutUint16(reply[8:10], uint16(len(mods)))
	for i, m := range mods {
		off := 32 + i*8
		binary.LittleEndian.PutUint32(reply[off:off+4], m)
		if i == 2 { // 0x50 (Mod4|Mod2) is the one that fails
			reply[off+4] = 1 // GrabStatus.AlreadyGrabbed
		} else {
			reply[off+4] = 0 // GrabStatus.Success
		}
	}

	result, err := DecodeXIPassiveGrabDeviceReply(reply)
	if err != nil {
		t.Fatalf("DecodeXIPassiveGrabDeviceReply: %v", err)
	}
	if result.AllSucceeded() {
		t.Fatal("AllSucceeded() = true, want false: one of four modifier variants failed")
	}
	if len(result.Failed) != 1 {
		t.Fatalf("len(Failed) = %d, want 1", len(result.Failed))
	}
	if result.Failed[0].Modifiers != 0x50 {
		t.Fatalf("Failed[0].Modifiers = %#x, want %#x", result.Failed[0].Modifiers, 0x50)
	}
	if result.Failed[0].Status != 1 {
		t.Fatalf("Failed[0].Status = %d, want 1", result.Failed[0].Status)
	}
}

func TestDecodeXIPassiveGrabDeviceReply_TotalSuccess(t *testing.T) {
	mods := []uint32{0x40, 0x42, 0x50, 0x52}
	reply := make([]byte, 32+len(mods)*8)
	reply[0] = 1
	binary.LittleEndian.PutUint16(reply[8:10], uint16(len(mods)))
	for i, m := range mods {
		off := 32 + i*8
		binary.LittleEndian.PutUint32(reply[off:off+4], m)
		reply[off+4] = 0
	}

	result, err := DecodeXIPassiveGrabDeviceReply(reply)
	if err != nil {
		t.Fatalf("DecodeXIPassiveGrabDeviceReply: %v", err)
	}
	if !result.AllSucceeded() {
		t.Fatalf("AllSucceeded() = false, want true: Failed=%+v", result.Failed)
	}
	if len(result.Failed) != 0 {
		t.Fatalf("len(Failed) = %d, want 0", len(result.Failed))
	}
}

// --- XIPassiveUngrabDevice ---

func TestEncodeXIPassiveUngrabDevice_WireBytes(t *testing.T) {
	mods := GrabModifierVariants(0x40)
	req := EncodeXIPassiveUngrabDevice(131, 0x100, 38, 3, mods, GrabTypeKeycode)

	if req[0] != 131 || req[1] != xiMinorPassiveUngrabDevice {
		t.Fatalf("header = %d,%d want 131,%d", req[0], req[1], xiMinorPassiveUngrabDevice)
	}
	if got := binary.LittleEndian.Uint32(req[4:8]); got != 0x100 {
		t.Fatalf("grab_window = %#x, want %#x", got, 0x100)
	}
	if got := binary.LittleEndian.Uint32(req[8:12]); got != 38 {
		t.Fatalf("detail = %d, want 38", got)
	}
	if got := binary.LittleEndian.Uint16(req[12:14]); got != 3 {
		t.Fatalf("deviceid = %d, want 3", got)
	}
	if got := binary.LittleEndian.Uint16(req[14:16]); got != uint16(len(mods)) {
		t.Fatalf("num_modifiers = %d, want %d", got, len(mods))
	}
	if req[16] != GrabTypeKeycode {
		t.Fatalf("grab_type = %d, want %d", req[16], GrabTypeKeycode)
	}
	for i, m := range mods {
		off := 20 + i*4
		if got := binary.LittleEndian.Uint32(req[off : off+4]); got != m {
			t.Fatalf("modifiers[%d] = %#x, want %#x", i, got, m)
		}
	}
}

// --- XISelectEvents ---

// TestEncodeXISelectEvents_HierarchyEvents_MaskLenInFourByteUnits proves
// mask_len counts 4-byte CARD32 words, not bytes or bits -- a mutant that
// sizes the mask list in bytes truncates or corrupts every mask after the
// first.
func TestEncodeXISelectEvents_HierarchyEvents_MaskLenInFourByteUnits(t *testing.T) {
	masks := []EventMaskEntry{
		{DeviceID: DeviceAllMaster, Mask: []uint32{XIEventMaskHierarchy}},
	}
	req := EncodeXISelectEvents(131, 0x100, masks)

	if req[0] != 131 || req[1] != xiMinorSelectEvents {
		t.Fatalf("header = %d,%d want 131,%d", req[0], req[1], xiMinorSelectEvents)
	}
	if got := binary.LittleEndian.Uint32(req[4:8]); got != 0x100 {
		t.Fatalf("window = %#x, want %#x", got, 0x100)
	}
	if got := binary.LittleEndian.Uint16(req[8:10]); got != 1 {
		t.Fatalf("num_mask = %d, want 1", got)
	}
	// EventMask entry starts at offset 12: deviceid(2), mask_len(2), then
	// mask_len CARD32 words.
	if got := binary.LittleEndian.Uint16(req[12:14]); got != DeviceAllMaster {
		t.Fatalf("masks[0].deviceid = %d, want %d", got, DeviceAllMaster)
	}
	if got := binary.LittleEndian.Uint16(req[14:16]); got != 1 {
		t.Fatalf("masks[0].mask_len = %d, want 1 (one CARD32 word, NOT a byte count)", got)
	}
	if got := binary.LittleEndian.Uint32(req[16:20]); got != XIEventMaskHierarchy {
		t.Fatalf("masks[0].mask[0] = %#x, want %#x (Hierarchy bit)", got, XIEventMaskHierarchy)
	}
	if len(req) != 20 {
		t.Fatalf("total request length = %d, want 20", len(req))
	}
}

func TestXIEventMaskHierarchy_BitValue(t *testing.T) {
	// Hierarchy is bit 11 of the XIEventMask enum.
	if XIEventMaskHierarchy != 1<<11 {
		t.Fatalf("XIEventMaskHierarchy = %#x, want %#x", XIEventMaskHierarchy, 1<<11)
	}
}
