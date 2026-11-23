//go:build phone

package main

import (
	"fmt"

	"hotkeyd/internal/bind"
)

// hostOverrides for the phone (`go build -tags phone`): the phone's KWin
// session. It has no st, so a chord that runs one of the desktop's programs
// is pointed at what the phone does have. Chords that talk to kwi3 over
// $KWI3SOCK need nothing here.
// kwinMod is $mod on a kwin session: Alt on the phone, as on the desktop
// (the Clicks keyboard's Alt key is mapped to leftalt by the clicks dot).
const kwinMod = "Mod1"

// hostDroppedLayerBinds: layer chords this host does not bind (applied by
// config.go's init). The system layer ($mod+0) is the desktop's; the phone
// has no display manager to switch user through and no swap to hibernate
// to, so u and h would only make i3exit refuse. The bar's hint strip
// (quickshell ModeBarTheme.qml) drops the same two on kwi3-phone.
var hostDroppedLayerBinds = map[string]map[string]string{
	"system": {
		"u": "no display manager on the phone to switch user through",
		"h": "no swap on the phone to hibernate to",
	},
}

func hostOverrides() map[string][]bind.Action {
	over := map[string][]bind.Action{
		// wm-launch-terminal, as on the desktop, so the terminal opens in the
		// focused workspace's project (its tmux session) and not in $HOME.
		"$mod+Return": runAction("~/.local/bin/wm-launch-terminal foot"),
		// KWin has no restart in place; reloading the script is its way.
		"$mod+Shift+c": runAction("$HOME/.local/bin/i3reload"),
		// i3-scrot is X11-only, and KWin has no wlr-screencopy for grim:
		// kwi3-shot asks KWin's ScreenShot2. The region picker is the global
		// table's qs-screenshot.sh, which hands a Wayland session to the
		// quickshell picker (RegionShot.qml) instead of qs-region.py.
		"Print":            runAction("$HOME/.local/bin/kwi3-shot"),
		"$mod+Print":       runAction("$HOME/.local/bin/kwi3-shot -w"),
		"$mod+Shift+Print": runAction(qsScreenshot),
		// Back camera: opens quickshell's CameraOverlay and the camera
		// layer, whose keys take or drop the photo (sp041). Phone-only: no
		// other host has the camera.
		"$mod+f": {bind.Run{Cmd: qsOverlay + " camera-open"}, bind.EnterLayer{Layer: "camera"}},
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
