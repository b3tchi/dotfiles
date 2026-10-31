package main

// sp011 Task 10: the `--input kwin` key source. Instead of XI2 grabs on an X
// display, the daemon asks the kwi3keys KWin plugin to swallow chords and
// reads press/release/mods events from it (internal/kwin). Everything after
// the event -> layer.Event translation (engine, dispatch, grab resync,
// mode.set) is the code the X11 path runs.

import (
	"fmt"
	"os"
	"path/filepath"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwin"
	"hotkeyd/internal/layer"
)

// kwinDisplay names the daemon's per-instance files (lock, state socket,
// control socket, grab report) when there is no X display to key them on:
// "kwin-<socket>" after the KWin this daemon is a client of ($WAYLAND_DISPLAY),
// as the plugin names its grab socket, so a second KWin of the same user
// gets a second daemon instead of exit 3 on the first one's lock.
func kwinDisplay() string { return kwinDisplayFor(os.Getenv("WAYLAND_DISPLAY")) }

func kwinDisplayFor(wayland string) string {
	if wayland == "" {
		wayland = "wayland-0"
	}
	return "kwin-" + filepath.Base(wayland)
}

// kwinModBits maps the grab server's X11-valued mods to canonical modifiers.
var kwinModBits = []struct {
	bit  uint32
	name string
}{
	{kwin.ModShift, "Shift"},
	{kwin.ModCtrl, "Ctrl"},
	{kwin.ModAlt, "Mod1"},
	{kwin.ModSuper, "Mod4"},
}

const kwinModMask = kwin.ModShift | kwin.ModCtrl | kwin.ModAlt | kwin.ModSuper

// kwinModsSet is the canonical modifier names set in mods.
func kwinModsSet(mods uint32) map[string]bool {
	out := map[string]bool{}
	for _, m := range kwinModBits {
		if mods&m.bit != 0 {
			out[m.name] = true
		}
	}
	return out
}

// kwinGrabManager is *kwin.GrabManager's surface.
type kwinGrabManager interface {
	SyncBinds(chords []string) bool
	OnMappingNotify() bool
	Active() map[string]kwin.Chord
	Wanted() []string
	GrabReport() (wanted, active int, missing []string)
}

// kwinGrabs adapts a kwin.GrabManager to the daemon's grabSyncer. A
// GrabbedChord carries the keysym in Code and the X11-valued mods in Mask,
// which is what handleKwinKey matches an incoming event against.
type kwinGrabs struct{ m kwinGrabManager }

func (g kwinGrabs) SyncBinds(c []string) bool { return g.m.SyncBinds(c) }
func (g kwinGrabs) OnMappingNotify() bool     { return g.m.OnMappingNotify() }
func (g kwinGrabs) Wanted() []string          { return g.m.Wanted() }
func (g kwinGrabs) GrabReport() (int, int, []string) {
	return g.m.GrabReport()
}
func (g kwinGrabs) Active() map[string]GrabbedChord {
	act := g.m.Active()
	out := make(map[string]GrabbedChord, len(act))
	for k, c := range act {
		out[k] = GrabbedChord{Code: c.Keysym, Mask: c.Mods}
	}
	return out
}

// kwinChordKey finds the bare key name of the active chord a (keysym, mods)
// event belongs to. Exact (keysym, mods) match first; failing that the first
// wanted chord with that keysym, mirroring keysymFor's code-only fallback.
func kwinChordKey(wanted []string, active map[string]GrabbedChord, mod string, keysym, mods uint32) (string, bool) {
	fallback, have := "", false
	for _, chord := range wanted {
		gc, ok := active[chord]
		if !ok || gc.Code != keysym {
			continue
		}
		if gc.Mask == mods {
			if _, key, err := bind.ParseChord(chord, mod); err == nil {
				return key, true
			}
		}
		if !have {
			fallback, have = chord, true
		}
	}
	if have {
		if _, key, err := bind.ParseChord(fallback, mod); err == nil {
			return key, true
		}
	}
	return "", false
}

// kwinModQuery answers the hold-layer poll from the plugin's mods stream.
func (d *Daemon) kwinModQuery() layer.ModifierDown {
	mods := d.kwinMods
	return func(mod string) (bool, error) {
		for _, m := range kwinModBits {
			if m.name == mod {
				return mods&m.bit != 0, nil
			}
		}
		return false, fmt.Errorf("kwinModQuery: unknown modifier %q", mod)
	}
}

// handleKwinEvent is the plugin-side twin of handleXEvent.
func (d *Daemon) handleKwinEvent(ev kwin.Event) {
	switch ev.Kind {
	case "mods":
		prev := d.kwinMods
		d.kwinMods = ev.Mods & kwinModMask
		d.handleKwinMods(prev, d.kwinMods)
		// A released hold modifier ends its layer now, exactly as the idle
		// poll would on its next tick (adr0016) - just without the wait.
		d.pollIdle()
	case "press", "release":
		d.kwinMods = ev.Mods & kwinModMask
		d.handleKwinKey(ev)
	case "lost":
		// The plugin clears its grab set when the connection drops, so
		// whatever layer was up has no keys behind it any more: back to the
		// default layer. The client re-sends whatever set is current on
		// reconnect, so resync to the default set first.
		d.kwinMods = 0
		d.dispatchAll(d.engine.Reset())
		d.resyncGrabs()
	case "up":
		// Reconnected: the client already re-sent the set; a resync makes
		// the grab report truthful again (Active() was empty while down).
		d.resyncGrabs()
	}
}

// handleKwinMods turns a change of the plugin's modifier mask into the
// modifier key presses and releases the engine tracks holds from. The
// plugin passes modifier keys through and reports only the mask, so
// without this a layer's Mod sublayers (nav: held Ctrl moves, held Alt
// resizes) never engage on a kwin session.
func (d *Daemon) handleKwinMods(prev, now uint32) {
	for _, m := range kwinModBits {
		if (prev^now)&m.bit == 0 {
			continue
		}
		kind := layer.Release
		if now&m.bit != 0 {
			kind = layer.Press
		}
		before := d.engine.State().Layer
		d.dispatchAll(d.engine.Handle(layer.Event{
			Kind: kind,
			Key:  modKeysymNames[m.name][0],
			Mods: kwinModsSet(now),
		}))
		if d.engine.State().Layer != before {
			d.resyncGrabs()
		}
	}
}

func (d *Daemon) handleKwinKey(ev kwin.Event) {
	mods := ev.Mods & kwinModMask
	key, ok := kwinChordKey(d.grabs.Wanted(), d.grabs.Active(), d.mod, ev.Keysym, mods)
	if !ok {
		return // not one of ours
	}
	if deviceIgnored(ev.Device) {
		return
	}
	kind := layer.Press
	if ev.Kind == "release" {
		kind = layer.Release
	}
	rawState := mods
	before := d.engine.State().Layer
	actions := d.engine.Handle(layer.Event{
		Kind:     kind,
		Key:      key,
		Mods:     kwinModsSet(mods),
		Device:   ev.Device,
		RawState: &rawState,
	})
	d.dispatchAll(actions)
	if d.engine.State().Layer != before {
		d.resyncGrabs()
	}
}
