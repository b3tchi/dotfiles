#!/bin/sh
# qs-clip.sh — clipboard-history picker control script (sp014 task 4).
#
# usage: qs-clip.sh [toggle]      open/close the picker on the active session
#        qs-clip.sh list          print the history as "<row>\t<preview>" lines
#        qs-clip.sh set <row>     put history row <row> on the clipboard
#
# The picker itself is quickshell/config/ClipHistory.qml, hosted inside the
# session's normal quickshell instance (config/shell.qml wires it in). This
# script is BOTH the outside entry point (`toggle`, bound to a key in the base
# i3 config) and the back end the QML calls (`list`, `set`) — so every piece of
# non-UI logic lives here in sh where it can be unit-tested without an X server,
# and the QML stays presentation only.
#
# WHICH SESSION — DERIVED, NEVER INHERITED
#
#   Native `:0` and xrdp `:10` are both permanently live ([[adr0004]]), and the
#   shell this runs from may carry a DISPLAY belonging to the other session or
#   no longer belonging to anything (the stale-DISPLAY bug class fixed in
#   tmux.conf, and the one that got task .3 rejected once). Opening the picker
#   on the wrong display puts it where nobody is looking, which is worse than
#   not opening it at all.
#
#   So the target is derived from the live quickshell instances, not from the
#   environment: every `quickshell` process is inspected for (a) the session it
#   belongs to, read out of /proc/<pid>/environ — the same environ-matching
#   qs-session.sh uses — and (b) whether it actually answers the `cliphistory`
#   IPC target. An inherited DISPLAY is accepted ONLY when it matches one of
#   those instances; otherwise, if exactly one instance qualifies it is used,
#   and if several do the script refuses and names them rather than guessing.
#
#   `QS_CLIP_DISPLAY` (e.g. `DISPLAY=:10`) forces a session explicitly.
#
# `set` is a thin wrapper over i3/scripts/clip-set.sh and propagates its exit
# code verbatim, because the picker's UI depends on the 0/1/2 split:
#   0 = on the clipboard of every live display, 1 = nothing written anywhere
#   (safe to retry), 2 = partial write, clipboard state indeterminate.
# See i3/scripts/clip-set.sh for the full contract.
#
# copyq is addressed as a plain `copyq eval` per copyq/dot.yaml's client
# contract — no XDG_CONFIG_HOME juggling, or the server socket path moves.
#
# Test: quickshell/test-clip-history.sh (headless, Xvfb + xdotool).
set -u

PROG="${0##*/}"
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

TARGET=cliphistory                    # the IpcHandler target in ClipHistory.qml

# Overridable only so the headless suite can point at a stub / a worktree copy;
# production leaves all three unset.
CLIP_SET="${QS_CLIP_SET:-$SELF_DIR/../i3/scripts/clip-set.sh}"
CAP="${QS_CLIP_CAP:-200}"             # most rows the picker will ever show
WIDTH="${QS_CLIP_PREVIEW:-120}"       # preview characters before truncation

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }

case "$CAP"   in '' | *[!0-9]*) die "QS_CLIP_CAP must be a number, got '$CAP'" ;; esac
case "$WIDTH" in '' | *[!0-9]*) die "QS_CLIP_PREVIEW must be a number, got '$WIDTH'" ;; esac

# ------------------------------------------------------------------- list ---
#
# One line per history row: "<row>\t<preview>". The row number is the copyq
# index the caller must hand back to `set`, so filtering/sorting in the UI can
# never desynchronise the visible list from the history.
#
# The preview is the first NON-BLANK line of the entry, with tabs and other
# control whitespace folded to spaces (a tab would break the field split) and
# truncated to WIDTH characters. Leading blank lines are skipped because an
# entry that starts with them would otherwise render as a blank row — the
# preview exists to identify the entry, and only the preview is truncated: the
# full entry is what `set` publishes.
#
# The list is capped at CAP rows. A history longer than that is not paged; the
# oldest entries are simply not offered (they are still in copyq, reachable by
# `set <row>` directly).
cmd_list() {
  command -v copyq >/dev/null 2>&1 || die "copyq not found in PATH"
  copyq eval -- '
var CAP='"$CAP"', W='"$WIDTH"';
var n = size(); if (n > CAP) n = CAP;
var o = [];
for (var i = 0; i < n; ++i) {
  var t = str(read("text/plain", i));
  var ls = t.split("\n");
  var p = "";
  for (var j = 0; j < ls.length; ++j) {
    var c = ls[j].replace(/[\t\r\v\f]/g, " ").replace(/^\s+|\s+$/g, "");
    if (c !== "") { p = c; break; }
  }
  if (p === "") p = "(empty)";
  if (p.length > W) p = p.substring(0, W - 1) + "…";
  o.push(i + "\t" + p);
}
o.join("\n")
'
}

# -------------------------------------------------------------------- set ---
#
# exec, so clip-set.sh's exit code IS this script's exit code — the picker
# reads 0/1/2 off it and shows a different outcome for each.
cmd_set() {
  [ $# -eq 1 ] || die "usage: $PROG set <row>"
  case "$1" in '' | *[!0-9]*) die "row must be a non-negative integer, got '$1'" ;; esac
  [ -r "$CLIP_SET" ] || die "clip-set.sh not found at $CLIP_SET"
  exec sh "$CLIP_SET" "$1"
}

# ----------------------------------------------------------------- toggle ---

# The session a pid belongs to, as a "VAR=value" key: X11 DISPLAY when the
# process has one (native i3 and xrdp are both X11), else WAYLAND_DISPLAY
# (sway). Empty when the process has neither.
session_key_of() { # <pid>
  _e="$(tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null)" || return 1
  _v="$(printf '%s\n' "$_e" | sed -n 's/^DISPLAY=//p' | head -1)"
  [ -n "$_v" ] && { printf 'DISPLAY=%s\n' "$_v"; return 0; }
  _v="$(printf '%s\n' "$_e" | sed -n 's/^WAYLAND_DISPLAY=//p' | head -1)"
  [ -n "$_v" ] && { printf 'WAYLAND_DISPLAY=%s\n' "$_v"; return 0; }
  return 1
}

# "<pid> <session-key>" for every quickshell instance that answers `cliphistory`.
# Asking each instance what it exposes — rather than pattern-matching its
# command line — is what lets the picker be hosted anywhere (main shell today,
# a dedicated instance tomorrow) without this script needing to know.
candidates() {
  for _pid in $(pgrep -x quickshell 2>/dev/null); do
    _key="$(session_key_of "$_pid")" || continue
    quickshell ipc --pid "$_pid" show 2>/dev/null \
      | grep -qx "target $TARGET" || continue
    printf '%s %s\n' "$_pid" "$_key"
  done
}

cmd_toggle() {
  command -v quickshell >/dev/null 2>&1 || die "quickshell not found in PATH"

  # What the caller's environment CLAIMS the session is. Never used on its own
  # — only to pick between instances that were found independently.
  _want="${QS_CLIP_DISPLAY:-}"
  if [ -z "$_want" ]; then
    if [ -n "${DISPLAY:-}" ]; then _want="DISPLAY=$DISPLAY"
    elif [ -n "${WAYLAND_DISPLAY:-}" ]; then _want="WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    fi
  fi

  _found="$(candidates)"
  [ -n "$_found" ] && _n="$(printf '%s\n' "$_found" | wc -l)" || _n=0
  [ "$_n" -gt 0 ] || die "no quickshell instance exposing '$TARGET' — is the shell running?"

  _pid=""
  if [ -n "$_want" ]; then
    _pid="$(printf '%s\n' "$_found" | awk -v w="$_want" '$2 == w { print $1; exit }')"
  fi

  if [ -z "$_pid" ]; then
    if [ "$_n" -eq 1 ]; then
      _pid="${_found%% *}"
    else
      die "'$_want' matches no running instance, and $_n sessions are live \
($(printf '%s\n' "$_found" | awk '{print $2}' | tr '\n' ' ')) \
— set QS_CLIP_DISPLAY to choose"
    fi
  fi

  exec quickshell ipc --pid "$_pid" call "$TARGET" toggle
}

# ------------------------------------------------------------------- main ---

case "${1:-toggle}" in
  list)   cmd_list ;;
  set)    shift; cmd_set "$@" ;;
  toggle) cmd_toggle ;;
  *)      die "usage: $PROG [toggle|list|set <row>]" ;;
esac
