#!/usr/bin/env nu

# WM IPC abstraction — detects i3 or sway and provides unified commands.
# Used by ws-list.nu, ws-switch.nu, project-picker.

# Detect which WM is running and return the IPC command name
export def ipc-cmd [] {
	# Check sway first (if both are somehow running, prefer the Wayland session)
	if (^pgrep -x sway | complete | get exit_code) == 0 {
		"swaymsg"
	} else if (^pgrep -x i3 | complete | get exit_code) == 0 {
		"i3-msg"
	} else {
		null
	}
}

# Run a WM IPC command with the given arguments
# Returns null if no WM detected
export def ipc [...args: string] {
	let cmd = ipc-cmd
	if $cmd == null { return null }
	^$cmd ...$args
}
