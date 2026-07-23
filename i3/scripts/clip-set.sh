#!/bin/sh
# clip-set.sh — publish one file-store entry to the clipboard (sp016 task 3,
# adapted from sp014 task 3). The backend swapped from copyq to the bespoke
# clip-store.sh file store ([[sp016]] mid-execution pivot); this script's own
# CLI contract and display fan-out are unchanged.
#
# usage: clip-set.sh <id> [src-display]
#
#   <id>           a store entry filename, e.g. "000005.clip" -- opaque,
#                  exactly as `qs-clip.sh list` (task 2) hands it back. Must
#                  match the store's own naming, six digits + ".clip";
#                  anything else (a .tmp work file, a path, garbage) is
#                  refused before anything is read. The store's own writer
#                  (clip-store.sh) owns what happens at the six-digit
#                  ceiling (999999) -- this script never generates or
#                  increments an id, only consumes whatever it is handed, so
#                  that boundary is out of scope here.
#   [src-display]  REQUIRED, one way or another (positional here, or the
#                  CLIP_SET_SRC_DISPLAY env override below) -- which
#                  display's store <id> is read from. See "WHICH STORE THE
#                  ID IS READ FROM" below for why this cannot default to
#                  anything, least of all inherited $DISPLAY.
#
# env: CLIP_SET_SRC_DISPLAY  same as the [src-display] positional, takes
#                            precedence over it when both are given.
#
# CLI CONTRACT (the caller must pass the source display explicitly --
# qs-clip.sh's `cmd_set` passes its own session's display as $2, wired by
# sp016 task 5):
#
#   clip-set.sh <id> [src-display]
#     exit 0   the entry is on CLIPBOARD and PRIMARY of EVERY live X display,
#              and each of those displays has been observed serving it back
#     exit 1   precondition failure — NO selection was written anywhere, on any
#              display. The clipboard is exactly as the caller left it.
#     exit 2   partial failure — the entry reached at least one selection but
#              not all of them. The clipboard state is indeterminate: some
#              displays/selections may hold the entry, others may not.
#     exit 78  configuration failure ($XDG_RUNTIME_DIR unset) — distinct from
#              1/2 because it is not about the id or the displays at all; the
#              store's own root cannot even be named. Same EX_CONFIG code
#              clip-store.sh (task 6) uses for the identical refusal.
#     stderr   one-line reason on failure; silent on success
#
#   The 1-vs-2 split is the whole point of having two failure codes. Everything
#   checkable up front — missing/bad id, unknown/stale id, missing tool, no
#   live display at all — is checked BEFORE the first write, so exit 1 is a
#   hard promise that nothing was touched and a caller may retry or fall back
#   freely. Exit 2 can only be reached after X has already been handed the
#   entry, so it makes no such promise. A caller that must not leave a stale
#   half-set clipboard should treat 2, not 1, as the dangerous code.
#
#   This script does NOT paste. It only publishes the entry; the user pastes
#   manually with their own keybinding. No window is inspected and no keystroke
#   is synthesized — that was deliberately dropped from sp014 task 3's scope
#   and stays out of scope here.
#
# BYTE-EXACT, INCLUDING MULTILINE — THE REASON FOR THIS TASK
#
#   clipcat's `get` (evaluated as ft007's backend, then falsified in
#   execution) irreversibly escapes embedded control characters: a real
#   newline and a literal two-char `\n` sequence rendered byte-identical
#   (dotfiles-i9i). The file store fixes this by construction — an entry is
#   `cat`, nothing more, so whatever bytes clip-store.sh wrote are exactly
#   the bytes this script reads and hands to xclip. No escaping layer exists
#   to get wrong.
#
# WHICH DISPLAYS GET THE PUBLISH — ALL OF THEM, NEVER INHERITED, NEVER GUESSED
#
#   This runs on a host where native `:0` and xrdp `:10` are both permanently
#   live ([[adr0004]]), fired from a picker or keybind whose own DISPLAY may
#   belong to the other session or may simply be stale. So DISPLAY is ignored
#   entirely for the FAN-OUT, and no attempt is made to work out which session
#   the human is looking at — there is no dependency-free way to ask X that,
#   and guessing wrong means the pick (which can be a password) lands in the
#   session nobody is watching. This half of the design is carried over from
#   sp014 task 3 unchanged: it was never about the backend.
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
# WHICH STORE THE ID IS READ FROM — THE ONE NEW RESOLUTION THIS TASK ADDS,
# AND WHY IT IS *ALSO* "NEVER INHERITED, NEVER GUESSED"
#
#   Unlike copyq (one global daemon, one global history, no display concept on
#   the read side at all), the file store is PER DISPLAY: clip-store.sh runs
#   one loop per live display, each with its own directory and its own
#   independently-numbered ids starting at 000001, so "000005.clip" in :0's
#   store and in :10's store ROUTINELY both exist, as two entirely unrelated
#   entries. Something has to say which store an id came from, and this is
#   NOT a case where an ambient signal can be trusted: sp016's own anti-
#   patterns are unqualified on this point ("Never trust inherited DISPLAY —
#   derive it, as the shipped scripts do"), and the failure mode of getting
#   it wrong here is worse than the fan-out's, not milder. Guessing the wrong
#   FAN-OUT target just means a display that should have received the entry
#   doesn't (a partial-failure exit 2, or a display silently not offered a
#   pick it should have been). Guessing the wrong SOURCE store means finding
#   a DIFFERENT, VALID entry under the same id in the wrong store and
#   publishing IT — successfully, exit 0, to every live display. A
#   silent-wrong-content publish is worse in kind than the ordering/escaping
#   bugs (dotfiles-8il, dotfiles-i9i) that motivated the whole pivot away
#   from clipcat.
#
#   So the source display is a REQUIRED, EXPLICIT argument: pass it
#   positionally as $2, or set CLIP_SET_SRC_DISPLAY (which wins if both are
#   given). Neither present is a hard usage error, not a guess and not a
#   fallback to $DISPLAY — mirroring clip-store.sh's own precedent exactly
#   (`DPY="${CLIP_STORE_DISPLAY:-${1:-}}"`: env override or positional arg,
#   never ambient $DISPLAY). The caller is responsible for having already
#   worked out which session it is (exactly as qs-clip.sh's `cmd_toggle`
#   already does for its own purposes) and handing that answer down
#   explicitly — this script will not do that derivation itself and will not
#   accept an implicit one. qs-clip.sh's `cmd_set` passes its own session's
#   $DISPLAY as $2 (wired by sp016 task 5): `list`/`set` run inside a
#   specific session's own quickshell process, so that value IS the derived
#   session, resolved once and handed down. A bare call is still refused
#   loudly rather than quietly guessed at — which is the point.
#
# Test: i3/scripts/test-clip-set.sh (headless, Xvfb, two displays).
set -u

T=5                          # seconds before a single xclip call is abandoned
PROG="${0##*/}"

# Where X display sockets are enumerated from for the WRITE fan-out.
# Overridable only so the test harness can present a controlled set of
# displays instead of the host's live ones -- production never sets it.
SOCKET_DIR="${CLIP_SET_SOCKET_DIR:-/tmp/.X11-unix}"

# exit 1 -- nothing has been written yet.
die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }

# exit 2 -- something has already been written.
die_partial() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

# exit 78 (EX_CONFIG) -- the store's own root cannot be named. Same refusal
# clip-store.sh makes for the identical reason: a silent fallback to a
# persistent path would put every copied secret on disk for good.
die_config() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 78; }

# ------------------------------------------------------------------ args ---

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: $PROG <id> [src-display]"
ID="$1"
ARG_SRC="${2:-}"
case "$ID" in
  [0-9][0-9][0-9][0-9][0-9][0-9].clip) : ;;
  *) die "id must look like NNNNNN.clip, got '$ID'" ;;
esac

command -v xclip >/dev/null 2>&1 || die "xclip not found in PATH"

# ------------------------------------------------------------ store root ---
#
# The store lives under $XDG_RUNTIME_DIR and nowhere else (clip-store.sh's
# own invariant); this script does not write the store, but naming a
# fallback path here would be just as much of a persistent-disk leak as
# clip-store.sh writing to one, so the refusal is identical: loud, and
# before anything else runs.
[ -n "${XDG_RUNTIME_DIR:-}" ] \
  || die_config "XDG_RUNTIME_DIR is unset; refusing to guess where the store is"

# The source display: see "WHICH STORE THE ID IS READ FROM" above. REQUIRED
# and EXPLICIT -- CLIP_SET_SRC_DISPLAY wins if set, else the $2 positional,
# else a hard refusal. $DISPLAY is deliberately never consulted here: it is
# exactly as untrustworthy for picking a source store as it is for picking a
# fan-out target, and picking the wrong one is worse (see above).
SRC_DPY="${CLIP_SET_SRC_DISPLAY:-$ARG_SRC}"
[ -n "$SRC_DPY" ] \
  || die "no source display given -- pass it as \$2 or set CLIP_SET_SRC_DISPLAY; \$DISPLAY is never trusted (a per-display store id is meaningless without knowing which store it came from)"

# X DISPLAY may carry a screen suffix (`:0.0`); clip-store.sh keys the store
# dir on the bare display, so strip the screen here too or a raw $DISPLAY
# passed as the source would miss the store entirely. In sh globs `.` is
# literal: `:0.0` -> `:0`, bare `:0` unchanged.
SRC_DPY="${SRC_DPY%.*}"

STORE="$XDG_RUNTIME_DIR/clip-store/$SRC_DPY"

# ----------------------------------------------------------------- entry ---
#
# Read the entry BEFORE touching any display: an unknown/stale id must not be
# able to blank a selection, which is what makes the exit-1 promise true.
# `cat` of a regular file is the whole read -- no escaping layer to get
# wrong, unlike clipcat's `get` (dotfiles-i9i).

ENTRY="$STORE/$ID"
[ -f "$ENTRY" ] \
  || die "no such entry: $ENTRY (unknown or stale id, or store not created yet)"

# A ZERO-BYTE entry is a VALID publish, not a guard failure -- deliberately
# different from copyq's old behaviour, which treated "row empty" and "row
# does not exist" as the same rejection. copyq's `read` had no way to tell
# those apart (an absent row and an empty one both come back as nothing), so
# sp014 task 3 folded "empty" into the precondition-failure guard rather than
# publish an ambiguous result. The file store removes the ambiguity: `-f`
# above answers "does this entry exist" completely independently of its
# length, so an empty file is simply an entry whose content happens to be
# zero bytes -- exactly as real as a copy of an empty selection would be.
# Byte-exactness is this task's whole point (see above); refusing to
# publish a legitimate zero-byte entry would be re-introducing, by policy,
# the exact kind of "not really byte-exact" carve-out the pivot exists to
# eliminate. So: file exists -> publish whatever bytes it holds, including
# none. (In practice clip-store.sh's own capture path never stores a
# zero-byte entry -- its read_sel requires `-s` -- so this case is only
# reachable via direct seeding, e.g. a test fixture or a future writer; it
# is handled correctly here regardless.)

TMP="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$TMP" "$TMP.head"' EXIT

cat "$ENTRY" > "$TMP" 2>/dev/null || die "could not read $ENTRY"

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
