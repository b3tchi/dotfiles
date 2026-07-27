#!/bin/sh
# clip-img-bridge.sh — per-display loop: republish an image/bmp-only X
# CLIPBOARD selection as image/png too.
#
# xrdp-chansrv (0.10.x, this host's version) bridges a Windows clipboard
# image into the X CLIPBOARD as image/bmp ONLY — no image/png, no text
# target (verified live: TARGETS came back `image/bmp` and nothing else).
# Ctrl+V-style image paste in terminal apps (Claude Code CLI's clipboard
# reader among them) looks for image/png (occasionally image/jpeg); an
# image/bmp-only selection is invisible to them even though the bytes are
# right there. clip-win-bridge.sh does not help here — it is a deliberate
# TEXT-only bridge (see its header) and this is a same-selection format gap,
# not a Windows<->X sync gap.
#
# This loop watches the CLIPBOARD (clipnotify, poll-free) and on every
# change: if the owner advertises image/bmp but not image/png, it reads the
# bmp bytes, converts with ImageMagick, and republishes the PNG on the same
# CLIPBOARD selection (`xclip -i` becomes the new owner and stays resident —
# it reads the file into memory before forking, so the work file can be
# removed right after the call returns).
#
# SECURITY: same two-gate shape as clip-store.sh/clip-feed.sh — TARGETS is
# checked for a password-manager hint (both atom spellings) before AND after
# the payload read, fails closed. No known local emitter advertises a hint
# on an image selection; this is defense in depth, not a demonstrated fix.
#
# CONSTRAINTS (adr0002; the clip-store.sh mould):
#  * Display is NAMED ($1 or CLIP_IMG_BRIDGE_DISPLAY), never an inherited
#    $DISPLAY — identical behavior from i3 autostart, tmux pane, or login
#    shell.
#  * Every xclip call is `timeout`-wrapped: a hung owner must cost one
#    bounded read, not wedge the loop. clipnotify itself is NOT wrapped.
#  * flock single-instance per display; losing the race is normal, exit 0.
#  * Work files live under $XDG_RUNTIME_DIR only (tmpfs, 0700) — refuses
#    loudly (exit 78) if unset, no persistent-path fallback.
#
# usage: i3/scripts/clip-img-bridge.sh <display>   (e.g. :10)
# env:   CLIP_IMG_BRIDGE_DISPLAY  display to serve (alternative to $1)
#        CLIP_IMG_BRIDGE_TIMEOUT  seconds before one xclip call is
#                                 abandoned (default 2 — bmp payloads are
#                                 bigger than clip-store.sh's text default)
#        CLIP_IMG_BRIDGE_LOCK     single-instance lock file
#        CLIPNOTIFY               clipnotify binary (default: from PATH)
#        MAGICK                   convert binary (default: magick, falling
#                                  back to convert)
set -u

DPY="${CLIP_IMG_BRIDGE_DISPLAY:-${1:-}}"
T="${CLIP_IMG_BRIDGE_TIMEOUT:-2}"
CN="${CLIPNOTIFY:-clipnotify}"

if [ -z "$DPY" ]; then
  echo "clip-img-bridge.sh: no display: pass one as \$1 or set CLIP_IMG_BRIDGE_DISPLAY" >&2
  exit 78
fi
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  echo "clip-img-bridge.sh: XDG_RUNTIME_DIR is unset; refusing to fall back to a persistent path" >&2
  exit 78
fi
DPY="${DPY%.*}"   # strip a screen suffix (:10.0 -> :10), same as clip-store.sh

if ! command -v "$CN" >/dev/null 2>&1; then
  echo "clip-img-bridge.sh: clipnotify not found ('$CN')" >&2
  exit 69
fi
MAGICK="${MAGICK:-}"
if [ -z "$MAGICK" ]; then
  if command -v magick >/dev/null 2>&1; then MAGICK=magick
  elif command -v convert >/dev/null 2>&1; then MAGICK=convert
  else
    echo "clip-img-bridge.sh: no ImageMagick 'magick'/'convert' found" >&2
    exit 69
  fi
fi

umask 077
ROOT="$XDG_RUNTIME_DIR/clip-img-bridge"
STORE="$ROOT/$DPY"
LOCK="${CLIP_IMG_BRIDGE_LOCK:-$ROOT/$DPY.lock}"
mkdir -p "$STORE" || exit 1
chmod 700 "$ROOT" "$STORE"

exec 9>"$LOCK" || exit 1
flock -n 9 || exit 0

BMP="$STORE/img.bmp"
PNG="$STORE/img.png"
TGT="$STORE/.tgt"
trap 'rm -f "$BMP" "$PNG" "$TGT"' EXIT

targets() {
  timeout "$T" env DISPLAY="$DPY" xclip -selection clipboard -t TARGETS -o \
    > "$TGT" 2>/dev/null 9>&-
}
hinted() {
  grep -qFx -e 'x-kde-passwordManagerHint' \
            -e 'application/x-kde-passwordManagerHint' "$TGT"
}
has_target() { grep -qFx "$1" "$TGT"; }

handle_event() {
  mkdir -p "$STORE"

  targets || return 0
  hinted && return 0
  has_target 'image/bmp' || return 0
  has_target 'image/png' && return 0   # already visible to png readers

  # chansrv is known-flaky (clip-win-bridge.sh header, upstream #2596):
  # TARGETS can advertise image/bmp while the channel is transiently
  # stalled, serving nothing. clipnotify gives this event exactly one
  # shot — unlike clip-store.sh's poll loop, there is no "try again next
  # cycle" — so a few quick retries absorb the stall inline instead of
  # losing the paste until the next ownership change (which, for a
  # single persistent chansrv owner across several Windows-side copies,
  # may not come again this session).
  tries=0
  while [ "$tries" -lt 5 ]; do
    timeout "$T" env DISPLAY="$DPY" xclip -selection clipboard -t image/bmp -o \
      > "$BMP" 2>/dev/null 9>&-
    [ -s "$BMP" ] && break
    tries=$((tries + 1))
    sleep 0.3 9>&-
  done
  [ -s "$BMP" ] || { rm -f "$BMP"; return 0; }

  # TOCTOU re-check — owner may have changed while we read the payload.
  if ! targets || hinted || ! has_target 'image/bmp' || has_target 'image/png'; then
    rm -f "$BMP"
    return 0
  fi

  "$MAGICK" "$BMP" "$PNG" 2>/dev/null || { rm -f "$BMP" "$PNG"; return 0; }
  rm -f "$BMP"
  [ -s "$PNG" ] || { rm -f "$PNG"; return 0; }

  # xclip -i reads $PNG into memory, forks, and the parent returns — the
  # forked child stays resident as the new selection owner independent of
  # this script's lifetime.
  timeout "$T" env DISPLAY="$DPY" xclip -selection clipboard -t image/png -i "$PNG" \
    2>/dev/null 9>&-
  rm -f "$PNG"
}

# Check the CURRENT selection once before waiting for the next change —
# clipnotify only fires on ownership change, so a (re)start with an
# already-pasted image/bmp-only selection sitting there (loop crashed and
# was restarted, or an i3 reload raced a live paste) would otherwise sit
# invisible until the next Windows-side copy.
handle_event

# Same pre-spawn-before-handling shape as clip-store.sh: the next clipnotify
# watch is standing BEFORE handle_event runs, shrinking the unsubscribed
# window to one clipnotify startup instead of the full read+convert+publish.
env DISPLAY="$DPY" "$CN" -s clipboard 9>&- &
CN_PID=$!
while wait "$CN_PID"; do
  env DISPLAY="$DPY" "$CN" -s clipboard 9>&- &
  CN_PID=$!
  handle_event
done
