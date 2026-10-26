package main

// sp012 Task 3 (kwi3-hoex.3): internal/win32's key translator against the
// REAL table this binary ships - Binds with this build's host overrides
// (host_default.go, host_phone.go, and host_win32.go once it exists, by
// build tag), the kwi3-only chords, and every layer, sublayer and exit
// key. It lives in package main because the table does.

import (
	"sort"
	"testing"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/win32"
)

// tableChords is every chord string the built table binds.
func tableChords() []string {
	var out []string
	for _, b := range effectiveBinds("kwi3") {
		out = append(out, b.Chord)
	}
	names := make([]string, 0, len(Layers))
	for name := range Layers {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		l := Layers[name]
		for _, b := range l.Binds {
			out = append(out, b.Chord)
		}
		for _, m := range l.Mods {
			for _, b := range m.Binds {
				out = append(out, b.Chord)
			}
		}
		out = append(out, l.ExitKeys...)
	}
	return out
}

// heldVK is the left-hand VK a chord's modifier is pressed with.
var heldVK = map[bind.Modifier]uint16{
	bind.Shift: win32.VK_LSHIFT,
	bind.Ctrl:  win32.VK_LCONTROL,
	bind.Mod1:  win32.VK_LMENU,
	bind.Mod4:  win32.VK_LWIN,
}

// Every chord translates both ways: its keysym has a US key whose own
// keysym is the chord's again, the modifier keys held for it read back as
// the chord's X11 mask (what grabs.go and the KWin path match against),
// and the mask registers with RegisterHotKey. A chord that cannot is
// named with its reason.
func TestWin32Keymap_EveryTableChordTranslatesBothWays(t *testing.T) {
	chords := tableChords()
	if len(chords) < 50 {
		t.Fatalf("walked only %d chords; the table walk is broken", len(chords))
	}
	for _, mod := range bind.ModResolutions {
		for _, chord := range chords {
			mods, name, err := bind.ParseChord(chord, mod)
			if err != nil {
				t.Errorf("$mod=%s chord %q: %s", mod, chord, err)
				continue
			}
			keysym, ok := keysymByName[name]
			if !ok {
				t.Errorf("$mod=%s chord %q: keysym %q not in keysymByName", mod, chord, name)
				continue
			}
			key, err := win32.Resolve(keysym)
			if err != nil {
				t.Errorf("$mod=%s chord %q: keysym %q has no VK: %s", mod, chord, name, err)
				continue
			}
			back, ok := win32.ToKeysym(key.VK)
			if key.Shift {
				back, ok = win32.ShiftedKeysym(key.VK)
			}
			if !ok || back != keysym {
				t.Errorf("$mod=%s chord %q: %q -> VK 0x%02x shift=%v -> keysym 0x%x, want 0x%x",
					mod, chord, name, key.VK, key.Shift, back, keysym)
			}

			want := maskFromMods(mods)
			held := map[uint16]bool{}
			for m := range mods {
				vk, ok := heldVK[m]
				if !ok {
					t.Errorf("$mod=%s chord %q: modifier %s has no Windows key", mod, chord, m)
					continue
				}
				held[vk] = true
			}
			if key.Shift {
				held[win32.VK_LSHIFT] = true
				want |= maskShift
			}
			if got := win32.ModBits(func(vk uint16) bool { return held[vk] }); got != want {
				t.Errorf("$mod=%s chord %q: held modifiers read as mask %#x, want %#x", mod, chord, got, want)
			}

			reg, err := win32.HotkeyMods(want)
			if err != nil {
				t.Errorf("$mod=%s chord %q: %s", mod, chord, err)
				continue
			}
			if mods[bind.Mod1] && reg&win32.MOD_ALT == 0 {
				t.Errorf("$mod=%s chord %q: Mod1 registers as %#x, no MOD_ALT", mod, chord, reg)
			}
			if mods[bind.Mod4] && reg&win32.MOD_WIN == 0 {
				t.Errorf("$mod=%s chord %q: Mod4 registers as %#x, no MOD_WIN", mod, chord, reg)
			}
		}
	}
}

// On Windows $mod is Alt (Mod1): a $mod chord is Alt held, and both ways
// of reading it agree. Swapping the Alt and Win bits fails this.
func TestWin32Keymap_ModIsAlt(t *testing.T) {
	mods, name, err := bind.ParseChord("$mod+Return", "Mod1")
	if err != nil {
		t.Fatal(err)
	}
	if got := win32.ModBits(func(vk uint16) bool { return vk == win32.VK_LMENU }); got != maskFromMods(mods) || got != maskMod1 {
		t.Fatalf("LMENU held reads as %#x; $mod+Return under Mod1 is %#x", got, maskFromMods(mods))
	}
	if reg, err := win32.HotkeyMods(maskFromMods(mods)); err != nil || reg != win32.MOD_ALT {
		t.Fatalf("$mod registers as %#x, %v; want MOD_ALT", reg, err)
	}
	if key, ok := win32.ToVK(keysymByName[name]); !ok || key.VK != win32.VK_RETURN || key.Shift {
		t.Fatalf("Return -> %+v, %v; want VK_RETURN", key, ok)
	}
}

// Every name keysymByName knows has a VK except the ones listed with why:
// a new keysym added to the table gets a decision here, not silence.
func TestWin32Keymap_KeysymTableUnmappableAreKnown(t *testing.T) {
	want := map[string]bool{
		"Meta_L": true, "Meta_R": true,
		"XF86MonBrightnessUp": true, "XF86MonBrightnessDown": true,
	}
	for name, ks := range keysymByName {
		_, err := win32.Resolve(ks)
		switch {
		case err != nil && !want[name]:
			t.Errorf("keysym %q has no VK and is not a known exception: %s", name, err)
		case err == nil && want[name]:
			t.Errorf("keysym %q now has a VK; drop it from the exceptions", name)
		case err != nil:
			t.Logf("unmappable on Windows: %s", err)
		}
	}
}
