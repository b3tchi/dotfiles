package main

import (
	"fmt"

	"hotkeyd/internal/x11"
)

// keysymByName is livecheck's own name -> keysym table. It is deliberately
// small: only the keys the live checks actually inject or resolve.
//
// It is NOT shared with the daemon's table (cmd/hotkeyd/grabs.go's
// keysymByName) because that package is `main` and nothing can import it —
// the same reason this whole tool observes the daemon from outside rather
// than calling into it. The overlap is nine or so entries of X11 protocol
// constants, which are fixed by the protocol and cannot drift.
var keysymByName = map[string]uint32{
	"F8":           0xffc5,
	"F9":           0xffc6,
	"F10":          0xffc7,
	"F11":          0xffc8,
	"F12":          0xffc9,
	"Tab":          0xff09,
	"ISO_Left_Tab": 0xfe20,
	"Escape":       0xff1b,
	"Return":       0xff0d,
	"Num_Lock":     0xff7f,
	"Caps_Lock":    0xffe5,
	"Shift_L":      0xffe1,
	"Control_L":    0xffe3,
	"Alt_L":        0xffe9,
	"Super_L":      0xffeb,
	"Super_R":      0xffec,
	"space":        0x0020,
	"a":            0x0061,
	"h":            0x0068,
	"j":            0x006a,
	"k":            0x006b,
	"l":            0x006c,
	"o":            0x006f,
	"q":            0x0071,
	"r":            0x0072,
	"w":            0x0077,
}

// keysymNamesUsedByChecks names every keysym the live checks reach for, so
// a missing entry is a unit-test failure here rather than a runtime
// surprise on the rig.
var keysymNamesUsedByChecks = []string{
	"F8", "F9", "F10", "F11", "F12",
	"Tab", "ISO_Left_Tab", "Escape", "Return",
	"Num_Lock", "Caps_Lock",
	"Shift_L", "Control_L", "Alt_L", "Super_L", "Super_R",
	"h", "j", "o", "q", "r",
}

// keycodeFor resolves a keysym NAME to a keycode against the mapping read
// off THIS server on THIS run.
//
// Nothing here may be hardcoded: keysyms_per_keycode is 7 under the suite's
// Xvfb, 10 on a native session and 15 on adr0004's xrdp :10 (measured — see
// x11.KeyboardMapping's own doc), and the keycode a keysym lands on differs
// with the layout. A live check that assumed either is testing the rig it
// was written on, not the one it is running on.
func keycodeFor(m x11.KeyboardMapping, name string) (byte, error) {
	ks, ok := keysymByName[name]
	if !ok {
		return 0, fmt.Errorf("livecheck: keysym %q is not in this tool's name table", name)
	}
	stride := int(m.KeysymsPerKeycode)
	if stride == 0 {
		return 0, fmt.Errorf("livecheck: empty keyboard mapping (keysyms_per_keycode is 0)")
	}
	rows := len(m.Keysyms) / stride
	for i := 0; i < rows; i++ {
		for _, got := range m.Keysyms[i*stride : (i+1)*stride] {
			if got == ks {
				return byte(int(m.FirstKeycode) + i), nil
			}
		}
	}
	return 0, fmt.Errorf("livecheck: keysym %q (%#x) is not on this display's keymap", name, ks)
}

// keysymAtLevel reads one shift level of a keycode's row. Level 0 is the
// unshifted keysym, level 1 the shifted one — which is what separates Tab
// from ISO_Left_Tab on the SAME keycode, and therefore what separates the
// switcher cycling forwards from cycling backwards.
func keysymAtLevel(m x11.KeyboardMapping, keycode byte, level int) (uint32, bool) {
	row := m.KeysymsForKeycode(keycode)
	if row == nil || level < 0 || level >= len(row) {
		return 0, false
	}
	return row[level], true
}

// nameForKeysym is keysymByName reversed, for reporting what a level
// actually held.
func nameForKeysym(ks uint32) string {
	for n, v := range keysymByName {
		if v == ks {
			return n
		}
	}
	return fmt.Sprintf("keysym %#x", ks)
}
