// loop.go is the one home for adr0014's three reader-loop guards, shared by
// census.go's RunLoop (two clocks: a fast gated poll plus a slow ungated
// bound refresh) and messages.go's RunMessagesLoop (one clock). Both used
// to reimplement the same select-over-a-ticker shape independently; this
// file is that shape, written once, named against the ADR it satisfies:
//
//   - guard 1, fail fast on unrecoverable setup — the optional `setup`
//     argument runs once, before any tick. A non-nil error return exits
//     immediately without ticking at all: the loop never retries its own
//     vanished precondition from the inside. Both callers here pass nil,
//     because agent-monitor's actual setup check (Available() /
//     MessagesAvailable()) already runs once in cmd/agent-monitor/main.go,
//     before either loop starts — but the hook exists on this function so
//     the guard is exercised directly by loop_test.go rather than only by
//     convention.
//   - guard 2, a sleep floor on every iteration — each clock's OWN ticker
//     interval is its floor. No failure path inside a TickFn can make its
//     own clock fire faster than once per interval, whatever the failure.
//   - guard 3, retry bounded by a timer outside the loop — a failing tick
//     is retried only on ITS OWN ticker's next fire, never inline and
//     never immediately.
package source

import (
	"context"
	"time"
)

// TickFn is one guarded loop iteration: sample, and report whether the
// displayed frame changed. It must never retry internally — RunSingleTicked
// and RunDualTicked own guard 3 (the bounded retry) themselves, by
// construction, simply by calling a TickFn once per ticker fire and never
// again until the next one.
type TickFn func(ctx context.Context) bool

// RunSingleTicked runs one TickFn on one ticker until ctx is cancelled, or
// returns setup's error immediately if setup is non-nil and fails. This is
// messages.go's RunMessagesLoop's entire body: one clock, adr0014's guards
// applied to it.
func RunSingleTicked(ctx context.Context, setup func() error, interval time.Duration, tick TickFn, onTick func(changed bool)) error {
	if setup != nil {
		if err := setup(); err != nil {
			return err // guard 1: exit, never retry a vanished setup from inside
		}
	}
	ticker := time.NewTicker(interval) // guard 2: sleep floor
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			changed := tick(ctx) // guard 3: bounded retry, next tick only
			if onTick != nil {
				onTick(changed)
			}
		}
	}
}

// RunDualTicked runs two TickFns on two independent tickers inside ONE
// select in ONE goroutine, so onTick is never invoked concurrently with
// itself even though the two clocks fire on unrelated schedules —
// census.go's RunLoop callers may rely on onTick being serialized (its own
// regression test increments a plain, unsynchronized int from onTick).
// This is RunLoop's entire body: the fast, gated clock and the slow,
// ungated bound clock, each carrying adr0014's guards independently — the
// sleep floor and the bounded retry both apply PER CLOCK, not to the pair
// as a whole.
func RunDualTicked(ctx context.Context, setup func() error, fastInterval time.Duration, fastTick TickFn, slowInterval time.Duration, slowTick TickFn, onTick func(changed bool)) error {
	if setup != nil {
		if err := setup(); err != nil {
			return err
		}
	}
	fastTicker := time.NewTicker(fastInterval) // guard 2, fast clock's floor
	defer fastTicker.Stop()
	slowTicker := time.NewTicker(slowInterval) // guard 2, slow clock's floor
	defer slowTicker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-fastTicker.C:
			changed := fastTick(ctx) // guard 3, fast clock: retry next fast fire only
			if onTick != nil {
				onTick(changed)
			}
		case <-slowTicker.C:
			changed := slowTick(ctx) // guard 3, slow clock: retry next slow fire only
			if onTick != nil {
				onTick(changed)
			}
		}
	}
}
