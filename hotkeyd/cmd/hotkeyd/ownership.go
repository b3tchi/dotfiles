// ownership.go implements `check --ownership` (sp021 Task 13, bd
// dotfiles-ylmp.12) -- a NEW capability with no hotkeyd.py precedent,
// designed in now per us020 AC3 even though us020 itself is still `status:
// draft`: per display, chord -> resolved modifier -> owner (i3 / daemon /
// neither / BOTH), non-zero exit on any BOTH.
//
// # Where the ownership data comes from
//
// i3's side: i3 IPC's GET_CONFIG returns the RAW, unparsed config file text
// -- it does not expose i3's parsed bind table structurally. This package
// therefore parses `bindsym` lines itself, the same way
// hotkeyd/test_binds.py's `_i3_chords` already does for the fallback-file
// freshness tests (see i3TopLevelBindsymChords): only TOP-LEVEL binds count
// (a bindsym inside a `mode "..." { }` block is grabbed only while that
// mode is active, so it is not part of the always-on ownership set i3
// always contests).
//
// The daemon's side: daemonOwnedChords reuses daemon.go's globalChords,
// the SAME always-on grab-set function main.go wires into the real
// GrabManager -- not every chord in every layer, for the identical reason
// (a layer's own binds are conditional on that layer being active).
//
// # Per display means per $mod resolution
//
// i3's raw config text is the SAME regardless of which of this repo's two
// sessions asks (native :0 sets `i3wm.mod: Mod4`, xrdp :10 sets
// `i3wm.mod: Mod1` -- see grabs.go's ResolveMod) -- both sessions run the
// SAME config files, just with $mod substituted differently. So "per
// display" means: fetch GET_CONFIG once from whichever i3 the --display
// flag resolves to, then evaluate ownership under EVERY entry in
// bind.ModResolutions, exactly mirroring how test_binds.py's own
// fallback-freshness tests are `@pytest.mark.parametrize("mod", ["Mod4",
// "Mod1"])` against one config file.
package main

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/i3"
)

// Owner is check --ownership's four-way classification for one chord under
// one $mod resolution.
type Owner string

const (
	OwnerI3      Owner = "i3"
	OwnerDaemon  Owner = "daemon"
	OwnerNeither Owner = "neither"
	OwnerBoth    Owner = "BOTH"
)

// ownerOf classifies chord against the i3-owned and daemon-owned sets for
// ONE $mod resolution. Pure: the design's "per display, chord -> resolved
// modifier -> owner" mapping, factored out so it is independently testable
// against any fabricated pair of sets, including a chord present in
// NEITHER (which the CLI's own union-of-both-sets enumeration can never
// produce, but the mapping itself must still answer correctly -- see
// TestOwnerOf_AllFourOutcomes).
func ownerOf(chord bind.ChordKey, i3Owned, daemonOwned map[bind.ChordKey]bool) Owner {
	inI3 := i3Owned[chord]
	inDaemon := daemonOwned[chord]
	switch {
	case inI3 && inDaemon:
		return OwnerBoth
	case inI3:
		return OwnerI3
	case inDaemon:
		return OwnerDaemon
	default:
		return OwnerNeither
	}
}

// i3BindFlags are the bindsym flags i3 accepts before the chord itself --
// ported verbatim from hotkeyd/test_binds.py's _BIND_FLAGS, so a flagged
// bindsym line ("bindsym --release $mod+Print ...") is still recognized by
// its chord, not swallowed by the flag.
var i3BindFlags = map[string]bool{
	"--release": true, "--border": true, "--whole-window": true,
	"--exclude-titlebar": true, "--no-warn": true, "--locked": true,
}

// i3TopLevelBindsymChords extracts every top-level `bindsym` chord string
// from raw i3 config text, EXCLUDING anything inside a `mode "..." { }`
// block -- ported from hotkeyd/test_binds.py's _i3_chords, whose doc
// explains the exclusion: mode-scoped binds are grabbed only while that
// mode is active, so they are not part of the always-on ownership set this
// check compares against.
//
// Deliberately a line-oriented scan, not a real i3-config parser: this is
// exactly test_binds.py's own precedent (i3 has no IPC surface for its
// parsed bind table -- GET_CONFIG returns raw text), and nesting depth is
// tracked only for `mode { }` blocks, matching that file's own scope.
func i3TopLevelBindsymChords(configText string) []string {
	var out []string
	depth := 0
	for _, line := range strings.Split(configText, "\n") {
		s := strings.TrimSpace(line)
		if s == "" || strings.HasPrefix(s, "#") {
			continue
		}
		if strings.HasPrefix(s, "mode ") && strings.HasSuffix(s, "{") {
			depth++
			continue
		}
		if s == "}" {
			if depth > 0 {
				depth--
			}
			continue
		}
		if depth > 0 || !strings.HasPrefix(s, "bindsym") {
			continue
		}
		toks := strings.Fields(s)[1:]
		for len(toks) > 0 && i3BindFlags[toks[0]] {
			toks = toks[1:]
		}
		if len(toks) > 0 {
			out = append(out, toks[0])
		}
	}
	return out
}

// normalizeI3Chord folds an i3-side chord string into a bind.ChordKey under
// mod, TOLERANT of keysyms bind.keysyms has never heard of (i3-only
// spellings, mouse buttons, XF86 names this table does not use) --
// deliberately NOT bind.NormalizeChord, which would reject those as
// "unknown keysym" and silently drop them from the ownership picture.
// Modifiers still fold through bind.CanonModifier (the SAME alias table
// and $mod resolution the daemon's own chords use), so "Super+d" and
// "$mod+d" (mod=Mod4) compare equal -- ownership is meaningless without
// that folding. ok=false means an unrecognised MODIFIER (never an
// unrecognised key) made the chord unnormalizable.
func normalizeI3Chord(chord, mod string) (bind.ChordKey, bool) {
	parts := strings.Split(chord, "+")
	key := strings.TrimSpace(parts[len(parts)-1])
	if key == "" {
		return bind.ChordKey{}, false
	}
	mods := make([]string, 0, len(parts)-1)
	for _, raw := range parts[:len(parts)-1] {
		canon, ok := bind.CanonModifier(raw, mod)
		if !ok {
			return bind.ChordKey{}, false
		}
		mods = append(mods, string(canon))
	}
	sort.Strings(mods)
	return bind.ChordKey{Mods: strings.Join(mods, "+"), Key: key}, true
}

// i3OwnedChords is i3's always-on ownership set for one $mod resolution:
// every top-level bindsym chord in configText, normalized.
func i3OwnedChords(configText, mod string) map[bind.ChordKey]bool {
	out := map[bind.ChordKey]bool{}
	for _, chord := range i3TopLevelBindsymChords(configText) {
		if key, ok := normalizeI3Chord(chord, mod); ok {
			out[key] = true
		}
	}
	return out
}

// daemonOwnedChords is the daemon's always-on ownership set for one $mod
// resolution: globalChords (daemon.go) -- the exact same always-on grab
// set main.go wires into the real GrabManager, which already excludes
// layer-only binds and honours DisplayMod scoping (chordActiveOnDisplay)
// -- normalized the same way the daemon's own table validation does
// (bind.NormalizeChord). A chord that fails to normalize here would mean
// the compiled table is invalid, which --check already refuses before
// --ownership could ever see it, so errors are silently skipped rather
// than surfaced a second time.
func daemonOwnedChords(binds []bind.Bind, mod string) map[bind.ChordKey]bool {
	out := map[bind.ChordKey]bool{}
	for _, chord := range globalChords(binds, mod) {
		if key, err := bind.NormalizeChord(chord, mod); err == nil {
			out[key] = true
		}
	}
	return out
}

// unionSortedKeys returns the union of a and b's keys, in a stable
// (Mods,Key) order -- so reportOwnership's output is deterministic and
// diffable, not map-iteration-order dependent.
func unionSortedKeys(a, b map[bind.ChordKey]bool) []bind.ChordKey {
	seen := map[bind.ChordKey]bool{}
	var out []bind.ChordKey
	for k := range a {
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	for k := range b {
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Mods != out[j].Mods {
			return out[i].Mods < out[j].Mods
		}
		return out[i].Key < out[j].Key
	})
	return out
}

// chordKeyString renders a ChordKey the way a chord is normally spelled
// ("Mod4+Shift+q", or just "q" for a bare key).
func chordKeyString(k bind.ChordKey) string {
	if k.Mods == "" {
		return k.Key
	}
	return k.Mods + "+" + k.Key
}

// reportOwnership is check --ownership's pure report body: given i3's raw
// GET_CONFIG text and the compiled bind table, print per-$mod-resolution
// ownership rows to w and return 0, or non-zero if any chord is owned by
// BOTH. Factored out from runOwnership so it is testable with a fabricated
// i3 config fixture and zero real i3 connection (test_plan's own words:
// "against a fixture i3 config").
func reportOwnership(w io.Writer, i3Config string, binds []bind.Bind) int {
	anyBoth := false
	for _, mod := range bind.ModResolutions {
		i3Owned := i3OwnedChords(i3Config, mod)
		daemonOwned := daemonOwnedChords(binds, mod)

		fmt.Fprintf(w, "-- $mod=%s --\n", mod)
		for _, key := range unionSortedKeys(i3Owned, daemonOwned) {
			owner := ownerOf(key, i3Owned, daemonOwned)
			fmt.Fprintf(w, "  %-24s %s\n", chordKeyString(key), owner)
			if owner == OwnerBoth {
				anyBoth = true
			}
		}
	}
	if anyBoth {
		fmt.Fprintln(w, "hotkeyd: check --ownership: at least one chord is owned by BOTH i3 and the daemon")
		return 1
	}
	return 0
}

// runOwnership is `check --ownership`'s production entry point: resolve
// display's i3 IPC socket (the same cross-display-safe resolver main.go's
// real daemon uses, so this never queries the WRONG i3 -- see main.go's
// i3SocketResolver doc), fetch GET_CONFIG, and report.
func runOwnership(display string) int {
	client := i3.NewClient(i3SocketResolver(resolveDisplay(display)), nil)
	defer client.Close()

	cfg, err := client.GetConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "hotkeyd: check --ownership: cannot reach i3: %s\n", err)
		return 1
	}
	return reportOwnership(os.Stdout, cfg, Binds)
}
