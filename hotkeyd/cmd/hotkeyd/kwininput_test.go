package main

// sp011 Task 10: `--input kwin`. Every test drives the real daemon loop, the
// real layer.Engine over the shipped Binds/Layers and the real
// kwin.GrabManager, against a fake kwi3keys plugin on a unix socket (so the
// grab sets asserted are what actually crossed the wire) and a fake kwi3
// dispatcher / mode server. Nothing here touches X.

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwin"
	"hotkeyd/internal/layer"
)

// grabSet is a set of (keysym, mods) pairs.
type grabSet map[[2]uint32]bool

type fakePlugin struct {
	t    *testing.T
	ln   net.Listener
	path string

	mu    sync.Mutex
	conn  net.Conn
	grabs []grabSet // every grab set received
	wake  chan struct{}
}

func newFakePlugin(t *testing.T) *fakePlugin {
	t.Helper()
	p := filepath.Join(os.TempDir(), "hk10-"+strings.ReplaceAll(t.Name(), "/", "_")+".sock")
	os.Remove(p)
	ln, err := net.Listen("unix", p)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakePlugin{t: t, ln: ln, path: p, wake: make(chan struct{}, 64)}
	t.Cleanup(func() { ln.Close(); os.Remove(p) })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Write([]byte(`{"hello":1,"kwin":"6.8.1"}` + "\n"))
			f.mu.Lock()
			f.conn = c
			f.mu.Unlock()
			go f.read(c)
		}
	}()
	return f
}

func (f *fakePlugin) read(c net.Conn) {
	br := bufio.NewReader(c)
	for {
		line, err := br.ReadBytes('\n')
		if err != nil {
			return
		}
		var m struct {
			Grab []struct{ Keysym, Mods uint32 } `json:"grab"`
		}
		if json.Unmarshal(line, &m) == nil && m.Grab != nil {
			set := grabSet{}
			for _, g := range m.Grab {
				set[[2]uint32{g.Keysym, g.Mods}] = true
			}
			f.mu.Lock()
			f.grabs = append(f.grabs, set)
			f.mu.Unlock()
			f.wake <- struct{}{}
		}
	}
}

func (f *fakePlugin) send(line string) {
	f.mu.Lock()
	c := f.conn
	f.mu.Unlock()
	c.Write([]byte(line + "\n"))
}

func (f *fakePlugin) drop() {
	f.mu.Lock()
	c := f.conn
	f.mu.Unlock()
	c.Close()
}

func (f *fakePlugin) lastGrab() grabSet {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.grabs) == 0 {
		return nil
	}
	return f.grabs[len(f.grabs)-1]
}

// waitGrab waits for a grab set satisfying ok to be the latest one.
func (f *fakePlugin) waitGrab(ok func(grabSet) bool, what string) grabSet {
	f.t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		if g := f.lastGrab(); g != nil && ok(g) {
			return g
		}
		select {
		case <-f.wake:
		case <-deadline:
			f.t.Fatalf("timed out waiting for grab set: %s (last %v)", what, f.lastGrab())
		}
	}
}

const (
	ksReturn = 0xff0d
	ksH      = 'h'
	ksTab    = 0xff09
	ksR      = 'r'
	ksQ      = 'q'
	modSuper = 64
)

type kwinRig struct {
	t      *testing.T
	plugin *fakePlugin
	dae    *Daemon
	k      *fakeKwi3
	runs   *[]string
	runMu  *sync.Mutex
	sig    chan os.Signal
	done   chan int
	states *stateRecorder
	modes  *modeServer
}

func newKwinRig(t *testing.T) *kwinRig {
	t.Helper()
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	pl := newFakePlugin(t)
	gm, err := kwin.NewGrabManager(pl.path, "Mod4", func(n string) (uint32, bool) {
		v, ok := keysymByName[n]
		return v, ok
	}, func(string) {})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(gm.Close)

	modes := newModeServer(t, false)
	states := &stateRecorder{}
	pub, rep := enginePublisher(states, modes.addr, func(string) {})
	t.Cleanup(func() { rep.Close() })
	engine := layer.NewEngine(Binds, Layers, layer.Config{Mod: "Mod4", Publisher: pub})

	var mu sync.Mutex
	var runs []string
	k := &fakeKwi3{}
	dae := NewDaemon(DaemonConfig{
		KeyEvents: gm.Events(),
		Grabs:     kwinGrabs{gm},
		Engine:    engine,
		Lock:      &fakeLock{},
		XConn:     closerFunc(gm.Close),
		Kwi3:      k,
		Run: func(c string) error {
			mu.Lock()
			runs = append(runs, c)
			mu.Unlock()
			return nil
		},
		Binds: Binds, Layers: Layers, Mod: "Mod4", Display: kwinDisplay,
		Log:      func(string) {},
		IdleTick: 10 * time.Second, HoldTick: 10 * time.Second,
	})
	dae.resyncGrabs()
	r := &kwinRig{t: t, plugin: pl, dae: dae, k: k, runs: &runs, runMu: &mu,
		sig: make(chan os.Signal, 1), done: make(chan int, 1), states: states, modes: modes}
	go func() { r.done <- dae.Run(r.sig) }()
	t.Cleanup(r.stop)
	return r
}

func (r *kwinRig) stop() {
	select {
	case r.sig <- os.Interrupt:
	default:
	}
	select {
	case <-r.done:
	case <-time.After(3 * time.Second):
	}
}

func (r *kwinRig) press(ks, mods uint32) {
	r.plugin.send(`{"ev":"press","keysym":` + itoa(ks) + `,"mods":` + itoa(mods) + `,"device":"kbd"}`)
}
func (r *kwinRig) release(ks, mods uint32) {
	r.plugin.send(`{"ev":"release","keysym":` + itoa(ks) + `,"mods":` + itoa(mods) + `,"device":"kbd"}`)
}
func (r *kwinRig) modsEv(m uint32) { r.plugin.send(`{"mods":` + itoa(m) + `}`) }

func itoa(v uint32) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func (r *kwinRig) runList() []string {
	r.runMu.Lock()
	defer r.runMu.Unlock()
	return append([]string(nil), *r.runs...)
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out: %s", what)
}

func hasKey(g grabSet, ks, mods uint32) bool { return g[[2]uint32{ks, mods}] }

func TestKwinCommandDispatch(t *testing.T) {
	r := newKwinRig(t)
	r.plugin.waitGrab(func(g grabSet) bool { return hasKey(g, ksH, modSuper) }, "default set has $mod+h")
	r.press(ksH, modSuper)
	waitFor(t, "one dispatch", func() bool { return len(r.k.sent()) == 1 })
	if got := r.k.sent()[0]; got != "focus left" {
		t.Fatalf("dispatched %q, want focus left", got)
	}
	r.release(ksH, modSuper)
	time.Sleep(100 * time.Millisecond)
	if n := len(r.k.sent()); n != 1 {
		t.Fatalf("release dispatched again: %d calls, want exactly 1 per press", n)
	}
}

func TestKwinRunSpawns(t *testing.T) {
	r := newKwinRig(t)
	r.plugin.waitGrab(func(g grabSet) bool { return hasKey(g, ksReturn, modSuper) }, "default set has $mod+Return")
	r.press(ksReturn, modSuper)
	waitFor(t, "spawn", func() bool { return len(r.runList()) == 1 })
	want := ""
	for _, b := range Binds {
		if b.Chord == "$mod+Return" {
			want = b.Actions[0].(bind.Run).Cmd
		}
	}
	if got := r.runList()[0]; want == "" || !strings.Contains(got, want) {
		t.Fatalf("spawned %q", got)
	}
	if n := len(r.k.sent()); n != 0 {
		t.Fatalf("a Run chord also dispatched %d rpc call(s)", n)
	}
}

// $mod+r enters resize: the plugin is sent the resize layer's keys (bare q
// only exists in the layer's set), and kwi3 is told mode.set resize.
func TestKwinLayerResync(t *testing.T) {
	r := newKwinRig(t)
	g0 := r.plugin.waitGrab(func(g grabSet) bool { return hasKey(g, ksR, modSuper) }, "default set has $mod+r")
	if hasKey(g0, ksQ, 0) {
		t.Fatal("bare q is grabbed in the default layer")
	}
	r.press(ksR, modSuper)
	r.plugin.waitGrab(func(g grabSet) bool { return hasKey(g, ksQ, 0) }, "resize layer's exit key q grabbed")
	if got := r.states.layers(); got[len(got)-1] != "resize" {
		t.Fatalf("engine layers %v, want to end in resize", got)
	}
	waitFor(t, "mode.set resize", func() bool {
		for _, q := range r.modes.got() {
			if strings.Contains(q, "mode.set") && strings.Contains(q, "resize") {
				return true
			}
		}
		return false
	})
	// and back out again: q leaves, bare keys are released to applications.
	r.press(ksQ, 0)
	r.plugin.waitGrab(func(g grabSet) bool { return !hasKey(g, ksQ, 0) }, "q released after leaving")
}

// A hold layer ends when the held modifier's release arrives on the mods
// stream, with no key event at all - the same commit the X11 path gets from
// its idle poll.
func TestKwinHoldRelease(t *testing.T) {
	r := newKwinRig(t)
	r.plugin.waitGrab(func(g grabSet) bool { return hasKey(g, ksTab, modSuper) }, "default set has $mod+Tab")
	r.modsEv(modSuper)
	r.press(ksTab, modSuper)
	waitFor(t, "switcher layer", func() bool {
		l := r.states.layers()
		return len(l) > 0 && l[len(l)-1] == "switcher"
	})
	var runsBefore int
	r.runMu.Lock()
	runsBefore = len(*r.runs)
	r.runMu.Unlock()
	r.modsEv(0) // $mod released
	waitFor(t, "layer exit", func() bool {
		l := r.states.layers()
		return l[len(l)-1] == layer.DefaultLayer
	})
	runs := r.runList()
	confirmed := false
	for _, c := range runs[min(runsBefore, len(runs)):] {
		confirmed = confirmed || strings.Contains(c, "switcher-confirm")
	}
	if !confirmed {
		t.Fatalf("on_hold_release did not run: %v", runs)
	}
}

// A plugin whose connection drops takes its grabs with it: the engine must
// not stay in a layer nobody can leave, and the (default) set is re-sent
// when the plugin comes back.
func TestKwinReconnectResetsLayer(t *testing.T) {
	r := newKwinRig(t)
	r.plugin.waitGrab(func(g grabSet) bool { return hasKey(g, ksR, modSuper) }, "default set")
	r.press(ksR, modSuper)
	r.plugin.waitGrab(func(g grabSet) bool { return hasKey(g, ksQ, 0) }, "in resize")
	r.plugin.drop()
	waitFor(t, "engine reset", func() bool {
		l := r.states.layers()
		return l[len(l)-1] == layer.DefaultLayer
	})
	// The client re-sends whatever set it last had the moment it reconnects
	// (the stale resize one); the daemon then converges it to the default.
	r.plugin.waitGrab(func(g grabSet) bool { return hasKey(g, ksR, modSuper) && !hasKey(g, ksQ, 0) },
		"default set (no bare q) re-sent after reconnect")
}

// --input kwin never dials X and refuses to run without $KWI3SOCK.
func TestKwinNoDisplay(t *testing.T) {
	t.Setenv("DISPLAY", "")
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())

	t.Run("unset KWI3SOCK is refused, no i3 fallback", func(t *testing.T) {
		t.Setenv("KWI3SOCK", "")
		if code := runKwin(filepath.Join(t.TempDir(), "none.sock")); code != 78 {
			t.Fatalf("exit %d, want 78", code)
		}
	})

	t.Run("starts with DISPLAY unset", func(t *testing.T) {
		pl := newFakePlugin(t)
		t.Setenv("KWI3SOCK", filepath.Join(t.TempDir(), "kwi3.rpc.sock"))
		done := make(chan int, 1)
		go func() { done <- runKwin(pl.path) }()
		pl.waitGrab(func(g grabSet) bool { return len(g) > 0 }, "daemon grabbed chords with no X display")
		// stop it the way the service manager does
		p, _ := os.FindProcess(os.Getpid())
		p.Signal(os.Interrupt)
		select {
		case code := <-done:
			if code != 0 {
				t.Fatalf("exit %d, want 0", code)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("daemon did not stop")
		}
	})
}
