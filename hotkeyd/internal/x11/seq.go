package x11

import (
	"io"
	"sync"
)

// reconstructSeq reconstructs the full sequence number a 16-bit wire value
// refers to, given the highest full sequence number allocated so far
// (lastFull). The X11 wire protocol only carries the low 16 bits of a
// sequence number, and those wrap every 65536 requests. Naively keying
// pending requests by the raw 16-bit value lets a stale entry from an
// earlier generation claim a reply/error that actually belongs to a fresh
// request reusing the same low bits (poc015 gotcha 10).
//
// This always picks the largest full sequence <= lastFull whose low 16
// bits equal wireLow16. That is always the correct match: the server can
// only ever reference a request the client has already sent, so the true
// answer is never in the future relative to lastFull, and is always within
// the most recent 65536 requests (this client never leaves more than
// 65536 requests unresolved at once).
func reconstructSeq(lastFull uint64, wireLow16 uint16) uint64 {
	lastLow := uint16(lastFull)
	diff := lastLow - wireLow16 // uint16 subtraction wraps mod 65536
	return lastFull - uint64(diff)
}

// pendingKind distinguishes what kind of frame a waiter is expecting.
type pendingResult struct {
	isError bool
	reply   []byte // full reply bytes (32 + extra), only if !isError
	xerr    XError // only if isError

	// err is set only by failAll: the connection died before the server
	// answered, so this waiter is being released rather than answered.
	// Distinct from xerr, which is a real X protocol error the server
	// DID send.
	err error
}

// Sequencer allocates X11 request sequence numbers and correlates incoming
// replies/errors back to the goroutine that sent the request. Sequence
// allocation and the socket write happen under ONE mutex (poc015 gotcha 9):
// the server numbers requests by arrival order, so incrementing the
// counter outside the write's critical section would let two concurrent
// senders race and swap identities.
type Sequencer struct {
	w io.Writer

	mu      sync.Mutex
	nextSeq uint64 // next full sequence number to assign; starts at 1
	lastSeq uint64 // most recently assigned full sequence number
	pending map[uint64]chan pendingResult

	// lostErr latches the connection-loss error once failAll has run.
	// Non-nil means no read loop is left to dispatch anything, so a new
	// request must fail here rather than register a waiter nobody will
	// ever answer (dotfiles-83j4).
	lostErr error
}

// NewSequencer creates a Sequencer that writes requests to w.
func NewSequencer(w io.Writer) *Sequencer {
	return &Sequencer{
		w:       w,
		nextSeq: 1,
		pending: make(map[uint64]chan pendingResult),
	}
}

// SendChecked allocates the next sequence number, registers a waiter for
// it, and writes req to the underlying connection -- all under the same
// lock. It returns the full sequence number assigned and a channel that
// will receive exactly one reply or error once the read loop dispatches
// it.
func (s *Sequencer) SendChecked(req []byte) (seq uint64, waiter <-chan pendingResult, err error) {
	ch := make(chan pendingResult, 1)

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.lostErr != nil {
		return 0, nil, s.lostErr
	}

	seq = s.nextSeq
	s.nextSeq++
	s.lastSeq = seq
	s.pending[seq] = ch

	if _, err = s.w.Write(req); err != nil {
		delete(s.pending, seq)
		return seq, nil, err
	}

	return seq, ch, nil
}

// SendUnchecked allocates the next sequence number and writes req, without
// registering a waiter (no reply is expected). Errors from an unchecked
// request are still correlatable via the returned sequence number if the
// caller wants to watch for them separately, but SendUnchecked itself does
// not wait.
func (s *Sequencer) SendUnchecked(req []byte) (seq uint64, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.lostErr != nil {
		return 0, s.lostErr
	}

	seq = s.nextSeq
	s.nextSeq++
	s.lastSeq = seq

	_, err = s.w.Write(req)
	return seq, err
}

// failAll releases every waiting request with err and latches the
// sequencer closed, so requests issued from here on fail immediately
// instead of blocking on a reply no read loop is left to deliver. Called
// once, by the read loop, on its way out (read.go) — the connection is
// gone and nothing it was correlating can ever be answered.
func (s *Sequencer) failAll(err error) {
	s.mu.Lock()
	if s.lostErr == nil {
		s.lostErr = err
	}
	waiters := s.pending
	s.pending = make(map[uint64]chan pendingResult)
	s.mu.Unlock()

	// Every waiter channel is buffered (cap 1) and read at most once, so
	// this cannot block even if the requesting goroutine has already
	// given up.
	for _, ch := range waiters {
		ch <- pendingResult{err: err}
	}
}

// dispatch resolves a wire-level (16-bit) sequence number against the
// current window and delivers the result to the matching waiter, if any.
// It reports whether a waiter was found. Must be called from the read
// loop only.
func (s *Sequencer) dispatch(wireLow16 uint16, result pendingResult) (fullSeq uint64, delivered bool) {
	s.mu.Lock()
	fullSeq = reconstructSeq(s.lastSeq, wireLow16)
	ch, ok := s.pending[fullSeq]
	if ok {
		delete(s.pending, fullSeq)
	}
	s.mu.Unlock()

	if ok {
		if result.isError {
			result.xerr.Seq = fullSeq
		}
		ch <- result
	}
	return fullSeq, ok
}

// pendingCount reports how many requests are still awaiting a reply/error.
// Test-only introspection.
func (s *Sequencer) pendingCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.pending)
}
