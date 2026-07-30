// daemon.go assembles everything sp021's prior tasks landed into one run
// loop (sp021 Task 12, bd dotfiles-ylmp.11) — the Go port of hotkeyd.py's
// Daemon + run_daemon (hotkeyd.py:1309-1670), restructured around Go
// channels/select instead of Python's `select.select` + SIGALRM-free signal
// flags.
//
// # Why every dependency here is an interface, not a concrete type
//
// dotfiles-eez2 records the exact defect class this file exists to close:
// hotkeyd.py's run_daemon wired dae.pump_i3() (and friends) into a loop that
// only ever ran against a REAL X display, so every unit suite drove the
// pieces in isolation and NOTHING drove the wiring — a deleted pump_i3()
// call shipped green. Every external dependency the run loop touches
// (i3.Client, grabSyncer, deviceAttributor, lockBeater, the events channel,
// the hold-poll ModifierDown factory) is an interface or a channel a test
// can substitute with zero Xvfb, zero real i3, and zero real sockets — see
// daemon_test.go's fakes and its "wiring-deletion" tests, each of which
// fails if the seam it names is unwired.
//
// # adr0016's bounded sampling interval
//
// IdleTick and HoldPollInterval are the two named constants adr0016 asks
// for: the hold-layer idle poll (layer.Engine.PollIdle) runs on the run
// loop's own timeout branch, at HoldPollInterval while a hold layer is
// active and IdleTick otherwise — ported verbatim from hotkeyd.py's
// HOLD_TIMEOUT_S / IDLE_TIMEOUT_S.
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"sort"
	"syscall"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/i3"
	"hotkeyd/internal/layer"
	"hotkeyd/internal/proc"
	"hotkeyd/internal/x11"
)

// -- adr0016: bounded sampling interval, named in code -----------------

// IdleTick is how long the run loop may wait for the next X event before
// it re-checks i3 / the heartbeat / the hold-idle poll — the ordinary
// bound. Ported from hotkeyd.py's IDLE_TIMEOUT_S (0.25s): cheap enough to
// notice a phantom held modifier (dotfiles-hwds.27) with nothing else
// waiting on it.
const IdleTick = 250 * time.Millisecond

// HoldPollInterval is [[adr0016]]'s named bounded sampling interval: while
// a hold layer is active this IS the commit latency (the modifier's
// release cannot be delivered as an event — see adr0016), so the loop
// ticks much faster whenever layer.Engine.HoldModifier() is non-empty.
// Ported from hotkeyd.py's HOLD_TIMEOUT_S (0.02s) — below the threshold at
// which a released alt-tab feels delayed.
const HoldPollInterval = 20 * time.Millisecond

// sighupMessage is what SIGHUP logs. SIGHUP table reload is DROPPED by
// this rewrite (binds compile into the binary, dwm config.h style — see
// sp021's solution and Task 18 / ft011's amendment): there is nothing left
// to reload, so this names the actual replacement rather than silently
// doing nothing.
const sighupMessage = "hotkeyd: SIGHUP is a no-op on this build — rebuild + `hotkeyd.sh restart` to pick up a table change"

// exitXConnLost is run_daemon's runtime (not startup) fatal exit: the X
// server died mid-run. Grabs die with the connection (X server behaviour);
// [[ft003]]'s panic bind, external to this daemon, is the recovery route —
// this is NOT a reconnect loop (adr0014: no unbounded inline retry).
// Mirrors hotkeyd.py's run_daemon ConnectionClosedError handling (code=1).
const exitXConnLost = 1

// core + XI2 wire constants this file demuxes incoming x11.Events on. Not
// exported from internal/x11 (poc014/poc015's scope was requests + wire
// parsing, not event classification) — named here, matching hotkeyd.py's
// module-level constants byte for byte (MappingNotify=34 is the X11 core
// protocol constant; genericEventCode mirrors internal/x11's own
// unexported one; the XI_* values are xinput.xml's evtype enum).
const (
	coreMappingNotify = 34
	xiGenericEvent    = 35

	xiEvtKeyPress         = 2
	xiEvtKeyRelease       = 3
	xiEvtDeviceChanged    = 1
	xiEvtHierarchyChanged = 11
)

// -- chord-set derivation (hotkeyd.py's global_chords/layer_chords/chords_for) --

// modKeysymNames is the reverse of internal/layer's (unexported)
// modKeysyms table — duplicated here deliberately rather than exported
// from that package, since it is layer's own X-free vocabulary and this
// is the one place outside it that needs the reverse direction: grabbing a
// sublayer's own modifier KEYS is what makes the modifier observable as
// "held" at all (without these grabs a Ctrl press inside a layer never
// reaches the daemon and the move/resize sublayers are dead in a real
// session while every pure-engine test still passes).
var modKeysymNames = map[string][]string{
	"Shift": {"Shift_L", "Shift_R"},
	"Ctrl":  {"Control_L", "Control_R"},
	"Mod1":  {"Alt_L", "Alt_R", "Meta_L", "Meta_R"},
	"Mod4":  {"Super_L", "Super_R"},
}

// exitModifiers are the modifiers a hand is plausibly still holding when
// it reaches for a layer's exit key. Ported from hotkeyd.py's
// EXIT_MODIFIERS.
var exitModifiers = []string{"Shift", "Ctrl", "Mod1"}

// shiftedKeysym names keys whose shifted level is a DIFFERENT keysym on a
// standard keymap, so a hold layer's "+Shift+" fan-out does not grab a
// (code, mask) pair twice under two names. Ported from hotkeyd.py's
// SHIFTED_KEYSYM.
var shiftedKeysym = map[string]string{"Tab": "ISO_Left_Tab"}

// chordActiveOnDisplay reports whether b participates in the grab set
// being computed for mod — us020's display qualifier (bind.Bind.DisplayMod):
// an unqualified bind ("") is active on every display; a qualified one only
// on its own. A DisplayMod value Validate could not resolve is treated as
// active rather than silently dropped — Validate already refuses such a
// table by name (R27) before any grab, so this function never actually
// observes that case on a loaded table; it degrades safely rather than
// hiding a bind if that invariant is ever violated.
func chordActiveOnDisplay(b bind.Bind, mod string) bool {
	if b.DisplayMod == "" {
		return true
	}
	canon, ok := bind.CanonModifier(b.DisplayMod, mod)
	if !ok {
		return true
	}
	return string(canon) == mod
}

// dedupOrdered preserves first-seen order — the Go analogue of Python's
// `dict.fromkeys`, which every chord-set function above it relies on.
func dedupOrdered(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		if seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

// globalChords is what is grabbed in the default layer: the global binds
// active on this display, and nothing else. Layer binds are deliberately
// NOT here — see layerChords' doc for why grabbing them permanently would
// swallow keys from every application. Ported from hotkeyd.py's
// global_chords.
func globalChords(binds []bind.Bind, mod string) []string {
	out := make([]string, 0, len(binds))
	for _, b := range binds {
		if chordActiveOnDisplay(b, mod) {
			out = append(out, b.Chord)
		}
	}
	return dedupOrdered(out)
}

func containsStr(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

// layerChords is the extra chords a layer needs while it is ACTIVE: its
// bare keys, its exit keys (bare and modifier-held), its Mod sublayer
// chords, the sublayer modifiers' own keysyms (so held state is
// observable at all), and — for a HOLD layer — every one of its keys
// re-grabbed under the hold modifier's mask too, because that is the mask
// they actually arrive with once the hold modifier is down. Ported
// verbatim from hotkeyd.py's layer_chords; see that function's docstring
// (hotkeyd.py:1093-1147) for the full reasoning this port carries over
// unchanged.
func layerChords(lay bind.Layer, mod string) []string {
	keys := make([]string, 0, len(lay.Binds))
	for _, b := range lay.Binds {
		if chordActiveOnDisplay(b, mod) {
			keys = append(keys, b.Chord)
		}
	}

	out := append([]string(nil), keys...)
	out = append(out, lay.ExitKeys...)

	routed := map[string]bool{}

	labels := make([]string, 0, len(lay.Mods))
	for label := range lay.Mods {
		labels = append(labels, label)
	}
	sort.Strings(labels)
	for _, label := range labels {
		sub := lay.Mods[label]
		canonStr := sub.Modifier
		if canon, ok := bind.CanonModifier(sub.Modifier, mod); ok {
			canonStr = string(canon)
		}
		for _, b := range sub.Binds {
			if !chordActiveOnDisplay(b, mod) {
				continue
			}
			out = append(out, canonStr+"+"+b.Chord)
		}
		out = append(out, modKeysymNames[canonStr]...)
		if canonStr != "Shift" { // never routed: see layerChords' Shift note
			routed[canonStr] = true
		}
	}

	if lay.Hold != "" {
		hc := lay.Hold
		if canon, ok := bind.CanonModifier(lay.Hold, mod); ok {
			hc = string(canon)
		}
		allKeys := append(append([]string(nil), keys...), lay.ExitKeys...)
		for _, c := range allKeys {
			out = append(out, hc+"+"+c)
		}
		for _, c := range keys {
			if shifted, ok := shiftedKeysym[c]; ok && containsStr(keys, shifted) {
				continue
			}
			out = append(out, hc+"+Shift+"+c)
		}
		routed[hc] = true
	}

	for _, canon := range exitModifiers {
		if routed[canon] {
			continue
		}
		for _, k := range lay.ExitKeys {
			out = append(out, canon+"+"+k)
		}
	}

	return dedupOrdered(out)
}

// chordsFor is the grab set for the CURRENT state, re-synced on every
// layer transition. Ported from hotkeyd.py's chords_for.
func chordsFor(binds []bind.Bind, layers map[string]bind.Layer, activeLayer, mod string) []string {
	out := globalChords(binds, mod)
	if activeLayer != "" && activeLayer != layer.DefaultLayer {
		if lay, ok := layers[activeLayer]; ok {
			out = append(out, layerChords(lay, mod)...)
		}
	}
	return dedupOrdered(out)
}

// -- incoming-event translation (hotkeyd.py's key_event/to_event/mods_from_mask) --

// xiEvType reads a GenericEvent frame's XI2 evtype field (offset 8:10 —
// shared by every XI2 sub-event, key or otherwise), without assuming the
// rest of the frame parses as an XIDeviceEvent. HierarchyChanged/
// DeviceChanged events do NOT share XIDeviceEvent's variable-length tail,
// so this reads only the field every XI2 GenericEvent has in common,
// BEFORE deciding whether x11.ParseDeviceEvent is even applicable.
func xiEvType(raw []byte) uint16 {
	if len(raw) < 10 {
		return 0
	}
	return binary.LittleEndian.Uint16(raw[8:10])
}

// keysymFor mirrors hotkeyd.py's GrabManager.keysym_for: which chord's
// bare keysym an incoming (keycode, effective-modifier-mask) belongs to,
// per THIS daemon's ACTIVE grab set — never a raw X keysym translation,
// because Tab and ISO_Left_Tab share one physical keycode at two shift
// levels and only the active-grab identity disambiguates which bind fired.
// The mask match is tried first (state with lock bits stripped); the
// code-only answer is the fallback. wanted supplies a DETERMINISTIC
// iteration order (table declaration order) for that fallback — Go's maps
// have none, unlike the insertion-ordered Python dict this replaces.
func keysymFor(wanted []string, active map[string]GrabbedChord, mod string, code, state uint32) (string, bool) {
	want := state &^ (x11.ModMaskLock | x11.ModMaskMod2)
	fallback, haveFallback := "", false
	for _, chord := range wanted {
		gc, ok := active[chord]
		if !ok || gc.Code != code {
			continue
		}
		if gc.Mask == want {
			if _, key, err := bind.ParseChord(chord, mod); err == nil {
				return key, true
			}
		}
		if !haveFallback {
			fallback, haveFallback = chord, true
		}
	}
	if haveFallback {
		if _, key, err := bind.ParseChord(fallback, mod); err == nil {
			return key, true
		}
	}
	return "", false
}

// modsFromMask reports the canonical modifier names set in mask, lock
// bits dropped — NumLock/CapsLock ride in every mask but are not layer
// modifiers (poc013). Ported from hotkeyd.py's mods_from_mask, reusing
// grabs.go's maskByModifier (chord-mask encoding) in reverse.
func modsFromMask(mask uint32) map[string]bool {
	mask &^= x11.ModMaskLock | x11.ModMaskMod2
	out := map[string]bool{}
	for mod, bit := range maskByModifier {
		if bit == x11.ModMaskLock || bit == x11.ModMaskMod2 {
			continue
		}
		if mask&bit != 0 {
			out[string(mod)] = true
		}
	}
	return out
}

func deviceIgnored(name string) bool {
	if name == "" {
		return false
	}
	return containsStr(bind.IgnoreDevices, name)
}

// -- seams the run loop depends on, as interfaces (see the file doc) ----

// grabSyncer is the subset of *GrabManager's behaviour daemon.go needs.
// *GrabManager already implements every method below with a matching
// signature (grabs.go, sp021 Task 11) — this interface exists so
// daemon_test.go can substitute a fake with zero X, never so *GrabManager
// has to change.
type grabSyncer interface {
	SyncBinds(chords []string) bool
	OnMappingNotify() bool
	Active() map[string]GrabbedChord
	Wanted() []string
	GrabReport() (wanted, active int, missing []string)
}

var _ grabSyncer = (*GrabManager)(nil)

// deviceAttributor is the subset of *DeviceRegistry's behaviour daemon.go
// needs. *DeviceRegistry already implements both methods (devices.go,
// sp021 Task 11).
type deviceAttributor interface {
	Invalidate()
	AttributeSource(ev x11.DeviceEvent) (name string, ok bool)
}

var _ deviceAttributor = (*DeviceRegistry)(nil)

// lockBeater is the subset of *proc.Lock's behaviour daemon.go needs.
// *proc.Lock already implements both methods (proc/lock.go, sp021 Task
// 10).
type lockBeater interface {
	Beat()
	Release()
}

var _ lockBeater = (*proc.Lock)(nil)

// -- Daemon ---------------------------------------------------------------

// DaemonConfig is NewDaemon's dependency set. Every field beyond the plain
// data ones (Binds, Layers, Mod, Display) is an interface or a channel —
// see the file doc for why: it is what lets daemon_test.go drive the run
// loop with fakes and prove each wiring seam is load-bearing, without
// Xvfb.
type DaemonConfig struct {
	// Events is the X connection's decoded event stream — production
	// wiring passes a live *x11.Conn's Events field directly (it is a
	// plain `chan x11.Event`, assignable to this receive-only type with
	// no adapter); tests construct their own channel and feed synthetic
	// frames.
	Events <-chan x11.Event

	I3      i3.Client
	Grabs   grabSyncer
	Devices deviceAttributor
	Engine  *layer.Engine
	Lock    lockBeater

	// Publisher is closed at shutdown if non-nil. nil is a legal,
	// intentional configuration: see buildPublisher's doc in main.go for
	// the "log and continue without a publisher" policy on
	// layer.ErrChannelUnavailable.
	Publisher io.Closer

	// XConn is the X connection's own closer, closed at shutdown — this
	// is what releases every outstanding passive grab (X server
	// behaviour: grabs die with the client's connection), matching the
	// edge case "X server death mid-run: grabs died with the
	// connection".
	XConn io.Closer

	// NewModQuery builds a FRESH layer.ModifierDown for one PollIdle
	// call. Fresh per call (not one long-lived func) so production
	// wiring can cache a single QueryPointer round trip across the (at
	// most two) canons one poll tick asks about, rather than one round
	// trip per canon — see main.go's newPointerModifierQuery.
	NewModQuery func() layer.ModifierDown

	// Run spawns a bind.Run action's command. Defaults to proc.Run
	// (setsid-detached, no fd inheritance). Overridable so tests can
	// exercise the "action spawn failing -> logged, loop continues" edge
	// case without depending on what actually fails a real fork/exec.
	Run func(command string) error

	Binds  []bind.Bind
	Layers map[string]bind.Layer
	Mod    string
	// Display is the (already default-resolved) $DISPLAY value this
	// daemon serves — used only for the grab-report sidecar path
	// (proc.WriteGrabReport keys on it).
	Display string

	// Log defaults to a "hotkeyd: "-prefixed stderr line, matching
	// grabs.go's grabLog convention.
	Log func(string)

	// IdleTick / HoldTick default to the package constants of the same
	// shape; overridable only for tests (adr0016: production must not
	// tune these by feel).
	IdleTick time.Duration
	HoldTick time.Duration
}

// Daemon is the whole thing wired together: grabs -> engine -> dispatch +
// state feed, and the run loop that drives it. The Go analogue of
// hotkeyd.py's Daemon class plus run_daemon's loop body.
type Daemon struct {
	events  <-chan x11.Event
	i3      i3.Client
	grabs   grabSyncer
	devices deviceAttributor
	engine  *layer.Engine
	lock    lockBeater

	pub    io.Closer
	xConn  io.Closer
	newMod func() layer.ModifierDown
	run    func(command string) error

	binds   []bind.Bind
	layers  map[string]bind.Layer
	mod     string
	display string
	log     func(string)

	idleTick time.Duration
	holdTick time.Duration
}

// NewDaemon builds a Daemon from cfg. wireI3Mode is called here (subscribe
// to i3's `mode` event, seed the engine with the mode i3 is in right now)
// exactly as hotkeyd.py's Daemon.__init__ does — best-effort: an i3 that
// cannot be reached at construction time is not fatal (Task 9's behaviour
// matrix: a lost i3 must not take the keyboard layer down with it), and
// the wanted subscription is remembered regardless of outcome so the next
// successful connect (by any path) re-subscribes automatically.
func NewDaemon(cfg DaemonConfig) *Daemon {
	d := &Daemon{
		events:   cfg.Events,
		i3:       cfg.I3,
		grabs:    cfg.Grabs,
		devices:  cfg.Devices,
		engine:   cfg.Engine,
		lock:     cfg.Lock,
		pub:      cfg.Publisher,
		xConn:    cfg.XConn,
		newMod:   cfg.NewModQuery,
		run:      cfg.Run,
		binds:    cfg.Binds,
		layers:   cfg.Layers,
		mod:      cfg.Mod,
		display:  cfg.Display,
		log:      cfg.Log,
		idleTick: cfg.IdleTick,
		holdTick: cfg.HoldTick,
	}
	if d.log == nil {
		d.log = daemonLog
	}
	if d.run == nil {
		d.run = proc.Run
	}
	if d.idleTick == 0 {
		d.idleTick = IdleTick
	}
	if d.holdTick == 0 {
		d.holdTick = HoldPollInterval
	}
	d.wireI3Mode()
	return d
}

func daemonLog(msg string) {
	fmt.Fprintln(os.Stderr, "hotkeyd: "+msg)
}

// onI3Event is the i3.EventHandler wired into the i3.Client at
// construction (main.go). Only the `mode` event matters here — i3 modes
// hold their own passive grabs on the same bare keys a layer wants, so two
// active "modes" mean two owners (dotfiles-hwds.10); this is the one side
// of that arbitration i3 lets the daemon see.
func (d *Daemon) onI3Event(kind uint32, data map[string]any) {
	if kind != i3.EventMode {
		return
	}
	change, _ := data["change"].(string)
	d.dispatchAll(d.engine.SetI3Mode(change))
}

// wireI3Mode subscribes to `mode` events and seeds the engine with
// whatever mode i3 is in right now — needed because i3 never sends a
// `mode` event for a mode it was already in before Subscribe was called.
func (d *Daemon) wireI3Mode() {
	if err := d.i3.Subscribe("mode"); err != nil {
		d.log(fmt.Sprintf("i3: subscribe: %s", err))
		return
	}
	d.syncI3Mode()
}

func (d *Daemon) syncI3Mode() {
	state, err := d.i3.BindingState()
	if err != nil {
		d.log(fmt.Sprintf("i3: binding state: %s", err))
		return
	}
	d.dispatchAll(d.engine.SetI3Mode(state))
}

// idleTimeout is adr0016's bounded sampling interval, dynamic on whether a
// hold layer is currently active (HoldModifier() != "").
func (d *Daemon) idleTimeout() time.Duration {
	if d.engine.HoldModifier() != "" {
		return d.holdTick
	}
	return d.idleTick
}

// pumpI3 is one non-blocking pass over the i3 connection — called from
// every run-loop iteration, so an i3 mode change (or a lost/regained i3)
// takes the keyboard back within one iteration. Ported from hotkeyd.py's
// Daemon.pump_i3.
func (d *Daemon) pumpI3() {
	before := d.engine.State().Layer
	reconnected, err := d.i3.PollEvents()
	if err != nil {
		d.log(fmt.Sprintf("i3: %s", err))
	}
	if reconnected {
		// A reconnect means a restarted i3, whose mode has reset.
		// Believing the last mode we heard would refuse every layer
		// entry from here on.
		d.syncI3Mode()
	}
	if d.engine.State().Layer != before {
		d.resyncGrabs()
	}
}

// pollIdle is the hold-layer idle poll (adr0016): reconciles the engine's
// held-modifier belief against the server and, while a hold layer is
// active, asks whether its modifier is still down — the ONLY channel that
// can observe that release (see internal/layer/hold.go). Builds a FRESH
// ModifierDown per call so production wiring pays at most one X round
// trip per tick regardless of how many canons this poll asks about.
func (d *Daemon) pollIdle() {
	before := d.engine.State().Layer
	actions, err := d.engine.PollIdle(d.newMod())
	if err != nil {
		d.log(fmt.Sprintf("hold-layer poll: %s", err))
		return
	}
	d.dispatchAll(actions)
	if d.engine.State().Layer != before {
		d.resyncGrabs()
	}
}

// resyncGrabs re-syncs the grab set to the engine's CURRENT layer and
// publishes the resulting grab report — called whenever a Handle/pumpI3/
// pollIdle call moved the engine to a different layer. A layer's bare
// keys exist only while that layer is active, so they never shadow an
// application's keyboard outside it; SyncBinds moves only the difference,
// so nothing is dropped mid-gesture (dotfiles-hwds.41).
func (d *Daemon) resyncGrabs() {
	chords := chordsFor(d.binds, d.layers, d.engine.State().Layer, d.mod)
	d.grabs.SyncBinds(chords)
	d.publishGrabReport()
}

// publishGrabReport is the evidence proc.WriteGrabReport publishes for
// --health verdict 9 (adr0017) — grabs.go's GrabReport doc names this
// call site as this task's job.
func (d *Daemon) publishGrabReport() {
	wanted, active, missing := d.grabs.GrabReport()
	proc.WriteGrabReport(d.display, wanted, active, missing)
}

// dispatch routes one action: an i3 Command through the i3 client, a Run
// through proc.Run (setsid-detached spawn). EnterLayer/ExitLayer/Func
// never escape engine.run() (internal/layer), so anything else reaching
// here is a defensive no-op — matching hotkeyd.py's _dispatch, which only
// ever understood Run and a bare command string.
func (d *Daemon) dispatch(a bind.Action) {
	switch v := a.(type) {
	case bind.Run:
		// Action spawn failing (the run target missing, /bin/sh itself
		// missing, ...) is logged and the loop continues — a bad action
		// must not take the daemon down.
		if err := d.run(v.Cmd); err != nil {
			d.log(fmt.Sprintf("run %q: %s", v.Cmd, err))
		}
	case bind.Command:
		ok, i3Err, err := d.i3.Command(string(v))
		if err != nil {
			d.log(fmt.Sprintf("i3 dispatch error: %q: %s", string(v), err))
			return
		}
		if !ok {
			d.log(fmt.Sprintf("i3 dispatch failed: %q: %s", string(v), i3Err))
		}
	}
}

func (d *Daemon) dispatchAll(actions []bind.Action) {
	for _, a := range actions {
		d.dispatch(a)
	}
}

// handleXEvent demultiplexes one raw X event: MappingNotify triggers a
// compare-then-regrab, an XI2 hierarchy/device-changed event invalidates
// the device name cache, and an XI2 key press/release is handed to
// handleKeyEvent. Code==0 is conn.go's own marker for an X error frame
// that never found a checked-request waiter (an async/spurious error) —
// logged, never fatal on its own (see the file doc's X-death-is-fatal
// note: that path is the events channel CLOSING, handled in Run, not this
// function).
func (d *Daemon) handleXEvent(ev x11.Event) {
	switch ev.Code {
	case coreMappingNotify:
		d.grabs.OnMappingNotify()
		d.publishGrabReport()
	case xiGenericEvent:
		switch xiEvType(ev.Raw) {
		case xiEvtDeviceChanged, xiEvtHierarchyChanged:
			d.devices.Invalidate()
		case xiEvtKeyPress, xiEvtKeyRelease:
			d.handleKeyEvent(ev.Raw)
		}
	case 0:
		d.log("async X error (no waiting request) — see the raw frame in logs above")
	}
}

// handleKeyEvent is the press -> match -> dispatch -> (maybe resync)
// cycle for one XI2 key event. Ported from hotkeyd.py's Daemon.pump.
func (d *Daemon) handleKeyEvent(raw []byte) {
	dev, err := x11.ParseDeviceEvent(raw)
	if err != nil {
		d.log(fmt.Sprintf("malformed XI2 device event: %s", err))
		return
	}
	if dev.Repeat {
		// XI2 sets XIKeyRepeat on the repeated PRESS itself (core
		// delivery instead synthesised a release+press pair per repeat).
		// One action per physical press.
		return
	}

	key, ok := keysymFor(d.grabs.Wanted(), d.grabs.Active(), d.mod, dev.Detail, dev.Mods.Effective)
	if !ok {
		return // not one of ours
	}

	deviceName, _ := d.devices.AttributeSource(dev)
	if deviceIgnored(deviceName) {
		return
	}

	kind := layer.Press
	if dev.EventType == xiEvtKeyRelease {
		kind = layer.Release
	}
	keycode := int(dev.Detail)
	rawState := dev.Mods.Effective
	deviceID := int(dev.SourceID)

	before := d.engine.State().Layer
	actions := d.engine.Handle(layer.Event{
		Kind:     kind,
		Key:      key,
		Mods:     modsFromMask(dev.Mods.Effective),
		Device:   deviceName,
		DeviceID: &deviceID,
		Keycode:  &keycode,
		RawState: &rawState,
	})
	d.dispatchAll(actions)
	if d.engine.State().Layer != before {
		d.resyncGrabs()
	}
}

// shutdown is run_daemon's `finally`: hand the layer's overlay back BEFORE
// tearing anything down (dotfiles-hwds.51 — a daemon dying inside a hold
// layer must not leave the overlay stranded on screen), then close the
// state feed, the i3 connection, the X connection (releasing every
// outstanding grab — X server behaviour), and finally release the
// single-instance lock. Ported from hotkeyd.py's run_daemon finally
// block.
func (d *Daemon) shutdown() {
	for _, a := range d.engine.ShutdownActions() {
		d.dispatch(a)
	}
	if d.pub != nil {
		if err := d.pub.Close(); err != nil {
			d.log(fmt.Sprintf("state publisher: close: %s", err))
		}
	}
	if err := d.i3.Close(); err != nil {
		d.log(fmt.Sprintf("i3: close: %s", err))
	}
	if d.xConn != nil {
		if err := d.xConn.Close(); err != nil {
			d.log(fmt.Sprintf("x11: close: %s", err))
		}
	}
	if d.lock != nil {
		d.lock.Release()
	}
}

// Run is the assembled run loop: one select multiplexes X events, the
// process's signal channel, and a timer standing in for the hold-idle
// poll / heartbeat / i3-pump tick (adr0016's bounded sampling interval).
// sig is injected rather than read from a package-level signal.Notify
// call so daemon_test.go can drive every branch — including SIGHUP/SIGTERM
// — with a plain channel and zero real OS signals.
//
// Returns the process exit code: 0 on a clean SIGTERM/SIGINT, exitXConnLost
// if the X connection dies mid-run (events channel closes — a fatal named
// exit per the edge case: grabs died with the connection, and [[ft003]]'s
// panic bind is the recovery, not a reconnect loop).
func (d *Daemon) Run(sig <-chan os.Signal) int {
	timer := time.NewTimer(d.idleTimeout())
	defer timer.Stop()
	code := 0

runLoop:
	for {
		select {
		case s := <-sig:
			if s == syscall.SIGHUP {
				d.log(sighupMessage)
			} else {
				// SIGTERM, SIGINT: on_exit fires, grabs ungrabbed,
				// socket closed, lock released, exit 0 — see shutdown().
				break runLoop
			}
		case ev, ok := <-d.events:
			if !ok {
				d.log("X connection lost, exiting")
				code = exitXConnLost
				break runLoop
			}
			// Beat every iteration, event branch included: an
			// auto-repeat flood must not starve the heartbeat, and
			// Beat() self-throttles to at most once per second, so
			// calling it on every event costs nothing extra.
			d.lock.Beat()
			d.pumpI3()
			d.handleXEvent(ev)
		case <-timer.C:
			d.lock.Beat()
			d.pumpI3()
			d.pollIdle()
		}

		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(d.idleTimeout())
	}

	d.shutdown()
	return code
}
