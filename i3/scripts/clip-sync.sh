#!/bin/sh
# clip-sync.sh — mirror PRIMARY <-> CLIPBOARD X selections.
#
# The xrdp/WSL i3 session (config.d/wsl.conf) runs no clipboard manager:
# native.conf gets PRIMARY<->CLIPBOARD sync from clipit, but clipit isn't
# installed here and autocutsel is AUR-only. st sets PRIMARY on text-select
# but pastes from CLIPBOARD, so "select in one window / paste in st" desyncs.
# This bridges the two selections dependency-free with xclip (already a dep).
# Whichever selection a user changed last wins and is copied to the other.
#
# All xclip calls are wrapped in `timeout`: under xrdp/WSLg a selection owner
# can be unresponsive (e.g. a copied image, or a dead RDP client), and a bare
# `xclip -o` blocks forever — one hung read froze the whole loop and stopped
# syncing until the daemon was killed. timeout abandons the stuck call and the
# loop continues on the next tick.
#
# ------------------------------------------------- THE STARTUP SEED (rxlj) ---
#
# The last-seen state is SEEDED from the live selections before the loop runs,
# and this is the whole point of the seed: an unseeded loop starts with both
# last-seen values EMPTY, so its first tick finds PRIMARY "changed" (anything
# differs from empty) and publishes that selection over the CLIPBOARD. Since
# wsl.conf starts this from `exec_always`, that made every i3 config reload
# revert the clipboard to whatever PRIMARY last held — measured live: a fresh
# Windows copy replaced by an hours-old terminal selection one second after
# the loop came up, which is the "paste gives old text" bug.
#
# WHICH SIDE WINS AT STARTUP: the CLIPBOARD. On the first observation no user
# action has been seen, so the loop cannot know which side is newer, and it
# must not guess in the direction that destroys work — a CLIPBOARD entry is
# always an explicit copy, while PRIMARY is a side effect of dragging across
# text. So a non-empty CLIPBOARD is published to PRIMARY and never the
# reverse. An EMPTY clipboard has nothing to lose, so there PRIMARY seeds
# both (a fresh session where only a selection exists still converges).
# After the seed, the ordinary last-writer-wins rule takes over unchanged.
#
# ---------------------------------------------- WHICH SESSION (rxlj) --------
#
# The display is an ARGUMENT, never the inherited $DISPLAY, and every xclip
# call names it explicitly — the same contract clip-store.sh, clip-img-bridge.sh
# and clip-set.sh already hold, and for the same reason: adr0004 keeps two X
# servers permanently live, and a shell that starts this may carry a DISPLAY
# belonging to the other session, to a dead one, or to a test's Xvfb. That
# last case is not hypothetical — a harness instance left over on `:89` owned
# this job on a deployed machine while the real session's `:10` selections
# stopped mirroring entirely, invisibly, because `pgrep clip-sync.sh` still
# showed a live loop. A missing display is refused loudly (78) rather than
# defaulted, because syncing the wrong session's selections is worse than
# syncing none.
#
# flock single-instance per display, for the same reason as clip-store.sh:
# i3 `exec_always` re-runs autostarts on every config reload, and a second
# loop would race the first for every change. Losing the race is the normal
# case, not an error: exit 0. That guard is also what lets wsl.conf drop the
# `pkill -f 'clip-sync\.sh$'` it used to need — a pkill that could not tell a
# production loop from any other, and killed across sessions.
# Children close fd 9 (`9>&-`) so a forked xclip never holds the lock past
# this shell's death (the clip-feed.sh lesson — observed).
#
# Test: i3/scripts/test-clip-sync.sh (headless, Xvfb; every loop it starts is
# handed a WRONG inherited DISPLAY so a loop that trusts the environment
# fails the suite).
#
# usage: i3/scripts/clip-sync.sh <display>       (e.g. clip-sync.sh :10)
# env:   CLIP_SYNC_DISPLAY  display to serve (alternative to $1)
#        CLIP_SYNC_POLL     seconds between polls (default 0.5)
#        CLIP_SYNC_TIMEOUT  seconds before one xclip call is abandoned (1)
#        CLIP_SYNC_LOCK     single-instance lock file
#                           (default $XDG_RUNTIME_DIR/clip-sync.<display>.lock)
# exit:  0 on clean end (lost the single-instance race),
#        78 (EX_CONFIG) when the display or XDG_RUNTIME_DIR is missing.
set -u

DPY="${CLIP_SYNC_DISPLAY:-${1:-}}"
POLL="${CLIP_SYNC_POLL:-0.5}"
T="${CLIP_SYNC_TIMEOUT:-1}"

if [ -z "$DPY" ]; then
  echo "clip-sync.sh: no display: pass one as \$1 or set CLIP_SYNC_DISPLAY" >&2
  exit 78
fi

# X DISPLAY may carry a screen suffix (`:0.0`); the lock is keyed on the bare
# display so a caller passing the raw $DISPLAY still collides with the
# autostart's bare `:0`/`:10` instance instead of running beside it. In sh
# parameter expansion `.` is literal: `:0.0` -> `:0`, bare `:0` unchanged.
# Done AFTER the emptiness check so an unset display still fails loudly.
# The display handed to xclip keeps the suffix ($DPY before this line is the
# same server either way, so the bare form is used throughout for simplicity).
DPY="${DPY%.*}"

if [ -z "${CLIP_SYNC_LOCK:-}" ] && [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  echo "clip-sync.sh: XDG_RUNTIME_DIR is unset; refusing to fall back to a persistent path" >&2
  exit 78
fi
LOCK="${CLIP_SYNC_LOCK:-$XDG_RUNTIME_DIR/clip-sync.$DPY.lock}"

umask 077

# Single-instance guard, per display (see WHICH SESSION above).
exec 9>"$LOCK" || exit 1
flock -n 9 || exit 0

A="$(mktemp)"; B="$(mktemp)"; NEW="$(mktemp)"
trap 'rm -f "$A" "$B" "$NEW"' EXIT
: > "$A"; : > "$B"   # last-seen PRIMARY ($A) and CLIPBOARD ($B)

# read a selection ($1) into $NEW; returns nonzero on timeout/empty/error
get() { timeout "$T" env DISPLAY="$DPY" xclip -selection "$1" -o > "$NEW" 2>/dev/null 9>&- && [ -s "$NEW" ]; }
# set a selection ($1) from $NEW; guarded so a hung owner can't wedge the loop
put() { timeout "$T" env DISPLAY="$DPY" xclip -selection "$1" -i < "$NEW" 2>/dev/null 9>&-; }

# ------------------------------------------------------------- the seed ---
# Both last-seen files are filled from the live selections BEFORE the loop can
# treat either as a change. The single write this may do is CLIPBOARD ->
# PRIMARY, never the reverse (see THE STARTUP SEED above).
if get clipboard; then
  cp "$NEW" "$A"; cp "$NEW" "$B"
  put primary
elif get primary; then
  cp "$NEW" "$A"; cp "$NEW" "$B"
  put clipboard
fi

while :; do
  if get primary && ! cmp -s "$NEW" "$A"; then
    cp "$NEW" "$A"; cp "$NEW" "$B"
    put clipboard
  elif get clipboard && ! cmp -s "$NEW" "$B"; then
    cp "$NEW" "$B"; cp "$NEW" "$A"
    put primary
  fi
  # 9>&- here too, not only on the xclip calls: `fuser` on the lock showed the
  # poll `sleep` holding fd 9 open. It is short-lived, so it never actually
  # wedged a restart, but the rule is the rule — no child of this loop holds
  # the single-instance lock (clip-feed.sh's header has the incident).
  sleep "$POLL" 9>&-
done
