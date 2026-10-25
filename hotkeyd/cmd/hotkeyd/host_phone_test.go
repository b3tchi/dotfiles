//go:build phone

package main

import (
	"fmt"
	"reflect"
	"testing"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwi3rpc"
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
	if got := phoneBind(t, "$mod+Return"); !reflect.DeepEqual(got.Actions, runAction("foot")) {
		t.Fatalf("$mod+Return on the phone = %+v, want run foot", got)
	}
	// Kwi3OnlyBinds is appended after the shared table; the override must
	// still reach it.
	if got := phoneBind(t, "$mod+Shift+c"); !reflect.DeepEqual(got.Actions, runAction("$HOME/.local/bin/i3reload")) {
		t.Fatalf("$mod+Shift+c on the phone = %+v, want run i3reload", got)
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
