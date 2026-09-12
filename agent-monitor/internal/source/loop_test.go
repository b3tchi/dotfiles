package source

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// TestRunSingleTicked_SetupErrorExitsWithoutTicking is guard 1: a failed
// setup exits immediately rather than being retried inline, and the loop
// never ticks at all — there is nothing to retry it FROM.
func TestRunSingleTicked_SetupErrorExitsWithoutTicking(t *testing.T) {
	ticked := 0
	err := RunSingleTicked(context.Background(), func() error {
		return errors.New("boom: unrecoverable setup")
	}, 5*time.Millisecond, func(ctx context.Context) bool {
		ticked++
		return true
	}, nil)

	if err == nil {
		t.Fatal("expected the setup error to propagate")
	}
	if ticked != 0 {
		t.Fatalf("expected zero ticks after a failed setup, got %d", ticked)
	}
}

// TestRunSingleTicked_SleepFloorHoldsUnderFastFailingTicks is guard 2,
// measured rather than asserted-by-constant: a tick that does no work at
// all (the exact shape adr0014's floor exists to bound — an unbounded
// retry around a fast-failing precondition burns a core) must still only
// fire once per ticker interval. Only a wall-clock measurement over several
// iterations catches a floor that has silently stopped applying; asserting
// the interval constant is declared somewhere would not.
func TestRunSingleTicked_SleepFloorHoldsUnderFastFailingTicks(t *testing.T) {
	const interval = 20 * time.Millisecond
	const wantTicks = 5

	var mu sync.Mutex
	ticks := 0
	ctx, cancel := context.WithCancel(context.Background())
	start := time.Now()

	RunSingleTicked(ctx, nil, interval, func(ctx context.Context) bool {
		mu.Lock()
		ticks++
		n := ticks
		mu.Unlock()
		if n >= wantTicks {
			cancel()
		}
		return false // fast-fail: no work, nothing to slow this down but the ticker
	}, nil)

	elapsed := time.Since(start)
	// The Nth tick cannot fire before (N-1) full intervals have elapsed —
	// even allowing for scheduler jitter shaving a little off the top, a
	// busy-loop bug would blow through this floor by orders of magnitude,
	// not by a few milliseconds.
	minElapsed := time.Duration(wantTicks-1) * interval
	if elapsed < minElapsed {
		t.Fatalf("ticks ran faster than the sleep floor allows: %d ticks in %v, expected at least %v", wantTicks, elapsed, minElapsed)
	}
}

// TestRunSingleTicked_RecoversAfterVanishedDirectoryReturns is guard 3: a
// tick that fails every time its precondition (here, a stand-in for
// $XDG_RUNTIME_DIR) is gone must keep being retried on the ticker's own
// schedule — never inline, never abandoned — and must succeed again as
// soon as the precondition returns, with no special-case recovery path.
func TestRunSingleTicked_RecoversAfterVanishedDirectoryReturns(t *testing.T) {
	const interval = 10 * time.Millisecond

	var mu sync.Mutex
	dirGone := true
	attempts := 0
	recoveredAt := 0

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	go func() {
		time.Sleep(interval * 3)
		mu.Lock()
		dirGone = false // the directory "comes back"
		mu.Unlock()
	}()

	RunSingleTicked(ctx, nil, interval, func(ctx context.Context) bool {
		mu.Lock()
		defer mu.Unlock()
		attempts++
		if dirGone {
			return false // guard 3: fails fast, retried only on the next tick
		}
		if recoveredAt == 0 {
			recoveredAt = attempts
		}
		return true
	}, nil)

	if recoveredAt == 0 {
		t.Fatal("sampler never recovered once the directory returned")
	}
	if attempts < 3 {
		t.Fatalf("expected several failed attempts before recovery, got %d", attempts)
	}
}

func TestRunSingleTicked_OnTickFiresWithEveryResult(t *testing.T) {
	var mu sync.Mutex
	var changes []bool
	ctx, cancel := context.WithCancel(context.Background())

	result := true
	RunSingleTicked(ctx, nil, 5*time.Millisecond, func(ctx context.Context) bool {
		return result
	}, func(changed bool) {
		mu.Lock()
		changes = append(changes, changed)
		n := len(changes)
		result = !result // alternate true/false across ticks
		mu.Unlock()
		if n >= 4 {
			cancel()
		}
	})

	mu.Lock()
	defer mu.Unlock()
	if len(changes) < 4 {
		t.Fatalf("expected at least 4 onTick calls, got %d", len(changes))
	}
}

// TestRunDualTicked_SetupErrorExitsWithoutTickingEitherClock is RunLoop's
// guard 1: neither the fast nor the slow clock ticks at all if setup fails.
func TestRunDualTicked_SetupErrorExitsWithoutTickingEitherClock(t *testing.T) {
	fastTicks, slowTicks := 0, 0
	err := RunDualTicked(context.Background(), func() error {
		return errors.New("boom")
	}, 5*time.Millisecond, func(ctx context.Context) bool { fastTicks++; return false },
		20*time.Millisecond, func(ctx context.Context) bool { slowTicks++; return false }, nil)

	if err == nil {
		t.Fatal("expected the setup error to propagate")
	}
	if fastTicks != 0 || slowTicks != 0 {
		t.Fatalf("expected no ticks on either clock after a failed setup, got fast=%d slow=%d", fastTicks, slowTicks)
	}
}

// TestRunDualTicked_EachClockRetriesOnItsOwnScheduleIndependently proves
// guard 3 applies PER CLOCK: a permanently failing fast tick must not stop
// or slow the slow clock's own independent progress, and vice versa.
func TestRunDualTicked_EachClockRetriesOnItsOwnScheduleIndependently(t *testing.T) {
	var mu sync.Mutex
	fastTicks, slowTicks := 0, 0

	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()

	RunDualTicked(ctx, nil,
		10*time.Millisecond, func(ctx context.Context) bool {
			mu.Lock()
			fastTicks++
			mu.Unlock()
			return false // always fails
		},
		30*time.Millisecond, func(ctx context.Context) bool {
			mu.Lock()
			slowTicks++
			mu.Unlock()
			return true // always succeeds
		}, nil)

	mu.Lock()
	defer mu.Unlock()
	if fastTicks < 3 {
		t.Fatalf("expected the fast clock to keep ticking despite always failing, got %d", fastTicks)
	}
	if slowTicks < 2 {
		t.Fatalf("expected the slow clock to tick independently, got %d", slowTicks)
	}
}
