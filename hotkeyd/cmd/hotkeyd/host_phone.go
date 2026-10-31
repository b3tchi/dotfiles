//go:build phone

package main

import (
	"fmt"

	"hotkeyd/internal/bind"
)

// hostOverrides for the phone (`go build -tags phone`): the headless KWin
// session reached over RDP. It has no dotfiles, nushell or st, so a chord
// that runs one of this machine's own programs is pointed at what the phone
// does have. Chords that talk to kwi3 over $KWI3SOCK need nothing here.
func hostOverrides() map[string][]bind.Action {
	over := map[string][]bind.Action{
		"$mod+Return": runAction("foot"),
		// KWin has no restart in place; reloading the script is its way.
		"$mod+Shift+c": runAction("$HOME/.local/bin/i3reload"),
		// i3-scrot is X11-only, and KWin has no wlr-screencopy for grim:
		// kwi3-shot asks KWin's ScreenShot2. The region picker is the global
		// table's qs-screenshot.sh, which hands a Wayland session to the
		// quickshell picker (RegionShot.qml) instead of qs-region.py.
		"Print":            runAction("$HOME/.local/bin/kwi3-shot"),
		"$mod+Print":       runAction("$HOME/.local/bin/kwi3-shot -w"),
		"$mod+Shift+Print": runAction(qsScreenshot),
	}
	// ws-switch.nu is nushell; kwi3's workspace.focus/workspace.move take
	// the same 1-based position directly.
	for n := 1; n <= 8; n++ {
		over[fmt.Sprintf("$mod+%d", n)] = cmdAction(fmt.Sprintf("workspace %d", n))
		over[fmt.Sprintf("$mod+Ctrl+%d", n)] = cmdAction(fmt.Sprintf("move container to workspace %d", n))
		over[fmt.Sprintf("$mod+Shift+%d", n)] = cmdAction(fmt.Sprintf("move container to workspace %d; workspace %d", n, n))
	}
	return over
}
