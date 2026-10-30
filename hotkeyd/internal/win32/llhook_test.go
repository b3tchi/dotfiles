package win32

// sp012 Task 5 (kwi3-hoex.5): the hook's decision, fed synthetic
// KBDLLHOOKSTRUCT-shaped events. NO hook is installed anywhere in this
// file - Decide is the callback's body, called directly.

import (
	"math/rand"
	"sort"
	"testing"
	"time"
)

const ksTab uint32 = 0xff09

func down(vk uint16) KeyInput { return KeyInput{VK: vk} }
func up(vk uint16) KeyInput   { return KeyInput{VK: vk, Up: true, Flags: LLKHF_UP} }

func drain(h *Hook) []HookEvent {
	var out []HookEvent
	for {
		select {
		case ev := <-h.events:
			out = append(out, ev)
		default:
			return out
		}
	}
}

// switcherOwned is what the daemon hands the hook in the default layer
// ($mod+Tab, the switcher's entry chord) plus, in the layer, its keys
// under the held $mod.
var switcherOwned = map[Chord]bool{
	{Keysym: ksTab, Mods: ModAlt}:            true, // $mod+Tab / Mod1+Tab
	{Keysym: ksTab, Mods: ModAlt | ModShift}: true, // Mod1+Shift+Tab
	{Keysym: 'w', Mods: ModAlt}:              true,
}

// $mod+Tab: Alt passes, Tab is swallowed and queued with Alt, Tab again
// while held is swallowed and queued, each Tab release is swallowed, and
// Alt's release passes and is queued as the modifier change the engine
// ends the hold layer on.
func TestHook_AltTabSequence(t *testing.T) {
	h := NewHook(16)
	h.SetOwned(switcherOwned)
	steps := []struct {
		in      KeyInput
		swallow bool
	}{
		{down(VK_LMENU), false},
		{down(VK_TAB), true},
		{up(VK_TAB), true},
		{down(VK_TAB), true},
		{down(VK_TAB), true}, // auto-repeat: still ours
		{up(VK_TAB), true},
		{up(VK_LMENU), false},
	}
	for i, s := range steps {
		if got := h.Decide(s.in); got != s.swallow {
			t.Fatalf("step %d (%+v): swallow=%v, want %v", i, s.in, got, s.swallow)
		}
	}
	got := drain(h)
	want := []HookEvent{
		{Kind: "mods", VK: VK_LMENU, Mods: ModAlt},
		{Kind: "press", VK: VK_TAB, Keysym: ksTab, Mods: ModAlt},
		{Kind: "release", VK: VK_TAB, Keysym: ksTab, Mods: ModAlt},
		{Kind: "press", VK: VK_TAB, Keysym: ksTab, Mods: ModAlt},
		{Kind: "press", VK: VK_TAB, Keysym: ksTab, Mods: ModAlt},
		{Kind: "release", VK: VK_TAB, Keysym: ksTab, Mods: ModAlt},
		{Kind: "mods", VK: VK_LMENU, Mods: 0},
	}
	if len(got) != len(want) {
		t.Fatalf("events %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("event %d %+v, want %+v", i, got[i], want[i])
		}
	}
	if h.Mods() != 0 || h.Overflow() != 0 {
		t.Errorf("mods %d overflow %d after the sequence", h.Mods(), h.Overflow())
	}
}

// Every key the hook does not own passes, and is not queued: plain
// letters, Tab without $mod, $mod with another key, a VK with no keysym,
// and every modifier (even a right-hand one).
func TestHook_EverythingElsePasses(t *testing.T) {
	h := NewHook(16)
	h.SetOwned(switcherOwned)
	for _, in := range []KeyInput{
		down('A'), up('A'), down(VK_TAB), up(VK_TAB),
		down(VK_RCONTROL), down(VK_TAB), up(VK_TAB), up(VK_RCONTROL), // Ctrl+Tab
		down(VK_LWIN), up(VK_LWIN),
		down(VK_LMENU), down('1'), up('1'), down(0xFF), up(0xFF), up(VK_LMENU),
	} {
		if h.Decide(in) {
			t.Errorf("%+v swallowed, want passed", in)
		}
	}
	for _, ev := range drain(h) {
		if ev.Kind != "mods" {
			t.Errorf("queued %+v, want only modifier changes", ev)
		}
	}
}

// The recover chord passes whatever the hook owns - even when the owned
// set (wrongly) names it, in a hold layer or not, under Alt or Win.
func TestHook_RecoverChordAlwaysPasses(t *testing.T) {
	h := NewHook(16)
	owned := map[Chord]bool{
		{Keysym: 'r', Mods: ModAlt | ModShift}:   true,
		{Keysym: 'r', Mods: ModSuper | ModShift}: true,
	}
	for k := range switcherOwned {
		owned[k] = true
	}
	h.SetOwned(owned)
	seqs := [][]KeyInput{
		{down(VK_LMENU), down(VK_LSHIFT), down('R'), up('R'), up(VK_LSHIFT), up(VK_LMENU)},
		// inside the switcher: Alt held, Tab taken, then Shift+r
		{down(VK_LMENU), down(VK_TAB), up(VK_TAB), down(VK_RSHIFT), down('R'), up('R'), up(VK_RSHIFT), up(VK_LMENU)},
		{down(VK_RWIN), down(VK_LSHIFT), down('R'), up('R'), up(VK_LSHIFT), up(VK_RWIN)},
	}
	for i, seq := range seqs {
		for _, in := range seq {
			sw := h.Decide(in)
			if in.VK == 'R' && sw {
				t.Errorf("seq %d: recover chord's r (%+v) swallowed", i, in)
			}
		}
		for _, ev := range drain(h) {
			if ev.VK == 'R' {
				t.Errorf("seq %d: recover chord queued %+v", i, ev)
			}
		}
	}
}

// The callback only queues: with nobody reading (the engine blocked) and
// a queue of 4, a thousand owned presses each return in well under 1 ms,
// and every one past the fourth is counted as overflow, not waited for.
func TestHook_FullQueueCountsOverflowAndNeverBlocks(t *testing.T) {
	h := NewHook(4)
	h.SetOwned(switcherOwned)
	h.Decide(down(VK_LMENU)) // 1 queued (mods)
	took := make([]time.Duration, 0, 1000)
	for i := 0; i < 1000; i++ {
		t0 := time.Now()
		sw := h.Decide(down(VK_TAB))
		took = append(took, time.Since(t0))
		if !sw {
			t.Fatalf("press %d passed; an owned key stays swallowed with the queue full", i)
		}
	}
	// p99, not the max: wall-clock on a shared box, where the OS can
	// deschedule the thread mid-call (cmd/hotkeyd's callbackTimes says
	// more). A callback that waited would never return at all here.
	sort.Slice(took, func(i, j int) bool { return took[i] < took[j] })
	worst := took[len(took)-1]
	if p99 := took[len(took)*99/100]; p99 >= time.Millisecond {
		t.Errorf("p99 callback %s, want under 1ms", p99)
	}
	if got := h.Overflow(); got != 1000-3 {
		t.Errorf("overflow %d, want %d", got, 1000-3)
	}
	t.Logf("slowest of 1000 callbacks with the queue full: %s", worst)
}

// LLKHF_INJECTED is handled exactly like a physical event; the flag only
// rides along on the queued event.
func TestHook_InjectedHandledLikePhysical(t *testing.T) {
	h := NewHook(16)
	h.SetOwned(switcherOwned)
	h.Decide(KeyInput{VK: VK_LMENU, Flags: LLKHF_INJECTED})
	if !h.Decide(KeyInput{VK: VK_TAB, Flags: LLKHF_INJECTED}) {
		t.Fatal("injected $mod+Tab passed")
	}
	evs := drain(h)
	if len(evs) != 2 || !evs[0].Injected || !evs[1].Injected || evs[1].Kind != "press" {
		t.Errorf("events %+v, want mods+press both flagged injected", evs)
	}
}

// A held modifier's auto-repeat is one transition, not many.
func TestHook_ModifierRepeatQueuesOnce(t *testing.T) {
	h := NewHook(16)
	for i := 0; i < 5; i++ {
		h.Decide(down(VK_LMENU))
	}
	if evs := drain(h); len(evs) != 1 {
		t.Errorf("events %+v, want one", evs)
	}
}

// $mod released while hotkeyd was not running: the release arrives for a
// modifier the hook never saw go down. Nothing is stuck - the state stays
// "nothing held" and a following Tab passes.
func TestHook_OrphanModifierReleaseLeavesNothingHeld(t *testing.T) {
	h := NewHook(16)
	h.SetOwned(switcherOwned)
	h.Resync(func(uint16) bool { return false })
	h.Decide(up(VK_LMENU))
	if h.Mods() != 0 {
		t.Fatalf("mods %d after an orphan Alt release", h.Mods())
	}
	if h.Decide(down(VK_TAB)) {
		t.Error("Tab swallowed with no $mod held")
	}
}

// Resync reads the keyboard; Stale is the removed-hook probe.
func TestHook_ResyncAndStale(t *testing.T) {
	h := NewHook(16)
	h.SetOwned(switcherOwned)
	altDown := func(vk uint16) bool { return vk == VK_LMENU }
	none := func(uint16) bool { return false }

	if h.Stale(none) {
		t.Error("stale with nothing held anywhere")
	}
	// The hook missed Alt going down (Windows unhooked it): stale.
	if !h.Stale(altDown) {
		t.Error("not stale with Alt down and untracked")
	}
	h.Resync(altDown)
	if h.Mods() != ModAlt || h.Stale(altDown) {
		t.Errorf("after resync mods %d stale %v", h.Mods(), h.Stale(altDown))
	}
	if evs := drain(h); len(evs) != 1 || evs[0] != (HookEvent{Kind: "mods", Mods: ModAlt}) {
		t.Errorf("resync queued %+v", evs)
	}
	// Tab now is $mod+Tab.
	if !h.Decide(down(VK_TAB)) {
		t.Error("$mod+Tab after resync passed")
	}
	// A reinstall forgets swallowed presses: that release then passes.
	h.Resync(none)
	if h.Decide(up(VK_TAB)) {
		t.Error("release swallowed after resync forgot its press")
	}
	h.Remind()
	if evs := drain(h); len(evs) < 1 || evs[len(evs)-1] != (HookEvent{Kind: "mods", Mods: 0}) {
		t.Errorf("remind queued %+v", evs)
	}
}

// A release swallowed only because its press was: a key pressed BEFORE it
// became owned keeps its release.
func TestHook_ReleaseFollowsPress(t *testing.T) {
	h := NewHook(16)
	h.Decide(down(VK_LMENU))
	if h.Decide(down(VK_TAB)) {
		t.Fatal("unowned Tab swallowed")
	}
	h.SetOwned(switcherOwned)
	if h.Decide(up(VK_TAB)) {
		t.Error("release of a press that passed was swallowed")
	}
}

// answers feeds seq and returns, per step, what Decide answered.
func answers(h *Hook, seq []KeyInput) []bool {
	out := make([]bool, len(seq))
	for i, in := range seq {
		out[i] = h.Decide(in)
	}
	return out
}

// (a) of rejection #1: Tab swallowed as $mod+Tab, $mod released (the layer
// ends, the owned set shrinks to the entry chord), Tab auto-repeats with no
// modifier: the repeat and the release stay swallowed - the application
// never saw this Tab go down, so it must not see it come up either, and it
// must not see a repeat with no press. The repeat is not queued: bare Tab
// is not owned any more.
func TestHook_SwallowedKeyStaysSwallowedThroughRepeats(t *testing.T) {
	h := NewHook(32)
	h.SetOwned(switcherOwned)
	got := answers(h, []KeyInput{down(VK_LMENU), down(VK_TAB)})
	drain(h)
	h.SetOwned(map[Chord]bool{{Keysym: ksTab, Mods: ModAlt}: true}) // the default layer's set
	got = append(got, answers(h, []KeyInput{up(VK_LMENU), down(VK_TAB), down(VK_TAB), up(VK_TAB)})...)
	want := []bool{false, true, false, true, true, true}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("answers %v, want %v", got, want)
		}
	}
	for _, ev := range drain(h) {
		if ev.Kind == "press" {
			t.Errorf("a repeat of a no-longer-owned chord was queued: %+v", ev)
		}
	}
}

// (b): Tab pressed bare (passed), then $mod pressed, Tab auto-repeats as
// Mod1+Tab: still passed, nothing queued (no switcher entry from a
// repeat), and the release passes.
func TestHook_PassedKeyStaysPassedThroughRepeats(t *testing.T) {
	h := NewHook(32)
	h.SetOwned(switcherOwned)
	got := answers(h, []KeyInput{down(VK_TAB), down(VK_LMENU), down(VK_TAB), down(VK_TAB), up(VK_TAB), up(VK_LMENU)})
	for i, sw := range got {
		if sw {
			t.Fatalf("step %d swallowed: %v", i, got)
		}
	}
	for _, ev := range drain(h) {
		if ev.Kind != "mods" {
			t.Errorf("queued %+v", ev)
		}
	}
	// A fresh press after the release is decided anew.
	h.Decide(down(VK_LMENU))
	if !h.Decide(down(VK_TAB)) {
		t.Error("a fresh $mod+Tab after the release passed")
	}
}

// Return held, then $mod pressed: Alt+Return is owned in every layer (a
// global on the same key as the switcher's Return), but the held Return's
// repeats go on passing - no terminal spawned from a repeat, no stuck
// Return.
func TestHook_HeldReturnThenAltIsNotAltReturn(t *testing.T) {
	h := NewHook(32)
	owned := map[Chord]bool{{Keysym: 0xff0d, Mods: ModAlt}: true}
	h.SetOwned(owned)
	got := answers(h, []KeyInput{down(VK_RETURN), down(VK_RETURN), down(VK_LMENU), down(VK_RETURN), down(VK_RETURN), up(VK_RETURN), up(VK_LMENU)})
	for i, sw := range got {
		if sw {
			t.Fatalf("step %d swallowed: %v", i, got)
		}
	}
	for _, ev := range drain(h) {
		if ev.Kind == "press" {
			t.Errorf("queued %+v: a repeat read as Alt+Return", ev)
		}
	}
}

// Property: over random press/repeat/release sequences of a few keys, with
// modifiers going up and down and the owned set changing in between (layer
// changes), every answer a key gets from its first press to its release is
// the first press's answer, and the recover chord's r is never swallowed.
func TestHook_PropertyPressAndReleaseAgree(t *testing.T) {
	keys := []uint16{VK_TAB, VK_RETURN, 'W', 'R', VK_ESCAPE}
	mods := []uint16{VK_LMENU, VK_RMENU, VK_LSHIFT, VK_LCONTROL}
	sets := []map[Chord]bool{
		switcherOwned,
		{{Keysym: ksTab, Mods: ModAlt}: true, {Keysym: 0xff0d, Mods: ModAlt}: true},
		{{Keysym: ksTab, Mods: 0}: true, {Keysym: 'w', Mods: 0}: true, {Keysym: 0xff1b, Mods: ModAlt}: true,
			{Keysym: 'r', Mods: ModAlt | ModShift}: true},
		nil,
	}
	rng := rand.New(rand.NewSource(5))
	h := NewHook(1 << 16)
	isDown := map[uint16]bool{}
	first := map[uint16]bool{}
	for step := 0; step < 20000; step++ {
		switch r := rng.Intn(10); {
		case r == 0:
			h.SetOwned(sets[rng.Intn(len(sets))])
		case r <= 3:
			vk := mods[rng.Intn(len(mods))]
			h.Decide(KeyInput{VK: vk, Up: rng.Intn(2) == 0})
		default:
			vk := keys[rng.Intn(len(keys))]
			up := isDown[vk] && rng.Intn(3) == 0
			sw := h.Decide(KeyInput{VK: vk, Up: up})
			if vk == 'R' && sw {
				recoverHeld := h.Mods()&ModShift != 0 && h.Mods()&(ModAlt|ModSuper) != 0
				if recoverHeld && !isDown[vk] {
					t.Fatalf("step %d: the recover chord's r was swallowed", step)
				}
			}
			switch {
			case up:
				if sw != first[vk] {
					t.Fatalf("step %d: vk %#x released %v, its press %v", step, vk, sw, first[vk])
				}
				isDown[vk] = false
			case isDown[vk]:
				if sw != first[vk] {
					t.Fatalf("step %d: vk %#x repeat %v, its press %v", step, vk, sw, first[vk])
				}
			default:
				isDown[vk], first[vk] = true, sw
			}
		}
		drain(h)
	}
}

// HOTKEYD_TRACE (kwi3-hoex.35): with no EnableTrace the hook records
// nothing; with it, every non-modifier key event of a chord (Alt held
// here throughout; typing is TestHook_TraceOmitsTyping's) gets one record
// saying what the callback answered and why, and each modifier TRANSITION
// one (its auto-repeat none), with the modifiers tracked after the event.
func TestHook_TraceRecordsEachDecision(t *testing.T) {
	quiet := NewHook(16)
	quiet.SetOwned(switcherOwned)
	quiet.Decide(down(VK_LMENU))
	quiet.Decide(down(VK_TAB))
	if quiet.trace.Load() != nil || quiet.TraceDropped() != 0 {
		t.Fatal("a hook with no EnableTrace has a trace")
	}

	h := NewHook(16)
	h.SetOwned(switcherOwned)
	tr := h.EnableTrace(32)
	seq := []KeyInput{
		down(VK_LMENU), down(VK_LMENU), // Alt, then its auto-repeat
		down(VK_LSHIFT),
		down(VK_LEFT), up(VK_LEFT), // Alt+Shift+Left: not the hook's
		up(VK_LSHIFT),
		down(VK_TAB), down(VK_TAB), up(VK_TAB), // $mod+Tab: owned, repeat, release
		{VK: 'R', Flags: LLKHF_INJECTED}, // Alt+r, injected, not owned
		up('R'),
		up(VK_LMENU),
	}
	for _, in := range seq {
		h.Decide(in)
	}
	want := []string{
		"hook vk=0xa4 down passed (modifier) injected=false mods=Alt",
		"hook vk=0xa0 down passed (modifier) injected=false mods=Shift+Alt",
		"hook vk=0x25 down passed (not owned) injected=false mods=Shift+Alt",
		"hook vk=0x25 up passed (release of a passed press) injected=false mods=Shift+Alt",
		"hook vk=0xa0 up passed (modifier) injected=false mods=Alt",
		"hook vk=0x9 down swallowed (owned) injected=false mods=Alt",
		"hook vk=0x9 down swallowed (repeat of a swallowed press) injected=false mods=Alt",
		"hook vk=0x9 up swallowed (release of a swallowed press) injected=false mods=Alt",
		"hook vk=0x52 down passed (not owned) injected=true mods=Alt",
		"hook vk=0x52 up passed (release of a passed press) injected=false mods=Alt",
		"hook vk=0xa4 up passed (modifier) injected=false mods=none",
	}
	var got []string
drained:
	for {
		select {
		case r := <-tr:
			got = append(got, r.String())
		default:
			break drained
		}
	}
	if len(got) != len(want) {
		t.Fatalf("%d trace records, want %d:\n%s", len(got), len(want), joinLines(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("record %d:\n got %s\nwant %s", i, got[i], want[i])
		}
	}
	// A full channel drops and counts; the callback never waits. (Alt is
	// held: a bare key is typing and never traced, kwi3-hoex.36.)
	small := NewHook(16)
	small.EnableTrace(1)
	small.Decide(down(VK_LMENU))
	small.Decide(down(VK_LEFT))
	small.Decide(up(VK_LEFT))
	if small.TraceDropped() != 2 {
		t.Fatalf("TraceDropped = %d, want 2", small.TraceDropped())
	}
}

func joinLines(s []string) string {
	out := ""
	for _, l := range s {
		out += l + "\n"
	}
	return out
}

// kwi3-hoex.36: the trace goes to a persistent log, so a key the hook
// passes is recorded only when Alt, Ctrl or Win is held - a chord, never
// typing. Plain and Shift+ keys (with their repeats and releases, even if
// a modifier goes down before the release) leave no record; Alt+Shift+Left
// (the diagnosis kwi3-hoex.35 needs), Ctrl+c, Win+e and an owned key do.
func TestHook_TraceOmitsTyping(t *testing.T) {
	h := NewHook(64)
	h.SetOwned(switcherOwned)
	tr := h.EnableTrace(64)
	seq := []KeyInput{
		down('P'), down('P'), up('P'), // plain p, with a repeat
		down(VK_LSHIFT),
		down('A'), down('A'), up('A'), // Shift+a
		down('2'), // Shift+2, released only after Alt is down
		down(VK_LMENU),
		up('2'),
		down(VK_LEFT), up(VK_LEFT), // Alt+Shift+Left
		up(VK_LSHIFT),
		down(VK_TAB), up(VK_TAB), // $mod+Tab, owned
		up(VK_LMENU),
		down(VK_LCONTROL), down('C'), up('C'), up(VK_LCONTROL), // Ctrl+c
		down(VK_LWIN), down('E'), up('E'), up(VK_LWIN), // Win+e
		down('Z'), up('Z'), // plain z again
	}
	for _, in := range seq {
		h.Decide(in)
	}
	want := []string{
		"hook vk=0xa0 down passed (modifier) injected=false mods=Shift",
		"hook vk=0xa4 down passed (modifier) injected=false mods=Shift+Alt",
		"hook vk=0x25 down passed (not owned) injected=false mods=Shift+Alt",
		"hook vk=0x25 up passed (release of a passed press) injected=false mods=Shift+Alt",
		"hook vk=0xa0 up passed (modifier) injected=false mods=Alt",
		"hook vk=0x9 down swallowed (owned) injected=false mods=Alt",
		"hook vk=0x9 up swallowed (release of a swallowed press) injected=false mods=Alt",
		"hook vk=0xa4 up passed (modifier) injected=false mods=none",
		"hook vk=0xa2 down passed (modifier) injected=false mods=Ctrl",
		"hook vk=0x43 down passed (not owned) injected=false mods=Ctrl",
		"hook vk=0x43 up passed (release of a passed press) injected=false mods=Ctrl",
		"hook vk=0xa2 up passed (modifier) injected=false mods=none",
		"hook vk=0x5b down passed (modifier) injected=false mods=Win",
		"hook vk=0x45 down passed (not owned) injected=false mods=Win",
		"hook vk=0x45 up passed (release of a passed press) injected=false mods=Win",
		"hook vk=0x5b up passed (modifier) injected=false mods=none",
	}
	var got []string
drained:
	for {
		select {
		case r := <-tr:
			got = append(got, r.String())
		default:
			break drained
		}
	}
	if len(got) != len(want) {
		t.Fatalf("%d trace records, want %d:\n%s", len(got), len(want), joinLines(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("record %d:\n got %s\nwant %s", i, got[i], want[i])
		}
	}

	// A release whose press the hook never saw (a Resync forgot it) is
	// traced only as its press would have been: bare, nothing; under Alt,
	// one record.
	h.Resync(func(uint16) bool { return false })
	h.Decide(up('Q'))
	h.Decide(down(VK_LMENU))
	h.Decide(up('Q'))
	got = got[:0]
	for len(tr) > 0 {
		got = append(got, (<-tr).String())
	}
	want = []string{
		"hook vk=0xa4 down passed (modifier) injected=false mods=Alt",
		"hook vk=0x51 up passed (release of a passed press) injected=false mods=Alt",
	}
	if joinLines(got) != joinLines(want) {
		t.Errorf("after Resync:\n%swant\n%s", joinLines(got), joinLines(want))
	}
}

// kwi3-hoex.43: Win+D - Windows' "show desktop", which minimised every
// window of Jan's kwi3 session with no way back (kwi3 hides the taskbar) -
// is swallowed, under either Win key: its press, its auto-repeats and its
// release, whatever the owned set says and whichever key comes up first.
// The Win key itself still passes, and nothing is queued for the daemon
// but the modifier changes: a blocked key does nothing at all.
func TestHook_WinDIsBlocked(t *testing.T) {
	for _, win := range []uint16{VK_LWIN, VK_RWIN} {
		for _, owned := range []map[Chord]bool{nil, switcherOwned, {{Keysym: 'd', Mods: ModSuper}: true}} {
			h := NewHook(16)
			h.SetOwned(owned)
			steps := []struct {
				in      KeyInput
				swallow bool
			}{
				{down(win), false},
				{down('D'), true},
				{down('D'), true}, // auto-repeat
				{up('D'), true},
				{down('D'), true}, // Win+D again, Win still held
				{up(win), false},  // Win up first...
				{up('D'), true},   // ...and D's release still swallowed
			}
			for i, s := range steps {
				if got := h.Decide(s.in); got != s.swallow {
					t.Fatalf("win %#x owned %v step %d (%+v): swallow=%v, want %v", win, owned, i, s.in, got, s.swallow)
				}
			}
			for _, ev := range drain(h) {
				if ev.Kind != "mods" {
					t.Errorf("win %#x owned %v: a blocked key queued %+v", win, owned, ev)
				}
			}
		}
	}
}

// Only Win+D, and only it: plain d, Shift+d, Alt+d, Ctrl+d, Win+e, Win+m,
// and Win+D with another modifier held too (Win+Shift+D, Ctrl+Win+D,
// Win+Alt+D) all pass - Jan has decided nothing about any other chord.
func TestHook_OnlyWinDIsBlocked(t *testing.T) {
	cases := []struct {
		name string
		mods []uint16
		key  uint16
	}{
		{"d", nil, 'D'},
		{"Shift+d", []uint16{VK_LSHIFT}, 'D'},
		{"Alt+d", []uint16{VK_LMENU}, 'D'},
		{"Ctrl+d", []uint16{VK_LCONTROL}, 'D'},
		{"Win+e", []uint16{VK_LWIN}, 'E'},
		{"Win+m", []uint16{VK_LWIN}, 'M'},
		{"Win+Shift+m", []uint16{VK_LWIN, VK_LSHIFT}, 'M'},
		{"Win+Shift+d", []uint16{VK_LWIN, VK_LSHIFT}, 'D'},
		{"Ctrl+Win+d", []uint16{VK_LCONTROL, VK_RWIN}, 'D'},
		{"Win+Alt+d", []uint16{VK_RWIN, VK_LMENU}, 'D'},
	}
	for _, c := range cases {
		h := NewHook(16)
		for _, m := range c.mods {
			h.Decide(down(m))
		}
		if h.Decide(down(c.key)) || h.Decide(down(c.key)) || h.Decide(up(c.key)) {
			t.Errorf("%s: swallowed, want passed", c.name)
		}
	}
	// A d held down BEFORE Win keeps its first answer (sticky): passed.
	h := NewHook(16)
	h.Decide(down('D'))
	h.Decide(down(VK_LWIN))
	if h.Decide(up('D')) {
		t.Error("the release of a d pressed before Win was swallowed")
	}
}

// HOTKEYD_TRACE records a blocked Win+D as a blocked chord - swallowed,
// with Win held - never as a passed key; a plain d around it (typing)
// leaves no record at all.
func TestHook_WinDTrace(t *testing.T) {
	h := NewHook(16)
	tr := h.EnableTrace(32)
	for _, in := range []KeyInput{
		down('D'), up('D'),
		down(VK_LWIN), down('D'), down('D'), up('D'), up(VK_LWIN),
		down('D'), up('D'),
	} {
		h.Decide(in)
	}
	var got []string
	for len(tr) > 0 {
		got = append(got, (<-tr).String())
	}
	want := []string{
		"hook vk=0x5b down passed (modifier) injected=false mods=Win",
		"hook vk=0x44 down swallowed (blocked: Win+D, show desktop) injected=false mods=Win",
		"hook vk=0x44 down swallowed (repeat of a blocked press) injected=false mods=Win",
		"hook vk=0x44 up swallowed (release of a blocked press) injected=false mods=Win",
		"hook vk=0x5b up passed (modifier) injected=false mods=none",
	}
	if joinLines(got) != joinLines(want) {
		t.Errorf("trace:\n%swant\n%s", joinLines(got), joinLines(want))
	}
}
