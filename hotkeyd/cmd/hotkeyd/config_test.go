package main

import (
	"bytes"
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
//
// EXTERNAL LAYERS ARE EXCLUDED (sp023 Task 5, bd dotfiles-1m4t.5), and the
// reason is what keeps this an honest golden rather than a weakened one.
// The claim this fixture defends is "the shipped KEYBOARD has not drifted
// from the table Python shipped". An External layer is not part of any
// keyboard: plan decision 1 makes it signal-only, and rule R28 makes that
// structural — it may declare no Binds, Mods, ExitKeys, OneShot, Hold,
// OnHoldRelease or OnExit, so there is literally nothing about it a
// dumpLayer could carry except four empty collections and two false
// booleans. It holds zero grabs and is unreachable by any chord (R29
// forbids EnterLayer targeting it), so its presence changes no key.
//
// The alternative — writing an entry for it into
// testdata/golden-dump-python.json — was rejected: that file is the dump
// binds.py ACTUALLY produced at the moment it was deleted, and inventing a
// layer Python never had would destroy exactly the provenance that makes it
// worth comparing against.
//
// The exclusion cannot hide drift, and that is asserted rather than
// asserted-by-comment: TestGoldenDumpExclusion_IsExactlyTheExternalLayers
// below pins that every excluded layer is External AND behaviorally empty,
// so marking a real chord-bearing layer External to duck this comparison
// fails there (and at R28) instead of passing silently here.
func goldenDumpFromGoTable() dumpTable {
	binds := make([]dumpBind, len(Binds))
	for i, b := range Binds {
		binds[i] = bindRepr(b)
	}
	layers := map[string]dumpLayer{}
	for name, l := range Layers {
		if l.External {
			continue
		}
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
// intentionalDivergences records every bind whose behavior DELIBERATELY no
// longer matches what Python shipped, with the reason and the issue that
// changed it. The golden dump is a truthful historical record of the table the
// user's keyboard actually had before the rewrite — editing the fixture to
// match a later deliberate change would turn that record into a lie, and the
// next person reading it would believe Python behaved a way it never did.
//
// So the fixture stays frozen and divergence becomes explicit HERE, where it
// has to be named and justified. An accidental behavior change still fails the
// parity test, which is the property that matters; only a change someone chose
// and wrote down passes.
//
// Keep this list short. A long one means the parity contract has stopped
// meaning anything and should be retired deliberately rather than eroded.
var intentionalDivergences = map[string]string{
	// dotfiles-b3d4: Python fired this on PRESS. A held chord therefore
	// relaunched the launcher for as long as it was down; each launch killed
	// the previous SELECTOR but not the previous LAUNCHER, which then ran its
	// unconditional clear and wiped the layer the newer launch had raised —
	// the aiming strip and ring flickered in and out. Release fires once per
	// physical gesture, matching the two sibling screenshot binds
	// ($mod+Print, $mod+Shift+Print) that already carried OnRelease.
	"$mod+Shift+s": "OnRelease: fires once per gesture instead of per repeat",
}

// applyIntentionalDivergences rewrites the PYTHON side to the behavior we
// deliberately chose afterwards, so the comparison still covers chord, device
// and actions for those binds — only the named field stops being asserted.
// Applied to the python dump rather than the go one so an unexpected go-side
// change still shows up as a mismatch.
func applyIntentionalDivergences(d *dumpTable) {
	for i, b := range d.Binds {
		if _, ok := intentionalDivergences[b.Chord]; ok {
			d.Binds[i].OnRelease = true
		}
	}
}

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
// TestIntentionalDivergencesAreLive keeps the allowlist above honest. An entry
// that no longer describes a real divergence is WORSE than no entry at all: it
// silently stops asserting OnRelease for that chord, so a later accidental
// change to the same bind would sail through the parity test that exists to
// catch exactly that.
//
// Every entry must therefore name a chord that (a) still exists in the frozen
// python dump, and (b) still actually differs — python false, go true. Revert
// the go-side change and this test tells you to drop the entry.
func TestIntentionalDivergencesAreLive(t *testing.T) {
	raw, err := os.ReadFile(goldenDumpFixture)
	if err != nil {
		t.Fatalf("cannot read the golden dump at %s: %v", goldenDumpFixture, err)
	}
	var pyDump dumpTable
	if err := json.Unmarshal(raw, &pyDump); err != nil {
		t.Fatalf("could not parse golden-dump JSON at %s: %v", goldenDumpFixture, err)
	}
	goDump := goldenDumpFromGoTable()

	pyByChord := map[string]dumpBind{}
	for _, b := range pyDump.Binds {
		pyByChord[b.Chord] = b
	}
	goByChord := map[string]dumpBind{}
	for _, b := range goDump.Binds {
		goByChord[b.Chord] = b
	}

	for chord, reason := range intentionalDivergences {
		py, ok := pyByChord[chord]
		if !ok {
			t.Errorf("intentionalDivergences names %q (%s), but no such chord "+
				"exists in the frozen python dump — the entry is stale and is "+
				"masking nothing; drop it", chord, reason)
			continue
		}
		got, ok := goByChord[chord]
		if !ok {
			t.Errorf("intentionalDivergences names %q (%s), but the go table no "+
				"longer declares that chord; drop the entry", chord, reason)
			continue
		}
		if py.OnRelease {
			t.Errorf("intentionalDivergences names %q (%s), but python ALREADY "+
				"had OnRelease=true — there is no divergence to allow; drop it",
				chord, reason)
		}
		if !got.OnRelease {
			t.Errorf("intentionalDivergences names %q (%s), but the go table has "+
				"OnRelease=false — the divergence was reverted, so the entry now "+
				"silently disables parity for this bind; drop it", chord, reason)
		}
	}
}

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

	applyIntentionalDivergences(&pyDump)
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
// THE EXTERNAL (SIGNAL-ONLY) LAYERS — sp023 Task 5's cutover (bd
// dotfiles-1m4t.5) and sp024 Task 2's (bd dotfiles-0tv1.2).
//
// BOTH phases of one screenshot gesture used to be real i3 modes, switched
// into over `i3-msg mode <name>` purely so quickshell/qs-focus-border.py and
// Bar.qml (SEPARATE processes with no access to the overlay's in-memory
// state) could react to them: "screenshot" while the user AIMS, entered by
// qs-screenshot.sh, and "screenshot-drag" the instant a region starts being
// DRAWN, entered by qs-region.py's own `_press`. Both are layers in THIS
// table now, entered over `hotkeyd set-layer <name>`; neither i3 mode block
// survives (sp024 deleted the last of them). The tests below pin the two
// properties that make those migrations safe rather than merely done: each
// layer is declared, and declaring them cost zero keys.
// ---------------------------------------------------------------------------

// The two External layers the shipped table declares — the two phases of one
// gesture, handed off external → external at mouse-press time (pinned by
// internal/layer's TestExternalToExternalHandoff). Named as constants because
// several separate contracts spell each one: this table, the shell/python
// consumers below, and test-hotkeyd.sh's stage 18.
const (
	aimingLayerName = "screenshot"      // quickshell/qs-screenshot.sh (sp024)
	dragLayerName   = "screenshot-drag" // quickshell/qs-region.py    (sp023)
)

// assertDeclaredExternal is the existence proof both cutovers need. `hotkeyd
// set-layer <name>` is refused BY NAME unless the compiled table declares the
// layer External (setlayer.go's client-side gate and control.go's daemon-side
// gate both call validateControlLayer), so without the entry the consumer's
// call is a guaranteed exit-1 no-op every time — a silently dead signal, which
// is precisely the failure these tests exist to make loud.
func assertDeclaredExternal(t *testing.T, name, consumer string) {
	t.Helper()
	lay, ok := Layers[name]
	if !ok {
		t.Fatalf("the shipped table declares no %q layer (have: %v) — "+
			"%s's `set-layer %s` would be refused by name every time",
			name, sortedLayerNames(Layers), consumer, name)
	}
	if !lay.External {
		t.Fatalf("layer %q exists but is not declared External — set-layer only "+
			"accepts External names (control.go validateControlLayer)", name)
	}
	// The client-side gate is the one the consumer actually hits; assert
	// through it rather than re-deriving the rule, so a change to the
	// acceptance policy shows up here too.
	if err := validateControlLayer(Layers, name); err != nil {
		t.Errorf("validateControlLayer(%q) = %v, want nil — the shipped table must "+
			"accept the exact name %s sends", name, err, consumer)
	}
}

// TestRealTable_ScreenshotDragIsDeclaredExternal is sp023's existence proof:
// the DRAWING phase, raised by the overlay at press time.
func TestRealTable_ScreenshotDragIsDeclaredExternal(t *testing.T) {
	assertDeclaredExternal(t, dragLayerName, "qs-region.py")
}

// TestRealTable_ScreenshotAimingIsDeclaredExternal is sp024's — the AIMING
// phase, raised by the launcher before the selector starts. It is the whole
// gate of that cutover: i3's `mode "screenshot" {}` block is DELETED in the
// same commit that adds this declaration, so if the name were missing here
// the hint strip and the ring would have no channel left at all (us019 AC1,
// AC4). Deliberately a second, separately-named test rather than a loop, so a
// dropped declaration names the phase it broke.
func TestRealTable_ScreenshotAimingIsDeclaredExternal(t *testing.T) {
	assertDeclaredExternal(t, aimingLayerName, "qs-screenshot.sh")
}

// TestRealTable_ExternalLayersAreSignalOnly walks EVERY field of bind.Layer
// by reflection rather than listing the seven behavioral ones by hand: a
// field added to bind.Layer later is behavioral until someone says otherwise,
// and this test refuses it automatically instead of ignoring it.
//
// bind.Validate's R28 enforces the same rule over the same table, so this is
// deliberately a second, independent statement of it at the shipped-table
// level — R28 is a general rule that a future exemption could widen, whereas
// this is a flat assertion about what actually ships.
//
// It also refuses to be VACUOUS: a table with no External layer at all fails
// here, so this cannot quietly become a test of nothing if the declaration is
// ever dropped.
func TestRealTable_ExternalLayersAreSignalOnly(t *testing.T) {
	externals := externalLayerNames(Layers)
	if len(externals) == 0 {
		t.Fatal("no External layer in the shipped table — this test would be vacuous; " +
			"sp023 Task 5 declares screenshot-drag")
	}

	for _, name := range externals {
		lay := Layers[name]
		rv := reflect.ValueOf(lay)
		rt := rv.Type()
		for i := 0; i < rt.NumField(); i++ {
			field := rt.Field(i)
			if field.Name == "External" {
				continue
			}
			if !rv.Field(i).IsZero() {
				t.Errorf("External layer %q declares %s = %#v — an external-trigger "+
					"layer declares NOTHING but the flag (sp023 plan decision 1, R28)",
					name, field.Name, rv.Field(i).Interface())
			}
		}
	}
}

// TestRealTable_ExternalLayerHoldsZeroGrabs is decision 1's "it holds zero
// grabs" stated against the REAL grab-set function the daemon wires into its
// GrabManager, not against the struct shape. layerChords is what a layer
// costs in keys while it is ACTIVE; for an external layer that must be the
// empty set under every $mod resolution, which is what makes a STRANDED
// external layer cost pixels and never keys (us019 AC5).
func TestRealTable_ExternalLayerHoldsZeroGrabs(t *testing.T) {
	externals := externalLayerNames(Layers)
	if len(externals) == 0 {
		t.Fatal("no External layer in the shipped table — this test would be vacuous")
	}
	for _, name := range externals {
		for _, mod := range bind.ModResolutions {
			if got := layerChords(Layers[name], mod); len(got) != 0 {
				t.Errorf("layerChords(%q, mod=%s) = %v, want none — an external layer "+
					"must grab nothing", name, mod, got)
			}
		}
	}
}

// TestRealTable_NoChordEntersAnExternalLayer closes the other way a signal-
// only layer could start costing keys: not through the layer's own fields,
// but through a GLOBAL bind that enters it. R29 forbids exactly this, and
// this asserts it holds on the shipped table specifically — an `EnterLayer{
// "screenshot-drag"}` bind would hand the daemon a grab for a layer whose
// whole point is that the overlay's seat grab owns input during a drag.
func TestRealTable_NoChordEntersAnExternalLayer(t *testing.T) {
	external := map[string]bool{}
	for _, name := range externalLayerNames(Layers) {
		external[name] = true
	}
	if len(external) == 0 {
		t.Fatal("no External layer in the shipped table — this test would be vacuous")
	}
	for _, b := range Binds {
		for _, a := range b.Actions {
			if el, ok := a.(bind.EnterLayer); ok && external[el.Layer] {
				t.Errorf("global bind %q enters External layer %q — external layers are "+
					"reachable only through `set-layer` (R29, sp023 plan decision 1)",
					b.Chord, el.Layer)
			}
		}
	}
}

// daemonOwnedChordCount is the size of the daemon's always-on grab set, per
// $mod resolution, FROZEN AS A LITERAL — measured on the shipped table
// immediately before sp023 Task 5 declared the screenshot-drag layer.
//
// A literal is the whole point. Task 5's success criterion is that
// `check --ownership` output is UNCHANGED by declaring an external layer,
// and any number re-derived from the same table it guards would satisfy that
// no matter what the layer contributed. This one cannot: if a future edit
// gives an "external" layer a chord — or slips an entry bind in beside it —
// the count moves and this fails.
//
// Both resolutions carry the same count because no shipped bind is
// DisplayMod-qualified yet (see config.go's package doc on us020); if that
// changes, this map is where the divergence gets recorded deliberately.
var daemonOwnedChordCount = map[string]int{
	"Mod4": 70,
	"Mod1": 70,
}

// TestOwnershipRowCount_UnmovedByTheExternalLayer is the ownership row-count
// parity assertion Task 5's success criteria name, driven through the REAL
// reportOwnership entry point (not just globalChords) so it measures the
// rows a user would actually see from `check --ownership`.
//
// The i3 side is deliberately an EMPTY config: with no i3-owned chords in the
// union, every row printed is a daemon-owned one, so the row count IS the
// daemon's grab-set size and a single extra grab is visible as a single extra
// row. (reportOwnership's behaviour against a populated i3 config, including
// the BOTH-collision exit code, is ownership_test.go's own subject.)
func TestOwnershipRowCount_UnmovedByTheExternalLayer(t *testing.T) {
	var buf bytes.Buffer
	if code := reportOwnership(&buf, "", Binds); code != 0 {
		t.Fatalf("reportOwnership over an empty i3 config = %d, want 0 (nothing to "+
			"collide with); output:\n%s", code, buf.String())
	}

	rows := map[string]int{}
	current := ""
	for _, line := range strings.Split(buf.String(), "\n") {
		if strings.HasPrefix(line, "-- $mod=") {
			current = strings.TrimSuffix(strings.TrimPrefix(line, "-- $mod="), " --")
			continue
		}
		if strings.TrimSpace(line) == "" || current == "" {
			continue
		}
		rows[current]++
	}

	for _, mod := range bind.ModResolutions {
		want, ok := daemonOwnedChordCount[mod]
		if !ok {
			t.Fatalf("no frozen row count for $mod=%s — bind.ModResolutions grew and "+
				"daemonOwnedChordCount did not", mod)
		}
		if rows[mod] != want {
			t.Errorf("check --ownership printed %d rows for $mod=%s, want %d — "+
				"declaring an External (signal-only) layer must not add or remove a "+
				"single owned chord (sp023 Task 5)", rows[mod], mod, want)
		}
	}
	if len(rows) != len(bind.ModResolutions) {
		t.Errorf("ownership report covered %d $mod resolutions, want %d", len(rows), len(bind.ModResolutions))
	}
}

// TestGoldenDumpExclusion_IsExactlyTheExternalLayers guards the exclusion
// goldenDumpFromGoTable makes. Without this, "skip External layers" would be
// an escape hatch: mark any layer External and its chords stop being compared
// against the Python fixture. Here the excluded set must be exactly the
// External layers, and each one must be behaviorally empty — so nothing with
// keyboard behaviour can ever leave the comparison through that door.
func TestGoldenDumpExclusion_IsExactlyTheExternalLayers(t *testing.T) {
	dumped := goldenDumpFromGoTable().Layers

	excluded := []string{}
	for name, lay := range Layers {
		if _, in := dumped[name]; in {
			if lay.External {
				t.Errorf("layer %q is External but was still dumped for golden comparison", name)
			}
			continue
		}
		excluded = append(excluded, name)
		if !lay.External {
			t.Errorf("layer %q was excluded from the golden dump but is NOT External — "+
				"only signal-only layers may skip the parity comparison", name)
		}
		if rep := layerRepr(lay); !reflect.DeepEqual(rep, dumpLayer{Mods: map[string]dumpMod{},
			Binds: []dumpBind{}, ExitKeys: []string{}, OnHoldRelease: []string{}, OnExit: []string{}}) {
			t.Errorf("excluded layer %q is not behaviorally empty: %+v — excluding it "+
				"would hide real keyboard behaviour from the golden dump", name, rep)
		}
	}
	sort.Strings(excluded)
	if !reflect.DeepEqual(excluded, externalLayerNames(Layers)) {
		t.Errorf("excluded from golden dump = %v, External layers = %v — the two must "+
			"be the same set", excluded, externalLayerNames(Layers))
	}
}

// externalLayerNames returns every External-declared layer name, sorted, so
// assertions over "the external layers" are deterministic.
func externalLayerNames(m map[string]bind.Layer) []string {
	out := []string{}
	for name, lay := range m {
		if lay.External {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// sortedLayerNames is externalLayerNames' unfiltered twin, for failure
// messages that need to show what the table DOES declare.
func sortedLayerNames(m map[string]bind.Layer) []string {
	out := make([]string, 0, len(m))
	for name := range m {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
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
