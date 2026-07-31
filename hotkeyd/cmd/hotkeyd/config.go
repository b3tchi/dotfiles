// Package main hosts the hotkeyd daemon binary. This file is the Go
// transcription of hotkeyd/binds.py's declarative bind table (sp021 Task 6,
// bd dotfiles-ylmp.5) — same chords, same actions, same layers, expressed in
// the internal/bind package's types instead of binds.py's dataclasses.
//
// Kept a straight port rather than a redesign: every group below carries a
// short comment naming the binds.py group it came from, so a diff against
// binds.py stays legible group by group. The rationale prose that lives
// alongside each group in binds.py (why this chord and not that one, what
// broke before, what was measured on which display) is NOT duplicated here —
// binds.py remains the source of truth for that history for the duration of
// the parallel-run window; TestGoldenDumpParity is what keeps this table
// from silently drifting away from it.
//
// us020 (per-display $mod qualifiers, bind.Bind.DisplayMod) has not shipped
// in binds.py as of this port (status: draft) — see docs/notes/us020.md — so
// no DisplayMod-qualified entries appear below. The two motivating cases
// named in that story ($mod+w and a native-only Alt+Tab) are correspondingly
// ABSENT from binds.py itself right now and so are absent here too; adding
// them is a Python change first, a Go change (and a DisplayMod field) second.
//
// # A malformed entry fails go build, not go test
//
// binds.py's Bind is a Python dataclass: `chord: str` is a type HINT, never
// enforced at construction, so `Bind(42, 'kill')` or `Bind('$mod+q', 5)`
// builds a Bind object just fine and is only caught later, at runtime, by
// validate() walking the table. bind.Bind is a real Go struct, so the same
// mistakes are a compiler error before any binary exists — no runtime check
// needed for these at all. For instance, this does NOT compile:
//
//	// cannot use 42 (untyped int constant) as string value in struct literal
//	bind.Bind{Chord: 42, Actions: []bind.Action{bind.Command("focus left")}}
//
//	// cannot use "focus left" (untyped string constant) as bind.Action value
//	// in array or slice literal: bind.Command("focus left") is needed
//	bind.Bind{Chord: "$mod+q", Actions: []bind.Action{"focus left"}}
//
//	// missing field Layer in struct literal of type bind.EnterLayer
//	// (only when using keyed-and-unkeyed mixed literals; EnterLayer{} alone
//	// compiles with Layer=="" and is instead caught by Validate's R13 —
//	// "enters a layer which does not exist" — since "" is never a real
//	// layer name. The FIELD TYPE is what the compiler enforces; whether a
//	// non-empty string names a REAL layer is necessarily a runtime check on
//	// both sides, because it depends on the rest of the table.)
//	bind.EnterLayer{NotAField: "nav"}
//
// bind.Validate (internal/bind, bd dotfiles-ylmp.4) is what still runs at
// test time in this package (TestValidatorOverRealTable_BothModResolutions)
// — it catches exactly the class of problem no compiler can: duplicate
// chords, the reserved panic chord, a layer with no exit_keys, and so on.
package main

import (
	"fmt"

	"hotkeyd/internal/bind"
)

// ---------------------------------------------------------------------------
// shared constants — verbatim from binds.py's WS_SWITCH / NAV_STEP /
// QS_OVERLAY and the quickshell script paths named inline in its table.
// ---------------------------------------------------------------------------

const (
	wsSwitch  = "~/.local/bin/ws-switch.nu"
	navStep   = "5 px or 5 ppt"
	qsOverlay = "~/.dotfiles/quickshell/qs-overlay.sh"

	qsScreenshot = "~/.dotfiles/quickshell/qs-screenshot.sh"
	qsNotif      = "~/.dotfiles/quickshell/qs-notif.sh"
	qsClip       = "~/.dotfiles/quickshell/qs-clip.sh"
)

// cmdAction and runAction wrap the single-action-slice shape every Bind.Actions
// needs, mirroring binds.py's actions_of() collapsing "one action or many"
// into always-a-list on the Go side (see bind.Action's doc).
func cmdAction(s string) []bind.Action { return []bind.Action{bind.Command(s)} }
func runAction(s string) []bind.Action { return []bind.Action{bind.Run{Cmd: s}} }

// ---------------------------------------------------------------------------
// direction tables — Go twin of binds.py's _DIRS / _ARROWS. Shared by the
// nav layer, the standalone resize layer, and the global directional group
// so the four ways "left" gets spelled cannot drift apart from each other,
// same argument binds.py makes for keeping one source table.
// ---------------------------------------------------------------------------

type dirEntry struct {
	key    string // letter keysym: h, j, k, l
	focus  string // "focus"/"move" direction word
	resize string // "resize" verb, e.g. "shrink width"
}

// Order matches binds.py's _DIRS dict literal (h, j, k, l).
var dirs = []dirEntry{
	{"h", "left", "shrink width"},
	{"j", "down", "grow height"},
	{"k", "up", "shrink height"},
	{"l", "right", "grow width"},
}

type arrowEntry struct {
	arrow string // X keysym name: Left, Down, Up, Right
	dir   string // the letter key it mirrors
}

// Order matches binds.py's _ARROWS dict literal (Left, Down, Up, Right).
var arrows = []arrowEntry{
	{"Left", "h"},
	{"Down", "j"},
	{"Up", "k"},
	{"Right", "l"},
}

// arrowsForDir returns every arrow keysym that mirrors letter key dirKey —
// binds.py's `[a for a, d in _ARROWS.items() if d == key]`.
func arrowsForDir(dirKey string) []string {
	var out []string
	for _, a := range arrows {
		if a.dir == dirKey {
			out = append(out, a.arrow)
		}
	}
	return out
}

// dirByKey looks up a dirEntry by its letter key, for the resize layer's
// arrow pass (binds.py indexes `_DIRS[key][1]` there).
func dirByKey(key string) dirEntry {
	for _, d := range dirs {
		if d.key == key {
			return d
		}
	}
	panic("cmd/hotkeyd: no dirEntry for key " + key) // unreachable: arrows only ever names dirs' own keys
}

// navBinds is binds.py's _nav_binds(kind): the nav layer's own bare-keysym
// table, one call per sublayer kind ("focus" is the layer's own binds,
// "move" and "resize" are its Mod sublayers).
func navBinds(kind string) []bind.Bind {
	var out []bind.Bind
	for _, d := range dirs {
		keys := append([]string{d.key}, arrowsForDir(d.key)...)
		for _, k := range keys {
			switch kind {
			case "focus":
				out = append(out, bind.Bind{Chord: k, Actions: cmdAction("focus " + d.focus)})
			case "move":
				out = append(out, bind.Bind{Chord: k, Actions: cmdAction("move " + d.focus)})
			default: // "resize"
				out = append(out, bind.Bind{Chord: k, Actions: cmdAction(fmt.Sprintf("resize %s %s", d.resize, navStep))})
			}
		}
	}
	return out
}

// resizeLayerBinds is binds.py's _resize_layer_binds(): the standalone
// resize mode's table. NOT navBinds("resize") — see binds.py's comment on
// why the coarse/fine (5px letters / 10px arrows) split is carried
// separately here.
func resizeLayerBinds() []bind.Bind {
	var out []bind.Bind
	for _, d := range dirs {
		out = append(out, bind.Bind{Chord: d.key, Actions: cmdAction(fmt.Sprintf("resize %s 5 px or 5 ppt", d.resize))})
	}
	for _, a := range arrows {
		out = append(out, bind.Bind{
			Chord:   a.arrow,
			Actions: cmdAction(fmt.Sprintf("resize %s 10 px or 10 ppt", dirByKey(a.dir).resize)),
		})
	}
	return out
}

// workspaceBinds is binds.py's _workspace_binds(): the 8-wide switch /
// move-container / move-and-follow group, indexed by display position via
// ws-switch.nu rather than by i3 workspace name.
func workspaceBinds() []bind.Bind {
	var out []bind.Bind
	for n := 1; n <= 8; n++ {
		out = append(out,
			bind.Bind{Chord: fmt.Sprintf("$mod+%d", n), Actions: runAction(fmt.Sprintf("%s %d", wsSwitch, n))},
			bind.Bind{Chord: fmt.Sprintf("$mod+Ctrl+%d", n), Actions: runAction(fmt.Sprintf("%s %d move", wsSwitch, n))},
			bind.Bind{Chord: fmt.Sprintf("$mod+Shift+%d", n), Actions: runAction(fmt.Sprintf("%s %d follow", wsSwitch, n))},
		)
	}
	return out
}

// directionalBinds is binds.py's _directional_binds(): the global
// $mod+hjkl/arrows focus group and its $mod+Shift move counterpart, built
// from the SAME dirs/arrows tables the nav layer uses.
func directionalBinds() []bind.Bind {
	var out []bind.Bind
	for _, d := range dirs {
		keys := append([]string{d.key}, arrowsForDir(d.key)...)
		for _, k := range keys {
			out = append(out,
				bind.Bind{Chord: "$mod+" + k, Actions: cmdAction("focus " + d.focus)},
				bind.Bind{Chord: "$mod+Shift+" + k, Actions: cmdAction("move " + d.focus)},
			)
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Layers — Go twin of binds.py's LAYERS dict. Four layers: nav (with move /
// resize Mod sublayers), the standalone resize mode, the one-shot system
// mode, and the hold-modifier alt-tab switcher.
// ---------------------------------------------------------------------------

var Layers = map[string]bind.Layer{
	// was i3 `mode "nav"` (dotfiles-5u6m). Bare keys focus, held Ctrl moves,
	// held Alt resizes.
	"nav": {
		Binds: navBinds("focus"),
		Mods: map[string]bind.Mod{
			"move":   {Modifier: "Ctrl", Binds: navBinds("move")},
			"resize": {Modifier: "Mod1", Binds: navBinds("resize")},
		},
		ExitKeys: []string{"q", "Escape", "Return"},
	},

	// was i3 `mode "resize"` (dotfiles-hwds.48). Entered by $mod+r,
	// persistent, left with q / Escape / Return.
	"resize": {
		Binds:    resizeLayerBinds(),
		ExitKeys: []string{"q", "Escape", "Return"},
	},

	// was i3 `mode "$mode_system"` (dotfiles-hwds.38). Entered by $mod+0;
	// one key, one action, back to default (ONE-SHOT).
	"system": {
		Binds: []bind.Bind{
			{Chord: "l", Actions: runAction("i3exit lock")},
			{Chord: "e", Actions: runAction("i3exit logout")},
			{Chord: "u", Actions: runAction("i3exit switch_user")},
			{Chord: "s", Actions: runAction("i3exit suspend")},
			{Chord: "h", Actions: runAction("i3exit hibernate")},
			{Chord: "r", Actions: runAction("i3exit reboot")},
			{Chord: "p", Actions: runAction("i3exit shutdown")},
		},
		ExitKeys: []string{"q", "Escape", "Return"},
		OneShot:  true,
	},

	// was quickshell/qs-keymon.py + four `nop` grabs in i3 (dotfiles-hwds.40).
	// Alt-tab switcher: a HOLD layer ($mod), Tab/w cycle, Escape/Return
	// cancel/confirm and leave, space hands off to the overlay for search,
	// q is the exit_keys floor.
	"switcher": {
		Binds: []bind.Bind{
			{Chord: "Tab", Actions: runAction(qsOverlay + " switcher")},
			{Chord: "w", Actions: runAction(qsOverlay + " switcher")},
			{Chord: "ISO_Left_Tab", Actions: runAction(qsOverlay + " switcher-prev")},
			{Chord: "space", Actions: []bind.Action{
				bind.Run{Cmd: qsOverlay + " switcher-search"}, bind.ExitLayer{}}},
			{Chord: "Escape", Actions: []bind.Action{
				bind.Run{Cmd: qsOverlay + " switcher-cancel"}, bind.ExitLayer{}}},
			{Chord: "Return", Actions: []bind.Action{
				bind.Run{Cmd: qsOverlay + " switcher-confirm"}, bind.ExitLayer{}}},
		},
		Hold:          "$mod",
		OnHoldRelease: runAction(qsOverlay + " switcher-confirm"),
		ExitKeys:      []string{"q"},
		// dispatched on every INVOLUNTARY exit (dotfiles-hwds.51), so a
		// stranded overlay never sits on screen holding the keyboard.
		OnExit: runAction(qsOverlay + " switcher-cancel"),
	},

	// was i3 `mode "screenshot-drag"` (sp023, bd dotfiles-1m4t.5) — the
	// FIFTH layer shape, and the only one no chord can reach.
	//
	// quickshell/qs-region.py raises this the instant the user starts
	// drawing a region, so quickshell/qs-focus-border.py (a SEPARATE
	// process, with no access to the overlay's in-memory drag state) can
	// drop the red "this is what `w` would capture" highlight that goes
	// stale the moment an arbitrary region is being drawn. It used to
	// travel as a real i3 mode over `i3-msg mode screenshot-drag`, because
	// i3's mode-change IPC event was the only channel already wired to
	// both processes; the daemon's own layer feed is that channel now, so
	// the i3 mode block is deleted rather than kept beside this (a signal
	// in two channels is the double-fire class ft011 exists to kill).
	//
	// DECLARES NOTHING BUT THE FLAG, and that is the design, not brevity
	// (sp023 plan decision 1; rule R28 refuses any behavioral field here
	// by name). It holds zero grabs and does not shadow the global table
	// while active: during a drag the overlay owns a seat grab over all
	// input anyway, so daemon grabs would be inert — and a STRANDED
	// external layer (both the overlay and its launcher dying without
	// clearing) must therefore cost pixels, never keys (us019 AC5). The
	// real keyboard escape in that case is i3's own surviving
	// `mode "screenshot"` block and its Escape/q fallback.
	//
	// Entered and left ONLY by `hotkeyd set-layer <name>` / `set-layer
	// default` — never by a keystroke, which is why the R20 "a layer with
	// no ExitKeys can never be left" rule exempts this shape.
	"screenshot-drag": {External: true},
}

// ---------------------------------------------------------------------------
// Binds — Go twin of binds.py's BINDS list, group by group in the same
// order binds.py declares them.
// ---------------------------------------------------------------------------

// Binds is the daemon's global bind table.
var Binds = buildBinds()

func buildBinds() []bind.Bind {
	out := []bind.Bind{
		// SCOPED TO THE T6 CUTOVER (dotfiles-hwds.16): only the nav entry
		// chord, because nav is the group T6 migrates.
		{Chord: "$mod+o", Actions: []bind.Action{bind.EnterLayer{Layer: "nav"}}},
	}

	// ---- THE ENTRY-POINT GROUP (dotfiles-hwds.33) -------------------------
	// Terminal, launcher, project picker — the three binds i3/config carried
	// itself rather than delegating to config.common.
	out = append(out,
		bind.Bind{Chord: "$mod+Return", Actions: runAction("~/.local/bin/wm-launch-terminal st")},
		bind.Bind{Chord: "$mod+d", Actions: runAction(qsOverlay + " launcher")},
		bind.Bind{Chord: "$mod+p", Actions: runAction(qsOverlay + " projects")},
	)

	// ---- THE WORKSPACE GROUP (dotfiles-hwds.34) ---------------------------
	// 26 chords: the number row in three rows (switch/move/move+follow) plus
	// the two `workspace next|prev` arrows sharing the group's $mod+Ctrl shape.
	out = append(out, workspaceBinds()...)
	out = append(out,
		bind.Bind{Chord: "$mod+Ctrl+Right", Actions: cmdAction("workspace next")},
		bind.Bind{Chord: "$mod+Ctrl+Left", Actions: cmdAction("workspace prev")},
	)

	// ---- THE LAYOUT GROUP (dotfiles-hwds.36) ------------------------------
	// 12 chords: border style, split orientation, layout mode, fullscreen,
	// sticky, scratchpad, focus-parent. Plain i3 commands, no run().
	out = append(out,
		bind.Bind{Chord: "$mod+u", Actions: cmdAction("border none")},
		bind.Bind{Chord: "$mod+y", Actions: cmdAction("border pixel 4")},
		// Verbatim from i3, "bellow" typo and all — a cutover moves a bind,
		// it does not quietly reword the notification.
		bind.Bind{Chord: "$mod+s", Actions: cmdAction("split h;exec notify-send 'tile side'")},
		bind.Bind{Chord: "$mod+b", Actions: cmdAction("split v;exec notify-send 'tile bellow'")},
		bind.Bind{Chord: "$mod+q", Actions: cmdAction("split toggle")},
		bind.Bind{Chord: "$mod+z", Actions: cmdAction("fullscreen toggle")},
		bind.Bind{Chord: "$mod+t", Actions: cmdAction("layout tabbed")},
		bind.Bind{Chord: "$mod+e", Actions: cmdAction("layout toggle split")},
		bind.Bind{Chord: "$mod+Shift+p", Actions: cmdAction("sticky toggle")},
		bind.Bind{Chord: "$mod+a", Actions: cmdAction("focus parent")},
		bind.Bind{Chord: "$mod+Shift+minus", Actions: cmdAction("move scratchpad")},
		bind.Bind{Chord: "$mod+minus", Actions: cmdAction("scratchpad show")},
	)

	// ---- THE DIRECTIONAL GROUP (dotfiles-hwds.37) -------------------------
	// 16 chords: $mod+hjkl/arrows focus, $mod+Shift+ forms move.
	out = append(out, directionalBinds()...)

	// ---- THE SCREENSHOT GROUP (dotfiles-hwds.39) --------------------------
	// Print with no modifier at all (base mask 0), plus the on_release
	// window-capture and selection-capture pair, plus the quickshell region
	// picker.
	out = append(out,
		bind.Bind{Chord: "Print", Actions: runAction("i3-scrot")},
		bind.Bind{Chord: "$mod+Print", Actions: runAction("i3-scrot -w"), OnRelease: true},
		bind.Bind{Chord: "$mod+Shift+Print", Actions: runAction("i3-scrot -s"), OnRelease: true},
		bind.Bind{Chord: "$mod+Shift+s", Actions: runAction(qsScreenshot)},
	)

	// ---- THE SYSTEM MODE (dotfiles-hwds.38) -------------------------------
	// One chord: the seven session actions live in Layers["system"].
	out = append(out, bind.Bind{Chord: "$mod+0", Actions: []bind.Action{bind.EnterLayer{Layer: "system"}}})

	// ---- THE ALT-TAB SWITCHER (dotfiles-hwds.40) --------------------------
	// One chord (the second, $mod+w, was removed — dotfiles-hwds.50 — and
	// stays removed here; see the package doc for why us020 does not bring
	// it back yet). The action is a tuple: open the overlay AND take the
	// layer in one gesture.
	out = append(out, bind.Bind{
		Chord: "$mod+Tab",
		Actions: []bind.Action{
			bind.Run{Cmd: qsOverlay + " switcher"},
			bind.EnterLayer{Layer: "switcher"},
		},
	})

	// ---- THE OVERLAY GROUP (dotfiles-hwds.43) -----------------------------
	// Notification browser and clipboard picker toggles.
	out = append(out,
		bind.Bind{Chord: "$mod+n", Actions: runAction(qsNotif + " toggle")},
		bind.Bind{Chord: "$mod+v", Actions: runAction(qsClip + " toggle")},
	)

	// ---- THE APPS + SESSION GROUP (dotfiles-hwds.46) ----------------------
	// Lock, a launcher, an exit-with-confirmation nagbar. ($mod+F5/mocp
	// stays dropped — dotfiles-hwds.47.)
	out = append(out,
		bind.Bind{Chord: "$mod+9", Actions: runAction("blurlock")},
		bind.Bind{Chord: "$mod+Ctrl+m", Actions: runAction("terminal -e 'alsamixer'")},
		// The nagbar's own quoting, preserved exactly (b0c9f27e).
		bind.Bind{Chord: "$mod+Shift+e", Actions: runAction(
			"i3-nagbar -t warning -m 'You pressed the exit shortcut. Do you really" +
				" want to exit i3? This will end your X session.'" +
				" -b 'Yes, exit i3' 'i3-msg exit'")},
	)

	// ---- THE RESIZE MODE (dotfiles-hwds.48) --------------------------------
	// One chord: the ten resize verbs live in Layers["resize"].
	out = append(out, bind.Bind{Chord: "$mod+r", Actions: []bind.Action{bind.EnterLayer{Layer: "resize"}}})

	return out
}
