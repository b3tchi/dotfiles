package bind

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Modifier is a canonical modifier name — the folded form every alias in
// modifierAliases resolves to.
type Modifier string

const (
	Shift Modifier = "Shift"
	Lock  Modifier = "Lock"
	Ctrl  Modifier = "Ctrl"
	Mod1  Modifier = "Mod1"
	Mod2  Modifier = "Mod2"
	Mod3  Modifier = "Mod3"
	Mod4  Modifier = "Mod4"
	Mod5  Modifier = "Mod5"
)

// ModToken is the placeholder resolved per display at daemon start, from the
// same X resource i3 reads (i3wm.mod, [[ft003]]) with the same Mod4
// default. The xrdp session sets Mod1 because Super does not survive an RDP
// client, so ONE table means Super on :0 and Alt on :10 — hardcoding Mod4
// would leave every such chord FREE on :10, where the daemon would own and
// serve it while i3 owned the Alt equivalent.
const ModToken = "$mod"

// DefaultMod is the modifier ModToken resolves to when no mod is supplied.
const DefaultMod = "Mod4"

// PanicChord is the one chord i3 keeps forever (i3/config.common,
// hotkeyd-panic.sh panic). See RESERVED_CHORDS.
const PanicChord = "$mod+Ctrl+Shift+r"

// ModResolutions enumerates every modifier $mod resolves to on a display
// this repo runs on: Mod4 on the native :0 session, Mod1 on the xrdp :10
// session (xrdp/xinitrc merges i3wm.mod: Mod1). Both are enumerated because
// ReservedChords below must hold under whichever one Validate happens to be
// called with.
var ModResolutions = []string{"Mod4", "Mod1"}

// modifierAliases folds every spelling the i3 configs and human habit
// already use onto one canonical Modifier. Folding these is what makes
// duplicate detection real: "Super+d" and "Mod4+d" are the same chord, and
// declaring both must be an error, not two binds racing for one key.
var modifierAliases = map[string]Modifier{
	"shift":   Shift,
	"lock":    Lock,
	"ctrl":    Ctrl,
	"control": Ctrl,
	"mod1":    Mod1,
	"alt":     Mod1,
	"meta":    Mod1,
	"mod2":    Mod2,
	"numlock": Mod2,
	"mod3":    Mod3,
	"mod4":    Mod4,
	"super":   Mod4,
	"win":     Mod4,
	"logo":    Mod4,
	"mod5":    Mod5,
}

// keysyms are the keysym names accepted in a chord's key position.
// Deliberately a static set rather than an X round-trip: validation must
// run with no display (--check in a hook, on a headless box). The daemon
// does the real keymap resolution and reports a keysym that is absent from
// the CURRENT keymap at that point.
var keysyms = buildKeysyms()

func buildKeysyms() map[string]bool {
	out := map[string]bool{}
	for c := 'a'; c <= 'z'; c++ {
		out[string(c)] = true
	}
	for c := '0'; c <= '9'; c++ {
		out[string(c)] = true
	}
	for n := 1; n <= 24; n++ {
		out[fmt.Sprintf("F%d", n)] = true
	}
	for _, k := range []string{
		"Return", "Escape", "Tab", "ISO_Left_Tab", "space", "BackSpace",
		"Delete", "Insert", "Home", "End", "Prior", "Next",
		"Left", "Right", "Up", "Down",
		"minus", "plus", "equal", "comma", "period", "slash", "backslash",
		"semicolon", "apostrophe", "grave", "bracketleft", "bracketright",
		"Print", "Pause", "Menu",
		"Shift_L", "Shift_R", "Control_L", "Control_R",
		"Alt_L", "Alt_R", "Super_L", "Super_R", "Meta_L", "Meta_R",
		"Num_Lock", "Caps_Lock",
		"XF86MonBrightnessUp", "XF86MonBrightnessDown",
		"XF86AudioRaiseVolume", "XF86AudioLowerVolume", "XF86AudioMute",
		"XF86AudioPlay", "XF86AudioNext", "XF86AudioPrev",
	} {
		out[k] = true
	}
	return out
}

// BindError is a chord or table that cannot be loaded. Message names the
// offender — the Go analogue of binds.py's BindError(ValueError).
type BindError struct{ Msg string }

func (e *BindError) Error() string { return e.Msg }

func bindErrorf(format string, a ...any) error {
	return &BindError{Msg: fmt.Sprintf(format, a...)}
}

// isMultiDigitKeycode reports whether key looks like a bare X keycode
// (">1 digit") rather than a keysym name. A single digit IS a keysym ("1" is
// the digit-one key, and "$mod+1" is how the workspace binds have always
// read); multi-digit means someone typed a keycode — 37, 105, 133 — which is
// the portability trap poc013 measured (Super_L is keycode 133 on :0, 115 on
// the xrdp :10 session).
func isMultiDigitKeycode(key string) bool {
	if len(key) < 2 {
		return false
	}
	_, err := strconv.Atoi(key)
	return err == nil
}

// ParseChord splits a chord into its modifier set and keysym name. mod is
// what the ModToken resolves to on the display being validated.
//
// Returns a *BindError naming the chord for anything unusable: an unknown
// modifier, an empty key, or a bare keycode.
func ParseChord(chord, mod string) (map[Modifier]bool, string, error) {
	if strings.TrimSpace(chord) == "" {
		return nil, "", bindErrorf("empty chord: %q", chord)
	}
	parts := strings.Split(chord, "+")
	key := strings.TrimSpace(parts[len(parts)-1])
	if key == "" {
		return nil, "", bindErrorf("chord %q has no key after the last '+'", chord)
	}
	if isMultiDigitKeycode(key) {
		return nil, "", bindErrorf(
			"chord %q uses a keycode (%s); use a keysym name — "+
				"keycodes differ per session (Super_L is 133 on :0, 115 on :10)",
			chord, key)
	}
	mods := map[Modifier]bool{}
	for _, raw := range parts[:len(parts)-1] {
		name := strings.ToLower(strings.TrimSpace(raw))
		if name == ModToken {
			name = strings.ToLower(strings.TrimSpace(mod))
		}
		canon, ok := modifierAliases[name]
		if !ok {
			return nil, "", bindErrorf("chord %q has unknown modifier %q", chord, raw)
		}
		mods[canon] = true
	}
	if !keysyms[key] {
		return nil, "", bindErrorf(
			"chord %q has unknown keysym %q (add it to bind.keysyms if the keymap really has it)",
			chord, key)
	}
	return mods, key, nil
}

// ChordKey is the order-insensitive, alias-folded identity of a chord, used
// for duplicate detection and the RESERVED_CHORDS membership test.
type ChordKey struct {
	Mods string // sorted, "+"-joined canonical modifier names, e.g. "Ctrl+Shift"
	Key  string
}

// NormalizeChord is ParseChord plus folding the modifier set into a stable,
// comparable identity.
func NormalizeChord(chord, mod string) (ChordKey, error) {
	mods, key, err := ParseChord(chord, mod)
	if err != nil {
		return ChordKey{}, err
	}
	return ChordKey{Mods: sortedModNames(mods), Key: key}, nil
}

func sortedModNames(mods map[Modifier]bool) string {
	names := make([]string, 0, len(mods))
	for m := range mods {
		names = append(names, string(m))
	}
	sort.Strings(names)
	return strings.Join(names, "+")
}

// CanonModifier resolves a modifier written on its own — a Mod sublayer's
// Modifier, a layer's Hold — where a chord's modifierAliases alone are not
// enough, because ParseChord resolves the ModToken for chords but a bare
// "$mod" looked up directly in modifierAliases would resolve to nothing on
// EITHER display, which is a feature that works on neither rather than one
// that works on the wrong one. Returns ("", false) for anything
// unresolvable, so callers report the offender themselves.
func CanonModifier(name, mod string) (Modifier, bool) {
	n := strings.ToLower(strings.TrimSpace(name))
	if n == ModToken {
		n = strings.ToLower(strings.TrimSpace(mod))
	}
	canon, ok := modifierAliases[n]
	return canon, ok
}

// canonDisplayMod resolves a Bind.DisplayMod value. "" means unqualified
// (ok=true, canon=""). Unlike CanonModifier, the ModToken itself is not a
// legal DisplayMod value — DisplayMod names a RESOLUTION ($mod's value on
// one display), not a token to be resolved, so "$mod" here is just an
// unrecognised modifier name like any other typo.
func canonDisplayMod(raw string) (canon string, ok bool) {
	if raw == "" {
		return "", true
	}
	n := strings.ToLower(strings.TrimSpace(raw))
	m, found := modifierAliases[n]
	if !found {
		return "", false
	}
	return string(m), true
}

// ReservedChords holds the panic chord's normalized identity under EVERY
// $mod resolution this repo runs on. Reserving the literal ModToken alone
// would leave a hole, because the validator is display-agnostic while $mod
// is not: a table that spells "Mod1+Ctrl+Shift+r" steals the chord on :10
// and "Mod4+Ctrl+Shift+r" steals it on :0, and neither is a string match for
// "$mod". Normalising the token under both resolutions closes it in both
// directions. Alias folding ("Super", "Alt", "win", case) comes free from
// NormalizeChord.
var ReservedChords = computeReservedChords()

func computeReservedChords() map[ChordKey]bool {
	out := map[ChordKey]bool{}
	for _, m := range ModResolutions {
		k, err := NormalizeChord(PanicChord, m)
		if err != nil {
			panic("bind: PanicChord failed to normalize under " + m + ": " + err.Error())
		}
		out[k] = true
	}
	return out
}
