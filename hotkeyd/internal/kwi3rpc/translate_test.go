package kwi3rpc

import (
	"reflect"
	"testing"
)

// callsEqual compares Translate's output ignoring map key order (maps
// compare fine with reflect.DeepEqual already, this helper just gives a
// readable failure).
func wantCalls(t *testing.T, cmd string, want []Call) {
	t.Helper()
	got, err := Translate(cmd)
	if err != nil {
		t.Fatalf("Translate(%q): unexpected error: %s", cmd, err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Translate(%q) = %#v, want %#v", cmd, got, want)
	}
}

func wantUnsupported(t *testing.T, cmd string) {
	t.Helper()
	_, err := Translate(cmd)
	if err == nil {
		t.Fatalf("Translate(%q): expected an error, got none", cmd)
	}
	if _, ok := err.(*UnsupportedVerbError); !ok {
		t.Fatalf("Translate(%q): expected *UnsupportedVerbError, got %T: %s", cmd, err, err)
	}
}

// -- the exact strings hotkeyd's real table (cmd/hotkeyd/config.go) sends --

func TestTranslateFocusDirections(t *testing.T) {
	for _, d := range []string{"left", "right", "up", "down"} {
		wantCalls(t, "focus "+d, []Call{{Method: "window.focus", Params: map[string]interface{}{"direction": d}}})
	}
}

func TestTranslateFocusParent(t *testing.T) {
	// No ft010 method takes a "parent" direction; the escape hatch is the
	// same one i3act/i3tree use headless - a named binding, run by
	// action.run (core/commands.js's bindings(): {name: "focusParent",
	// action: "parent"}).
	wantCalls(t, "focus parent", []Call{{Method: "action.run", Params: map[string]interface{}{"name": "focusParent"}}})
}

func TestTranslateMoveDirections(t *testing.T) {
	for _, d := range []string{"left", "right", "up", "down"} {
		wantCalls(t, "move "+d, []Call{{Method: "window.move", Params: map[string]interface{}{"direction": d}}})
	}
}

func TestTranslateResize(t *testing.T) {
	// rpc.js: "delta's SIGN is grow/shrink, its magnitude is not" - any
	// nonzero value on the right side steps by RESIZE_STEP either way, so
	// the translated delta need not carry hotkeyd's own "5 px or 5 ppt"
	// amount at all.
	wantCalls(t, "resize shrink width 5 px or 5 ppt",
		[]Call{{Method: "window.resize", Params: map[string]interface{}{"dimension": "width", "delta": -1}}})
	wantCalls(t, "resize grow height 10 px or 10 ppt",
		[]Call{{Method: "window.resize", Params: map[string]interface{}{"dimension": "height", "delta": 1}}})
}

func TestTranslateBorder(t *testing.T) {
	wantCalls(t, "border none", []Call{{Method: "window.border", Params: map[string]interface{}{"style": "none"}}})
	// The pixel WIDTH ("4") has no home in ft010's window.border (style
	// only, no thickness) - kwi3 draws one frame width regardless, so it is
	// dropped rather than invented a param for.
	wantCalls(t, "border pixel 4", []Call{{Method: "window.border", Params: map[string]interface{}{"style": "pixel"}}})
}

func TestTranslateSplit(t *testing.T) {
	wantCalls(t, "split h", []Call{{Method: "layout.split", Params: map[string]interface{}{"orientation": "horizontal"}}})
	wantCalls(t, "split v", []Call{{Method: "layout.split", Params: map[string]interface{}{"orientation": "vertical"}}})
	wantCalls(t, "split toggle", []Call{{Method: "layout.split", Params: map[string]interface{}{"orientation": "toggle"}}})
}

func TestTranslateSplitCompoundWithExec(t *testing.T) {
	// hotkeyd's real table chains a notify-send after the split
	// ($mod+s/$mod+b) as ONE i3 command string, "split h;exec ...". kwi3's
	// own i3 codec treats ";" as a statement separator (ipcSplitStatements)
	// and runs each independently; Translate does the same, as two calls.
	wantCalls(t, "split h;exec notify-send 'tile side'", []Call{
		{Method: "layout.split", Params: map[string]interface{}{"orientation": "horizontal"}},
		{Method: "exec", Params: map[string]interface{}{"command": "notify-send 'tile side'"}},
	})
	wantCalls(t, "split v;exec notify-send 'tile bellow'", []Call{
		{Method: "layout.split", Params: map[string]interface{}{"orientation": "vertical"}},
		{Method: "exec", Params: map[string]interface{}{"command": "notify-send 'tile bellow'"}},
	})
}

func TestTranslateFullscreenToggle(t *testing.T) {
	// window.fullscreen{on} takes an explicit boolean - there is no ft010
	// "toggle" - so this goes through action.run just like focus parent.
	wantCalls(t, "fullscreen toggle", []Call{{Method: "action.run", Params: map[string]interface{}{"name": "fullScreen"}}})
}

func TestTranslateFullscreenEnableDisable(t *testing.T) {
	wantCalls(t, "fullscreen enable", []Call{{Method: "window.fullscreen", Params: map[string]interface{}{"on": true}}})
	wantCalls(t, "fullscreen disable", []Call{{Method: "window.fullscreen", Params: map[string]interface{}{"on": false}}})
}

func TestTranslateFloatingEnableDisableToggle(t *testing.T) {
	wantCalls(t, "floating enable", []Call{{Method: "window.float", Params: map[string]interface{}{"on": true}}})
	wantCalls(t, "floating disable", []Call{{Method: "window.float", Params: map[string]interface{}{"on": false}}})
	wantCalls(t, "floating toggle", []Call{{Method: "action.run", Params: map[string]interface{}{"name": "float"}}})
}

func TestTranslateLayout(t *testing.T) {
	wantCalls(t, "layout tabbed", []Call{{Method: "layout.set", Params: map[string]interface{}{"layout": "tabbed"}}})
	// "layout toggle split" - the trailing "split" is not read by kwi3's OWN
	// i3 codec either (ipcCmdLayout only ever looks at w[1]); Translate
	// matches that, not a stricter grammar of its own.
	wantCalls(t, "layout toggle split", []Call{{Method: "layout.set", Params: map[string]interface{}{"layout": "toggle"}}})
	wantCalls(t, "layout toggle", []Call{{Method: "layout.set", Params: map[string]interface{}{"layout": "toggle"}}})
	// i3's "stacking" is kwi3's "stacked" (core/rpc.js RPC_LAYOUTS / i3ipc.js
	// IPC_LAYOUTS both normalise it the same way).
	wantCalls(t, "layout stacking", []Call{{Method: "layout.set", Params: map[string]interface{}{"layout": "stacked"}}})
}

func TestTranslateKill(t *testing.T) {
	wantCalls(t, "kill", []Call{{Method: "window.close", Params: nil}})
}

func TestTranslateExec(t *testing.T) {
	wantCalls(t, "exec notify-send hi", []Call{{Method: "exec", Params: map[string]interface{}{"command": "notify-send hi"}}})
	// i3 accepts (and ignores) a leading --no-startup-id.
	wantCalls(t, "exec --no-startup-id notify-send hi",
		[]Call{{Method: "exec", Params: map[string]interface{}{"command": "notify-send hi"}}})
}

func TestTranslateWorkspaceByNumberAndName(t *testing.T) {
	wantCalls(t, "workspace 2", []Call{{Method: "workspace.focus", Params: map[string]interface{}{"num": 2}}})
	wantCalls(t, "workspace dotfiles", []Call{{Method: "workspace.focus", Params: map[string]interface{}{"name": "dotfiles"}}})
}

func TestTranslateWorkspaceNextPrev(t *testing.T) {
	// ft010's workspace.focus takes num|id|name only - no direction - so
	// this is the one pseudo-method Client resolves itself (workspace.list
	// then workspace.focus{num}); it must never reach the wire as
	// "workspace.neighbour".
	wantCalls(t, "workspace next", []Call{{Method: methodWorkspaceNeighbour, Params: map[string]interface{}{"step": 1}}})
	wantCalls(t, "workspace prev", []Call{{Method: methodWorkspaceNeighbour, Params: map[string]interface{}{"step": -1}}})
}

// -- the genuine ft010 gaps: no method exists, and none can be built from
// existing methods either. These must be reported, not silently dropped. --

func TestTranslateStickyIsUnsupported(t *testing.T) {
	wantUnsupported(t, "sticky toggle")
}

func TestTranslateScratchpadIsUnsupported(t *testing.T) {
	wantUnsupported(t, "move scratchpad")
	wantUnsupported(t, "scratchpad show")
}

func TestTranslateWorkspaceBackAndForthIsUnsupported(t *testing.T) {
	// Not in hotkeyd's real table, but the same genuine gap as sticky/
	// scratchpad (no previous-workspace method on the RPC surface) -
	// covered so KnownUnsupportedVerbs stays honest about the whole class.
	wantUnsupported(t, "workspace back_and_forth")
}

func TestTranslateUnknownVerbIsAnError(t *testing.T) {
	if _, err := Translate("frobnicate loudly"); err == nil {
		t.Fatalf("Translate of a nonsense verb: expected an error, got none")
	}
}
