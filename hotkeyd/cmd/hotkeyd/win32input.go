package main

// sp012 Task 4 (kwi3-hoex.4): the `--input win32` key source's glue. The
// Windows thread (internal/win32's Source) registers chords with
// RegisterHotKey and reports each WM_HOTKEY as a keysym plus X11 modifier
// bits; this file hands those to the daemon as the same press events the
// KWin source produces (kwin.Event), so everything from layer.Event on -
// engine, dispatch, grab resync on a layer change, mode.set - is the code
// the X11 and KWin paths run (handleKwinEvent, kwininput.go).
//
// Pure Go, no build tag: tested on Linux. The Windows-only startup is
// win32run.go.

import (
	"fmt"
	"strings"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwin"
	"hotkeyd/internal/layer"
	"hotkeyd/internal/win32"
)

// win32Mod is what $mod means on Windows: Alt (Mod1), Jan's $mod on the
// RDP session, where the Win key stays with the client. There is no X
// resource to read it from (ResolveMod) and bind.DefaultMod is Mod4.
const win32Mod = string(bind.Mod1)

// win32Device names the key source in a layer.Event. No bind names it, so
// a device-scoped bind never matches a Windows key (there is one keyboard
// as far as RegisterHotKey can tell).
const win32Device = "win32"

// win32Grabs adapts a *win32.Hotkeys to the daemon's grabSyncer, the way
// kwinGrabs adapts the KWin manager: Code carries the keysym and Mask the
// X11 modifier bits, which handleKwinKey matches an event against.
type win32Grabs struct{ h *win32.Hotkeys }

func (g win32Grabs) SyncBinds(c []string) bool { return g.h.SyncBinds(c) }
func (g win32Grabs) OnMappingNotify() bool     { return g.h.OnMappingNotify() }
func (g win32Grabs) Wanted() []string          { return g.h.Wanted() }
func (g win32Grabs) GrabReport() (int, int, []string) {
	return g.h.GrabReport()
}
func (g win32Grabs) Active() map[string]GrabbedChord {
	act := g.h.Active()
	out := make(map[string]GrabbedChord, len(act))
	for k, c := range act {
		out[k] = GrabbedChord{Code: c.Keysym, Mask: c.Mods}
	}
	return out
}

// win32KeyEvents turns the hotkey thread's events into the daemon's
// key-event stream: one press per WM_HOTKEY (RegisterHotKey reports no
// release). The returned channel closes when in does.
func win32KeyEvents(in <-chan win32.Event) <-chan kwin.Event {
	return win32Merge(in, nil, nil, nil, nil, nil)
}

// win32TraceEnv, set to 1, turns on the per-event trace (kwi3-hoex.35):
// every WM_HOTKEY taken (registration id, key, modifiers, message time and
// the modifier keys GetAsyncKeyState reads down at that moment), every
// low-level hook decision on a chord (key, direction, swallowed or passed
// and why, injected, the tracked modifiers) and what the daemon made of
// each key event (chord, layer, actions). A key the hook passes is traced
// only with Alt, Ctrl or Win held, never typing (kwi3-hoex.36). Off by
// default: nothing is read and no line is written.
const win32TraceEnv = "HOTKEYD_TRACE"

// win32TraceWarning is the line the trace starts with, on the log it then
// writes to: what it records, that the log persists, and what to do about
// it (kwi3-hoex.36).
const win32TraceWarning = win32TraceEnv + "=1: tracing to this log (session start: " +
	`%LOCALAPPDATA%\hotkeyd\<desktop>.log), with ms timestamps, every WM_HOTKEY, every chord ` +
	"and every key pressed while Alt, Ctrl or Win is held (AltGr is Ctrl+Alt), and every " +
	"modifier press and release; keys typed bare or with Shift alone are not recorded. " +
	"Do not type passwords or other secrets while it is on, " +
	"and delete this log and its .log.1 afterwards (the next session start rotates it to .log.1)"

// win32Trace is the trace's two inputs win32Merge reads: the line sink and
// the hook's decision records (nil: no hook, or not traced).
type win32Trace struct {
	log  func(string)
	hook <-chan win32.HookTrace
}

// traceFromEnv is HOTKEYD_TRACE's gate: with it set to 1, the trace sink
// (traceLog over log), after one line on log saying the trace is on;
// otherwise nil and nothing is logged.
func traceFromEnv(getenv func(string) string, log func(string), now func() time.Time) func(string) {
	if strings.TrimSpace(getenv(win32TraceEnv)) != "1" {
		return nil
	}
	log(win32TraceWarning)
	return traceLog(log, now)
}

// traceLog prefixes each trace line with "trace" and the wall-clock time
// to the millisecond, so a trace can be read against the host's and
// against what Jan pressed.
func traceLog(log func(string), now func() time.Time) func(string) {
	return func(s string) {
		log("trace " + now().Format("15:04:05.000") + " " + s)
	}
}

// hookStats is what win32Merge reads of the low-level hook beside its
// events: the overflow counter, logged when it rises.
type hookStats interface{ Overflow() uint64 }

// win32Merge is the daemon's key-event stream from both Windows sources:
// WM_HOTKEY presses (in) and, when the table needs it, the low-level
// hook's presses, releases and modifier changes (hook; nil: none). The
// stream closes when in does - the hotkey thread is the daemon's life.
// log and debug may be nil. log gets a line whenever the hook's queue has dropped
// events since the last one; debug (HOTKEYD_WIN32_DEBUG=1) gets every
// LLKHF_INJECTED event (handled like a physical one until sp012 Task 14
// measures what RDP delivers).
func win32Merge(in <-chan win32.Event, hook <-chan win32.HookEvent, stats hookStats, log, debug func(string), trace *win32Trace) <-chan kwin.Event {
	out := make(chan kwin.Event, cap(in)+cap(hook))
	var hookTrace <-chan win32.HookTrace
	if trace != nil {
		hookTrace = trace.hook
	}
	go func() {
		defer close(out)
		var dropped uint64
		for {
			select {
			case t := <-hookTrace:
				trace.log(t.String())
				continue
			case ev, ok := <-in:
				if !ok {
					return
				}
				if trace != nil {
					trace.log(ev.TraceString())
				}
				out <- win32KeyEvent(ev)
			case ev := <-hook:
				if ev.Injected && debug != nil {
					debug(fmt.Sprintf("low-level hook: injected %s vk=%#x keysym=%#x mods=%#x", ev.Kind, ev.VK, ev.Keysym, ev.Mods))
				}
				out <- win32HookEvent(ev)
			}
			if stats != nil && log != nil {
				if n := stats.Overflow(); n > dropped {
					log(fmt.Sprintf("low-level hook: %d key event(s) dropped, the queue was full (%d in all)", n-dropped, n))
					dropped = n
				}
			}
		}
	}()
	return out
}

func win32HookEvent(ev win32.HookEvent) kwin.Event {
	return kwin.Event{Kind: ev.Kind, Keysym: ev.Keysym, Mods: ev.Mods, Device: win32Device}
}

// tableNeedsHook reports whether the table has anything RegisterHotKey
// cannot serve - a hold layer, or a chord bound on release - and so needs
// the low-level hook. Without either, hotkeyd installs no hook at all.
func tableNeedsHook(binds []bind.Bind, layers map[string]bind.Layer) bool {
	for _, b := range binds {
		if b.OnRelease {
			return true
		}
	}
	for _, l := range layers {
		if l.Hold != "" {
			return true
		}
		for _, b := range l.Binds {
			if b.OnRelease {
				return true
			}
		}
	}
	return false
}

// hookChords is the set of chords the low-level hook serves instead of
// RegisterHotKey (sp012 Task 5): every chord a hold layer grabs while it is
// up (layerChords: its keys bare and under the held modifier, its exit
// keys), every chord that enters a hold layer (the $mod+Tab press must come
// in the same ordered stream as the $mod release that ends the layer), and
// every release-only chord. Matched by normalized identity, so "$mod+Tab"
// and "Mod1+Tab" are one chord - which also makes a global chord on the
// key of a hold-layer chord ($mod+Return, the switcher's Return under the
// held $mod) the hook's in every layer: one owner per key, and no
// unregister/register churn on every Alt+Tab.
func hookChords(binds []bind.Bind, layers map[string]bind.Layer, mod string) func(string) bool {
	set := map[bind.ChordKey]bool{}
	add := func(chord string) {
		if k, err := bind.NormalizeChord(chord, mod); err == nil {
			set[k] = true
		}
	}
	entersHold := func(b bind.Bind) bool {
		for _, a := range b.Actions {
			if e, ok := a.(bind.EnterLayer); ok && layers[e.Layer].Hold != "" {
				return true
			}
		}
		return false
	}
	for _, b := range binds {
		if entersHold(b) {
			add(b.Chord)
		}
	}
	for _, l := range layers {
		for _, b := range l.Binds {
			if entersHold(b) {
				add(b.Chord)
			}
		}
		if l.Hold != "" {
			for _, c := range layerChords(l, mod) {
				add(c)
			}
		}
	}
	release := releaseOnlyChords(binds, layers, mod)
	return func(chord string) bool {
		if release(chord) {
			return true
		}
		k, err := bind.NormalizeChord(chord, mod)
		return err == nil && set[k]
	}
}

func win32KeyEvent(ev win32.Event) kwin.Event {
	// NoRelease: RegisterHotKey reports the press alone, and the engine
	// would otherwise read the next WM_HOTKEY of the same key within
	// KeyWedgeMS as auto-repeat and swallow it - Alt+Shift+Left twice with
	// the modifiers held moved the window once (kwi3-hoex.35).
	return kwin.Event{Kind: "press", Keysym: ev.Keysym, Mods: ev.Mods, Device: win32Device, NoRelease: true}
}

// releaseOnlyChords is the set of chords every one of whose binds - in the
// global table or any layer - fires on release. RegisterHotKey cannot serve
// those (sp012 Task 5's hook does); a chord with any press bind is served
// on its press.
func releaseOnlyChords(binds []bind.Bind, layers map[string]bind.Layer, mod string) func(string) bool {
	press := map[bind.ChordKey]bool{}
	release := map[bind.ChordKey]bool{}
	note := func(b bind.Bind) {
		k, err := bind.NormalizeChord(b.Chord, mod)
		if err != nil {
			return
		}
		if b.OnRelease {
			release[k] = true
		} else {
			press[k] = true
		}
	}
	for _, b := range binds {
		note(b)
	}
	for _, l := range layers {
		for _, b := range l.Binds {
			note(b)
		}
		for _, m := range l.Mods {
			for _, b := range m.Binds {
				note(b)
			}
		}
	}
	return func(chord string) bool {
		k, err := bind.NormalizeChord(chord, mod)
		return err == nil && release[k] && !press[k]
	}
}

// win32ModQuery answers the hold-layer poll from the keyboard's real state
// (GetAsyncKeyState, read through down) rather than from the last event's
// mods: RegisterHotKey reports no release, so the event stream never says
// a modifier went up.
func win32ModQuery(down func(vk uint16) bool) func() layer.ModifierDown {
	return func() layer.ModifierDown {
		bits := win32.ModBits(down)
		return func(mod string) (bool, error) {
			for _, m := range kwinModBits {
				if m.name == mod {
					return bits&m.bit != 0, nil
				}
			}
			return false, fmt.Errorf("win32ModQuery: unknown modifier %q", mod)
		}
	}
}
