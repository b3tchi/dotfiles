package bind

// Event is the minimal fact set an Action needs about the keystroke that
// fired it. cmd/hotkeyd owns the real dispatch event shape (X device
// attribution, timestamps, ...); this package only needs a name to give
// Func a concrete signature, since bind/validate never construct an Event
// themselves — they only carry the type.
type Event struct {
	Chord     string
	OnRelease bool
}

// Action is anything a bind (or a layer's OnHoldRelease / OnExit) can
// dispatch: an i3 command string, a Run spawn, a layer verb, or an arbitrary
// Go func. binds.py expresses the same union with
// `Union[str, Run, EnterLayer, ExitLayer, Callable]`; Go has no union types,
// so each variant is its own type implementing the isAction marker method,
// and a Bind's action list is always a slice — binds.py allows a bare
// action OR a tuple of actions, and collapsing that into "always a slice"
// removes a branch every caller would otherwise have to make.
type Action interface {
	isAction()
}

// Command is a literal i3 command string, e.g. "focus left".
type Command string

func (Command) isAction() {}

// Run spawns a process. Distinct from Command so the daemon need not route
// every action through i3.
type Run struct {
	Cmd string
}

func (Run) isAction() {}

// EnterLayer switches the active layer to Layer.
type EnterLayer struct {
	Layer string
}

func (EnterLayer) isAction() {}

// ExitLayer returns to the default layer.
type ExitLayer struct{}

func (ExitLayer) isAction() {}

// Func is an arbitrary callable action, taking the event that fired it. Its
// body is never inspected by Validate — binds.py does not introspect a
// Python callable either, so there is no corresponding rejection rule for
// it, by design.
type Func func(Event) error

func (Func) isAction() {}

// Bind is one chord -> action(s) mapping.
type Bind struct {
	// Chord is a "+"-joined modifier/keysym string, e.g. "$mod+Shift+q". The
	// $mod token resolves per display (see ParseChord); the modifiers
	// preceding the final "+" may use any spelling in modifierAliases; the
	// keysym after the last "+" must be a known static keysym name (never a
	// keycode — keycodes differ per session, poc013).
	Chord string

	// Actions dispatches in order when the chord fires. A bind with one
	// action is still a one-element slice; see the Action doc for why.
	Actions []Action

	// OnRelease fires this bind on key release instead of key press. Part
	// of the duplicate-detection identity: a press bind and a release bind
	// on the same chord are different events, not a collision (i3 does the
	// same with --release).
	OnRelease bool

	// Device restricts this bind to one source device, by name as XI2
	// reports it (`xinput list`). "" — the zero value — means "any source".
	// Core X11 KeyPress carries no device identity at all, which is why the
	// daemon grabs through XI2: XIDeviceEvent.sourceid is the only channel
	// that can tell one keyboard from another, or a real keystroke from an
	// injected one, since injection and real input share a display. Part of
	// the duplicate-detection identity: two binds on one chord scoped to
	// DIFFERENT devices are disambiguated at dispatch by sourceid and
	// cannot double-fire, so they are NOT a collision; two binds on one
	// chord with the SAME device (including both "") still collide
	// ([[ft011]] api_surface, verbatim).
	Device string

	// DisplayMod scopes this bind to ONE $mod resolution ("" — the zero
	// value — means every display, i.e. today's behaviour, us020 AC5). When
	// set it must be a recognised modifier name (folds through the same
	// aliases a chord's modifiers do — "super", "win", "mod4" all mean
	// Mod4). Validated headless regardless of which resolution Validate is
	// called with (us020 AC2) — see the package doc for how it interacts
	// with duplicate detection and RESERVED_CHORDS.
	DisplayMod string
}

// IgnoreDevices is the process-wide list of source devices, by XI2 name,
// whose events the daemon drops outright — matched against the SOURCE
// (slave) device, never the master. Ships EMPTY by default, deliberately:
// see hotkeyd/binds.py's IGNORE_DEVICES comment ([[ft011]]) for why XTEST
// cannot be assumed safe to drop. Not itself subject to Validate: binds.py's
// validate() does not check IGNORE_DEVICES either, since it is a plain
// dispatch-time filter with no table-shape implication. cmd/hotkeyd owns
// setting this from the compiled table (a later task); this package only
// carries the type/field so the table can express it.
var IgnoreDevices []string

// Mod is a held-modifier sub-layer: while Modifier is down, Binds apply
// (e.g. nav's Ctrl-held "move" sublayer). Modifier is resolved the same way
// a Layer's Hold modifier is — see CanonModifier — including the $mod
// token.
type Mod struct {
	Modifier string
	Binds    []Bind
}

// Layer is a named table grabbed only while it is active. Four shapes exist
// ([[ft011]] "## layers"): persistent (entered by a chord, left by an exit
// key), one-shot (OneShot: any bind that fires returns to default),
// hold (Hold set: lives exactly as long as Hold is down, ends by asking the
// server — [[adr0016]]), and sublayers (Mods: a second table while a
// modifier is held on top of this one).
type Layer struct {
	// Binds is this layer's own bind table, matched against the BARE
	// keysym of the event (no modifier) — see the R06 rejection rule.
	Binds []Bind

	// Mods declares held-modifier sub-layers, keyed by an arbitrary label
	// used only in problem messages and the doc (e.g. "move", "resize").
	Mods map[string]Mod

	// ExitKeys leaves the layer, matched on the bare keysym regardless of
	// any modifier still held — a layer with no ExitKeys can never be left
	// (rule R20).
	ExitKeys []string

	// OneShot returns to the default layer as soon as ANY bind here fires
	// — a menu you answer once rather than a mode you stand in. A key
	// matching nothing is swallowed exactly as in a persistent layer.
	OneShot bool

	// Hold, when set, makes this a HOLD layer: it lives exactly as long as
	// Hold is down and ends by asking the server whether Hold is still
	// down, never by waiting for a release event ([[adr0016]] — the
	// modifier is already down when the layer is entered, so a passive
	// grab on it never activates and no release is deliverable). "" means
	// this is not a hold layer. Resolved the same way a chord's modifiers
	// are — the $mod token is accepted here too.
	Hold string

	// OnHoldRelease dispatches when Hold's release is observed (or the
	// server confirms it is up). Declaring this with Hold == "" is
	// rejected (rule R14) — nothing could ever dispatch it.
	OnHoldRelease []Action

	// OnExit dispatches on every INVOLUNTARY exit from this layer — an
	// explicit exit action, i3 taking a mode, daemon shutdown, or (in the
	// Python daemon) a SIGHUP reload. Exit keys are excluded by design:
	// they are the user handing the keyboard back to whatever the layer
	// put on screen. The action must be idempotent, because the commit
	// paths run their own verb first. nil means no on-exit action (opt-in
	// per layer). Not itself checked by Validate — binds.py's validator
	// does not inspect on_exit either.
	OnExit []Action
}
