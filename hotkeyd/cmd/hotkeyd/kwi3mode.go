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
//   - Publish never blocks: it records the CURRENT mode and kicks one
//     worker goroutine through a one-slot channel, so a burst of layer
//     changes during a kwi3 hiccup collapses to the last one - the only
//     one whose colour matters.
//   - The reporter has its OWN kwi3rpc.Client (own connection, own lock),
//     so a mode.set in flight never serialises a chord behind it, and each
//     Call is bounded (WithCallTimeout) so a kwi3 that stopped answering
//     costs one timeout per attempt, not a worker parked for ever.
//   - Failures are logged once until the next success: an unreachable
//     socket by kwi3rpc.Client itself (its own down/up lines), any other
//     error (a kwi3 too old to know mode.set answers -32601) here.
//
// And it converges (kwi3-55l.28) - the ring must not stay red because one
// message was lost:
//   - The reporter keeps the CURRENT mode apart from the last one kwi3
//     ACKNOWLEDGED, and duplicate suppression compares against the acked
//     one, so a mode whose call failed is never mistaken for delivered.
//   - A transport failure (dial refused, timeout, connection dropped)
//     retries the current mode with bounded exponential backoff
//     (modeRetryMin..modeRetryMax) until an attempt is acked. It also
//     forgets the acked mode: kwi3 scopes mode.set to the connection that
//     sent it (ft010) and reverts to "default" when that connection
//     closes, so after a drop nothing is known to be set. An *RPCError is
//     kwi3's definite answer (e.g. -32601 from a kwi3 without mode.set)
//     and is not retried.
//   - Resync (hooked to the chord client's kwi3rpc.WithOnConnect in
//     main.go) forgets the acked mode and resends the current one, so a
//     kwi3 that restarted while hotkeyd sat in a mode - the new process
//     starts in "default" - is told the current mode on the first chord
//     that reaches it.
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
	"sync"
	"time"

	"hotkeyd/internal/kwi3rpc"
	"hotkeyd/internal/layer"
)

// modeCallTimeout bounds one mode.set. kwi3 answers on its event loop in
// well under a millisecond; a second is "not answering", not "slow".
const modeCallTimeout = time.Second

// modeRetryMin/modeRetryMax bound the backoff between retries of a mode.set
// that failed on the transport: the first retry waits modeRetryMin, each
// further one doubles, capped at modeRetryMax. Variables so tests can
// shrink them.
var (
	modeRetryMin = 250 * time.Millisecond
	modeRetryMax = 5 * time.Second
)

type kwi3ModeReporter struct {
	caller *kwi3rpc.Client
	log    func(string)
	// retryMin/retryMax: modeRetryMin/Max as they were at construction.
	retryMin, retryMax time.Duration

	mu      sync.Mutex
	current string        // the effective mode hotkeyd is in now
	acked   string        // last mode kwi3 acknowledged on this connection; "" = unknown
	gen     uint64        // bumped by Resync, so an ack racing it is not trusted
	kick    chan struct{} // one slot: "current may differ from acked"
	done    chan struct{} // closed by Close
	closed  bool
}

func newKwi3ModeReporter(caller *kwi3rpc.Client, logf func(string), initial string) *kwi3ModeReporter {
	r := &kwi3ModeReporter{
		caller:   caller,
		log:      logf,
		retryMin: modeRetryMin,
		retryMax: modeRetryMax,
		kick:     make(chan struct{}, 1),
		done:     make(chan struct{}),
	}
	go r.run()
	// The engine's starting layer, sent unconditionally (acked starts
	// unknown): a kwi3 left in "resize" by a hotkeyd that died mid-mode is
	// put back to "default".
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
	if r.closed {
		return
	}
	r.current = name
	if name != r.acked {
		r.kickLocked()
	}
}

// Resync forgets what kwi3 acknowledged and resends the current mode. It
// is the chord client's OnConnect hook: it runs with that client's lock
// held, so it only takes the reporter's own lock and never blocks.
func (r *kwi3ModeReporter) Resync() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.acked = ""
	r.gen++
	r.kickLocked()
}

func (r *kwi3ModeReporter) kickLocked() {
	select {
	case r.kick <- struct{}{}:
	default: // already kicked; the worker reads r.current when it wakes
	}
}

func (r *kwi3ModeReporter) run() {
	failing := false
	var backoff time.Duration
	var retry *time.Timer
	var retryC <-chan time.Time
	for {
		select {
		case <-r.done:
			if retry != nil {
				retry.Stop()
			}
			r.caller.Close()
			return
		case <-r.kick:
		case <-retryC:
		}
		if retry != nil {
			retry.Stop()
			retry, retryC = nil, nil
		}

		r.mu.Lock()
		name, gen := r.current, r.gen
		upToDate := name == r.acked
		r.mu.Unlock()
		if upToDate {
			backoff = 0
			continue
		}

		_, err := r.caller.Call("mode.set", map[string]interface{}{"name": name})

		var rpcErr *kwi3rpc.RPCError
		r.mu.Lock()
		switch {
		case err == nil:
			failing = false
			backoff = 0
			if r.gen == gen {
				r.acked = name
			}
			if r.current != r.acked { // changed (or Resync'd) mid-call
				r.kickLocked()
			}
		case errors.As(err, &rpcErr):
			// kwi3 answered, with a refusal: retrying gets the same answer.
			// The connection (and whatever it set before) is untouched.
			backoff = 0
			if !failing {
				failing = true
				r.log(fmt.Sprintf("kwi3 mode.set %q failed: %s (the focus ring keeps its last colour; logged once until one succeeds)", name, err))
			}
		default:
			// Transport failure: the connection is gone, and kwi3 reverts a
			// mode set by a closed connection - nothing is known set now.
			r.acked = ""
			if !errors.Is(err, kwi3rpc.ErrUnreachable) && !failing {
				// (an unreachable socket kwi3rpc.Client already logged, once)
				failing = true
				r.log(fmt.Sprintf("kwi3 mode.set %q failed: %s (retrying with backoff; logged once until one succeeds)", name, err))
			}
			if backoff == 0 {
				backoff = r.retryMin
			} else if backoff *= 2; backoff > r.retryMax {
				backoff = r.retryMax
			}
			retry = time.NewTimer(backoff)
			retryC = retry.C
		}
		r.mu.Unlock()
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
// nil: the engine's "no feed"), and the reporter is nil. On a kwi3 session
// it tees statePub (when there is one) with a mode reporter, and returns
// the reporter - main.go closes it at shutdown and hooks its Resync to the
// chord client's reconnect.
func enginePublisher(statePub layer.Publisher, kwi3Sock string, logf func(string)) (layer.Publisher, *kwi3ModeReporter) {
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
