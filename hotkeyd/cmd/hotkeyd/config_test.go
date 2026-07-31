package main

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"

	"hotkeyd/internal/bind"
)

// THE GOLDEN DUMP IS NOW A FROZEN FIXTURE (dotfiles-ylmp.16).
//
// This used to shell out to python on every run and compare the Go table
// against whatever hotkeyd/binds.py said right then — the live parity gate
// for the epic's parallel-run window. binds.py is deleted, so the live
// comparison has no second side; what remains is testdata/golden-dump-python.json,
// the dump taken from binds.py at the moment it was removed.
//
// KEPT, NOT DELETED, and the distinction matters. A test that can only ever
// skip is worth nothing and this one would have skipped forever (its old
// os.Stat guard on binds.py). But the CLAIM it defends did not expire with
// python: the shipped keyboard is supposed to be the table Python shipped,
// and the compiled-in Go table is now the only copy of it. Frozen, this is
// an ordinary golden test — it no longer proves the two engines agree (there
// is one engine), it proves the surviving engine has not drifted from the
// keyboard the user actually had. A deliberate table change updates the
// fixture in the same commit, which is the point: the diff shows up in review
// instead of arriving silently on someone's keyboard.
//
// The script below is retained verbatim as the RECORD of how the fixture was
// produced — it is no longer executed. To regenerate it you would need
// binds.py back out of git history (`git show <commit>^:hotkeyd/binds.py`),
// which is the correct amount of friction for changing what this test
// considers ground truth. Run from the hotkeyd/ directory:
//
//	python3 -c '
//	import binds as B
//	import json
//
//	def action_repr(a):
//	    if isinstance(a, B.Run):
//	        return "run:" + a.cmd
//	    if isinstance(a, B.EnterLayer):
//	        return "enter:" + a.layer
//	    if isinstance(a, B.ExitLayer):
//	        return "exit"
//	    if isinstance(a, str):
//	        return "cmd:" + a
//	    return "other:" + repr(a)
//
//	def bind_repr(b):
//	    return {
//	        "chord": b.chord,
//	        "on_release": bool(b.on_release),
//	        "device": b.device or "",
//	        "actions": [action_repr(a) for a in B.actions_of(b)],
//	    }
//
//	def hold_release_repr(layer):
//	    hr = layer.on_hold_release
//	    if hr is None:
//	        return []
//	    seq = hr if isinstance(hr, (list, tuple)) else [hr]
//	    return [action_repr(a) for a in seq]
//
//	def on_exit_repr(layer):
//	    oe = getattr(layer, "on_exit", None)
//	    if oe is None:
//	        return []
//	    seq = oe if isinstance(oe, (list, tuple)) else [oe]
//	    return [action_repr(a) for a in seq]
//
//	def layer_repr(layer):
//	    return {
//	        "binds": [bind_repr(b) for b in layer.binds],
//	        "mods": {
//	            label: {"modifier": m.modifier,
//	                    "binds": [bind_repr(b) for b in m.binds]}
//	            for label, m in layer.mods.items()
//	        },
//	        "exit_keys": list(layer.exit_keys),
//	        "one_shot": bool(layer.one_shot),
//	        "hold": layer.hold or "",
//	        "on_hold_release": hold_release_repr(layer),
//	        "on_exit": on_exit_repr(layer),
//	    }
//
//	dump = {
//	    "binds": [bind_repr(b) for b in B.BINDS],
//	    "layers": {name: layer_repr(layer) for name, layer in B.LAYERS.items()},
//	}
//	print(json.dumps(dump))
//	'
//
// goldenDumpScript below is byte-for-byte the same script quoted above. It is
// dead as CODE (nothing executes it since dotfiles-ylmp.16) and live as
// PROVENANCE: it is the definition of what the fixture's fields mean, and
// deleting it would leave a JSON blob no one could re-derive or audit.
const goldenDumpScript = `
import binds as B
import json

def action_repr(a):
    if isinstance(a, B.Run):
        return "run:" + a.cmd
    if isinstance(a, B.EnterLayer):
        return "enter:" + a.layer
    if isinstance(a, B.ExitLayer):
        return "exit"
    if isinstance(a, str):
        return "cmd:" + a
    return "other:" + repr(a)

def bind_repr(b):
    return {
        "chord": b.chord,
        "on_release": bool(b.on_release),
        "device": b.device or "",
        "actions": [action_repr(a) for a in B.actions_of(b)],
    }

def hold_release_repr(layer):
    hr = layer.on_hold_release
    if hr is None:
        return []
    seq = hr if isinstance(hr, (list, tuple)) else [hr]
    return [action_repr(a) for a in seq]

def on_exit_repr(layer):
    oe = getattr(layer, "on_exit", None)
    if oe is None:
        return []
    seq = oe if isinstance(oe, (list, tuple)) else [oe]
    return [action_repr(a) for a in seq]

def layer_repr(layer):
    return {
        "binds": [bind_repr(b) for b in layer.binds],
        "mods": {
            label: {"modifier": m.modifier,
                    "binds": [bind_repr(b) for b in m.binds]}
            for label, m in layer.mods.items()
        },
        "exit_keys": list(layer.exit_keys),
        "one_shot": bool(layer.one_shot),
        "hold": layer.hold or "",
        "on_hold_release": hold_release_repr(layer),
        "on_exit": on_exit_repr(layer),
    }

dump = {
    "binds": [bind_repr(b) for b in B.BINDS],
    "layers": {name: layer_repr(layer) for name, layer in B.LAYERS.items()},
}
print(json.dumps(dump))
`

// ---------------------------------------------------------------------------
// golden-dump comparison shapes — mirrors the Python script's JSON output
// field for field, so json.Unmarshal into dumpTable works for either side.
// ---------------------------------------------------------------------------

type dumpBind struct {
	Chord     string   `json:"chord"`
	OnRelease bool     `json:"on_release"`
	Device    string   `json:"device"`
	Actions   []string `json:"actions"`
}

type dumpMod struct {
	Modifier string     `json:"modifier"`
	Binds    []dumpBind `json:"binds"`
}

type dumpLayer struct {
	Binds         []dumpBind         `json:"binds"`
	Mods          map[string]dumpMod `json:"mods"`
	ExitKeys      []string           `json:"exit_keys"`
	OneShot       bool               `json:"one_shot"`
	Hold          string             `json:"hold"`
	OnHoldRelease []string           `json:"on_hold_release"`
	OnExit        []string           `json:"on_exit"`
}

type dumpTable struct {
	Binds  []dumpBind           `json:"binds"`
	Layers map[string]dumpLayer `json:"layers"`
}

// actionRepr canonicalizes one bind.Action exactly the way the Python
// script's action_repr() canonicalizes one binds.py action — same tag
// prefixes, same string shape, so the two sides are comparable byte for
// byte once serialized.
func actionRepr(a bind.Action) string {
	switch v := a.(type) {
	case bind.Run:
		return "run:" + v.Cmd
	case bind.EnterLayer:
		return "enter:" + v.Layer
	case bind.ExitLayer:
		return "exit"
	case bind.Command:
		return "cmd:" + string(v)
	default:
		return fmt.Sprintf("other:%#v", a)
	}
}

func bindRepr(b bind.Bind) dumpBind {
	actions := make([]string, len(b.Actions))
	for i, a := range b.Actions {
		actions[i] = actionRepr(a)
	}
	return dumpBind{Chord: b.Chord, OnRelease: b.OnRelease, Device: b.Device, Actions: actions}
}

func actionsRepr(actions []bind.Action) []string {
	out := make([]string, len(actions))
	for i, a := range actions {
		out[i] = actionRepr(a)
	}
	return out
}

func layerRepr(l bind.Layer) dumpLayer {
	binds := make([]dumpBind, len(l.Binds))
	for i, b := range l.Binds {
		binds[i] = bindRepr(b)
	}
	mods := map[string]dumpMod{}
	for label, m := range l.Mods {
		mb := make([]dumpBind, len(m.Binds))
		for i, b := range m.Binds {
			mb[i] = bindRepr(b)
		}
		mods[label] = dumpMod{Modifier: m.Modifier, Binds: mb}
	}
	return dumpLayer{
		Binds:         binds,
		Mods:          mods,
		ExitKeys:      append([]string{}, l.ExitKeys...),
		OneShot:       l.OneShot,
		Hold:          l.Hold,
		OnHoldRelease: actionsRepr(l.OnHoldRelease),
		OnExit:        actionsRepr(l.OnExit),
	}
}

// goldenDumpFromGoTable canonicalizes THIS package's real Binds/Layers vars
// the same way the Python script canonicalizes binds.py's BINDS/LAYERS.
func goldenDumpFromGoTable() dumpTable {
	binds := make([]dumpBind, len(Binds))
	for i, b := range Binds {
		binds[i] = bindRepr(b)
	}
	layers := map[string]dumpLayer{}
	for name, l := range Layers {
		layers[name] = layerRepr(l)
	}
	return dumpTable{Binds: binds, Layers: layers}
}

func dumpBindKey(b dumpBind) string {
	return fmt.Sprintf("%s\x00%v\x00%s\x00%s", b.Chord, b.OnRelease, b.Device, strings.Join(b.Actions, "\x01"))
}

func sortDumpBinds(bs []dumpBind) {
	sort.Slice(bs, func(i, j int) bool { return dumpBindKey(bs[i]) < dumpBindKey(bs[j]) })
}

// normalizeDumpTable sorts every bind slice into a stable order (by chord
// identity) so the comparison is over the SET/multiset the success criteria
// asks for, not over incidental construction order on either side.
func normalizeDumpTable(d *dumpTable) {
	sortDumpBinds(d.Binds)
	for name, l := range d.Layers {
		sortDumpBinds(l.Binds)
		for label, m := range l.Mods {
			sortDumpBinds(m.Binds)
			l.Mods[label] = m
		}
		d.Layers[name] = l
	}
}

// goldenDumpFixture is the dump binds.py produced at the moment it was
// deleted (dotfiles-ylmp.16), via goldenDumpScript above. Checked in, because
// it is now the only surviving statement of the table the user's keyboard
// actually had before the rewrite.
const goldenDumpFixture = "testdata/golden-dump-python.json"

// TestGoldenDumpParity proves the compiled-in Go table is chord for chord,
// action for action, layer for layer the table Python shipped. It compared
// against a LIVE python import until dotfiles-ylmp.16; it now compares against
// the frozen dump taken when python was removed. See goldenDumpScript's doc
// comment above for what the fixture's fields mean and how it was produced.
//
// A hard failure, never a skip. The old live version skipped when python3 was
// absent, which was right when the fixture had to be computed; there is
// nothing left to be absent, so a read error here is a broken checkout, not a
// reason to pass.
func TestGoldenDumpParity(t *testing.T) {
	raw, err := os.ReadFile(goldenDumpFixture)
	if err != nil {
		t.Fatalf("cannot read the golden dump at %s -- this fixture IS the "+
			"parity target now that binds.py is deleted, so a missing one is a "+
			"hard failure, not a skip: %v", goldenDumpFixture, err)
	}

	var pyDump dumpTable
	if err := json.Unmarshal(raw, &pyDump); err != nil {
		t.Fatalf("could not parse golden-dump JSON at %s: %v", goldenDumpFixture, err)
	}
	goDump := goldenDumpFromGoTable()

	normalizeDumpTable(&pyDump)
	normalizeDumpTable(&goDump)

	if len(pyDump.Binds) != len(goDump.Binds) {
		t.Errorf("global bind COUNT mismatch: python=%d go=%d", len(pyDump.Binds), len(goDump.Binds))
	}
	if !reflect.DeepEqual(pyDump.Binds, goDump.Binds) {
		t.Errorf("global bind inventory mismatch (chord/action set):\npython: %+v\ngo:     %+v",
			pyDump.Binds, goDump.Binds)
	}

	if len(pyDump.Layers) != len(goDump.Layers) {
		t.Errorf("layer COUNT mismatch: python=%d (%v) go=%d (%v)",
			len(pyDump.Layers), layerNames(pyDump.Layers), len(goDump.Layers), layerNames(goDump.Layers))
	}
	for name, pl := range pyDump.Layers {
		gl, ok := goDump.Layers[name]
		if !ok {
			t.Errorf("layer %q exists in python but not in go", name)
			continue
		}
		if !reflect.DeepEqual(pl, gl) {
			t.Errorf("layer %q mismatch:\npython: %+v\ngo:     %+v", name, pl, gl)
		}
	}
	for name := range goDump.Layers {
		if _, ok := pyDump.Layers[name]; !ok {
			t.Errorf("layer %q exists in go but not in python", name)
		}
	}
}

func layerNames(m map[string]dumpLayer) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// ---------------------------------------------------------------------------
// validator-over-the-real-table: what the type system CANNOT catch
// (duplicates, reserved chords, missing exit_keys, ...) must be caught by
// bind.Validate actually running over Binds/Layers, under BOTH $mod
// resolutions this repo runs on (see bind.ModResolutions).
// ---------------------------------------------------------------------------

func TestValidatorOverRealTable_BothModResolutions(t *testing.T) {
	for _, mod := range bind.ModResolutions {
		problems := bind.Validate(Binds, Layers, mod)
		if len(problems) != 0 {
			t.Errorf("Validate(mod=%s) found %d problem(s) on the shipped table:", mod, len(problems))
			for _, p := range problems {
				t.Errorf("  %s", p)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// negative-literal suite — Go twins of the shell scenarios injected by
// hotkeyd/test-hotkeyd.sh stage 3 (faulty.py) and stage 8 (trap.py). Every
// scenario those two files exercise gets a named test here, over table
// LITERALS, so none of them is silently dropped in the port (design's
// explicit no-silent-drop requirement).
// ---------------------------------------------------------------------------

// TestFaultyTable_MirrorsShellStage3 mirrors test-hotkeyd.sh stage 3's
// injected faulty.py:
//
//	BINDS = [Bind('Mod4+z', 'kill'), Bind('Mod4+z', 'nop dup'),
//	         Bind('Mod4+y', ''), Bind('Mod4+o', enter_layer('ghost'))]
//	LAYERS = {}
//
// Three faults in one table: a duplicate chord (Mod4+z), an empty command
// (Mod4+y), and an EnterLayer targeting a layer that does not exist
// (ghost). The shell stage asserts a non-zero exit AND that the output
// names all three offenders — this test asserts the same over Validate's
// problem list directly.
func TestFaultyTable_MirrorsShellStage3(t *testing.T) {
	faultyBinds := []bind.Bind{
		{Chord: "Mod4+z", Actions: []bind.Action{bind.Command("kill")}},
		{Chord: "Mod4+z", Actions: []bind.Action{bind.Command("nop dup")}},
		{Chord: "Mod4+y", Actions: []bind.Action{bind.Command("")}},
		{Chord: "Mod4+o", Actions: []bind.Action{bind.EnterLayer{Layer: "ghost"}}},
	}

	problems := bind.Validate(faultyBinds, map[string]bind.Layer{}, bind.DefaultMod)
	if len(problems) == 0 {
		t.Fatal("faulty table validated clean — the validator is not load-bearing")
	}
	for _, token := range []string{"Mod4+z", "Mod4+y", "ghost"} {
		found := false
		for _, p := range problems {
			if strings.Contains(string(p), token) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("no problem names %q (a bare non-empty result is not actionable): %v", token, problems)
		}
	}
}

// TestFaultyTable_DuplicateChordNamedIndependently isolates stage 3's first
// fault so a regression in duplicate detection fails on its own, not only
// as part of the combined faulty-table assertion above.
func TestFaultyTable_DuplicateChordNamedIndependently(t *testing.T) {
	binds := []bind.Bind{
		{Chord: "Mod4+z", Actions: []bind.Action{bind.Command("kill")}},
		{Chord: "Mod4+z", Actions: []bind.Action{bind.Command("nop dup")}},
	}
	problems := bind.Validate(binds, map[string]bind.Layer{}, bind.DefaultMod)
	found := false
	for _, p := range problems {
		if strings.Contains(string(p), "Mod4+z") && strings.Contains(string(p), "duplicate") {
			found = true
		}
	}
	if !found {
		t.Errorf("duplicate Mod4+z not reported: %v", problems)
	}
}

// TestFaultyTable_EmptyCommandNamedIndependently isolates stage 3's second
// fault: an empty command string is not a silently-dropped bind, it is a
// reported one.
func TestFaultyTable_EmptyCommandNamedIndependently(t *testing.T) {
	binds := []bind.Bind{
		{Chord: "Mod4+y", Actions: []bind.Action{bind.Command("")}},
	}
	problems := bind.Validate(binds, map[string]bind.Layer{}, bind.DefaultMod)
	found := false
	for _, p := range problems {
		if strings.Contains(string(p), "Mod4+y") && strings.Contains(string(p), "empty") {
			found = true
		}
	}
	if !found {
		t.Errorf("empty command on Mod4+y not reported: %v", problems)
	}
}

// TestFaultyTable_MissingLayerNamedIndependently isolates stage 3's third
// fault: EnterLayer("ghost") where "ghost" was never declared.
func TestFaultyTable_MissingLayerNamedIndependently(t *testing.T) {
	binds := []bind.Bind{
		{Chord: "Mod4+o", Actions: []bind.Action{bind.EnterLayer{Layer: "ghost"}}},
	}
	problems := bind.Validate(binds, map[string]bind.Layer{}, bind.DefaultMod)
	found := false
	for _, p := range problems {
		if strings.Contains(string(p), "ghost") {
			found = true
		}
	}
	if !found {
		t.Errorf("missing layer 'ghost' not reported: %v", problems)
	}
}

// TestTrapLayerTable_MirrorsShellStage8 mirrors test-hotkeyd.sh stage 8's
// injected trap.py:
//
//	BINDS = [Bind('$mod+o', enter_layer('trap'))]
//	LAYERS = {'trap': Layer(binds=[Bind('h', 'focus left')], exit_keys=[])}
//
// A layer with no exit_keys is a trap: once entered there is no chord that
// leaves it. The shell stage starts a REAL daemon against this table and
// asserts it refuses to start, naming "exit_keys" in the refusal; this is
// the load-time proof over the same table shape, without needing a process.
func TestTrapLayerTable_MirrorsShellStage8(t *testing.T) {
	trapBinds := []bind.Bind{
		{Chord: "$mod+o", Actions: []bind.Action{bind.EnterLayer{Layer: "trap"}}},
	}
	trapLayers := map[string]bind.Layer{
		"trap": {
			Binds:    []bind.Bind{{Chord: "h", Actions: []bind.Action{bind.Command("focus left")}}},
			ExitKeys: nil, // the trap: no way out
		},
	}

	problems := bind.Validate(trapBinds, trapLayers, bind.DefaultMod)
	if len(problems) == 0 {
		t.Fatal("trap layer validated clean — a layer with no exit_keys must be refused")
	}
	found := false
	for _, p := range problems {
		if strings.Contains(string(p), "exit_keys") {
			found = true
		}
	}
	if !found {
		t.Errorf("no problem names exit_keys: %v", problems)
	}

	if _, _, err := bind.Load(trapBinds, trapLayers, bind.DefaultMod); err == nil {
		t.Error("Load() accepted a trap layer instead of refusing it")
	}
}
