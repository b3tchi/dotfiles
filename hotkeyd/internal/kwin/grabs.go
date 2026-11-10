package kwin

import (
	"fmt"
	"sort"

	"hotkeyd/internal/bind"
)

// X11 modifier values, which the grab server's mods field uses.
const (
	ModShift uint32 = 1
	ModCtrl  uint32 = 4
	ModAlt   uint32 = 8
	ModSuper uint32 = 64
)

var modMask = map[bind.Modifier]uint32{
	bind.Shift: ModShift, bind.Ctrl: ModCtrl, bind.Mod1: ModAlt, bind.Mod4: ModSuper,
}

// Chord is what the plugin is asked to grab. It is the Wayland-side
// analogue of cmd/hotkeyd's GrabbedChord{Code, Mask}.
type Chord struct {
	Keysym uint32
	Mods   uint32
}

// shiftedSymbol is the US-layout shift level of the symbol keys. KWin
// reports a chord AFTER the shift level (measured on 6.8.1: Super+Shift+1
// arrives as (exclam, Super)), so a "+Shift+1" chord is sent as the shifted
// keysym with Shift removed from mods. ASSUMPTION/LIMITATION: this is a US
// map; hotkeyd has no per-layout shift-level data (X11 asks the live keymap),
// so on another layout a shifted symbol chord will not match. Letters need
// no entry: they shift to upper case and KWin keeps Shift in mods for them.
var shiftedSymbol = map[string]uint32{
	"1": '!', "2": '@', "3": '#', "4": '$', "5": '%', "6": '^', "7": '&',
	"8": '*', "9": '(', "0": ')', "minus": '_', "equal": '+', "comma": '<',
	"period": '>', "slash": '?', "semicolon": ':', "apostrophe": '"',
	"grave": '~', "bracketleft": '{', "bracketright": '}', "backslash": '|',
	"Tab": 0xfe20, // ISO_Left_Tab (unmeasured; xkb's usual Shift+Tab level)
}

// resolve turns a chord string into the wire chord.
func resolve(chord, mod string, keysym func(string) (uint32, bool)) (Chord, error) {
	mods, key, err := bind.ParseChord(chord, mod)
	if err != nil {
		return Chord{}, err
	}
	ks, ok := keysym(key)
	if !ok {
		return Chord{}, fmt.Errorf("chord %q: keysym %q is not known to the grab table", chord, key)
	}
	var m uint32
	for k := range mods {
		bit, ok := modMask[k]
		if !ok {
			return Chord{}, fmt.Errorf("chord %q: modifier %s cannot be grabbed on KWin", chord, k)
		}
		m |= bit
	}
	if m&ModShift != 0 {
		switch {
		case len(key) == 1 && key[0] >= 'a' && key[0] <= 'z':
			ks = uint32(key[0] - 'a' + 'A') // letter: upper case, Shift kept
		default:
			if s, ok := shiftedSymbol[key]; ok {
				ks, m = s, m&^ModShift // symbol: shift level, Shift consumed
			}
		}
	}
	return Chord{Keysym: ks, Mods: m}, nil
}

// GrabManager mirrors cmd/hotkeyd's X11 GrabManager method set over the
// grab server. KeysymByName is the daemon's existing keysym table.
type GrabManager struct {
	c      *Client
	mod    string
	keysym func(string) (uint32, bool)
	log    func(string)

	wanted   []string
	active   map[string]Chord
	problems []string
	reported map[string]bool
}

// NewGrabManager dials the plugin (fail-fast, see Dial). mod is what $mod
// resolves to; keysym resolves a keysym name; log may be nil.
func NewGrabManager(path, mod string, keysym func(string) (uint32, bool), log func(string)) (*GrabManager, error) {
	c, err := Dial(path, log)
	if err != nil {
		return nil, err
	}
	if log == nil {
		log = func(s string) { fmt.Println("hotkeyd: " + s) }
	}
	return &GrabManager{c: c, mod: mod, keysym: keysym, log: log,
		active: map[string]Chord{}, reported: map[string]bool{}}, nil
}

// Events is the plugin's event stream, for the daemon's run loop.
func (g *GrabManager) Events() <-chan Event { return g.c.Events() }

// Close stops the connection.
func (g *GrabManager) Close() { g.c.Close() }

// SyncBinds sends the resolved set. Unresolvable chords become problems and
// the rest are still grabbed. Returns whether the active set changed.
func (g *GrabManager) SyncBinds(chords []string) bool {
	seen := map[string]bool{}
	g.wanted = nil
	for _, ch := range chords {
		if !seen[ch] {
			seen[ch] = true
			g.wanted = append(g.wanted, ch)
		}
	}
	return g.apply()
}

func (g *GrabManager) apply() bool {
	resolved := map[string]Chord{}
	taken := map[Chord]bool{}
	var wire []wireChord
	g.problems = nil
	for _, ch := range g.wanted {
		c, err := resolve(ch, g.mod, g.keysym)
		if err != nil {
			g.problems = append(g.problems, err.Error())
			continue
		}
		if taken[c] {
			continue
		}
		taken[c] = true
		resolved[ch] = c
		wire = append(wire, wireChord{c.Keysym, c.Mods})
	}
	// The protocol has no ack: "active" is what a live connection was
	// given. While disconnected nothing is grabbed (the plugin clears the
	// set), and the reconnect re-sends it.
	sent := g.c.SetGrabs(wire)
	next := map[string]Chord{}
	if sent {
		next = resolved
	}
	changed := len(next) != len(g.active)
	for k, v := range next {
		if g.active[k] != v {
			changed = true
		}
	}
	g.active = next
	g.reportProblems()
	return changed
}

func (g *GrabManager) reportProblems() {
	for _, p := range g.problems {
		if !g.reported[p] {
			g.reported[p] = true
			g.log("grab problem: " + p)
		}
	}
}

// OnMappingNotify is a no-op: KWin delivers keysyms already resolved
// through xkb, so there is no X keyboard mapping to re-sync against.
func (g *GrabManager) OnMappingNotify() bool { return false }

// Active is a copy of the chords the plugin was given on the live link.
func (g *GrabManager) Active() map[string]Chord {
	out := make(map[string]Chord, len(g.active))
	for k, v := range g.active {
		out[k] = v
	}
	return out
}

// Wanted is the requested chord list, in order.
func (g *GrabManager) Wanted() []string { return append([]string(nil), g.wanted...) }

// GrabReport counts wanted vs active and lists the chords missing.
func (g *GrabManager) GrabReport() (wanted, active int, missing []string) {
	for _, ch := range g.wanted {
		if _, ok := g.active[ch]; !ok {
			missing = append(missing, ch)
		}
	}
	sort.Strings(missing)
	return len(g.wanted), len(g.active), missing
}
