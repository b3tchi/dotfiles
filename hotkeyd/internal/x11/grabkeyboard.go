package x11

import (
	"encoding/binary"
	"fmt"
)

// GrabKeyboard/UngrabKeyboard (opcodes 31/32, xproto.xml) are the core
// protocol's ACTIVE keyboard grab -- distinct from every other request this
// package encodes, which are all either connection setup or XI2 PASSIVE
// grabs. Neither hotkeyd's daemon nor any prior sp021 task needed this: the
// daemon only ever registers passive grabs. It exists for exactly one
// caller -- health.go's --health verdict-8 probe (adr0017's "another client
// holds the keyboard"), ported from hotkeyd.py's probe_keyboard_grab, which
// asks the only way X answers the question: try to take the keyboard for
// itself. AlreadyGrabbed means someone else already holds an EXCLUSIVE
// grab; success is released immediately (UngrabKeyboard), since holding it
// would itself be the outage a health probe must not cause.
//
// Deliberately scoped to exactly what the probe needs -- no minor-opcode
// registration table, no owner-events knob beyond a bool param, because
// nothing else in this codebase issues this request.

// Core X11 request opcodes for the active keyboard grab pair.
const (
	opGrabKeyboard   = 31
	opUngrabKeyboard = 32
)

// GrabKeyboard reply status values (xproto.xml GrabStatus enum). Distinct
// names, not a bare bool: InvalidTime/NotViewable/Frozen are "the server
// could not answer the question right now", not "granted" or "denied" --
// health.go's probe treats them as inconclusive (matching hotkeyd.py's
// probe_keyboard_grab: "Silent when it cannot ask at all").
const (
	GrabStatusSuccess        byte = 0
	GrabStatusAlreadyGrabbed byte = 1
	GrabStatusInvalidTime    byte = 2
	GrabStatusNotViewable    byte = 3
	GrabStatusFrozen         byte = 4
)

// EncodeGrabKeyboard builds a core-protocol GrabKeyboard request. time=0
// means CurrentTime (the server substitutes its own clock). pointerMode/
// keyboardMode take the same GrabModeSync/GrabModeAsync values xi2.go
// already names for the paired_device_mode field -- the core protocol's
// GrabMode enum and XI2's share the same two numeric values (0/1).
func EncodeGrabKeyboard(ownerEvents bool, grabWindow, t uint32, pointerMode, keyboardMode byte) []byte {
	buf := make([]byte, 16)
	putRequestHeader(buf, opGrabKeyboard, boolByte(ownerEvents))
	binary.LittleEndian.PutUint32(buf[4:8], grabWindow)
	binary.LittleEndian.PutUint32(buf[8:12], t)
	buf[12] = pointerMode
	buf[13] = keyboardMode
	// buf[14:16] unused
	return buf
}

// DecodeGrabKeyboardReply decodes a GrabKeyboard reply's status byte.
func DecodeGrabKeyboardReply(reply []byte) (byte, error) {
	if len(reply) < 2 {
		return 0, fmt.Errorf("x11: GrabKeyboard reply too short: %d bytes", len(reply))
	}
	return reply[1], nil
}

// GrabKeyboard attempts to take an EXCLUSIVE active grab of the keyboard on
// grabWindow, with owner-events=true and both modes Async (matching
// hotkeyd.py's `grab_keyboard(True, X.GrabModeAsync, X.GrabModeAsync,
// X.CurrentTime)`) -- the shape health.go's verdict-8 probe needs and the
// only shape this package exposes.
func (c *Conn) GrabKeyboard(grabWindow uint32) (byte, error) {
	reply, err := c.doRequest(EncodeGrabKeyboard(true, grabWindow, 0, GrabModeAsync, GrabModeAsync))
	if err != nil {
		return 0, err
	}
	return DecodeGrabKeyboardReply(reply)
}

// EncodeUngrabKeyboard builds a core-protocol UngrabKeyboard request. This
// request has no reply on the wire (like XIPassiveUngrabDevice -- see
// (*Conn).UngrabKeyboard's SendUnchecked use).
func EncodeUngrabKeyboard(t uint32) []byte {
	buf := make([]byte, 8)
	putRequestHeader(buf, opUngrabKeyboard, 0)
	binary.LittleEndian.PutUint32(buf[4:8], t)
	return buf
}

// UngrabKeyboard releases an active keyboard grab this connection holds.
// time=0 means CurrentTime.
func (c *Conn) UngrabKeyboard(t uint32) error {
	_, err := c.seq.SendUnchecked(EncodeUngrabKeyboard(t))
	return err
}
