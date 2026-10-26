//go:build win32

package main

import (
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwi3rpc"
)

// win32Table is true: the shared table's frozen X11 assertions are skipped
// and this file pins the Windows table instead.
const win32Table = true

// win32Sock is a host pipe name; any non-empty $KWI3SOCK selects the kwi3
// table, the only one a Windows session has.
const win32Sock = `\\.\pipe\kwi3-jan-kwi3t-1-test`

// winBinds is the table the daemon grabs on Windows.
func winBinds() []bind.Bind { return effectiveBinds(win32Sock) }

func winBind(t *testing.T, chord string) bind.Bind {
	t.Helper()
	for _, b := range winBinds() {
		if b.Chord == chord {
			return b
		}
	}
	t.Fatalf("%s is not in the Windows table", chord)
	return bind.Bind{}
}

// allRuns is every Run the Windows table can start, with where it lives:
// global binds, every layer's binds and Mods, OnHoldRelease and OnExit.
func allRuns() map[string]string {
	out := map[string]string{}
	add := func(where string, acts []bind.Action) {
		for _, a := range acts {
			if r, ok := a.(bind.Run); ok {
				out[where] = r.Cmd
				where += "'" // a second Run in one action list
			}
		}
	}
	for _, b := range winBinds() {
		add(b.Chord, b.Actions)
	}
	for name, l := range Layers {
		for _, b := range layerBinds(l) {
			add(name+": "+b.Chord, b.Actions)
		}
		add(name+": OnHoldRelease", l.OnHoldRelease)
		add(name+": OnExit", l.OnExit)
	}
	return out
}

func TestWin32_EntryChords(t *testing.T) {
	cases := map[string][]bind.Action{
		"$mod+Return": runAction("wt.exe -w new"),
		"$mod+d":      runAction("kwi3-run.exe launcher"),
		"$mod+Tab": {
			bind.Run{Cmd: "kwi3-run.exe switcher"},
			bind.EnterLayer{Layer: "switcher"},
		},
	}
	for chord, want := range cases {
		if got := winBind(t, chord); !reflect.DeepEqual(got.Actions, want) {
			t.Errorf("%s = %#v, want %#v", chord, got.Actions, want)
		}
	}
}

func TestWin32_SwitcherLayerDrivesKwi3Run(t *testing.T) {
	sw, ok := Layers["switcher"]
	if !ok {
		t.Fatal("the switcher layer is missing on Windows")
	}
	run := func(v string) bind.Run { return bind.Run{Cmd: "kwi3-run.exe " + v} }
	want := map[string][]bind.Action{
		"Tab":          {run("switcher")},
		"w":            {run("switcher")},
		"ISO_Left_Tab": {run("switcher-prev")},
		"space":        {run("switcher-search"), bind.ExitLayer{}},
		"Escape":       {run("switcher-cancel"), bind.ExitLayer{}},
		"Return":       {run("switcher-confirm"), bind.ExitLayer{}},
	}
	got := map[string][]bind.Action{}
	for _, b := range sw.Binds {
		got[b.Chord] = b.Actions
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("switcher binds = %#v\nwant %#v", got, want)
	}
	if w := []bind.Action{run("switcher-confirm")}; !reflect.DeepEqual(sw.OnHoldRelease, w) {
		t.Errorf("switcher OnHoldRelease = %#v, want %#v", sw.OnHoldRelease, w)
	}
	if w := []bind.Action{run("switcher-cancel")}; !reflect.DeepEqual(sw.OnExit, w) {
		t.Errorf("switcher OnExit = %#v, want %#v", sw.OnExit, w)
	}
	if sw.Hold != "$mod" {
		t.Errorf("switcher Hold = %q, want $mod", sw.Hold)
	}
}

// Every program the Windows table can start is one Windows has: Windows
// Terminal or the runner, the runner only with a verb it knows.
func TestWin32_EveryRunIsAWindowsProgram(t *testing.T) {
	verbs := map[string]bool{
		"launcher": true, "switcher": true, "switcher-prev": true,
		"switcher-confirm": true, "switcher-cancel": true, "switcher-search": true,
	}
	for where, cmd := range allRuns() {
		w := strings.Fields(cmd)
		switch {
		case cmd == "wt.exe -w new":
		case len(w) == 2 && w[0] == "kwi3-run.exe" && verbs[w[1]]:
		default:
			t.Errorf("%s runs %q, not a Windows program this session has", where, cmd)
		}
	}
}

// The workspace chords go to kwi3 as RPC by position, as on the phone.
func TestWin32_WorkspaceChords(t *testing.T) {
	for n := 1; n <= 8; n++ {
		cases := map[string][]kwi3rpc.Call{
			fmt.Sprintf("$mod+%d", n):      {{Method: "workspace.focus", Params: map[string]interface{}{"num": n}}},
			fmt.Sprintf("$mod+Ctrl+%d", n): {{Method: "workspace.move", Params: map[string]interface{}{"num": n}}},
			fmt.Sprintf("$mod+Shift+%d", n): {
				{Method: "workspace.move", Params: map[string]interface{}{"num": n}},
				{Method: "workspace.focus", Params: map[string]interface{}{"num": n}}},
		}
		for chord, want := range cases {
			assertKwi3Calls(t, chord, want)
		}
	}
}

// $mod+s/$mod+b split and nothing else: no exec for a host that spawns
// nothing.
func TestWin32_SplitWithoutNotify(t *testing.T) {
	assertKwi3Calls(t, "$mod+s", []kwi3rpc.Call{{Method: "layout.split", Params: map[string]interface{}{"orientation": "horizontal"}}})
	assertKwi3Calls(t, "$mod+b", []kwi3rpc.Call{{Method: "layout.split", Params: map[string]interface{}{"orientation": "vertical"}}})
}

func assertKwi3Calls(t *testing.T, chord string, want []kwi3rpc.Call) {
	t.Helper()
	b := winBind(t, chord)
	if len(b.Actions) != 1 {
		t.Fatalf("%s: %d actions, want 1", chord, len(b.Actions))
	}
	cmd, ok := b.Actions[0].(bind.Command)
	if !ok {
		t.Fatalf("%s: action %T, want a kwi3 command, not a run", chord, b.Actions[0])
	}
	got, err := kwi3rpc.Translate(string(cmd))
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("%s: Translate(%q) = %#v, %v; want %#v", chord, cmd, got, err, want)
	}
}

// The chords whose programs Windows does not have are absent - listed here
// by chord, independently of host_win32.go's own list, read from the built
// table with and without $KWI3SOCK.
func TestWin32_LinuxOnlyChordsAbsent(t *testing.T) {
	absent := []string{
		"Print", "$mod+Print", "$mod+Shift+Print", "$mod+Shift+s", // screenshot
		"$mod+n", "$mod+v", // notifications, clipboard
		"$mod+0",                                // the system layer's entry
		"$mod+Shift+c",                          // restart in place (sp014)
		"$mod+p",                                // project picker: no kwi3-run verb
		"$mod+9", "$mod+Ctrl+m", "$mod+Shift+e", // blurlock, alsamixer, i3-nagbar
		bind.PanicChord, // the host's recover chord, never hotkeyd's
	}
	for _, table := range []struct {
		name  string
		binds []bind.Bind
	}{{"kwi3", winBinds()}, {"no $KWI3SOCK", effectiveBinds("")}} {
		have := map[string]bool{}
		for _, b := range table.binds {
			have[b.Chord] = true
		}
		var present []string
		for _, c := range absent {
			if have[c] {
				present = append(present, c)
			}
		}
		if len(present) != 0 {
			t.Errorf("%s table still has %v", table.name, present)
		}
	}
	if _, ok := Layers["system"]; ok {
		t.Error(`the "system" layer (i3exit) is still declared on Windows`)
	}
	for where, cmd := range allRuns() {
		if strings.Contains(cmd, "i3exit") {
			t.Errorf("%s still runs %q", where, cmd)
		}
	}
}

// The layers left are the shared ones less system; the External screenshot
// layers stay (set-layer raises them, no chord does).
func TestWin32_Layers(t *testing.T) {
	want := []string{"nav", "resize", "screenshot", "screenshot-drag", "switcher"}
	if got := sortedLayerNames(Layers); !reflect.DeepEqual(got, want) {
		t.Errorf("layers = %v, want %v", got, want)
	}
}

// The kwi3 tail is $mod+Shift+q alone, and the whole table is frozen by
// count: a chord added to the shared table must be decided for Windows.
func TestWin32_TableSize(t *testing.T) {
	tail := effectiveBinds(win32Sock)[len(Binds):]
	if got := chordsOf(tail); !reflect.DeepEqual(got, []string{"$mod+Shift+q"}) {
		t.Errorf("kwi3-only tail = %v, want [$mod+Shift+q]", got)
	}
	chords := chordsOf(Binds)
	sort.Strings(chords)
	if len(Binds) != 59 {
		t.Errorf("Windows Binds has %d chords, want 59 (70 shared less 11 removed): %v", len(Binds), chords)
	}
}

// bind.Validate passes on the Windows table under either $mod, with and
// without $KWI3SOCK - the check the daemon makes before it grabs.
func TestWin32_Validate(t *testing.T) {
	for _, mod := range bind.ModResolutions {
		for _, sock := range []string{win32Sock, ""} {
			if problems := bind.Validate(effectiveBinds(sock), Layers, mod); len(problems) != 0 {
				t.Errorf("Validate(mod=%s, sock=%q): %v", mod, sock, problems)
			}
			if err := validateTable(effectiveBinds(sock), Layers, mod); err != nil {
				t.Errorf("validateTable(mod=%s, sock=%q): %v", mod, sock, err)
			}
		}
	}
}
