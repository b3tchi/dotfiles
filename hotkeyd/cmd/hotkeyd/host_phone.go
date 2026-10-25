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
