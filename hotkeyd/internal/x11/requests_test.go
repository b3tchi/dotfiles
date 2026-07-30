package x11

import (
	"encoding/binary"
	"fmt"
	"testing"
)

// --- QueryExtension ---

func TestEncodeQueryExtension_WireBytes(t *testing.T) {
	buf := EncodeQueryExtension("XInputExtension")

	if buf[0] != opQueryExtension {
		t.Fatalf("opcode = %d, want %d", buf[0], opQueryExtension)
	}
	if buf[1] != 0 {
		t.Fatalf("byte 1 (pad) = %d, want 0", buf[1])
	}
	nameLen := binary.LittleEndian.Uint16(buf[4:6])
	if nameLen != 15 {
		t.Fatalf("name_len = %d, want 15", nameLen)
	}
	gotName := string(buf[8 : 8+15])
	if gotName != "XInputExtension" {
		t.Fatalf("name = %q, want %q", gotName, "XInputExtension")
	}
	// 15 bytes needs 1 byte of padding to reach a 4-byte boundary.
	wantTotal := 8 + 15 + 1
	if len(buf) != wantTotal {
		t.Fatalf("total request length = %d, want %d", len(buf), wantTotal)
	}
	lengthUnits := binary.LittleEndian.Uint16(buf[2:4])
	if int(lengthUnits)*4 != len(buf) {
		t.Fatalf("length field = %d units (%d bytes), want %d bytes", lengthUnits, lengthUnits*4, len(buf))
	}
}

func TestDecodeQueryExtensionReply(t *testing.T) {
	reply := make([]byte, 32)
	reply[0] = 1 // Reply
	reply[8] = 1 // present = true
	reply[9] = 131
	reply[10] = 2
	reply[11] = 129

	info, err := DecodeQueryExtensionReply(reply)
	if err != nil {
		t.Fatalf("DecodeQueryExtensionReply: %v", err)
	}
	if !info.Present {
		t.Error("Present = false, want true")
	}
	if info.MajorOpcode != 131 {
		t.Errorf("MajorOpcode = %d, want 131", info.MajorOpcode)
	}
	if info.FirstEvent != 2 {
		t.Errorf("FirstEvent = %d, want 2", info.FirstEvent)
	}
	if info.FirstError != 129 {
		t.Errorf("FirstError = %d, want 129", info.FirstError)
	}
}

func TestDecodeQueryExtensionReply_NotPresent(t *testing.T) {
	reply := make([]byte, 32)
	reply[0] = 1
	reply[8] = 0 // present = false

	info, err := DecodeQueryExtensionReply(reply)
	if err != nil {
		t.Fatalf("DecodeQueryExtensionReply: %v", err)
	}
	if info.Present {
		t.Error("Present = true, want false")
	}
}

// --- GetKeyboardMapping ---

func TestEncodeGetKeyboardMapping_WireBytes(t *testing.T) {
	buf := EncodeGetKeyboardMapping(8, 200)
	if buf[0] != opGetKeyboardMapping {
		t.Fatalf("opcode = %d, want %d", buf[0], opGetKeyboardMapping)
	}
	if buf[4] != 8 {
		t.Fatalf("first_keycode = %d, want 8", buf[4])
	}
	if buf[5] != 200 {
		t.Fatalf("count = %d, want 200", buf[5])
	}
	if len(buf) != 8 {
		t.Fatalf("total request length = %d, want 8", len(buf))
	}
}

// TestGetKeyboardMapping_KeysymsPerKeycodeFixtures is the headline poc015
// gotcha: keysyms_per_keycode is NOT a fixed stride (Xvfb measured 7, a
// native :0 session 10, an xrdp :10 session 15). The count must be read off
// the reply's own keysyms_per_keycode byte and the reply-length field, never
// assumed. A mutant that hardcodes any single stride fails at least two of
// these three fixtures.
func TestGetKeyboardMapping_KeysymsPerKeycodeFixtures(t *testing.T) {
	for _, perKeycode := range []byte{7, 10, 15} {
		t.Run(fmt.Sprintf("perKeycode=%d", perKeycode), func(t *testing.T) {
			const numKeycodes = 3
			numKeysyms := int(perKeycode) * numKeycodes

			reply := make([]byte, 32+numKeysyms*4)
			reply[0] = 1                                                  // Reply
			reply[1] = perKeycode                                         // keysyms_per_keycode
			binary.LittleEndian.PutUint32(reply[4:8], uint32(numKeysyms)) // length field: KEYSYM is 4 bytes = 1 unit each
			for i := 0; i < numKeysyms; i++ {
				binary.LittleEndian.PutUint32(reply[32+i*4:], uint32(0x1000+i))
			}

			mapping, err := DecodeGetKeyboardMappingReply(reply, 8)
			if err != nil {
				t.Fatalf("DecodeGetKeyboardMappingReply: %v", err)
			}
			if mapping.KeysymsPerKeycode != perKeycode {
				t.Fatalf("KeysymsPerKeycode = %d, want %d", mapping.KeysymsPerKeycode, perKeycode)
			}
			if len(mapping.Keysyms) != numKeysyms {
				t.Fatalf("len(Keysyms) = %d, want %d", len(mapping.Keysyms), numKeysyms)
			}

			// Keycode 9's keysyms are the second row (index perKeycode..2*perKeycode).
			got := mapping.KeysymsForKeycode(9)
			if len(got) != int(perKeycode) {
				t.Fatalf("KeysymsForKeycode(9) len = %d, want %d", len(got), perKeycode)
			}
			wantFirst := uint32(0x1000 + int(perKeycode))
			if got[0] != wantFirst {
				t.Fatalf("KeysymsForKeycode(9)[0] = %#x, want %#x", got[0], wantFirst)
			}
		})
	}
}

func TestDecodeGetKeyboardMappingReply_DeclaredLengthOverrunsBuffer(t *testing.T) {
	reply := make([]byte, 32) // declares keysyms via length field but body is truncated
	reply[0] = 1
	reply[1] = 7
	binary.LittleEndian.PutUint32(reply[4:8], 21) // claims 21 keysyms, 84 bytes -- not present

	if _, err := DecodeGetKeyboardMappingReply(reply, 8); err == nil {
		t.Fatal("DecodeGetKeyboardMappingReply: want error for truncated body, got nil")
	}
}

// --- GetProperty ---

func TestEncodeGetProperty_WireBytes(t *testing.T) {
	buf := EncodeGetProperty(false, 0x100, 23 /* RESOURCE_MANAGER */, AnyPropertyType, 5, 100)
	if buf[0] != opGetProperty {
		t.Fatalf("opcode = %d, want %d", buf[0], opGetProperty)
	}
	if buf[1] != 0 {
		t.Fatalf("delete = %d, want 0", buf[1])
	}
	if got := binary.LittleEndian.Uint32(buf[4:8]); got != 0x100 {
		t.Fatalf("window = %#x, want %#x", got, 0x100)
	}
	if got := binary.LittleEndian.Uint32(buf[8:12]); got != 23 {
		t.Fatalf("property = %d, want 23", got)
	}
	if got := binary.LittleEndian.Uint32(buf[16:20]); got != 5 {
		t.Fatalf("long_offset = %d, want 5", got)
	}
	if got := binary.LittleEndian.Uint32(buf[20:24]); got != 100 {
		t.Fatalf("long_length = %d, want 100", got)
	}
	if len(buf) != 24 {
		t.Fatalf("total request length = %d, want 24", len(buf))
	}
}

// TestGetProperty_LengthInFormatUnitsNotBytes is poc015 gotcha 6: value_len
// is in FORMAT units (8/16/32-bit quantities), not bytes. For format=8 the
// two coincide, hiding the bug; format=32 exposes it -- a mutant that reads
// value_len directly as a byte count decodes a Value 4x too short here.
func TestGetProperty_LengthInFormatUnitsNotBytes(t *testing.T) {
	const valueLenUnits = 3 // 3 32-bit quantities
	const format = 32
	valueBytes := valueLenUnits * (format / 8) // 12 bytes

	reply := make([]byte, 32+valueBytes)
	reply[0] = 1
	reply[1] = format
	binary.LittleEndian.PutUint32(reply[8:12], 6)              // type atom
	binary.LittleEndian.PutUint32(reply[12:16], 0)             // bytes_after
	binary.LittleEndian.PutUint32(reply[16:20], valueLenUnits) // value_len, FORMAT UNITS
	for i := 0; i < valueBytes; i++ {
		reply[32+i] = byte(0xA0 + i)
	}

	prop, err := DecodeGetPropertyReply(reply)
	if err != nil {
		t.Fatalf("DecodeGetPropertyReply: %v", err)
	}
	if prop.Format != format {
		t.Fatalf("Format = %d, want %d", prop.Format, format)
	}
	if len(prop.Value) != valueBytes {
		t.Fatalf("len(Value) = %d, want %d (value_len=%d units * format/8=%d)", len(prop.Value), valueBytes, valueLenUnits, format/8)
	}
	for i := 0; i < valueBytes; i++ {
		if prop.Value[i] != byte(0xA0+i) {
			t.Fatalf("Value[%d] = %#x, want %#x", i, prop.Value[i], byte(0xA0+i))
		}
	}
}

func TestGetProperty_Format8_UnitsCoincideWithBytes(t *testing.T) {
	const valueLenUnits = 5
	const format = 8
	reply := make([]byte, 32+valueLenUnits)
	reply[0] = 1
	reply[1] = format
	binary.LittleEndian.PutUint32(reply[16:20], valueLenUnits)
	copy(reply[32:], []byte("hello"))

	prop, err := DecodeGetPropertyReply(reply)
	if err != nil {
		t.Fatalf("DecodeGetPropertyReply: %v", err)
	}
	if string(prop.Value) != "hello" {
		t.Fatalf("Value = %q, want %q", prop.Value, "hello")
	}
}

// TestGetPropertyAll_MultiReplyLoop_LongOffsetInFourByteUnits is poc015
// gotcha 7: RESOURCE_MANAGER (or any property) can span multiple replies;
// the loop must advance long_offset in 4-byte units using BytesAfter, not
// stop after one round trip. A mutant that ignores BytesAfter (single-shot)
// truncates the assembled value; a mutant that advances by bytes instead of
// 4-byte units skips or repeats data.
func TestGetPropertyAll_MultiReplyLoop_LongOffsetInFourByteUnits(t *testing.T) {
	calls := 0
	var gotOffsets []uint32

	fetch := func(offset, length uint32) (PropertyReply, error) {
		calls++
		gotOffsets = append(gotOffsets, offset)
		switch calls {
		case 1:
			// First reply: 8 bytes of format=8 data (2 4-byte units), more
			// remains.
			return PropertyReply{
				Format:     8,
				Type:       31, // STRING
				BytesAfter: 4,
				Value:      []byte("ABCDEFGH"),
			}, nil
		case 2:
			// Second reply: remaining 4 bytes, BytesAfter now 0.
			return PropertyReply{
				Format:     8,
				Type:       31,
				BytesAfter: 0,
				Value:      []byte("IJKL"),
			}, nil
		default:
			t.Fatalf("unexpected extra call #%d", calls)
			return PropertyReply{}, nil
		}
	}

	format, typ, value, err := getPropertyAll(fetch, AnyPropertyType)
	if err != nil {
		t.Fatalf("getPropertyAll: %v", err)
	}
	if calls != 2 {
		t.Fatalf("calls = %d, want 2 (BytesAfter>0 must trigger a second round trip)", calls)
	}
	if gotOffsets[0] != 0 {
		t.Fatalf("first call offset = %d, want 0", gotOffsets[0])
	}
	// 8 bytes = 2 4-byte units -- long_offset advances in 4-byte units, not bytes.
	if gotOffsets[1] != 2 {
		t.Fatalf("second call offset = %d, want 2 (4-byte units of the 8 bytes read, NOT 8)", gotOffsets[1])
	}
	if format != 8 {
		t.Fatalf("format = %d, want 8", format)
	}
	if typ != 31 {
		t.Fatalf("type = %d, want 31", typ)
	}
	if string(value) != "ABCDEFGHIJKL" {
		t.Fatalf("value = %q, want %q", value, "ABCDEFGHIJKL")
	}
}

func TestGetPropertyAll_SingleReply_NoBytesAfter(t *testing.T) {
	calls := 0
	fetch := func(offset, length uint32) (PropertyReply, error) {
		calls++
		return PropertyReply{Format: 8, Type: 31, BytesAfter: 0, Value: []byte("xrdb")}, nil
	}
	_, _, value, err := getPropertyAll(fetch, AnyPropertyType)
	if err != nil {
		t.Fatalf("getPropertyAll: %v", err)
	}
	if calls != 1 {
		t.Fatalf("calls = %d, want 1", calls)
	}
	if string(value) != "xrdb" {
		t.Fatalf("value = %q, want %q", value, "xrdb")
	}
}

// --- QueryPointer ---

func TestEncodeQueryPointer_WireBytes(t *testing.T) {
	buf := EncodeQueryPointer(0xDEAD)
	if buf[0] != opQueryPointer {
		t.Fatalf("opcode = %d, want %d", buf[0], opQueryPointer)
	}
	if got := binary.LittleEndian.Uint32(buf[4:8]); got != 0xDEAD {
		t.Fatalf("window = %#x, want %#x", got, 0xDEAD)
	}
	if len(buf) != 8 {
		t.Fatalf("total request length = %d, want 8", len(buf))
	}
}

func TestDecodeQueryPointerReply_NegativeCoords(t *testing.T) {
	// Negative root_x/root_y: pointer left of / above the primary monitor.
	reply := make([]byte, 32)
	reply[0] = 1
	reply[1] = 1                                       // same_screen = true
	binary.LittleEndian.PutUint32(reply[8:12], 0x100)  // root
	binary.LittleEndian.PutUint32(reply[12:16], 0x200) // child
	wantRootX, wantRootY := int16(-50), int16(-10)
	binary.LittleEndian.PutUint16(reply[16:18], uint16(wantRootX)) // root_x
	binary.LittleEndian.PutUint16(reply[18:20], uint16(wantRootY)) // root_y
	binary.LittleEndian.PutUint16(reply[20:22], uint16(int16(5)))
	binary.LittleEndian.PutUint16(reply[22:24], uint16(int16(6)))
	binary.LittleEndian.PutUint16(reply[24:26], 0x0014)

	info, err := DecodeQueryPointerReply(reply)
	if err != nil {
		t.Fatalf("DecodeQueryPointerReply: %v", err)
	}
	if !info.SameScreen {
		t.Error("SameScreen = false, want true")
	}
	if info.RootX != -50 {
		t.Errorf("RootX = %d, want -50", info.RootX)
	}
	if info.RootY != -10 {
		t.Errorf("RootY = %d, want -10", info.RootY)
	}
	if info.Root != 0x100 {
		t.Errorf("Root = %#x, want %#x", info.Root, 0x100)
	}
	if info.Mask != 0x0014 {
		t.Errorf("Mask = %#x, want %#x", info.Mask, 0x0014)
	}
}
