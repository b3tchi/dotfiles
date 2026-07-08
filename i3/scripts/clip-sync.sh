#!/bin/sh
# clip-sync.sh — mirror PRIMARY <-> CLIPBOARD X selections.
#
# The xrdp/WSL i3 session (config.d/wsl.conf) runs no clipboard manager:
# native.conf gets PRIMARY<->CLIPBOARD sync from clipit, but clipit isn't
# installed here and autocutsel is AUR-only. st sets PRIMARY on text-select
# but pastes from CLIPBOARD, so "select in one window / paste in st" desyncs.
# This bridges the two selections dependency-free with xclip (already a dep).
# Whichever selection a user changed last wins and is copied to the other.
set -u

A="$(mktemp)"; B="$(mktemp)"; NEW="$(mktemp)"
trap 'rm -f "$A" "$B" "$NEW"' EXIT
: > "$A"; : > "$B"   # last-seen PRIMARY ($A) and CLIPBOARD ($B)

while :; do
  if xclip -selection primary -o > "$NEW" 2>/dev/null && [ -s "$NEW" ] \
     && ! cmp -s "$NEW" "$A"; then
    cp "$NEW" "$A"; cp "$NEW" "$B"
    xclip -selection clipboard -i < "$NEW"
  elif xclip -selection clipboard -o > "$NEW" 2>/dev/null && [ -s "$NEW" ] \
       && ! cmp -s "$NEW" "$B"; then
    cp "$NEW" "$B"; cp "$NEW" "$A"
    xclip -selection primary -i < "$NEW"
  fi
  sleep 0.5
done
