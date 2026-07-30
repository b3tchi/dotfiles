package layer

import (
	"fmt"

	"hotkeyd/internal/bind"
)

// ModifierDown asks the X server whether mod is currently down, sampled
// STANDALONE rather than off any event's state mask ([[adr0016]]
// consequence 1: "the query must be standalone" — an event's state mask is
// pre-event in X, so it cannot answer "is it down now", and a separate
// round trip has no event to be "pre").
//
// cmd/hotkeyd implements this against a real query (sp021 Task 11/12); this
// package only carries the func type, so the engine itself stays X-free —
// the structural point of [[adr0016]].
type ModifierDown func(mod string) (bool, error)

// PollIdle is the daemon's idle-path hook. Call it on a bounded interval
// (adr0016's consequence: "the idle path costs one X round trip while a
// hold layer is up"); it is safe and cheap to call unconditionally, since
// it queries nothing and returns (nil, nil) when the engine currently has
// no opinion worth checking against the server.
//
// [[adr0016]] consequence 2 is honoured here structurally: PollIdle NEVER
// reads e.held to decide whether a hold layer should end — it asks query
// for the exact modifier(s) it cares about (the current layer's Hold, plus
// any sublayer modifier the engine currently believes is held) and acts
// only on query's answer. A hold layer entered with its modifier ALREADY
// down (the daemon never saw the press — the structural case adr0016
// exists for) is handled identically to one whose press WAS seen: the
// query is asked either way, and e.held is never consulted for the hold
// decision.
func (e *Engine) PollIdle(query ModifierDown) ([]bind.Action, error) {
	canons := map[string]bool{}
	for c := range e.held {
		canons[c] = true
	}
	hold := e.HoldModifier()
	if hold != "" {
		canons[hold] = true
	}
	if len(canons) == 0 {
		return nil, nil
	}

	down := map[string]bool{}
	for c := range canons {
		d, err := query(c)
		if err != nil {
			return nil, fmt.Errorf("layer: ModifierDown(%s): %w", c, err)
		}
		down[c] = d
	}

	var out []bind.Action
	if hold != "" {
		out = e.ReconcileHoldLayer(down[hold])
	}
	e.ReconcileHolds(down)
	return out, nil
}
