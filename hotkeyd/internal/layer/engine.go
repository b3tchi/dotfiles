// Package layer is the Go port of hotkeyd/layers.py's LayerEngine — the
// pure, X-free state machine that turns key events into dispatchable
// actions and owns layer + held-modifier state (sp021 Task 7,
// bd dotfiles-ylmp.6). StatePublisher (layers.py's socket fan-out) is NOT
// part of this package's files_touched — it lands in sp021 Task 8
// (bd dotfiles-ylmp.7, "internal/layer — state publisher"), which shares
// this package.
//
// Like internal/bind, it is pure: no X connection, no i3 connection. A hold
// layer's lifetime is the one exception that would otherwise force an X
// dependency in here — [[adr0016]] settles it by injecting a
// ModifierDown(mod) (bool, error) func (hold.go) that the DAEMON implements
// against a real query, polled on its idle path. The engine never dials X
// itself and never trusts its own held-set to end a hold layer; see hold.go
// for both numbered adr0016 consequences honoured.
//
// # Port table — reconciled against hotkeyd/layers.py's LayerEngine
//
// hotkeyd/layers.py's LayerEngine (as of 2026-07-30, the commit this task
// was written against) has exactly 21 methods across 436 source lines (class
// body, `class LayerEngine:` through its last method, verified by parsing
// the file's AST: `ast.walk` + `ClassDef` + `FunctionDef` count). The task
// card states "442 lines" — a 6-line discrepancy from the 436 measured here.
// Re-derivation rather than re-assertion (per this task's own instruction):
// the AST-measured span is lines 165-600 inclusive of layers.py, which is
// unambiguous once you draw the boundary at the class's own first and last
// line. The task's number is close enough to be the same measurement taken
// slightly differently (e.g. including one or two blank/trailing lines
// outside the class, or measured against an earlier revision) rather than a
// different quantity entirely — unlike sp021's earlier "42 rejection rules"
// drift (bind's package doc), which turned out to be counting a materially
// different thing. The METHOD COUNT (21) matches exactly.
//
//	Python method (layers.py)     Go (this package)                          Note
//	__init__                      NewEngine(binds, layers, Config) *Engine   Config replaces Python's keyword-arg defaults
//	state (property)              (*Engine).State() State
//	_active_mod                   (*Engine).activeMod() string               see "sublayer precedence" below
//	_hold_canon                   (*Engine).holdCanon(bind.Layer) string
//	hold_modifier (property)      (*Engine).HoldModifier() string
//	_hold_release_actions         (*Engine).holdReleaseActions(string) []bind.Action
//	_exit_actions                 (*Engine).exitActions(string) []bind.Action
//	reconcile_hold_layer          (*Engine).ReconcileHoldLayer(bool) []bind.Action   narrowed signature, see hold.go
//	held (property)               (*Engine).Held() []string                  sorted slice, not a set (Go has none built in)
//	reconcile_holds               (*Engine).ReconcileHolds(map[string]bool) bool
//	i3_mode (property)            (*Engine).I3Mode() string
//	set_i3_mode                   (*Engine).SetI3Mode(string) []bind.Action
//	_i3_owns_the_keyboard         (*Engine).i3OwnsKeyboard() bool
//	_publish                      (*Engine).publish(*Event, string)
//	handle                        (*Engine).Handle(Event) []bind.Action
//	_is_repeat                    (*Engine).isRepeat(string, time.Time) bool
//	_expire_stale_holds           (*Engine).expireStaleHolds(Event, time.Time)
//	_index                        (*Engine).buildIndex([]bind.Bind) map[indexKey][]bind.Bind
//	_match                        (*Engine).match(Event, bool) ([]bind.Action, *bind.Bind)   also returns the matched Bind, see below
//	_match_in_layer                (*Engine).matchInLayer(bind.Layer, Event, bool) ([]bind.Action, *bind.Bind)
//	_run                           (*Engine).run([]bind.Action, *bind.Bind) []bind.Action     see "callable actions" below
//
// Exports beyond the 21. The port table above is the reconciliation against
// layers.py and deliberately does not grow entries for capabilities Python
// never had:
//
//   - (*Engine).ShutdownActions — a Daemon method in Python, not a
//     LayerEngine one; detailed immediately below.
//   - (*Engine).PollIdle (hold.go, sp021) — [[adr0016]]'s ask-the-server
//     seam. Python's daemon built the down-set itself and called
//     reconcile_hold_layer directly, so there was nothing to export.
//   - (*Engine).SetExternalLayer (sp023 Task 2) — the external-trigger
//     layer kind, which layers.py had no equivalent of at all: every
//     Python layer was chord-entered. See its own doc for the
//     signal-only semantics and the deliberate divergence from
//     EnterLayer's i3-mode arbitration.
//
// (*Engine).ShutdownActions() []bind.Action wraps
// exitActions for cmd/hotkeyd's shutdown path, mirroring
// Daemon.shutdown_actions (hotkeyd.py:1507-1524) — a method on Daemon, not
// LayerEngine, in Python, where it could reach engine._exit_actions(layer)
// directly across what was one module. Go's package boundary has no
// equivalent to Python's "private but same-module" access, so this package
// exports the one seam a caller outside it needs. See "on_exit and the
// involuntary exit routes" below.
//
// Module-level functions (layers.py, not LayerEngine methods) ported
// alongside the class because the engine cannot behave correctly without
// them:
//
//	Event (dataclass)             Event (struct)
//	_stderr_log                   defaultLog
//	format_transition              formatTransition
//	device_matches                 deviceMatches
//	MOD_KEYSYMS                    modKeysyms
//	RELEASE_GUARD_MS                ReleaseGuardMS
//	KEY_WEDGE_MS                    KeyWedgeMS
//	DEFAULT_LAYER                   DefaultLayer
//	DEFAULT_I3_MODE                  DefaultI3Mode
//	_or_none                        orNoneStr / orNoneInt / orNoneMask / orNoneDevice (split by type; Go has no untyped None)
//
// Deleted / deferred, not ported by this task:
//
//   - StatePublisher, socket_path, ChannelUnavailable, ChannelBusy — deferred
//     to sp021 Task 8 (bd dotfiles-ylmp.7), which owns publisher.go in this
//     same package. Not "deleted" — out of THIS task's files_touched.
//   - binds.py's actions_of(bind) helper — not needed. Python's Bind.action
//     is a bare-value-or-tuple union that actions_of() normalizes into a
//     list; bind.Bind.Actions (internal/bind, landed by sp021 Task 5) is
//     already always a slice, so there is nothing to normalize.
//
// # Sublayer precedence — a structural deviation from Python, not a bug
//
// _active_mod's docstring states precedence is "the layer's DECLARATION
// order, not press order". Python dicts preserve insertion order (3.7+), so
// iterating layer.mods.items() in source order is exactly declaration order.
// bind.Layer.Mods (internal/bind, already landed) is a plain Go map, which
// has NO iteration order guarantee at all — Go maps are deliberately
// randomized per run specifically to stop code from depending on one. That
// type shape was fixed by sp021 Task 5, outside this task's files_touched,
// so this package cannot recover "declaration order" by construction.
//
// activeMod() therefore breaks ties by SORTING THE LABELS
// ALPHABETICALLY and taking the first whose canonical modifier is held —
// deterministic (satisfies the actual invariant the Python test asserts:
// "must not flap depending on press order"), but not equivalent to
// declaration order in general. For the shipped nav layer specifically
// (labels "move" and "resize"), alphabetical order and declaration order
// coincide ("move" < "resize"), so the port is behaviourally identical for
// every table this repo ships today — but a future table with labels that
// sort the other way from their declaration would resolve differently than
// Python would have. Filed as discovered work (bd dotfiles-9y8n) rather
// than silently accepted: internal/bind would need an ordered
// representation (e.g. Mods becoming a slice of
// labelled entries) to close this exactly.
//
// # Callable actions — bind.Func's reduced Event, not layers.py's rich one
//
// Python's callable actions receive the FULL triggering Event (key, mods,
// device, keycode, ...). internal/bind's Func type (landed by sp021 Task 5)
// deliberately takes the much smaller bind.Event{Chord, OnRelease} — its own
// doc says so explicitly: "this package only needs a name to give Func a
// concrete signature". This package honours that reduction rather than
// working around it: run() builds one bind.Event from the Bind that matched
// (Chord + OnRelease), or the zero value when no Bind is behind the call
// (i3-mode-forced exits, hold-layer commits, reconciliation — none of which
// python ties to a specific Bind either, though python still had ev.key
// available there and this port does not). A Func that needs to know WHICH
// physical key fired cannot be expressed with today's bind.Func signature;
// that is a pre-existing constraint of the landed bind package, not
// something this task's files can change.
//
// # on_exit and the involuntary exit routes
//
// A layer's on_exit ([[ft011]]) fires on every INVOLUNTARY exit from that
// layer, and NEVER on an exit key — an exit key is the user consciously
// handing the keyboard back to whatever the layer put on screen (see
// matchInLayer). There are exactly three involuntary routes in this port,
// enumerated here rather than left implicit:
//
//  1. An explicit ExitLayer action reaches run() — via a bind's own action
//     list, appended automatically for a one-shot layer's firing bind, or
//     appended by holdReleaseActions when a hold layer commits.
//  2. i3 takes a mode (SetI3Mode, when the new mode is non-default and a
//     layer is active) — dotfiles-hwds.10.
//  3. The daemon shuts down while a layer is active (ShutdownActions,
//     called from cmd/hotkeyd's run-loop teardown, mirroring
//     hotkeyd.py:1507-1524's Daemon.shutdown_actions) — dotfiles-hwds.51:
//     a daemon killed inside a hold layer takes its grabs with it and
//     leaves the layer's overlay on screen with nothing left able to close
//     it.
//
// SIGHUP-triggered reload is explicitly NOT an involuntary exit route in
// this port, though layers.py's on_exit docstring named it as one: the
// Python daemon re-read its bind table live over SIGHUP, so a reload could
// happen mid-layer. sp021's solution drops that capability — binds compile
// into the source (dwm config.h style), so a "reload" is `go build` +
// `hotkeyd.sh restart`: a fresh PROCESS, which is route 3 (shutdown)
// followed by a new start, not a fourth in-process route. [[ft011]] is
// amended to say this in sp021 Task 18 (bd dotfiles-ylmp.17); this
// enumeration is the code-level statement this task's own success
// criterion asks for ("the enumeration in code says so").
//
// The on_exit action list itself MUST BE IDEMPOTENT. Every commit path
// runs its own verb FIRST and its on_exit cleanup SECOND (see
// holdReleaseActions and run()'s bind.ExitLayer case): the switcher's
// on_hold_release commits the selection, and the on_exit that follows in
// the SAME call is a hide on a window the commit may already have hidden.
// An on_exit action that is not safe to run twice — or to run when its
// target is already in the state it asks for — will double-apply on that
// path. Idempotency is a contract on the ACTION a table author supplies;
// this package cannot enforce it (there is nothing to check — the engine
// only ever RUNS the actions it is handed), so it is documented here as
// the requirement it is, exactly as layers.py's _exit_actions docstring
// stated it in prose.
//
// # 120 ms release fall-back guard — permanent, not a workaround
//
// [[ft011]]: xrdp synthesises Shift around every character it sends, so a
// modifier's release can be lost. expireStaleHolds (Python's
// _expire_stale_holds) is the guard: a held-modifier belief with no
// corroborating event for longer than guardMS is dropped. Measured
// permanent on the live :10 session ([[ft011]], 2026-07-28) — narrowing it
// to "real keystrokes only" was tried and abandoned once XI2 measurement
// showed xrdp injects the synthetic Shift at the DEVICE level
// (sourceid 7, same as real keys), so there is nothing to filter on.
// ReleaseGuardMS keeps the same value (120) Python shipped.
package layer

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"hotkeyd/internal/bind"
)

// ReleaseGuardMS is how long a held-modifier belief may go without a
// corroborating event before expireStaleHolds drops it. Sized for xrdp's
// per-character Shift synthesis; permanent, not tunable-by-feel ([[ft011]]).
const ReleaseGuardMS = 120

// KeyWedgeMS bounds how long a non-modifier key may stay believed "down"
// with no observed release before isRepeat gives up treating further
// presses as auto-repeat. A lost release must not make a key permanently
// dead; 1 s is orders of magnitude above any real repeat interval.
const KeyWedgeMS = 1000

// DefaultLayer is what a fresh engine starts in, and what every exit route
// returns to.
const DefaultLayer = "default"

// DefaultI3Mode is what i3 calls "no mode is active" — reported under this
// exact name both in the `mode` event's `change` field and in
// GET_BINDING_STATE.
const DefaultI3Mode = "default"

// modKeysyms maps a modifier keysym name to the canonical modifier name the
// engine tracks holds under. The engine tracks holds from these events
// DIRECTLY rather than trusting an event's reported mask, which is
// pre-event in X (the release of Ctrl still carries the Ctrl bit).
var modKeysyms = map[string]string{
	"Shift_L": "Shift", "Shift_R": "Shift",
	"Control_L": "Ctrl", "Control_R": "Ctrl",
	"Alt_L": "Mod1", "Alt_R": "Mod1", "Meta_L": "Mod1", "Meta_R": "Mod1",
	"Super_L": "Mod4", "Super_R": "Mod4",
}

// Kind is one key event's direction.
type Kind string

const (
	Press   Kind = "press"
	Release Kind = "release"
)

// Event is one key event, X-agnostic so the engine is testable without a
// display — the Go analogue of layers.py's Event dataclass.
//
// Mods is what the SESSION reports as held AT this event — canonical
// modifier names (e.g. "Ctrl", "Mod4"), used only to corroborate or expire
// a hold, never as the primary source (see modKeysyms).
//
// Device / DeviceID are the SOURCE device that produced the event — XI2's
// sourceid (the physical slave) and the name it resolves to, not the
// master in the event header. A zero value ("" / nil) means "unknown",
// matching every X-free test and every unscoped bind's behaviour from
// before device identity existed.
//
// Keycode / RawState are carried for the TRANSITION LOG only — no matching
// decision reads them (dotfiles-hwds.27). nil means the caller did not
// supply one, and the log prints "none" rather than a guessed value.
type Event struct {
	Kind     Kind
	Key      string
	Mods     map[string]bool
	Device   string
	DeviceID *int
	Keycode  *int
	RawState *uint32
}

// State is the layer engine's published shape: which layer is active, and
// which (if any) held-modifier sublayer within it. Mod == "" means no
// active sublayer (the wire encoding is JSON null; sp021 Task 8 / this
// package's publisher.go owns that encoding — this type is the in-memory
// value, not the wire format).
type State struct {
	Layer string
	Mod   string
}

// Publisher receives every state CHANGE (never a repeat). sp021 Task 8's
// StatePublisher (this package's publisher.go, not yet landed) implements
// it against the unix-socket fan-out; tests implement it with an in-memory
// recorder.
type Publisher interface {
	Publish(State)
}

// Config carries NewEngine's optional dependencies, replacing Python's
// keyword-argument defaults (publisher=None, clock=None, ...).
type Config struct {
	Publisher Publisher
	// Clock defaults to time.Now. Tests inject a fake to drive the 120 ms
	// guard and KeyWedgeMS deterministically without wall-clock sleeps.
	Clock func() time.Time
	// GuardMS defaults to ReleaseGuardMS. Overridable only for tests —
	// production code must not tune this by feel ([[ft011]]).
	GuardMS int
	// Mod is what "$mod" resolves to on this display: "Mod4" native,
	// "Mod1" on xrdp. Defaults to bind.DefaultMod.
	Mod string
	// Log defaults to writing "hotkeyd: <msg>" lines to stderr.
	Log func(string)
}

// indexKey is the global bind table's lookup identity: a chord's
// alias-folded, order-insensitive modifier set plus its keysym plus
// press-vs-release. Mirrors layers.py's `_index` tuple key.
type indexKey struct {
	chord     bind.ChordKey
	onRelease bool
}

// Engine turns key events into dispatchable actions and owns layer +
// held-modifier state — the Go port of layers.py's LayerEngine. See the
// package doc for the full method-by-method port table.
type Engine struct {
	binds  []bind.Bind
	layers map[string]bind.Layer

	publisher Publisher
	clock     func() time.Time
	guardMS   int
	mod       string
	log       func(string)

	// i3's binding mode, fed in by the daemon from i3's `mode` event. Starts
	// optimistic (DefaultI3Mode): a daemon that cannot ask i3 must still be
	// usable.
	i3Mode string

	layerName string
	held      map[string]time.Time // canonical modifier -> last corroborated at
	down      map[string]time.Time // non-modifier keys down -> last seen

	// Seeded with the STARTING state in NewEngine, never nil: the contract
	// is "publish on change", and the state a fresh engine is already in is
	// not a change (see publish).
	lastPublished *State

	global map[indexKey][]bind.Bind
}

// NewEngine builds an Engine over binds and layers. binds is copied
// defensively; layers is used as given (bind.Layer values are copied by
// Go's map semantics on read, so aliasing the caller's map is safe).
func NewEngine(binds_ []bind.Bind, layers map[string]bind.Layer, cfg Config) *Engine {
	e := &Engine{
		binds:     append([]bind.Bind(nil), binds_...),
		layers:    layers,
		publisher: cfg.Publisher,
		clock:     cfg.Clock,
		guardMS:   cfg.GuardMS,
		mod:       cfg.Mod,
		log:       cfg.Log,
		i3Mode:    DefaultI3Mode,
		layerName: DefaultLayer,
		held:      map[string]time.Time{},
		down:      map[string]time.Time{},
	}
	if e.clock == nil {
		e.clock = time.Now
	}
	if e.guardMS == 0 {
		e.guardMS = ReleaseGuardMS
	}
	if e.mod == "" {
		e.mod = bind.DefaultMod
	}
	if e.log == nil {
		e.log = defaultLog
	}
	e.lastPublished = &State{Layer: DefaultLayer, Mod: ""}
	e.global = e.buildIndex(e.binds)
	return e
}

func defaultLog(msg string) {
	fmt.Fprintf(os.Stderr, "hotkeyd: %s\n", msg)
}

// -- state --------------------------------------------------------------

// State returns the engine's current published shape.
func (e *Engine) State() State {
	return State{Layer: e.layerName, Mod: e.activeMod()}
}

// activeMod resolves which named modifier sub-layer is active. See the
// package doc ("Sublayer precedence") for why ties break alphabetically by
// label rather than by declaration order.
func (e *Engine) activeMod() string {
	layer, ok := e.layers[e.layerName]
	if !ok {
		return ""
	}
	labels := make([]string, 0, len(layer.Mods))
	for label := range layer.Mods {
		labels = append(labels, label)
	}
	sort.Strings(labels)
	for _, label := range labels {
		m := layer.Mods[label]
		canon, ok := bind.CanonModifier(m.Modifier, e.mod)
		if !ok {
			continue
		}
		if _, held := e.held[string(canon)]; held {
			return label
		}
	}
	return ""
}

// -- hold layers (dotfiles-hwds.40, adr0016) -----------------------------

// holdCanon resolves layer.Hold to a canonical modifier name, or "" when
// the layer is not a hold layer (or its Hold field fails to resolve, which
// Validate should already have refused at load time).
func (e *Engine) holdCanon(layer bind.Layer) string {
	if layer.Hold == "" {
		return ""
	}
	canon, ok := bind.CanonModifier(layer.Hold, e.mod)
	if !ok {
		return ""
	}
	return string(canon)
}

// HoldModifier is the modifier whose release/absence ends the CURRENT
// layer, or "" when the current layer is not a hold layer. Exposed for
// hold.go's PollIdle: a hold layer is the one state where the engine needs
// the SERVER's answer about a modifier it may never have seen pressed.
func (e *Engine) HoldModifier() string {
	layer, ok := e.layers[e.layerName]
	if !ok {
		return ""
	}
	return e.holdCanon(layer)
}

// holdReleaseActions is what to do when canon is confirmed up while the
// current layer holds on it. Deliberately reads NOTHING about whether the
// engine believed the modifier was down — see ReconcileHoldLayer's doc for
// why a belief-gated commit would never fire.
func (e *Engine) holdReleaseActions(canon string) []bind.Action {
	layer, ok := e.layers[e.layerName]
	if !ok || e.holdCanon(layer) != canon {
		return nil
	}
	out := make([]bind.Action, 0, len(layer.OnHoldRelease)+1)
	out = append(out, layer.OnHoldRelease...)
	out = append(out, bind.ExitLayer{})
	return out
}

// exitActions is layerName's on_exit, as a slice (dotfiles-hwds.51). Every
// route out of a layer funnels through run(), so a layer that owns
// something outside the daemon (the switcher's overlay) cannot be left
// behind by a route that forgot to clean up.
func (e *Engine) exitActions(layerName string) []bind.Action {
	layer, ok := e.layers[layerName]
	if !ok {
		return nil
	}
	return layer.OnExit
}

// ShutdownActions is involuntary exit route 3 (see the package doc's "on_exit
// and the involuntary exit routes" section): what must be dispatched before
// the daemon goes away, mirroring hotkeyd.py:1507-1524's
// Daemon.shutdown_actions exactly, including what it deliberately does NOT
// do:
//
//   - Returns rather than dispatches or runs. cmd/hotkeyd's run loop owns
//     the dispatch channel — this is called from ITS shutdown path (a
//     defer/teardown, python's `finally`) — and the actions are handed to
//     the SAME dispatcher every other action goes through, not invoked
//     here. In particular this does NOT go through run(): a bind.Func in
//     an on_exit list is returned un-invoked, exactly as
//     hotkeyd.py's _dispatch only understands Run and a bare i3 command
//     string and silently drops anything else — a pre-existing property of
//     the python shutdown path that this port preserves rather than
//     widens.
//   - Empty when no layer is up, or the current layer IS the default one,
//     so stopping an idle daemon stays silent — a stray cancel would hide
//     an overlay the user opened by hand.
//   - Does not mutate engine state or publish: it is a pure query, called
//     once, as the daemon is already on its way out.
//
// This is the one seam this package exports beyond the 21-method port
// table above: hotkeyd.py's Daemon (a single module) could reach
// engine._exit_actions(layer) directly; Go's package boundary forbids that
// from cmd/hotkeyd, so this wraps exitActions with the exact
// currently-active-layer selection Daemon.shutdown_actions performed
// inline.
func (e *Engine) ShutdownActions() []bind.Action {
	if e.layerName == "" || e.layerName == DefaultLayer {
		return nil
	}
	return e.exitActions(e.layerName)
}

// ReconcileHoldLayer ends the current hold layer when down is false — i.e.
// the server confirms its modifier is NOT down. Returns the actions to
// dispatch (on_hold_release, then an implicit exit).
//
// THE RELEASE-BEFORE-GRAB RACE (adr0016) is why this exists: a fast
// "$mod+Tab" tap can release $mod before the layer's grabs are installed,
// so the release is delivered to whoever had focus and never to this
// daemon — no key event will ever end the layer. Gated on nothing but
// down: not on self.held, which is empty at layer entry by construction
// ($mod is pressed BEFORE the layer exists), so a commit gated on belief
// would never fire ([[adr0016]] consequence 2).
//
// Signature note: layers.py's reconcile_hold_layer(mods_down) took a full
// "what's down right now" set and checked membership for the one canon
// this layer cares about. hold.go's PollIdle already resolves that single
// membership question via one ModifierDown(mod) call before reaching here,
// so this port narrows the parameter to the bool that question answers —
// same adr0016 shape (ask the server, never wait for a release, never
// consult held), pre-resolved by the caller instead of re-derived from a
// set every time.
func (e *Engine) ReconcileHoldLayer(down bool) []bind.Action {
	layer, ok := e.layers[e.layerName]
	if !ok {
		return nil
	}
	canon := e.holdCanon(layer)
	if canon == "" || down {
		return nil
	}
	out := e.run(e.holdReleaseActions(canon), nil)
	e.publish(nil, "hold-released:"+canon)
	return out
}

// -- belief vs. the server (dotfiles-hwds.27) ----------------------------

// Held returns the modifiers the engine currently BELIEVES are down,
// sorted for deterministic assertions. Exposed so a caller's idle path can
// skip reconciliation entirely when there is no belief to check.
func (e *Engine) Held() []string {
	out := make([]string, 0, len(e.held))
	for k := range e.held {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// ReconcileHolds retracts held-modifier beliefs the server does not
// corroborate RIGHT NOW (down). RETRACT ONLY, never assert: a modifier this
// engine never observed being pressed is not added here even when down
// says it is held elsewhere on the display — down is what the SERVER
// reports, held is what THIS DAEMON has seen, and asserting from down alone
// would manufacture a sublayer belonging to some other client's gesture.
//
// The LAYER is deliberately untouched — X has no opinion about "nav", so a
// modifier mismatch here must not cancel a legitimate layer the user is
// standing in.
//
// Returns whether the reconciliation actually changed the published state.
func (e *Engine) ReconcileHolds(down map[string]bool) bool {
	now := e.clock()
	var dropped []string
	for c := range e.held {
		if !down[c] {
			dropped = append(dropped, c)
		}
	}
	sort.Strings(dropped)
	for c := range e.held {
		if down[c] {
			e.held[c] = now
		}
	}
	for _, c := range dropped {
		delete(e.held, c)
	}
	if len(dropped) == 0 {
		return false
	}
	before := e.lastPublished
	e.publish(nil, "reconcile:dropped="+strings.Join(dropped, ","))
	return !statesEqual(before, e.lastPublished)
}

// -- i3-mode arbitration --------------------------------------------------

// I3Mode is the i3 binding mode this engine last heard about.
func (e *Engine) I3Mode() string {
	return e.i3Mode
}

// SetI3Mode feeds i3's binding mode in — the daemon calls this from the
// `mode` event on the IPC connection it already holds. i3 modes hold their
// own passive grabs on the same bare keys a layer wants, so two active
// "modes" mean two owners (dotfiles-hwds.10); arbitration is one-sided
// because i3 grabbed first and cannot be asked to yield.
//
// Returns the cleanup actions (this layer's on_exit) rather than running
// them, since this is called from the i3 event path, which owns dispatch.
// Returns nil when name did not actually change the mode (a no-op).
func (e *Engine) SetI3Mode(name string) []bind.Action {
	if name == "" {
		name = DefaultI3Mode
	}
	if name == e.i3Mode {
		return nil
	}
	e.i3Mode = name
	var out []bind.Action
	if name != DefaultI3Mode && e.layerName != DefaultLayer {
		leaving := e.layerName
		e.layerName = DefaultLayer
		out = e.run(e.exitActions(leaving), nil)
		e.publish(nil, "i3-entered-mode:"+name)
	}
	return out
}

func (e *Engine) i3OwnsKeyboard() bool {
	return e.i3Mode != DefaultI3Mode
}

// -- external-trigger layers (sp023) --------------------------------------

// The named refusals SetExternalLayer answers with. Every one of them is a
// REFUSAL, never a silent no-op ([[us019]] AC4: refused by name): the caller
// is another process, and a request the daemon declines must be
// distinguishable at the socket boundary from one it honoured. Wrapped with
// the offending name via fmt.Errorf, so callers can match the class with
// errors.Is and still report which layer was at fault.
var (
	// ErrNoSuchLayer: the name is in no compiled table at all.
	ErrNoSuchLayer = errors.New("layer: no such layer")
	// ErrNotExternalLayer: the name IS a layer, but a chord-entered one.
	// Chord layers stay chord-only — the runtime half of sp023 plan
	// decision 3, mirroring internal/bind's compile-time R29.
	ErrNotExternalLayer = errors.New("layer: not an external-trigger layer")
	// ErrLayerActive: a chord-entered layer is currently active, so an
	// external process may not touch layer state at all — not even to
	// clear. See SetExternalLayer's doc.
	ErrLayerActive = errors.New("layer: a chord-entered layer is active")
)

// isExternal reports whether name is a declared signal-only layer. An
// unknown name is not external (the caller refuses it separately).
func (e *Engine) isExternal(name string) bool {
	layer, ok := e.layers[name]
	return ok && layer.External
}

// SetExternalLayer enters a declared External layer, or clears one when name
// is DefaultLayer — the runtime half of sp023's external-trigger kind, and
// the ONLY route into a layer that has no chord. The daemon's control socket
// (sp023 Task 3) is its only caller; every other layer stays chord-only.
//
// Accepts exactly two shapes, refusing everything else by name:
//
//   - a name declared External in the compiled table (enter)
//   - DefaultLayer (clear)
//
// and refuses ANY request while a chord-entered layer is active, so an
// external process can never kick the user out of a layer they are standing
// in (sp023 plan decision 3). That guard is checked FIRST, and deliberately
// covers the clear too: a remote `set-layer default` mid-nav would otherwise
// be exactly the eviction the policy exists to forbid. External -> external
// is allowed (the current layer is the daemon's own signal, not the user's
// place), as is entering from default.
//
// Refusals mutate nothing and publish nothing — the engine is provably in
// the state it was in before the call.
//
// # Divergence from EnterLayer while i3 owns a mode (sp023 plan decision 4)
//
// run()'s bind.EnterLayer case REFUSES while i3OwnsKeyboard(), because a
// chord layer's passive grabs would collide with the ones i3's mode already
// holds (dotfiles-hwds.10). SetExternalLayer deliberately does NOT make that
// check, and the divergence is load-bearing rather than an oversight.
//
// Its ORIGINAL motivating example is gone as of sp024: qs-screenshot.sh used
// to put i3 into a real "screenshot" mode for the bar's hint strip before the
// overlay process started, so the drag signal ALWAYS arrived with
// i3Mode == "screenshot" and refusing here would have made the feature
// unreachable in the only flow it existed for. The aiming phase is its own
// External layer now and that i3 mode block is deleted, so the whole gesture
// runs with i3 sitting in "default" — the two set-layer calls the flow makes
// are external -> external.
//
// The divergence STAYS, because what it protects outlives that flow: i3 can
// still own a mode when an external signal arrives. The panic path is the
// live case (hotkeyd stopped, config.d/zz-fallback-binds.conf linked in, the
// user standing in a real nav/resize/$mode_system mode), and a mode i3 owns
// must not make a signal-only layer unreachable. It is safe for the same
// reason it always was: an External layer is SIGNAL-ONLY (sp023 plan
// decision 1) — it holds zero grabs and does not shadow the global table (see
// match()), so there is nothing for i3's mode to collide WITH, and the
// arbitration EnterLayer performs has no subject here.
//
// The reverse direction is unchanged: i3 ENTERING a new non-default mode
// while an external layer is active still force-exits it through SetI3Mode
// (involuntary exit route 2), because that route is about i3 taking the
// keyboard, not about grab arbitration.
func (e *Engine) SetExternalLayer(name string) error {
	if name == "" {
		name = DefaultLayer
	}

	// Authority guard first: a layer the USER entered outranks any external
	// request, including a clear.
	if e.layerName != DefaultLayer && !e.isExternal(e.layerName) {
		return fmt.Errorf("%w: %q is active", ErrLayerActive, e.layerName)
	}

	if name == DefaultLayer {
		if e.layerName == DefaultLayer {
			return nil // ok no-op: callers clear unconditionally on every exit path
		}
		leaving := e.layerName
		e.layerName = DefaultLayer
		// No exitActions: an External layer has no OnExit by construction
		// (internal/bind's R28), so there is nothing to run and no new
		// teardown path to own — see ShutdownActions.
		e.publish(nil, "external-layer-cleared:"+leaving)
		return nil
	}

	layer, ok := e.layers[name]
	if !ok {
		return fmt.Errorf("%w: %q", ErrNoSuchLayer, name)
	}
	if !layer.External {
		return fmt.Errorf("%w: %q", ErrNotExternalLayer, name)
	}
	if e.layerName == name {
		return nil // idempotent re-set; publish-on-change would swallow it anyway
	}
	e.layerName = name
	e.publish(nil, "external-layer-set:"+name)
	return nil
}

// -- publish --------------------------------------------------------------

// publish emits the state IF it changed, and logs the transition with what
// caused it. ev may be nil for a transition with no triggering key event
// (a hold-layer poll commit, an i3-forced exit, a reconciliation) — the log
// then says "trigger=none" rather than inventing one.
func (e *Engine) publish(ev *Event, note string) {
	st := e.State()
	if e.lastPublished != nil && *e.lastPublished == st {
		return
	}
	prev := e.lastPublished
	stCopy := st
	e.lastPublished = &stCopy
	e.log(formatTransition(prev, st, ev, e.Held(), e.i3Mode, note))
	if e.publisher != nil {
		e.publisher.Publish(st)
	}
}

func statesEqual(a, b *State) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// -- event handling ---------------------------------------------------------

// Handle feeds one event and returns the actions to dispatch. Callables
// (bind.Func) are invoked here, since they own their own effect.
func (e *Engine) Handle(ev Event) []bind.Action {
	now := e.clock()
	canon, isModKey := modKeysyms[ev.Key]

	// Expire first, on EVERY event including modifier ones — skipping this
	// let a stale hold win precedence for one publish after a lost release.
	e.expireStaleHolds(ev, now)

	if isModKey {
		if ev.Kind == Press {
			e.held[canon] = now
			e.publish(&ev, "")
			return nil // modifiers never act on their own
		}
		delete(e.held, canon)
		// ...with exactly one exception: a hold layer ends when ITS modifier
		// comes up, expressed as an action rather than a bind.
		out := e.run(e.holdReleaseActions(canon), nil)
		e.publish(&ev, "")
		return out
	}

	var actions []bind.Action
	var matched *bind.Bind
	if ev.Kind == Release {
		// ORPHAN RELEASE (dotfiles-hwds.24): xrdp delivers every character
		// as release-press-release, the leading release arriving before any
		// press. Guarded by what the engine SAW, not a time window: a
		// release for a key this engine never saw go down is not this
		// engine's release.
		_, wasDown := e.down[ev.Key]
		delete(e.down, ev.Key)
		if wasDown {
			actions, matched = e.match(ev, true)
		}
	} else {
		if e.isRepeat(ev.Key, now) {
			// Publish before returning: expiry above may have changed the
			// state, and swallowing it here would show a layer the engine
			// had already left until the key was finally released.
			e.publish(&ev, "")
			return nil // auto-repeat: one action per press
		}
		e.down[ev.Key] = now
		actions, matched = e.match(ev, false)
	}

	out := e.run(actions, matched)
	// Publish ONCE, after the actions have moved the state, so entering a
	// layer costs one line, not two.
	e.publish(&ev, "")
	return out
}

// isRepeat reports whether key looks like an X auto-repeat press: same key,
// no release seen. Bounded by KeyWedgeMS so a genuinely lost release does
// not make the key dead for the rest of the session.
func (e *Engine) isRepeat(key string, now time.Time) bool {
	seen, ok := e.down[key]
	if !ok {
		return false
	}
	if now.Sub(seen) > time.Duration(KeyWedgeMS)*time.Millisecond {
		delete(e.down, key)
		return false
	}
	e.down[key] = now
	return true
}

// expireStaleHolds drops a held-modifier belief the session has stopped
// corroborating for longer than guardMS. Runs on every event (not on a
// timer) — see the package doc's "120 ms release fall-back guard" section
// for why this is permanent.
func (e *Engine) expireStaleHolds(ev Event, now time.Time) {
	for canon, seen := range e.held {
		if ev.Mods[canon] {
			e.held[canon] = now // corroborated, refresh
		} else if now.Sub(seen) > time.Duration(e.guardMS)*time.Millisecond {
			delete(e.held, canon)
		}
	}
}

// -- matching -----------------------------------------------------------

// buildIndex builds the global bind table's chord-identity -> binds map, in
// table order. A slice rather than one Bind per key because device= splits
// one chord across several binds that Validate deliberately does not call
// duplicates (sourceid disambiguates them at dispatch).
func (e *Engine) buildIndex(binds []bind.Bind) map[indexKey][]bind.Bind {
	out := map[indexKey][]bind.Bind{}
	for _, b := range binds {
		ck, err := bind.NormalizeChord(b.Chord, e.mod)
		if err != nil {
			continue // validated at load; skip defensively
		}
		key := indexKey{chord: ck, onRelease: b.OnRelease}
		out[key] = append(out[key], b)
	}
	return out
}

// chordKeyFromEvent builds the same order-insensitive, alias-folded
// identity buildIndex keys binds under, from an event's already-canonical
// mods + key — so match() and buildIndex() agree without re-parsing a
// chord string at dispatch time.
func chordKeyFromEvent(key string, mods map[string]bool) bind.ChordKey {
	names := make([]string, 0, len(mods))
	for m := range mods {
		names = append(names, m)
	}
	sort.Strings(names)
	return bind.ChordKey{Mods: strings.Join(names, "+"), Key: key}
}

// match finds the actions for ev, and the Bind they came from (nil if none,
// or if dispatch happened through a layer's tuple-return path where no
// single Bind pointer is meaningful — matchInLayer always returns one when
// it returns actions). While a layer is active, only ITS table is
// consulted — i3-mode-style shadowing of the global table.
//
// EXCEPT for an External layer (sp023 plan decision 1), which is SIGNAL-ONLY
// and falls through to the global index exactly as the default layer does.
// It has no table to consult — internal/bind's R28 refuses an External layer
// that declares Binds at all — so routing it through matchInLayer would not
// merely be pointless, it would make every global chord dead for as long as
// the layer is up. That is the stranded-external-layer hazard [[us019]] AC5
// forbids ("if the process owning the binds stops, the session remains
// usable"): the layer is cleared by a verb from a process that may have
// died, so its cost must be pixels (a border cue), never keys.
func (e *Engine) match(ev Event, onRelease bool) ([]bind.Action, *bind.Bind) {
	if layer, ok := e.layers[e.layerName]; ok && !layer.External {
		return e.matchInLayer(layer, ev, onRelease)
	}
	key := indexKey{chord: chordKeyFromEvent(ev.Key, ev.Mods), onRelease: onRelease}
	for _, b := range e.global[key] {
		if deviceMatches(b, ev) {
			bb := b
			return bb.Actions, &bb
		}
	}
	return nil, nil
}

// matchInLayer matches ev against layer's own table (or the active
// sublayer's, if any modifier is held). Exit keys are matched FIRST, on the
// bare keysym alone — deliberately ignoring held modifiers, so a layer
// stays leavable one-handed.
func (e *Engine) matchInLayer(layer bind.Layer, ev Event, onRelease bool) ([]bind.Action, *bind.Bind) {
	if !onRelease && containsString(layer.ExitKeys, ev.Key) {
		e.layerName = DefaultLayer
		// on_exit is deliberately NOT run here (dotfiles-hwds.51 stops short
		// of this route): an exit key is the user consciously handing the
		// keyboard back to whatever the layer put on screen.
		return nil, nil
	}

	modLabel := e.activeMod()
	table := layer.Binds
	if modLabel != "" {
		table = layer.Mods[modLabel].Binds
	}
	for _, b := range table {
		if b.Chord == ev.Key && b.OnRelease == onRelease && deviceMatches(b, ev) {
			bb := b
			if layer.OneShot {
				out := make([]bind.Action, 0, len(bb.Actions)+1)
				out = append(out, bb.Actions...)
				out = append(out, bind.ExitLayer{})
				return out, &bb
			}
			return bb.Actions, &bb
		}
	}
	return nil, nil
}

func containsString(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

// deviceMatches reports whether bnd accepts ev's SOURCE device. An unscoped
// bind (Device == "") accepts anything; a scoped bind accepts only its own
// device — and deliberately NOT an event whose source could not be
// resolved, since an unattributable event must not satisfy a predicate
// whose whole purpose is attribution.
func deviceMatches(bnd bind.Bind, ev Event) bool {
	if bnd.Device == "" {
		return true
	}
	return ev.Device == bnd.Device
}

// -- running actions ------------------------------------------------------

// bindEventFor builds the bind.Event a Func action receives when b is the
// Bind whose action list is being run — or the zero value when there is no
// specific Bind behind the call (on_exit, hold commits, i3-mode-forced
// exits, reconciliation). See the package doc's "callable actions" section
// for why this is smaller than layers.py's raw Event.
func bindEventFor(b *bind.Bind) bind.Event {
	if b == nil {
		return bind.Event{}
	}
	return bind.Event{Chord: b.Chord, OnRelease: b.OnRelease}
}

// run dispatches actions, resolving layer verbs and invoking callables
// in place; everything else (Command, Run) is returned for the caller to
// dispatch. srcBind is the Bind actions came from, if any — see
// bindEventFor.
func (e *Engine) run(actions []bind.Action, srcBind *bind.Bind) []bind.Action {
	bev := bindEventFor(srcBind)
	var out []bind.Action
	for _, a := range actions {
		switch v := a.(type) {
		case bind.EnterLayer:
			if e.isExternal(v.Layer) {
				// Defense in depth (sp023 plan decision 3): internal/bind's
				// R29 already refuses this table at load time, so this is
				// unreachable on anything --check accepted. Kept because the
				// consequence of it being wrong is silent — a chord would
				// enter a layer that holds no grabs and matches no keys —
				// and because the engine is also driven by tests and future
				// callers that never went through Validate. Logged like the
				// i3-mode refusal below rather than swallowed.
				e.log(fmt.Sprintf("refusing to enter layer %q by chord: it is an external-trigger layer (set-layer only)", v.Layer))
				continue
			}
			if e.i3OwnsKeyboard() {
				// The layer's grabs would be refused by X anyway; not
				// entering means the daemon never asks for them, so its
				// state cannot disagree with reality.
				e.log(fmt.Sprintf("refusing to enter layer %q: i3 is in mode %q", v.Layer, e.i3Mode))
				continue
			}
			e.layerName = v.Layer
		case bind.ExitLayer:
			leaving := e.layerName
			e.layerName = DefaultLayer
			// Appended AFTER whatever already ran, so a commit runs first
			// and this only tidies up behind it (dotfiles-hwds.51).
			for _, extra := range e.exitActions(leaving) {
				if fn, ok := extra.(bind.Func); ok {
					if err := fn(bev); err != nil {
						e.log(fmt.Sprintf("on_exit action error: %v", err))
					}
				} else {
					out = append(out, extra)
				}
			}
		case bind.Func:
			if err := v(bev); err != nil {
				e.log(fmt.Sprintf("action error: %v", err))
			}
		default:
			out = append(out, a)
		}
	}
	return out
}

// -- transition log (dotfiles-hwds.27) -------------------------------------

// formatTransition renders one line describing a published state change and
// why it happened — the Go port of layers.py's format_transition. Every
// field earns its place discriminating a real cause from a spurious layer
// belief; a field the daemon could not resolve prints "none" rather than a
// guessed value.
func formatTransition(prev *State, next State, ev *Event, held []string, i3Mode, note string) string {
	prevLayer := DefaultLayer
	prevMod := ""
	if prev != nil {
		prevLayer = prev.Layer
		prevMod = prev.Mod
	}
	parts := []string{
		"transition",
		fmt.Sprintf("layer=%s->%s", prevLayer, next.Layer),
		fmt.Sprintf("mod=%s->%s", orNoneStr(prevMod), orNoneStr(next.Mod)),
	}
	if ev == nil {
		parts = append(parts, "trigger=none")
	} else {
		modsList := make([]string, 0, len(ev.Mods))
		for m := range ev.Mods {
			modsList = append(modsList, m)
		}
		sort.Strings(modsList)
		modsStr := "none"
		if len(modsList) > 0 {
			modsStr = strings.Join(modsList, ",")
		}
		parts = append(parts,
			fmt.Sprintf("trigger=%s:%s", ev.Kind, ev.Key),
			"keycode="+orNoneInt(ev.Keycode),
			"mask="+orNoneMask(ev.RawState),
			"mods="+modsStr,
			"sourceid="+orNoneInt(ev.DeviceID),
			"device="+orNoneDevice(ev.Device),
		)
	}
	heldStr := "none"
	if len(held) > 0 {
		heldStr = strings.Join(held, ",")
	}
	parts = append(parts, "held="+heldStr, "i3_mode="+i3Mode)
	if note != "" {
		parts = append(parts, "note="+note)
	}
	return strings.Join(parts, " ")
}

func orNoneStr(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func orNoneInt(p *int) string {
	if p == nil {
		return "none"
	}
	return strconv.Itoa(*p)
}

func orNoneMask(p *uint32) string {
	if p == nil {
		return "none"
	}
	return fmt.Sprintf("0x%04x", *p)
}

func orNoneDevice(d string) string {
	if d == "" {
		return "none"
	}
	return fmt.Sprintf("%q", d)
}
