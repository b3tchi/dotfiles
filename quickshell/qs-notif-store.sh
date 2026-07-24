#!/bin/sh
# qs-notif-store.sh -- persistent notification file-store + live-state writer
# (sp019 task 1, dotfiles-c5fd.1). The ft007/clip-store.sh mould, adapted:
# durable history instead of a memory-only tmpfs store ([[adr0013]] departs
# from [[adr0011]] deliberately -- see docs/notes/spec/sp019.md).
#
# This file DEFINES the store contract; qs-notif.sh (task 5) and the
# quickshell/notif daemon (task 2, the only intended caller of `append` /
# `dismiss` / `state`) are written against it.
#
# ------------------------------------------------------------ THE STORE ---
#   store dir   ${XDG_STATE_HOME:-$HOME/.local/state}/qs-notif/   mode 0700
#   entry       NNNNNN.notif -- six-digit zero-padded monotonic seq.
#               line 1  <epoch>\t<urgency>\t<app>
#               line 2  summary (control whitespace folded to a single space)
#               line 3+ raw body bytes, byte-exact, never escaped or folded
#   id          the filename. Opaque to every consumer: equality and
#               existence only, never parsed or arithmetic'd on.
#
#   Lexicographic filename order IS arrival order (spec AC2); newest is the
#   highest seq. Entries become visible ATOMICALLY -- payload written to a
#   `.tmp` work file in the store dir, then link(2)ed into its final name.
#   `ln` (not `mv`) because it FAILS on an existing name instead of silently
#   clobbering it: a seq collision (two concurrent appends) costs a bounded
#   retry, never a lost entry.
#
#   Unlike ft007's clipboard store, this store is DELIBERATELY PERSISTENT
#   (under $XDG_STATE_HOME, never $XDG_RUNTIME_DIR) and age-capped rather
#   than count-capped: every append prunes entries whose header epoch is
#   older than QS_NOTIF_MAX_AGE (default 172800s / 2 days). See [[adr0013]].
#
# ------------------------------------------------------- THE LIVE STATE ---
#   The `state` verb atomically rewrites a small live-state file consumers
#   `tail -F` (default ${QS_NOTIF_STATE:-$XDG_RUNTIME_DIR/qs-notif.state}),
#   tmp+rename so a reader never observes a partial line set:
#     count <N>
#     critical <0|1>
#     seq <N>
#     last <epoch>\t<folded text>
#
# ----------------------------------------------------------- CONSTRAINTS ---
# (adr0002; the clip-store.sh / qs-clip.sh mould)
#  * #!/bin/sh, set -u, umask 077 throughout -- every file/dir this script
#    creates is 0700/0600 by construction.
#  * Ids are opaque strings end to end: equality and shape-check only, never
#    parsed for meaning or used in arithmetic (leading zeros are stripped
#    ONLY for the internal seq-continuation counter, never exposed).
#  * Unset XDG_RUNTIME_DIR fails `state` loudly (exit 78, EX_CONFIG); unset
#    HOME and XDG_STATE_HOME both fail the store verbs (`append`/`dismiss`)
#    the same way -- no silent fallback to a guessed path.
#
# usage: qs-notif-store.sh append <epoch> <urgency> <app> <summary>   (body on stdin)
#        qs-notif-store.sh dismiss <id|latest>
#        qs-notif-store.sh state <count> <critical:0|1> <seq> <epoch> <text>
# env:   QS_NOTIF_MAX_AGE   seconds before an entry is pruned (default 172800)
#        QS_NOTIF_STATE     live-state file path (default $XDG_RUNTIME_DIR/qs-notif.state)
# exit:  0 ok / 1 usage or missing entry / 78 XDG unset (EX_CONFIG)
set -u
umask 077

PROG="${0##*/}"

MAX_AGE="${QS_NOTIF_MAX_AGE:-172800}"

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }

# Fold control whitespace (tab, real newline, CR, vertical/form feed) in <text>
# to a single space each -- applied to the summary line and the state file's
# `last` text, never to the raw body (which must stay byte-exact). tr maps
# position-wise between two equal-length sets, so each of the five listed
# characters becomes exactly one space.
fold_ws() { # <text>
  printf '%s' "$1" | tr '\t\n\r\v\f' '     '
}

# Store dir: ${XDG_STATE_HOME:-$HOME/.local/state}/qs-notif. Both
# XDG_STATE_HOME and HOME unset is refused loudly (exit 78) rather than
# guessing a path -- the family convention every store script shares.
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

# Path of the newest entry (highest seq) in <store>; empty when none.
# Pathname expansion is sorted, so the last match is the newest.
newest_entry() { # <store>
  _ne=""
  for _f in "$1"/[0-9][0-9][0-9][0-9][0-9][0-9].notif; do
    [ -e "$_f" ] && _ne="$_f"
  done
  printf '%s' "$_ne"
}

# Link <wip> into <store> as the next seq entry. Recomputed from the
# directory on every write so a restarted caller continues the sequence
# rather than restarting it. Leading zeros are stripped before arithmetic --
# $((000008)) is an octal error in POSIX sh. On an `ln` collision (a
# concurrent append took the seq) the next number is tried; the retry is
# bounded so a wedged directory cannot spin forever.
store_write() { # <store> <wip>
  _store="$1" _wip="$2"
  _last="$(newest_entry "$_store")"
  if [ -n "$_last" ]; then
    _b="${_last##*/}"; _b="${_b%.notif}"
    _n="${_b#"${_b%%[!0]*}"}"; [ -n "$_n" ] || _n=0
    _n=$((_n + 1))
  else
    _n=1
  fi
  _tries=0
  while [ "$_tries" -lt 100 ]; do
    if ln "$_wip" "$_store/$(printf '%06d' "$_n").notif" 2>/dev/null; then
      rm -f "$_wip"
      return 0
    fi
    _n=$((_n + 1)); _tries=$((_tries + 1))
  done
  return 1
}

# Prune entries whose header epoch is older than QS_NOTIF_MAX_AGE seconds
# (default 172800s / 2 days). Age is measured against the CURRENT wall
# clock, not the epoch of the entry just written -- an entry exactly at the
# cap is kept, one second past it is pruned (strict >, not >=).
prune() { # <store>
  _store="$1"
  _now="$(date +%s)"
  for _f in "$_store"/[0-9][0-9][0-9][0-9][0-9][0-9].notif; do
    [ -e "$_f" ] || continue
    _hdr_epoch="$(sed -n '1p' "$_f" | cut -f1)"
    case "$_hdr_epoch" in '' | *[!0-9]*) continue ;; esac
    if [ $((_now - _hdr_epoch)) -gt "$MAX_AGE" ]; then
      rm -f "$_f"
    fi
  done
}

# --------------------------------------------------------------- append ---

cmd_append() {
  [ $# -eq 4 ] || die "usage: $PROG append <epoch> <urgency> <app> <summary>"
  _epoch="$1" _urgency="$2" _app="$3" _summary="$4"

  _store="$(store_dir)"; _rc=$?
  [ "$_rc" -eq 0 ] || exit "$_rc"

  mkdir -p "$_store" || exit 1
  chmod 700 "$_store"

  _wip="$_store/.wip.$$"
  {
    printf '%s\t%s\t%s\n' "$_epoch" "$_urgency" "$_app"
    printf '%s\n' "$(fold_ws "$_summary")"
    cat
  } > "$_wip" || { rm -f "$_wip"; exit 1; }

  store_write "$_store" "$_wip" || { rm -f "$_wip"; exit 1; }
  prune "$_store"
  return 0
}

# -------------------------------------------------------------- dismiss ---

# Highest-seq entry name in <store> (bare filename, not a path); empty when
# the store is empty or absent.
newest_name() { # <store>
  _nn=""
  for _f in "$1"/[0-9][0-9][0-9][0-9][0-9][0-9].notif; do
    [ -e "$_f" ] && _nn="${_f##*/}"
  done
  printf '%s' "$_nn"
}

cmd_dismiss() {
  [ $# -eq 1 ] || die "usage: $PROG dismiss <id|latest>"
  _store="$(store_dir)"; _rc=$?
  [ "$_rc" -eq 0 ] || exit "$_rc"

  if [ "$1" = "latest" ]; then
    _id="$(newest_name "$_store")"
    [ -n "$_id" ] || { printf '%s: no entries to dismiss\n' "$PROG" >&2; exit 1; }
  else
    _id="$1"
  fi

  # Shape-check BEFORE any path use, regardless of whether the id came from
  # "latest" resolution or the caller directly -- an id is an opaque string,
  # matched for shape only, never trusted to be safe as a path component.
  case "$_id" in
    [0-9][0-9][0-9][0-9][0-9][0-9].notif) : ;;
    *) die "invalid id: '$_id'" ;;
  esac

  [ -f "$_store/$_id" ] || { printf '%s: no such entry: %s\n' "$PROG" "$_id" >&2; exit 1; }
  rm -f "$_store/$_id"
}

# ----------------------------------------------------------------- state ---

# Live-state file path: ${QS_NOTIF_STATE:-$XDG_RUNTIME_DIR/qs-notif.state}.
# Unlike store_dir() this ALWAYS requires either the override or
# XDG_RUNTIME_DIR -- there is no HOME fallback, because the live-state file
# is transient (consumers tail -F it) and belongs under the runtime dir, not
# on persistent disk. Checked explicitly (rather than relying on the
# ${VAR:-word} expansion) so an unset XDG_RUNTIME_DIR fails loudly at exit
# 78 instead of `set -u` killing the script with an unbound-variable error
# whose exit code is not ours to control.
state_file() {
  if [ -n "${QS_NOTIF_STATE:-}" ]; then
    printf '%s' "$QS_NOTIF_STATE"
    return 0
  fi
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    printf '%s: XDG_RUNTIME_DIR is unset; refusing to guess a live-state path\n' "$PROG" >&2
    return 78
  fi
  printf '%s/qs-notif.state\n' "$XDG_RUNTIME_DIR"
  return 0
}

cmd_state() {
  [ $# -eq 5 ] || die "usage: $PROG state <count> <critical:0|1> <seq> <epoch> <text>"
  _count="$1" _critical="$2" _seq="$3" _epoch="$4" _text="$5"

  _sf="$(state_file)"; _rc=$?
  [ "$_rc" -eq 0 ] || exit "$_rc"

  _sf_dir="${_sf%/*}"
  [ "$_sf_dir" != "$_sf" ] && { mkdir -p "$_sf_dir" || exit 1; }

  _tmp="${_sf}.tmp.$$"
  {
    printf 'count %s\n' "$_count"
    printf 'critical %s\n' "$_critical"
    printf 'seq %s\n' "$_seq"
    printf 'last %s\t%s\n' "$_epoch" "$(fold_ws "$_text")"
  } > "$_tmp" || { rm -f "$_tmp"; exit 1; }

  mv -f "$_tmp" "$_sf" || { rm -f "$_tmp"; exit 1; }
}

# --------------------------------------------------------------- main ---

case "${1:-}" in
  append)  shift; cmd_append "$@" ;;
  dismiss) shift; cmd_dismiss "$@" ;;
  state)   shift; cmd_state "$@" ;;
  *) die "usage: $PROG {append|dismiss|state} ..." ;;
esac
