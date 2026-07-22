#!/bin/sh
# clip-win-bridge.sh — two-way bridge: X CLIPBOARD (xrdp :10) <-> Windows
# clipboard, over WSL interop (powershell.exe), NOT the RDP channel.
#
# xrdp-chansrv is the built-in path for this and it is not trustworthy:
# its clipboard channel dies silently on long sessions / reconnects
# (upstream #2596 — observed here after chansrv ran 6 days), it serves
# only STRING/UTF8_STRING targets (#3338), and image paste is a 0.10.x
# regression (#3102). Text is what matters day-to-day, and WSL can reach
# the Windows clipboard directly through interop — so this daemon does,
# and keeps working whether or not chansrv's channel is alive. When both
# are alive they converge: every write is guarded by a content compare,
# so the two syncers echo each other once and then go quiet.
#
# Direction Win -> X: a persistent powershell polls Get-Clipboard in-process
# (one interop spawn total, not one per tick) and emits base64(UTF-8) lines
# on change; the reader decodes into the X CLIPBOARD via xclip.
# Direction X -> Win: the main loop polls the X CLIPBOARD and on change
# pipes raw UTF-8 into a fresh powershell Set-Clipboard (spawn cost only on
# actual copies). stdin carries the payload — no arg-length limit, and
# UTF-8 survives (clip.exe mangles diacritics; measured, don't switch back).
#
# Design constraints (the clip-sync.sh / clip-feed.sh mould):
#  * Explicit DISPLAY on every X call — identical behavior from i3
#    autostart, tmux pane, or login shell.
#  * Every xclip call wrapped in `timeout` — a hung selection owner (dead
#    RDP client, image payload) blocks a bare `xclip -o` forever.
#  * flock single-instance guard; losing the race is normal, exit 0.
#    Children close fd 9 (`9>&-`) — the lock lives on the open file
#    description and an inherited fd in a surviving child would wedge
#    restarts (see clip-feed.sh header).
#  * SECURITY: a selection advertising application/x-kde-passwordManagerHint
#    is never forwarded to Windows — the Windows clipboard feeds Win+V
#    history and optional cloud sync, which would launder a KeePassXC copy
#    into persistent storage. TARGETS is checked before the payload is read.
#
# Line endings: Windows text arrives CRLF; it is normalized to LF before
# hitting X (pasting \r into a terminal is never wanted). LAST stores the
# LF form, and Win-side echoes are re-normalized before compare, so the
# conversion cannot ping-pong.
#
# usage: i3/scripts/clip-win-bridge.sh    (daemon; exits 0 if already running)
# env:   CLIP_BRIDGE_DISPLAY=:10  X display bridged
#        CLIP_BRIDGE_POLL=0.5     seconds between X-side polls
#        CLIP_BRIDGE_WIN_POLL=700 milliseconds between Windows-side polls
#        CLIP_BRIDGE_TIMEOUT=1    seconds before a single xclip call is abandoned
#        CLIP_BRIDGE_LOCK=...     single-instance lock file
set -u

DSP="${CLIP_BRIDGE_DISPLAY:-:10}"
POLL="${CLIP_BRIDGE_POLL:-0.5}"
WPOLL="${CLIP_BRIDGE_WIN_POLL:-700}"
T="${CLIP_BRIDGE_TIMEOUT:-1}"
LOCK="${CLIP_BRIDGE_LOCK:-/tmp/clip-win-bridge.$(id -u).lock}"
PS=powershell.exe

command -v "$PS" >/dev/null 2>&1 || exit 0   # not WSL / interop off

exec 9>"$LOCK" || exit 1
flock -n 9 || exit 0

D="$(mktemp -d)"
NEW="$D/new"; LAST="$D/last"; TGT="$D/tgt"; WIN="$D/win"
: > "$LAST"    # last content synced in either direction

targets() {
  timeout "$T" env DISPLAY="$DSP" xclip -selection clipboard -t TARGETS -o \
    > "$TGT" 2>/dev/null 9>&-
}
read_x() {
  timeout "$T" env DISPLAY="$DSP" xclip -selection clipboard -o \
    > "$NEW" 2>/dev/null 9>&- && [ -s "$NEW" ]
}
set_x() {
  timeout "$T" env DISPLAY="$DSP" xclip -selection clipboard -i \
    < "$1" 2>/dev/null 9>&-
}
set_win() {
  "$PS" -NoProfile -Command \
    '[Console]::InputEncoding=[Text.Encoding]::UTF8; Set-Clipboard -Value ([Console]::In.ReadToEnd())' \
    < "$1" >/dev/null 2>&1 9>&-
}
nap() { sleep "$1" 9>&-; }

# --- Win -> X reader (background) -------------------------------------------
# The watcher powershell never exits on its own; if interop hiccups and it
# dies, the outer loop respawns it after a beat.
win_watch() {
  while :; do
    "$PS" -NoProfile -Command '
      [Console]::OutputEncoding=[Text.Encoding]::ASCII
      $last = $null
      while ($true) {
        Start-Sleep -Milliseconds '"$WPOLL"'
        try { $c = Get-Clipboard -Raw -ErrorAction Stop } catch { $c = $null }
        if ($c -and $c -cne $last) {
          $last = $c
          [Console]::Out.WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($c)))
        }
      }' 2>/dev/null 9>&- |
    while IFS= read -r line; do
      printf '%s' "$line" | base64 -d 2>/dev/null | tr -d '\r' > "$WIN"
      [ -s "$WIN" ] || continue
      cmp -s "$WIN" "$LAST" && continue   # our own X->Win push echoing back
      cp "$WIN" "$LAST"
      set_x "$WIN"
    done
    nap 5
  done
}
# The subshell must not inherit fd 9 (see the lock note above), and its
# powershell must not outlive us — an orphaned interop watcher keeps polling
# the Windows clipboard forever. pkill -P reaps the pipeline children.
win_watch 9>&- &
WPID=$!
trap 'rm -rf "$D"; pkill -P "$WPID" 2>/dev/null; kill "$WPID" 2>/dev/null' EXIT

# --- X -> Win poller (foreground) -------------------------------------------
while :; do
  # SECURITY GATE — before the payload is ever read; see header.
  if targets && grep -qFx 'application/x-kde-passwordManagerHint' "$TGT"; then
    nap "$POLL"; continue
  fi
  if read_x && ! cmp -s "$NEW" "$LAST"; then
    # TOCTOU re-check, clip-feed.sh style: the payload may come from a
    # different owner than the one the gate passed on. Fails closed.
    if ! targets || grep -qFx 'application/x-kde-passwordManagerHint' "$TGT"; then
      nap "$POLL"; continue
    fi
    cp "$NEW" "$LAST"
    set_win "$NEW"
  fi
  nap "$POLL"
done
