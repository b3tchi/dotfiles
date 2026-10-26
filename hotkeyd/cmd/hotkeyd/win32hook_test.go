package main

// sp012 Task 5 (kwi3-hoex.5): the low-level hook wired to the real daemon,
// engine and shipped table, on Linux. NO hook is installed: the test calls
// the hook's decision (win32.Hook.Decide, the callback's whole body) with
// synthetic KBDLLHOOKSTRUCT-shaped events, and the daemon reads what it
// queued exactly as it would from the real callback.

import (
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/layer"
	"hotkeyd/internal/proc"
	"hotkeyd/internal/win32"
)

type runRecorder struct {
	mu    sync.Mutex
	cmds  []string
	block chan struct{} // non-nil: the first Run waits on it
}

func (r *runRecorder) run(cmd string) error {
	r.mu.Lock()
	r.cmds = append(r.cmds, cmd)
	first := len(r.cmds) == 1
	block := r.block
	r.mu.Unlock()
	if first && block != nil {
		<-block
	}
	return nil
}

func (r *runRecorder) got() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.cmds...)
}

type hookRig struct {
	hook   *win32.Hook
	hk     *win32.Hotkeys
	reg    *recRegistrar
	runs   *runRecorder
	states *stateRecorder
	in     chan win32.Event
	logs   *logRecorder
}

type logRecorder struct {
	mu    sync.Mutex
	lines []string
}

func (l *logRecorder) log(s string) {
	l.mu.Lock()
	l.lines = append(l.lines, s)
	l.mu.Unlock()
}

func (l *logRecorder) all() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.lines...)
}

// newHookRig assembles what startWin32 does when the table needs the hook:
// the Hotkeys manager routing hookChords to the hook, the hook's queue
// merged with the WM_HOTKEY stream, the hold poll on the stream's mods.
func newHookRig(t *testing.T, buffer int, runs *runRecorder) *hookRig {
	t.Helper()
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	if !tableNeedsHook(Binds, Layers) {
		t.Fatal("the shipped table has no hold layer: nothing for the hook to do")
	}
	reg := newRecRegistrar()
	hook := win32.NewHook(buffer)
	hk := win32.NewHotkeys(reg, win32Mod, func(n string) (uint32, bool) {
		v, ok := keysymByName[n]
		return v, ok
	}, releaseOnlyChords(Binds, Layers, win32Mod), func(string) {})
	hk.UseHook(hook, hookChords(Binds, Layers, win32Mod))
	states := &stateRecorder{}
	engine := layer.NewEngine(Binds, Layers, layer.Config{Mod: win32Mod, Publisher: states})
	in := make(chan win32.Event, 8)
	logs := &logRecorder{}
	dae := NewDaemon(DaemonConfig{
		KeyEvents: win32Merge(in, hook.Events(), hook, logs.log, nil),
		Grabs:     win32Grabs{hk},
		Engine:    engine,
		Lock:      &fakeLock{},
		Kwi3:      &fakeKwi3{},
		Run:       runs.run,
		Binds:     Binds, Layers: Layers, Mod: win32Mod, Display: "kwi3t-test",
		Log:      logs.log,
		IdleTick: 10 * time.Second, HoldTick: 10 * time.Second,
	})
	dae.resyncGrabs()
	sig := make(chan os.Signal, 1)
	done := make(chan int, 1)
	go func() { done <- dae.Run(sig) }()
	t.Cleanup(func() {
		sig <- os.Interrupt
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("daemon did not stop")
		}
	})
	return &hookRig{hook: hook, hk: hk, reg: reg, runs: runs, states: states, in: in, logs: logs}
}

// layer is the engine's layer as last published (the engine itself is the
// daemon goroutine's alone).
func (r *hookRig) layer() string {
	l := r.states.layers()
	if len(l) == 0 {
		return layer.DefaultLayer
	}
	return l[len(l)-1]
}

func kdown(vk uint16) win32.KeyInput { return win32.KeyInput{VK: vk} }
func kup(vk uint16) win32.KeyInput {
	return win32.KeyInput{VK: vk, Up: true, Flags: win32.LLKHF_UP}
}

func countRuns(cmds []string, suffix string) int {
	n := 0
	for _, c := range cmds {
		if strings.HasSuffix(c, " "+suffix) {
			n++
		}
	}
	return n
}

// The shipped table needs the hook (the switcher is a hold layer); a table
// with neither a hold layer nor a release chord does not.
func TestWin32Hook_TableNeedsHook(t *testing.T) {
	if !tableNeedsHook(Binds, Layers) {
		t.Error("shipped table: no hook needed")
	}
	plain := []bind.Bind{{Chord: "$mod+1", Actions: cmdAction("workspace 1")}}
	if tableNeedsHook(plain, map[string]bind.Layer{"resize": Layers["resize"]}) {
		t.Error("plain table with a non-hold layer: hook needed")
	}
	rel := []bind.Bind{{Chord: "$mod+Print", Actions: runAction("x"), OnRelease: true}}
	if !tableNeedsHook(rel, nil) {
		t.Error("a release-only chord: no hook needed")
	}
}

// Which chords the hook serves: the switcher's entry and every chord of
// the hold layer; never a plain chord, never the recover chord. A global
// chord on the same key as a hold-layer chord ($mod+Return: the layer's
// Return under the held $mod) is the hook's throughout - one owner per
// key, and no RegisterHotKey churn on every Alt+Tab.
func TestWin32Hook_HookChords(t *testing.T) {
	via := hookChords(Binds, Layers, win32Mod)
	for _, c := range []string{"$mod+Tab", "Mod1+Tab", "Tab", "Mod1+Escape", "Mod1+ISO_Left_Tab", "Mod1+w", "$mod+Return"} {
		if !via(c) {
			t.Errorf("%s not served by the hook", c)
		}
	}
	for _, c := range []string{"$mod+1", "$mod+h", "$mod+Shift+r", "Mod1+Shift+r", "$mod+d"} {
		if via(c) {
			t.Errorf("%s served by the hook", c)
		}
	}
}

// $mod+Tab enters the switcher and is swallowed; Tab while held is
// swallowed and dispatched; the $mod release passes and fires
// OnHoldRelease exactly once; $mod+Tab never reaches RegisterHotKey.
func TestWin32Hook_SwitcherHoldSequence(t *testing.T) {
	runs := &runRecorder{}
	r := newHookRig(t, 0, runs)
	if r.reg.holds(noRepeatAlt, win32.VK_TAB) {
		t.Fatal("$mod+Tab registered with RegisterHotKey")
	}
	steps := []struct {
		in      win32.KeyInput
		swallow bool
	}{
		{kdown(win32.VK_LMENU), false},
		{kdown(win32.VK_TAB), true},
		{kup(win32.VK_TAB), true},
	}
	for i, s := range steps {
		if got := r.hook.Decide(s.in); got != s.swallow {
			t.Fatalf("step %d: swallow %v, want %v", i, got, s.swallow)
		}
	}
	waitFor(t, "switcher layer", func() bool { return r.layer() == "switcher" })
	for i := 0; i < 2; i++ {
		if !r.hook.Decide(kdown(win32.VK_TAB)) || !r.hook.Decide(kup(win32.VK_TAB)) {
			t.Fatal("Tab while $mod held passed")
		}
	}
	waitFor(t, "two cycles", func() bool { return countRuns(r.runs.got(), "switcher") == 3 })
	if r.hook.Decide(kup(win32.VK_LMENU)) {
		t.Fatal("$mod release swallowed")
	}
	waitFor(t, "back in default", func() bool { return r.layer() == layer.DefaultLayer })
	// A later re-statement of the same state (the probe's Remind) must
	// not fire it again.
	r.hook.Remind()
	time.Sleep(100 * time.Millisecond)
	got := r.runs.got()
	if n := countRuns(got, "switcher-confirm"); n != 1 {
		t.Errorf("switcher-confirm ran %d times, want 1: %q", n, got)
	}
	// The layer's on_exit tidies up AFTER the commit, as on X11 (engine
	// run(): commit first, idempotent cleanup second, dotfiles-hwds.51).
	if n := countRuns(got, "switcher-cancel"); n > 1 || (n == 1 && !strings.HasSuffix(got[len(got)-1], "switcher-cancel")) {
		t.Errorf("switcher-cancel not once after the commit: %q", got)
	}
	// In the default layer bare Tab passes again.
	if r.hook.Decide(kdown(win32.VK_TAB)) {
		t.Error("bare Tab swallowed outside the switcher")
	}
	r.hook.Decide(kup(win32.VK_TAB))
}

// $mod+Shift+r passes the hook in the switcher and out of it, and nothing
// is dispatched for it.
func TestWin32Hook_RecoverChordPasses(t *testing.T) {
	runs := &runRecorder{}
	r := newHookRig(t, 0, runs)
	seq := []win32.KeyInput{kdown(win32.VK_LMENU), kdown(win32.VK_LSHIFT), kdown('R'), kup('R'), kup(win32.VK_LSHIFT)}
	for _, in := range seq {
		if r.hook.Decide(in) {
			t.Fatalf("%+v swallowed (outside the switcher)", in)
		}
	}
	r.hook.Decide(kdown(win32.VK_TAB))
	r.hook.Decide(kup(win32.VK_TAB))
	waitFor(t, "switcher layer", func() bool { return r.layer() == "switcher" })
	for _, in := range []win32.KeyInput{kdown(win32.VK_LSHIFT), kdown('R'), kup('R'), kup(win32.VK_LSHIFT)} {
		if r.hook.Decide(in) {
			t.Fatalf("%+v swallowed in the switcher", in)
		}
	}
	r.hook.Decide(kup(win32.VK_LMENU))
	waitFor(t, "back in default", func() bool { return r.layer() == layer.DefaultLayer })
	for _, c := range r.runs.got() {
		if strings.Contains(c, " r") {
			t.Errorf("dispatched %q for the recover chord", c)
		}
	}
}

// The callback only queues: with the engine blocked for 2 s in a Run, the
// hook keeps answering each event in under 1 ms, the overflow counter
// rises instead, the daemon says so once it reads again, and the probe's
// re-statement of the modifiers ends the layer the dropped release left up.
func TestWin32Hook_BlockedEngineNeverBlocksCallback(t *testing.T) {
	runs := &runRecorder{block: make(chan struct{})}
	r := newHookRig(t, 16, runs)
	r.hook.Decide(kdown(win32.VK_LMENU))
	r.hook.Decide(kdown(win32.VK_TAB)) // -> Run "switcher", which blocks
	waitFor(t, "the engine is in the blocked Run", func() bool { return len(runs.got()) == 1 })

	release := time.AfterFunc(2*time.Second, func() { close(runs.block) })
	defer release.Stop()
	var took []time.Duration
	t0 := time.Now()
	for time.Since(t0) < 1500*time.Millisecond {
		for _, in := range []win32.KeyInput{kup(win32.VK_TAB), kdown(win32.VK_TAB)} {
			s := time.Now()
			if !r.hook.Decide(in) {
				t.Fatal("an owned Tab passed while the engine was blocked")
			}
			took = append(took, time.Since(s))
		}
		time.Sleep(time.Millisecond)
	}
	r.hook.Decide(kup(win32.VK_TAB))
	if r.hook.Decide(kup(win32.VK_LMENU)) { // most likely dropped: the queue is full
		t.Fatal("$mod release swallowed")
	}
	p99, worst := callbackTimes(t, took)
	if r.hook.Overflow() == 0 {
		t.Fatalf("no overflow after %d events against a blocked engine", len(took))
	}
	t.Logf("%d callbacks with the engine blocked: p99 %s, slowest %s, %d dropped", len(took), p99, worst, r.hook.Overflow())

	waitFor(t, "the drop is logged", func() bool {
		for _, l := range r.logs.all() {
			if strings.Contains(l, "dropped, the queue was full") {
				return true
			}
		}
		return false
	})
	r.hook.Remind() // the probe's tick
	waitFor(t, "back in default", func() bool { return r.layer() == layer.DefaultLayer })
	time.Sleep(100 * time.Millisecond)
	if c := countRuns(runs.got(), "switcher-confirm"); c != 1 {
		t.Errorf("switcher-confirm ran %d times, want 1", c)
	}
}

// callbackTimes holds the callback to its bound: 99% of calls under 1 ms,
// and not one anywhere near the engine's 2 s block. The bound is on the
// 99th percentile, not the slowest call, because this is wall-clock time
// on a shared box: the OS descheduling the test thread mid-call (seen:
// 1.4 ms once in five runs, with the race detector off) is not the
// callback waiting for anything. A callback that waited on the engine
// would take ~2 s and fail the second check by three orders of magnitude.
func callbackTimes(t *testing.T, took []time.Duration) (p99, worst time.Duration) {
	t.Helper()
	sorted := append([]time.Duration(nil), took...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	p99 = sorted[len(sorted)*99/100]
	worst = sorted[len(sorted)-1]
	if p99 >= time.Millisecond {
		t.Errorf("p99 callback %s, want under 1ms", p99)
	}
	if worst >= 50*time.Millisecond {
		t.Errorf("slowest callback %s: it waited on something", worst)
	}
	return p99, worst
}

// $mod released while hotkeyd was not running: the hook starts with
// nothing held (Resync from the keyboard), the orphan release leaves the
// daemon in the default layer, and a following Tab passes.
func TestWin32Hook_StaleModAtStartNoStuckLayer(t *testing.T) {
	runs := &runRecorder{}
	r := newHookRig(t, 0, runs)
	r.hook.Resync(func(uint16) bool { return false })
	if r.hook.Decide(kup(win32.VK_LMENU)) {
		t.Fatal("orphan $mod release swallowed")
	}
	time.Sleep(50 * time.Millisecond)
	if l := r.layer(); l != layer.DefaultLayer {
		t.Fatalf("layer %q after an orphan release", l)
	}
	if r.hook.Decide(kdown(win32.VK_TAB)) {
		t.Error("Tab swallowed with no $mod")
	}
	if len(runs.got()) != 0 {
		t.Errorf("ran %q", runs.got())
	}
}

// Chords the hook serves count as GRANTED in the grab report - the report
// `hotkeyd --health` reads (sp012 Task 7): with the hook up, none of them
// is ever "missing", in the default layer or the switcher. Under the
// Windows table (-tags win32) nothing at all is missing in either layer.
func TestWin32Hook_HookChordsCountAsGranted(t *testing.T) {
	runs := &runRecorder{}
	r := newHookRig(t, 0, runs)
	via := hookChords(Binds, Layers, win32Mod)
	check := func(where string, above int) int {
		t.Helper()
		// The published report (the daemon goroutine owns the manager;
		// the file is what it wrote after its last resync).
		var wanted, active int
		var missing []string
		waitFor(t, where+": report settles", func() bool {
			rep, ok := proc.ReadGrabReport("kwi3t-test")
			if !ok {
				return false
			}
			wanted, active, missing = rep.Wanted, rep.Active, rep.Missing
			for _, m := range missing {
				if via(strings.SplitN(m, ": ", 2)[0]) {
					return false
				}
			}
			return wanted > above // the layer's chords are in
		})
		hooked := r.hook.Owned()
		if len(hooked) == 0 {
			t.Fatalf("%s: the hook serves nothing", where)
		}
		if overlayCmd() == "kwi3-run.exe" && (len(missing) != 0 || active != wanted) {
			t.Errorf("%s (Windows table): %d of %d granted, missing %q", where, active, wanted, missing)
		}
		t.Logf("%s: %d of %d granted, %d by the hook, missing %q", where, active, wanted, len(hooked), missing)
		return wanted
	}
	base := check("default layer", 0)
	r.hook.Decide(kdown(win32.VK_LMENU))
	r.hook.Decide(kdown(win32.VK_TAB))
	waitFor(t, "switcher layer", func() bool { return r.layer() == "switcher" })
	check("switcher layer", base)
	r.hook.Decide(kup(win32.VK_TAB))
	r.hook.Decide(kup(win32.VK_LMENU))
}
