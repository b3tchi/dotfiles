package win32

// sp012 Task 4 (kwi3-hoex.4): the RegisterHotKey thread on real Windows,
// run through hotkeyd/test-win32.sh.
//
// SAFETY: RegisterHotKey registrations are shared by every desktop of the
// window station (kwi3-hoex.8 measured it), so these tests register only
// Ctrl+Alt+Shift+F22/F23 - keys no keyboard here has - and everything
// else goes through DryRun or a posted WM_HOTKEY. kwi3-hoex.8's own rig
// key is Alt+Shift+F24; these never collide with it.

import (
	"errors"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

const (
	vkF22 uint16 = 0x85
	vkF23 uint16 = 0x86
	// testMods is a combination nobody presses with F22/F23.
	testMods = MOD_CONTROL | MOD_ALT | MOD_SHIFT
)

var procFindWindowExW = modUser32.NewProc("FindWindowExW")

func startSource(t *testing.T, opts Options) *Source {
	t.Helper()
	s, err := Start(opts)
	if err != nil {
		t.Fatalf("Start: %s", err)
	}
	t.Cleanup(s.Close)
	return s
}

func postHotkey(t *testing.T, hwnd uintptr, id int32, mods uint32, vk uint16) {
	t.Helper()
	if r, _, err := procPostMessageW.Call(hwnd, uintptr(WM_HOTKEY), uintptr(id), uintptr(mods)|uintptr(vk)<<16); r == 0 {
		t.Fatalf("PostMessageW(WM_HOTKEY): %s", err)
	}
}

func nextEvent(t *testing.T, s *Source) Event {
	t.Helper()
	select {
	case ev, ok := <-s.Events():
		if !ok {
			t.Fatal("Events closed")
		}
		return ev
	case <-time.After(3 * time.Second):
		t.Fatal("no event within 3s")
	}
	return Event{}
}

// The thread owns a message-only window; a WM_HOTKEY posted to it comes
// out of Events as the key's keysym and X11 modifier bits.
func TestWindows_PostedHotkeyIsTranslated(t *testing.T) {
	s := startSource(t, Options{DryRun: true})
	cls, _ := syscall.UTF16PtrFromString(ClassName)
	found, _, _ := procFindWindowExW.Call(hwndMessage, 0, uintptr(unsafe.Pointer(cls)), 0)
	if found == 0 {
		t.Fatalf("no message-only window of class %s", ClassName)
	}
	t.Logf("window %#x on thread %d (FindWindowEx(HWND_MESSAGE) found %#x)", s.Window(), s.ThreadID(), found)

	postHotkey(t, s.Window(), 7, MOD_ALT, '2')
	if ev := key(nextEvent(t, s)); ev != (Event{VK: '2', Keysym: '2', Mods: ModAlt, ID: 7}) {
		t.Errorf("Alt+2 read %+v", ev)
	}
	postHotkey(t, s.Window(), 8, MOD_ALT|MOD_SHIFT, VK_RETURN)
	if ev := key(nextEvent(t, s)); ev != (Event{VK: VK_RETURN, Keysym: 0xff0d, Mods: ModAlt | ModShift, ID: 8}) {
		t.Errorf("Alt+Shift+Return read %+v", ev)
	}
	// A key the translator has no keysym for is dropped, not sent.
	postHotkey(t, s.Window(), 9, MOD_ALT, 0xFF)
	postHotkey(t, s.Window(), 10, MOD_WIN, 'Q')
	if ev := key(nextEvent(t, s)); ev != (Event{VK: 'Q', Keysym: 'q', Mods: ModSuper, ID: 10}) {
		t.Errorf("after an unknown VK, Win+Q read %+v", ev)
	}
}

// key is ev without the message time, which the test cannot predict. With
// no Options.Trace, Async must read 0: nothing was asked of the keyboard.
func key(ev Event) Event {
	ev.MsgTime = 0
	return ev
}

// HOTKEYD_TRACE (kwi3-hoex.35): with Options.Trace, each WM_HOTKEY carries
// the modifier keys read down as it was taken (KeyDown, here a chosen
// answer: Alt and right Shift down), its registration id and a message
// time; without it, KeyDown is never called.
func TestWindows_TraceReadsAsyncModifiers(t *testing.T) {
	asked := 0
	s := startSource(t, Options{DryRun: true, Trace: true, KeyDown: func(vk uint16) bool {
		asked++
		return vk == VK_LMENU || vk == VK_RSHIFT
	}})
	postHotkey(t, s.Window(), 21, MOD_ALT|MOD_SHIFT, VK_LEFT)
	ev := nextEvent(t, s)
	if ev.ID != 21 || ev.VK != VK_LEFT || ev.Mods != ModAlt|ModShift || ev.Async != ModAlt|ModShift || ev.MsgTime == 0 {
		t.Fatalf("traced Alt+Shift+Left read %+v", ev)
	}
	if asked == 0 {
		t.Fatal("KeyDown was never asked")
	}
	t.Logf("trace: %s", ev.TraceString())

	asked = 0
	quiet := startSource(t, Options{DryRun: true, KeyDown: func(uint16) bool { asked++; return true }})
	postHotkey(t, quiet.Window(), 22, MOD_ALT, VK_LEFT)
	if ev := nextEvent(t, quiet); ev.Async != 0 || asked != 0 {
		t.Fatalf("untraced: Async %#x, KeyDown asked %d times", ev.Async, asked)
	}
}

// DryRun never reaches RegisterHotKey; an injected Register answers on
// the loop's own thread, and what it says is what the manager reports.
func TestWindows_InjectedRegisterRunsOnTheLoopThread(t *testing.T) {
	var onThread []uintptr
	var s *Source
	s = startSource(t, Options{Register: func(hwnd uintptr, id int32, mods uint32, vk uint16) error {
		onThread = append(onThread, hwnd)
		if vk == '2' {
			return ERROR_HOTKEY_ALREADY_REGISTERED
		}
		return nil
	}})
	h := NewHotkeys(s, "Mod1", func(n string) (uint32, bool) {
		return map[string]uint32{"1": '1', "2": '2'}[n], n == "1" || n == "2"
	}, nil, nil)
	h.SyncBinds([]string{"$mod+1", "$mod+2"})
	if len(onThread) != 2 || onThread[0] != s.Window() {
		t.Fatalf("Register calls %v, want 2 on window %#x", onThread, s.Window())
	}
	_, a, missing := h.GrabReport()
	if a != 1 || len(missing) != 1 || missing[0] != "$mod+2: RegisterHotKey refused: ERROR_HOTKEY_ALREADY_REGISTERED (1409)" {
		t.Errorf("report %d %q", a, missing)
	}
}

// Real RegisterHotKey, on a key nobody has: the first registration is
// granted, a second thread's registration of the same chord is refused
// with ERROR_HOTKEY_ALREADY_REGISTERED and listed by the manager, and once
// the first thread has ended the chord registers again (Windows freed it).
func TestWindows_RealRegisterRefusedThenFreedOnExit(t *testing.T) {
	a := startSource(t, Options{})
	if err := a.Register(1, testMods|MOD_NOREPEAT, vkF23); err != nil {
		if errors.Is(err, ERROR_HOTKEY_ALREADY_REGISTERED) {
			t.Skipf("UNVERIFIED: Ctrl+Alt+Shift+F23 is already registered by another process here")
		}
		t.Fatalf("RegisterHotKey(Ctrl+Alt+Shift+F23) on a message-only window: %s", ErrorName(err))
	}
	t.Logf("RegisterHotKey(Ctrl+Alt+Shift+F23) on window %#x: granted", a.Window())

	b := startSource(t, Options{})
	keysym := func(n string) (uint32, bool) {
		ks, ok := map[string]uint32{"F22": 0xffbe + 21, "F23": 0xffbe + 22}[n]
		return ks, ok
	}
	h := NewHotkeys(b, "Mod1", keysym, nil, nil)
	h.SyncBinds([]string{"Ctrl+Mod1+Shift+F23", "Ctrl+Mod1+Shift+F22"})
	_, active, missing := h.GrabReport()
	if active != 1 || len(missing) != 1 ||
		missing[0] != "Ctrl+Mod1+Shift+F23: RegisterHotKey refused: ERROR_HOTKEY_ALREADY_REGISTERED (1409)" {
		t.Fatalf("second thread: %d active, missing %q", active, missing)
	}
	t.Logf("second thread: F22 granted, F23 refused: %q", missing)
	h.ReleaseAll()

	a.Close() // the thread holding F23 ends without unregistering it
	c := startSource(t, Options{})
	if err := c.Register(1, testMods|MOD_NOREPEAT, vkF23); err != nil {
		t.Fatalf("after the holder's thread ended, F23 still refused: %s", ErrorName(err))
	}
	if err := c.Unregister(1); err != nil {
		t.Errorf("UnregisterHotKey: %s", ErrorName(err))
	}
	if err := c.Unregister(1); !errors.Is(err, ERROR_HOTKEY_NOT_REGISTERED) {
		t.Errorf("a second UnregisterHotKey = %v, want ERROR_HOTKEY_NOT_REGISTERED", err)
	}
}

// Close ends the loop: Events closes and later calls fail instead of
// hanging.
func TestWindows_CloseEndsTheThread(t *testing.T) {
	s, err := Start(Options{DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	select {
	case _, ok := <-s.Events():
		if ok {
			t.Fatal("an event after Close")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Events not closed")
	}
	if err := s.Register(1, MOD_NOREPEAT|testMods, vkF22); err == nil {
		t.Fatal("Register after Close succeeded")
	}
	s.Close() // twice is harmless
}

func TestWindows_DesktopName(t *testing.T) {
	name, err := DesktopName()
	if err != nil || name == "" {
		t.Fatalf("DesktopName = %q, %v", name, err)
	}
	t.Logf("this test runs on desktop %q", name)
}
