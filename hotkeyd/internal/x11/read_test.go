package x11

import (
	"encoding/binary"
	"errors"
	"io"
	"testing"
	"time"
)

// buildErrorFrame builds a 32-byte X Error frame.
func buildErrorFrame(code byte, seq uint16, badValue uint32, minorOp uint16, majorOp byte) []byte {
	buf := make([]byte, 32)
	buf[0] = 0 // Error
	buf[1] = code
	binary.LittleEndian.PutUint16(buf[2:4], seq)
	binary.LittleEndian.PutUint32(buf[4:8], badValue)
	binary.LittleEndian.PutUint16(buf[8:10], minorOp)
	buf[10] = majorOp
	return buf
}

// buildReplyFrame builds a Reply frame: 32-byte header plus extraUnits*4
// bytes of additional data.
func buildReplyFrame(seq uint16, extraUnits uint32, fill byte) []byte {
	buf := make([]byte, 32+int(extraUnits)*4)
	buf[0] = 1 // Reply
	buf[1] = 0
	binary.LittleEndian.PutUint16(buf[2:4], seq)
	binary.LittleEndian.PutUint32(buf[4:8], extraUnits)
	for i := 32; i < len(buf); i++ {
		buf[i] = fill
	}
	return buf
}

// buildGenericEventFrame builds a GenericEvent (code 35) frame: 32-byte
// header plus lengthUnits*4 bytes of extra payload -- the exact shape
// poc014 found stock xgb silently dropped.
func buildGenericEventFrame(seq uint16, extOpcode byte, evtype uint16, lengthUnits uint32, fill byte) []byte {
	buf := make([]byte, 32+int(lengthUnits)*4)
	buf[0] = 35 // GenericEvent
	buf[1] = extOpcode
	binary.LittleEndian.PutUint16(buf[2:4], seq)
	binary.LittleEndian.PutUint32(buf[4:8], lengthUnits)
	binary.LittleEndian.PutUint16(buf[8:10], evtype)
	for i := 32; i < len(buf); i++ {
		buf[i] = fill
	}
	return buf
}

// buildNormalEventFrame builds a fixed-size (32 byte) core event frame.
func buildNormalEventFrame(code byte, seq uint16) []byte {
	buf := make([]byte, 32)
	buf[0] = code
	binary.LittleEndian.PutUint16(buf[2:4], seq)
	return buf
}

func TestConn_ReadLoop_ReplyWithExtraDataDeliveredToWaiter(t *testing.T) {
	pr, pw := io.Pipe()
	c := newTestConn(pr)

	waiterSeq, waiter, err := c.seq.SendChecked([]byte("request-1"))
	if err != nil {
		t.Fatalf("SendChecked: %v", err)
	}
	if waiterSeq != 1 {
		t.Fatalf("first sequence = %d, want 1", waiterSeq)
	}

	go c.readLoop()

	frame := buildReplyFrame(uint16(waiterSeq), 3, 0xAB) // 32 + 12 extra bytes
	if _, err := pw.Write(frame); err != nil {
		t.Fatalf("write frame: %v", err)
	}

	select {
	case res := <-waiter:
		if res.isError {
			t.Fatalf("got error result, want reply: %+v", res.xerr)
		}
		if len(res.reply) != 44 {
			t.Fatalf("reply length = %d, want 44 (32 + 3*4)", len(res.reply))
		}
		if res.reply[32] != 0xAB {
			t.Errorf("extra data not delivered: reply[32] = %#x, want 0xAB", res.reply[32])
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for reply")
	}
	pw.Close()
}

func TestConn_ReadLoop_ErrorDeliveredToWaiter(t *testing.T) {
	pr, pw := io.Pipe()
	c := newTestConn(pr)

	seq, waiter, err := c.seq.SendChecked([]byte("request-1"))
	if err != nil {
		t.Fatalf("SendChecked: %v", err)
	}

	go c.readLoop()

	frame := buildErrorFrame(9 /* BadValue */, uint16(seq), 0xdeadbeef, 47, 131)
	if _, err := pw.Write(frame); err != nil {
		t.Fatalf("write frame: %v", err)
	}

	select {
	case res := <-waiter:
		if !res.isError {
			t.Fatal("got reply result, want error")
		}
		if res.xerr.Code != 9 {
			t.Errorf("Code = %d, want 9", res.xerr.Code)
		}
		if res.xerr.BadValue != 0xdeadbeef {
			t.Errorf("BadValue = %#x, want 0xdeadbeef", res.xerr.BadValue)
		}
		if res.xerr.MinorOpcode != 47 || res.xerr.MajorOpcode != 131 {
			t.Errorf("opcode = %d/%d, want 131/47", res.xerr.MajorOpcode, res.xerr.MinorOpcode)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for error")
	}
	pw.Close()
}

func TestConn_ReadLoop_GenericEventReadsLengthTimes4Payload(t *testing.T) {
	pr, pw := io.Pipe()
	c := newTestConn(pr)
	go c.readLoop()

	// 120-byte GenericEvent measured in poc014/poc015 -- 32 header + 88
	// extra bytes = 22 units of 4 bytes.
	frame := buildGenericEventFrame(9, 131, 2, 22, 0xCD)
	if len(frame) != 120 {
		t.Fatalf("test fixture bug: frame is %d bytes, want 120", len(frame))
	}

	go func() {
		pw.Write(frame)
	}()

	select {
	case ev := <-c.Events:
		if len(ev.Raw) != 120 {
			t.Fatalf("event raw length = %d, want 120 (the poc014 stock-xgb bug reads only 32)", len(ev.Raw))
		}
		if ev.Raw[119] != 0xCD {
			t.Errorf("last payload byte = %#x, want 0xCD -- extra payload truncated", ev.Raw[119])
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for GenericEvent")
	}
	pw.Close()
}

func TestConn_ReadLoop_NormalEventIsFixed32Bytes(t *testing.T) {
	pr, pw := io.Pipe()
	c := newTestConn(pr)
	go c.readLoop()

	frame := buildNormalEventFrame(12 /* Expose */, 5)
	go func() {
		pw.Write(frame)
	}()

	select {
	case ev := <-c.Events:
		if len(ev.Raw) != 32 {
			t.Fatalf("event raw length = %d, want 32", len(ev.Raw))
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for event")
	}
	pw.Close()
}

// ---------------------------------------------------------------------
// Connection loss (dotfiles-83j4). The X server dying mid-run is a FATAL,
// OBSERVABLE event for every consumer of a Conn, not a quiet stop:
//
//   - the event stream must CLOSE, because a receive on a channel that is
//     merely idle is indistinguishable from "no keys pressed yet" — that
//     is exactly why the Go daemon outlived its dead Xvfb by >30s while
//     hotkeyd.py exited in ~1s (adr0014 fail-fast),
//   - every checked request already in flight must FAIL, because its
//     reply can never arrive and `res := <-waiter` would otherwise block
//     that goroutine forever,
//   - and requests issued AFTER the loss must fail immediately rather
//     than registering a waiter no read loop is left to answer.
// ---------------------------------------------------------------------

func TestConn_ReadLoop_ConnectionLost_ClosesEventsChannel(t *testing.T) {
	pr, pw := io.Pipe()
	c := newTestConn(pr)
	go c.readLoop()

	// The X server dies: its end of the socket goes away, so the read
	// loop's next ReadFull returns EOF.
	pw.Close()

	select {
	case _, ok := <-c.Events:
		if ok {
			t.Fatal("Events delivered a value after the connection died; want the channel CLOSED")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Events was still open 2s after the connection died — a consumer selecting on it " +
			"cannot tell a dead X server from an idle one, so the daemon never fails fast (dotfiles-83j4)")
	}
}

func TestConn_ReadLoop_ConnectionLost_FailsPendingCheckedRequest(t *testing.T) {
	pr, pw := io.Pipe()
	c := newTestConn(pr)
	go c.readLoop()

	// A checked request goes out and is waiting on a reply that the
	// server, about to die, will never send.
	type result struct {
		reply []byte
		err   error
	}
	res := make(chan result, 1)
	go func() {
		reply, err := c.doRequest(make([]byte, 4))
		res <- result{reply, err}
	}()

	// Wait for the waiter to actually be registered, so this test cannot
	// pass by racing the request in AFTER the read loop already ended
	// (which is the separate "issued after the loss" case below).
	deadline := time.Now().Add(2 * time.Second)
	for c.seq.pendingCount() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the checked request never registered a waiter")
		}
		time.Sleep(time.Millisecond)
	}

	pw.Close()

	select {
	case got := <-res:
		if got.err == nil {
			t.Fatalf("doRequest returned reply=%v err=nil after the connection died; want a named error", got.reply)
		}
		if !errors.Is(got.err, ErrConnLost) {
			t.Fatalf("doRequest error = %v; want one matching ErrConnLost", got.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a checked request in flight when the connection died never returned — " +
			"it is blocked forever on a reply the dead server cannot send (dotfiles-83j4)")
	}
}

func TestConn_RequestAfterConnectionLost_FailsImmediatelyNotHangs(t *testing.T) {
	pr, pw := io.Pipe()
	c := newTestConn(pr)
	go c.readLoop()

	pw.Close()
	<-c.done // the read loop has ended; nothing will dispatch replies now

	res := make(chan error, 1)
	go func() {
		_, err := c.doRequest(make([]byte, 4))
		res <- err
	}()

	select {
	case err := <-res:
		if !errors.Is(err, ErrConnLost) {
			t.Fatalf("doRequest error = %v; want one matching ErrConnLost", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a request issued after the connection died never returned — the sequencer " +
			"registered a waiter no read loop is left to answer (dotfiles-83j4)")
	}
}

// newTestConn builds a Conn over a discard writer and the given reader,
// for read-loop-focused tests that don't care what bytes get written.
func newTestConn(r io.Reader) *Conn {
	return &Conn{
		r:      r,
		seq:    NewSequencer(io.Discard),
		Events: make(chan Event, 16),
		done:   make(chan struct{}),
	}
}
