package main

// plan.go turns the shipped table into the ordered list of presses both arms
// execute. The SAME plan object drives both engines, so a trial id means the
// same injection on either side and the diff is trial-for-trial.

import (
	"fmt"
	"sort"
)

// Trial is one injection, plus the state the daemon must be in when it lands.
type Trial struct {
	ID     string   // stable across arms
	Group  string   // report grouping
	Kind   string   // bind | exit | precedence | negative
	Layer  string   // "" = the default layer
	ModLbl string   // sublayer label this press is meant to select, if any
	Chord  string   // the table's own spelling
	Press  string   // the xdotool `key` argument
	Expect []string // the table's declared actions, for the report only
}

// BuildPlan enumerates every chord in the shipped table, in a deterministic
// order. mod is what $mod resolved to on the rig, read off the daemon's own
// startup line.
func BuildPlan(d *Dump, mod string) ([]Trial, error) {
	var out []Trial

	// -- the 70 top-level binds, in table order ---------------------------
	for _, b := range d.Binds {
		press, err := XdoChord(b.Chord, mod)
		if err != nil {
			return nil, fmt.Errorf("top-level bind %q: %w", b.Chord, err)
		}
		out = append(out, Trial{
			ID: "default|" + b.Chord, Group: "default", Kind: "bind",
			Chord: b.Chord, Press: press, Expect: b.Actions,
		})
	}

	// -- every layer: its own binds, each sublayer's binds, its exit keys --
	for _, name := range d.LayerNames() {
		l := d.Layers[name]
		if _, ok := d.EntryChord(name); !ok {
			return nil, fmt.Errorf("layer %q has no entry chord in the table", name)
		}
		for _, b := range l.Binds {
			press, err := XdoChord(b.Chord, mod)
			if err != nil {
				return nil, fmt.Errorf("layer %s bind %q: %w", name, b.Chord, err)
			}
			out = append(out, Trial{
				ID: "layer:" + name + "|" + b.Chord, Group: "layer:" + name, Kind: "bind",
				Layer: name, Chord: b.Chord, Press: press, Expect: b.Actions,
			})
		}
		for _, label := range l.ModLabels() {
			m := l.Mods[label]
			for _, b := range m.Binds {
				chord := m.Modifier + "+" + b.Chord
				press, err := XdoChord(chord, mod)
				if err != nil {
					return nil, fmt.Errorf("layer %s mod %s bind %q: %w", name, label, b.Chord, err)
				}
				out = append(out, Trial{
					ID:    "layer:" + name + "/" + label + "|" + chord,
					Group: "layer:" + name + "/" + label, Kind: "bind",
					Layer: name, ModLbl: label, Chord: chord, Press: press, Expect: b.Actions,
				})
			}
		}
		for _, ek := range l.ExitKeys {
			press, err := XdoChord(ek, mod)
			if err != nil {
				return nil, fmt.Errorf("layer %s exit key %q: %w", name, ek, err)
			}
			out = append(out, Trial{
				ID: "layer:" + name + "|exit:" + ek, Group: "layer:" + name, Kind: "exit",
				Layer: name, Chord: ek, Press: press,
				Expect: []string{"leave " + name},
			})
		}
	}

	// -- sublayer precedence (dotfiles-9y8n) ------------------------------
	//
	// Every layer with more than one sublayer gets a trial that holds ALL of
	// their modifiers at once on the first key the sublayers share. That is
	// the tie internal/layer breaks ALPHABETICALLY by label while python
	// breaks it by declaration order; the two agree on every shipped table
	// only by accident of naming, and this trial is what turns "agrees by
	// inspection" into "agreed when measured".
	for _, name := range d.LayerNames() {
		l := d.Layers[name]
		labels := l.ModLabels()
		if len(labels) < 2 {
			continue
		}
		key, ok := sharedFirstKey(l, labels)
		if !ok {
			continue
		}
		chord := ""
		for _, label := range labels {
			chord += l.Mods[label].Modifier + "+"
		}
		chord += key
		press, err := XdoChord(chord, mod)
		if err != nil {
			return nil, fmt.Errorf("precedence trial for %s: %w", name, err)
		}
		out = append(out, Trial{
			ID: "precedence:" + name + "|" + chord, Group: "precedence:" + name,
			Kind: "precedence", Layer: name, Chord: chord, Press: press,
			Expect: expectedPerLabel(l, labels, key),
		})
	}

	// -- negative control --------------------------------------------------
	//
	// A chord the table does not contain. hotkeyd must dispatch nothing;
	// the rig's i3 holds it and fires the injector-liveness probe, so this
	// single trial proves the press really happened AND that the harness can
	// tell a silent daemon from a dead injector.
	npress, err := XdoChord(probeChord, mod)
	if err != nil {
		return nil, err
	}
	out = append(out, Trial{
		ID: "negative|" + probeChord, Group: "negative", Kind: "negative",
		Chord: probeChord, Press: npress,
		Expect: []string{"(nothing — not in the table)"},
	})

	return out, nil
}

// sharedFirstKey is the first key (in the first label's declaration order)
// that every sublayer of l binds — the key on which their claims actually
// collide.
func sharedFirstKey(l DumpLayer, labels []string) (string, bool) {
	for _, b := range l.Mods[labels[0]].Binds {
		all := true
		for _, other := range labels[1:] {
			found := false
			for _, ob := range l.Mods[other].Binds {
				if ob.Chord == b.Chord {
					found = true
					break
				}
			}
			if !found {
				all = false
				break
			}
		}
		if all {
			return b.Chord, true
		}
	}
	return "", false
}

// expectedPerLabel renders what each sublayer would dispatch for key, so the
// report can say which one won rather than only that the arms agreed.
func expectedPerLabel(l DumpLayer, labels []string, key string) []string {
	out := []string{}
	sorted := append([]string{}, labels...)
	sort.Strings(sorted)
	for _, label := range sorted {
		for _, b := range l.Mods[label].Binds {
			if b.Chord == key {
				for _, a := range b.Actions {
					out = append(out, label+" would: "+a)
				}
			}
		}
	}
	return out
}
