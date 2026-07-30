package x11

import (
	"encoding/binary"
	"testing"
)

// TestEncodeGrabKeyboard_WireBytes pins the core-protocol GrabKeyboard
// request layout (opcode 31, xproto.xml): owner-events in the header's
// data1 byte, grab-window, time, pointer-mode, keyboard-mode, and the
// total request length in 4-byte units (4, per the spec table).
func TestEncodeGrabKeyboard_WireBytes(t *testing.T) {
	buf := EncodeGrabKeyboard(true, 0xCAFE, 0x1234, GrabModeAsync, GrabModeSync)
	if buf[0] != opGrabKeyboard {
		t.Fatalf("opcode = %d, want %d", buf[0], opGrabKeyboard)
	}
	if buf[1] != 1 {
		t.Fatalf("owner-events = %d, want 1 (true)", buf[1])
	}
	if got := binary.LittleEndian.Uint16(buf[2:4]); got != 4 {
		t.Fatalf("request length = %d units, want 4", got)
	}
	if got := binary.LittleEndian.Uint32(buf[4:8]); got != 0xCAFE {
		t.Fatalf("grab-window = %#x, want %#x", got, 0xCAFE)
	}
	if got := binary.LittleEndian.Uint32(buf[8:12]); got != 0x1234 {
		t.Fatalf("time = %#x, want %#x", got, 0x1234)
	}
	if buf[12] != GrabModeAsync {
		t.Fatalf("pointer-mode = %d, want %d (Async)", buf[12], GrabModeAsync)
	}
	if buf[13] != GrabModeSync {
		t.Fatalf("keyboard-mode = %d, want %d (Sync)", buf[13], GrabModeSync)
	}
	if len(buf) != 16 {
		t.Fatalf("total request length = %d bytes, want 16", len(buf))
	}
}

func TestEncodeGrabKeyboard_OwnerEventsFalse(t *testing.T) {
	buf := EncodeGrabKeyboard(false, 1, 0, GrabModeAsync, GrabModeAsync)
	if buf[1] != 0 {
		t.Fatalf("owner-events = %d, want 0 (false)", buf[1])
	}
}

// TestDecodeGrabKeyboardReply_EveryStatus pins every named GrabKeyboard
// status byte this package's health probe (--health verdict 8) has to tell
// apart -- Success releases immediately, AlreadyGrabbed is the verdict-8
// evidence, and the rest ("cannot ask right now") must not be misread as
// either of those.
func TestDecodeGrabKeyboardReply_EveryStatus(t *testing.T) {
	cases := []struct {
		name string
		byte byte
		want byte
	}{
		{"Success", 0, GrabStatusSuccess},
		{"AlreadyGrabbed", 1, GrabStatusAlreadyGrabbed},
		{"InvalidTime", 2, GrabStatusInvalidTime},
		{"NotViewable", 3, GrabStatusNotViewable},
		{"Frozen", 4, GrabStatusFrozen},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			reply := make([]byte, 32)
			reply[1] = c.byte
			got, err := DecodeGrabKeyboardReply(reply)
			if err != nil {
				t.Fatalf("unexpected error: %s", err)
			}
			if got != c.want {
				t.Fatalf("status = %d, want %d", got, c.want)
			}
		})
	}
}

func TestDecodeGrabKeyboardReply_TooShort(t *testing.T) {
	if _, err := DecodeGrabKeyboardReply([]byte{1}); err == nil {
		t.Fatal("want an error for a truncated reply, got nil")
	}
}

// TestEncodeUngrabKeyboard_WireBytes pins the core-protocol UngrabKeyboard
// request layout (opcode 32): no reply on the wire (a void request, like
// XIPassiveUngrabDevice -- see (*Conn).UngrabKeyboard's SendUnchecked use).
func TestEncodeUngrabKeyboard_WireBytes(t *testing.T) {
	buf := EncodeUngrabKeyboard(0xABCD)
	if buf[0] != opUngrabKeyboard {
		t.Fatalf("opcode = %d, want %d", buf[0], opUngrabKeyboard)
	}
	if got := binary.LittleEndian.Uint16(buf[2:4]); got != 2 {
		t.Fatalf("request length = %d units, want 2", got)
	}
	if got := binary.LittleEndian.Uint32(buf[4:8]); got != 0xABCD {
		t.Fatalf("time = %#x, want %#x", got, 0xABCD)
	}
	if len(buf) != 8 {
		t.Fatalf("total request length = %d bytes, want 8", len(buf))
	}
}
