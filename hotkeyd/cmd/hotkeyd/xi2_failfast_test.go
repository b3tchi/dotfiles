// xi2_failfast_test.go — the Go engine's answer to hotkeyd.py's stage-13
// process-level claim: "a display without XI2 is refused by name, exit
// non-zero, no stack trace, nothing left behind" (test-hotkeyd.sh, python
// arm).
//
// WHY THIS FILE EXISTS. The python suite manufactures an XI2-less display
// by monkeypatching python-xlib inside the daemon's own interpreter. A
// compiled binary has no such hook, and no real server on this box can be
// made to present XI2 as absent (Xvfb answers `-extension XInputExtension`
// with "can not be disabled", measured in dotfiles-ylmp.15). So the parity
// gate's go arm ran `go test -run TestRequireXI2` instead — four unit tests
// over the *helper*, which between them never touch exitXI2Unavailable.
// `grep exitXI2Unavailable *_test.go` returned nothing: the daemon's
// fail-fast *behaviour* — the thing hotkeyd.py's stage 13 actually measures
// — was NOT_MEASURED on go (audit gap 2, dotfiles-ylmp.15).
//
// The equivalent hook for a compiled binary is one level down: not inside
// the process, but on the wire. These tests stand up a FAKE X SERVER that
// completes a real connection-setup handshake and then answers
// QueryExtension("XInputExtension") with present=0 — which is exactly what
// a server without XI2 does — and drive the real Dispatch()/run() against
// it. That reaches the same code path the python shim reaches, and pins the
// same five observable facts.
//
// The A/B is what makes it evidence rather than decoration: the SAME fake
// server with the present bit FLIPPED ON walks straight past the gate and
// grabs chords (TestRun_XI2Present_PassesTheGate), and a display with no
// server at all fails with a DIFFERENT, non-XI2 verdict
// (TestRun_XI2NoServerAtAll_...). Exit 5 is therefore the XI2 verdict
// specifically, not a generic startup failure the fake happens to provoke.
//
// Displays are abstract-namespace sockets in the :700+ range: nothing is
// created under /tmp/.X11-unix, so a concurrent shell suite's
// probe_free_display() cannot collide with these and these cannot outlive
// the process.
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"math/rand"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/x11"
)

// fakeXIMajorOpcode is the major opcode this fake server hands out for
// XInputExtension when it claims to have one. Any value works; 130 is what
// a stock Xorg tends to assign, which keeps hexdumps recognizable.
const fakeXIMajorOpcode = 130

// xiMinorQueryVersionWire is XIQueryVersion's minor opcode on the wire
// (x11's own constant is unexported; this is the same number, kept local so
// a drift in either place shows up as a hung fake rather than silently
// agreeing).
const xiMinorQueryVersionWire = 47

// fakeXOpts configures what the fake server claims about XI2.
type fakeXOpts struct {
	// present is the QueryExtension("XInputExtension") present bit — the
	// ONE byte that separates the two headline tests below.
	present bool
	// verMajor/verMinor answer XIQueryVersion (only reachable when
	// present is true).
	verMajor, verMinor uint16
	// hangUpAfterXI2 closes the connection once the XI2 negotiation is
	// done, so the control case terminates instead of running a daemon
	// against a fake server that cannot serve one.
	hangUpAfterXI2 bool
}

func fakePad4(n int) int { return (4 - n%4) % 4 }

// pickFreeDisplayNum returns a display number in :700-:979 with neither a
// filesystem-namespace nor an abstract-namespace socket already answering.
func pickFreeDisplayNum(t *testing.T) int {
	t.Helper()
	for i := 0; i < 200; i++ {
		n := 700 + rand.Intn(280)
		if _, err := os.Stat(x11.SocketPath(n)); err == nil {
			continue
		}
		if c, err := net.Dial("unix", "@"+x11.SocketPath(n)); err == nil {
			c.Close()
			continue
		}
		return n
	}
	t.Fatal("no free display number in :700-:979 for the fake X server")
	return 0
}

// startFakeXServer binds an abstract-namespace X socket and serves the
// handshake plus whatever XI2 answer o asks for. It returns the $DISPLAY
// string to point the daemon at.
func startFakeXServer(t *testing.T, o fakeXOpts) string {
	t.Helper()
	n := pickFreeDisplayNum(t)
	ln, err := net.Listen("unix", "@"+x11.SocketPath(n))
	if err != nil {
		t.Fatalf("fake X server: listen on abstract %s: %v", x11.SocketPath(n), err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			// One goroutine per connection: run() opens a SECOND
			// connection for the foreign-grab probe once it is past the
			// XI2 gate.
			go serveFakeX(c, o)
		}
	}()
	return fmt.Sprintf(":%d", n)
}

// serveFakeX speaks just enough of the X11 wire protocol to get a client
// through Open() and one QueryExtension. Every other request is answered
// with a correlated X Error, never silence — a fake that simply ignored a
// request would turn a failed assertion into a hung test.
func serveFakeX(c net.Conn, o fakeXOpts) {
	defer c.Close()

	var hdr [12]byte
	if _, err := io.ReadFull(c, hdr[:]); err != nil {
		return
	}
	nameLen := int(binary.LittleEndian.Uint16(hdr[6:8]))
	dataLen := int(binary.LittleEndian.Uint16(hdr[8:10]))
	rest := make([]byte, nameLen+fakePad4(nameLen)+dataLen+fakePad4(dataLen))
	if _, err := io.ReadFull(c, rest); err != nil {
		return
	}
	if _, err := c.Write(fakeSetupSuccess()); err != nil {
		return
	}

	var seq uint16
	for {
		var rh [4]byte
		if _, err := io.ReadFull(c, rh[:]); err != nil {
			return
		}
		units := int(binary.LittleEndian.Uint16(rh[2:4]))
		if units < 1 {
			return
		}
		if _, err := io.ReadFull(c, make([]byte, (units-1)*4)); err != nil {
			return
		}
		seq++

		reply := make([]byte, 32)
		reply[0] = 1
		binary.LittleEndian.PutUint16(reply[2:4], seq)

		switch {
		case rh[0] == 98: // QueryExtension
			if o.present {
				reply[8] = 1
				reply[9] = fakeXIMajorOpcode
			}
			if _, err := c.Write(reply); err != nil {
				return
			}
		case rh[0] == fakeXIMajorOpcode && rh[1] == xiMinorQueryVersionWire:
			binary.LittleEndian.PutUint16(reply[8:10], o.verMajor)
			binary.LittleEndian.PutUint16(reply[10:12], o.verMinor)
			if _, err := c.Write(reply); err != nil {
				return
			}
			if o.hangUpAfterXI2 {
				return
			}
		default:
			xerr := make([]byte, 32)
			xerr[0] = 0
			xerr[1] = 17 // BadImplementation
			binary.LittleEndian.PutUint16(xerr[2:4], seq)
			xerr[10] = rh[0]
			if _, err := c.Write(xerr); err != nil {
				return
			}
		}
	}
}

// fakeSetupSuccess builds a minimal Success connection-setup response: one
// screen, no pixmap formats, no depths, empty vendor. The screen walk has
// to land exactly on the declared length or ParseSetupResponse refuses it
// (ErrScreenWalkMismatch), so a mistake here fails loudly rather than
// producing a client that limps.
func fakeSetupSuccess() []byte {
	const bodyLen = 32 + 40 // fixed fields + one SCREEN with zero depths
	body := make([]byte, bodyLen)

	binary.LittleEndian.PutUint32(body[0:], 12345)    // release number
	binary.LittleEndian.PutUint32(body[4:], 0x400000) // resource-id-base
	binary.LittleEndian.PutUint32(body[8:], 0x1fffff) // resource-id-mask
	binary.LittleEndian.PutUint32(body[12:], 256)     // motion buffer size
	binary.LittleEndian.PutUint16(body[16:], 0)       // vendor length
	binary.LittleEndian.PutUint16(body[18:], 65535)   // max request length
	body[20] = 1                                      // number of screens
	body[21] = 0                                      // number of pixmap formats
	body[22] = 0                                      // image byte order
	body[23] = 0                                      // bitmap format bit order
	body[24] = 32                                     // scanline unit
	body[25] = 32                                     // scanline pad
	body[26] = 8                                      // min keycode
	body[27] = 255                                    // max keycode

	binary.LittleEndian.PutUint32(body[32:], 0x100) // root window
	binary.LittleEndian.PutUint16(body[52:], 640)   // width in pixels
	binary.LittleEndian.PutUint16(body[54:], 480)   // height in pixels
	binary.LittleEndian.PutUint32(body[64:], 0x21)  // root visual
	body[70] = 24                                   // root depth
	body[71] = 0                                    // number of depths

	out := make([]byte, 8+len(body))
	out[0] = 1 // Success
	binary.LittleEndian.PutUint16(out[2:4], 11)
	binary.LittleEndian.PutUint16(out[4:6], 0)
	binary.LittleEndian.PutUint16(out[6:8], uint16(len(body)/4))
	copy(out[8:], body)
	return out
}

// runDispatchCaptured runs Dispatch(argv) with os.Stderr redirected, under
// a deadline. A daemon that HANGS on a display it cannot serve is a
// distinct failure from one that exits wrong, and hotkeyd.py's stage 13
// distinguishes them (rc 124); so does this.
func runDispatchCaptured(t *testing.T, argv []string, limit time.Duration) (int, string) {
	t.Helper()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	old := os.Stderr
	os.Stderr = w

	var sb strings.Builder
	drained := make(chan struct{})
	go func() {
		io.Copy(&sb, r)
		close(drained)
	}()

	codes := make(chan int, 1)
	go func() { codes <- Dispatch(argv) }()

	var code int
	timedOut := false
	select {
	case code = <-codes:
	case <-time.After(limit):
		timedOut = true
	}

	os.Stderr = old
	w.Close()
	<-drained
	r.Close()

	if timedOut {
		t.Fatalf("Dispatch(%v) HUNG for %s — stderr so far: %s", argv, limit, sb.String())
	}
	return code, sb.String()
}

// TestRun_XI2Absent_ExitsFiveByName is the go engine's replacement for
// hotkeyd.py's stage-13 process claims, one assertion per python assertion.
func TestRun_XI2Absent_ExitsFiveByName(t *testing.T) {
	rt := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", rt)
	t.Setenv("HOTKEYD_I3SOCK", filepath.Join(rt, "no-i3.sock"))
	dpy := startFakeXServer(t, fakeXOpts{present: false})

	code, out := runDispatchCaptured(t, []string{"--display", dpy}, 20*time.Second)

	// py: "exits non-zero on a display without XI2" — and specifically the
	// NAMED code, not the generic 1, and not exitAlreadyRunning.
	if code != exitXI2Unavailable {
		t.Fatalf("Dispatch on an XI2-less display = %d, want exitXI2Unavailable (%d); stderr: %s",
			code, exitXI2Unavailable, out)
	}
	if exitXI2Unavailable == 0 || exitXI2Unavailable == 1 || exitXI2Unavailable == exitAlreadyRunning {
		t.Fatalf("exitXI2Unavailable (%d) is not distinct from the generic/already-running codes",
			exitXI2Unavailable)
	}
	// py: "the message names XI2"
	if !strings.Contains(out, "XI2 unavailable") {
		t.Errorf("no 'XI2 unavailable' in the output: %s", out)
	}
	// py: "and names the missing extension"
	if !strings.Contains(out, "XInputExtension") {
		t.Errorf("does not name the extension: %s", out)
	}
	// py: "no stack trace" — a named refusal, not a crash.
	if strings.Contains(out, "panic:") || strings.Contains(out, "goroutine ") {
		t.Errorf("failed with a stack trace instead of a named error: %s", out)
	}
	// py: "left no state socket behind" — the XI2 probe runs BEFORE the
	// lock and the publisher, so the whole runtime dir must still be
	// empty.
	entries, err := os.ReadDir(rt)
	if err != nil {
		t.Fatalf("reading %s: %v", rt, err)
	}
	if len(entries) != 0 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("refusing to start left %v behind in XDG_RUNTIME_DIR", names)
	}
}

// TestRun_XI2Present_PassesTheGate is the control the assertion above is
// worthless without: the SAME fake server, the SAME code path, one byte
// different. If the daemon refused every display this fake serves — for
// any of the dozen reasons a hand-rolled X server might be inadequate —
// the test above would pass for the wrong reason.
func TestRun_XI2Present_PassesTheGate(t *testing.T) {
	rt := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", rt)
	t.Setenv("HOTKEYD_I3SOCK", filepath.Join(rt, "no-i3.sock"))
	dpy := startFakeXServer(t, fakeXOpts{
		present: true, verMajor: 2, verMinor: 3, hangUpAfterXI2: true,
	})

	code, out := runDispatchCaptured(t, []string{"--display", dpy}, 20*time.Second)

	if code == exitXI2Unavailable {
		t.Fatalf("an XI2-2.3 display was still refused with exitXI2Unavailable; stderr: %s", out)
	}
	if strings.Contains(out, "XI2 unavailable") {
		t.Errorf("the XI2 verdict fired on a display that HAS XI2: %s", out)
	}
	// Past the gate for real: startup only reaches the grab report after
	// the lock, the mod resolve and table validation have all run.
	if !strings.Contains(out, "chords grabbed on "+dpy) {
		t.Errorf("startup did not reach the grab report, so 'past the gate' is unproven: %s", out)
	}
}

// TestRun_XI2NoServerAtAll_DoesNotReportXI2 pins the other side: exit 5 is
// the XI2 verdict specifically. A display with nothing listening must fail
// differently, or "exit 5" would just mean "startup went wrong somehow".
func TestRun_XI2NoServerAtAll_DoesNotReportXI2(t *testing.T) {
	rt := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", rt)
	t.Setenv("HOTKEYD_I3SOCK", filepath.Join(rt, "no-i3.sock"))
	dpy := fmt.Sprintf(":%d", pickFreeDisplayNum(t))

	code, out := runDispatchCaptured(t, []string{"--display", dpy}, 20*time.Second)

	if code == exitXI2Unavailable {
		t.Fatalf("a display with NO server reported exitXI2Unavailable; stderr: %s", out)
	}
	if code == 0 {
		t.Fatalf("a display with NO server reported success; stderr: %s", out)
	}
	if !strings.Contains(out, "cannot open display") {
		t.Errorf("the failure is not named as a connection failure: %s", out)
	}
}
