package win32

// sp012 Task 5: the grab manager's split between RegisterHotKey and the
// low-level hook.

import (
	"strings"
	"testing"
)

func switcherHooking(c string) bool {
	switch c {
	case "$mod+Tab", "Mod1+Tab", "Mod1+Shift+Tab", "Tab", "$mod+Print":
		return true
	}
	return false
}

// A hooked chord is never passed to RegisterHotKey: the hook owns it, it
// reads as served in Active and the grab report, and plain chords still
// register.
func TestHotkeys_HookChordsGoToTheHook(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	hook := NewHook(8)
	h.UseHook(hook, switcherHooking)
	if !h.SyncBinds([]string{"$mod+1", "$mod+Tab"}) {
		t.Fatal("SyncBinds reported no change")
	}
	if f.registered(VK_TAB, MOD_ALT|MOD_NOREPEAT) {
		t.Fatal("$mod+Tab passed to RegisterHotKey")
	}
	if !f.registered('1', MOD_ALT|MOD_NOREPEAT) {
		t.Fatal("$mod+1 not registered")
	}
	if own := hook.Owned(); len(own) != 1 || !own[Chord{Keysym: ksTab, Mods: ModAlt}] {
		t.Errorf("hook owns %v, want only Alt+Tab", own)
	}
	if _, ok := h.Active()["$mod+Tab"]; !ok {
		t.Error("$mod+Tab not in Active")
	}
	if w, a, m := h.GrabReport(); w != 2 || a != 2 || len(m) != 0 {
		t.Errorf("grab report %d %d %q", w, a, m)
	}

	// Entering the layer: its keys join the hook; leaving: they go.
	h.SyncBinds([]string{"$mod+1", "$mod+Tab", "Tab", "Mod1+Tab", "Mod1+Shift+Tab"})
	if own := hook.Owned(); len(own) != 3 {
		t.Errorf("hook owns %v in the layer, want Tab, Alt+Tab, Alt+Shift+Tab", own)
	}
	h.SyncBinds([]string{"$mod+1", "$mod+Tab"})
	if own := hook.Owned(); len(own) != 1 {
		t.Errorf("hook owns %v after the layer, want Alt+Tab", own)
	}
	for _, c := range f.calls {
		if strings.Contains(c, string(rune(VK_TAB))) {
			t.Errorf("a Tab chord reached the registrar: %q", c)
		}
	}
	h.ReleaseAll()
	if len(hook.Owned()) != 0 {
		t.Error("ReleaseAll left the hook owning chords")
	}
}

// A release-only chord is served by the hook instead of refused.
func TestHotkeys_ReleaseOnlyServedByHook(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, func(c string) bool { return c == "$mod+Print" }, nil)
	hook := NewHook(8)
	h.UseHook(hook, switcherHooking)
	h.SyncBinds([]string{"$mod+Print"})
	if _, _, m := h.GrabReport(); len(m) != 0 {
		t.Fatalf("missing %q", m)
	}
	if !hook.Owned()[Chord{Keysym: 0xff61, Mods: ModAlt}] {
		t.Errorf("hook owns %v", hook.Owned())
	}
	if len(f.calls) != 0 {
		t.Errorf("registrar calls %q", f.calls)
	}
}

// With no hook installed the hook's chords are refused, named, and still
// never registered.
func TestHotkeys_NoHookRefusesHookChords(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	h.UseHook(nil, switcherHooking)
	h.SyncBinds([]string{"$mod+1", "$mod+Tab"})
	_, a, m := h.GrabReport()
	if a != 1 || len(m) != 1 || m[0] != "$mod+Tab: "+ReasonNoHook {
		t.Errorf("active %d missing %q", a, m)
	}
	if f.registered(VK_TAB, MOD_ALT|MOD_NOREPEAT) {
		t.Error("$mod+Tab registered with no hook")
	}
}

// A plain chord on a hooked key goes to the hook too: the hook sees the
// key first, so a registration of it could never fire.
func TestHotkeys_SameKeyAsHookedFollowsIt(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	hook := NewHook(8)
	h.UseHook(hook, func(c string) bool { return c == "$mod+Tab" })
	h.SyncBinds([]string{"$mod+Tab", "Mod1+Tab"})
	if len(f.calls) != 0 {
		t.Errorf("registrar calls %q", f.calls)
	}
	if _, ok := h.Hooked()["Mod1+Tab"]; !ok {
		t.Errorf("hooked %v", h.Hooked())
	}
}

// A registered chord that becomes the hook's is unregistered first.
func TestHotkeys_RegisteredChordMovesToHook(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	hook := NewHook(8)
	hookTab := false
	h.UseHook(hook, func(c string) bool { return hookTab && c == "Mod1+Tab" })
	h.SyncBinds([]string{"Mod1+Tab"})
	if !f.registered(VK_TAB, MOD_ALT|MOD_NOREPEAT) {
		t.Fatal("not registered while not hooked")
	}
	hookTab = true
	h.SyncBinds([]string{"Mod1+Tab"})
	if f.registered(VK_TAB, MOD_ALT|MOD_NOREPEAT) || len(hook.Owned()) != 1 {
		t.Errorf("registered %v, hook %v", f.held, hook.Owned())
	}
}

// The recover chord never reaches the hook either.
func TestHotkeys_ReservedNeverHooked(t *testing.T) {
	f := newFakeReg()
	h := NewHotkeys(f, "Mod1", testKeysym, nil, nil)
	hook := NewHook(8)
	h.UseHook(hook, func(string) bool { return true })
	h.SyncBinds([]string{"$mod+Shift+r", "Mod1+Shift+r"})
	if len(hook.Owned()) != 0 || len(f.calls) != 0 {
		t.Errorf("hook %v calls %q", hook.Owned(), f.calls)
	}
}
