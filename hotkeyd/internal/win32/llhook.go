package win32

// sp012 Task 5 (kwi3-hoex.5): the low-level keyboard hook's DECISION,
// separate from the hook itself (llhook_windows.go), so every swallow/pass
// answer is tested on Linux with synthetic events and no hook installed.
//
// What the hook is for: the chords RegisterHotKey cannot serve - a hold
// layer (the $mod+Tab switcher, whose end is the $mod RELEASE) and chords
// bound only on release. The daemon hands the hook the set of chords it
// owns right now (Hotkeys.SyncBinds, through SetOwned); the hook's
// callback then answers per key event with no call into the daemon:
//
//   - a modifier key (Shift/Ctrl/Alt/Win, either side) ALWAYS passes; its
//     transitions update the tracked modifier state and are queued as a
//     "mods" event, which is how the engine sees $mod go up and fires the
//     hold layer's OnHoldRelease;
//   - the recover chord ($mod+Shift+r, under either $mod) ALWAYS passes,
//     whatever is owned - it is the host's (adr0003), and the only way
//     back from a daemon that is wedged or wrong;
//   - Win+D (either Win key, no other modifier) - Windows' "show
//     desktop" - is SWALLOWED, press, repeats and release, and nothing is
//     queued: it does nothing at all while hotkeyd runs (kwi3-hoex.43).
//     It minimised every window of Jan's kwi3 session, and kwi3 hides the
//     taskbar, so nothing brought them back. No other chord is blocked;
//   - a key press whose (keysym, modifiers) is owned is queued and
//     SWALLOWED (the callback returns 1), and so is that key's release;
//   - everything else passes (CallNextHookEx).
//
// The decision is STICKY per key, from its first press to its release: a
// key's auto-repeat presses and its release get the answer its first
// press got, whatever the modifiers or the owned set did since. Deciding
// each repeat afresh can split a key (Tab swallowed down, passed repeat,
// swallowed up - or Return passed down, then Alt pressed and the repeat
// read as Alt+Return): the application sees a press with no release, and
// the key is stuck. A swallowed repeat is queued only while its chord is
// still owned.
//
// The callback only queues: a full queue drops the event and counts it
// (Overflow) - it never waits for the daemon, so a busy or wedged engine
// can never make Windows time the hook out (LowLevelHooksTimeout).

import (
	"fmt"
	"sync"
	"sync/atomic"
)

// KBDLLHOOKSTRUCT.flags bits (WinUser.h).
const (
	LLKHF_EXTENDED          uint32 = 0x01
	LLKHF_LOWER_IL_INJECTED uint32 = 0x02
	LLKHF_INJECTED          uint32 = 0x10
	LLKHF_ALTDOWN           uint32 = 0x20
	LLKHF_UP                uint32 = 0x80
)

// The keysym of the recover chord's key, `r` (X11 XK_r).
const keysymR uint32 = 0x72

// The keysym of show desktop's key, `d` (X11 XK_d).
const keysymD uint32 = 0x64

// BlockedChords names what the hook blocks, for the daemon's start line.
const BlockedChords = "Win+D (show desktop)"

// KeyInput is one WH_KEYBOARD_LL callback's input: the KBDLLHOOKSTRUCT
// fields the decision reads, and whether wParam was WM_KEYUP/WM_SYSKEYUP.
type KeyInput struct {
	VK    uint16
	Scan  uint32
	Flags uint32
	Up    bool
}

// Injected reports LLKHF_INJECTED. Injected events are handled exactly
// like physical ones (until sp012 Task 14 measures what RDP delivers);
// the flag only travels on to debug output.
func (k KeyInput) Injected() bool { return k.Flags&LLKHF_INJECTED != 0 }

// HookEvent is what the callback queues for the daemon. Kind is "press",
// "release" or "mods"; Mods is the tracked X11 modifier state AT the event
// (for a "mods" event, the state after the transition).
type HookEvent struct {
	Kind     string
	VK       uint16
	Keysym   uint32
	Mods     uint32
	Injected bool
}

// Hook is the decision state. Decide runs on the hook's thread; SetOwned,
// Mods, Stale and Overflow may be called from any goroutine.
type Hook struct {
	owned    atomic.Pointer[map[Chord]bool]
	mods     atomic.Uint32
	overflow atomic.Uint64
	events   chan HookEvent

	// trace, when set (EnableTrace), gets one HookTrace per key event the
	// callback decides - never blocking: a full channel drops it and
	// counts it (TraceDropped).
	trace        atomic.Pointer[chan HookTrace]
	traceDropped atomic.Uint64

	// mu guards the per-key state below. Decide takes it uncontended on
	// every event; the only other taker is Resync (a hook reinstall, at
	// most once per probe interval), for microseconds.
	mu      sync.Mutex
	modDown [256]bool     // which modifier VKs (sided) are down
	keys    [256]keyState // each other key, from its first press to its release
}

// keyState is a key's sticky decision.
type keyState uint8

const (
	keyUp        keyState = iota
	keyPassed             // down, its first press passed (and traced, if on)
	keySwallowed          // down, its first press swallowed
	keyTyped              // down, its first press passed untraced: typing (traceable)
	keyBlocked            // down, its first press was Win+D: swallowed, never queued
)

// traceable reports whether a key the hook passes may be traced with mods
// held: only with Alt, Ctrl or Win down - a chord, never typing. Shift
// alone is ordinary typing. HOTKEYD_TRACE writes to a persistent log, so
// plain and Shift+ keys stay out of it (kwi3-hoex.36).
func traceable(mods uint32) bool { return mods&(ModAlt|ModCtrl|ModSuper) != 0 }

// NewHook builds a hook decision with a queue of buffer events (default
// 64). It owns nothing until SetOwned.
func NewHook(buffer int) *Hook {
	if buffer <= 0 {
		buffer = 64
	}
	h := &Hook{events: make(chan HookEvent, buffer)}
	empty := map[Chord]bool{}
	h.owned.Store(&empty)
	return h
}

// Events is the queue the daemon reads.
func (h *Hook) Events() <-chan HookEvent { return h.events }

// Overflow is how many events found the queue full and were dropped.
func (h *Hook) Overflow() uint64 { return h.overflow.Load() }

// Mods is the modifier state the hook has tracked, as X11 bits.
func (h *Hook) Mods() uint32 { return h.mods.Load() }

// SetOwned replaces the set of chords the hook swallows. The map is
// copied; nil owns nothing.
func (h *Hook) SetOwned(owned map[Chord]bool) {
	cp := make(map[Chord]bool, len(owned))
	for k, v := range owned {
		if v {
			cp[k] = true
		}
	}
	h.owned.Store(&cp)
}

// Owned is a copy of the owned set.
func (h *Hook) Owned() map[Chord]bool {
	cur := *h.owned.Load()
	cp := make(map[Chord]bool, len(cur))
	for k := range cur {
		cp[k] = true
	}
	return cp
}

// IsRecoverChord reports whether (keysym, mods) is the recover chord,
// $mod+Shift+r, under either $mod (Alt or Win): r with Shift and Alt or
// Win held, whatever else is held too. The hook passes it unconditionally.
func IsRecoverChord(keysym, mods uint32) bool {
	return keysym == keysymR && mods&ModShift != 0 && mods&(ModAlt|ModSuper) != 0
}

// IsShowDesktop reports whether (keysym, mods) is Win+D, Windows' "show
// desktop": d with Win held and no other modifier (Win+Shift+D, Ctrl+Win+D
// and Win+Alt+D are other chords, not blocked). The hook swallows it.
func IsShowDesktop(keysym, mods uint32) bool {
	return keysym == keysymD && mods == ModSuper
}

func (h *Hook) enqueue(ev HookEvent) {
	select {
	case h.events <- ev:
	default:
		h.overflow.Add(1)
	}
}

func (h *Hook) trackedBits() uint32 {
	var m uint32
	for vk, down := range h.modDown {
		if !down {
			continue
		}
		if bit, ok := ModifierBit(uint16(vk)); ok {
			m |= bit
		}
	}
	return m
}

// HookTrace is one decision of the callback, for HOTKEYD_TRACE
// (kwi3-hoex.35): the key, its direction, whether it was swallowed and
// why, the injected flag and the modifiers the hook tracked AFTER the
// event. A modifier's auto-repeat is not traced; its transitions are. A
// key the hook passes is traced only when its press came with Alt, Ctrl
// or Win held (traceable), and then so are its repeats and release; one
// pressed bare or with Shift alone - typing - is never traced, nor its
// repeats or release (kwi3-hoex.36).
type HookTrace struct {
	VK        uint16
	Up        bool
	Swallowed bool
	Why       string
	Injected  bool
	Mods      uint32
}

// String is the trace line's body.
func (t HookTrace) String() string {
	dir, verdict := "down", "passed"
	if t.Up {
		dir = "up"
	}
	if t.Swallowed {
		verdict = "swallowed"
	}
	return fmt.Sprintf("hook vk=%#x %s %s (%s) injected=%t mods=%s",
		t.VK, dir, verdict, t.Why, t.Injected, ModNames(t.Mods))
}

// EnableTrace makes the callback report every decision on a channel of
// buffer entries (default 256) and returns it. It may be called while the
// hook runs (the callback reads it atomically); the channel is never
// closed.
func (h *Hook) EnableTrace(buffer int) <-chan HookTrace {
	if buffer <= 0 {
		buffer = 256
	}
	ch := make(chan HookTrace, buffer)
	h.trace.Store(&ch)
	return ch
}

// TraceDropped is how many trace records found the channel full.
func (h *Hook) TraceDropped() uint64 { return h.traceDropped.Load() }

func (h *Hook) traced(in KeyInput, swallow bool, why string) bool {
	if p := h.trace.Load(); p != nil {
		select {
		case *p <- HookTrace{VK: in.VK, Up: in.Up, Swallowed: swallow, Why: why,
			Injected: in.Injected(), Mods: h.mods.Load()}:
		default:
			h.traceDropped.Add(1)
		}
	}
	return swallow
}

// Decide is the callback's whole job: true swallows the event (the
// callback returns 1), false passes it on (CallNextHookEx). It never
// blocks: the queue is written with a non-blocking send.
func (h *Hook) Decide(in KeyInput) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	inj := in.Injected()

	if _, isMod := ModifierBit(in.VK); isMod {
		was := h.modDown[in.VK&0xff]
		h.modDown[in.VK&0xff] = !in.Up
		if was != !in.Up { // a transition, not an auto-repeat
			m := h.trackedBits()
			h.mods.Store(m)
			h.enqueue(HookEvent{Kind: "mods", VK: in.VK, Mods: m, Injected: inj})
			h.traced(in, false, "modifier")
		}
		return false // a modifier is never ours to swallow
	}

	mods := h.mods.Load()
	ks, known := ToKeysym(in.VK)
	slot := &h.keys[in.VK&0xff]
	if in.Up {
		was := *slot
		*slot = keyUp
		switch was {
		case keySwallowed:
			h.enqueue(HookEvent{Kind: "release", VK: in.VK, Keysym: ks, Mods: mods, Injected: inj})
			return h.traced(in, true, "release of a swallowed press") // its press was ours, so is its release
		case keyTyped: // its press was typing: so is its release
			return false
		case keyBlocked: // blocked down, blocked up - whatever came up first
			return h.traced(in, true, "release of a blocked press")
		case keyUp: // a press the hook never saw (a Resync): traced as a press would be
			if !traceable(mods) {
				return false
			}
		}
		return h.traced(in, false, "release of a passed press")
	}
	owned := known && !IsRecoverChord(ks, mods) && (*h.owned.Load())[Chord{Keysym: ks, Mods: mods}]
	switch *slot {
	case keyPassed: // an auto-repeat of a key that went to the application
		return h.traced(in, false, "repeat of a passed press")
	case keyTyped: // an auto-repeat of typing: never traced
		return false
	case keyBlocked: // an auto-repeat of Win+D: blocked, never queued
		return h.traced(in, true, "repeat of a blocked press")
	case keySwallowed: // an auto-repeat of ours: swallowed whatever happens
		if owned {
			h.enqueue(HookEvent{Kind: "press", VK: in.VK, Keysym: ks, Mods: mods, Injected: inj})
		}
		return h.traced(in, true, "repeat of a swallowed press")
	}
	if known && IsShowDesktop(ks, mods) { // before owned: nothing may serve it
		*slot = keyBlocked
		return h.traced(in, true, "blocked: Win+D, show desktop")
	}
	if !owned {
		why := "not owned"
		if known && IsRecoverChord(ks, mods) {
			why = "the recover chord"
		} else if !traceable(mods) {
			*slot = keyTyped
			return false
		}
		*slot = keyPassed
		return h.traced(in, false, why)
	}
	*slot = keySwallowed
	h.enqueue(HookEvent{Kind: "press", VK: in.VK, Keysym: ks, Mods: mods, Injected: inj})
	return h.traced(in, true, "owned")
}

// Resync sets the tracked modifier state from the keyboard's (down reads
// GetAsyncKeyState) and queues it as a "mods" event: what a fresh start or
// a reinstalled hook believes. A key whose press was swallowed is
// forgotten - its release, if it ever comes, then passes.
func (h *Hook) Resync(down func(vk uint16) bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for i := range h.modDown {
		h.modDown[i] = false
		h.keys[i] = keyUp
	}
	for _, mb := range modifierBits {
		if down(mb.vk) {
			h.modDown[mb.vk&0xff] = true
		}
	}
	m := h.trackedBits()
	h.mods.Store(m)
	h.enqueue(HookEvent{Kind: "mods", Mods: m})
}

// Remind queues the tracked modifier state again, unchanged: the periodic
// re-statement that heals a "mods" event the queue dropped, or one that
// the daemon read out of order against a WM_HOTKEY from the other thread.
func (h *Hook) Remind() {
	h.enqueue(HookEvent{Kind: "mods", Mods: h.mods.Load()})
}

// Stale reports whether the keyboard's modifier state (down reads
// GetAsyncKeyState) disagrees with what the hook tracked: the sign that
// Windows removed the hook (a callback that timed out is unhooked
// silently) and transitions went unseen. Off the input desktop down reads
// 0 for every key, and so does the hook's state (it saw nothing), so it
// never reads stale there.
func (h *Hook) Stale(down func(vk uint16) bool) bool {
	return ModBits(down) != h.mods.Load()
}
