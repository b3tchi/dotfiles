#!/bin/sh
# clip-set.sh — put one copyq history row on the clipboard (sp014 task 3).
#
# usage: clip-set.sh <row>
#
#   <row>  copyq history index, 0 = newest. Digits only.
#
# CLI CONTRACT (task .4's quickshell picker invokes exactly this):
#
#   clip-set.sh <row>
#     exit 0   the entry is on CLIPBOARD and PRIMARY of EVERY live X display,
#              and each of those displays has been observed serving it back
#     exit 1   precondition failure — NO selection was written anywhere, on any
#              display. The clipboard is exactly as the caller left it.
#     exit 2   partial failure — the entry reached at least one selection but
#              not all of them. The clipboard state is indeterminate: some
#              displays/selections may hold the entry, others may not.
#     stderr   one-line reason on failure; silent on success
#
#   The 1-vs-2 split is the whole point of having two failure codes. Everything
#   checkable up front — missing/bad row, empty entry, missing tool, no live
#   display at all — is checked BEFORE the first write, so exit 1 is a hard
#   promise that nothing was touched and a caller may retry or fall back
#   freely. Exit 2 can only be reached after X has already been handed the
#   entry, so it makes no such promise. A caller that must not leave a stale
#   half-set clipboard should treat 2, not 1, as the dangerous code.
#
#   This script does NOT paste. It only publishes the entry; the user pastes
#   manually with their own keybinding. No window is inspected and no keystroke
#   is synthesized — that was deliberately dropped from this task's scope.
#
# WHICH DISPLAYS — ALL OF THEM, NEVER INHERITED, NEVER GUESSED
#
#   This runs on a host where native `:0` and xrdp `:10` are both permanently
#   live ([[adr0004]]), fired from a picker or keybind whose own DISPLAY may
#   belong to the other session or may simply be stale. So DISPLAY is ignored
#   entirely, and no attempt is made to work out which session the human is
#   looking at — there is no dependency-free way to ask X that, and guessing
#   wrong means the pick (which can be a password) lands in the session nobody
#   is watching.
#
#   Instead every live display gets the entry. Both sessions belong to the same
#   user on the same machine, so publishing to both leaks nothing across a
#   trust boundary, and it makes the result independent of enumeration order —
#   the failure mode that a "probe the sockets and take the first" rule had,
#   where the lexicographic glob made `:0` beat `:10` every time.
#
#   A display whose socket is present but which cannot be handed the entry (the
#   server is gone, the socket is stale) is skipped silently — that is a dead
#   session, not an error. If NO display accepts it, that is exit 1.
#
# copyq is addressed as a plain `copyq read` per copyq/dot.yaml's client
# contract — no XDG_CONFIG_HOME juggling, or the socket path moves.
#
# Test: i3/scripts/test-clip-set.sh (headless, Xvfb, two displays).
set -u

T=5                          # seconds before a single xclip call is abandoned
PROG="${0##*/}"

# Where X display sockets are enumerated from. Overridable only so the test
# harness can present a controlled set of displays instead of the host's live
# ones -- production never sets it.
SOCKET_DIR="${CLIP_SET_SOCKET_DIR:-/tmp/.X11-unix}"

# exit 1 -- nothing has been written yet.
die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }

# exit 2 -- something has already been written.
die_partial() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

# ------------------------------------------------------------------ args ---

[ $# -eq 1 ] || die "usage: $PROG <row>"
ROW="$1"
case "$ROW" in
  '' | *[!0-9]*) die "row must be a non-negative integer, got '$ROW'" ;;
esac

for tool in copyq xclip; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done

# ----------------------------------------------------------------- entry ---
#
# Read the entry BEFORE touching any display: a bad row must not be able to
# blank a selection, which is what makes the exit-1 promise true.

TMP="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$TMP" "$TMP.head"' EXIT

copyq read "$ROW" > "$TMP" 2>/dev/null || die "copyq read $ROW failed"
[ -s "$TMP" ] || die "history row $ROW is empty or does not exist"

head -c 64 "$TMP" > "$TMP.head"

# --------------------------------------------------------- set selections ---

# Both selections: CLIPBOARD is what ctrl+v pastes, PRIMARY keeps middle-click
# and terminal-select behaviour consistent with the pick. xclip backgrounds
# itself as the selection owner and serves the entry for as long as it is
# asked to, so large entries transfer via INCR untouched.
#
# xclip forks before it actually owns the selection, so a write that "returned
# 0" is not yet observable by a paste. Each display is therefore polled until
# CLIPBOARD serves the entry back. Only a prefix is compared, so a multi-
# megabyte pick does not pay for a full round trip per display.
settled_on() { # <display>
  _i=0
  while [ "$_i" -lt 40 ]; do
    if timeout "$T" env DISPLAY="$1" xclip -selection clipboard -o 2>/dev/null \
       | head -c 64 | cmp -s - "$TMP.head"; then
      return 0
    fi
    _i=$((_i + 1))
    sleep 0.05
  done
  return 1
}

WROTE=0

for SOCK in "$SOCKET_DIR"/X*; do
  [ -e "$SOCK" ] || continue
  DPY=":${SOCK##*/X}"

  # The CLIPBOARD write doubles as the liveness probe: a display we cannot
  # hand the entry to is a display there is no point reporting on. Failing
  # here before anything else has been written is still a clean skip, so the
  # exit-1 promise survives an entirely dead socket directory.
  if ! timeout "$T" env DISPLAY="$DPY" xclip -selection clipboard -i < "$TMP" \
       2>/dev/null; then
    continue
  fi

  # Past this point the display demonstrably accepted a selection, so any
  # further failure on it is a real, partial failure -- not a dead session.
  timeout "$T" env DISPLAY="$DPY" xclip -selection primary -i < "$TMP" \
    2>/dev/null || die_partial "could not set the primary selection on $DPY"

  settled_on "$DPY" || die_partial "clipboard ownership on $DPY did not settle"

  WROTE=$((WROTE + 1))
done

[ "$WROTE" -gt 0 ] \
  || die "no live X display under $SOCKET_DIR -- nothing to set the clipboard on"
