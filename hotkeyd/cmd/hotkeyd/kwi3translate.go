package main

import (
	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwi3rpc"
)

// kwi3UnmappedChord names one bind.Command action reachable from this
// daemon's real bind table (Binds, Layers - cmd/hotkeyd/config.go) that
// kwi3rpc.Translate has no ft010 method for at all. sp004 Task 16's own
// decision point (kwi3-234.16): reported, never silently dropped from the
// grab set - the chord still fires normally on a real i3 session; it is
// unsupported ONLY once $KWI3SOCK selects the kwi3rpc dispatch path (see
// daemon.go's dispatch).
type kwi3UnmappedChord struct {
	Chord  string // the bind's chord spelling, or a marker for a Hold layer's own actions
	Action string // the exact i3 command text, e.g. "sticky toggle"
	Err    error
}

// walkForKwi3Translation walks every bind.Command action reachable from
// binds and layers - the default layer's own binds, every named layer's
// own binds, its Mod sublayers, and its OnHoldRelease/OnExit actions - and
// asks kwi3rpc.Translate whether ft010 has a method for it. Used two ways:
//   - NewDaemon logs the result once at startup when a kwi3rpc client is
//     configured (never for an i3 session - those chords are unaffected);
//   - TestKwi3TranslateCoversRealTable (this package) pins today's
//     unsupported set against the REAL table, so a chord added later with a
//     brand new unmapped verb fails the build rather than silently joining
//     "things that just don't work under kwi3rpc" with nobody told.
func walkForKwi3Translation(binds []bind.Bind, layers map[string]bind.Layer) []kwi3UnmappedChord {
	var out []kwi3UnmappedChord
	check := func(chord string, a bind.Action) {
		cmd, ok := a.(bind.Command)
		if !ok {
			return // Run/EnterLayer/ExitLayer/Func never go near kwi3rpc - see daemon.go's dispatch
		}
		if _, err := kwi3rpc.Translate(string(cmd)); err != nil {
			out = append(out, kwi3UnmappedChord{Chord: chord, Action: string(cmd), Err: err})
		}
	}
	walkBinds := func(bs []bind.Bind) {
		for _, b := range bs {
			for _, a := range b.Actions {
				check(b.Chord, a)
			}
		}
	}
	walkBinds(binds)
	for name, l := range layers {
		walkBinds(l.Binds)
		for _, m := range l.Mods {
			walkBinds(m.Binds)
		}
		for _, a := range l.OnHoldRelease {
			check("(layer "+name+" hold-release)", a)
		}
		for _, a := range l.OnExit {
			check("(layer "+name+" on-exit)", a)
		}
	}
	return out
}
