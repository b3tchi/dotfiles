package bind

import (
	"fmt"
	"sort"
	"strings"
)

// Problem is one reason a table failed to load, naming the offender exactly
// as binds.py's validator does, so a human reading --check output does not
// need to translate.
type Problem string

func (p Problem) String() string { return string(p) }

// dupKey is the duplicate-detection identity: normalized chord, OnRelease,
// and Device. OnRelease is part of it because press and release on one
// chord are different events, not a collision (i3 does the same with
// --release). Device is part of it because two binds on one chord scoped to
// DIFFERENT source devices are disambiguated at dispatch by sourceid and
// cannot double-fire; two binds on one chord with the SAME device (including
// both "") still collide ([[ft011]] api_surface, verbatim).
//
// DisplayMod is deliberately NOT part of this key. Unlike Device, an
// unqualified bind ("") is active on EVERY display, so it overlaps with
// every specific qualifier rather than being a disjoint scope — folding
// DisplayMod into the identity would let an unqualified bind and a
// same-chord Mod4-qualified bind pass as "different", when on a real :0
// display both would be live and would double-fire. Display scoping is
// instead handled by which binds PARTICIPATE in a given Validate(mod) pass
// — see scan.
type dupKey struct {
	ChordKey
	OnRelease bool
	Device    string
}

func actionProblem(a Action, where, what string) string {
	switch v := a.(type) {
	case Command:
		if strings.TrimSpace(string(v)) == "" {
			return fmt.Sprintf("%s: %s has an empty command", where, what)
		}
	case Run:
		if strings.TrimSpace(v.Cmd) == "" {
			return fmt.Sprintf("%s: %s has an empty run() command", where, what)
		}
	}
	return ""
}

func commandProblem(b Bind, where string) string {
	what := fmt.Sprintf("chord %q", b.Chord)
	if len(b.Actions) == 0 {
		return fmt.Sprintf("%s: %s has an empty action tuple", where, what)
	}
	for _, a := range b.Actions {
		if p := actionProblem(a, where, what); p != "" {
			return p
		}
	}
	return ""
}

// deviceProblem flags a Device that is set but blank/whitespace-only.
//
// Deviation from binds.py, forced by Go's type system: Python distinguishes
// device=None (no scope) from device="" (an explicit-but-empty scope, which
// it also rejects). Go's string zero value "" IS the "no scope" sentinel —
// there is no third state — so an exact "" cannot be separately flagged as
// "explicitly set to empty" the way Python's device="" can. A blank string
// with real whitespace ("  ") is still distinguishable from "" and is
// rejected here, which is the meaningful case in practice (a bad template
// render leaving whitespace) and is what this package's R12 test exercises.
func deviceProblem(b Bind, where string) string {
	if b.Device == "" {
		return ""
	}
	if strings.TrimSpace(b.Device) == "" {
		return fmt.Sprintf(
			"%s: chord %q has a blank device= (%q); leave Device \"\" to match any source device",
			where, b.Chord, b.Device)
	}
	return ""
}

// bareProblem enforces that a LAYER table's own chords (the layer's own
// binds, or a Mod sublayer's) are bare keysyms — see scan(bare=true).
// Inside a layer the modifier is not part of the chord: the sublayer
// supplies it, and the engine compares the chord to the bare keysym of the
// event. Refusing a modifier-carrying chord here keeps the grab set narrow:
// grabbing "Shift+h" inside a layer would take a chord the daemon has no
// meaning for.
func bareProblem(b Bind, where, mod string) string {
	mods, _, err := ParseChord(b.Chord, mod)
	if err != nil {
		return "" // reported by the caller's own parse
	}
	if len(mods) == 0 {
		return ""
	}
	return fmt.Sprintf(
		"%s: chord %q carries modifiers (%s); layer binds must be BARE keysyms — "+
			"express a held modifier as a Mod sublayer. The engine matches a "+
			"layer bind against the keysym alone, so this chord would be "+
			"grabbed and could never fire",
		where, b.Chord, sortedModNames(mods))
}

// scan validates one list of binds (the global table, one layer's own
// binds, or one Mod sublayer's binds) and folds duplicates into seen.
// prefix, when non-empty, is a sublayer's resolved modifier name prepended
// to each chord before computing its identity (never before the bare
// check — a sublayer bind is itself still a bare keysym; the modifier comes
// from the sublayer, not the chord string).
func scan(bs []Bind, where string, layers map[string]Layer, seen map[dupKey]string,
	prefix, mod string, bare bool) []Problem {
	var problems []Problem
	for _, b := range bs {
		canonDisp, dispOK := canonDisplayMod(b.DisplayMod)
		if !dispOK {
			problems = append(problems, Problem(fmt.Sprintf(
				"%s: chord %q has unknown display qualifier %q",
				where, b.Chord, b.DisplayMod)))
		}
		effectiveMod := mod
		if canonDisp != "" {
			effectiveMod = canonDisp
		}

		if bare {
			if p := bareProblem(b, where, effectiveMod); p != "" {
				problems = append(problems, Problem(p))
				continue
			}
		}

		chord := b.Chord
		if prefix != "" {
			chord = prefix + "+" + chord
		}

		key, err := NormalizeChord(chord, effectiveMod)
		if err != nil {
			problems = append(problems, Problem(fmt.Sprintf("%s: %s", where, err.Error())))
			continue
		}

		// Checked unconditionally, regardless of whether this bind is
		// even active in the current pass (see the package doc): a
		// display-qualified bind cannot dodge the panic-chord reservation
		// by being scoped to a display the caller is not validating right
		// now.
		if ReservedChords[key] {
			problems = append(problems, Problem(fmt.Sprintf(
				"%s: chord %q is the panic chord (%s), reserved for i3 — "+
					"it is the only way back from a daemon that is dead or "+
					"wrong, so no table may bind it",
				where, b.Chord, PanicChord)))
		}

		// Duplicate detection only among binds ACTIVE in this pass: an
		// unqualified bind, or one whose DisplayMod matches the mod this
		// Validate call is simulating.
		if canonDisp == "" || canonDisp == mod {
			dk := dupKey{ChordKey: key, OnRelease: b.OnRelease, Device: b.Device}
			if prevWhere, ok := seen[dk]; ok {
				problems = append(problems, Problem(fmt.Sprintf(
					"%s: chord %q is already bound in %s (duplicate binds double-fire)",
					where, b.Chord, prevWhere)))
			} else {
				seen[dk] = where
			}
		}

		if p := commandProblem(b, where); p != "" {
			problems = append(problems, Problem(p))
		}
		if p := deviceProblem(b, where); p != "" {
			problems = append(problems, Problem(p))
		}
		for _, a := range b.Actions {
			if el, ok := a.(EnterLayer); ok {
				target, exists := layers[el.Layer]
				if !exists {
					problems = append(problems, Problem(fmt.Sprintf(
						"%s: chord %q enters layer %q, which does not exist",
						where, b.Chord, el.Layer)))
				} else if target.External {
					// R29: external-trigger layers are set-layer-only —
					// chord layers stay chord-only (plan decision 3,
					// compile-time half).
					problems = append(problems, Problem(fmt.Sprintf(
						"%s: chord %q enters layer %q via EnterLayer, but %q "+
							"is declared External — external-trigger layers "+
							"can only be entered via the set-layer verb, "+
							"never a chord",
						where, b.Chord, el.Layer, el.Layer)))
				}
			}
		}
	}
	return problems
}

// externalProblems refuses every behavioral field an External layer
// declares, naming both the layer and the offending field so a stray field
// is refused rather than silently ignored (rule R28, sp023 Task 1, plan
// decision 1: an external-trigger layer declares nothing but the flag). Not
// called at all for a non-External layer.
func externalProblems(name string, layer Layer) []Problem {
	where := fmt.Sprintf("layer %q", name)
	var problems []Problem
	note := func(field string) {
		problems = append(problems, Problem(fmt.Sprintf(
			"%s: declared External but also declares %s — an external-trigger "+
				"layer is signal-only and must declare nothing but the flag",
			where, field)))
	}
	if len(layer.Binds) > 0 {
		note("Binds")
	}
	if len(layer.Mods) > 0 {
		note("Mods")
	}
	if len(layer.ExitKeys) > 0 {
		note("ExitKeys")
	}
	if layer.OneShot {
		note("OneShot")
	}
	if layer.Hold != "" {
		note("Hold")
	}
	if len(layer.OnHoldRelease) > 0 {
		note("OnHoldRelease")
	}
	if len(layer.OnExit) > 0 {
		note("OnExit")
	}
	return problems
}

// holdProblems checks one layer's own hold declaration under the display
// being validated.
func holdProblems(name string, layer Layer, mod string) []Problem {
	where := fmt.Sprintf("layer %q", name)
	var problems []Problem
	if layer.Hold == "" {
		if len(layer.OnHoldRelease) > 0 {
			problems = append(problems, Problem(fmt.Sprintf(
				"%s: on_hold_release is declared with no hold modifier, "+
					"so nothing could ever dispatch it", where)))
		}
		return problems
	}
	canon, ok := CanonModifier(layer.Hold, mod)
	if !ok {
		problems = append(problems, Problem(fmt.Sprintf(
			"%s: unknown hold modifier %q", where, layer.Hold)))
		return problems
	}
	if canon == Shift {
		// Not a style rule. xrdp synthesises Shift around every character
		// it sends on :10, so a Shift HOLD is not observable in that
		// session at all — the same measurement that made the nav layer
		// use Ctrl and not Shift as its move modifier.
		problems = append(problems, Problem(fmt.Sprintf(
			"%s: hold modifier %q resolves to Shift; xrdp synthesises "+
				"Shift around every character on :10, so a held Shift is "+
				"not observable there and the layer's lifetime would be random",
			where, layer.Hold)))
	}
	for _, a := range layer.OnHoldRelease {
		if p := actionProblem(a, where, "on_hold_release"); p != "" {
			problems = append(problems, Problem(p))
		}
	}
	return problems
}

// Validate returns every problem found, as human-readable strings naming
// the chord. An empty slice means the table is loadable. Reports ALL
// problems rather than the first: mid-migration you want the whole list,
// not one round trip per typo.
//
// mod is what ModToken resolves to on the display being simulated — call
// Validate once per resolution in ModResolutions to fully cover a table
// that uses display-qualified binds (see the package doc).
func Validate(binds []Bind, layers map[string]Layer, mod string) []Problem {
	if mod == "" {
		mod = DefaultMod
	}
	var problems []Problem
	problems = append(problems, scan(binds, "global", layers, map[dupKey]string{}, "", mod, false)...)

	layerNames := make([]string, 0, len(layers))
	for name := range layers {
		layerNames = append(layerNames, name)
	}
	sort.Strings(layerNames)

	for _, name := range layerNames {
		layer := layers[name]
		seen := map[dupKey]string{}
		where := fmt.Sprintf("layer %q", name)

		if layer.External {
			// R28: an External layer declares nothing but the flag.
			problems = append(problems, externalProblems(name, layer)...)
			if name == "default" {
				// R30: "default" is the clear verb's own target name — a
				// layer declaring External there would make the clear
				// verb ambiguous.
				problems = append(problems, Problem(fmt.Sprintf(
					"layer %q declares External, but %q is the reserved "+
						"clear-verb name — an external-trigger layer cannot "+
						"be named %q",
					name, name, name)))
			}
		}

		problems = append(problems, scan(layer.Binds, where, layers, seen, "", mod, true)...)
		problems = append(problems, holdProblems(name, layer, mod)...)

		labels := make([]string, 0, len(layer.Mods))
		for label := range layer.Mods {
			labels = append(labels, label)
		}
		sort.Strings(labels)
		for _, label := range labels {
			sub := layer.Mods[label]
			subWhere := fmt.Sprintf("layer %q mod %q", name, label)
			canon, ok := CanonModifier(sub.Modifier, mod)
			if !ok {
				problems = append(problems, Problem(fmt.Sprintf(
					"%s: unknown modifier %q", subWhere, sub.Modifier)))
				continue
			}
			// Sublayer binds share the layer's own `seen` map, on purpose:
			// duplicate detection covers a layer's base binds AND its
			// sublayer tables together, since both are live grabs
			// whenever the layer is active.
			problems = append(problems, scan(sub.Binds, subWhere, layers, seen, string(canon), mod, true)...)
		}

		if len(layer.ExitKeys) == 0 {
			if layer.External {
				// R20 exemption: an External layer is left the same way it
				// was entered — the set-layer verb, never a keystroke — so
				// requiring ExitKeys here would be meaningless. Scoped to
				// this flag only; see the R20 mutation tests proving the
				// identical shape WITHOUT External still trips this rule.
				continue
			}
			problems = append(problems, Problem(fmt.Sprintf(
				"layer %q has no exit_keys — it could not be left", name)))
			continue
		}
		for _, k := range layer.ExitKeys {
			mods, _, err := ParseChord(k, mod)
			if err != nil {
				problems = append(problems, Problem(fmt.Sprintf(
					"layer %q exit key: %s", name, err.Error())))
				continue
			}
			if len(mods) > 0 {
				// An exit key is matched on the keysym alone, on purpose: a
				// layer must stay leavable with any modifier still held.
				problems = append(problems, Problem(fmt.Sprintf(
					"layer %q exit key %q carries modifiers (%s); exit keys "+
						"are BARE keysyms and already work with any modifier held",
					name, k, sortedModNames(mods))))
			}
		}
	}
	return problems
}

// Load validates the table and returns it, or a *BindError joining every
// problem found (never just the first).
func Load(binds []Bind, layers map[string]Layer, mod string) ([]Bind, map[string]Layer, error) {
	problems := Validate(binds, layers, mod)
	if len(problems) > 0 {
		msgs := make([]string, len(problems))
		for i, p := range problems {
			msgs[i] = string(p)
		}
		return nil, nil, bindErrorf("%s", strings.Join(msgs, "\n"))
	}
	return binds, layers, nil
}
