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
set -u

T=1                  # seconds before a single xclip call is abandoned
A="$(mktemp)"; B="$(mktemp)"; NEW="$(mktemp)"
trap 'rm -f "$A" "$B" "$NEW"' EXIT
: > "$A"; : > "$B"   # last-seen PRIMARY ($A) and CLIPBOARD ($B)

# read a selection ($1) into $NEW; returns nonzero on timeout/empty/error
get() { timeout "$T" xclip -selection "$1" -o > "$NEW" 2>/dev/null && [ -s "$NEW" ]; }
# set a selection ($1) from $NEW; guarded so a hung owner can't wedge the loop
put() { timeout "$T" xclip -selection "$1" -i < "$NEW" 2>/dev/null; }

while :; do
  if get primary && ! cmp -s "$NEW" "$A"; then
    cp "$NEW" "$A"; cp "$NEW" "$B"
    put clipboard
  elif get clipboard && ! cmp -s "$NEW" "$B"; then
    cp "$NEW" "$B"; cp "$NEW" "$A"
    put primary
  fi
  sleep 0.5
done
