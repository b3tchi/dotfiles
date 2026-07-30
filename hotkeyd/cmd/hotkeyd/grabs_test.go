package main

import (
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/x11"
)

// ---------------------------------------------------------------------
// Stage 1: keysym table + mask-from-modifiers + resolveChord (pure,
// no X round trip).
// ---------------------------------------------------------------------

func TestKeysymByName_CoversEveryNameConfigsRealTableUses(t *testing.T) {
	// config.go's Binds (sp021 Task 6 / bd dotfiles-ylmp.5) is the real
	// 70-bind table this daemon ships. Every chord's keysym must resolve
	// in keysymByName, or the grab table silently loses a key the moment
	// someone adds a chord this table doesn't know about.
	for _, b := range Binds {
		for _, mod := range bind.ModResolutions {
			_, key, err := bind.ParseChord(b.Chord, mod)
			if err != nil {
				t.Fatalf("chord %q under mod=%s: %s", b.Chord, mod, err)
			}
			if _, ok := keysymByName[key]; !ok {
				t.Errorf("chord %q: keysym %q has no entry in keysymByName", b.Chord, key)
			}
		}
	}
}

func TestMaskFromMods_CombinesEveryModifierBit(t *testing.T) {
	mods := map[bind.Modifier]bool{bind.Shift: true, bind.Ctrl: true, bind.Mod4: true}
	mask := maskFromMods(mods)
	want := maskShift | maskCtrl | maskMod4
	if mask != want {
		t.Fatalf("maskFromMods = %#x, want %#x", mask, want)
	}
}

func TestResolveChord_KeysymFirst_FindsKeycodeRegardlessOfPosition(t *testing.T) {
	// "keysym-first" resolution: search the CURRENT keymap for the
	// keysym rather than trusting a cached keycode.
	mapping := x11.KeyboardMapping{
		KeysymsPerKeycode: 1,
		FirstKeycode:      8,
		Keysyms:           []uint32{keysymByName["a"], keysymByName["h"], keysymByName["Return"]},
	}
	gc, err := resolveChord("h", "Mod4", mapping)
	if err != nil {
		t.Fatalf("resolveChord: %s", err)
	}
	if gc.Code != 9 || gc.Mask != 0 {
		t.Fatalf("resolveChord(h) = %+v, want code=9 mask=0", gc)
	}
}

func TestResolveChord_ModifiedChord_ComputesMask(t *testing.T) {
	mapping := x11.KeyboardMapping{
		KeysymsPerKeycode: 1,
		FirstKeycode:      8,
		Keysyms:           []uint32{keysymByName["r"]},
	}
	gc, err := resolveChord("$mod+Ctrl+Shift+r", "Mod4", mapping)
	if err != nil {
		t.Fatalf("resolveChord: %s", err)
	}
	want := maskShift | maskCtrl | maskMod4
	if gc.Code != 8 || gc.Mask != want {
		t.Fatalf("resolveChord($mod+Ctrl+Shift+r) = %+v, want code=8 mask=%#x", gc, want)
	}
}

func TestResolveChord_KeysymAbsentFromKeymap_ReportsNotOnKeymap(t *testing.T) {
	mapping := x11.KeyboardMapping{
		KeysymsPerKeycode: 1,
		FirstKeycode:      8,
		Keysyms:           []uint32{keysymByName["a"]},
	}
	_, err := resolveChord("h", "Mod4", mapping)
	if err == nil {
		t.Fatal("resolveChord(h): want error, got nil")
	}
}

func TestResolveChord_UnknownModifier_ReportsBindError(t *testing.T) {
	mapping := x11.KeyboardMapping{
		KeysymsPerKeycode: 1,
		FirstKeycode:      8,
		Keysyms:           []uint32{keysymByName["h"]},
	}
	_, err := resolveChord("Bogus+h", "Mod4", mapping)
	if err == nil {
		t.Fatal("resolveChord(Bogus+h): want error, got nil")
	}
}

// ---------------------------------------------------------------------
// fakeX — a grabX double driving the unit tests with zero X, per the
// task's test_plan.
// ---------------------------------------------------------------------

type grabCallRecord struct {
	keycode   uint32
	modifiers []uint32
	mask      []uint32
}

type ungrabCallRecord struct {
	keycode   uint32
	modifiers []uint32
}

type fakeX struct {
	mapping    x11.KeyboardMapping
	mappingErr error

	// keyed by keycode: what XIPassiveGrabDevice should answer for a grab
	// on that keycode. Absent entries default to a clean, fully-successful
	// GrabResult (empty Failed).
	grabResults map[uint32]x11.GrabResult
	grabErrs    map[uint32]error

	mappingCalls []struct{ first, count byte }
	grabCalls    []grabCallRecord
	ungrabCalls  []ungrabCallRecord
}

func newFakeX(mapping x11.KeyboardMapping) *fakeX {
	return &fakeX{
		mapping:     mapping,
		grabResults: map[uint32]x11.GrabResult{},
		grabErrs:    map[uint32]error{},
	}
}

func (f *fakeX) GetKeyboardMapping(firstKeycode, count byte) (x11.KeyboardMapping, error) {
	f.mappingCalls = append(f.mappingCalls, struct{ first, count byte }{firstKeycode, count})
	if f.mappingErr != nil {
		return x11.KeyboardMapping{}, f.mappingErr
	}
	return f.mapping, nil
}

func (f *fakeX) XIPassiveGrabDevice(majorOpcode byte, grabWindow uint32, deviceid uint16, keycode uint32, modifiers, mask []uint32) (x11.GrabResult, error) {
	f.grabCalls = append(f.grabCalls, grabCallRecord{
		keycode:   keycode,
		modifiers: append([]uint32(nil), modifiers...),
		mask:      append([]uint32(nil), mask...),
	})
	if err, ok := f.grabErrs[keycode]; ok {
		return x11.GrabResult{}, err
	}
	if res, ok := f.grabResults[keycode]; ok {
		return res, nil
	}
	return x11.GrabResult{}, nil
}

func (f *fakeX) XIPassiveUngrabDevice(majorOpcode byte, grabWindow uint32, deviceid uint16, keycode uint32, modifiers []uint32) error {
	f.ungrabCalls = append(f.ungrabCalls, ungrabCallRecord{
		keycode:   keycode,
		modifiers: append([]uint32(nil), modifiers...),
	})
	return nil
}

// mapping builds a single-level (KeysymsPerKeycode=1) keyboard mapping from
// keysym names, assigning sequential keycodes starting at 8. Built off the
// SAME keysymByName table the production code uses, so an unknown name
// fails loudly here rather than silently mis-testing.
func testMapping(names ...string) x11.KeyboardMapping {
	const first = 8
	syms := make([]uint32, len(names))
	for i, n := range names {
		ks, ok := keysymByName[n]
		if !ok {
			panic("testMapping: unknown keysym name " + n)
		}
		syms[i] = ks
	}
	return x11.KeyboardMapping{KeysymsPerKeycode: 1, FirstKeycode: first, Keysyms: syms}
}

func newTestGrabManager(x grabX, mod string) *GrabManager {
	return NewGrabManager(x, 131, 1 /* grabWindow */, x11.DeviceAllMaster, 8, 255, mod, func(string) {})
}

func TestSyncBinds_GrabsWantedChords(t *testing.T) {
	fx := newFakeX(testMapping("h", "q"))
	g := newTestGrabManager(fx, "Mod4")

	g.SyncBinds([]string{"h", "$mod+q"})

	if len(fx.grabCalls) != 2 {
		t.Fatalf("grab calls = %d, want 2 (calls: %+v)", len(fx.grabCalls), fx.grabCalls)
	}
	active := g.Active()
	if len(active) != 2 {
		t.Fatalf("active = %d chords, want 2 (%+v)", len(active), active)
	}
	if gc, ok := active["h"]; !ok || gc.Code != 8 || gc.Mask != 0 {
		t.Errorf(`active["h"] = %+v, ok=%v, want code=8 mask=0`, gc, ok)
	}
	if gc, ok := active["$mod+q"]; !ok || gc.Code != 9 || gc.Mask != maskMod4 {
		t.Errorf(`active["$mod+q"] = %+v, ok=%v, want code=9 mask=%#x`, gc, ok, maskMod4)
	}
}

func TestSyncBinds_GrabRegistersAllFourLockVariantsInOneCall(t *testing.T) {
	fx := newFakeX(testMapping("q"))
	g := newTestGrabManager(fx, "Mod4")

	g.SyncBinds([]string{"$mod+q"})

	if len(fx.grabCalls) != 1 {
		t.Fatalf("grab calls = %d, want 1", len(fx.grabCalls))
	}
	got := fx.grabCalls[0].modifiers
	want := x11.GrabModifierVariants(maskMod4)
	if len(got) != len(want) {
		t.Fatalf("modifiers = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("modifiers[%d] = %#x, want %#x", i, got[i], want[i])
		}
	}
}

func TestSyncBinds_ChordRemovedFromWantedIsUngrabbed(t *testing.T) {
	fx := newFakeX(testMapping("h"))
	g := newTestGrabManager(fx, "Mod4")

	g.SyncBinds([]string{"h"})
	g.SyncBinds([]string{})

	if len(fx.ungrabCalls) != 1 {
		t.Fatalf("ungrab calls = %d, want 1 (calls: %+v)", len(fx.ungrabCalls), fx.ungrabCalls)
	}
	if fx.ungrabCalls[0].keycode != 8 {
		t.Errorf("ungrab keycode = %d, want 8", fx.ungrabCalls[0].keycode)
	}
	if _, ok := g.Active()["h"]; ok {
		t.Error(`Active()["h"] still present after removing it from wanted`)
	}
}

func TestSyncBinds_UnchangedChordIsNeverRegrabbed(t *testing.T) {
	fx := newFakeX(testMapping("h", "q"))
	g := newTestGrabManager(fx, "Mod4")

	g.SyncBinds([]string{"h", "$mod+q"})
	fx.grabCalls = nil
	fx.ungrabCalls = nil

	g.SyncBinds([]string{"h", "$mod+q"}) // same set again

	if len(fx.grabCalls) != 0 || len(fx.ungrabCalls) != 0 {
		t.Fatalf("resyncing the same wanted set touched X: grabs=%d ungrabs=%d, want 0/0",
			len(fx.grabCalls), len(fx.ungrabCalls))
	}
}

// ---------------------------------------------------------------------
// dotfiles-hwds.41 regression + MappingNotify diff scenarios.
// ---------------------------------------------------------------------

// TestHWDS41Regression_LostChordRecoversAfterKeymapSettles is the named
// regression test for dotfiles-hwds.41: GrabManager.on_mapping_notify used
// to walk self._active (what is STILL grabbed) instead of the wanted set,
// which made the grab set MONOTONIC -- a chord whose keysym transiently
// resolved to nothing (routine on :10, where xrdp reprograms the keymap on
// every RDP reconnect) was deleted from the set that would ever be asked
// for again, and never came back for the life of the process.
//
// This reproduces that transient exactly: "h" is grabbed, then a
// MappingNotify arrives while "h" is momentarily absent from the keymap
// (mid-remap), then a second MappingNotify arrives once the keymap has
// settled and "h" is back. A GrabManager driving the next set from ACTIVE
// would never re-attempt "h" here, because ACTIVE no longer mentions it
// after the first notify.
func TestHWDS41Regression_LostChordRecoversAfterKeymapSettles(t *testing.T) {
	fx := newFakeX(testMapping("h", "q"))
	g := newTestGrabManager(fx, "Mod4")

	g.SyncBinds([]string{"h", "$mod+q"})
	if _, ok := g.Active()["h"]; !ok {
		t.Fatal(`setup: Active()["h"] absent after initial SyncBinds`)
	}

	// Transient: the keymap momentarily no longer has "h" on it (xrdp
	// reprogramming mid-reconnect). "q" is unaffected -- unrelated chords
	// must not be disturbed by one chord's transient loss.
	fx.mapping = testMapping("q")
	g.OnMappingNotify()

	if _, ok := g.Active()["h"]; ok {
		t.Fatal(`Active()["h"] still present while "h" is off the keymap`)
	}
	if _, ok := g.Active()["$mod+q"]; !ok {
		t.Fatal(`Active()["$mod+q"] lost during an unrelated chord's transient keymap loss`)
	}
	if !wantedContains(g, "h") {
		t.Fatal(`"h" was removed from the WANTED set -- it must stay parked there so it can recover`)
	}

	// The keymap settles: "h" is back.
	fx.mapping = testMapping("h", "q")
	g.OnMappingNotify()

	if _, ok := g.Active()["h"]; !ok {
		t.Fatal(`Active()["h"] did not recover once the keymap settled -- this is the hwds.41 regression`)
	}
}

func wantedContains(g *GrabManager, chord string) bool {
	for _, c := range g.Wanted() {
		if c == chord {
			return true
		}
	}
	return false
}

func TestOnMappingNotify_NoOpRemap_TouchesNothing(t *testing.T) {
	// A chord's resolved (code, mask) is unchanged across the notify (even
	// though the keyboard mapping object itself is a fresh fetch) -- no
	// grab or ungrab call should fire for it.
	fx := newFakeX(testMapping("h", "q"))
	g := newTestGrabManager(fx, "Mod4")
	g.SyncBinds([]string{"h", "$mod+q"})
	fx.grabCalls = nil
	fx.ungrabCalls = nil

	fx.mapping = testMapping("h", "q") // same names, same resulting codes
	changed := g.OnMappingNotify()

	if changed {
		t.Error("OnMappingNotify reported changed=true for a no-op remap")
	}
	if len(fx.grabCalls) != 0 || len(fx.ungrabCalls) != 0 {
		t.Fatalf("no-op remap touched X: grabs=%d ungrabs=%d, want 0/0", len(fx.grabCalls), len(fx.ungrabCalls))
	}
}

func TestOnMappingNotify_ChordRemapped_OnlyThatPairIsTouched(t *testing.T) {
	// xmodmap-style remap: "h"'s keysym moves to a different physical key,
	// while "q" stays exactly where it was. Only h's (code, mask) pair may
	// be touched -- q's grab must not be disturbed just because a
	// MappingNotify fired somewhere else in the keymap.
	fx := newFakeX(testMapping("h", "q")) // h=8, q=9
	g := newTestGrabManager(fx, "Mod4")
	g.SyncBinds([]string{"h", "$mod+q"})
	fx.grabCalls = nil
	fx.ungrabCalls = nil

	// h moves to code 10; q's row (code 9) is untouched.
	fx.mapping = x11.KeyboardMapping{
		KeysymsPerKeycode: 1,
		FirstKeycode:      8,
		Keysyms:           []uint32{keysymByName["x"], keysymByName["q"], keysymByName["h"]},
	}
	g.OnMappingNotify()

	if len(fx.ungrabCalls) != 1 || fx.ungrabCalls[0].keycode != 8 {
		t.Fatalf("ungrabCalls = %+v, want exactly one ungrab of the OLD h keycode (8)", fx.ungrabCalls)
	}
	if len(fx.grabCalls) != 1 || fx.grabCalls[0].keycode != 10 {
		t.Fatalf("grabCalls = %+v, want exactly one grab of the NEW h keycode (10)", fx.grabCalls)
	}
	if gc, ok := g.Active()["$mod+q"]; !ok || gc.Code != 9 {
		t.Fatalf(`Active()["$mod+q"] = %+v, ok=%v -- q's unchanged grab must survive untouched`, gc, ok)
	}
}

func TestOnMappingNotify_ChordHiddenChordStaysInWantedNotJustActive(t *testing.T) {
	// Edge case from the task design: "A chord whose keysym is absent from
	// the current keymap: parked in wanted, grabbed automatically after a
	// MappingNotify restores it." -- verifies the parking explicitly,
	// distinct from the full hwds.41 recovery test above.
	fx := newFakeX(testMapping("h"))
	g := newTestGrabManager(fx, "Mod4")
	g.SyncBinds([]string{"h"})

	fx.mapping = testMapping() // h vanishes
	g.OnMappingNotify()

	if !wantedContains(g, "h") {
		t.Fatal(`"h" must stay in Wanted() even while unresolvable`)
	}
	if _, ok := g.Active()["h"]; ok {
		t.Fatal(`Active()["h"] should be gone while unresolvable`)
	}
}

// ---------------------------------------------------------------------
// Per-modifier partial grab failure, BadAccess, duplicate-grab dedup.
// ---------------------------------------------------------------------

func TestGrab_PartialModifierFailure_ChordStaysMissingNotHalfActive(t *testing.T) {
	fx := newFakeX(testMapping("h"))
	g := newTestGrabManager(fx, "Mod4")

	// keycode 8 ("h"): the base variant succeeds but the Lock variant is
	// refused by a competing grabber -- a partially-failed chord.
	fx.grabResults[8] = x11.GrabResult{Failed: []x11.GrabModifierResult{
		{Modifiers: x11.ModMaskLock, Status: 1},
	}}

	g.SyncBinds([]string{"h"})

	if _, ok := g.Active()["h"]; ok {
		t.Fatal(`Active()["h"] present despite a partial modifier-variant failure -- must not be half-active`)
	}
	wanted, active, missing := g.GrabReport()
	if wanted != 1 || active != 0 || len(missing) != 1 || missing[0] != "h" {
		t.Fatalf("GrabReport() = wanted=%d active=%d missing=%v, want wanted=1 active=0 missing=[h]",
			wanted, active, missing)
	}
}

func TestGrab_BadAccessFromCompetingGrabber_NamedNotSilent(t *testing.T) {
	fx := newFakeX(testMapping("h"))
	var logged []string
	g := NewGrabManager(fx, 131, 1, x11.DeviceAllMaster, 8, 255, "Mod4", func(msg string) {
		logged = append(logged, msg)
	})

	fx.grabErrs[8] = x11.XError{Code: 10, Seq: 1, MajorOpcode: 131, MinorOpcode: 54} // BadAccess

	g.SyncBinds([]string{"h"})

	if _, ok := g.Active()["h"]; ok {
		t.Fatal(`Active()["h"] present despite a BadAccess error`)
	}
	found := false
	for _, msg := range logged {
		if strings.Contains(msg, "BadAccess") {
			found = true
		}
	}
	if !found {
		t.Fatalf("problems logged = %v, want one containing %q", logged, "BadAccess")
	}
}

func TestSyncBinds_TwoChordsSameKeycodeAndMask_OnlyFirstWantedGrabs(t *testing.T) {
	// Tab and ISO_Left_Tab are the shipped instance: the same physical key
	// at two shift levels, so bare forms of both resolve to (code, mask=0).
	// Asking X for the same passive grab twice is a BadAccess against
	// ourselves -- first wanted chord wins, the second is silently the same
	// grab under another name, not a problem.
	mapping := x11.KeyboardMapping{
		KeysymsPerKeycode: 2,
		FirstKeycode:      8,
		Keysyms:           []uint32{keysymByName["Tab"], keysymByName["ISO_Left_Tab"]},
	}
	fx := newFakeX(mapping)
	g := newTestGrabManager(fx, "Mod4")

	g.SyncBinds([]string{"Tab", "ISO_Left_Tab"})

	if len(fx.grabCalls) != 1 {
		t.Fatalf("grab calls = %d, want 1 (calls: %+v)", len(fx.grabCalls), fx.grabCalls)
	}
	if _, ok := g.Active()["Tab"]; !ok {
		t.Error(`Active()["Tab"] missing -- first-wanted chord should win the grab`)
	}
	if _, ok := g.Active()["ISO_Left_Tab"]; ok {
		t.Error(`Active()["ISO_Left_Tab"] present -- the losing duplicate must not get its own entry`)
	}
	wanted, active, missing := g.GrabReport()
	if wanted != 1 || active != 1 || len(missing) != 0 {
		t.Fatalf("GrabReport() = wanted=%d active=%d missing=%v, want wanted=1 active=1 missing=[]",
			wanted, active, missing)
	}
}

// ---------------------------------------------------------------------
// GetKeyboardMapping failure resilience, GrabReport healthy path, keycode
// range wiring.
// ---------------------------------------------------------------------

func TestApply_KeyboardMappingError_LeavesPriorActiveUntouched(t *testing.T) {
	fx := newFakeX(testMapping("h"))
	g := newTestGrabManager(fx, "Mod4")
	g.SyncBinds([]string{"h"})
	fx.grabCalls = nil
	fx.ungrabCalls = nil

	fx.mappingErr = errFakeMappingFetch
	changed := g.OnMappingNotify()

	if changed {
		t.Error("OnMappingNotify reported changed=true on a GetKeyboardMapping error")
	}
	if len(fx.grabCalls) != 0 || len(fx.ungrabCalls) != 0 {
		t.Fatalf("a mapping-fetch error touched X: grabs=%d ungrabs=%d, want 0/0", len(fx.grabCalls), len(fx.ungrabCalls))
	}
	if _, ok := g.Active()["h"]; !ok {
		t.Fatal(`Active()["h"] lost after a transient GetKeyboardMapping error -- must keep prior grabs`)
	}
}

func TestGrabReport_AllChordsGrabbed_ReportsCleanly(t *testing.T) {
	fx := newFakeX(testMapping("h", "q"))
	g := newTestGrabManager(fx, "Mod4")
	g.SyncBinds([]string{"h", "$mod+q"})

	wanted, active, missing := g.GrabReport()
	if wanted != 2 || active != 2 || len(missing) != 0 {
		t.Fatalf("GrabReport() = wanted=%d active=%d missing=%v, want wanted=2 active=2 missing=[]",
			wanted, active, missing)
	}
}

func TestNewGrabManager_QueriesFullKeycodeRange(t *testing.T) {
	fx := newFakeX(testMapping("h"))
	g := NewGrabManager(fx, 131, 1, x11.DeviceAllMaster, 8, 255, "Mod4", func(string) {})

	g.SyncBinds([]string{"h"})

	if len(fx.mappingCalls) != 1 {
		t.Fatalf("mapping calls = %d, want 1", len(fx.mappingCalls))
	}
	if fx.mappingCalls[0].first != 8 || fx.mappingCalls[0].count != 248 {
		t.Fatalf("GetKeyboardMapping(first=%d, count=%d), want first=8 count=248",
			fx.mappingCalls[0].first, fx.mappingCalls[0].count)
	}
}

type fakeMappingErr struct{}

func (fakeMappingErr) Error() string { return "fake: GetKeyboardMapping unavailable" }

var errFakeMappingFetch error = fakeMappingErr{}

// ---------------------------------------------------------------------
// $mod resolution (ResolveMod) -- poc015's measured RESOURCE_MANAGER
// shape: "i3wm.mod:" present with a value on :10, ABSENT ENTIRELY on :0.
// ---------------------------------------------------------------------

func fakePropertyFetcher(value string, err error) modPropertyFetcher {
	return func(window, property, propertyType uint32) (byte, uint32, []byte, error) {
		if err != nil {
			return 0, 0, nil, err
		}
		return 8, x11.AnyPropertyType, []byte(value), nil
	}
}

func TestResolveMod_ParsesI3wmModLine(t *testing.T) {
	fetch := fakePropertyFetcher("Xft.dpi:\t96\ni3wm.mod:\tMod1\nXcursor.size:\t24\n", nil)
	if got := ResolveMod(fetch, 1); got != "Mod1" {
		t.Fatalf("ResolveMod = %q, want %q", got, "Mod1")
	}
}

func TestResolveMod_DefaultOnAbsence(t *testing.T) {
	// poc015 measured: ":0" has NO i3wm.mod line in RESOURCE_MANAGER AT
	// ALL. The fallback replicates i3's set_from_resource default, not a
	// value read off the server.
	fetch := fakePropertyFetcher("Xft.dpi:\t96\nXcursor.size:\t24\n", nil)
	if got := ResolveMod(fetch, 1); got != bind.DefaultMod {
		t.Fatalf("ResolveMod = %q, want bind.DefaultMod %q", got, bind.DefaultMod)
	}
}

func TestResolveMod_DefaultOnFetchError(t *testing.T) {
	fetch := fakePropertyFetcher("", errFakeMappingFetch)
	if got := ResolveMod(fetch, 1); got != bind.DefaultMod {
		t.Fatalf("ResolveMod = %q, want bind.DefaultMod %q", got, bind.DefaultMod)
	}
}

func TestResolveMod_EmptyValueLineFallsThroughToDefault(t *testing.T) {
	fetch := fakePropertyFetcher("i3wm.mod:\t\n", nil)
	if got := ResolveMod(fetch, 1); got != bind.DefaultMod {
		t.Fatalf("ResolveMod = %q, want bind.DefaultMod %q (empty value must not count as present)", got, bind.DefaultMod)
	}
}

func TestResolveMod_TrimsTabSeparator(t *testing.T) {
	// poc015's exact measured line shape: "i3wm.mod:\tMod1".
	fetch := fakePropertyFetcher("i3wm.mod:\tMod1", nil)
	if got := ResolveMod(fetch, 1); got != "Mod1" {
		t.Fatalf("ResolveMod = %q, want %q", got, "Mod1")
	}
}

func TestResolveMod_UsesAnyPropertyType(t *testing.T) {
	var gotWindow, gotProperty, gotType uint32
	fetch := func(window, property, propertyType uint32) (byte, uint32, []byte, error) {
		gotWindow, gotProperty, gotType = window, property, propertyType
		return 8, x11.AnyPropertyType, []byte("i3wm.mod:\tMod1\n"), nil
	}
	ResolveMod(fetch, 42)

	if gotWindow != 42 {
		t.Errorf("window = %d, want 42 (the root window passed in)", gotWindow)
	}
	if gotProperty != resourceManagerAtom {
		t.Errorf("property = %d, want resourceManagerAtom (%d)", gotProperty, resourceManagerAtom)
	}
	if gotType != x11.AnyPropertyType {
		t.Errorf("propertyType = %d, want x11.AnyPropertyType", gotType)
	}
}

// ---------------------------------------------------------------------
// Integration (Xvfb): real grab/regrab under an xmodmap remap, and $mod
// resolution against a display with and without the i3wm.mod resource
// line. Skips cleanly when Xvfb/xmodmap/xrdb/xdotool are absent. Uses an
// unusual display-number range (6000-7999) since sibling tasks in this
// epic also spin up Xvfb.
// ---------------------------------------------------------------------

func requireBinaryForIntegration(t *testing.T, name string) {
	t.Helper()
	if _, err := exec.LookPath(name); err != nil {
		t.Skipf("%s not available on PATH: %v", name, err)
	}
}

func pickFreeIntegrationDisplay(t *testing.T) int {
	t.Helper()
	for attempt := 0; attempt < 50; attempt++ {
		n := 6000 + rand.IntN(2000)
		if _, err := os.Stat(fmt.Sprintf("/tmp/.X11-unix/X%d", n)); err != nil {
			return n
		}
	}
	t.Fatal("could not find a free display number")
	return 0
}

func startIntegrationXvfb(t *testing.T, dispNum int) {
	t.Helper()
	requireBinaryForIntegration(t, "Xvfb")

	sockPath := fmt.Sprintf("/tmp/.X11-unix/X%d", dispNum)
	cmd := exec.Command("Xvfb", fmt.Sprintf(":%d", dispNum), "-nolisten", "tcp", "-screen", "0", "320x240x24")
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting Xvfb: %v", err)
	}
	t.Cleanup(func() {
		cmd.Process.Kill()
		cmd.Wait()
		os.Remove(sockPath)
	})

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(sockPath); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("Xvfb did not create its socket in time: %s", stderr.String())
}

// TestIntegration_GrabManager_RealGrabAndXmodmapRegrab_Xvfb drives a
// GrabManager against a REAL X connection: grab "a", inject a real keypress
// via xdotool and see it delivered, remap 'a' onto a different physical key
// with xmodmap, drive the resulting core MappingNotify through
// OnMappingNotify, and prove the daemon now delivers on the NEW key and no
// longer on the old one.
func TestIntegration_GrabManager_RealGrabAndXmodmapRegrab_Xvfb(t *testing.T) {
	requireBinaryForIntegration(t, "Xvfb")
	requireBinaryForIntegration(t, "xmodmap")
	requireBinaryForIntegration(t, "xdotool")

	dispNum := pickFreeIntegrationDisplay(t)
	startIntegrationXvfb(t, dispNum)
	display := fmt.Sprintf(":%d", dispNum)

	conn, info, err := x11.Open(display)
	if err != nil {
		t.Fatalf("Open(%s): %v", display, err)
	}
	defer conn.Close()

	ext, err := conn.QueryExtension("XInputExtension")
	if err != nil || !ext.Present {
		t.Fatalf("QueryExtension(XInputExtension): present=%v err=%v", ext.Present, err)
	}
	if _, err := conn.XIQueryVersion(ext.MajorOpcode, 2, 3); err != nil {
		t.Fatalf("XIQueryVersion: %v", err)
	}
	root := info.Screens[0].Root

	g := NewGrabManager(conn, ext.MajorOpcode, root, x11.DeviceAllMaster, info.MinKeycode, info.MaxKeycode, "Mod4", func(msg string) { t.Log("grab problem:", msg) })

	g.SyncBinds([]string{"a"})
	gc, ok := g.Active()["a"]
	if !ok {
		t.Fatal(`Active()["a"] absent after SyncBinds against a real Xvfb`)
	}
	origCode := gc.Code
	t.Logf("chord 'a' grabbed at keycode %d mask %#x", gc.Code, gc.Mask)

	// A real keypress on the grabbed key must be delivered.
	if !waitForKeyDelivery(t, conn, display, "a", origCode, 2*time.Second) {
		t.Fatal("injected 'a' keypress was not delivered on the freshly-grabbed keycode")
	}

	// Pick an unused keycode to swap 'a' onto, and remap the original away
	// from 'a' entirely -- a real xmodmap-driven remap, not a simulated one.
	newCode := origCode + 1
	if newCode > uint32(info.MaxKeycode) {
		newCode = origCode - 1
	}
	runXmodmap(t, display, fmt.Sprintf("keycode %d = b", origCode))
	runXmodmap(t, display, fmt.Sprintf("keycode %d = a", newCode))

	if !waitForMappingNotify(t, conn, 3*time.Second) {
		t.Fatal("no MappingNotify observed after xmodmap remap")
	}
	g.OnMappingNotify()

	gc2, ok := g.Active()["a"]
	if !ok {
		t.Fatal(`Active()["a"] absent after the xmodmap regrab`)
	}
	if gc2.Code != newCode {
		t.Fatalf("Active()[\"a\"].Code = %d after remap, want the new keycode %d", gc2.Code, newCode)
	}
	if gc2.Code == origCode {
		t.Fatal("chord still grabbed at the OLD keycode after 'a' moved away from it")
	}
	t.Logf("chord 'a' regrabbed at keycode %d after xmodmap remap (was %d)", gc2.Code, origCode)

	// Delivery now happens on the NEW keycode.
	if !waitForKeyDelivery(t, conn, display, "a", newCode, 2*time.Second) {
		t.Fatal("injected 'a' keypress was not delivered on the NEW keycode after regrab")
	}
}

func runXmodmap(t *testing.T, display, expr string) {
	t.Helper()
	cmd := exec.Command("xmodmap", "-display", display, "-e", expr)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("xmodmap -e %q: %v: %s", expr, err, out)
	}
}

// waitForMappingNotify drains conn.Events until a core MappingNotify frame
// (event code 34) is seen or timeout elapses.
func waitForMappingNotify(t *testing.T, conn *x11.Conn, timeout time.Duration) bool {
	t.Helper()
	const mappingNotifyCode = 34
	deadline := time.After(timeout)
	for {
		select {
		case ev := <-conn.Events:
			if ev.Code == mappingNotifyCode {
				return true
			}
		case <-deadline:
			return false
		}
	}
}

// waitForKeyDelivery injects keysymName via xdotool and waits for a
// matching XI2 DeviceEvent (press, Detail==wantKeycode) on conn.Events.
func waitForKeyDelivery(t *testing.T, conn *x11.Conn, display, keysymName string, wantKeycode uint32, timeout time.Duration) bool {
	t.Helper()
	deadline := time.After(timeout)
	injected := false
	for {
		if !injected {
			cmd := exec.Command("xdotool", "key", "--clearmodifiers", keysymName)
			cmd.Env = append(cmd.Environ(), "DISPLAY="+display)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("xdotool key %s: %v: %s", keysymName, err, out)
			}
			injected = true
		}
		select {
		case ev := <-conn.Events:
			if ev.Code != genericEventCodeForTest {
				continue
			}
			dev, err := x11.ParseDeviceEvent(ev.Raw)
			if err != nil {
				continue
			}
			if dev.EventType == 2 && dev.Detail == wantKeycode { // XI_KeyPress
				return true
			}
		case <-deadline:
			return false
		}
	}
}

// genericEventCodeForTest mirrors internal/x11's unexported genericEventCode
// (35, the GenericEvent core event code XI2 device events ride on).
const genericEventCodeForTest = 35

// TestIntegration_ResolveMod_Xvfb_WithoutResourceLine drives ResolveMod
// against a bare Xvfb, which has no RESOURCE_MANAGER property set at all
// (no xrdb has ever run) -- the poc015-measured ":0 has no i3wm.mod line"
// case, at the "property does not exist" extreme.
func TestIntegration_ResolveMod_Xvfb_WithoutResourceLine(t *testing.T) {
	requireBinaryForIntegration(t, "Xvfb")

	dispNum := pickFreeIntegrationDisplay(t)
	startIntegrationXvfb(t, dispNum)
	display := fmt.Sprintf(":%d", dispNum)

	conn, info, err := x11.Open(display)
	if err != nil {
		t.Fatalf("Open(%s): %v", display, err)
	}
	defer conn.Close()
	root := info.Screens[0].Root

	got := ResolveMod(conn.GetPropertyAll, root)
	if got != bind.DefaultMod {
		t.Fatalf("ResolveMod on a bare Xvfb = %q, want bind.DefaultMod %q", got, bind.DefaultMod)
	}
}

// TestIntegration_ResolveMod_Xvfb_WithResourceLine loads a real
// RESOURCE_MANAGER property onto a live Xvfb and confirms ResolveMod reads
// the i3wm.mod line back off the server.
//
// Seeded via a short python3-Xlib ChangeProperty script rather than `xrdb`:
// this sandbox's `xrdb`/`xprop -set` exit 0 without actually setting the
// property on Xvfb (verified independently -- readback via `xprop -root`
// shows RESOURCE_MANAGER absent no matter how it's invoked), while
// python3-Xlib's change_property/get_full_property round-trips it
// correctly.
//
// The Go connection is opened BEFORE the python setter runs and stays open
// for the whole test (measured requirement, not a style choice): an Xvfb
// with zero connected clients resets root-window state, including
// properties, the instant the last client disconnects -- setting the
// property from a python process that then exits, with no other client
// connected, silently loses it before anything can read it back. Keeping
// our own connection open the entire time means the client count never
// drops to zero. A real i3/xrdp session never hits this because the window
// manager itself stays connected continuously; only a single-shot
// set-and-disconnect script (as this test's setter would otherwise be) on
// an otherwise-empty Xvfb can.
func TestIntegration_ResolveMod_Xvfb_WithResourceLine(t *testing.T) {
	requireBinaryForIntegration(t, "Xvfb")
	requireBinaryForIntegration(t, "python3")

	dispNum := pickFreeIntegrationDisplay(t)
	startIntegrationXvfb(t, dispNum)
	display := fmt.Sprintf(":%d", dispNum)

	conn, info, err := x11.Open(display)
	if err != nil {
		t.Fatalf("Open(%s): %v", display, err)
	}
	defer conn.Close()
	root := info.Screens[0].Root

	const setPropertyScript = `
from Xlib import display as xdisplay
d = xdisplay.Display()
root = d.screen().root
atom = d.intern_atom("RESOURCE_MANAGER")
strtype = d.intern_atom("STRING")
root.change_property(atom, strtype, 8, b"i3wm.mod:\tMod1\n")
d.sync()
`
	cmd := exec.Command("python3", "-c", setPropertyScript)
	cmd.Env = append(cmd.Environ(), "DISPLAY="+display)
	if out, err := cmd.CombinedOutput(); err != nil {
		if strings.Contains(string(out), "ModuleNotFoundError") || strings.Contains(string(out), "No module named") {
			t.Skipf("python3-Xlib not available: %s", out)
		}
		t.Fatalf("python3 ChangeProperty script: %v: %s", err, out)
	}

	got := ResolveMod(conn.GetPropertyAll, root)
	if got != "Mod1" {
		t.Fatalf("ResolveMod after seeding RESOURCE_MANAGER = %q, want %q", got, "Mod1")
	}
}
