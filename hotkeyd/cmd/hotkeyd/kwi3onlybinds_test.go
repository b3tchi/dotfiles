package main

// bd kwi3-55l.1: $mod+Shift+q (i3's "kill") did nothing on a kwi3 X11
// session (3392). Root cause: the chord is deliberately ABSENT from Binds
// (buildBinds(), config.go) -- i3/config.common's own comment calls it
// "STILL i3's, on purpose", kept native so it survives even if this daemon
// crashes -- but a kwi3 session has no i3 process to own it at all, so it
// reached nobody. Kwi3OnlyBinds (config.go) plus effectiveBinds (main.go)
// give the daemon that same chord, translated over $KWI3SOCK via
// internal/kwi3rpc, but ONLY when a kwi3 session is detected -- a plain i3
// session's grab set is untouched, so the "STILL i3's" resilience argument
// and the ownership invariant it protects (a chord is owned by i3 XOR the
// daemon, never both) both keep holding there.
//
// This file is the regression test AT THE BREAK POINT: effectiveBinds is
// exactly the function main.go's run() calls to decide what this process
// grabs, so a future change that once again drops $mod+Shift+q from the
// kwi3 grab set -- or, the opposite mistake, leaks it into a plain i3
// session's grab set -- fails here without needing Xvfb or a real daemon.

import (
	"sort"
	"testing"

	"hotkeyd/internal/bind"
)

// TestEffectiveBinds_NoKwi3Sock_IsBaseBindsUnchanged is the "a plain i3
// session is untouched" half: with kwi3Sock == "" (run()'s value whenever
// $KWI3SOCK is unset), effectiveBinds must hand back Binds itself -- same
// length, same chords, in particular NOT carrying $mod+Shift+q -- so
// `check --ownership` run against the real i3/config.common (which still
// natively owns that chord, config.common line ~56) never sees it as a
// daemon-owned chord and reports a BOTH collision. Compared by chord+action
// rather than by slice identity: what must hold is behavioural equivalence,
// not that no copy was ever made.
func TestEffectiveBinds_NoKwi3Sock_IsBaseBindsUnchanged(t *testing.T) {
	got := effectiveBinds("")
	if len(got) != len(Binds) {
		t.Fatalf("effectiveBinds(\"\") has %d binds, want exactly len(Binds) = %d", len(got), len(Binds))
	}
	for i := range Binds {
		if got[i].Chord != Binds[i].Chord {
			t.Fatalf("effectiveBinds(\"\")[%d].Chord = %q, want %q (Binds must be unchanged for a non-kwi3 session)",
				i, got[i].Chord, Binds[i].Chord)
		}
	}
	for _, b := range got {
		if b.Chord == "$mod+Shift+q" {
			t.Fatalf("effectiveBinds(\"\") includes $mod+Shift+q -- a plain i3/sway session must leave " +
				"that chord to i3's own native bindsym (i3/config.common), not grab it too")
		}
	}
}

// TestEffectiveBinds_Kwi3Sock_AddsKillAndNothingElse is the kwi3-session
// half: with a non-empty kwi3Sock (run()'s value whenever $KWI3SOCK is
// set), effectiveBinds must return every chord in Binds PLUS exactly
// Kwi3OnlyBinds appended -- the actual fix for kwi3-55l.1's reported bug.
func TestEffectiveBinds_Kwi3Sock_AddsKillAndNothingElse(t *testing.T) {
	got := effectiveBinds("/run/user/1000/kwi3.rpc.sock")
	if len(got) != len(Binds)+len(Kwi3OnlyBinds) {
		t.Fatalf("effectiveBinds(sock) has %d binds, want len(Binds)+len(Kwi3OnlyBinds) = %d",
			len(got), len(Binds)+len(Kwi3OnlyBinds))
	}
	for i := range Binds {
		if got[i].Chord != Binds[i].Chord {
			t.Fatalf("effectiveBinds(sock)[%d].Chord = %q, want %q (Binds prefix must be unchanged)",
				i, got[i].Chord, Binds[i].Chord)
		}
	}
	tail := got[len(Binds):]
	if len(tail) != len(Kwi3OnlyBinds) {
		t.Fatalf("effectiveBinds(sock) tail has %d entries, want %d", len(tail), len(Kwi3OnlyBinds))
	}
	for i := range Kwi3OnlyBinds {
		if tail[i].Chord != Kwi3OnlyBinds[i].Chord {
			t.Fatalf("effectiveBinds(sock) tail[%d].Chord = %q, want %q", i, tail[i].Chord, Kwi3OnlyBinds[i].Chord)
		}
	}

	var found bool
	for _, b := range got {
		if b.Chord != "$mod+Shift+q" {
			continue
		}
		found = true
		if len(b.Actions) != 1 {
			t.Fatalf("$mod+Shift+q has %d actions, want exactly 1", len(b.Actions))
		}
		cmd, ok := b.Actions[0].(bind.Command)
		if !ok || string(cmd) != "kill" {
			t.Fatalf("$mod+Shift+q's action = %#v, want bind.Command(\"kill\")", b.Actions[0])
		}
	}
	if !found {
		t.Fatal("effectiveBinds(sock) is missing $mod+Shift+q entirely -- the kwi3-55l.1 fix regressed")
	}
}

// TestEffectiveBinds_Kwi3Sock_DoesNotMutateBinds guards against a future
// rewrite that appends to Binds in place (`append(Binds, Kwi3OnlyBinds...)`
// instead of a fresh slice) -- which would silently leak $mod+Shift+q into
// every FUTURE plain-i3 call too, since append can grow Binds's own backing
// array when it has spare capacity.
func TestEffectiveBinds_Kwi3Sock_DoesNotMutateBinds(t *testing.T) {
	before := len(Binds)
	_ = effectiveBinds("/some/sock")
	if len(Binds) != before {
		t.Fatalf("calling effectiveBinds with a kwi3 sock changed len(Binds) from %d to %d -- "+
			"it must return a fresh slice, never grow Binds's own backing array", before, len(Binds))
	}
	for _, b := range Binds {
		if b.Chord == "$mod+Shift+q" {
			t.Fatal("Binds itself now contains $mod+Shift+q after a kwi3-session call -- mutation leaked")
		}
	}
}

// TestKwi3OnlyBinds_ValidatesUnderBothModResolutions proves the MERGED
// table (what a real kwi3 session actually grabs) is a valid bind.Bind
// table under both $mod resolutions this daemon ever runs under (native
// Mod4, xrdp Mod1) -- no duplicate chord, no reserved-chord collision, no
// malformed layer reference. Binds and Layers alone are already covered by
// TestValidatorOverRealTable_BothModResolutions; this is that same
// guarantee for the table effectiveBinds hands to a kwi3 session.
func TestKwi3OnlyBinds_ValidatesUnderBothModResolutions(t *testing.T) {
	merged := effectiveBinds("/some/sock")
	for _, mod := range []string{"Mod4", "Mod1"} {
		if problems := bind.Validate(merged, Layers, mod); len(problems) != 0 {
			t.Errorf("Binds+Kwi3OnlyBinds under %s: %d problem(s): %v", mod, len(problems), problems)
		}
	}
}

// TestKwi3OnlyBinds_TranslatesWithNoFtO10Gap is TestKwi3TranslateCoversRealTable's
// twin for the kwi3-only table: every bind.Command action in Kwi3OnlyBinds
// must translate through kwi3rpc with NO error (unlike sticky/scratchpad in
// the base table) -- a chord this daemon only ever grabs FOR kwi3 sessions
// had better have an ft010 method to call, or it would silently do nothing
// under the one transport it exists for.
func TestKwi3OnlyBinds_TranslatesWithNoFtO10Gap(t *testing.T) {
	got := walkForKwi3Translation(Kwi3OnlyBinds, map[string]bind.Layer{})
	if len(got) != 0 {
		t.Fatalf("Kwi3OnlyBinds has action(s) with no ft010 mapping: %v", got)
	}
}

// TestKwi3OnlyBinds_OwnershipFlipsWithSession is the ownership-invariant
// proof, spelled out with the SAME machinery ownership_test.go already
// trusts (daemonOwnedChords): under a plain i3 session's table (Binds
// alone), $mod+Shift+q is NOT daemon-owned, for either $mod resolution --
// i3's own native bindsym remains the sole owner, exactly as
// i3/config.common's "STILL i3's, on purpose" comment intends. Under a
// kwi3 session's table (effectiveBinds with a socket), it IS daemon-owned.
func TestKwi3OnlyBinds_OwnershipFlipsWithSession(t *testing.T) {
	key := func(mod string) bind.ChordKey {
		k, err := bind.NormalizeChord("$mod+Shift+q", mod)
		if err != nil {
			t.Fatalf("NormalizeChord($mod+Shift+q, %s) failed: %s", mod, err)
		}
		return k
	}
	for _, mod := range []string{"Mod4", "Mod1"} {
		plainOwned := daemonOwnedChords(effectiveBinds(""), mod)
		if plainOwned[key(mod)] {
			t.Errorf("under %s, a plain i3 session's daemon-owned set includes $mod+Shift+q -- "+
				"this must stay i3's alone (config.common) or check --ownership would report BOTH", mod)
		}

		kwi3Owned := daemonOwnedChords(effectiveBinds("/some/sock"), mod)
		if !kwi3Owned[key(mod)] {
			t.Errorf("under %s, a kwi3 session's daemon-owned set is missing $mod+Shift+q -- "+
				"the kwi3-55l.1 fix regressed", mod)
		}
	}
}

// TestKwi3OnlyBinds_Chords is a small named-table guard: exactly one chord
// today, $mod+Shift+q -> kill. A future addition to Kwi3OnlyBinds should
// make this test fail by name (forcing a deliberate update) rather than
// silently pass a bigger table.
func TestKwi3OnlyBinds_Chords(t *testing.T) {
	got := make([]string, 0, len(Kwi3OnlyBinds))
	for _, b := range Kwi3OnlyBinds {
		got = append(got, b.Chord)
	}
	sort.Strings(got)
	want := []string{"$mod+Shift+q"}
	if len(got) != len(want) {
		t.Fatalf("Kwi3OnlyBinds chords = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Kwi3OnlyBinds chords = %v, want %v", got, want)
		}
	}
}
