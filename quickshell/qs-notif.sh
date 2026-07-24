#!/bin/sh
# qs-notif.sh -- notification-history browser control script (sp019 task 5,
# dotfiles-c5fd.5). The qs-clip.sh two-verb contract mould, adapted: `set`
# becomes `dismiss`, publish-to-clipboard becomes write-to-FIFO.
#
# usage: qs-notif.sh [toggle]            open/close the browser on the active session
#        qs-notif.sh list                print history as "<id>\t<preview>" lines
#        qs-notif.sh dismiss <id|latest> ask the daemon to drop one entry
#
# The browser itself is quickshell/config/NotifHistory.qml (task 6), hosted
# inside the MAIN quickshell instance (config/shell.qml wires it in) beside
# ClipHistory. This script is BOTH the outside entry point (`toggle`, bound
# to a key in the base i3 config) and the back end the QML calls (`list`,
# `dismiss`) -- exactly qs-clip.sh's split, so all non-UI logic lives here in
# sh where it is unit-tested without an X server.
#
# WHICH SESSION -- DERIVED, NEVER INHERITED (toggle only)
#
#   VERBATIM the qs-clip.sh mechanism (candidates()/session_key_of()), with
#   only the IPC target string changed (cliphistory -> notifhistory) -- see
#   qs-clip.sh's own header for the full rationale (native :0 / xrdp :10
#   dual-session reality, adr0004: an inherited DISPLAY may belong to the
#   other session or nothing at all, so the target is derived from which
#   live quickshell instance actually answers the IPC target, never
#   guessed). `QS_NOTIF_DISPLAY` forces a session explicitly, exactly like
#   `QS_CLIP_DISPLAY` does for the clipboard picker.
#
# LIST -- READS THE STORE DIRECTLY, READ-ONLY (refinement delta 4)
#
#   Unlike `dismiss`, `list` never talks to the daemon or the FIFO: it
#   recomputes qs-notif-store.sh's own store directory
#   (${XDG_STATE_HOME:-$HOME/.local/state}/qs-notif/, task 1) rather than
#   shelling out to it, so a listing never blocks on, or waits for, a live
#   daemon. Only the six-digit `??????.notif` glob is a visible entry -- a
#   stray or in-flight work file is silently skipped, never listed.
#
# DISMISS -- FIFO WRITE, BOUNDED TIMEOUT, NEVER BLOCKS (refinement delta 4)
#
#   The daemon (task 2) is the ONLY store mutator; this script never removes
#   an entry itself, so a dismiss of an id that has already vanished (an
#   age-prune race between `list` and `dismiss`) still writes the FIFO line
#   successfully -- the daemon side is what fails on the missing entry, not
#   this script.
#
#   `dismiss <id|latest>` shape-checks the id, then opens the daemon's
#   command FIFO for writing under a hard timeout. A dead daemon leaves the
#   FIFO with no reader, and opening a FIFO for write-only blocks in the
#   open(2) syscall itself until a reader appears -- forever, absent the
#   timeout. `timeout $FIFO_TIMEOUT` wraps the open+write in one subshell so
#   a SIGTERM interrupts the blocked open, giving a hard upper bound
#   (default 2s, `QS_NOTIF_FIFO_TIMEOUT` overrides) with NOTHING written to
#   the daemon side -- the open never completed, so the write after it never
#   ran either.
#
# EXIT CODES (ids are opaque strings end to end: equality + shape only,
# never parsed or arithmetic'd on)
#   0  ok
#   1  usage error, invalid id, or no daemon listening (dismiss timed out)
#   78 an XDG_* variable this operation needs is unset (EX_CONFIG)
#
# Test: quickshell/test-notif-history.sh (headless for the list/dismiss
# script phases; toggle's session-derivation regression needs Xvfb +
# quickshell, same as qs-clip.sh's own PHASE 1).
set -u

PROG="${0##*/}"

TARGET=notifhistory                        # the IpcHandler target in NotifHistory.qml
ENTRY_GLOB='[0-9][0-9][0-9][0-9][0-9][0-9].notif'

WIDTH="${QS_NOTIF_PREVIEW:-120}"           # preview characters before truncation
FIFO_TIMEOUT="${QS_NOTIF_FIFO_TIMEOUT:-2}" # seconds before a dismiss write gives up

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }

case "$WIDTH"        in '' | *[!0-9]*) die "QS_NOTIF_PREVIEW must be a number, got '$WIDTH'" ;; esac
case "$FIFO_TIMEOUT" in '' | *[!0-9]*) die "QS_NOTIF_FIFO_TIMEOUT must be a number, got '$FIFO_TIMEOUT'" ;; esac

# --------------------------------------------------------------- the store ---
#
# ${XDG_STATE_HOME:-$HOME/.local/state}/qs-notif -- the SAME computation
# qs-notif-store.sh's own store_dir() makes (task 1), duplicated here rather
# than shelled out to, because `list` is read-only and must never invoke the
# store script's writer paths. Unset XDG_STATE_HOME AND HOME fails loudly
# (exit 78), the family convention every store-adjacent script shares.
store_dir() {
  if [ -n "${XDG_STATE_HOME:-}" ]; then
    printf '%s/qs-notif\n' "$XDG_STATE_HOME"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    printf '%s/.local/state/qs-notif\n' "$HOME"
    return 0
  fi
  printf '%s: both XDG_STATE_HOME and HOME are unset; refusing to guess a store location\n' "$PROG" >&2
  return 78
}

# ------------------------------------------------------------------- list ---
#
# One line per entry: "<id>\t<preview>", newest first (reverse-lexicographic
# filename sort -- lexicographic filename order IS arrival order, task 1's
# own invariant, so a descending sort on the name is newest-first,
# deterministic across calls over an unchanged store).
#
# Absent/empty store dir: no output, exit 0 -- nothing captured yet is not
# an error.
cmd_list() {
  _store="$(store_dir)"; _rc=$?
  [ "$_rc" -eq 0 ] || exit "$_rc"

  [ -d "$_store" ] || return 0

  for _name in $(cd "$_store" 2>/dev/null && ls -1 2>/dev/null \
                 | grep -E '^[0-9]{6}\.notif$' | sort -r); do
    _path="$_store/$_name"
    [ -f "$_path" ] || continue   # vanished between the listing and this read
    printf '%s\t%s\n' "$_name" "$(preview_of "$_path")"
  done
  return 0
}

# The preview: "<relative-or-HH:MM time>  <summary> -- <folded body first
# line>", truncated to WIDTH characters, character- (not byte-) aware in a
# UTF-8 locale (gawk's length()/substr() are char-aware there -- the
# qs-clip.sh preview_of mould).
#
#   line 1  <epoch>\t<urgency>\t<app>          -- only the epoch is used here
#   line 2  summary (already control-whitespace-folded by the store on
#           write; folded again here defensively, since this reader must
#           never trust a hand-seeded or otherwise non-conforming file to
#           already be clean)
#   line 3+ raw body -- the FIRST non-blank line, folded the same way (a raw
#           tab/newline in the preview would break the "<id>\t<preview>"
#           line protocol); the on-disk body itself is untouched by this
#           folding
#
# Summary entirely whitespace: the preview falls back to the folded body
# line; if that is also absent, "(empty)".
preview_of() { # <path>
  gawk -v W="$WIDTH" '
    function fold(s) {
      gsub(/[\t\r\v\f\n]/, " ", s)
      gsub(/^[ ]+/, "", s)
      gsub(/[ ]+$/, "", s)
      return s
    }
    NR == 1 { split($0, hdr, "\t"); epoch = hdr[1] + 0; next }
    NR == 2 { summary = fold($0); next }
    {
      if (!body_found) {
        b = fold($0)
        if (b != "") { body = b; body_found = 1 }
      }
    }
    END {
      d = systime() - epoch
      if (d < 0) d = 0
      if (d < 60)         t = "just now"
      else if (d < 3600)  t = int(d / 60) "m ago"
      else if (d < 86400) t = int(d / 3600) "h ago"
      else                t = strftime("%H:%M", epoch)

      if (summary != "") {
        content = summary
        if (body != "") content = content " \xe2\x80\x94 " body
      } else if (body != "") {
        content = body
      } else {
        content = "(empty)"
      }

      p = t "  " content
      if (length(p) > W) p = substr(p, 1, W - 1) "\xe2\x80\xa6"
      print p
    }
  ' "$1"
}

# --------------------------------------------------------------- dismiss ---
#
# The daemon (task 2) is the ONLY store mutator. This script asks it to drop
# an entry over the command FIFO; it never touches the store itself. See
# "DISMISS" in the file header for the bounded-timeout mechanism.
cmd_dismiss() {
  [ $# -eq 1 ] || die "usage: $PROG dismiss <id|latest>"
  _id="$1"

  # Shape check BEFORE any fifo touch -- an id is an opaque string, matched
  # for shape only, never trusted to be safe as anything else. `latest` is
  # the one literal word this script recognises without forwarding it
  # through path-shaped validation; everything else must look like a real
  # six-digit entry name.
  case "$_id" in
    latest) : ;;
    $ENTRY_GLOB) : ;;
    *) die "invalid id: '$_id'" ;;
  esac

  if [ -n "${QS_NOTIF_FIFO:-}" ]; then
    _fifo="$QS_NOTIF_FIFO"
  else
    if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
      printf '%s: XDG_RUNTIME_DIR is unset; refusing to guess the notification daemon'"'"'s fifo path\n' "$PROG" >&2
      exit 78
    fi
    _fifo="$XDG_RUNTIME_DIR/qs-notif.cmd"
  fi

  if [ ! -p "$_fifo" ]; then
    printf '%s: no notification daemon fifo at %s -- is the daemon running?\n' "$PROG" "$_fifo" >&2
    exit 1
  fi

  # Bounded-timeout open+write in one subshell: opening a fifo for
  # write-only blocks in open(2) until a reader appears, so `timeout` is
  # what turns "the daemon is dead" into a bounded failure instead of an
  # indefinite hang. Killed before the open completes means NOTHING was
  # written -- the write on the line after it never gets a chance to run.
  if ! timeout "$FIFO_TIMEOUT" sh -c 'printf "%s\n" "$2" > "$1"' _ "$_fifo" "dismiss $_id" 2>/dev/null; then
    printf '%s: no daemon listening on %s (dismiss %s) -- timed out after %ss\n' \
      "$PROG" "$_fifo" "$_id" "$FIFO_TIMEOUT" >&2
    exit 1
  fi
  return 0
}

# ----------------------------------------------------------------- toggle ---
#
# VERBATIM qs-clip.sh's mechanism -- see its header for the full rationale.
# Only TARGET and the QS_NOTIF_DISPLAY override name differ.

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

# "<pid> <session-key>" for every quickshell instance that answers
# `notifhistory`. Asking each instance what it exposes -- rather than
# pattern-matching its command line -- is what lets the browser be hosted
# anywhere (main shell today, a dedicated instance tomorrow) without this
# script needing to know.
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

  # What the caller's environment CLAIMS the session is. Never used on its
  # own -- only to pick between instances that were found independently.
  _want="${QS_NOTIF_DISPLAY:-}"
  if [ -z "$_want" ]; then
    if [ -n "${DISPLAY:-}" ]; then _want="DISPLAY=$DISPLAY"
    elif [ -n "${WAYLAND_DISPLAY:-}" ]; then _want="WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    fi
  fi

  _found="$(candidates)"
  [ -n "$_found" ] && _n="$(printf '%s\n' "$_found" | wc -l)" || _n=0
  [ "$_n" -gt 0 ] || die "no quickshell instance exposing '$TARGET' -- is the shell running?"

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
-- set QS_NOTIF_DISPLAY to choose"
    fi
  fi

  exec quickshell ipc --pid "$_pid" call "$TARGET" toggle
}

# ------------------------------------------------------------------- main ---

case "${1:-toggle}" in
  list)    cmd_list ;;
  dismiss) shift; cmd_dismiss "$@" ;;
  toggle)  cmd_toggle ;;
  *)       die "usage: $PROG [toggle|list|dismiss <id|latest>]" ;;
esac
