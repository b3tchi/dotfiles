#!/usr/bin/env bash
# nnn-preview-hook.sh — pushes nnn's highlighted entry to preview-d (ft005)
# via the mandatory `preview send` wrapper (adr0001 nushell-first surface,
# adr0003 mandatory-wrapper mandate — this script never talks to the
# daemon directly). The nnn-side half of sp008 Task 5's cursor-signal
# bridge; mirrors nvim/plugins/preview.lua's CursorHold/CursorMoved signal.
#
# Two modes:
#
#   One-shot — invoked with the entry path as $1 (nnn's `$nnn` plugin
#   substitution, or a manual key binding via NNN_PLUG). Sends that one
#   entry and exits.
#
#   Live/FIFO — invoked with no argument and $NNN_FIFO set. Tails the FIFO
#   nnn writes the highlighted path to on every selection change (the
#   `preview-tui`-style live-preview pattern) and sends each entry as the
#   cursor moves, until nnn closes the FIFO.
#
# Wire-up (in your nnn launcher, e.g. fish/config.fish or n.fish):
#   export NNN_FIFO=/tmp/nnn.fifo
#   export NNN_PLUG='p:nnn-preview-hook.sh'   # bind to a key for one-shot
#   nnn ...                                    # live mode auto-starts if
#                                               # you background this script
#                                               # against $NNN_FIFO
#
# Directory entries are skipped, not an error (sp008 Task 5 edge case:
# "nnn on a directory entry -> no send... not an error") — the daemon has
# no directory-listing renderer and cd'ing into a preview would surprise.

set -uo pipefail

send_entry() {
	local entry="$1"
	[ -n "$entry" ] || return 0
	if [ -d "$entry" ]; then
		return 0
	fi
	if ! command -v preview >/dev/null 2>&1; then
		echo "nnn-preview-hook: 'preview' wrapper not on PATH — run: rotz install preview" >&2
		return 1
	fi
	preview send "$entry"
}

# One-shot mode: an explicit path argument.
if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
	send_entry "$1"
	exit $?
fi

# Live mode: tail $NNN_FIFO for each highlighted entry.
if [ -z "${NNN_FIFO:-}" ]; then
	echo "nnn-preview-hook: no path argument and NNN_FIFO not set — nothing to do" >&2
	exit 1
fi

while IFS= read -r entry <"$NNN_FIFO"; do
	send_entry "$entry" || true
done
