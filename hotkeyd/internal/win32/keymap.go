// Package win32 is hotkeyd's Windows key source (sp012). This file is its
// key translator: Windows virtual-key codes and modifier state become X11
// keysyms and X11 modifier bits, the values internal/kwin's grab protocol
// already speaks (Shift 1, Control 4, Alt = Mod1 8, Win = Mod4 64), so a
// key leaves this package as the same layer.Event input the X11 and KWin
// paths produce and nothing after it knows it came from Windows.
//
// It is pure Go with no build tag, so it is tested on Linux; the Windows
// cross-check against VkKeyScanEx is keymap_windows_test.go.
//
// ASSUMPTION/LIMITATION, the one internal/kwin/grabs.go makes: the layout is
// US (00000409). Jan's OS layout is plain US and his keyboard is hardware
// Dvorak, so the VK a key sends is the US one. hotkeyd has no per-layout
// shift-level data; on another layout a symbol chord resolves to the wrong
// key. AltGr is Windows' RMENU plus an LCONTROL it injects, so ModBits
// reports it as Alt plus Control - harmless on US, which has no AltGr.
// VK_RETURN covers both Enter keys (the numpad one differs only by the
// extended-key flag, which a VK does not carry), so KP_Enter has no VK.
package win32

import "fmt"

// Virtual-key codes, from WinUser.h.
const (
	VK_BACK      uint16 = 0x08
	VK_TAB       uint16 = 0x09
	VK_CLEAR     uint16 = 0x0C
	VK_RETURN    uint16 = 0x0D
	VK_SHIFT     uint16 = 0x10
	VK_CONTROL   uint16 = 0x11
	VK_MENU      uint16 = 0x12
	VK_PAUSE     uint16 = 0x13
	VK_CAPITAL   uint16 = 0x14
	VK_ESCAPE    uint16 = 0x1B
	VK_SPACE     uint16 = 0x20
	VK_PRIOR     uint16 = 0x21
	VK_NEXT      uint16 = 0x22
	VK_END       uint16 = 0x23
	VK_HOME      uint16 = 0x24
	VK_LEFT      uint16 = 0x25
	VK_UP        uint16 = 0x26
	VK_RIGHT     uint16 = 0x27
	VK_DOWN      uint16 = 0x28
	VK_SELECT    uint16 = 0x29
	VK_EXECUTE   uint16 = 0x2B
	VK_SNAPSHOT  uint16 = 0x2C
	VK_INSERT    uint16 = 0x2D
	VK_DELETE    uint16 = 0x2E
	VK_HELP      uint16 = 0x2F
	VK_LWIN      uint16 = 0x5B
	VK_RWIN      uint16 = 0x5C
	VK_APPS      uint16 = 0x5D
	VK_NUMPAD0   uint16 = 0x60
	VK_MULTIPLY  uint16 = 0x6A
	VK_ADD       uint16 = 0x6B
	VK_SEPARATOR uint16 = 0x6C
	VK_SUBTRACT  uint16 = 0x6D
	VK_DECIMAL   uint16 = 0x6E
	VK_DIVIDE    uint16 = 0x6F
	VK_F1        uint16 = 0x70
	VK_F24       uint16 = 0x87
	VK_NUMLOCK   uint16 = 0x90
	VK_SCROLL    uint16 = 0x91
	VK_LSHIFT    uint16 = 0xA0
	VK_RSHIFT    uint16 = 0xA1
	VK_LCONTROL  uint16 = 0xA2
	VK_RCONTROL  uint16 = 0xA3
	VK_LMENU     uint16 = 0xA4
	VK_RMENU     uint16 = 0xA5

	VK_VOLUME_MUTE      uint16 = 0xAD
	VK_VOLUME_DOWN      uint16 = 0xAE
	VK_VOLUME_UP        uint16 = 0xAF
	VK_MEDIA_NEXT_TRACK uint16 = 0xB0
	VK_MEDIA_PREV_TRACK uint16 = 0xB1
	VK_MEDIA_STOP       uint16 = 0xB2
	VK_MEDIA_PLAY_PAUSE uint16 = 0xB3

	VK_OEM_1      uint16 = 0xBA // ;:
	VK_OEM_PLUS   uint16 = 0xBB // =+
	VK_OEM_COMMA  uint16 = 0xBC // ,<
	VK_OEM_MINUS  uint16 = 0xBD // -_
	VK_OEM_PERIOD uint16 = 0xBE // .>
	VK_OEM_2      uint16 = 0xBF // /?
	VK_OEM_3      uint16 = 0xC0 // `~
	VK_OEM_4      uint16 = 0xDB // [{
	VK_OEM_5      uint16 = 0xDC // \|
	VK_OEM_6      uint16 = 0xDD // ]}
	VK_OEM_7      uint16 = 0xDE // '"
	VK_OEM_102    uint16 = 0xE2 // the 102nd key; \| on the US layout
)

// RegisterHotKey's fsModifiers bits, from WinUser.h.
const (
	MOD_ALT      uint32 = 0x0001
	MOD_CONTROL  uint32 = 0x0002
	MOD_SHIFT    uint32 = 0x0004
	MOD_WIN      uint32 = 0x0008
	MOD_NOREPEAT uint32 = 0x4000
)

// X11 modifier bits (X.h's ShiftMask, ControlMask, Mod1Mask, Mod4Mask) -
// the same values internal/kwin's ModShift..ModSuper carry.
const (
	ModShift uint32 = 1
	ModCtrl  uint32 = 4
	ModAlt   uint32 = 8
	ModSuper uint32 = 64
)

// Key is where a keysym lives on the US layout: a VK, and whether the
// keysym is that key's Shift level.
type Key struct {
	VK    uint16
	Shift bool
}

// base is VK -> the keysym of the key's unshifted level. Every keysym here
// is the one keysymdef.h names; a-z, 0-9, F1-F24 and the numpad digits are
// filled in by init.
var base = map[uint16]uint32{
	VK_BACK:     0xff08, // BackSpace
	VK_TAB:      0xff09, // Tab
	VK_CLEAR:    0xff0b, // Clear
	VK_RETURN:   0xff0d, // Return
	VK_PAUSE:    0xff13, // Pause
	VK_SCROLL:   0xff14, // Scroll_Lock
	VK_ESCAPE:   0xff1b, // Escape
	VK_SPACE:    0x0020, // space
	VK_HOME:     0xff50, // Home
	VK_LEFT:     0xff51, // Left
	VK_UP:       0xff52, // Up
	VK_RIGHT:    0xff53, // Right
	VK_DOWN:     0xff54, // Down
	VK_PRIOR:    0xff55, // Prior (Page Up)
	VK_NEXT:     0xff56, // Next (Page Down)
	VK_END:      0xff57, // End
	VK_SELECT:   0xff60, // Select
	VK_SNAPSHOT: 0xff61, // Print
	VK_EXECUTE:  0xff62, // Execute
	VK_INSERT:   0xff63, // Insert
	VK_APPS:     0xff67, // Menu
	VK_HELP:     0xff6a, // Help
	VK_NUMLOCK:  0xff7f, // Num_Lock
	VK_DELETE:   0xffff, // Delete
	VK_CAPITAL:  0xffe5, // Caps_Lock

	VK_MULTIPLY:  0xffaa, // KP_Multiply
	VK_ADD:       0xffab, // KP_Add
	VK_SEPARATOR: 0xffac, // KP_Separator
	VK_SUBTRACT:  0xffad, // KP_Subtract
	VK_DECIMAL:   0xffae, // KP_Decimal
	VK_DIVIDE:    0xffaf, // KP_Divide

	VK_LSHIFT:   0xffe1, // Shift_L
	VK_RSHIFT:   0xffe2, // Shift_R
	VK_LCONTROL: 0xffe3, // Control_L
	VK_RCONTROL: 0xffe4, // Control_R
	VK_LMENU:    0xffe9, // Alt_L
	VK_RMENU:    0xffea, // Alt_R
	VK_LWIN:     0xffeb, // Super_L
	VK_RWIN:     0xffec, // Super_R
	// The side-less VKs GetKeyState also answers for; they read as the left
	// key, the one ToVK gives back for Shift_L/Control_L/Alt_L.
	VK_SHIFT:   0xffe1,
	VK_CONTROL: 0xffe3,
	VK_MENU:    0xffe9,

	VK_VOLUME_MUTE:      0x1008ff12, // XF86AudioMute
	VK_VOLUME_DOWN:      0x1008ff11, // XF86AudioLowerVolume
	VK_VOLUME_UP:        0x1008ff13, // XF86AudioRaiseVolume
	VK_MEDIA_PLAY_PAUSE: 0x1008ff14, // XF86AudioPlay
	VK_MEDIA_STOP:       0x1008ff15, // XF86AudioStop
	VK_MEDIA_PREV_TRACK: 0x1008ff16, // XF86AudioPrev
	VK_MEDIA_NEXT_TRACK: 0x1008ff17, // XF86AudioNext

	VK_OEM_1:      ';',
	VK_OEM_PLUS:   '=',
	VK_OEM_COMMA:  ',',
	VK_OEM_MINUS:  '-',
	VK_OEM_PERIOD: '.',
	VK_OEM_2:      '/',
	VK_OEM_3:      '`',
	VK_OEM_4:      '[',
	VK_OEM_5:      '\\',
	VK_OEM_6:      ']',
	VK_OEM_7:      '\'',
	VK_OEM_102:    '\\',
}

// shifted is VK -> the keysym of the key's Shift level on the US layout,
// internal/kwin/grabs.go's shiftedSymbol read the other way. Capital
// letters are filled in by init.
var shifted = map[uint16]uint32{
	'1': '!', '2': '@', '3': '#', '4': '$', '5': '%',
	'6': '^', '7': '&', '8': '*', '9': '(', '0': ')',
	VK_OEM_1: ':', VK_OEM_PLUS: '+', VK_OEM_COMMA: '<', VK_OEM_MINUS: '_',
	VK_OEM_PERIOD: '>', VK_OEM_2: '?', VK_OEM_3: '~', VK_OEM_4: '{',
	VK_OEM_5: '|', VK_OEM_6: '}', VK_OEM_7: '"',
	VK_TAB: 0xfe20, // ISO_Left_Tab
}

// aliasVK are VKs whose keysym belongs to another VK in the reverse map:
// the side-less modifiers and the 102nd key (\ on US, as VK_OEM_5 is).
var aliasVK = map[uint16]bool{VK_SHIFT: true, VK_CONTROL: true, VK_MENU: true, VK_OEM_102: true}

// noKey names keysyms hotkeyd's tables know that have no Windows key, so
// the grab report says why rather than only "not found".
var noKey = map[uint32]string{
	0x1008ff02: "XF86MonBrightnessUp has no virtual-key code; Windows handles brightness itself",
	0x1008ff03: "XF86MonBrightnessDown has no virtual-key code; Windows handles brightness itself",
	0xffe7:     "Meta_L has no Windows key (Alt is Alt_L, Win is Super_L)",
	0xffe8:     "Meta_R has no Windows key (Alt is Alt_R, Win is Super_R)",
	0xfe03:     "ISO_Level3_Shift (AltGr) is not on the US layout",
	0xff8d:     "KP_Enter is VK_RETURN with the extended-key flag, which a VK cannot name",
}

// reverse is keysym -> Key, built from base and shifted.
var reverse = map[uint32]Key{}

func init() {
	for c := uint16('A'); c <= 'Z'; c++ {
		base[c] = uint32(c - 'A' + 'a')
		shifted[c] = uint32(c)
	}
	for c := uint16('0'); c <= '9'; c++ {
		base[c] = uint32(c)
	}
	for i := uint16(0); i <= 9; i++ {
		base[VK_NUMPAD0+i] = 0xffb0 + uint32(i) // KP_0..KP_9
	}
	for vk := VK_F1; vk <= VK_F24; vk++ {
		base[vk] = 0xffbe + uint32(vk-VK_F1) // F1..F24
	}
	for vk, ks := range base {
		if !aliasVK[vk] {
			reverse[ks] = Key{VK: vk}
		}
	}
	for vk, ks := range shifted {
		reverse[ks] = Key{VK: vk, Shift: true}
	}
}

// ToKeysym is the keysym of vk's unshifted level - what X11 reports for a
// keycode at level 0 and what a chord's bare key name means ('A' is 0x61,
// "a"). A numpad VK is its KP_* keysym, never the digit. false for a VK
// with no keysym here.
func ToKeysym(vk uint16) (uint32, bool) {
	ks, ok := base[vk]
	return ks, ok
}

// ShiftedKeysym is the keysym of vk's Shift level on the US layout
// ('1' is exclam, VK_TAB is ISO_Left_Tab, 'A' is A). false for a key whose
// Shift level is not a different keysym.
func ShiftedKeysym(vk uint16) (uint32, bool) {
	ks, ok := shifted[vk]
	return ks, ok
}

// Resolve is ToVK with the reason when there is no key: the error names
// the keysym, so a grab report can list it.
func Resolve(keysym uint32) (Key, error) {
	if k, ok := reverse[keysym]; ok {
		return k, nil
	}
	if why, ok := noKey[keysym]; ok {
		return Key{}, fmt.Errorf("keysym 0x%x: %s", keysym, why)
	}
	return Key{}, fmt.Errorf("keysym 0x%x has no key on the US layout", keysym)
}

// ToVK is the US key that types keysym: its VK, and whether Shift is part
// of it (exclam is '1' plus Shift, ISO_Left_Tab is VK_TAB plus Shift).
func ToVK(keysym uint32) (Key, bool) {
	k, err := Resolve(keysym)
	return k, err == nil
}

// modifierBits are the VKs ModBits reads, each with its X11 bit. The lock
// keys are deliberately absent: Caps, Num and Scroll lock never change a
// chord, as XI2's lock-bit fan-out ignores them on X11.
var modifierBits = []struct {
	vk  uint16
	bit uint32
}{
	{VK_LSHIFT, ModShift}, {VK_RSHIFT, ModShift},
	{VK_LCONTROL, ModCtrl}, {VK_RCONTROL, ModCtrl},
	{VK_LMENU, ModAlt}, {VK_RMENU, ModAlt},
	{VK_LWIN, ModSuper}, {VK_RWIN, ModSuper},
}

// ModBits is the X11 modifier mask of the keys down reports held: left or
// right Shift 1, Control 4, Alt 8, Win 64. down is asked only about the
// eight sided modifier VKs (GetAsyncKeyState answers them, and so does a
// hook's own key-state set).
func ModBits(down func(vk uint16) bool) uint32 {
	var m uint32
	for _, mb := range modifierBits {
		if down(mb.vk) {
			m |= mb.bit
		}
	}
	return m
}

// ModifierBit is the X11 bit a modifier VK carries (sided or not), for a
// hook tracking which modifiers are down. false for any other key,
// the lock keys included.
func ModifierBit(vk uint16) (uint32, bool) {
	switch vk {
	case VK_LSHIFT, VK_RSHIFT, VK_SHIFT:
		return ModShift, true
	case VK_LCONTROL, VK_RCONTROL, VK_CONTROL:
		return ModCtrl, true
	case VK_LMENU, VK_RMENU, VK_MENU:
		return ModAlt, true
	case VK_LWIN, VK_RWIN:
		return ModSuper, true
	}
	return 0, false
}

// HotkeyMods turns an X11 modifier mask into RegisterHotKey's MOD_* bits.
// A bit Windows has no modifier for (Lock, Mod2, Mod3, Mod5) is an error
// naming it, not dropped: a chord that needs it cannot be registered.
func HotkeyMods(x11 uint32) (uint32, error) {
	var m uint32
	pairs := []struct{ x, w uint32 }{
		{ModShift, MOD_SHIFT}, {ModCtrl, MOD_CONTROL}, {ModAlt, MOD_ALT}, {ModSuper, MOD_WIN},
	}
	rest := x11
	for _, p := range pairs {
		if x11&p.x != 0 {
			m |= p.w
			rest &^= p.x
		}
	}
	if rest != 0 {
		return 0, fmt.Errorf("X11 modifier bits %#x have no Windows modifier", rest)
	}
	return m, nil
}
