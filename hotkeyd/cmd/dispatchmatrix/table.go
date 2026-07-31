package main

// table.go turns the SHIPPED bind table into an ordered press plan.
//
// # Where the chord list comes from
//
// It is read at run time out of hotkeyd/binds.py, using byte-for-byte the
// script cmd/hotkeyd/config_test.go documents as the golden-dump
// regeneration command. Nothing here is hand-transcribed, and that is the
// whole point: a hand-written chord list is stale the moment the table moves,
// and a stale list is the failure mode this epic has spent several tasks
// fighting. The Go table is not read here at all — TestGoldenDumpParity
// already proves the two are identical chord-for-chord and action-for-action,
// so the python dump is a source INDEPENDENT of the Go engine this harness is
// grading.

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"strings"
)

// goldenDumpScript is the same script as cmd/hotkeyd/config_test.go's
// goldenDumpScript. Kept verbatim so the two tools describe the same table in
// the same shape; if that file's copy changes, this one must too.
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

type DumpBind struct {
	Chord     string   `json:"chord"`
	OnRelease bool     `json:"on_release"`
	Device    string   `json:"device"`
	Actions   []string `json:"actions"`
}

type DumpMod struct {
	Modifier string     `json:"modifier"`
	Binds    []DumpBind `json:"binds"`
}

type DumpLayer struct {
	Binds         []DumpBind         `json:"binds"`
	Mods          map[string]DumpMod `json:"mods"`
	ExitKeys      []string           `json:"exit_keys"`
	OneShot       bool               `json:"one_shot"`
	Hold          string             `json:"hold"`
	OnHoldRelease []string           `json:"on_hold_release"`
	OnExit        []string           `json:"on_exit"`
}

type Dump struct {
	Binds  []DumpBind           `json:"binds"`
	Layers map[string]DumpLayer `json:"layers"`
}

// LoadDump shells out to python3 in dir (the hotkeyd/ directory, so `import
// binds` resolves) and decodes the shipped table.
func LoadDump(dir, python string) (*Dump, error) {
	cmd := exec.Command(python, "-c", goldenDumpScript)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("dispatchmatrix: golden dump failed: %w", err)
	}
	var d Dump
	if err := json.Unmarshal(out, &d); err != nil {
		return nil, fmt.Errorf("dispatchmatrix: golden dump did not parse: %w", err)
	}
	if len(d.Binds) == 0 || len(d.Layers) == 0 {
		return nil, fmt.Errorf("dispatchmatrix: golden dump is empty (%d binds, %d layers)",
			len(d.Binds), len(d.Layers))
	}
	return &d, nil
}

// LayerNames returns the layer names in a stable order.
func (d *Dump) LayerNames() []string {
	out := make([]string, 0, len(d.Layers))
	for n := range d.Layers {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// ModLabels returns a layer's sublayer labels in a stable order.
//
// The order is SORTED, which is also how internal/layer's activeMod breaks
// ties (dotfiles-9y8n); the plan does not depend on it, but keeping the
// enumeration deterministic is what makes two arms comparable trial-for-trial.
func (l DumpLayer) ModLabels() []string {
	out := make([]string, 0, len(l.Mods))
	for n := range l.Mods {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// EntryChord finds the top-level chord whose action enters the named layer.
// Derived, never hardcoded — the entry chord is part of the table.
func (d *Dump) EntryChord(layer string) (string, bool) {
	want := "enter:" + layer
	for _, b := range d.Binds {
		for _, a := range b.Actions {
			if a == want {
				return b.Chord, true
			}
		}
	}
	return "", false
}

// RunTargets is every executable the table's Run actions name, as a path
// relative to the sandbox HOME. Derived from the table so a new Run action
// gets a stub automatically rather than escaping the sandbox and spawning the
// operator's real script.
//
// Two shapes appear in the shipped table and both are covered:
//
//	~/path/to/script      -> stubbed at that exact path under the sandbox HOME
//	bare-command          -> stubbed at $HOME/.local/bin/<name>, which the
//	                         daemon's PATH puts first
func (d *Dump) RunTargets() []string {
	seen := map[string]bool{}
	add := func(actions []string) {
		for _, a := range actions {
			cmd, ok := strings.CutPrefix(a, "run:")
			if !ok {
				continue
			}
			fields := strings.Fields(cmd)
			if len(fields) == 0 {
				continue
			}
			tok := fields[0]
			switch {
			case strings.HasPrefix(tok, "~/"):
				seen[strings.TrimPrefix(tok, "~/")] = true
			case strings.Contains(tok, "/"):
				// An absolute or relative path that is not under ~: the
				// sandbox cannot intercept it. Surfaced by the caller.
				seen["ABS:"+tok] = true
			default:
				seen[".local/bin/"+tok] = true
			}
		}
	}
	for _, b := range d.Binds {
		add(b.Actions)
	}
	for _, l := range d.Layers {
		for _, b := range l.Binds {
			add(b.Actions)
		}
		for _, m := range l.Mods {
			for _, b := range m.Binds {
				add(b.Actions)
			}
		}
		add(l.OnHoldRelease)
		add(l.OnExit)
	}
	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// ---------------------------------------------------------------------------
// chord -> xdotool
// ---------------------------------------------------------------------------

// xdoModifier maps a chord's modifier token onto the name xdotool knows.
// mod is what $mod resolved to on THIS display, read off the daemon's own
// startup line rather than assumed.
func xdoModifier(tok, mod string) (string, error) {
	t := strings.ToLower(strings.TrimSpace(tok))
	if t == "$mod" {
		t = strings.ToLower(strings.TrimSpace(mod))
	}
	switch t {
	case "shift":
		return "shift", nil
	case "ctrl", "control":
		return "ctrl", nil
	case "mod1", "alt", "meta":
		return "alt", nil
	case "mod4", "super", "win", "logo":
		return "super", nil
	}
	return "", fmt.Errorf("dispatchmatrix: modifier %q has no xdotool spelling", tok)
}

// XdoChord renders a table chord as an xdotool `key` argument.
func XdoChord(chord, mod string) (string, error) {
	parts := strings.Split(chord, "+")
	key := parts[len(parts)-1]
	out := make([]string, 0, len(parts))
	for _, p := range parts[:len(parts)-1] {
		m, err := xdoModifier(p, mod)
		if err != nil {
			return "", err
		}
		out = append(out, m)
	}
	out = append(out, key)
	return strings.Join(out, "+"), nil
}

// XdoChordWithout renders a chord with one modifier token removed — used for
// a hold layer, whose entry chord's hold modifier is pressed separately and
// kept DOWN.
func XdoChordWithout(chord, mod, drop string) (string, error) {
	dropCanon, err := xdoModifier(drop, mod)
	if err != nil {
		return "", err
	}
	parts := strings.Split(chord, "+")
	key := parts[len(parts)-1]
	out := []string{}
	for _, p := range parts[:len(parts)-1] {
		m, err := xdoModifier(p, mod)
		if err != nil {
			return "", err
		}
		if m == dropCanon {
			continue
		}
		out = append(out, m)
	}
	out = append(out, key)
	return strings.Join(out, "+"), nil
}
