package main

import (
	"reflect"
	"testing"

	"hotkeyd/internal/bind"
)

func chordsOf(bs []bind.Bind) []string {
	out := make([]string, len(bs))
	for i, b := range bs {
		out[i] = b.Chord
	}
	return out
}

func TestApplyHostOverrides(t *testing.T) {
	base := []bind.Bind{
		{Chord: "$mod+Return", Actions: runAction("st")},
		{Chord: "$mod+d", Actions: runAction("launcher")},
		{Chord: "$mod+h", Actions: cmdAction("focus left")},
	}
	got := applyHostOverrides(base, map[string][]bind.Action{
		"$mod+Return": runAction("foot"), // replaced in place
		"$mod+d":      nil,               // dropped
		"$mod+x":      runAction("b"),    // appended, sorted
		"$mod+c":      runAction("a"),
	})
	if want := []string{"$mod+Return", "$mod+h", "$mod+c", "$mod+x"}; !reflect.DeepEqual(chordsOf(got), want) {
		t.Fatalf("chords = %v, want %v", chordsOf(got), want)
	}
	if !reflect.DeepEqual(got[0].Actions, runAction("foot")) {
		t.Errorf("$mod+Return actions = %#v, want foot", got[0].Actions)
	}
	if !reflect.DeepEqual(base[0].Actions, runAction("st")) {
		t.Errorf("the shared table was mutated: %#v", base[0].Actions)
	}
	if same := applyHostOverrides(base, nil); !reflect.DeepEqual(same, base) {
		t.Errorf("no overrides changed the table: %v", chordsOf(same))
	}
}

// An empty action list removes a chord the same as nil does - from the
// shared table and from Kwi3OnlyBinds alike, after splitHostOverrides has
// routed it (sp012 Task 6). Untagged: runs on every host tag.
func TestApplyHostOverrides_EmptyActionsRemove(t *testing.T) {
	base := []bind.Bind{
		{Chord: "$mod+n", Actions: runAction("notif")},
		{Chord: "$mod+h", Actions: cmdAction("focus left")},
	}
	kwi3Only := []bind.Bind{
		{Chord: "$mod+Shift+q", Actions: cmdAction("kill")},
		{Chord: "$mod+Shift+c", Actions: runAction("restart")},
	}
	shared, kwi3 := splitHostOverrides(map[string][]bind.Action{
		"$mod+n":       {},
		"$mod+Shift+c": {},
		"$mod+x":       {}, // removing a chord nobody has adds nothing
	}, kwi3Only)
	if got, want := chordsOf(applyHostOverrides(base, shared)), []string{"$mod+h"}; !reflect.DeepEqual(got, want) {
		t.Errorf("shared table = %v, want %v", got, want)
	}
	if got, want := chordsOf(applyHostOverrides(kwi3Only, kwi3)), []string{"$mod+Shift+q"}; !reflect.DeepEqual(got, want) {
		t.Errorf("kwi3-only table = %v, want %v", got, want)
	}
}

// A layer only a removed chord entered goes with it, and so does a layer
// only that layer entered; a layer still entered elsewhere stays, and a
// layer no chord ever entered (External, raised by set-layer) is untouched.
func TestPruneOrphanedLayers(t *testing.T) {
	enter := func(l string) []bind.Action { return []bind.Action{bind.EnterLayer{Layer: l}} }
	layers := map[string]bind.Layer{
		"system": {Binds: []bind.Bind{{Chord: "x", Actions: enter("deeper")}}, ExitKeys: []string{"q"}},
		"deeper": {ExitKeys: []string{"q"}},
		"nav":    {ExitKeys: []string{"q"}},
		"resize": {ExitKeys: []string{"q"}},
		"shot":   {External: true},
	}
	before := []bind.Bind{
		{Chord: "$mod+0", Actions: enter("system")},
		{Chord: "$mod+o", Actions: enter("nav")},
		{Chord: "$mod+r", Actions: enter("resize")},
		{Chord: "$mod+Shift+o", Actions: enter("nav")},
	}
	after := []bind.Bind{before[2], before[3]} // $mod+0 and $mod+o removed
	got := pruneOrphanedLayers(layers, before, after)
	if names, want := sortedLayerNames(got), []string{"nav", "resize", "shot"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("layers = %v, want %v", names, want)
	}
	if len(layers) != 5 {
		t.Errorf("the shared layer table was mutated: %v", sortedLayerNames(layers))
	}
	if same := pruneOrphanedLayers(layers, before, before); !reflect.DeepEqual(same, layers) {
		t.Errorf("nothing removed, yet layers = %v", sortedLayerNames(same))
	}
}
