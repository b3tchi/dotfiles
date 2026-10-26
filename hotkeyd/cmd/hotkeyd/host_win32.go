//go:build win32

package main

import "hotkeyd/internal/bind"

// hostOverrides for Windows (`go build -tags win32`, sp012 Task 6): Jan's
// RDP session under i3kwin-win32. The tag is explicit, never implied by
// GOOS: an untagged GOOS=windows build carries the Linux table, and
// install-win32.sh builds with -tags win32.
//
// There is no shell on Windows: every Run here is split by internal/proc's
// SplitCommand (spaces separate words, double quotes group, nothing else
// escapes), so no command below may need a literal `"`.
//
// The recover chord $mod+Shift+r is the HOST's (one RegisterHotKey in
// i3kwin-win32, adr0003 amended 2026-10-26) and never appears here;
// bind.ReservedChords refuses it under Mod1 anyway.
func hostOverrides() map[string][]bind.Action {
	over := map[string][]bind.Action{
		// Windows Terminal, a new window each time (a second $mod+Return is a
		// second managed window, not a tab).
		"$mod+Return": runAction("wt.exe -w new"),

		// $mod+s/$mod+b without their notify-send: the host spawns nothing,
		// so the exec half could only fail (C15, adr0019).
		"$mod+s": cmdAction("split h"),
		"$mod+b": cmdAction("split v"),
	}
	// No nushell: the workspace group goes to kwi3's RPC directly, as on
	// the phone.
	kwi3WorkspaceOverrides(over)

	// Removed until Windows has the program (sp012 decision k): an empty
	// action list drops the chord, and the layer only it entered with it.
	for _, chord := range win32Removed {
		over[chord] = nil
	}
	return over
}

// win32Removed are the chords whose programs do not exist on Windows.
var win32Removed = []string{
	// the screenshot group: i3-scrot and qs-screenshot.sh
	"Print", "$mod+Print", "$mod+Shift+Print", "$mod+Shift+s",
	// the overlay group: quickshell notifications and clipboard
	"$mod+n", "$mod+v",
	// the system layer (i3exit) - removing its one entry chord removes it
	"$mod+0",
	// restart in place: kwi3-restart is X11's; Windows waits for sp014
	"$mod+Shift+c",
	// the project picker: kwi3-run.exe has no `projects` verb
	"$mod+p",
	// the apps + session group: blurlock, alsamixer, i3-nagbar
	"$mod+9", "$mod+Ctrl+m", "$mod+Shift+e",
}

// overlayCmd is the Windows runner (kwi3 repo, i3kwin/runner/win32): one
// resident process, each later start forwards its verb to it - launcher,
// switcher, switcher-prev, switcher-confirm, switcher-cancel,
// switcher-search.
func overlayCmd() string { return "kwi3-run.exe" }
