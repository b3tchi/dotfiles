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
	return newWin32RigWith(t, func(string) {}, nil)
}

// newWin32RigWith is newWin32Rig with the daemon's log and HOTKEYD_TRACE's
// sink (nil: no trace) handed in, and the WM_HOTKEY stream traced through
// win32Merge exactly as startWin32 wires it.
func newWin32RigWith(t *testing.T, log, trace func(string)) *win32Rig {
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
	var tr *win32Trace
	if trace != nil {
		tr = &win32Trace{log: trace}
	}
	keyEvents := win32Merge(in, nil, nil, log, nil, tr)
	dae := NewDaemon(DaemonConfig{
		KeyEvents:   keyEvents,
		Trace:       trace,
		Grabs:       win32Grabs{hk},
		Engine:      engine,
		Lock:        &fakeLock{},
		Kwi3:        k,
		NewModQuery: win32ModQuery(func(uint16) bool { return false }),
		Run:         func(string) error { return nil },
		Binds:       Binds, Layers: Layers, Mod: win32Mod, Display: "kwi3t-test",
		Log:      log,
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

// kwi3-hoex.35 (Jan, live, 2026-10-29): holding Alt+Shift and pressing
// Left twice moved the window once. RegisterHotKey reports a press and
// never a release, so the engine, which reads "same key down again with
// no release seen" as auto-repeat (isRepeat, X11's), swallowed every
// further WM_HOTKEY of that key within KeyWedgeMS of the last one. With
// MOD_NOREPEAT Windows sends no WM_HOTKEY for auto-repeat at all, so each
// one is a real keystroke and must dispatch.
func TestWin32HotkeyRepeatedWhileModsHeld(t *testing.T) {
	r := newWin32Rig(t)
	for i := 0; i < 3; i++ {
		r.hotkey(t, win32.MOD_ALT|win32.MOD_SHIFT, win32.VK_LEFT)
	}
	waitFor(t, "three dispatches", func() bool { return len(r.k.sent()) == 3 })
	for i, got := range r.k.sent() {
		if got != "move left" {
			t.Errorf("dispatch %d = %q, want move left", i, got)
		}
	}
}

// HOTKEYD_TRACE (kwi3-hoex.35). Off, the daemon writes no trace line for a
// WM_HOTKEY; on, each one gets the WM_HOTKEY line (id, key, modifiers,
// message time, async modifiers) and the daemon's line (the chord it
// resolved, the layer, the actions), and a key with no chord behind it
// says so.
func TestWin32Trace(t *testing.T) {
	quiet := &logRecorder{}
	r := newWin32RigWith(t, quiet.log, nil)
	r.in <- win32.Event{VK: win32.VK_LEFT, Keysym: 0xff51, Mods: win32.ModAlt | win32.ModShift, ID: 3, MsgTime: 100}
	waitFor(t, "dispatch", func() bool { return len(r.k.sent()) == 1 })
	for _, l := range quiet.all() {
		if strings.Contains(l, "trace") || strings.Contains(l, "WM_HOTKEY") {
			t.Fatalf("trace off, yet the log has %q", l)
		}
	}

	logs, traces := &logRecorder{}, &logRecorder{}
	r = newWin32RigWith(t, logs.log, traceLog(traces.log, func() time.Time {
		return time.Date(2026, 10, 29, 14, 5, 6, 789e6, time.UTC)
	}))
	// One event at a time: the WM_HOTKEY line and the daemon's line come
	// from two goroutines, so only each pair's order is fixed.
	steps := []struct {
		ev   win32.Event
		want [2]string
	}{
		{win32.Event{VK: win32.VK_LEFT, Keysym: 0xff51, Mods: win32.ModAlt | win32.ModShift, ID: 3, MsgTime: 100, Async: win32.ModAlt | win32.ModShift},
			[2]string{"trace 14:05:06.789 WM_HOTKEY id=3 vk=0x25 keysym=0xff51 mods=Shift+Alt msgtime=100 async=Shift+Alt",
				"trace 14:05:06.789 key press Left mods=0x9 norelease=true layer=default -> 1 action(s) [move left]"}},
		{win32.Event{VK: win32.VK_LEFT, Keysym: 0xff51, Mods: win32.ModAlt | win32.ModShift, ID: 3, MsgTime: 180, Async: win32.ModAlt},
			[2]string{"trace 14:05:06.789 WM_HOTKEY id=3 vk=0x25 keysym=0xff51 mods=Shift+Alt msgtime=180 async=Alt",
				"trace 14:05:06.789 key press Left mods=0x9 norelease=true layer=default -> 1 action(s) [move left]"}},
		{win32.Event{VK: win32.VK_F1 + 21, Keysym: 0xffd3, Mods: win32.ModAlt, ID: 99, MsgTime: 200},
			[2]string{"trace 14:05:06.789 WM_HOTKEY id=99 vk=0x85 keysym=0xffd3 mods=Alt msgtime=200 async=none",
				"trace 14:05:06.789 key press keysym=0xffd3 mods=0x8: no active chord, ignored"}},
	}
	for i, st := range steps {
		r.in <- st.ev
		n := 2 * (i + 1)
		waitFor(t, "two trace lines", func() bool { return len(traces.all()) >= n })
		got := traces.all()[n-2 : n]
		if got[0] != st.want[0] || got[1] != st.want[1] {
			t.Errorf("step %d:\n got %s\n     %s\nwant %s\n     %s", i, got[0], got[1], st.want[0], st.want[1])
		}
	}
	if len(r.k.sent()) != 2 {
		t.Errorf("dispatched %v, want move left twice", r.k.sent())
	}
	for _, l := range logs.all() {
		if strings.Contains(l, "trace") {
			t.Errorf("a trace line went to the daemon log, not the trace sink: %q", l)
		}
	}
}

// HOTKEYD_TRACE's gate: unset, empty, 0 or anything but 1 is no trace and
// no line; 1 (spaces trimmed) says so once on the log and returns the sink.
func TestWin32TraceFromEnv(t *testing.T) {
	now := func() time.Time { return time.Date(2026, 10, 29, 1, 2, 3, 4e6, time.UTC) }
	for _, v := range []string{"", "0", "true", "yes", "11"} {
		var lines []string
		if tr := traceFromEnv(func(k string) string {
			if k == win32TraceEnv {
				return v
			}
			return ""
		}, func(s string) { lines = append(lines, s) }, now); tr != nil || len(lines) != 0 {
			t.Errorf("HOTKEYD_TRACE=%q: trace %v, lines %q - want none", v, tr != nil, lines)
		}
	}
	var lines []string
	tr := traceFromEnv(func(k string) string {
		if k == "HOTKEYD_TRACE" {
			return " 1 "
		}
		return ""
	}, func(s string) { lines = append(lines, s) }, now)
	if tr == nil || len(lines) != 1 || !strings.HasPrefix(lines[0], "HOTKEYD_TRACE=1: tracing") {
		t.Fatalf("HOTKEYD_TRACE=1: trace %v, lines %q", tr != nil, lines)
	}
	tr("x")
	if lines[1] != "trace 01:02:03.004 x" {
		t.Fatalf("trace line %q", lines[1])
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
