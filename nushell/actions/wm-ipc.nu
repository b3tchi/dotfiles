#!/usr/bin/env nu

# WM IPC abstraction — detects kwi3, sway or i3 and provides unified commands.
# Used by ws-list.nu, ws-switch.nu, project-picker.
# Also callable from bash: wm-ipc.nu "-t get_workspaces"
#
# kwi3 (kwi3-ax6): a kwi3 session speaks JSON-RPC on $KWI3SOCK, not i3 IPC
# (kwi3 repo docs/notes/ft010.md; its i3 socket and I3SOCK export are gone
# since kwi3-234.18). When $KWI3SOCK is set it decides everything:
#   - answering (`kwi3-msg workspace.list` exits 0): the i3 command text the
#     callers send is translated to kwi3 methods (see kwi3-translate);
#   - set but dead: log to stderr and do nothing (null) - NEVER fall back to
#     i3 or sway, the same rule hotkeyd follows. A kwi3 session with an i3
#     answering beside it is exactly the case where "fall back" means acting
#     on the wrong window manager.
# With $KWI3SOCK unset the i3/sway code below runs exactly as before.
# Tested by nushell/actions/wm-ipc-test against kwi3's real core rig.

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

# ── kwi3 ─────────────────────────────────────────────────────────────────────

# null when $KWI3SOCK is unset (not a kwi3 session: i3/sway path), otherwise
# "live" or "dead". Dead is logged here, once per probe, naming the socket.
def kwi3-state [] {
	let sock = ($env | get -o KWI3SOCK | default "")
	if ($sock | is-empty) { return null }
	if (which kwi3-msg | is-empty) {
		print -e $"wm-ipc: KWI3SOCK=($sock) is set but kwi3-msg is not on PATH - doing nothing \(no fallback to i3\)"
		return "dead"
	}
	let r = (do -i { ^kwi3-msg -s $sock workspace.list } | complete)
	if $r.exit_code == 0 { return "live" }
	print -e $"wm-ipc: KWI3SOCK=($sock) does not answer \(kwi3-msg exit ($r.exit_code): ($r.stderr | str trim)\) - doing nothing \(no fallback to i3\)"
	"dead"
}

# Quote-aware split of an i3 command string into statements on ";" or ",",
# blanks dropped - the same rule as kwi3's core/i3ipc.js ipcSplitStatements
# and hotkeyd's kwi3rpc.splitStatements.
def kwi3-split-statements [text: string] {
	mut out = []
	mut cur = ""
	mut quote = ""
	for ch in ($text | split chars) {
		if $quote != "" {
			$cur = $cur + $ch
			if $ch == $quote { $quote = "" }
		} else if $ch == '"' or $ch == "'" {
			$quote = $ch
			$cur = $cur + $ch
		} else if $ch == ";" or $ch == "," {
			$out = ($out | append $cur)
			$cur = ""
		} else {
			$cur = $cur + $ch
		}
	}
	$out | append $cur | each {|s| $s | str trim } | where {|s| $s != "" }
}

# Split one statement into words on whitespace, a quoted run being one word
# with its quotes removed ("rename workspace \"a b\" to c" -> 5 words).
def kwi3-words [stmt: string] {
	mut out = []
	mut cur = ""
	mut quote = ""
	mut have = false
	for ch in ($stmt | split chars) {
		if $quote != "" {
			if $ch == $quote { $quote = "" } else { $cur = $cur + $ch }
		} else if $ch == '"' or $ch == "'" {
			$quote = $ch
			$have = true
		} else if $ch == " " or $ch == "\t" {
			if $have { $out = ($out | append $cur) }
			$cur = ""
			$have = false
		} else {
			$cur = $cur + $ch
			$have = true
		}
	}
	if $have { $out = ($out | append $cur) }
	$out
}

def kwi3-unsupported [stmt: string, why: string] {
	error make { msg: $"wm-ipc: kwi3 has no translation for \"($stmt)\": ($why)" }
}

# A workspace reference: a bare integer is a position (num), anything else a
# name - hotkeyd's kwi3rpc.translateWorkspace rule. `number`/`name` keywords
# are dropped, as kwi3's own i3 codec drops them.
def kwi3-ws-ref [stmt: string, words: list<string>] {
	let rest = if ($words | is-not-empty) and (($words | first | str lowercase) in ["number" "name"]) {
		$words | skip 1
	} else { $words }
	if ($rest | is-empty) { kwi3-unsupported $stmt "no workspace given" }
	if ($rest | length) == 1 and ($rest | first) =~ '^[0-9]+$' {
		{ num: ($rest | first | into int) }
	} else {
		{ name: ($rest | str join " ") }
	}
}

# One i3 statement -> one kwi3 operation {method, params}. `rename` becomes
# the pseudo-method "rename" ({old?, name}): workspace.rename takes an id, and
# the id has to be looked up WHEN the statement runs, after any earlier
# statement in the same chain has changed the workspaces.
def kwi3-translate-statement [stmt: string] {
	let w = (kwi3-words $stmt)
	let lw = ($w | each {|x| $x | str lowercase })
	let verb = ($lw | first)
	match $verb {
		"workspace" => {
			let arg = ($lw | get -o 1 | default "")
			if $arg in ["next" "prev" "previous" "next_on_output" "prev_on_output" "back_and_forth"] {
				kwi3-unsupported $stmt $"workspace ($arg) is not translated"
			}
			{ method: "workspace.focus", params: (kwi3-ws-ref $stmt ($w | skip 1)) }
		}
		"move" => {
			# move [container|window] to workspace [number|name] <ref>
			let at = ($lw | enumerate | where {|e| $e.item == "to" and ($lw | get -o ($e.index + 1)) == "workspace" } | get -o 0.index)
			let lead = if $at == null { [] } else { $lw | skip 1 | first ($at - 1) }
			if $at == null or ($lead | any {|x| $x not-in ["container" "window"] }) {
				kwi3-unsupported $stmt "only 'move [container|window] to workspace <ref>' is translated"
			}
			{ method: "workspace.move", params: (kwi3-ws-ref $stmt ($w | skip ($at + 2))) }
		}
		"rename" => {
			# rename workspace [<old>] to <new>
			let to = ($lw | enumerate | skip 2 | where item == "to" | get -o 0.index)
			if ($lw | get -o 1) != "workspace" or $to == null or ($w | length) <= ($to + 1) {
				kwi3-unsupported $stmt "expected 'rename workspace [<old>] to <new>'"
			}
			let old = ($w | skip 2 | first ($to - 2))
			let params = { name: ($w | skip ($to + 1) | str join " ") }
			{ method: "rename", params: (if ($old | is-empty) { $params } else { $params | insert old ($old | str join " ") }) }
		}
		"exec" => {
			# The rest of the statement text verbatim (quotes kept, they are
			# the shell's), minus the verb and any --no-startup-id style flags.
			mut rest = ($stmt | str replace -r '^\S+\s*' '')
			while ($rest | str starts-with "--") {
				$rest = ($rest | str replace -r '^\S+\s*' '')
			}
			if ($rest | is-empty) { kwi3-unsupported $stmt "exec needs a command" }
			{ method: "exec", params: { command: $rest } }
		}
		_ => { kwi3-unsupported $stmt $"verb '($verb)' is not translated" }
	}
}

# i3 command text -> list of kwi3 operations, ALL translated before any is
# sent: a chain with one untranslatable statement sends nothing (hotkeyd's
# kwi3rpc.Translate rule), so a half-applied chain never happens.
def kwi3-translate [command: string] {
	let text = ($command | str trim)
	if ($text | str starts-with "-t ") or ($text | str starts-with "--type ") {
		let t = ($text | split row -r '\s+' | get -o 1 | default "")
		let method = match $t {
			"get_workspaces" => "workspace.list",
			"get_tree" => "tree.get",
			_ => { kwi3-unsupported $text $"message type ($t) is not translated" }
		}
		return [{ method: $method, params: null, query: true }]
	}
	let stmts = (kwi3-split-statements $text)
	if ($stmts | is-empty) { kwi3-unsupported $text "empty command" }
	$stmts | each {|s| kwi3-translate-statement $s | insert query false }
}

def kwi3-call [sock: string, method: string, params: any] {
	if $params == null {
		do -i { ^kwi3-msg -s $sock $method } | complete
	} else {
		do -i { ^kwi3-msg -s $sock $method ($params | to json -r) } | complete
	}
}

# Run translated operations in order. A query returns kwi3's JSON verbatim
# (workspace.list carries i3's get_workspaces fields id/num/name/focused/
# visible/urgent/output; tree.get is i3's get_tree shape). Commands return
# i3-msg's own reply shape, one {"success": ...} per statement; any failed
# statement makes the whole call a loud error after the chain has run, as
# i3 itself runs the rest of a chain past a failed statement.
def kwi3-run [sock: string, command: string] {
	let ops = (kwi3-translate $command)
	if ($ops | length) == 1 and ($ops | first | get query) {
		let op = ($ops | first)
		let r = (kwi3-call $sock $op.method $op.params)
		if $r.exit_code != 0 {
			error make { msg: $"wm-ipc: kwi3 ($op.method) failed: ($r.stderr | str trim)" }
		}
		return ($r.stdout | str trim)
	}
	mut replies = []
	for op in $ops {
		let r = if $op.method == "rename" {
			let wss = (kwi3-call $sock "workspace.list" null)
			if $wss.exit_code != 0 {
				$wss
			} else {
				let list = ($wss.stdout | from json)
				let target = if "old" in $op.params {
					$list | where name == $op.params.old
				} else {
					$list | where focused == true
				}
				if ($target | is-empty) {
					{ exit_code: 1, stdout: "", stderr: $"no workspace named \"($op.params | get -o old | default '<focused>')\"" }
				} else {
					kwi3-call $sock "workspace.rename" { id: ($target | first | get id), name: $op.params.name }
				}
			}
		} else {
			kwi3-call $sock $op.method $op.params
		}
		$replies = ($replies | append (if $r.exit_code == 0 {
			{ success: true }
		} else {
			{ success: false, error: ($r.stderr | str trim) }
		}))
	}
	let failed = ($replies | where success == false)
	if ($failed | is-not-empty) {
		error make { msg: $"wm-ipc: kwi3 command \"($command)\" failed: ($failed | get error | str join '; ')" }
	}
	$replies | to json -r
}

# ── i3 / sway ────────────────────────────────────────────────────────────────

# Detect which WM is answering and return the IPC command name
export def ipc-cmd [] {
	let k = (kwi3-state)
	if $k != null { return (if $k == "live" { "kwi3-msg" } else { null }) }
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
	let k = (kwi3-state)
	if $k != null { return (if $k == "live" { $env.KWI3SOCK } else { null }) }
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
	let k = (kwi3-state)
	if $k != null { return (if $k == "live" { kwi3-run $env.KWI3SOCK $command } else { null }) }
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
	let k = (kwi3-state)
	if $k != null { return (if $k == "live" { kwi3-run $env.KWI3SOCK $command } else { null }) }
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

# Return detected WM name: "kwi3", "sway", "i3", or null
export def wm-name [] {
	let c = ipc-cmd
	if $c == "kwi3-msg" { "kwi3" } else if $c == "swaymsg" { "sway" } else if $c == "i3-msg" { "i3" } else { null }
}
