package win32

import (
	"strings"
	"syscall"
	"testing"
)

// fakeReg records every Registrar call; refuse names VKs whose
// registration fails with the given error.
type fakeReg struct {
	calls  []string
	held   map[int32]regCall
	refuse map[uint16]error
}

type regCall struct {
	mods uint32
	vk   uint16
}

func newFakeReg() *fakeReg {
	return &fakeReg{held: map[int32]regCall{}, refuse: map[uint16]error{}}
}

func (f *fakeReg) Register(id int32, mods uint32, vk uint16) error {
	f.calls = append(f.calls, "reg "+string(rune(vk)))
	if err, ok := f.refuse[vk]; ok {
		return err
	}
	f.held[id] = regCall{mods, vk}
	return nil
}

func (f *fakeReg) Unregister(id int32) error {
	c, ok := f.held[id]
	if !ok {
		return ERROR_HOTKEY_NOT_REGISTERED
	}
	f.calls = append(f.calls, "unreg "+string(rune(c.vk)))
	delete(f.held, id)
	return nil
}

func (f *fakeReg) registered(vk uint16, mods uint32) bool {
	for _, c := range f.held {
		if c.vk == vk && c.mods == mods {
			return true
		}
	}
	return false
}

var testKeysyms = map[string]uint32{
	"1": '1', "2": '2', "3": '3', "r": 'r', "d": 'd', "Return": 0xff0d,
	"plus": '+', "equal": '=', "ISO_Left_Tab": 0xfe20, "Print": 0xff61, "Tab": 0xff09,
}

func testKeysym(n string) (uint32, bool) { v, ok := testKeysyms[n]; return v, ok }

func TestHotkeys_RegistersWithNoRepeatUnderMod1(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	h.SyncBinds([]string{"$mod+2", "$mod+Shift+d", "$mod+Return"})
	for _, want := range []regCall{
		{MOD_NOREPEAT | MOD_ALT, '2'},
		{MOD_NOREPEAT | MOD_ALT | MOD_SHIFT, 'D'},
		{MOD_NOREPEAT | MOD_ALT, VK_RETURN},
	} {
		if !f.registered(want.vk, want.mods) {
			t.Errorf("no RegisterHotKey(mods %#x, vk %#x); held %v", want.mods, want.vk, f.held)
		}
	}
	if w, a, m := h.GrabReport(); w != 3 || a != 3 || len(m) != 0 {
		t.Errorf("GrabReport = %d, %d, %v; want 3, 3, none", w, a, m)
	}
}

// A WM_HOTKEY for a registration translates back to that registration's
// Chord, so the daemon's exact (keysym, mods) match finds the chord.
func TestHotkeys_TranslateReadsBackActiveChord(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	chords := []string{"$mod+2", "$mod+Shift+d", "$mod+plus", "$mod+ISO_Left_Tab", "Mod4+Ctrl+Return"}
	h.SyncBinds(chords)
	act := h.Active()
	for id, c := range f.held {
		lp := uintptr(c.mods&^MOD_NOREPEAT) | uintptr(c.vk)<<16
		ev, ok := Translate(lp)
		if !ok {
			t.Fatalf("Translate(%#x) failed", lp)
		}
		found := false
		for _, ch := range chords {
			if a, ok := act[ch]; ok && a == (Chord{ev.Keysym, ev.Mods}) {
				found = true
			}
		}
		if !found {
			t.Errorf("id %d: WM_HOTKEY reads %+v, matching no active chord %v", id, ev, act)
		}
	}
	if got := act["$mod+plus"]; got != (Chord{'=', ModAlt | ModShift}) {
		t.Errorf("$mod+plus = %+v, want '=' with Alt|Shift", got)
	}
	if got := act["$mod+ISO_Left_Tab"]; got != (Chord{0xff09, ModAlt | ModShift}) {
		t.Errorf("$mod+ISO_Left_Tab = %+v, want Tab with Alt|Shift", got)
	}
}

// A layer change unregisters the chords leaving and registers the ones
// arriving; a chord in both is left alone.
func TestHotkeys_LayerChangeMovesTheDifference(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	h.SyncBinds([]string{"$mod+1", "$mod+2"})
	f.calls = nil
	if !h.SyncBinds([]string{"$mod+1", "3"}) {
		t.Error("SyncBinds reported no change")
	}
	want := "unreg 2,reg 3"
	if got := strings.Join(f.calls, ","); got != want {
		t.Errorf("calls = %s, want %s", got, want)
	}
	if !f.registered('1', MOD_NOREPEAT|MOD_ALT) || !f.registered('3', MOD_NOREPEAT) || f.registered('2', MOD_NOREPEAT|MOD_ALT) {
		t.Errorf("held after the change: %v", f.held)
	}
	f.calls = nil
	if h.SyncBinds([]string{"$mod+1", "3"}) || len(f.calls) != 0 {
		t.Errorf("an unchanged set made calls %v", f.calls)
	}
}

// One refused chord leaves the rest registered, is listed with its
// Windows error named, and is tried once per sync - never in a loop.
func TestHotkeys_RefusedChordListedNotRetriedInALoop(t *testing.T) {
	f := newFakeReg()
	f.refuse['2'] = ERROR_HOTKEY_ALREADY_REGISTERED
	var logs []string
	h := NewHotkeys(f, "Mod1", testKeysym, nil, func(s string) { logs = append(logs, s) })
	h.SyncBinds([]string{"$mod+1", "$mod+2", "$mod+3"})
	tries := 0
	for _, c := range f.calls {
		if c == "reg 2" {
			tries++
		}
	}
	if tries != 1 {
		t.Errorf("RegisterHotKey for the refused chord called %d times, want 1", tries)
	}
	w, a, missing := h.GrabReport()
	if w != 3 || a != 2 || len(missing) != 1 ||
		missing[0] != "$mod+2: RegisterHotKey refused: ERROR_HOTKEY_ALREADY_REGISTERED (1409)" {
		t.Errorf("GrabReport = %d, %d, %q", w, a, missing)
	}
	// A second identical sync logs nothing new.
	n := len(logs)
	h.SyncBinds([]string{"$mod+1", "$mod+2", "$mod+3"})
	if len(logs) != n {
		t.Errorf("the refusal was logged again: %v", logs[n:])
	}
	// Any other Windows error is named by number.
	if got := ErrorName(syscall.Errno(5)); got != "Windows error 5" {
		t.Errorf("ErrorName(5) = %q", got)
	}
}

// $mod+Shift+r never reaches RegisterHotKey, in any spelling.
func TestHotkeys_ReservedChordNeverRegistered(t *testing.T) {
	for _, chord := range []string{"$mod+Shift+r", "Mod1+Shift+r", "Alt+Shift+r", "Shift+$mod+r"} {
		f := newFakeReg()
		h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
		h.SyncBinds([]string{chord, "$mod+1"})
		for _, c := range f.calls {
			if c == "reg R" {
				t.Errorf("%s: RegisterHotKey was called for R", chord)
			}
		}
		if why := h.Refused()[chord]; why != ReasonReserved {
			t.Errorf("%s: refused as %q, want the reserved reason", chord, why)
		}
	}
}

// A chord bound only on release is refused with that reason and never
// registered (Task 5's hook serves it).
func TestHotkeys_ReleaseOnlyChordRefused(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, func(c string) bool { return c == "$mod+Print" }, nil)
	h.SyncBinds([]string{"$mod+Print", "$mod+1"})
	if len(f.held) != 1 || f.registered(VK_SNAPSHOT, MOD_NOREPEAT|MOD_ALT) {
		t.Errorf("held = %v", f.held)
	}
	_, _, missing := h.GrabReport()
	if len(missing) != 1 || missing[0] != "$mod+Print: "+ReasonOnRelease {
		t.Errorf("missing = %q", missing)
	}
}

// Two chords for the same key and modifiers: one registration, the
// second listed.
func TestHotkeys_SameKeyTwiceRegistersOnce(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	h.SyncBinds([]string{"$mod+Shift+equal", "$mod+plus"})
	if len(f.held) != 1 {
		t.Errorf("held = %v, want one registration", f.held)
	}
	if why := h.Refused()["$mod+plus"]; !strings.Contains(why, "$mod+Shift+equal") {
		t.Errorf("refused = %q", why)
	}
}

func TestHotkeys_ReleaseAll(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	h.SyncBinds([]string{"$mod+1", "$mod+2"})
	h.ReleaseAll()
	if len(f.held) != 0 || len(h.Active()) != 0 {
		t.Errorf("after ReleaseAll held %v active %v", f.held, h.Active())
	}
}

func TestX11ModsInvertsHotkeyMods(t *testing.T) {
	all := ModShift | ModCtrl | ModAlt | ModSuper
	for i := uint32(0); i < 128; i++ {
		x := i & all
		hk, err := HotkeyMods(x)
		if err != nil {
			t.Fatal(err)
		}
		if got := X11Mods(hk | MOD_NOREPEAT); got != x {
			t.Errorf("X11Mods(HotkeyMods(%#x)) = %#x", x, got)
		}
	}
}
