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
