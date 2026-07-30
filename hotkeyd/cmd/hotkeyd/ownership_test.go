package main

// ownership_test.go covers `check --ownership` (sp021 Task 13, bd
// dotfiles-ylmp.12, us020 AC3): per display, chord -> resolved modifier ->
// owner (i3/daemon/neither/BOTH), driven against a fabricated i3
// GET_CONFIG fixture -- exactly what test_plan asks for, no real i3 or X
// needed.

import (
	"bytes"
	"strings"
	"testing"

	"hotkeyd/internal/bind"
)

// TestOwnerOf_AllFourOutcomes is the core classification the design names
// verbatim: i3-only, daemon-only, neither, and BOTH.
func TestOwnerOf_AllFourOutcomes(t *testing.T) {
	i3Only := bind.ChordKey{Mods: "Mod4", Key: "x"}
	daemonOnly := bind.ChordKey{Mods: "Mod4", Key: "y"}
	both := bind.ChordKey{Mods: "Mod4", Key: "z"}
	untouched := bind.ChordKey{Mods: "Mod4", Key: "w"}

	i3Owned := map[bind.ChordKey]bool{i3Only: true, both: true}
	daemonOwned := map[bind.ChordKey]bool{daemonOnly: true, both: true}

	cases := []struct {
		name string
		key  bind.ChordKey
		want Owner
	}{
		{"i3-only", i3Only, OwnerI3},
		{"daemon-only", daemonOnly, OwnerDaemon},
		{"both", both, OwnerBoth},
		{"neither", untouched, OwnerNeither},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ownerOf(c.key, i3Owned, daemonOwned); got != c.want {
				t.Errorf("ownerOf(%v) = %v, want %v", c.key, got, c.want)
			}
		})
	}
}

// TestI3TopLevelBindsymChords_ExcludesModeBlock mirrors test_binds.py's
// _i3_chords: a bindsym declared inside a `mode "..." { }` block is NOT
// part of the always-on ownership set, because it is grabbed only while
// that mode is active.
func TestI3TopLevelBindsymChords_ExcludesModeBlock(t *testing.T) {
	cfg := `
# a comment, ignored
bindsym $mod+Return exec st
mode "resize" {
    bindsym h resize shrink width 5 px
    bindsym Escape mode "default"
}
bindsym $mod+q kill
`
	got := i3TopLevelBindsymChords(cfg)
	want := []string{"$mod+Return", "$mod+q"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("chord[%d] = %q, want %q (full: %v)", i, got[i], want[i], got)
		}
	}
}

// TestI3TopLevelBindsymChords_StripsBindFlags mirrors test_binds.py's
// _BIND_FLAGS handling: --release and friends precede the chord, not
// replace it.
func TestI3TopLevelBindsymChords_StripsBindFlags(t *testing.T) {
	cfg := `bindsym --release --whole-window $mod+Print exec scrot`
	got := i3TopLevelBindsymChords(cfg)
	if len(got) != 1 || got[0] != "$mod+Print" {
		t.Fatalf("got %v, want [$mod+Print]", got)
	}
}

// TestI3TopLevelBindsymChords_SeesRealBinds guards the guard: a parser
// that silently returns nothing would make every ownership assertion
// vacuously true (mirrors test_binds.py's
// test_the_i3_config_parser_actually_sees_binds).
func TestI3TopLevelBindsymChords_SeesRealBinds(t *testing.T) {
	got := i3TopLevelBindsymChords("bindsym $mod+h focus left\n")
	if len(got) == 0 {
		t.Fatal("parser saw zero binds in a config that plainly has one")
	}
}

// TestNormalizeI3Chord_FoldsModAndAliases proves the tolerant i3-side
// normalizer folds $mod through the SAME resolution bind.CanonModifier
// uses, and aliases (Super/Alt/...) the same way the daemon's own table
// does -- otherwise "Super+d" (i3 config spelling) and "Mod4+d" (daemon
// spelling) would misreport as two different chords instead of a
// collision.
func TestNormalizeI3Chord_FoldsModAndAliases(t *testing.T) {
	a, ok := normalizeI3Chord("$mod+d", "Mod4")
	if !ok {
		t.Fatal("normalizeI3Chord($mod+d) failed to normalize")
	}
	b, ok := normalizeI3Chord("Super+d", "Mod1") // mod resolution irrelevant to a literal "Super"
	if !ok {
		t.Fatal("normalizeI3Chord(Super+d) failed to normalize")
	}
	if a != b {
		t.Errorf("$mod+d (under Mod4) = %v, Super+d = %v -- want equal (both fold to Mod4+d)", a, b)
	}
}

// TestNormalizeI3Chord_UnknownModifier_NotOK proves an i3-only or garbled
// modifier (unrecognised) is reported as unnormalizable rather than
// silently coerced into some other identity.
func TestNormalizeI3Chord_UnknownModifier_NotOK(t *testing.T) {
	if _, ok := normalizeI3Chord("Nonsense+d", "Mod4"); ok {
		t.Error("normalizeI3Chord accepted an unknown modifier")
	}
}

// TestDaemonOwnedChords_OnlyGlobalChords proves the daemon-owned set for
// ownership purposes is the ALWAYS-ON grab set (globalChords), not every
// chord in every layer -- a layer's own bare keys are only grabbed while
// that layer is active, so they are not part of the always-on ownership
// comparison, mirroring i3TopLevelBindsymChords' mode-block exclusion on
// the i3 side (test_binds.py's stated reasoning, ported).
func TestDaemonOwnedChords_OnlyGlobalChords(t *testing.T) {
	binds := []bind.Bind{{Chord: "$mod+q", Actions: []bind.Action{bind.Command("kill")}}}
	got := daemonOwnedChords(binds, "Mod4")
	want := bind.ChordKey{Mods: "Mod4", Key: "q"}
	if !got[want] {
		t.Fatalf("daemon-owned set missing the global chord %v: %v", want, got)
	}
	if len(got) != 1 {
		t.Fatalf("daemon-owned set = %v, want exactly 1 entry", got)
	}
}

// TestDaemonOwnedChords_DisplayQualifiedBind_NoFalseBOTH is us020 AC3, the
// success criterion named verbatim: a bind qualified to ONE $mod
// resolution must not participate in the daemon-owned set for the OTHER
// resolution, even if its literal chord string, resolved under that other
// mod, happens to collide with something i3 owns there.
func TestDaemonOwnedChords_DisplayQualifiedBind_NoFalseBOTH(t *testing.T) {
	// $mod+w, qualified to Mod4 only (dotfiles-hwds.50's restored bind,
	// the story's own motivating example).
	binds := []bind.Bind{{
		Chord:      "$mod+w",
		Actions:    []bind.Action{bind.Command("nop switcher")},
		DisplayMod: "Mod4",
	}}

	// Under Mod1 (:10, xrdp), $mod+w resolves to Mod1+w -- suppose i3
	// there ALSO binds Alt+w (a real collision, dotfiles-hwds.50's actual
	// incident: Alt+w is emacs/readline's copy chord).
	i3Config := "bindsym Mod1+w exec true\n"

	daemonOwned := daemonOwnedChords(binds, "Mod1")
	i3Owned := i3OwnedChords(i3Config, "Mod1")

	key := bind.ChordKey{Mods: "Mod1", Key: "w"}
	if daemonOwned[key] {
		t.Fatalf("daemon-owned set under Mod1 includes a Mod4-qualified bind: %v", daemonOwned)
	}
	owner := ownerOf(key, i3Owned, daemonOwned)
	if owner == OwnerBoth {
		t.Errorf("display-qualified bind produced a FALSE BOTH under the non-owning resolution: %v", owner)
	}
	if owner != OwnerI3 {
		t.Errorf("owner = %v, want OwnerI3 (i3 alone owns Mod1+w on :10)", owner)
	}

	// And under Mod4 (:0, native) the SAME bind DOES participate, so a
	// real i3 collision there is still caught -- the qualifier narrows
	// scope, it does not blind the check entirely.
	daemonOwnedNative := daemonOwnedChords(binds, "Mod4")
	nativeKey := bind.ChordKey{Mods: "Mod4", Key: "w"}
	if !daemonOwnedNative[nativeKey] {
		t.Fatalf("Mod4-qualified bind absent from the daemon-owned set under ITS OWN resolution: %v", daemonOwnedNative)
	}
}

// TestReportOwnership_AnyBOTH_ReturnsNonZero pins the "non-zero on any
// BOTH" success criterion end-to-end through reportOwnership.
func TestReportOwnership_AnyBOTH_ReturnsNonZero(t *testing.T) {
	binds := []bind.Bind{{Chord: "$mod+q", Actions: []bind.Action{bind.Command("kill")}}}
	i3Config := "bindsym $mod+q exec true\n" // collides under EVERY resolution

	var buf bytes.Buffer
	code := reportOwnership(&buf, i3Config, binds)
	if code == 0 {
		t.Fatalf("reportOwnership with a real BOTH collision returned 0; output:\n%s", buf.String())
	}
	if !strings.Contains(buf.String(), "BOTH") {
		t.Errorf("report does not name the BOTH collision: %s", buf.String())
	}
}

// TestReportOwnership_NoCollisions_ReturnsZero is the clean-bill twin: a
// table and config that never overlap must exit 0.
func TestReportOwnership_NoCollisions_ReturnsZero(t *testing.T) {
	binds := []bind.Bind{{Chord: "$mod+q", Actions: []bind.Action{bind.Command("kill")}}}
	i3Config := "bindsym $mod+Return exec st\n"

	var buf bytes.Buffer
	if code := reportOwnership(&buf, i3Config, binds); code != 0 {
		t.Fatalf("reportOwnership with no collisions = %d, want 0; output:\n%s", code, buf.String())
	}
}

// TestReportOwnership_DisplayQualifiedBind_EndToEnd_NoFalseBOTH is
// TestDaemonOwnedChords_DisplayQualifiedBind_NoFalseBOTH's twin at the
// reportOwnership entry point, over BOTH resolutions the function actually
// loops -- proving the CLI-level report, not just the helper, never emits
// a false BOTH for a display-qualified bind.
func TestReportOwnership_DisplayQualifiedBind_EndToEnd_NoFalseBOTH(t *testing.T) {
	binds := []bind.Bind{{
		Chord:      "$mod+w",
		Actions:    []bind.Action{bind.Command("nop switcher")},
		DisplayMod: "Mod4",
	}}
	i3Config := "bindsym Mod1+w exec true\n"

	var buf bytes.Buffer
	code := reportOwnership(&buf, i3Config, binds)
	if code != 0 {
		t.Fatalf("reportOwnership = %d, want 0 (no real BOTH, only a display-scoped non-collision); output:\n%s", code, buf.String())
	}
	if strings.Contains(buf.String(), "BOTH") {
		t.Errorf("report names a BOTH that should not exist: %s", buf.String())
	}
}
