package x11

import (
	"io"
	"sync"
	"testing"
)

// TestSequencer_WrapNeverConfusesStaleWithFresh drives >70,000 requests
// through a fake (discard) conn, forcing the 16-bit wire sequence to wrap,
// and proves that a stale pending request from before the wrap cannot
// claim an error that actually belongs to a fresh request sharing the
// same low-16 wire value (poc015 gotcha 10, the linear-scan false-positive
// gap named as execution scope in sp021's solution).
func TestSequencer_WrapNeverConfusesStaleWithFresh(t *testing.T) {
	s := NewSequencer(io.Discard)

	// Send an early request and leave it pending -- simulating a request
	// the server never replied to (or is slow to reply to).
	staleSeq, staleWaiter, err := s.SendChecked([]byte("stale-request"))
	if err != nil {
		t.Fatalf("SendChecked(stale): %v", err)
	}

	// Drive the sequence counter past one full 16-bit wrap (65536) so a
	// fresh request lands on exactly staleSeq+65536 -- same low-16 wire
	// value as the stale one.
	const wrapTarget = 65536
	target := staleSeq + wrapTarget

	var freshSeq uint64
	var freshWaiter <-chan pendingResult
	sent := 0
	for freshSeq == 0 || sent < 70001 {
		seq, waiter, err := s.SendChecked([]byte("request"))
		if err != nil {
			t.Fatalf("SendChecked(#%d): %v", sent, err)
		}
		sent++
		if seq == target {
			freshSeq = seq
			freshWaiter = waiter
		}
		if sent > 200000 {
			t.Fatal("runaway loop: never reached the colliding sequence")
		}
	}
	if sent < 70000 {
		t.Fatalf("only sent %d requests, want >70,000", sent)
	}
	if freshSeq == 0 {
		t.Fatal("never allocated the colliding post-wrap sequence")
	}
	if uint16(freshSeq) != uint16(staleSeq) {
		t.Fatalf("test fixture bug: freshSeq low16 (%d) != staleSeq low16 (%d)", uint16(freshSeq), uint16(staleSeq))
	}

	// The server now sends an error whose wire-level sequence is
	// ambiguous between staleSeq and freshSeq -- only their low 16 bits
	// are on the wire.
	wireLow := uint16(staleSeq)
	resolvedSeq, delivered := s.dispatch(wireLow, pendingResult{isError: true, xerr: XError{Code: 9}})
	if !delivered {
		t.Fatal("dispatch did not deliver to any waiter")
	}
	if resolvedSeq != freshSeq {
		t.Fatalf("dispatch resolved wire seq %d to full seq %d, want the FRESH seq %d (stale was %d) -- a stale sequence claimed a fresh error",
			wireLow, resolvedSeq, freshSeq, staleSeq)
	}

	select {
	case res := <-freshWaiter:
		if !res.isError || res.xerr.Seq != freshSeq {
			t.Fatalf("fresh waiter got wrong result: %+v", res)
		}
	default:
		t.Fatal("fresh waiter did not receive the error")
	}

	select {
	case res := <-staleWaiter:
		t.Fatalf("stale waiter incorrectly received a result: %+v", res)
	default:
		// expected: the stale request is still unresolved.
	}

	// Every request sent (the stale one plus the whole post-wrap batch)
	// remains pending except the single fresh one just resolved above.
	totalSent := 1 + sent
	if got, want := s.pendingCount(), totalSent-1; got != want {
		t.Fatalf("pendingCount = %d, want %d (every sent request still pending except the one just resolved)", got, want)
	}
}

// TestSequencer_ConcurrentSendChecked_NoRace exercises SendChecked from
// many goroutines at once so `go test -race` can catch any data race on
// sequence allocation or the underlying write (poc015 gotcha 9: allocation
// and write must share one mutex, or the server -- which numbers requests
// strictly by arrival order -- and the client's own bookkeeping can
// disagree about which goroutine sent which sequence).
func TestSequencer_ConcurrentSendChecked_NoRace(t *testing.T) {
	s := NewSequencer(io.Discard)

	const goroutines = 50
	const perGoroutine = 200

	seen := make(chan uint64, goroutines*perGoroutine)
	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < perGoroutine; i++ {
				seq, _, err := s.SendChecked([]byte("req"))
				if err != nil {
					t.Errorf("SendChecked: %v", err)
					return
				}
				seen <- seq
			}
		}()
	}
	wg.Wait()
	close(seen)

	unique := make(map[uint64]bool)
	count := 0
	for seq := range seen {
		if unique[seq] {
			t.Fatalf("sequence %d allocated twice -- allocation is not atomic with write", seq)
		}
		unique[seq] = true
		count++
	}
	if count != goroutines*perGoroutine {
		t.Fatalf("got %d sequences, want %d", count, goroutines*perGoroutine)
	}
}
