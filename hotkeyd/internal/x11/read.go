package x11

import (
	"encoding/binary"
	"fmt"
	"io"
)

// XError is a decoded X Error frame, correlated back to the request that
// caused it via Seq (the reconstructed full sequence number, not the raw
// 16-bit wire value).
type XError struct {
	Seq         uint64
	Code        byte
	BadValue    uint32
	MinorOpcode uint16
	MajorOpcode byte
}

func (e XError) Error() string {
	return fmt.Sprintf("x11: error code=%d seq=%d bad_value=%#x major=%d minor=%d",
		e.Code, e.Seq, e.BadValue, e.MajorOpcode, e.MinorOpcode)
}

// Event is a decoded X event, core or GenericEvent, delivered with its
// full raw wire bytes -- 32 bytes for a core event, 32+length*4 for a
// GenericEvent (poc014's stock-xgb bug: reading only the fixed 32 bytes
// silently desyncs the stream for every subsequent frame).
type Event struct {
	Code byte // low 7 bits of the first frame byte; bit 7 is the SendEvent flag
	Sent bool // SendEvent flag (bit 7 of the first byte)
	Raw  []byte
}

const genericEventCode = 35

// Conn is a live X11 connection: the transport (dial + auth + handshake)
// plus the sequencer and read loop that keep requests correlated to their
// replies/errors and events flowing to consumers.
type Conn struct {
	r      io.Reader
	w      io.Writer
	closer io.Closer

	seq    *Sequencer
	Events chan Event

	done    chan struct{}
	readErr error
}

// readLoop reads frames from the connection until it hits an error or the
// connection closes, dispatching replies/errors to their waiters via seq
// and events to the Events channel. Run this in its own goroutine.
func (c *Conn) readLoop() {
	defer close(c.done)

	for {
		frame, err := readFrame(c.r)
		if err != nil {
			c.readErr = err
			return
		}

		switch {
		case frame[0] == 0: // Error
			wireSeq := binary.LittleEndian.Uint16(frame[2:4])
			xerr := XError{
				Code:        frame[1],
				BadValue:    binary.LittleEndian.Uint32(frame[4:8]),
				MinorOpcode: binary.LittleEndian.Uint16(frame[8:10]),
				MajorOpcode: frame[10],
			}
			_, delivered := c.seq.dispatch(wireSeq, pendingResult{isError: true, xerr: xerr})
			if !delivered {
				// No checked request is waiting on this error (it came
				// from an unchecked request, or the waiter already gave
				// up). Surface it as an event-shaped notification rather
				// than dropping it silently.
				c.Events <- Event{Code: 0, Raw: frame}
			}

		case frame[0] == 1: // Reply
			wireSeq := binary.LittleEndian.Uint16(frame[2:4])
			c.seq.dispatch(wireSeq, pendingResult{isError: false, reply: frame})

		default: // Event, including GenericEvent
			code := frame[0] &^ 0x80
			sent := frame[0]&0x80 != 0
			c.Events <- Event{Code: code, Sent: sent, Raw: frame}
		}
	}
}

// readFrame reads one complete X11 wire frame: the fixed 32-byte base
// packet, extended for Replies and GenericEvents by the length field at
// offset 4 (CARD32, counted in 4-byte units) -- poc014's core fix, since
// stock xgb reads only the fixed 32 bytes and silently desyncs the stream
// on the first GenericEvent.
func readFrame(r io.Reader) ([]byte, error) {
	base := make([]byte, 32)
	if _, err := io.ReadFull(r, base); err != nil {
		return nil, err
	}

	kind := base[0]
	needsExtra := kind == 1 || kind == genericEventCode || (kind&^0x80) == genericEventCode
	if !needsExtra {
		return base, nil
	}

	extraUnits := binary.LittleEndian.Uint32(base[4:8])
	if extraUnits == 0 {
		return base, nil
	}

	frame := make([]byte, 32+int(extraUnits)*4)
	copy(frame, base)
	if _, err := io.ReadFull(r, frame[32:]); err != nil {
		return nil, fmt.Errorf("x11: reading %d extra bytes for frame kind %d: %w", extraUnits*4, kind, err)
	}
	return frame, nil
}
