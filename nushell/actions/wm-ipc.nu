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

# Find a valid i3 socket, handling stale I3SOCK after restarts
def find-i3-socket [] {
	let sock = ($env | get -o I3SOCK | default "")
	if ($sock | is-not-empty) and ($sock | path exists) {
		return $sock
	}
	let result = (^i3 --get-socketpath | complete)
	if $result.exit_code != 0 { return null }
	let found = ($result.stdout | str trim)
	if ($found | is-empty) { null } else { $found }
}

# Detect which WM is running and return the IPC command name
export def ipc-cmd [] {
	if (which pgrep | is-empty) {
		return null
	}
	if (^pgrep -x sway | complete | get exit_code) == 0 {
		if (find-sway-socket) != null { "swaymsg" } else { null }
	} else if (^pgrep -x i3 | complete | get exit_code) == 0 {
		if (find-i3-socket) != null { "i3-msg" } else { null }
	} else {
		null
	}
}

# Run a WM IPC command with the given arguments
# Pass the full command as a single string, e.g.: ipc "workspace dotfiles"
# Splits on space — do NOT use for exec with quoted args; use ipc-raw instead.
# Returns null if no WM detected
export def ipc [command: string] {
	let cmd = ipc-cmd
	if $cmd == null { return null }
	let parts = ($command | split row " ")
	if $cmd == "swaymsg" {
		let sock = (find-sway-socket)
		^swaymsg --socket $sock ...$parts
	} else {
		let sock = (find-i3-socket)
		if $sock == null {
			^$cmd ...$parts
		} else {
			^i3-msg -s $sock ...$parts
		}
	}
}

# Like ipc but passes the command as one argument (no split).
# Use this for `exec` with quoted args, or any command containing spaces inside quotes.
export def ipc-raw [command: string] {
	let cmd = ipc-cmd
	if $cmd == null { return null }
	if $cmd == "swaymsg" {
		let sock = (find-sway-socket)
		^swaymsg --socket $sock $command
	} else {
		let sock = (find-i3-socket)
		if $sock == null {
			^$cmd $command
		} else {
			^i3-msg -s $sock $command
		}
	}
}

# Return detected WM name: "sway", "i3", or null
export def wm-name [] {
	let c = ipc-cmd
	if $c == "swaymsg" { "sway" } else if $c == "i3-msg" { "i3" } else { null }
}
