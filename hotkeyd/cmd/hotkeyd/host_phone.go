//go:build phone

package main

import "hotkeyd/internal/bind"

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
	// ws-switch.nu is nushell; kwi3 takes the position directly.
	kwi3WorkspaceOverrides(over)
	return over
}

// overlayCmd is unchanged on the phone: the shared table's quickshell path.
func overlayCmd() string { return qsOverlayScript }
