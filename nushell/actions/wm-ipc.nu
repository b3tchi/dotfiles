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

# Candidate sway sockets, best guess first.
#
# These return a LIST rather than one path because the env var can be stale in
# a way `path exists` cannot see. The old version returned early whenever
# $SWAYSOCK named a file, which handles a socket that is GONE after a restart
# but not one that is merely DEAD - and a unix socket outlives the process that
# bound it, so the dead case is the common one. A stale env var therefore
# masked a live server. ipc-cmd probes these in order and takes the first that
# actually answers.
def find-sway-sockets [] {
	mut out = []
	let sock = ($env | get -o SWAYSOCK | default "")
	if ($sock | is-not-empty) and ($sock | path exists) {
		$out = ($out | append $sock)
	}
	let uid = (id -u | str trim)
	let socks = (glob $"/run/user/($uid)/sway-ipc.*.sock")
	if ($socks | is-not-empty) {
		let found = ($socks | each {|s| ls $s | first } | sort-by -r modified | get name)
		$out = ($out | append $found)
	}
	$out | uniq
}

# Candidate i3 sockets, best guess first. Same reasoning as find-sway-sockets.
#
# $I3SOCK first because it is how a kwi3 session names its socket (kwi3 has no
# `--get-socketpath` to ask), then i3's own answer for a real i3. `which i3`
# guards the second: kwi3 sessions need no i3 binary installed at all, and an
# unguarded `^i3` is an error rather than a miss.
def find-i3-sockets [] {
	mut out = []
	let sock = ($env | get -o I3SOCK | default "")
	if ($sock | is-not-empty) and ($sock | path exists) {
		$out = ($out | append $sock)
	}
	if (which i3 | is-not-empty) {
		let result = (do -i { ^i3 --get-socketpath } | complete)
		if $result.exit_code == 0 {
			let found = ($result.stdout | str trim)
			if ($found | is-not-empty) {
				$out = ($out | append $found)
			}
		}
	}
	$out | uniq
}

# Ask the socket, not the process table.
#
# This used to be `pgrep -x sway` / `pgrep -x i3`, which asked whether a
# process with that exact name was running. That is the wrong question in two
# directions, and kwi3 made the first one bite:
#
#   - kwi3 serves i3's IPC protocol but is neither `i3` nor `sway`, so every
#     pgrep missed and ipc-cmd returned null. ws-list.nu, ws-switch.nu,
#     wm-state, wm-current-workspace and the quickshell projects picker then
#     all returned nothing at all, silently, with no error anywhere.
#   - a live process does not prove a reachable socket, and a socket file on
#     disk does not prove a live server: a unix socket outlives the process
#     that bound it, so a leftover path from the previous session is already
#     there when the next one starts.
#
# So do what i3act and i3tree in the kwi3 tree do: a real GET_VERSION round
# trip. It is the cheapest message that proves something is listening AND
# speaking i3 framing on the far end. Measured on this box it is also 13x
# FASTER than the pgrep it replaces - 5ms against 66ms - because pgrep walks
# /proc and this is one write to a socket.
#
# sway is probed first so a sway session keeps winning on a box that has both.
def sock-answers [cmd: string, sock: string] {
	if (which timeout | is-empty) {
		return false
	}
	let r = if $cmd == "swaymsg" {
		(do -i { ^timeout 2 swaymsg --socket $sock -t get_version } | complete)
	} else {
		(do -i { ^timeout 2 i3-msg -s $sock -t get_version } | complete)
	}
	$r.exit_code == 0
}

# Detect which WM is answering and return the IPC command name
export def ipc-cmd [] {
	if (which swaymsg | is-not-empty) {
		for sock in (find-sway-sockets) {
			if (sock-answers "swaymsg" $sock) { return "swaymsg" }
		}
	}
	if (which i3-msg | is-not-empty) {
		for sock in (find-i3-sockets) {
			if (sock-answers "i3-msg" $sock) { return "i3-msg" }
		}
	}
	null
}

# The socket ipc-cmd settled on, so callers do not re-derive it. Returns null
# when nothing answers.
export def ipc-sock [] {
	if (which swaymsg | is-not-empty) {
		for sock in (find-sway-sockets) {
			if (sock-answers "swaymsg" $sock) { return $sock }
		}
	}
	if (which i3-msg | is-not-empty) {
		for sock in (find-i3-sockets) {
			if (sock-answers "i3-msg" $sock) { return $sock }
		}
	}
	null
}

# Run a WM IPC command with the given arguments
# Pass the full command as a single string, e.g.: ipc "workspace dotfiles"
# Splits on space — do NOT use for exec with quoted args; use ipc-raw instead.
# Returns null if no WM detected
export def ipc [command: string] {
	let cmd = ipc-cmd
	if $cmd == null { return null }
	let sock = (ipc-sock)
	if $sock == null { return null }
	let parts = ($command | split row " ")
	if $cmd == "swaymsg" {
		^swaymsg --socket $sock ...$parts
	} else {
		^i3-msg -s $sock ...$parts
	}
}

# Like ipc but passes the command as one argument (no split).
# Use this for `exec` with quoted args, or any command containing spaces inside quotes.
export def ipc-raw [command: string] {
	let cmd = ipc-cmd
	if $cmd == null { return null }
	let sock = (ipc-sock)
	if $sock == null { return null }
	if $cmd == "swaymsg" {
		^swaymsg --socket $sock $command
	} else {
		^i3-msg -s $sock $command
	}
}

# Return detected WM name: "sway", "i3", or null
export def wm-name [] {
	let c = ipc-cmd
	if $c == "swaymsg" { "sway" } else if $c == "i3-msg" { "i3" } else { null }
}
