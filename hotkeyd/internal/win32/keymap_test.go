package win32

import (
	"strings"
	"testing"
)

// The hand-written cases of sp012 Task 3, values from WinUser.h (VK) and
// keysymdef.h (keysym) - never from the table under test.
func TestToKeysym_HandCases(t *testing.T) {
	cases := []struct {
		name   string
		vk     uint16
		keysym uint32
	}{
		{"VK_RETURN", 0x0D, 0xff0d},
		{"VK_TAB", 0x09, 0xff09},
		{"VK_ESCAPE", 0x1B, 0xff1b},
		{"VK_SPACE", 0x20, 0x0020},
		{"VK_OEM_1", 0xBA, 0x003b},
		{"VK_F1", 0x70, 0xffbe},
		{"VK_F24", 0x87, 0xffd5},
		{"VK_LEFT", 0x25, 0xff51},
		{"VK_SNAPSHOT", 0x2C, 0xff61},
		{"'A'", 0x41, 0x0061},
		{"'Z'", 0x5A, 0x007a},
		{"'1'", 0x31, 0x0031},
		{"'0'", 0x30, 0x0030},
		{"VK_BACK", 0x08, 0xff08},
		{"VK_DELETE", 0x2E, 0xffff},
		{"VK_OEM_MINUS", 0xBD, 0x002d},
		{"VK_OEM_PLUS", 0xBB, 0x003d},
		{"VK_OEM_3", 0xC0, 0x0060},
		{"VK_OEM_7", 0xDE, 0x0027},
		{"VK_LWIN", 0x5B, 0xffeb},
		{"VK_RMENU", 0xA5, 0xffea},
		{"VK_APPS", 0x5D, 0xff67},
		{"VK_VOLUME_UP", 0xAF, 0x1008ff13},
	}
	for _, c := range cases {
		got, ok := ToKeysym(c.vk)
		if !ok || got != c.keysym {
			t.Errorf("ToKeysym(%s 0x%02x) = 0x%x, %v; want 0x%x", c.name, c.vk, got, ok, c.keysym)
		}
		key, ok := ToVK(c.keysym)
		if !ok || key.VK != c.vk || key.Shift {
			t.Errorf("ToVK(0x%x) = %+v, %v; want VK 0x%02x, no Shift", c.keysym, key, ok, c.vk)
		}
	}
}

// Numpad VKs are KP_* keysyms, never the digits the number row gives.
func TestToKeysym_NumpadIsKP(t *testing.T) {
	for i := uint16(0); i <= 9; i++ {
		got, ok := ToKeysym(0x60 + i)
		want := 0xffb0 + uint32(i) // XK_KP_0..XK_KP_9
		if !ok || got != want {
			t.Errorf("ToKeysym(VK_NUMPAD%d) = 0x%x, %v; want KP_%d 0x%x", i, got, ok, i, want)
		}
		if got == 0x30+uint32(i) {
			t.Errorf("VK_NUMPAD%d maps to the digit, not KP_%d", i, i)
		}
		if key, ok := ToVK(want); !ok || key.VK != 0x60+i || key.Shift {
			t.Errorf("ToVK(KP_%d) = %+v, %v; want VK_NUMPAD%d", i, key, ok, i)
		}
	}
	ops := map[uint16]uint32{0x6A: 0xffaa, 0x6B: 0xffab, 0x6D: 0xffad, 0x6E: 0xffae, 0x6F: 0xffaf}
	for vk, ks := range ops {
		if got, ok := ToKeysym(vk); !ok || got != ks {
			t.Errorf("ToKeysym(0x%02x) = 0x%x, %v; want 0x%x", vk, got, ok, ks)
		}
	}
}

// grabs.go's US-layout rule (internal/kwin shiftedSymbol): a shifted symbol
// is its US key plus Shift; a capital letter is its letter key plus Shift.
func TestToVK_ShiftedSymbolsFollowTheUSRule(t *testing.T) {
	cases := []struct {
		name   string
		keysym uint32
		vk     uint16
	}{
		{"exclam", '!', '1'}, {"at", '@', '2'}, {"numbersign", '#', '3'},
		{"dollar", '$', '4'}, {"percent", '%', '5'}, {"asciicircum", '^', '6'},
		{"ampersand", '&', '7'}, {"asterisk", '*', '8'}, {"parenleft", '(', '9'},
		{"parenright", ')', '0'}, {"underscore", '_', 0xBD}, {"plus", '+', 0xBB},
		{"less", '<', 0xBC}, {"greater", '>', 0xBE}, {"question", '?', 0xBF},
		{"colon", ':', 0xBA}, {"quotedbl", '"', 0xDE}, {"asciitilde", '~', 0xC0},
		{"braceleft", '{', 0xDB}, {"braceright", '}', 0xDD}, {"bar", '|', 0xDC},
		{"ISO_Left_Tab", 0xfe20, 0x09},
		{"A", 'A', 'A'}, {"Q", 'Q', 'Q'},
	}
	for _, c := range cases {
		key, ok := ToVK(c.keysym)
		if !ok || key.VK != c.vk || !key.Shift {
			t.Errorf("ToVK(%s 0x%x) = %+v, %v; want VK 0x%02x plus Shift", c.name, c.keysym, key, ok, c.vk)
		}
		if got, ok := ShiftedKeysym(c.vk); !ok || got != c.keysym {
			t.Errorf("ShiftedKeysym(0x%02x) = 0x%x, %v; want %s 0x%x", c.vk, got, ok, c.name, c.keysym)
		}
	}
}

// A keysym with no key on the US layout is refused by name, never a panic.
func TestToVK_NoUSKeyIsRefusedByName(t *testing.T) {
	cases := map[string]uint32{
		"ISO_Level3_Shift":    0xfe03,
		"XF86MonBrightnessUp": 0x1008ff02,
		"Meta_L":              0xffe7,
		"eacute":              0x00e9,
		"unassigned":          0x12345678,
	}
	for name, ks := range cases {
		key, ok := ToVK(ks)
		if ok {
			t.Errorf("ToVK(%s 0x%x) = %+v, want refused", name, ks, key)
		}
		_, err := Resolve(ks)
		if err == nil {
			t.Errorf("Resolve(%s 0x%x): no error", name, ks)
			continue
		}
		if !strings.Contains(err.Error(), "0x") {
			t.Errorf("Resolve(%s) error %q does not name the keysym", name, err)
		}
	}
	if _, ok := ToKeysym(0xFF); ok {
		t.Errorf("ToKeysym(0xFF) answered a keysym for an unassigned VK")
	}
}

// Every VK ToKeysym knows round-trips through ToVK, except the aliases
// listed (generic and duplicate keys whose keysym belongs to another VK).
func TestRoundTrip_EveryVK(t *testing.T) {
	aliases := map[uint16]uint16{
		VK_SHIFT: VK_LSHIFT, VK_CONTROL: VK_LCONTROL, VK_MENU: VK_LMENU,
		VK_OEM_102: VK_OEM_5,
	}
	n := 0
	for vk := 0; vk <= 0xFF; vk++ {
		ks, ok := ToKeysym(uint16(vk))
		if !ok {
			continue
		}
		n++
		key, ok := ToVK(ks)
		want := uint16(vk)
		if a, isAlias := aliases[uint16(vk)]; isAlias {
			want = a
		}
		if !ok || key.VK != want || key.Shift {
			t.Errorf("VK 0x%02x -> keysym 0x%x -> %+v, %v; want VK 0x%02x", vk, ks, key, ok, want)
		}
	}
	if n < 100 {
		t.Fatalf("only %d VKs translate; the table is suspiciously small", n)
	}
}

// ModBits: L and R of each modifier give the X11 bit; the lock keys and
// any other key give nothing.
func TestModBits(t *testing.T) {
	cases := []struct {
		name string
		down []uint16
		want uint32
	}{
		{"none", nil, 0},
		{"LShift", []uint16{VK_LSHIFT}, 1},
		{"RShift", []uint16{VK_RSHIFT}, 1},
		{"LControl", []uint16{VK_LCONTROL}, 4},
		{"RControl", []uint16{VK_RCONTROL}, 4},
		{"LAlt", []uint16{VK_LMENU}, 8},
		{"RAlt", []uint16{VK_RMENU}, 8},
		{"LWin", []uint16{VK_LWIN}, 64},
		{"RWin", []uint16{VK_RWIN}, 64},
		{"all", []uint16{VK_LSHIFT, VK_RCONTROL, VK_LMENU, VK_RWIN}, 1 | 4 | 8 | 64},
		{"locks", []uint16{VK_CAPITAL, VK_NUMLOCK, VK_SCROLL}, 0},
		{"Alt+locks", []uint16{VK_LMENU, VK_CAPITAL, VK_NUMLOCK, VK_SCROLL}, 8},
		{"letters", []uint16{'A', VK_RETURN, VK_TAB}, 0},
		// AltGr on Windows is RMENU plus an injected LCONTROL: it reads as
		// Alt plus Control (known limitation; Jan's layout is US).
		{"AltGr", []uint16{VK_RMENU, VK_LCONTROL}, 8 | 4},
	}
	for _, c := range cases {
		set := map[uint16]bool{}
		for _, vk := range c.down {
			set[vk] = true
		}
		got := ModBits(func(vk uint16) bool { return set[vk] })
		if got != c.want {
			t.Errorf("ModBits(%s) = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestModifierVK(t *testing.T) {
	cases := map[uint16]uint32{
		VK_LSHIFT: 1, VK_RSHIFT: 1, VK_SHIFT: 1,
		VK_LCONTROL: 4, VK_RCONTROL: 4, VK_CONTROL: 4,
		VK_LMENU: 8, VK_RMENU: 8, VK_MENU: 8,
		VK_LWIN: 64, VK_RWIN: 64,
	}
	for vk, want := range cases {
		if got, ok := ModifierBit(vk); !ok || got != want {
			t.Errorf("ModifierBit(0x%02x) = %d, %v; want %d", vk, got, ok, want)
		}
	}
	for _, vk := range []uint16{VK_CAPITAL, VK_NUMLOCK, VK_SCROLL, 'A', VK_TAB} {
		if _, ok := ModifierBit(vk); ok {
			t.Errorf("ModifierBit(0x%02x) claims a modifier", vk)
		}
	}
}

// HotkeyMods is the reverse for RegisterHotKey: X11 bits to MOD_*.
func TestHotkeyMods(t *testing.T) {
	cases := []struct {
		x11  uint32
		want uint32
	}{
		{0, 0},
		{1, MOD_SHIFT},
		{4, MOD_CONTROL},
		{8, MOD_ALT},
		{64, MOD_WIN},
		{1 | 4 | 8 | 64, MOD_SHIFT | MOD_CONTROL | MOD_ALT | MOD_WIN},
	}
	for _, c := range cases {
		got, err := HotkeyMods(c.x11)
		if err != nil || got != c.want {
			t.Errorf("HotkeyMods(%d) = %#x, %v; want %#x", c.x11, got, err, c.want)
		}
	}
	// Lock (2), Mod2 (16), Mod3 (32), Mod5 (128) have no Windows modifier.
	for _, bit := range []uint32{2, 16, 32, 128} {
		if _, err := HotkeyMods(8 | bit); err == nil {
			t.Errorf("HotkeyMods(8|%d): no error for a bit Windows cannot register", bit)
		}
	}
}

// The values RegisterHotKey's documentation gives.
func TestHotkeyModConstants(t *testing.T) {
	if MOD_ALT != 1 || MOD_CONTROL != 2 || MOD_SHIFT != 4 || MOD_WIN != 8 {
		t.Fatalf("MOD_* = %d %d %d %d, want 1 2 4 8", MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN)
	}
}
