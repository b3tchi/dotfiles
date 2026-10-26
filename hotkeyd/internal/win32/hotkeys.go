package win32

// sp012 Task 4 (kwi3-hoex.4): the RegisterHotKey grab manager. It is the
// Windows twin of cmd/hotkeyd's X11 GrabManager and internal/kwin's: the
// daemon hands it the chords the engine's current layer wants
// (SyncBinds), and it registers what it can and lists what it cannot.
//
// This file is pure Go with no build tag, so its decisions are tested on
// Linux: every Win32 call goes through Registrar, which the Windows build
// implements on its message-only window's thread (hotkeys_windows.go) and
// a test implements with a recorder.

import (
	"errors"
	"fmt"
	"sort"
	"syscall"

	"hotkeyd/internal/bind"
)

// RegisterHotKey's errors the report names (WinError.h).
const (
	ERROR_HOTKEY_ALREADY_REGISTERED syscall.Errno = 1409
	ERROR_HOTKEY_NOT_REGISTERED     syscall.Errno = 1419
)

// WM_HOTKEY is the message RegisterHotKey's window receives (WinUser.h).
const WM_HOTKEY uint32 = 0x0312

// Registrar is the Win32 surface the manager calls. Register is
// RegisterHotKey(window, id, mods, vk) with mods passed through exactly
// (the manager adds MOD_NOREPEAT); Unregister is UnregisterHotKey.
type Registrar interface {
	Register(id int32, mods uint32, vk uint16) error
	Unregister(id int32) error
}

// Chord is what a registration answers to, in the values every key source
// speaks after it: the base keysym of the registered VK and the X11
// modifier bits of the registered MOD_* set. A WM_HOTKEY translated by
// Translate reads back as exactly this pair.
type Chord struct {
	Keysym uint32
	Mods   uint32
}

// Event is one WM_HOTKEY, translated.
type Event struct {
	VK     uint16
	Keysym uint32
	Mods   uint32 // X11 bits
}

// Translate turns a WM_HOTKEY's lParam (low word the MOD_* set, high word
// the VK) into the keysym and X11 modifier bits of the key pressed. false
// for a VK the translator has no keysym for.
func Translate(lParam uintptr) (Event, bool) {
	mods := uint32(lParam & 0xffff)
	vk := uint16((lParam >> 16) & 0xffff)
	ks, ok := ToKeysym(vk)
	if !ok {
		return Event{}, false
	}
	return Event{VK: vk, Keysym: ks, Mods: X11Mods(mods)}, true
}

// X11Mods is HotkeyMods' inverse: RegisterHotKey's MOD_* bits as X11
// modifier bits. MOD_NOREPEAT and any unknown bit are ignored.
func X11Mods(hotkey uint32) uint32 {
	var m uint32
	if hotkey&MOD_SHIFT != 0 {
		m |= ModShift
	}
	if hotkey&MOD_CONTROL != 0 {
		m |= ModCtrl
	}
	if hotkey&MOD_ALT != 0 {
		m |= ModAlt
	}
	if hotkey&MOD_WIN != 0 {
		m |= ModSuper
	}
	return m
}

var bindModBits = map[bind.Modifier]uint32{
	bind.Shift: ModShift, bind.Ctrl: ModCtrl, bind.Mod1: ModAlt, bind.Mod4: ModSuper,
}

// ReasonOnRelease is why a chord bound only on release is not registered:
// WM_HOTKEY reports the press alone. Task 5's low-level hook serves it.
const ReasonOnRelease = "fires on release, which RegisterHotKey cannot report (the low-level hook, sp012 Task 5)"

// ReasonNoHook is why a chord the hook would serve is not served: the
// hook is not installed (SetWindowsHookEx refused it).
const ReasonNoHook = "needs the low-level hook, which is not installed"

// HookSink is where the manager hands the chords the low-level hook owns
// (*Hook implements it).
type HookSink interface {
	SetOwned(map[Chord]bool)
}

// ReasonReserved is why the panic chord is never registered (adr0003: it
// is the host's own key).
const ReasonReserved = "reserved: the panic/recover chord belongs to the host, never hotkeyd"

// registration is one RegisterHotKey this manager holds.
type registration struct {
	id    int32
	vk    uint16
	mods  uint32 // MOD_* without MOD_NOREPEAT
	chord Chord
}

// Hotkeys is the grab manager.
type Hotkeys struct {
	reg         Registrar
	mod         string
	keysym      func(string) (uint32, bool)
	releaseOnly func(string) bool
	log         func(string)

	hook    HookSink
	viaHook func(string) bool
	hooked  map[string]registration

	nextID   int32
	wanted   []string
	active   map[string]registration
	refused  map[string]string
	reported map[string]bool
}

// NewHotkeys builds a manager over reg. mod is what $mod resolves to;
// keysym resolves a keysym name; releaseOnly says whether a chord has only
// on-release binds (nil: none has); log may be nil.
func NewHotkeys(reg Registrar, mod string, keysym func(string) (uint32, bool), releaseOnly func(string) bool, log func(string)) *Hotkeys {
	if releaseOnly == nil {
		releaseOnly = func(string) bool { return false }
	}
	if log == nil {
		log = func(string) {}
	}
	return &Hotkeys{reg: reg, mod: mod, keysym: keysym, releaseOnly: releaseOnly, log: log,
		nextID: 1, active: map[string]registration{}, hooked: map[string]registration{}, refused: map[string]string{}, reported: map[string]bool{}}
}

// UseHook routes every chord viaHook answers true for to the low-level
// hook instead of RegisterHotKey (sp012 Task 5): a hold layer's chords and
// its entry chord, and chords bound only on release. sink nil means the
// hook could not be installed: those chords are then refused with
// ReasonNoHook. Call before the first SyncBinds.
func (h *Hotkeys) UseHook(sink HookSink, viaHook func(string) bool) {
	h.hook = sink
	h.viaHook = viaHook
	if h.hook == nil {
		h.hook = noHook{}
	}
}

type noHook struct{}

func (noHook) SetOwned(map[Chord]bool) {}

// hooking reports whether chord goes to the hook rather than RegisterHotKey.
func (h *Hotkeys) hooking(chord string) bool {
	return h.viaHook != nil && h.viaHook(chord)
}

// resolve turns a chord into the VK and MOD_* set to register, or the
// reason it cannot be registered.
func (h *Hotkeys) resolve(chord string) (registration, string) {
	if k, err := bind.NormalizeChord(chord, h.mod); err == nil && bind.ReservedChords[k] {
		return registration{}, ReasonReserved
	}
	mods, name, err := bind.ParseChord(chord, h.mod)
	if err != nil {
		return registration{}, err.Error()
	}
	if h.releaseOnly(chord) && !h.hooking(chord) {
		return registration{}, ReasonOnRelease
	}
	ks, ok := h.keysym(name)
	if !ok {
		return registration{}, fmt.Sprintf("keysym %q is not known to the grab table", name)
	}
	key, err := Resolve(ks)
	if err != nil {
		return registration{}, err.Error()
	}
	var x uint32
	for m := range mods {
		bit, ok := bindModBits[m]
		if !ok {
			return registration{}, fmt.Sprintf("modifier %s has no Windows modifier", m)
		}
		x |= bit
	}
	if key.Shift {
		x |= ModShift
	}
	hk, err := HotkeyMods(x)
	if err != nil {
		return registration{}, err.Error()
	}
	base, _ := ToKeysym(key.VK)
	return registration{vk: key.VK, mods: hk, chord: Chord{Keysym: base, Mods: x}}, ""
}

// SyncBinds makes the registered set the chords asked for: chords no
// longer wanted are unregistered first, then every wanted chord not yet
// registered is registered once. A refusal is recorded and logged once;
// it is tried again only on a later SyncBinds that still wants it, never
// in a loop. Returns whether the registered set changed.
func (h *Hotkeys) SyncBinds(chords []string) bool {
	seen := map[string]bool{}
	var wanted []string
	for _, ch := range chords {
		if !seen[ch] {
			seen[ch] = true
			wanted = append(wanted, ch)
		}
	}
	h.wanted = wanted
	changed := false

	// Old set out first, so a chord moving between two strings of the
	// same key never collides with its own earlier registration.
	gone := make([]string, 0)
	for ch := range h.active {
		if !seen[ch] {
			gone = append(gone, ch)
		}
	}
	sort.Strings(gone)
	for _, ch := range gone {
		r := h.active[ch]
		if err := h.reg.Unregister(r.id); err != nil {
			h.log(fmt.Sprintf("UnregisterHotKey %s: %s", ch, ErrorName(err)))
		}
		delete(h.active, ch)
		changed = true
	}
	for ch := range h.refused {
		if !seen[ch] {
			delete(h.refused, ch)
		}
	}

	type combo struct {
		vk   uint16
		mods uint32
	}

	// The hook's share first: a chord the hook serves, and any other chord
	// on the same key (the hook sees the key before RegisterHotKey would,
	// so a registration of it could never fire), is never registered.
	hooked := map[string]registration{}
	hookCombos := map[combo]bool{}
	if h.viaHook != nil {
		for _, ch := range wanted {
			if !h.hooking(ch) {
				continue
			}
			r, why := h.resolve(ch)
			if why != "" {
				h.refuse(ch, why)
				continue
			}
			hooked[ch] = r
			hookCombos[combo{r.vk, r.mods}] = true
		}
		for _, ch := range wanted {
			if _, ok := hooked[ch]; ok || h.hooking(ch) {
				continue
			}
			if r, why := h.resolve(ch); why == "" && hookCombos[combo{r.vk, r.mods}] {
				hooked[ch] = r
			}
		}
		for ch, r := range h.active {
			if _, ok := hooked[ch]; ok {
				if err := h.reg.Unregister(r.id); err != nil {
					h.log(fmt.Sprintf("UnregisterHotKey %s: %s", ch, ErrorName(err)))
				}
				delete(h.active, ch)
				changed = true
			}
		}
		if _, none := h.hook.(noHook); none {
			for ch := range hooked {
				h.refuse(ch, ReasonNoHook)
			}
			hooked = map[string]registration{}
		} else {
			for ch := range hooked {
				delete(h.refused, ch)
			}
		}
		if !sameKeys(hooked, h.hooked) {
			changed = true
		}
		h.hooked = hooked
		owned := make(map[Chord]bool, len(hooked))
		for _, r := range hooked {
			owned[r.chord] = true
		}
		h.hook.SetOwned(owned)
	}

	held := map[combo]string{}
	for _, ch := range wanted {
		if r, ok := h.active[ch]; ok {
			held[combo{r.vk, r.mods}] = ch
		}
	}
	for _, ch := range wanted {
		if _, ok := h.active[ch]; ok {
			continue
		}
		if _, ok := hooked[ch]; ok || (h.viaHook != nil && h.hooking(ch)) {
			continue // the hook's, served or refused above
		}
		r, why := h.resolve(ch)
		if why != "" {
			h.refuse(ch, why)
			continue
		}
		if other, ok := held[combo{r.vk, r.mods}]; ok {
			h.refuse(ch, fmt.Sprintf("the same key as %s, already registered", other))
			continue
		}
		r.id = h.nextID
		h.nextID++
		if err := h.reg.Register(r.id, r.mods|MOD_NOREPEAT, r.vk); err != nil {
			h.refuse(ch, "RegisterHotKey refused: "+ErrorName(err))
			continue
		}
		delete(h.refused, ch)
		h.active[ch] = r
		held[combo{r.vk, r.mods}] = ch
		changed = true
	}
	return changed
}

func (h *Hotkeys) refuse(chord, why string) {
	h.refused[chord] = why
	msg := chord + ": " + why
	if !h.reported[msg] {
		h.reported[msg] = true
		h.log("grab problem: " + msg)
	}
}

func sameKeys(a, b map[string]registration) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if _, ok := b[k]; !ok {
			return false
		}
	}
	return true
}

// ReleaseAll unregisters everything, for shutdown. (Windows frees a
// thread's registrations when it exits anyway; this makes the order
// explicit.)
func (h *Hotkeys) ReleaseAll() {
	for ch, r := range h.active {
		_ = h.reg.Unregister(r.id)
		delete(h.active, ch)
	}
	if h.viaHook != nil {
		h.hooked = map[string]registration{}
		h.hook.SetOwned(nil)
	}
}

// OnMappingNotify is a no-op: the US layout is fixed (keymap.go).
func (h *Hotkeys) OnMappingNotify() bool { return false }

// Active is a copy of the chords served: registered, or owned by the hook.
func (h *Hotkeys) Active() map[string]Chord {
	out := make(map[string]Chord, len(h.active)+len(h.hooked))
	for k, r := range h.active {
		out[k] = r.chord
	}
	for k, r := range h.hooked {
		out[k] = r.chord
	}
	return out
}

// Hooked is a copy of the chords the low-level hook owns.
func (h *Hotkeys) Hooked() map[string]Chord {
	out := make(map[string]Chord, len(h.hooked))
	for k, r := range h.hooked {
		out[k] = r.chord
	}
	return out
}

// Wanted is the requested chord list, in order.
func (h *Hotkeys) Wanted() []string { return append([]string(nil), h.wanted...) }

// Refused is a copy of the wanted chords not registered, with why.
func (h *Hotkeys) Refused() map[string]string {
	out := make(map[string]string, len(h.refused))
	for k, v := range h.refused {
		out[k] = v
	}
	return out
}

// GrabReport counts wanted vs registered. Each missing entry is the chord
// and why it is not registered ("$mod+x: RegisterHotKey refused:
// ERROR_HOTKEY_ALREADY_REGISTERED (1409)"), so the report itself says which
// chords were refused and with what Windows error.
func (h *Hotkeys) GrabReport() (wanted, active int, missing []string) {
	served := 0
	for _, ch := range h.wanted {
		if _, ok := h.active[ch]; ok {
			served++
			continue
		}
		if _, ok := h.hooked[ch]; ok {
			served++
			continue
		}
		why := h.refused[ch]
		if why == "" {
			why = "not registered"
		}
		missing = append(missing, ch+": "+why)
	}
	sort.Strings(missing)
	return len(h.wanted), served, missing
}

// ErrorName names a Win32 error the way the grab report prints it.
func ErrorName(err error) string {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		switch errno {
		case ERROR_HOTKEY_ALREADY_REGISTERED:
			return "ERROR_HOTKEY_ALREADY_REGISTERED (1409)"
		case ERROR_HOTKEY_NOT_REGISTERED:
			return "ERROR_HOTKEY_NOT_REGISTERED (1419)"
		}
		return fmt.Sprintf("Windows error %d", uint32(errno))
	}
	return err.Error()
}
