package x11

import (
	"encoding/binary"
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
