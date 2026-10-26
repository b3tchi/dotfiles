package main

// sp012 Task 4 (kwi3-hoex.4): `--input win32`'s daemon side, on Linux. The
// real daemon loop, the real layer.Engine over the shipped Binds/Layers
// under $mod=Mod1 and the real win32.Hotkeys manager, against a recording
// fake Registrar (what would have reached RegisterHotKey) and WM_HOTKEY
// lParams fed through win32.Translate. The Windows thread itself is
// hotkeys_windows_test.go / win32run_windows_test.go.

import (
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/layer"
	"hotkeyd/internal/win32"
)

type recCall struct {
	reg  bool
	id   int32
	mods uint32
	vk   uint16
}

// recRegistrar is a goroutine-safe fake Registrar.
type recRegistrar struct {
	mu    sync.Mutex
	calls []recCall
	held  map[int32]recCall
}

func newRecRegistrar() *recRegistrar { return &recRegistrar{held: map[int32]recCall{}} }

func (r *recRegistrar) Register(id int32, mods uint32, vk uint16) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	c := recCall{true, id, mods, vk}
	r.calls = append(r.calls, c)
	r.held[id] = c
	return nil
}

func (r *recRegistrar) Unregister(id int32) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	c := r.held[id]
	c.reg = false
	r.calls = append(r.calls, c)
	delete(r.held, id)
	return nil
}

func (r *recRegistrar) holds(mods uint32, vk uint16) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, c := range r.held {
		if c.mods == mods && c.vk == vk {
			return true
		}
	}
	return false
}

func (r *recRegistrar) all() []recCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]recCall(nil), r.calls...)
}

const noRepeatAlt = win32.MOD_NOREPEAT | win32.MOD_ALT

type win32Rig struct {
	reg    *recRegistrar
	in     chan win32.Event
	k      *fakeKwi3
	states *stateRecorder
	modes  *modeServer
	sig    chan os.Signal
	done   chan int
}

func newWin32Rig(t *testing.T) *win32Rig {
	t.Helper()
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	reg := newRecRegistrar()
	hk := win32.NewHotkeys(reg, win32Mod, func(n string) (uint32, bool) {
		v, ok := keysymByName[n]
		return v, ok
	}, releaseOnlyChords(Binds, Layers, win32Mod), func(string) {})
	modes := newModeServer(t, false)
	states := &stateRecorder{}
	pub, rep := enginePublisher(states, modes.addr, func(string) {})
	t.Cleanup(func() { rep.Close() })
	engine := layer.NewEngine(Binds, Layers, layer.Config{Mod: win32Mod, Publisher: pub})
	in := make(chan win32.Event, 8)
	k := &fakeKwi3{}
	dae := NewDaemon(DaemonConfig{
		KeyEvents:   win32KeyEvents(in),
		Grabs:       win32Grabs{hk},
		Engine:      engine,
		Lock:        &fakeLock{},
		Kwi3:        k,
		NewModQuery: win32ModQuery(func(uint16) bool { return false }),
		Run:         func(string) error { return nil },
		Binds:       Binds, Layers: Layers, Mod: win32Mod, Display: "kwi3t-test",
		Log:      func(string) {},
		IdleTick: 10 * time.Second, HoldTick: 10 * time.Second,
	})
	dae.resyncGrabs()
	r := &win32Rig{reg: reg, in: in, k: k, states: states, modes: modes,
		sig: make(chan os.Signal, 1), done: make(chan int, 1)}
	go func() { r.done <- dae.Run(r.sig) }()
	t.Cleanup(func() {
		r.sig <- os.Interrupt
		select {
		case <-r.done:
		case <-time.After(3 * time.Second):
		}
	})
	return r
}

// hotkey is what the thread sends for a WM_HOTKEY with this lParam.
func (r *win32Rig) hotkey(t *testing.T, mods uint32, vk uint16) {
	t.Helper()
	ev, ok := win32.Translate(uintptr(mods) | uintptr(vk)<<16)
	if !ok {
		t.Fatalf("Translate(mods %#x vk %#x) failed", mods, vk)
	}
	r.in <- ev
}

// The default layer's chords are registered with MOD_NOREPEAT under Alt,
// and a WM_HOTKEY for one dispatches its command to kwi3.
func TestWin32CommandDispatch(t *testing.T) {
	r := newWin32Rig(t)
	if !r.reg.holds(noRepeatAlt, 'H') {
		t.Fatal("$mod+h is not registered as MOD_NOREPEAT|MOD_ALT, 'H'")
	}
	for _, c := range r.reg.all() {
		if c.reg && c.mods&win32.MOD_NOREPEAT == 0 {
			t.Errorf("registered without MOD_NOREPEAT: %+v", c)
		}
	}
	r.hotkey(t, win32.MOD_ALT, 'H')
	waitFor(t, "one dispatch", func() bool { return len(r.k.sent()) == 1 })
	if got := r.k.sent()[0]; got != "focus left" {
		t.Fatalf("dispatched %q, want focus left", got)
	}
	// A WM_HOTKEY for a key with no registration behind it does nothing.
	r.hotkey(t, win32.MOD_ALT|win32.MOD_CONTROL|win32.MOD_SHIFT, win32.VK_F1+21)
	time.Sleep(50 * time.Millisecond)
	if n := len(r.k.sent()); n != 1 {
		t.Fatalf("an unregistered key dispatched: %v", r.k.sent())
	}
}

// $mod+r enters resize: the layer's bare keys are registered (q only
// exists there), kwi3 is told mode.set resize, and leaving unregisters
// them again - the grab resync, through the shared path.
func TestWin32LayerResync(t *testing.T) {
	r := newWin32Rig(t)
	if r.reg.holds(win32.MOD_NOREPEAT, 'Q') {
		t.Fatal("bare q is registered in the default layer")
	}
	before := len(r.reg.all())
	r.hotkey(t, win32.MOD_ALT, 'R')
	waitFor(t, "resize layer's q registered", func() bool { return r.reg.holds(win32.MOD_NOREPEAT, 'Q') })
	waitFor(t, "mode.set resize", func() bool {
		for _, q := range r.modes.got() {
			if strings.Contains(q, "mode.set") && strings.Contains(q, "resize") {
				return true
			}
		}
		return false
	})
	// The entry chord stays registered across the change (only the
	// difference moves).
	for _, c := range r.reg.all()[before:] {
		if !c.reg && c.vk == 'R' && c.mods == noRepeatAlt {
			t.Errorf("$mod+r was unregistered on entering its own layer")
		}
	}
	r.hotkey(t, 0, 'Q')
	waitFor(t, "q unregistered after leaving", func() bool { return !r.reg.holds(win32.MOD_NOREPEAT, 'Q') })
	if l := r.states.layers(); l[len(l)-1] != layer.DefaultLayer {
		t.Fatalf("layers %v, want back in default", l)
	}
}

// Every layer of the shipped table, under $mod=Mod1: $mod+Shift+r (the
// host's recover chord) never reaches RegisterHotKey, and every
// registration carries MOD_NOREPEAT.
func TestWin32Table_ReservedChordNeverRegistered(t *testing.T) {
	binds := effectiveBinds("kwi3")
	names := []string{layer.DefaultLayer}
	for n := range Layers {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, name := range names {
		reg := newRecRegistrar()
		var refused []string
		hk := win32.NewHotkeys(reg, win32Mod, func(n string) (uint32, bool) {
			v, ok := keysymByName[n]
			return v, ok
		}, releaseOnlyChords(binds, Layers, win32Mod), func(s string) { refused = append(refused, s) })
		hk.SyncBinds(chordsFor(binds, Layers, name, win32Mod))
		for _, c := range reg.all() {
			if c.vk == 'R' && c.mods&^win32.MOD_NOREPEAT == win32.MOD_ALT|win32.MOD_SHIFT {
				t.Errorf("layer %s: $mod+Shift+r passed to RegisterHotKey", name)
			}
			if c.mods&win32.MOD_NOREPEAT == 0 {
				t.Errorf("layer %s: %+v without MOD_NOREPEAT", name, c)
			}
		}
		w, a, missing := hk.GrabReport()
		t.Logf("layer %s: %d wanted, %d registered, refused %q", name, w, a, missing)
		if a == 0 {
			t.Errorf("layer %s registered nothing", name)
		}
	}
	// And asked directly, it is refused by name.
	hk := win32.NewHotkeys(newRecRegistrar(), win32Mod, func(n string) (uint32, bool) {
		v, ok := keysymByName[n]
		return v, ok
	}, nil, nil)
	hk.SyncBinds([]string{bind.PanicChord})
	if why := hk.Refused()[bind.PanicChord]; why != win32.ReasonReserved {
		t.Errorf("%s refused as %q", bind.PanicChord, why)
	}
}

// A chord whose binds all fire on release is refused with that reason; a
// press chord is not.
func TestWin32ReleaseOnlyChords(t *testing.T) {
	binds := []bind.Bind{
		{Chord: "$mod+Print", Actions: runAction("a"), OnRelease: true},
		{Chord: "$mod+h", Actions: runAction("b")},
		{Chord: "$mod+j", Actions: runAction("c"), OnRelease: true},
		{Chord: "Mod1+j", Actions: runAction("d")},
	}
	ro := releaseOnlyChords(binds, nil, win32Mod)
	if !ro("$mod+Print") || !ro("Alt+Print") {
		t.Error("$mod+Print is release-only")
	}
	if ro("$mod+h") || ro("$mod+j") {
		t.Error("a chord with a press bind is not release-only")
	}
}

func TestWin32ModQuery(t *testing.T) {
	q := win32ModQuery(func(vk uint16) bool { return vk == win32.VK_RMENU })()
	if down, err := q("Mod1"); err != nil || !down {
		t.Errorf("Mod1 = %v, %v; want down", down, err)
	}
	if down, _ := q("Mod4"); down {
		t.Error("Mod4 reads down")
	}
	if _, err := q("Mod3"); err == nil {
		t.Error("an unknown modifier is not an error")
	}
}

func TestWin32InputRefusedOffWindows(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("a Windows build accepts --input win32")
	}
	if code := run([]string{"--input", "win32"}); code != 2 {
		t.Fatalf("--input win32 off Windows exited %d, want 2", code)
	}
}
