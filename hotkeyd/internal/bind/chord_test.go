package bind

import "testing"

func TestParseChord_ResolvesModTokenPerDisplay(t *testing.T) {
	mods, key, err := ParseChord("$mod+Shift+q", "Mod4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "q" || !mods[Mod4] || !mods[Shift] || len(mods) != 2 {
		t.Fatalf("got mods=%v key=%q, want {Mod4,Shift} q", mods, key)
	}

	mods, key, err = ParseChord("$mod+Shift+q", "Mod1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "q" || !mods[Mod1] || !mods[Shift] || len(mods) != 2 {
		t.Fatalf("got mods=%v key=%q, want {Mod1,Shift} q", mods, key)
	}
}

func TestParseChord_SingleDigitIsKeysym(t *testing.T) {
	mods, key, err := ParseChord("$mod+1", "Mod4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "1" || !mods[Mod4] {
		t.Fatalf("got mods=%v key=%q, want {Mod4} 1", mods, key)
	}
}

func TestParseChord_BareKeysymNoModifiers(t *testing.T) {
	mods, key, err := ParseChord("h", "Mod4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "h" || len(mods) != 0 {
		t.Fatalf("got mods=%v key=%q, want {} h", mods, key)
	}
}

func TestNormalizeChord_OrderInsensitive(t *testing.T) {
	a, err := NormalizeChord("Shift+Ctrl+q", "Mod4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	b, err := NormalizeChord("Ctrl+Shift+q", "Mod4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if a != b {
		t.Fatalf("Shift+Ctrl+q and Ctrl+Shift+q normalized differently: %v vs %v", a, b)
	}
}

func TestNormalizeChord_AliasFolding(t *testing.T) {
	a, err := NormalizeChord("Super+d", "Mod4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	b, err := NormalizeChord("Mod4+d", "Mod4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if a != b {
		t.Fatalf("Super+d and Mod4+d normalized differently: %v vs %v", a, b)
	}
}

func TestCanonModifier_ResolvesModToken(t *testing.T) {
	canon, ok := CanonModifier("$mod", "Mod1")
	if !ok || canon != Mod1 {
		t.Fatalf("got (%v,%v), want (Mod1,true)", canon, ok)
	}
}

func TestCanonModifier_BareModTokenNeverInAliasesDirectly(t *testing.T) {
	// A bare "$mod" string looked up WITHOUT going through CanonModifier's
	// substitution must not silently resolve via modifierAliases — that
	// would be a feature that works on neither display rather than one
	// that works on the wrong one (see the doc comment on CanonModifier).
	if _, ok := modifierAliases["$mod"]; ok {
		t.Fatalf("modifierAliases must not contain the literal $mod token")
	}
}

func TestCanonModifier_UnknownReturnsFalse(t *testing.T) {
	if _, ok := CanonModifier("bogus", "Mod4"); ok {
		t.Fatalf("expected ok=false for an unknown modifier name")
	}
}

func TestReservedChords_HoldsBothModResolutions(t *testing.T) {
	native, err := NormalizeChord(PanicChord, "Mod4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	xrdp, err := NormalizeChord(PanicChord, "Mod1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !ReservedChords[native] {
		t.Fatalf("ReservedChords missing the native (Mod4) panic chord form")
	}
	if !ReservedChords[xrdp] {
		t.Fatalf("ReservedChords missing the xrdp (Mod1) panic chord form")
	}
	if len(ReservedChords) != 2 {
		t.Fatalf("got %d reserved forms, want exactly 2 (one per ModResolutions entry)", len(ReservedChords))
	}
}
