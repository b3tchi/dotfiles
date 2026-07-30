package main

import (
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"hotkeyd/internal/x11"
)

// X11 core modifier mask bits, by the names the bind table spells them with.
// Named here rather than imported because cmd/hotkeyd's maskByModifier lives
// in package main.
const (
	maskShift uint32 = 0x01
	maskMod1  uint32 = 0x08
	maskMod4  uint32 = 0x40
)

// Rig is livecheck's own X client: a real connection, over the real
// internal/x11 the daemon itself uses, with the same XI2 grab request. It is
// the "REAL adapter, not a copy of it" that live_check.py insists on — the
// grab mechanism under test is x11.XIPassiveGrabDevice either way.
type Rig struct {
	Display string
	Conn    *x11.Conn
	Info    *x11.SetupInfo
	Ext     x11.ExtensionInfo
	Root    uint32
	Mapping x11.KeyboardMapping

	held map[string][]uint32 // chord label -> modifier variants currently grabbed
	code map[string]byte     // chord label -> keycode currently grabbed
}

// OpenRig connects to display, probes XI2, and reads the keymap.
func OpenRig(display string) (*Rig, error) {
	conn, info, err := x11.Open(display)
	if err != nil {
		return nil, fmt.Errorf("livecheck: cannot open %s: %w", display, err)
	}
	if len(info.Screens) == 0 {
		conn.Close()
		return nil, fmt.Errorf("livecheck: %s: setup response has no screens", display)
	}
	ext, err := conn.QueryExtension("XInputExtension")
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("livecheck: QueryExtension: %w", err)
	}
	r := &Rig{
		Display: display, Conn: conn, Info: info, Ext: ext,
		Root: info.Screens[0].Root,
		held: map[string][]uint32{}, code: map[string]byte{},
	}
	if err := r.ReloadKeymap(); err != nil {
		conn.Close()
		return nil, err
	}
	return r, nil
}

// ReloadKeymap re-reads the whole keymap off the server. Called again after
// any keymap change, because every keycode this tool uses is resolved from
// it at runtime.
func (r *Rig) ReloadKeymap() error {
	count := int(r.Info.MaxKeycode) - int(r.Info.MinKeycode) + 1
	if count <= 0 || count > 255 {
		return fmt.Errorf("livecheck: implausible keycode range %d..%d", r.Info.MinKeycode, r.Info.MaxKeycode)
	}
	m, err := r.Conn.GetKeyboardMapping(r.Info.MinKeycode, byte(count))
	if err != nil {
		return fmt.Errorf("livecheck: GetKeyboardMapping: %w", err)
	}
	r.Mapping = m
	return nil
}

func (r *Rig) Close() {
	for label := range r.held {
		_ = r.Ungrab(label)
	}
	r.Conn.Close()
}

// Keycode resolves a keysym name against the CURRENT keymap.
func (r *Rig) Keycode(name string) (byte, error) { return keycodeFor(r.Mapping, name) }

// Grab takes a passive XI2 keycode grab on key+mask, registering the same
// four lock-bit variants the daemon's GrabManager does (x11's
// GrabModifierVariants). label is how this tool refers to the grab later.
//
// Returns the GrabResult: an EMPTY Failed list means the server gave us
// every variant, and a non-empty one is the refusal another XI2 grabber's
// prior claim produces.
func (r *Rig) Grab(label, key string, mask uint32) (x11.GrabResult, error) {
	code, err := r.Keycode(key)
	if err != nil {
		return x11.GrabResult{}, err
	}
	mods := x11.GrabModifierVariants(mask)
	res, err := r.Conn.XIPassiveGrabDevice(r.Ext.MajorOpcode, r.Root, x11.DeviceAllMaster,
		uint32(code), mods, []uint32{x11.XIEventMaskKeyPress | x11.XIEventMaskKeyRelease})
	if err != nil {
		return res, err
	}
	if len(res.Failed) < len(mods) {
		// Even a partial success holds something: record it so Ungrab
		// hands every variant back and this tool never leaves a grab on
		// the rig for the daemon to trip over.
		r.held[label] = mods
		r.code[label] = code
	}
	return res, nil
}

// Ungrab releases a grab taken by Grab.
func (r *Rig) Ungrab(label string) error {
	mods, ok := r.held[label]
	if !ok {
		return nil
	}
	err := r.Conn.XIPassiveUngrabDevice(r.Ext.MajorOpcode, r.Root, x11.DeviceAllMaster, uint32(r.code[label]), mods)
	delete(r.held, label)
	delete(r.code, label)
	return err
}

// ProbeOwned answers "does somebody ELSE already hold a passive XI2 grab on
// this chord?" by trying to take it and immediately handing it back.
//
// This is the out-of-process instrument for every "the daemon grabbed X"
// claim. live_check.py reads the daemon's own chord set, which only proves
// what it REQUESTED; two X clients cannot hold a passive grab on one chord,
// so a refusal here is the server itself confirming the daemon OBTAINED it —
// a strictly stronger claim than the in-process one, and the same
// discriminator live_check.py:342 reaches for when it insists on "OBTAINED,
// not merely requested".
//
// Note the direction of the evidence: refused => somebody owns it; granted
// => nobody did, and we just gave it straight back.
func (r *Rig) ProbeOwned(key string, mask uint32) (owned bool, detail string, err error) {
	const label = "__probe__"
	res, err := r.Grab(label, key, mask)
	if err != nil {
		return false, "", err
	}
	defer func() { _ = r.Ungrab(label) }()

	if len(res.Failed) == 0 {
		return false, "granted every modifier variant — nobody held it", nil
	}
	codes := make([]string, 0, len(res.Failed))
	for _, f := range res.Failed {
		codes = append(codes, fmt.Sprintf("mods=%#x status=%d", f.Modifiers, f.Status))
	}
	sort.Strings(codes)
	return true, "refused: " + strings.Join(codes, ", "), nil
}

// KeyEvent is one XI2 key event livecheck's own grab received.
type KeyEvent struct {
	Press    bool
	Keycode  byte
	Time     uint32
	SourceID uint16
	DeviceID uint16
	Repeat   bool
}

// Drain collects every XI2 key event delivered within d.
func (r *Rig) Drain(d time.Duration) []KeyEvent {
	var out []KeyEvent
	deadline := time.After(d)
	for {
		select {
		case ev, ok := <-r.Conn.Events:
			if !ok {
				return out
			}
			if ev.Code != 35 { // GenericEvent
				continue
			}
			de, err := x11.ParseDeviceEvent(ev.Raw)
			if err != nil {
				continue
			}
			if de.EventType != 2 && de.EventType != 3 {
				continue
			}
			out = append(out, KeyEvent{
				Press: de.EventType == 2, Keycode: byte(de.Detail), Time: de.Time,
				SourceID: de.SourceID, DeviceID: de.DeviceID, Repeat: de.Repeat,
			})
		case <-deadline:
			return out
		}
	}
}

// Presses counts press events for a keycode within a drained slice.
func Presses(evs []KeyEvent, code byte) int {
	n := 0
	for _, e := range evs {
		if e.Press && e.Keycode == code {
			n++
		}
	}
	return n
}

// DeviceNames reads the display's XI2 device inventory.
func (r *Rig) DeviceNames() (map[uint16]string, error) {
	devs, err := r.Conn.XIQueryDevice(r.Ext.MajorOpcode, x11.DeviceAll)
	if err != nil {
		return nil, err
	}
	out := make(map[uint16]string, len(devs))
	for _, d := range devs {
		out[d.DeviceID] = d.Name
	}
	return out, nil
}

// -- injection --------------------------------------------------------------

// Injector drives real key events into the rig through XTEST, using
// xdotool.
//
// # Why xdotool and not a hand-rolled XTEST request
//
// internal/x11 owns only the requests the DAEMON needs (its package doc says
// so), and XTEST FakeInput is not one of them. Adding it would grow the
// production package for a test tool's benefit. xdotool is already a build
// dependency of this repo's i3 layer, speaks the same XTEST extension
// python-xlib's fake_input does, and produces events attributed to exactly
// the same "Virtual core XTEST keyboard" slave — which is what the
// attribution claims are about. Where it is missing, every claim that needs
// injected input SKIPs rather than passing (see checks.go).
//
// Every invocation is env-pinned to the rig (childEnv), so an injector can
// never land on the caller's session even if $DISPLAY says otherwise.
type Injector struct {
	display string
	env     []string
	errs    []string
}

func NewInjector(display string) *Injector {
	return &Injector{display: display, env: childEnv(os.Environ(), display, "")}
}

// Errors returns every injection that xdotool refused.
//
// This exists because of a real self-inflicted wound during this task: an
// invalid long-option (`--clearmodifiers=0`) made EVERY chord injection fail
// silently, and the resulting run reported a dozen red lines about the
// daemon while the actual fault was in the instrument. An instrument that
// can fail without saying so turns every claim downstream of it into noise,
// so its failures are surfaced as their own verdict (see runMechanism).
func (in *Injector) Errors() []string { return append([]string{}, in.errs...) }

// Available reports whether xdotool is on PATH — a precondition, read off
// this run, that every injection-dependent claim is gated on.
func (in *Injector) Available() bool {
	_, err := exec.LookPath("xdotool")
	return err == nil
}

func (in *Injector) run(args ...string) error {
	cmd := exec.Command("xdotool", args...)
	cmd.Env = in.env
	out, err := cmd.CombinedOutput()
	if err != nil {
		e := fmt.Errorf("xdotool %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
		in.errs = append(in.errs, e.Error())
		return e
	}
	return nil
}

// Tap presses and releases one chord, e.g. Tap("super+o") or Tap("h").
func (in *Injector) Tap(chord string) error { return in.run("key", chord) }

// TapN taps the same chord n times, with delay between taps.
func (in *Injector) TapN(chord string, n int, delay time.Duration) error {
	for i := 0; i < n; i++ {
		if err := in.Tap(chord); err != nil {
			return err
		}
		time.Sleep(delay)
	}
	return nil
}

// TapSequence sends several keys inside ONE xdotool invocation, with the
// given inter-key delay in milliseconds. delayMS=0 is what puts two key
// events on a single millisecond, which is the rolling-typing case the
// repeat filter must not swallow.
func (in *Injector) TapSequence(delayMS int, keys ...string) error {
	args := append([]string{"key", "--delay", fmt.Sprint(delayMS)}, keys...)
	return in.run(args...)
}

func (in *Injector) Down(key string) error { return in.run("keydown", key) }
func (in *Injector) Up(key string) error   { return in.run("keyup", key) }

// ReleaseAll hands back every grab this rig still holds. Called between
// phases so livecheck never competes with the daemon it is about to observe
// — a leftover grab would make the daemon's own grab legitimately fail and
// turn a livecheck artefact into a reported defect.
func (r *Rig) ReleaseAll() {
	for label := range r.held {
		_ = r.Ungrab(label)
	}
}
