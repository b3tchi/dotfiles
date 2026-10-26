package win32

// sp012 Task 5 (kwi3-hoex.5): the hook thread and the real hook procedure
// on Windows, run through hotkeyd/test-win32.sh.
//
// SAFETY: NO real WH_KEYBOARD_LL hook is installed by any test here - a
// low-level hook is session-wide and would see (and could swallow) Jan's
// own keys. Every StartHook passes a recording Install, and the real
// installer refuses in a test binary anyway (the first test proves it
// refuses before calling SetWindowsHookExW). The hook procedure is called
// directly, through the same callback pointer Windows would be handed.

import (
	"errors"
	"sync"
	"syscall"
	"testing"
	"time"
)

const (
	wmKeyDown    = 0x0100
	wmSysKeyDown = 0x0104
)

type fakeInstaller struct {
	mu        sync.Mutex
	installs  []uintptr
	uninstall []uintptr
	next      uintptr
}

func (f *fakeInstaller) install(proc uintptr) (uintptr, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.installs = append(f.installs, proc)
	f.next++
	return 0x1000 + f.next, nil
}

func (f *fakeInstaller) remove(h uintptr) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.uninstall = append(f.uninstall, h)
	return nil
}

func (f *fakeInstaller) counts() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.installs), len(f.uninstall)
}

func startTestHook(t *testing.T, h *Hook, f *fakeInstaller, down func(uint16) bool, every time.Duration, log func(string)) *HookThread {
	t.Helper()
	ht, err := StartHook(h, HookOptions{Install: f.install, Uninstall: f.remove,
		KeyDown: down, ProbeEvery: every, ProbeConfirm: 10 * time.Millisecond, Log: log})
	if err != nil {
		t.Fatalf("StartHook: %s", err)
	}
	t.Cleanup(ht.Close)
	return ht
}

func nothingDown(uint16) bool { return false }

// The real installer never installs from a test binary.
func TestLLHook_Windows_RealInstallRefusedInTests(t *testing.T) {
	if _, err := realInstall(Proc()); !errors.Is(err, errInstallInTest) {
		t.Fatalf("realInstall in a test: %v, want the refusal", err)
	}
}

// One install with the hook procedure's address; Close uninstalls that
// handle; DryRun installs nothing.
func TestLLHook_Windows_InstallAndClose(t *testing.T) {
	f := &fakeInstaller{}
	ht, err := StartHook(NewHook(8), HookOptions{Install: f.install, Uninstall: f.remove, KeyDown: nothingDown})
	if err != nil {
		t.Fatal(err)
	}
	if n, _ := f.counts(); n != 1 || f.installs[0] != Proc() || ht.Installs() != 1 {
		t.Fatalf("installs %v, want one of %#x", f.installs, Proc())
	}
	ht.Close()
	if _, u := f.counts(); u != 1 || f.uninstall[0] != 0x1001 {
		t.Fatalf("uninstalls %v, want [0x1001]", f.uninstall)
	}

	g := &fakeInstaller{}
	dry, err := StartHook(NewHook(8), HookOptions{DryRun: true, Install: g.install, Uninstall: g.remove, KeyDown: nothingDown})
	if err != nil {
		t.Fatal(err)
	}
	dry.Close()
	if n, u := g.counts(); n != 0 || u != 0 {
		t.Fatalf("DryRun: %d installs %d uninstalls", n, u)
	}
}

func callProc(vk uint16, msg uintptr, flags uint32) uintptr {
	r, _, _ := syscall.SyscallN(Proc(), 0, msg, uintptr(NewKBDLLHookStruct(vk, flags)))
	return r
}

// The real hook procedure, called the way Windows calls it: $mod+Tab is
// swallowed (1), every other key goes to CallNextHookEx (0 with no other
// hook), an nCode below zero is passed without a look, and $mod+Shift+r
// passes even when owned.
func TestLLHook_Windows_ProcSwallowsAndPasses(t *testing.T) {
	h := NewHook(32)
	f := &fakeInstaller{}
	startTestHook(t, h, f, nothingDown, time.Hour, nil)
	drainUntil := func() []HookEvent {
		time.Sleep(10 * time.Millisecond)
		return drain(h)
	}
	drainUntil() // the start's Resync
	h.SetOwned(map[Chord]bool{
		{Keysym: ksTab, Mods: ModAlt}:          true,
		{Keysym: 'r', Mods: ModAlt | ModShift}: true,
	})
	steps := []struct {
		vk   uint16
		msg  uintptr
		want uintptr
	}{
		{VK_LMENU, wmSysKeyDown, 0},
		{VK_TAB, wmSysKeyDown, 1},
		{VK_TAB, wmKeyUp, 1},
		{'A', wmSysKeyDown, 0},
		{'A', wmKeyUp, 0},
		{VK_LSHIFT, wmSysKeyDown, 0},
		{'R', wmSysKeyDown, 0},
		{'R', wmKeyUp, 0},
		{VK_LSHIFT, wmKeyUp, 0},
		{VK_LMENU, wmKeyUp, 0},
	}
	for i, s := range steps {
		if got := callProc(s.vk, s.msg, 0); got != s.want {
			t.Fatalf("step %d vk %#x: proc returned %d, want %d", i, s.vk, got, s.want)
		}
	}
	evs := drainUntil()
	var presses int
	for _, ev := range evs {
		if ev.Kind == "press" {
			presses++
			if ev.Keysym != ksTab || ev.Mods != ModAlt {
				t.Errorf("queued press %+v", ev)
			}
		}
	}
	if presses != 1 {
		t.Errorf("events %+v, want one press", evs)
	}
	// nCode < 0: straight to CallNextHookEx, nothing decided.
	r, _, _ := syscall.SyscallN(Proc(), ^uintptr(0), wmSysKeyDown, uintptr(NewKBDLLHookStruct(VK_LMENU, 0)))
	if r != 0 || len(drainUntil()) != 0 {
		t.Errorf("nCode -1: returned %d / queued something", r)
	}
}

// Windows removed the hook: the keyboard says Alt is down, the hook never
// saw it. The probe notices, reinstalls once, logs, and the resync makes
// the hook agree with the keyboard.
func TestLLHook_Windows_ProbeReinstallsARemovedHook(t *testing.T) {
	h := NewHook(32)
	f := &fakeInstaller{}
	var mu sync.Mutex
	alt := false
	down := func(vk uint16) bool {
		mu.Lock()
		defer mu.Unlock()
		return alt && vk == VK_LMENU
	}
	var logs []string
	ht := startTestHook(t, h, f, down, 30*time.Millisecond, func(s string) {
		mu.Lock()
		logs = append(logs, s)
		mu.Unlock()
	})
	time.Sleep(100 * time.Millisecond)
	if ht.Reinstalls() != 0 {
		t.Fatal("reinstalled with nothing amiss")
	}
	mu.Lock()
	alt = true // pressed while the hook was gone
	mu.Unlock()
	deadline := time.Now().Add(3 * time.Second)
	for ht.Reinstalls() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	if ht.Reinstalls() != 1 || ht.Installs() != 2 {
		t.Fatalf("reinstalls %d installs %d, want 1 and 2", ht.Reinstalls(), ht.Installs())
	}
	if h.Mods() != ModAlt {
		t.Errorf("hook mods %#x after the resync, want Alt", h.Mods())
	}
	mu.Lock()
	n := len(logs)
	mu.Unlock()
	if n != 1 {
		t.Errorf("logged %d lines, want 1", n)
	}
	if _, u := f.counts(); u != 1 {
		t.Errorf("uninstalls %d before the reinstall, want 1", u)
	}
}

// A second hook in one process is refused (one callback slot, one hook).
func TestLLHook_Windows_OneHookPerProcess(t *testing.T) {
	f := &fakeInstaller{}
	startTestHook(t, NewHook(8), f, nothingDown, time.Hour, nil)
	if _, err := StartHook(NewHook(8), HookOptions{Install: f.install, Uninstall: f.remove, KeyDown: nothingDown}); err == nil {
		t.Fatal("a second hook started")
	}
}
