package main

import (
	"testing"

	"hotkeyd/internal/x11"
)

// EDGE CASE from the task design: "Xvfb keymap differs from real sessions
// (keysyms_per_keycode 7): any keycode assumption must resolve at runtime."
// These two mappings are the same three keys at the two measured strides
// (Xvfb 7, a native session 10) — the resolver must answer identically.
func mappingWithStride(stride byte) x11.KeyboardMapping {
	// keycode 8 => "a"(0x61), keycode 23 => Tab(0xff09)/ISO_Left_Tab(0xfe20),
	// keycode 76 => F10(0xffc7).
	rows := map[byte][]uint32{
		8:  {0x61, 0x41},
		23: {0xff09, 0xfe20},
		76: {0xffc7},
	}
	const first, last = 8, 76
	flat := make([]uint32, 0, int(stride)*(last-first+1))
	for kc := byte(first); kc <= last; kc++ {
		row := make([]uint32, stride)
		copy(row, rows[kc])
		flat = append(flat, row...)
	}
	return x11.KeyboardMapping{KeysymsPerKeycode: stride, FirstKeycode: first, Keysyms: flat}
}

func TestKeycodeFor_ResolvesAtRuntimeAtEveryStride(t *testing.T) {
	for _, stride := range []byte{7, 10, 15} {
		m := mappingWithStride(stride)
		for name, want := range map[string]byte{"a": 8, "Tab": 23, "F10": 76, "ISO_Left_Tab": 23} {
			got, err := keycodeFor(m, name)
			if err != nil {
				t.Errorf("stride %d: %s: %v", stride, name, err)
				continue
			}
			if got != want {
				t.Errorf("stride %d: %s resolved to %d, want %d", stride, name, got, want)
			}
		}
	}
}

func TestKeycodeFor_UnknownKeysymNameIsAnError(t *testing.T) {
	m := mappingWithStride(7)
	if _, err := keycodeFor(m, "NoSuchKeysymEver"); err == nil {
		t.Error("an unknown keysym name resolved silently — a keycode this tool guessed is worse than a refusal")
	}
}

func TestKeycodeFor_KeysymNotOnThisKeymapIsAnError(t *testing.T) {
	m := mappingWithStride(7)
	// F12 is in the name table but absent from this fabricated keymap.
	if _, err := keycodeFor(m, "F12"); err == nil {
		t.Error("a keysym absent from the keymap resolved anyway")
	}
}

// The shift level is the whole point of the Tab / ISO_Left_Tab pair: the
// switcher cycles the wrong way in silence if the daemon resolves by keycode
// alone (live_check.py:714-718).
func TestKeysymAtLevel_ReadsTheShiftColumn(t *testing.T) {
	m := mappingWithStride(7)
	if got, ok := keysymAtLevel(m, 23, 0); !ok || got != 0xff09 {
		t.Errorf("level 0 of keycode 23 = %#x (ok=%v), want Tab 0xff09", got, ok)
	}
	if got, ok := keysymAtLevel(m, 23, 1); !ok || got != 0xfe20 {
		t.Errorf("level 1 of keycode 23 = %#x (ok=%v), want ISO_Left_Tab 0xfe20", got, ok)
	}
}

func TestKeysymAtLevel_OutOfRangeIsNotOK(t *testing.T) {
	m := mappingWithStride(7)
	if _, ok := keysymAtLevel(m, 23, 99); ok {
		t.Error("a level past the row's stride reported ok")
	}
	if _, ok := keysymAtLevel(m, 200, 0); ok {
		t.Error("a keycode outside the mapping reported ok")
	}
}

// Every keysym name the live checks inject or resolve must be in the table,
// or the check dies at runtime on the rig rather than here.
func TestKeysymTable_CoversEveryNameTheChecksUse(t *testing.T) {
	for _, name := range keysymNamesUsedByChecks {
		if _, ok := keysymByName[name]; !ok {
			t.Errorf("keysym %q is used by a live check but missing from keysymByName", name)
		}
	}
}
