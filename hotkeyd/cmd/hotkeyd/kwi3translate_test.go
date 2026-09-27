package main

import (
	"sort"
	"testing"
)

// TestKwi3TranslateCoversRealTable is sp004 Task 16's success criterion 1:
// "every cmdAction string in cmd/hotkeyd/config.go translates to a method
// (a table-driven test over the REAL table, so a new chord without a
// mapping fails the build)". It walks the REAL Binds/Layers this daemon
// actually grabs (buildBinds(), Layers - both package vars, no fixture)
// and asserts the unsupported set is EXACTLY today's known one - not "zero
// unsupported chords", because two of hotkeyd's own real chords
// (sticky toggle, and both of the scratchpad ones) have no ft010 method to
// map to at all: kwi3's Logic has no sticky or scratchpad concept, full
// stop, so there is nothing for a translator to call (kwi3-234.16's own
// decision point - see internal/kwi3rpc/translate.go's
// KnownUnsupportedVerbs doc). A chord added later that hits a NEW unmapped
// verb changes this set and fails the build, which is the whole point:
// nobody should be able to add a chord whose kwi3 behaviour is "silently
// does nothing" without the build telling them so.
func TestKwi3TranslateCoversRealTable(t *testing.T) {
	got := walkForKwi3Translation(Binds, Layers)

	gotActions := make([]string, len(got))
	for i, c := range got {
		gotActions[i] = c.Action
	}
	sort.Strings(gotActions)

	want := []string{
		"move scratchpad",
		"scratchpad show",
		"sticky toggle",
	}
	sort.Strings(want)

	if len(gotActions) != len(want) {
		t.Fatalf("unsupported-under-kwi3rpc actions changed: got %v, want %v\n"+
			"(a NEW entry here means a chord was added, or an existing one's action "+
			"text changed, with no ft010 method - see internal/kwi3rpc/translate.go's "+
			"KnownUnsupportedVerbs before assuming this test is merely stale)",
			gotActions, want)
	}
	for i := range want {
		if gotActions[i] != want[i] {
			t.Fatalf("unsupported-under-kwi3rpc actions changed: got %v, want %v", gotActions, want)
		}
	}

	// Every one of the three must be tied to the chord Jan actually binds -
	// this table-driven check would be worthless if it were merely counting
	// three arbitrary strings rather than the real ones this daemon grabs.
	byChord := map[string]string{}
	for _, c := range got {
		byChord[c.Chord] = c.Action
	}
	wantChords := map[string]string{
		"$mod+Shift+p":     "sticky toggle",
		"$mod+Shift+minus": "move scratchpad",
		"$mod+minus":       "scratchpad show",
	}
	for chord, action := range wantChords {
		if byChord[chord] != action {
			t.Fatalf("expected chord %q to bind the unsupported action %q, got %q", chord, action, byChord[chord])
		}
	}
}

// TestKwi3TranslateEveryOtherRealChordTranslates is the positive half of
// the same criterion, spelled out chord by chord rather than only "the
// unsupported count did not change": every OTHER bind.Command in the real
// table must translate with NO error. Iterating buildBinds()/Layers
// directly (rather than hand-copying the verb list) is what makes a
// syntax typo in a future config.go edit ("worksapce next") fail this
// test immediately instead of silently landing in the unsupported set
// above for the wrong reason.
func TestKwi3TranslateEveryOtherRealChordTranslates(t *testing.T) {
	unsupported := map[string]bool{
		"sticky toggle":   true,
		"move scratchpad": true,
		"scratchpad show": true,
	}
	got := walkForKwi3Translation(Binds, Layers)
	for _, c := range got {
		if !unsupported[c.Action] {
			t.Errorf("chord %q action %q has NO ft010 mapping and is not in the known-unsupported set: %s",
				c.Chord, c.Action, c.Err)
		}
	}
}
