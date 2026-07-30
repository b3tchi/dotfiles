// GrabManager, DeviceRegistry, and $mod resolution (sp021 Task 10, bd
// dotfiles-ylmp.10) — the Go port of hotkeyd.py's GrabManager +
// DeviceRegistry + x_resource_mod ([[ft011]]). Dispatch-time chord
// resolution (matching an incoming XIDeviceEvent back to a bind) is out of
// scope here — that is cmd/hotkeyd's daemon-assembly task (bd
// dotfiles-ylmp.11); this file owns the grab set and its wire-level
// resolution only.
package main

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/x11"
)

// ---------------------------------------------------------------------
// modifier masks — xproto.h's ModMask bits. Lock and Mod2 are already
// named in the x11 package (the lock-bit fan-out GrabModifierVariants
// builds); the rest are named here because they are CHORD modifiers, not
// lock bits.
// ---------------------------------------------------------------------

const (
	maskShift uint32 = 0x01
	maskCtrl  uint32 = 0x04
	maskMod1  uint32 = 0x08
	maskMod3  uint32 = 0x20
	maskMod4  uint32 = 0x40
	maskMod5  uint32 = 0x80
)

var maskByModifier = map[bind.Modifier]uint32{
	bind.Shift: maskShift,
	bind.Lock:  x11.ModMaskLock,
	bind.Ctrl:  maskCtrl,
	bind.Mod1:  maskMod1,
	bind.Mod2:  x11.ModMaskMod2,
	bind.Mod3:  maskMod3,
	bind.Mod4:  maskMod4,
	bind.Mod5:  maskMod5,
}

// maskFromMods folds a chord's parsed modifier set into the core X11
// modifier mask XIPassiveGrabDevice's base modifier expects.
func maskFromMods(mods map[bind.Modifier]bool) uint32 {
	var mask uint32
	for m := range mods {
		mask |= maskByModifier[m]
	}
	return mask
}

// ---------------------------------------------------------------------
// keysym table — the numeric X keysym for every name bind.keysyms (chord.go)
// accepts. Values are from /usr/include/X11/keysymdef.h and XF86keysym.h.
// a-z and 0-9 equal their ASCII codepoint on any X server (XK_a==0x0061 ..
// XK_z==0x007a, XK_0==0x0030 .. XK_9==0x0039) and are filled in
// programmatically rather than listed by hand; F1..F24 are sequential from
// XK_F1==0xffbe. TestKeysymByName_CoversEveryNameConfigsRealTableUses keeps
// this in sync with the real bind table config.go ships.
var keysymByName = buildKeysymTable()

func buildKeysymTable() map[string]uint32 {
	out := map[string]uint32{
		"Return":       0xff0d,
		"Escape":       0xff1b,
		"Tab":          0xff09,
		"ISO_Left_Tab": 0xfe20,
		"space":        0x0020,
		"BackSpace":    0xff08,
		"Delete":       0xffff,
		"Insert":       0xff63,
		"Home":         0xff50,
		"End":          0xff57,
		"Prior":        0xff55,
		"Next":         0xff56,
		"Left":         0xff51,
		"Right":        0xff53,
		"Up":           0xff52,
		"Down":         0xff54,
		"minus":        0x002d,
		"plus":         0x002b,
		"equal":        0x003d,
		"comma":        0x002c,
		"period":       0x002e,
		"slash":        0x002f,
		"backslash":    0x005c,
		"semicolon":    0x003b,
		"apostrophe":   0x0027,
		"grave":        0x0060,
		"bracketleft":  0x005b,
		"bracketright": 0x005d,
		"Print":        0xff61,
		"Pause":        0xff13,
		"Menu":         0xff67,
		"Shift_L":      0xffe1,
		"Shift_R":      0xffe2,
		"Control_L":    0xffe3,
		"Control_R":    0xffe4,
		"Alt_L":        0xffe9,
		"Alt_R":        0xffea,
		"Super_L":      0xffeb,
		"Super_R":      0xffec,
		"Meta_L":       0xffe7,
		"Meta_R":       0xffe8,
		"Num_Lock":     0xff7f,
		"Caps_Lock":    0xffe5,

		// XF86keysym.h — media keys, not preloaded by every keysym table
		// (bind.go's doc notes python-xlib needed an explicit load_keysym_group
		// for these; here they are just static entries, so there is nothing
		// to load lazily).
		"XF86MonBrightnessUp":   0x1008ff02,
		"XF86MonBrightnessDown": 0x1008ff03,
		"XF86AudioRaiseVolume":  0x1008ff13,
		"XF86AudioLowerVolume":  0x1008ff11,
		"XF86AudioMute":         0x1008ff12,
		"XF86AudioPlay":         0x1008ff14,
		"XF86AudioNext":         0x1008ff17,
		"XF86AudioPrev":         0x1008ff16,
	}
	for c := 'a'; c <= 'z'; c++ {
		out[string(c)] = uint32(c)
	}
	for c := '0'; c <= '9'; c++ {
		out[string(c)] = uint32(c)
	}
	for n := 1; n <= 24; n++ {
		out[fmt.Sprintf("F%d", n)] = 0xffbe + uint32(n-1)
	}
	return out
}

// ---------------------------------------------------------------------
// chord resolution
// ---------------------------------------------------------------------

// GrabbedChord is the (keycode, base modifier mask) a chord resolves to —
// what XIPassiveGrabDevice actually grabs, exported so cmd/hotkeyd's
// daemon-assembly task (bd dotfiles-ylmp.11) can read GrabManager's active
// set without reaching into an unexported type.
type GrabbedChord struct {
	Code uint32
	Mask uint32
}

// codeForKeysym searches mapping's CURRENT rows for keysym and returns the
// keycode of the first row containing it. "Keysym-first" resolution: this
// walks the live keymap every call rather than trusting a keycode cached
// from an earlier one, which is what lets a chord recover after a
// transient remap (dotfiles-hwds.41).
func codeForKeysym(mapping x11.KeyboardMapping, keysym uint32) (byte, bool) {
	stride := int(mapping.KeysymsPerKeycode)
	if stride == 0 {
		return 0, false
	}
	rows := len(mapping.Keysyms) / stride
	for i := 0; i < rows; i++ {
		row := mapping.Keysyms[i*stride : (i+1)*stride]
		for _, ks := range row {
			if ks == keysym {
				return byte(int(mapping.FirstKeycode) + i), true
			}
		}
	}
	return 0, false
}

// resolveChord resolves one chord string to the (keycode, mask)
// XIPassiveGrabDevice needs, against mapping. mod is what $mod resolves to
// on this display (see ResolveMod).
func resolveChord(chord, mod string, mapping x11.KeyboardMapping) (GrabbedChord, error) {
	mods, key, err := bind.ParseChord(chord, mod)
	if err != nil {
		return GrabbedChord{}, err
	}
	keysym, ok := keysymByName[key]
	if !ok {
		return GrabbedChord{}, fmt.Errorf(
			"chord %q: keysym %q is not known to the grab table (add it to keysymByName)", chord, key)
	}
	code, ok := codeForKeysym(mapping, keysym)
	if !ok {
		return GrabbedChord{}, fmt.Errorf(
			"chord %q: keysym %q is not on the current keymap", chord, key)
	}
	return GrabbedChord{Code: uint32(code), Mask: maskFromMods(mods)}, nil
}

// ---------------------------------------------------------------------
// GrabManager
// ---------------------------------------------------------------------

// grabX is the subset of *x11.Conn's behavior GrabManager needs. The real
// *x11.Conn satisfies this interface automatically (see requests.go and
// xi2.go); a fake implementing it drives the unit tests with zero X.
type grabX interface {
	GetKeyboardMapping(firstKeycode, count byte) (x11.KeyboardMapping, error)
	XIPassiveGrabDevice(majorOpcode byte, grabWindow uint32, deviceid uint16, keycode uint32, modifiers, mask []uint32) (x11.GrabResult, error)
	XIPassiveUngrabDevice(majorOpcode byte, grabWindow uint32, deviceid uint16, keycode uint32, modifiers []uint32) error
}

// xiKeyEventMask is the XI2 event mask every chord grab registers: press
// and release. Bind.OnRelease dispatches off release DELIVERY, not off a
// second, separate grab.
var xiKeyEventMask = []uint32{x11.XIEventMaskKeyPress | x11.XIEventMaskKeyRelease}

// Compile-time check that the real *x11.Conn satisfies grabX, so a
// signature drift in internal/x11 fails cmd/hotkeyd's build immediately
// rather than being discovered at daemon-assembly time (bd
// dotfiles-ylmp.11).
var _ grabX = (*x11.Conn)(nil)

// GrabManager owns the mapping chord -> GrabbedChord and the XI2 passive
// grabs registered for it. Ported from hotkeyd.py's GrabManager ([[ft011]]);
// see dotfiles-hwds.41 for why WANTED and ACTIVE are kept as separate sets
// with the next grab set always computed from wanted.
type GrabManager struct {
	x           grabX
	majorOpcode byte
	grabWindow  uint32
	deviceID    uint16
	minKeycode  byte
	maxKeycode  byte
	mod         string
	log         func(string)

	mapping x11.KeyboardMapping

	// wanted is what the TABLE asks for -- deduplicated, order preserved.
	// Never mutated except by SyncBinds. apply() ALWAYS recomputes the next
	// grab set from wanted, never from active: deriving it from active is
	// what made the grab set monotonic (dotfiles-hwds.41) -- a chord lost to
	// one transient keymap change could never return, because the thing
	// that would have asked for it again was the very entry that got
	// deleted.
	wanted []string
	// active is what is CURRENTLY grabbed: chord -> the (code, mask) X
	// actually holds a passive grab for.
	active map[string]GrabbedChord

	problems []string
	reported map[string]bool
}

// NewGrabManager builds a GrabManager against x (the real *x11.Conn in
// production, a fake in tests). grabWindow is the target root window,
// majorOpcode is the XInputExtension major opcode (QueryExtension),
// deviceID is normally x11.DeviceAllMaster so a grab fires for every
// current and future master keyboard. minKeycode/maxKeycode come off the
// connection's SetupInfo. mod is what $mod resolves to on this display (see
// ResolveMod). log receives one line per newly-reported problem; nil
// defaults to a "hotkeyd: "-prefixed stderr line.
func NewGrabManager(x grabX, majorOpcode byte, grabWindow uint32, deviceID uint16, minKeycode, maxKeycode byte, mod string, log func(string)) *GrabManager {
	if log == nil {
		log = grabLog
	}
	return &GrabManager{
		x: x, majorOpcode: majorOpcode, grabWindow: grabWindow, deviceID: deviceID,
		minKeycode: minKeycode, maxKeycode: maxKeycode, mod: mod, log: log,
		active:   map[string]GrabbedChord{},
		reported: map[string]bool{},
	}
}

// Active returns a copy of the currently-grabbed chord -> GrabbedChord map.
func (g *GrabManager) Active() map[string]GrabbedChord {
	out := make(map[string]GrabbedChord, len(g.active))
	for k, v := range g.active {
		out[k] = v
	}
	return out
}

// Wanted returns a copy of the current wanted-chord list, in order.
func (g *GrabManager) Wanted() []string {
	return append([]string(nil), g.wanted...)
}

// SyncBinds makes the registered grabs match chords -- the new WANTED set.
// Only the difference between wanted and what is currently grabbed moves,
// so a table reload never drops a grab mid-gesture. Returns whether any
// grab actually changed.
func (g *GrabManager) SyncBinds(chords []string) bool {
	g.wanted = dedupPreserveOrder(chords)
	return g.apply()
}

// OnMappingNotify re-syncs the grab set against the CURRENT keymap:
// compare-then-regrab. Only (code, mask) pairs that actually changed are
// touched, so an unchanged chord is never dropped by a keymap event. Driven
// from wanted, never from active -- see the GrabManager doc.
func (g *GrabManager) OnMappingNotify() bool {
	return g.apply()
}

func dedupPreserveOrder(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		if seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

func keycodeCount(min, max byte) byte {
	n := int(max) - int(min) + 1
	if n < 0 {
		return 0
	}
	if n > 255 {
		return 255
	}
	return byte(n)
}

// resolveWanted resolves every wanted chord against mapping, deduplicating
// chords that resolve to the SAME (code, mask): two chords can name the
// same physical key at different shift levels (Tab / ISO_Left_Tab is the
// shipped instance), and asking X for the same passive grab twice would be
// a BadAccess against ourselves. First wanted chord wins; the loser is
// simply absent from resolved -- it is the same grab under another name,
// not a problem.
func (g *GrabManager) resolveWanted(mapping x11.KeyboardMapping) (resolved map[string]GrabbedChord, problems []string) {
	resolved = map[string]GrabbedChord{}
	taken := map[GrabbedChord]string{}
	for _, chord := range g.wanted {
		gc, err := resolveChord(chord, g.mod, mapping)
		if err != nil {
			problems = append(problems, err.Error())
			continue
		}
		if _, dup := taken[gc]; dup {
			continue
		}
		taken[gc] = chord
		resolved[chord] = gc
	}
	return resolved, problems
}

// apply re-resolves the wanted set against the live keymap and moves only
// the difference. Returns whether any grab actually changed.
func (g *GrabManager) apply() bool {
	mapping, err := g.x.GetKeyboardMapping(g.minKeycode, keycodeCount(g.minKeycode, g.maxKeycode))
	if err != nil {
		g.problems = []string{fmt.Sprintf("GetKeyboardMapping: %s", err)}
		g.reportProblems()
		return false
	}
	g.mapping = mapping

	resolved, problems := g.resolveWanted(mapping)
	g.problems = problems

	changed := false

	// Ungrab whatever is active but no longer resolves to its current
	// value -- sorted so the sequence of X calls is deterministic.
	stale := make([]string, 0, len(g.active))
	for chord := range g.active {
		if resolved[chord] != g.active[chord] {
			stale = append(stale, chord)
		}
	}
	sort.Strings(stale)
	for _, chord := range stale {
		g.ungrab(g.active[chord])
		delete(g.active, chord)
		changed = true
	}

	// Grab whatever wanted resolves to that is not already active at that
	// value -- iterate wanted's own order so a table's declaration order is
	// what determines grab order.
	for _, chord := range g.wanted {
		gc, ok := resolved[chord]
		if !ok {
			continue
		}
		if g.active[chord] == gc {
			continue
		}
		g.grab(chord, gc)
		changed = true
	}

	g.reportProblems()
	return changed
}

// coreErrorNames names the X core-protocol error codes hotkeyd's grab path
// can plausibly see, so a competing XI2 grabber's BadAccess (the [[ft011]]
// measured collision) is reported by name instead of a bare numeric code.
var coreErrorNames = map[byte]string{
	3:  "BadWindow",
	8:  "BadMatch",
	10: "BadAccess",
	11: "BadAlloc",
}

func describeXErr(err error) string {
	if xerr, ok := err.(x11.XError); ok {
		if name, ok := coreErrorNames[xerr.Code]; ok {
			return fmt.Sprintf("%s (%s)", name, err.Error())
		}
	}
	return err.Error()
}

func (g *GrabManager) grab(chord string, gc GrabbedChord) {
	variants := x11.GrabModifierVariants(gc.Mask)
	result, err := g.x.XIPassiveGrabDevice(g.majorOpcode, g.grabWindow, g.deviceID, gc.Code, variants, xiKeyEventMask)
	if err != nil {
		// A checked request surfaces a competing grabber's BadAccess here,
		// synchronously (the [[ft011]] measured collision) -- named, fed to
		// problems/health, never silent.
		g.problems = append(g.problems, fmt.Sprintf(
			"chord %q: %s -- already grabbed by another client?", chord, describeXErr(err)))
		return
	}
	if !result.AllSucceeded() {
		// Per-modifier failure: the reply names exactly which lock-bit
		// variants the server refused. Any failure means the chord as a
		// whole does not become active -- a partially-failed chord must be
		// visible to --health (verdict 9), not half-served.
		g.problems = append(g.problems, fmt.Sprintf(
			"chord %q: %d of %d modifier variant(s) refused -- already grabbed by another client?",
			chord, len(result.Failed), len(variants)))
		return
	}
	g.active[chord] = gc
}

func (g *GrabManager) ungrab(gc GrabbedChord) {
	variants := x11.GrabModifierVariants(gc.Mask)
	if err := g.x.XIPassiveUngrabDevice(g.majorOpcode, g.grabWindow, g.deviceID, gc.Code, variants); err != nil {
		// Best-effort: a failed ungrab of a chord leaving the wanted set
		// leaves a stray grab, not a crash.
		g.problems = append(g.problems, fmt.Sprintf("ungrab code=%d mask=%#x: %s", gc.Code, gc.Mask, err))
	}
}

// reportProblems announces a problem the first time it appears in this
// apply() round, edge-triggered on the message TEXT so a burst of
// MappingNotify does not spam the same line repeatedly.
func (g *GrabManager) reportProblems() {
	current := make(map[string]bool, len(g.problems))
	for _, p := range g.problems {
		current[p] = true
	}
	var newly []string
	for p := range current {
		if !g.reported[p] {
			newly = append(newly, p)
		}
	}
	sort.Strings(newly)
	for _, p := range newly {
		g.log(p)
	}
	g.reported = current
}

func grabLog(msg string) {
	fmt.Fprintln(os.Stderr, "hotkeyd: "+msg)
}

// GrabReport returns the wanted/active counts and the NAMED list of chords
// the table asks for but does not currently hold -- the evidence
// proc.WriteGrabReport publishes for --health verdict 9 (adr0017). Reuses
// the mapping from the most recent apply() round (SyncBinds/OnMappingNotify)
// rather than issuing a fresh GetKeyboardMapping, since it is always called
// immediately after one of those in the daemon's own loop.
func (g *GrabManager) GrabReport() (wanted, active int, missing []string) {
	taken := map[GrabbedChord]bool{}
	unresolvable := 0
	for _, chord := range g.wanted {
		gc, err := resolveChord(chord, g.mod, g.mapping)
		if err != nil {
			// Cannot resolve at all right now (unknown keysym, or absent
			// from the current keymap) -- has no grab target yet, so it
			// contributes to wanted on its own, not via taken.
			missing = append(missing, chord)
			unresolvable++
			continue
		}
		if taken[gc] {
			continue // same physical grab under another name -- see resolveWanted
		}
		taken[gc] = true
		if g.active[chord] != gc {
			// Resolves to a real target, but that target is not (yet)
			// actually held -- e.g. XIPassiveGrabDevice refused it. Already
			// counted via taken above; only added to the NAMED missing
			// list here, not double-counted into wanted.
			missing = append(missing, chord)
		}
	}
	return len(taken) + unresolvable, len(g.active), missing
}

// ---------------------------------------------------------------------
// $mod resolution
// ---------------------------------------------------------------------

// resourceManagerAtom is XA_RESOURCE_MANAGER (X11/Xatom.h) -- a PREDEFINED
// X11 atom, 23 on every server, so resolving it costs no InternAtom round
// trip.
const resourceManagerAtom uint32 = 23

// modPropertyFetcher matches x11.Conn.GetPropertyAll's shape -- the seam
// that lets ResolveMod run against a fake property store in tests, and (in
// production) is exactly what exercises Task 4's BytesAfter loop for a
// RESOURCE_MANAGER that spans more than one GetProperty reply.
type modPropertyFetcher func(window, property, propertyType uint32) (format byte, typ uint32, value []byte, err error)

// Compile-time check that (*x11.Conn).GetPropertyAll satisfies
// modPropertyFetcher.
var _ modPropertyFetcher = (*x11.Conn)(nil).GetPropertyAll

// ResolveMod is what "$mod" means on this display: the value of the
// "i3wm.mod:" line in RESOURCE_MANAGER, with bind.DefaultMod (Mod4) as the
// DEFAULT ON ABSENCE. ":0" has NO i3wm.mod line in RESOURCE_MANAGER AT ALL
// ([[poc015]] measured) -- so this replicates i3's own set_from_resource
// fallback semantics, not a value read off the server. A fetch error is
// treated the same as absence: a display that cannot answer GetProperty is,
// for this purpose, no different from one that answered with nothing.
func ResolveMod(fetch modPropertyFetcher, root uint32) string {
	_, _, value, err := fetch(root, resourceManagerAtom, x11.AnyPropertyType)
	if err != nil {
		return bind.DefaultMod
	}
	for _, line := range strings.Split(string(value), "\n") {
		name, val, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		if strings.TrimSpace(name) != "i3wm.mod" {
			continue
		}
		if v := strings.TrimSpace(val); v != "" {
			return v
		}
	}
	return bind.DefaultMod
}
