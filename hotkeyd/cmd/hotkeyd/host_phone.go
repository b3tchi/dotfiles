//go:build phone

package main

import "hotkeyd/internal/bind"

// hostOverrides for the phone (`go build -tags phone`): the headless KWin
// session reached over RDP. It has no dotfiles, nushell or st, so a chord
// that runs one of this machine's own programs is pointed at what the phone
// does have. Chords that talk to kwi3 over $KWI3SOCK need nothing here.
func hostOverrides() map[string][]bind.Action {
	return map[string][]bind.Action{
		"$mod+Return": runAction("foot"),
	}
}
