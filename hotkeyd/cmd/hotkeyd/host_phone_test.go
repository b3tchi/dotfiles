//go:build phone

package main

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwi3rpc"
	"hotkeyd/internal/layer"
)

// phoneBind finds chord in the table the kwin input actually grabs.
func phoneBind(t *testing.T, chord string) bind.Bind {
	t.Helper()
	for _, b := range effectiveBinds("/run/kwi3.sock") {
		if b.Chord == chord {
			return b
		}
	}
	t.Fatalf("%s is not in the phone's table", chord)
	return bind.Bind{}
}

func TestPhoneTable(t *testing.T) {
	if got := phoneBind(t, "$mod+Return"); !reflect.DeepEqual(got.Actions, runAction("~/.local/bin/wm-launch-terminal foot")) {
		t.Fatalf("$mod+Return on the phone = %+v, want run wm-launch-terminal foot", got)
	}
	// Kwi3OnlyBinds is appended after the shared table; the override must
	// still reach it.
	if got := phoneBind(t, "$mod+Shift+c"); !reflect.DeepEqual(got.Actions, runAction("$HOME/.local/bin/i3reload")) {
		t.Fatalf("$mod+Shift+c on the phone = %+v, want run i3reload", got)
	}
	wantCam := []bind.Action{bind.Run{Cmd: qsOverlay + " camera-open"}, bind.EnterLayer{Layer: "camera"}}
	if got := phoneBind(t, "$mod+f"); !reflect.DeepEqual(got.Actions, wantCam) {
		t.Fatalf("$mod+f on the phone = %+v, want qs-overlay.sh camera-open + camera layer", got)
	}
	for _, mod := range bind.ModResolutions {
		if problems := bind.Validate(effectiveBinds("/run/kwi3.sock"), Layers, mod); len(problems) != 0 {
			t.Errorf("Validate(mod=%s): %v", mod, problems)
		}
	}
}

// The workspace chords go to kwi3 as RPC, by position, with nothing run on
// the phone: switch, move, move-and-follow.
func TestPhoneWorkspaceChords(t *testing.T) {
	for n := 1; n <= 8; n++ {
		cases := map[string][]kwi3rpc.Call{
			fmt.Sprintf("$mod+%d", n):      {{Method: "workspace.focus", Params: map[string]interface{}{"num": n}}},
			fmt.Sprintf("$mod+Ctrl+%d", n): {{Method: "workspace.move", Params: map[string]interface{}{"num": n}}},
			fmt.Sprintf("$mod+Shift+%d", n): {
				{Method: "workspace.move", Params: map[string]interface{}{"num": n}},
				{Method: "workspace.focus", Params: map[string]interface{}{"num": n}}},
		}
		for chord, want := range cases {
			b := phoneBind(t, chord)
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
	}
}

// The camera layer drives quickshell's CameraOverlay (sp041 Task 7): every
// command it runs is a qs-overlay.sh camera-* verb, and the old gst path
// (phone-cam) is gone. space / Return / f snap and stay in the layer (the
// overlay ends it after the photo), Escape / q close and leave, and an
// involuntary exit closes too, so the preview never outlives the keys.
func TestCameraLayerDrivesOverlay(t *testing.T) {
	lay, ok := Layers["camera"]
	if !ok {
		t.Fatal("no camera layer")
	}
	want := map[string]string{
		"space": "camera-snap", "Return": "camera-snap", "f": "camera-snap",
		"Escape": "camera-close", "q": "camera-close",
	}
	got := map[string]string{}
	for _, b := range lay.Binds {
		var cmd string
		exits := false
		for _, a := range b.Actions {
			switch a := a.(type) {
			case bind.Run:
				cmd = a.Cmd
			case bind.ExitLayer:
				exits = true
			}
		}
		if strings.Contains(cmd, "phone-cam") {
			t.Errorf("%s still runs phone-cam: %q", b.Chord, cmd)
		}
		// A snap key must NOT leave the layer: leaving dispatches OnExit
		// (camera-close) at the same moment, which races the snap and wins
		// (photo not copied/announced, or not taken). The overlay ends the
		// layer itself after the photo (set-layer default). Close keys leave.
		snap := strings.HasSuffix(cmd, "camera-snap")
		if snap && exits {
			t.Errorf("%s snaps AND leaves the layer: its OnExit camera-close races the snap", b.Chord)
		}
		if !snap && !exits {
			t.Errorf("%s does not leave the camera layer", b.Chord)
		}
		got[b.Chord] = strings.TrimPrefix(cmd, qsOverlay+" ")
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("camera layer verbs = %v, want %v", got, want)
	}
	if !reflect.DeepEqual(lay.OnExit, runAction(qsOverlay+" camera-close")) {
		t.Errorf("camera OnExit = %+v, want qs-overlay.sh camera-close", lay.OnExit)
	}
	if !reflect.DeepEqual(lay.ExitKeys, []string{"BackSpace"}) {
		t.Errorf("camera ExitKeys = %v, want [BackSpace]", lay.ExitKeys)
	}
}

// What the camera keys actually DISPATCH through the layer engine, OnExit
// included (dotfiles-h0hl.7 audit): a snap must run camera-snap alone, never
// camera-close beside it (the two raced and the close won).
func TestCameraKeysDispatch(t *testing.T) {
	e := layer.NewEngine(effectiveBinds("/run/kwi3.sock"), Layers, layer.Config{Mod: kwinMod, Clock: time.Now})
	runs := func(acts []bind.Action) []string {
		var out []string
		for _, a := range acts {
			if r, ok := a.(bind.Run); ok {
				out = append(out, strings.TrimPrefix(r.Cmd, qsOverlay+" "))
			}
		}
		return out
	}
	press := func(key string, mods ...string) []string {
		m := map[string]bool{}
		for _, mod := range mods {
			m[mod] = true
		}
		return runs(e.Handle(layer.Event{Kind: layer.Press, Key: key, Mods: m}))
	}

	if got := press("f", kwinMod); !reflect.DeepEqual(got, []string{"camera-open"}) {
		t.Fatalf("$mod+f runs %v, want [camera-open]", got)
	}
	if got := e.State().Layer; got != "camera" {
		t.Fatalf("after $mod+f layer = %q, want camera", got)
	}
	if got := press("space"); !reflect.DeepEqual(got, []string{"camera-snap"}) {
		t.Fatalf("space runs %v, want exactly [camera-snap] (no racing camera-close)", got)
	}
	if got := e.State().Layer; got != "camera" {
		t.Fatalf("after space layer = %q, want camera (the overlay ends it after the photo)", got)
	}
	got := press("q")
	if len(got) == 0 || got[0] != "camera-close" {
		t.Fatalf("q runs %v, want camera-close", got)
	}
	for _, c := range got {
		if c == "camera-snap" {
			t.Fatalf("q runs %v: must not snap", got)
		}
	}
	if got := e.State().Layer; got != layer.DefaultLayer {
		t.Fatalf("after q layer = %q, want default", got)
	}
}
