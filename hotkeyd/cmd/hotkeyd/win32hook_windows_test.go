package main

// sp012 Task 5 (kwi3-hoex.5): `--input win32` assembled with the low-level
// hook, on real Windows (test-win32.sh; "_Windows_" is its filter).
//
// SAFETY: no real WH_KEYBOARD_LL hook. Every test hands startWin32 a
// recording Install (a hook is session-wide: a real one would see Jan's
// keys), the hotkey thread runs DryRun (nothing registered), and the hook
// procedure is called directly through the pointer Windows would get.
// That proves the procedure, the queue and the dispatch - never that
// Windows delivers a key to the hook; that is attended (kwi3-hoex.14).

import (
	"os"
	"strings"
	"sync"
	"syscall"
	"testing"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/win32"
)

type installRecorder struct {
	mu sync.Mutex
	n  int
}

func (r *installRecorder) opts() win32.HookOptions {
	return win32.HookOptions{
		Install: func(uintptr) (uintptr, error) {
			r.mu.Lock()
			defer r.mu.Unlock()
			r.n++
			return 0x2000, nil
		},
		Uninstall: func(uintptr) error { return nil },
		KeyDown:   func(uint16) bool { return false },
	}
}

func (r *installRecorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.n
}

// holdTable is a switcher in miniature that dispatches only kwi3
// commands, so nothing is spawned: $mod+Tab -> workspace 1 and the hold
// layer, Tab in it -> workspace 2, the $mod release -> workspace 3.
func holdTable() ([]bind.Bind, map[string]bind.Layer) {
	binds := append([]bind.Bind(nil), smallTable...)
	binds = append(binds, bind.Bind{Chord: "$mod+Tab", Actions: []bind.Action{
		bind.Command("workspace 1"), bind.EnterLayer{Layer: "sw"}}})
	layers := map[string]bind.Layer{"sw": {
		Binds:         []bind.Bind{{Chord: "Tab", Actions: cmdAction("workspace 2")}},
		Hold:          "$mod",
		OnHoldRelease: cmdAction("workspace 3"),
		ExitKeys:      []string{"q"},
	}}
	return binds, layers
}

func startHookDaemon(t *testing.T, kwi3Sock string, binds []bind.Bind, layers map[string]bind.Layer, rec *installRecorder) *Daemon {
	t.Helper()
	dae, _, err := startWin32(win32Config{
		Display:  "hk-hook-test",
		Kwi3Sock: kwi3Sock,
		Binds:    binds,
		Layers:   layers,
		Source:   win32.Options{DryRun: true},
		Hook:     rec.opts(),
		Log:      func(s string) { t.Log(s) },
	})
	if err != nil {
		t.Fatalf("startWin32: %s", err)
	}
	sig := make(chan os.Signal, 1)
	done := make(chan int, 1)
	go func() { done <- dae.Run(sig) }()
	t.Cleanup(func() {
		sig <- os.Interrupt
		<-done
	})
	return dae
}

const (
	wmKeyDown    = 0x0100
	wmKeyUp      = 0x0101
	wmSysKeyDown = 0x0104
)

func hookCall(vk uint16, msg uintptr) uintptr {
	r, _, _ := syscall.SyscallN(win32.Proc(), 0, msg, uintptr(win32.NewKBDLLHookStruct(vk, 0)))
	return r
}

// A table with no hold layer and no release chord installs no hook. (Test
// names stay short: the mode server's socket lives under t.TempDir(), and
// AF_UNIX paths on Windows are capped at 108 bytes.)
func TestWin32Hook_Windows_NoHook(t *testing.T) {
	rec := &installRecorder{}
	startHookDaemon(t, newModeServer(t, false).addr, smallTable, map[string]bind.Layer{}, rec)
	if n := rec.count(); n != 0 {
		t.Fatalf("SetWindowsHookEx called %d time(s) for a table with no hold layer", n)
	}
}

// With a hold layer: exactly one hook; $mod+Tab and Tab while held are
// swallowed and dispatched, the $mod release passes and fires
// OnHoldRelease once, other keys pass.
func TestWin32Hook_Windows_Hold(t *testing.T) {
	rec := &installRecorder{}
	modes := newModeServer(t, false)
	binds, layers := holdTable()
	dae := startHookDaemon(t, modes.addr, binds, layers, rec)
	if n := rec.count(); n != 1 {
		t.Fatalf("SetWindowsHookEx called %d time(s), want 1", n)
	}
	if _, ok := dae.grabs.Active()["$mod+Tab"]; !ok {
		t.Fatal("$mod+Tab not served")
	}
	focuses := func() int {
		n := 0
		for _, r := range modes.got() {
			if strings.HasPrefix(r, "workspace.focus") {
				n++
			}
		}
		return n
	}
	for i, s := range []struct {
		vk   uint16
		msg  uintptr
		want uintptr
	}{
		{win32.VK_LMENU, wmSysKeyDown, 0},
		{win32.VK_TAB, wmSysKeyDown, 1},
		{win32.VK_TAB, wmKeyUp, 1},
	} {
		if got := hookCall(s.vk, s.msg); got != s.want {
			t.Fatalf("step %d: proc %d, want %d", i, got, s.want)
		}
	}
	waitFor(t, "$mod+Tab dispatched", func() bool { return focuses() == 1 })
	if hookCall(win32.VK_TAB, wmSysKeyDown) != 1 || hookCall(win32.VK_TAB, wmKeyUp) != 1 {
		t.Fatal("Tab while $mod held passed")
	}
	waitFor(t, "Tab dispatched in the layer", func() bool { return focuses() == 2 })
	if hookCall('A', wmSysKeyDown) != 0 || hookCall('A', wmKeyUp) != 0 {
		t.Fatal("an unowned key was swallowed")
	}
	if hookCall(win32.VK_LMENU, wmKeyUp) != 0 {
		t.Fatal("$mod release swallowed")
	}
	waitFor(t, "OnHoldRelease dispatched", func() bool { return focuses() == 3 })
	if hookCall(win32.VK_TAB, wmKeyDown) != 0 {
		t.Error("bare Tab swallowed after the layer ended")
	}
	hookCall(win32.VK_TAB, wmKeyUp)
	if n := focuses(); n != 3 {
		t.Errorf("%d workspace.focus calls, want 3 (OnHoldRelease once)", n)
	}
}
