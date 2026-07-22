#!/bin/sh
# qs-clip.sh — clipboard-history picker control script (sp014 task 4; backend
# swapped to the bespoke file store by sp016 task 2, dotfiles-egm.2).
#
# usage: qs-clip.sh [toggle]      open/close the picker on the active session
#        qs-clip.sh list          print the history as "<id>\t<preview>" lines
#        qs-clip.sh set <id>      put store entry <id> on the clipboard
#
# The picker itself is quickshell/config/ClipHistory.qml, hosted inside the
# session's normal quickshell instance (config/shell.qml wires it in). This
# script is BOTH the outside entry point (`toggle`, bound to a key in the base
# i3 config) and the back end the QML calls (`list`, `set`) — so every piece of
# non-UI logic lives here in sh where it can be unit-tested without an X server,
# and the QML stays presentation only.
#
# WHICH SESSION — DERIVED, NEVER INHERITED (toggle only)
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
#   `QS_CLIP_DISPLAY` (e.g. `DISPLAY=:10`) forces a session explicitly. This
#   logic is UNCHANGED by the backend swap below — `list`/`set` are called
#   from inside a specific session's own quickshell process (its own `sh
#   qs-clip.sh list`/`set` child), so they read the session they are already
#   running under (`$DISPLAY`) and never need to probe or guess between
#   instances the way `toggle` does.
#
# BACKEND — THE FILE STORE (sp016 ## plan; see clip-store/dot.yaml and
# i3/scripts/clip-store.sh for the full contract this reads):
#
#   store dir   $XDG_RUNTIME_DIR/clip-store/<display>/    0700, tmpfs
#   entry       NNNNNN.clip — six-digit zero-padded monotonic seq, raw bytes
#   id          the filename. Opaque to this script: matched for existence
#               and equality only, never parsed or arithmetic'd on. `list`
#               reads it to preview and reports it back verbatim; `set`
#               forwards it to clip-set.sh unexamined beyond a shape check
#               that guards against it being used as a path component.
#
#   Lexicographic filename order IS capture order, so newest-first is a
#   reverse sort — deterministic, no daemon round-trip, no N+1 reads (the
#   defect class the prior copyq/clipcat backends could not avoid).
#
# `set` is a thin wrapper over i3/scripts/clip-set.sh — invoked as
# `clip-set.sh <id> <src-display>`, the source display being this process's
# own session (see cmd_set) — and propagates its exit code verbatim, because
# the picker's UI depends on the 0/1/2 split:
#   0 = on the clipboard of every live display, 1 = nothing written anywhere
#   (safe to retry), 2 = partial write, clipboard state indeterminate.
# See i3/scripts/clip-set.sh for the full contract. This script does its own
# existence check on the id before ever invoking clip-set.sh — belt-and-
# suspenders against the entry vanishing between `list` and `set` (a file
# whose last reader was seconds ago, pruned by a cap enforcement in between)
# — but does not otherwise duplicate clip-set.sh's job.
#
# Test: quickshell/test-clip-history.sh (headless; file-store fixtures need
# no X server for `list`/`set` — only the `toggle` session-derivation
# regression scenarios still use Xvfb + a running quickshell instance).
set -u

PROG="${0##*/}"
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

TARGET=cliphistory                    # the IpcHandler target in ClipHistory.qml
ENTRY_GLOB='[0-9][0-9][0-9][0-9][0-9][0-9].clip'
ENTRY_RE='^[0-9]{6}\.clip$'

# Overridable only so the headless suite can point at a stub / a worktree copy;
# production leaves all three unset.
CLIP_SET="${QS_CLIP_SET:-$SELF_DIR/../i3/scripts/clip-set.sh}"
CAP="${QS_CLIP_CAP:-200}"             # most entries the picker will ever show
WIDTH="${QS_CLIP_PREVIEW:-120}"       # preview characters before truncation

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }

case "$CAP"   in '' | *[!0-9]*) die "QS_CLIP_CAP must be a number, got '$CAP'" ;; esac
case "$WIDTH" in '' | *[!0-9]*) die "QS_CLIP_PREVIEW must be a number, got '$WIDTH'" ;; esac

# --------------------------------------------------------------- the store ---
#
# Prints the store directory for the session this process is running under,
# or fails loudly. Matches clip-store.sh's own computation exactly (same
# $XDG_RUNTIME_DIR/clip-store/<display> shape) so a consumer always looks
# where the writer wrote. Unset $XDG_RUNTIME_DIR fails loudly (exit 78, the
# family convention every store script shares) rather than falling back to
# any persistent path. An unset $DISPLAY is a plain usage error (exit 1):
# `list`/`set` run inside a specific session's own quickshell process, which
# always has one — there is nothing to derive here, unlike `toggle`.
store_dir() {
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    printf '%s: XDG_RUNTIME_DIR is unset; refusing to guess a store location\n' "$PROG" >&2
    return 78
  fi
  if [ -z "${DISPLAY:-}" ]; then
    printf '%s: DISPLAY is unset; cannot locate this session'"'"'s clipboard store\n' "$PROG" >&2
    return 1
  fi
  printf '%s/clip-store/%s\n' "$XDG_RUNTIME_DIR" "$DISPLAY"
  return 0
}

# ------------------------------------------------------------------- list ---
#
# One line per entry: "<id>\t<preview>". The id is the store filename the
# caller must hand back to `set` verbatim — it is never renumbered, so
# filtering/sorting in the UI can never desynchronise the visible list from
# the store (a filtered-to-one-row list still reports that row's real id).
#
# Newest first: filenames sort lexicographically in capture order, so a
# descending sort on the name IS newest-first — deterministic across calls
# with an unchanged store, unlike the copyq backend this replaced.
#
# The preview is the first NON-BLANK line of the entry, with tabs and other
# control whitespace folded to spaces (a raw tab or newline in the preview
# would break the "<id>\t<preview>" line protocol) and truncated to WIDTH
# characters. Leading blank lines are skipped because an entry that starts
# with them would otherwise render as a blank row — the preview exists only
# to identify the entry; `set` still publishes the full raw file, untouched
# by any of this folding or truncation.
#
# Consumers of the store read ONLY the `??????.clip` glob (six digits, the
# literal extension) and skip everything else: dotfiles (`.wip.tmp`, `.tgt`)
# and any in-flight `*.tmp` are writer work files, never a visible entry —
# this is what makes tmp-file-mid-write invisible to `list` by construction,
# not by a special case.
#
# The list is capped at CAP entries. A store larger than that is not paged;
# the oldest entries are simply not offered (still reachable by `set <id>`
# directly, and pruned from the store itself only by clip-store.sh's own cap).
#
# Absent/empty store dir: no output, exit 0 — a fresh session with nothing
# captured yet is not an error.
cmd_list() {
  _store="$(store_dir)"; _rc=$?
  [ "$_rc" -eq 0 ] || exit "$_rc"

  [ -d "$_store" ] || return 0

  _n=0
  for _name in $(cd "$_store" 2>/dev/null && ls -1 2>/dev/null \
                 | grep -E "$ENTRY_RE" | sort -r); do
    [ "$_n" -lt "$CAP" ] || break
    _path="$_store/$_name"
    [ -f "$_path" ] || continue   # vanished between the listing and this read
    printf '%s\t%s\n' "$_name" "$(preview_of "$_path")"
    _n=$((_n + 1))
  done
  return 0
}

# The first non-blank line of <file>, tabs/control-whitespace folded to a
# single space, trimmed, truncated to WIDTH characters (an ellipsis replaces
# the last character when it is). "(empty)" when every line is blank or the
# file has none. A literal two-character `\n` (backslash, n) is two ordinary
# characters here — only a REAL newline byte splits lines — and gawk's
# length()/substr() are character-, not byte-, aware in a UTF-8 locale, so a
# multi-byte preview truncates on a character boundary rather than mid-byte.
preview_of() { # <path>
  gawk -v W="$WIDTH" '
    {
      line = $0
      gsub(/[\t\r\v\f]/, " ", line)
      gsub(/^[ ]+/, "", line)
      gsub(/[ ]+$/, "", line)
      if (line != "" && !found) { p = line; found = 1 }
    }
    END {
      if (!found) p = "(empty)"
      if (length(p) > W) p = substr(p, 1, W - 1) "\xe2\x80\xa6"
      print p
    }
  ' "$1"
}

# -------------------------------------------------------------------- set ---
#
# exec, so clip-set.sh's exit code IS this script's exit code — the picker
# reads 0/1/2 off it and shows a different outcome for each. The id is
# forwarded byte-for-byte; nothing here reads or touches the entry's payload,
# so the full raw file is what eventually gets published, never the
# (lossy, truncated) preview.
cmd_set() {
  [ $# -eq 1 ] || die "usage: $PROG set <id>"

  # Shape check only — six digits + the literal extension. This is NOT
  # parsing the id for meaning (no arithmetic, no stripped leading zeros); it
  # exists solely so an id is never used to build an unexpected path
  # component. Equality against what `list` actually offered is still what
  # matters; this just bounds what "equality" is allowed to look like.
  case "$1" in
    $ENTRY_GLOB) : ;;
    *) die "invalid id: '$1'" ;;
  esac

  _store="$(store_dir)"; _rc=$?
  [ "$_rc" -eq 0 ] || exit "$_rc"

  # The entry may have vanished between the `list` that offered this id and
  # this `set` (a cap-enforced prune, a concurrent capture pushing it out).
  # Caught here, before clip-set.sh ever runs: exit 1, nothing published —
  # the same "nothing was touched" promise clip-set.sh's own precondition
  # checks make for every other failure it can detect up front.
  [ -f "$_store/$1" ] || { printf '%s: no such entry: %s\n' "$PROG" "$1" >&2; exit 1; }

  [ -r "$CLIP_SET" ] || die "clip-set.sh not found at $CLIP_SET"
  # The SOURCE DISPLAY is passed explicitly as $2 (sp016 task 5, the egm.3
  # outcome): the store is per-display, so "000005.clip" in :0's store and
  # :10's store routinely both exist as unrelated entries, and clip-set.sh
  # REFUSES a bare call rather than fall back to its own inherited DISPLAY
  # (see "WHICH STORE THE ID IS READ FROM" in its header). This process runs
  # inside a specific session's own quickshell instance, so its $DISPLAY *is*
  # the derived session — the same one store_dir() just resolved the id
  # against, which is what makes the existence check above and the read below
  # look at the same store.
  exec sh "$CLIP_SET" "$1" "$DISPLAY"
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
  *)      die "usage: $PROG [toggle|list|set <id>]" ;;
esac
