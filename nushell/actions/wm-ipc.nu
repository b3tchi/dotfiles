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

# Find a valid sway socket, handling stale SWAYSOCK after restarts
def find-sway-socket [] {
	let sock = ($env | get -o SWAYSOCK | default "")
	if ($sock | is-not-empty) and ($sock | path exists) {
		return $sock
	}
	let uid = (id -u | str trim)
	let socks = (glob $"/run/user/($uid)/sway-ipc.*.sock")
	if ($socks | is-empty) { return null }
	let found = ($socks | each {|s| ls $s | first } | sort-by -r modified | get name)
	if ($found | is-empty) { null } else { $found | first }
}

# Detect which WM is running and return the IPC command name
export def ipc-cmd [] {
	if (which pgrep | is-empty) {
		return null
	}
	if (^pgrep -x sway | complete | get exit_code) == 0 {
		if (find-sway-socket) != null { "swaymsg" } else { null }
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
	let parts = ($command | split row " ")
	if $cmd == "swaymsg" {
		let sock = (find-sway-socket)
		^swaymsg --socket $sock ...$parts
	} else {
		^$cmd ...$parts
	}
}
