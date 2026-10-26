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
	out := make(chan kwin.Event, cap(in))
	go func() {
		defer close(out)
		for ev := range in {
			out <- win32KeyEvent(ev)
		}
	}()
	return out
}

func win32KeyEvent(ev win32.Event) kwin.Event {
	return kwin.Event{Kind: "press", Keysym: ev.Keysym, Mods: ev.Mods, Device: win32Device}
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
