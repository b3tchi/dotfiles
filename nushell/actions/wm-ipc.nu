#!/usr/bin/env nu

# WM IPC abstraction — detects i3 or sway and provides unified commands.
# Used by ws-list.nu, ws-switch.nu, project-picker.
# Also callable from bash: wm-ipc.nu "-t get_workspaces"

def main [command?: string] {
	if ($command | is-empty) {
		# No args: print detected IPC command name
		let cmd = ipc-cmd
		if $cmd != null { print $cmd }
	} else {
		ipc $command
	}
}

# Detect which WM is running and return the IPC command name
export def ipc-cmd [] {
	if (which pgrep | is-empty) {
		return null
	}
	# Check sway first — require SWAYSOCK to avoid errors in terminals
	# without a sway connection (e.g. WezTerm -> WSL where sway runs separately)
	if ($env | get -o SWAYSOCK | is-not-empty) and (^pgrep -x sway | complete | get exit_code) == 0 {
		"swaymsg"
	} else if (^pgrep -x i3 | complete | get exit_code) == 0 {
		"i3-msg"
	} else {
		null
	}
}

# Run a WM IPC command with the given arguments
# Pass the full command as a single string, e.g.: ipc "workspace dotfiles"
# Returns null if no WM detected
export def ipc [command: string] {
	let cmd = ipc-cmd
	if $cmd == null { return null }
	# Split command string into args to pass to the binary
	let parts = ($command | split row " ")
	^$cmd ...$parts
}
