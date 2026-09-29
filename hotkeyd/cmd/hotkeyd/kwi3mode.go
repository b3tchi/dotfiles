package main

// kwi3-55l.25: on a kwi3 session, tell kwi3 which layer is active.
//
// kwi3 paints its window focus ring in a per-mode colour (config.js
// `kwi3.set({modeFrame: {resize: "#DC322F"}})`) and learns the mode from
// ft010's `mode.set {name}`. The layer engine already reports every state
// CHANGE to a layer.Publisher (the bars' state socket); this file tees that
// feed into a reporter that sends the layer's name to kwi3.
//
// Best-effort by construction, because chords are the daemon's job and a
// ring colour is not:
//   - Publish never blocks: it hands the name to one worker goroutine
//     through a one-slot, latest-wins mailbox, so a burst of layer changes
//     during a kwi3 hiccup collapses to the last one - the only one whose
//     colour matters.
//   - The reporter has its OWN kwi3rpc.Client (own connection, own lock),
//     so a mode.set in flight never serialises a chord behind it, and each
//     Call is bounded (WithCallTimeout) so a kwi3 that stopped answering
//     costs one timeout per change, not a worker parked for ever.
//   - Failures are logged once until the next success: an unreachable
//     socket by kwi3rpc.Client itself (its own down/up lines), any other
//     error (a kwi3 too old to know mode.set answers -32601) here.
//
// What is reported is the EFFECTIVE mode (kwi3-55l.29), not the bare Layer:
// on Jan's table `resize` is a held-modifier SUB-LAYER inside `nav`
// (layer.State{Layer: "nav", Mod: "resize"}), not a layer of its own, and
// reporting only State.Layer never told kwi3 "resize" at all - the ring
// stayed whatever colour `nav` painted it (none; `nav` has no modeFrame
// entry). effectiveMode returns the active mod sub-layer's label when one
// is held (State.Mod - already the bare label a Mods table declares, e.g.
// "move"/"resize": internal/bind/bind.go's Layer.Mods, keyed by that same
// label, and config.js's `modeFrame` keys on it directly), else the layer
// name - so a plain layer change (no Mods declared, or none held) still
// reports the layer as before. A plain i3 or sway session ($KWI3SOCK
// unset) gets no reporter at all - i3 modes are i3's own business there.

import (
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"hotkeyd/internal/kwi3rpc"
	"hotkeyd/internal/layer"
)

// modeCallTimeout bounds one mode.set. kwi3 answers on its event loop in
// well under a millisecond; a second is "not answering", not "slow".
const modeCallTimeout = time.Second

type kwi3ModeReporter struct {
	caller *kwi3rpc.Client
	log    func(string)

	mu      sync.Mutex
	last    string        // last effective mode queued, to drop unchanged repeats
	mailbox chan string   // one slot, latest wins
	done    chan struct{} // closed by Close
	closed  bool
}

func newKwi3ModeReporter(caller *kwi3rpc.Client, logf func(string), initial string) *kwi3ModeReporter {
	r := &kwi3ModeReporter{
		caller:  caller,
		log:     logf,
		mailbox: make(chan string, 1),
		done:    make(chan struct{}),
	}
	go r.run()
	// The engine's starting layer, sent unconditionally: a kwi3 left in
	// "resize" by a hotkeyd that died mid-mode is put back to "default".
	r.report(initial)
	return r
}

// Publish implements layer.Publisher.
func (r *kwi3ModeReporter) Publish(st layer.State) {
	r.report(effectiveMode(st))
}

// effectiveMode is the name kwi3 is told: the active mod sub-layer's label
// when one is held, else the layer name. See the file doc for why - this
// is the one place layer.State collapses to the single name ft010's
// `mode.set` and config.js's `modeFrame` both key on.
func effectiveMode(st layer.State) string {
	if st.Mod != "" {
		return st.Mod
	}
	return st.Layer
}

func (r *kwi3ModeReporter) report(name string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || name == r.last {
		return
	}
	r.last = name
	select { // drop a stale, not-yet-sent name: only the latest matters
	case <-r.mailbox:
	default:
	}
	r.mailbox <- name
}

func (r *kwi3ModeReporter) run() {
	failing := false
	for {
		select {
		case <-r.done:
			r.caller.Close()
			return
		case name := <-r.mailbox:
			_, err := r.caller.Call("mode.set", map[string]interface{}{"name": name})
			switch {
			case err == nil:
				failing = false
			case errors.Is(err, kwi3rpc.ErrUnreachable):
				// kwi3rpc.Client already logged the socket going down, once.
			case !failing:
				failing = true
				r.log(fmt.Sprintf("kwi3 mode.set %q failed: %s (the focus ring keeps its last colour; logged once until one succeeds)", name, err))
			}
		}
	}
}

// Close stops the worker. It never waits on kwi3: a mode.set in flight
// finishes (or times out) on its own.
func (r *kwi3ModeReporter) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.closed {
		r.closed = true
		close(r.done)
	}
	return nil
}

// teePublisher hands every state to each publisher in turn.
type teePublisher []layer.Publisher

func (t teePublisher) Publish(st layer.State) {
	for _, p := range t {
		p.Publish(st)
	}
}

// enginePublisher is the layer.Publisher the engine is built with. With no
// $KWI3SOCK (kwi3Sock == "") it is statePub itself, untouched (nil stays
// nil: the engine's "no feed"), and the closer is nil. On a kwi3 session it
// tees statePub (when there is one) with a mode reporter, and returns the
// reporter as the closer for shutdown.
func enginePublisher(statePub layer.Publisher, kwi3Sock string, logf func(string)) (layer.Publisher, io.Closer) {
	if kwi3Sock == "" {
		return statePub, nil
	}
	client := kwi3rpc.New(kwi3Sock,
		kwi3rpc.WithCallTimeout(modeCallTimeout),
		kwi3rpc.WithLog(func(s string) { logf("mode feed: " + s) }))
	rep := newKwi3ModeReporter(client, logf, layer.DefaultLayer)
	if statePub == nil {
		return rep, rep
	}
	return teePublisher{statePub, rep}, rep
}
