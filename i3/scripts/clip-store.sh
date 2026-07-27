#!/bin/sh
# clip-store.sh — per-display clipboard file-store loop: the bespoke backend
# that replaced clipcat as ft007's history store.  [sp016 task 6, pivot per
# poc012 after clipcat was falsified in execution: dotfiles-8il (list order
# non-deterministic), dotfiles-i9i (get irreversibly escapes control chars),
# dotfiles-apl (~25% of daemon starts born deaf).]
#
# One loop per display.  It blocks — poll-free — on `clipnotify -s clipboard`
# (XFixes selection events; official `extra` package, installed by
# clip-store/dot.yaml).  On each event it inspects the owner's TARGETS list
# FIRST, and only if no password-manager hint is advertised reads the payload
# and stores it as the next sequence file.  No daemon: a dead loop is visible
# (`pgrep`) and restartable by an i3 config reload, unlike clipcat's
# silently-deaf daemon.
#
# ------------------------------------------------------------ THE STORE ---
# This file DEFINES the store contract (sp016 ## plan); qs-clip.sh,
# clip-set.sh and clip-feed.sh are written against it:
#
#   store dir   $XDG_RUNTIME_DIR/clip-store/<display>/     0700, tmpfs
#   entry       NNNNNN.clip (text) or NNNNNN.img (image, always normalized
#               PNG bytes — see IMAGES below) — six-digit zero-padded
#               monotonic seq, raw payload bytes exactly as served: no
#               trailing newline added or stripped, no escaping.
#               Lexicographic filename order == capture order; newest is
#               the highest seq. The seq is ONE shared counter across both
#               kinds — a text and an image capture never collide on a
#               number — so a plain newest-first sort of the combined glob
#               still yields true capture order regardless of extension.
#   id          the filename.  Opaque to consumers: equality only, never
#               parsed, ordered on beyond sorting, or done arithmetic on.
#   work files  dotfiles (.wip.tmp, .tgt, .img.*.tmp) plus the in-flight
#               `*.tmp` write.  Consumers read only `??????.clip` /
#               `??????.img` names and skip everything else — a mid-write
#               `.tmp` is never a visible entry.
#
# Entries become visible ATOMICALLY: the payload is written to a `.tmp` in
# the same directory and link(2)ed into its final name — a reader never sees
# a partial entry.  `ln` rather than `mv` because it FAILS on an existing
# name instead of silently clobbering it: clip-feed.sh (task 7) writes into
# this same store from another process, and a seq collision must cost a
# retry, not an entry.  Consecutive identical captures dedup against the
# newest entry OF THE SAME KIND; CLIP_STORE_CAP / CLIP_STORE_IMG_CAP prune
# oldest entries of each kind independently after each write of that kind.
#
# ------------------------------------------------------------- IMAGES ---
# An image-only selection (no text target — the common case for a screen
# copy or, over xrdp, a Windows clipboard image) is captured too, as a
# SEPARATE entry kind (`.img`) rather than forced through the text path.
# Same TARGETS-driven negotiation clip-img-bridge.sh uses: image/png
# preferred, image/bmp accepted and converted (ImageMagick) — xrdp-chansrv
# 0.10.x serves Windows clipboard images as image/bmp only, and a stored
# `.img` entry is ALWAYS real PNG bytes regardless of source, so a reader
# never has to guess the format from the extension. A selection offering
# BOTH a text and an image target (a browser image-with-alt-text copy)
# captures as text — image capture only runs when read_sel finds no text
# target at all, so a plain-text-and-image mixed owner behaves exactly as
# it always has.
#
# Images get their OWN cap (CLIP_STORE_IMG_CAP, default 20 — much smaller
# than text's 100): a handful of screenshots are already megabytes on a
# tmpfs sized for text history, so the two kinds are pruned independently
# rather than letting large image entries crowd out small text ones under
# one shared limit.
#
# The store lives under $XDG_RUNTIME_DIR and NOWHERE ELSE — tmpfs, mode
# 0700, destroyed by logind at last logout.  That makes memory-only a
# filesystem-level property (copyq's daemon guarantee, which clipcat had
# demoted to config discipline).  If $XDG_RUNTIME_DIR is unset this script
# refuses to start, loudly (exit 78, EX_CONFIG — the same refusal clipcatd
# made for its history path): a silent fallback would put every copied
# secret on persistent disk.  Nothing here calls mktemp or touches /tmp.
#
# ------------------------------------------------------------- SECURITY ---
# The secret gate is the same code shape as clip-feed.sh's, checked on every
# capture path — the drop decision is OUR adversarially-tested code, not
# daemon config:
#
#  * TARGETS pre-check: the MIME targets the owner advertises are the ONLY
#    thing read from a selection that turns out to be a secret.  BOTH hint
#    spellings are matched — bare `x-kde-passwordManagerHint` and prefixed
#    `application/x-kde-passwordManagerHint` (clipcat defaulted to bare, the
#    shipped copyq rule used prefixed; neither is verified against a real
#    emitter — sp015 / dotfiles-cyg remain the actual fix, and this loop
#    ships no security improvement over the backends it replaces).  Do not
#    move this check below the payload read and do not remove it.
#  * TOCTOU re-check: TARGETS and the payload are separate X protocol
#    requests and X cannot fetch them atomically, so a password manager can
#    take the selection AFTER the gate passed on the previous owner and the
#    payload read then returns the secret (dotfiles-l6s; deterministically
#    reproduced by test-clip-store.sh's race-owner.py).  Re-checking TARGETS
#    after the read and refusing to store a payload a hint-bearing owner
#    currently claims closes the single-flip case.  Fails CLOSED: a re-check
#    that times out or finds no owner drops the item too.
#
# RESIDUAL EXPOSURE, stated plainly: a raced secret payload does reach the
# .wip.tmp work file before the re-check drops it — 0600, tmpfs, truncated
# on the next read (better than clip-feed.sh's /tmp mktemp, but not nothing).
# A third owner flipping ownership twice inside the ~10ms read window would
# still get through.  And the whole store is plaintext on tmpfs for the
# session's lifetime — same exposure as copyq and clipcat before it.
#
# ---------------------------------------------------------- CONSTRAINTS ---
# (adr0002; the clip-sync.sh / clip-feed.sh mould)
#  * The display is NAMED, never guessed: pass it as $1 or CLIP_STORE_DISPLAY.
#    An inherited $DISPLAY is deliberately ignored — the loop behaves
#    identically started from an i3 autostart, a tmux pane, or a login shell.
#  * Every xclip call is `timeout`-wrapped: a hung selection owner (dead RDP
#    client, image payload) must cost one bounded read, not wedge the loop.
#    `clipnotify` itself is NOT wrapped — blocking indefinitely is its job,
#    and it exits nonzero on its own when the display dies, which is what
#    ends this loop cleanly (no busy-spin, no zombie).
#  * flock single-instance per display: i3 `exec_always` re-runs autostarts
#    on config reload, and a second loop would race the first for every
#    event.  Losing the race is the normal case, not an error: exit 0.
#    Children close fd 9 (`9>&-`) so a forked xclip/clipnotify never holds
#    the lock past this shell's death (the clip-feed.sh lesson — observed).
#
# usage: i3/scripts/clip-store.sh <display>      (e.g. clip-store.sh :0)
# env:   CLIP_STORE_DISPLAY  display to serve (alternative to $1)
#        CLIP_STORE_CAP      max text entries kept (default 100; oldest pruned)
#        CLIP_STORE_IMG_CAP  max image entries kept (default 20; oldest pruned)
#        CLIP_STORE_TIMEOUT  seconds before one xclip call is abandoned (1)
#        CLIP_STORE_LOCK     single-instance lock file
#                            (default $XDG_RUNTIME_DIR/clip-store/<display>.lock)
#        CLIPNOTIFY          clipnotify binary (default: from PATH; the test
#                            harness points this at a source-built stand-in)
#        MAGICK              convert binary for image capture (default:
#                            magick, falling back to convert)
# exit:  0 on clean end (display gone / lost the single-instance race),
#        78 (EX_CONFIG) when the display or XDG_RUNTIME_DIR is missing.
set -u

DPY="${CLIP_STORE_DISPLAY:-${1:-}}"
CAP="${CLIP_STORE_CAP:-100}"
IMG_CAP="${CLIP_STORE_IMG_CAP:-20}"
T="${CLIP_STORE_TIMEOUT:-1}"
CN="${CLIPNOTIFY:-clipnotify}"

if [ -z "$DPY" ]; then
  echo "clip-store.sh: no display: pass one as \$1 or set CLIP_STORE_DISPLAY" >&2
  exit 78
fi
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  echo "clip-store.sh: XDG_RUNTIME_DIR is unset; refusing to fall back to a persistent path" >&2
  exit 78
fi

# X DISPLAY may carry a screen suffix (`:0.0`); the store dir is keyed on the
# bare display so a caller that passes the raw $DISPLAY still lands in the
# same directory the autostart (bare `:0`/`:10`) writes into. In sh globs `.`
# is literal: `:0.0` -> `:0`, bare `:0` unchanged. Done AFTER the emptiness
# check above so an unset display still fails loudly instead of silently
# normalizing away to nothing.
DPY="${DPY%.*}"

if ! command -v "$CN" >/dev/null 2>&1; then
  echo "clip-store.sh: clipnotify not found ('$CN'); install it (rotz install clip-store) or set CLIPNOTIFY=" >&2
  exit 69
fi

# ImageMagick — only needed for the image/bmp->png fallback (xrdp-chansrv
# serves Windows clipboard images as bmp only); a bare image/png selection
# never reaches this. Absence is refused loudly rather than silently
# skipping every image capture, matching the clipnotify refusal above.
MAGICK="${MAGICK:-}"
if [ -z "$MAGICK" ]; then
  if command -v magick >/dev/null 2>&1; then MAGICK=magick
  elif command -v convert >/dev/null 2>&1; then MAGICK=convert
  else
    echo "clip-store.sh: no ImageMagick 'magick'/'convert' found (needed for image/bmp capture)" >&2
    exit 69
  fi
fi

# 0700/0600 on everything this process creates, including the store dir and
# every entry — the containing tmpfs is per-user already, but the modes make
# the promise local.
umask 077

ROOT="$XDG_RUNTIME_DIR/clip-store"
STORE="$ROOT/$DPY"
LOCK="${CLIP_STORE_LOCK:-$ROOT/$DPY.lock}"

mkdir -p "$STORE" || exit 1
chmod 700 "$ROOT" "$STORE"

# Single-instance guard, per display (see CONSTRAINTS above).
exec 9>"$LOCK" || exit 1
flock -n 9 || exit 0

# Work files live INSIDE the store dir — never /tmp, never mktemp — so the
# "nothing outside $XDG_RUNTIME_DIR" property holds by construction.  Dotfile
# names, and .wip.tmp ends in .tmp: consumers skip both.  Fixed names are
# safe because flock guarantees one loop per store; clip-feed.sh writes with
# its own distinct names.
WIP="$STORE/.wip.tmp"
TGT="$STORE/.tgt"
IMG_RAW="$STORE/.img.raw.tmp"
IMG_WIP="$STORE/.img.wip.tmp"
trap 'rm -f "$WIP" "$TGT" "$IMG_RAW" "$IMG_WIP"' EXIT

# The MIME targets the current owner advertises.  Cheap, and for a selection
# that turns out to be a secret it is the ONLY thing ever read.
targets() {
  timeout "$T" env DISPLAY="$DPY" xclip -selection clipboard -t TARGETS -o \
    > "$TGT" 2>/dev/null 9>&-
}

# Does the advertised TARGETS list carry a password-manager hint, in either
# spelling?  Same gate shape as clip-feed.sh, extended to both atom forms.
hinted() {
  grep -qFx -e 'x-kde-passwordManagerHint' \
            -e 'application/x-kde-passwordManagerHint' "$TGT"
}

# Does the (already-fetched) TARGETS list carry the given atom? Used to pick
# an image source target without a second X round-trip — $TGT is still fresh
# from the targets() call at the top of handle_event.
has_target() { grep -qFx "$1" "$TGT"; }

# Does the current owner advertise a text target at all? THIS, not read_sel's
# exit code, is what decides text-vs-image — verified live against this
# host's xclip: a bare `xclip -o` with no `-t` does NOT fail on an
# image-only owner, it happily serves the image bytes as "text" (the
# opposite of what the pre-image-support version of this file assumed,
# which is how a run of plain image copies ended up stored as garbage
# `.clip` entries — `PNG`/`BM` magic bytes with a text extension — before
# this check existed). A mixed owner (image plus a text/plain URL, as
# browsers publish) still routes to text, matching prior intent.
has_text_target() {
  has_target UTF8_STRING || has_target STRING || has_target TEXT || has_target text/plain
}

# Read the payload as text; nonzero on timeout, error, or empty selection.
# Only ever called after has_text_target confirmed a text target exists —
# see that function for why the bare call itself cannot be trusted to fail
# on a non-text owner. An owner holding an EMPTY string succeeds with zero
# bytes, which the -s test skips.
read_sel() {
  timeout "$T" env DISPLAY="$DPY" xclip -selection clipboard -o \
    > "$WIP" 2>/dev/null 9>&- && [ -s "$WIP" ]
}

# Path of the newest entry of ONE kind (highest seq); empty when none exist.
# Pathname expansion is sorted, so the last match is the newest. Used for
# same-kind dedup — an image capture never dedups against the newest TEXT
# entry or vice versa, since the two are unrelated content.
newest_clip() {
  ne=""
  for f in "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
    [ -e "$f" ] && ne="$f"
  done
  printf '%s' "$ne"
}
newest_img() {
  ne=""
  for f in "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9].img; do
    [ -e "$f" ] && ne="$f"
  done
  printf '%s' "$ne"
}

# Highest sequence number in use ACROSS BOTH KINDS — the shared counter that
# keeps a text and an image capture from ever landing on the same number.
# Explicit numeric max, not "last match wins": `for f in glob1 glob2` yields
# each glob's own sorted matches one after another, not the two interleaved,
# so picking the last iterated file would pick the highest-numbered .img
# even when a higher-numbered .clip exists. Leading zeros are stripped
# before arithmetic — $((000008)) is an octal error in POSIX sh.
max_seq() {
  m=0
  for f in "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9].clip \
           "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9].img; do
    [ -e "$f" ] || continue
    b="${f##*/}"; b="${b%.*}"
    n="${b#"${b%%[!0]*}"}"; [ -n "$n" ] || n=0
    [ "$n" -gt "$m" ] && m="$n"
  done
  printf '%s' "$m"
}

# Link a work file into place as the next seq entry, with the given
# extension. Recomputed from the directory on every write (the feeder
# appends to this store too, and a restarted loop must continue the
# sequence, not restart it). On an `ln` collision (concurrent writer took
# the seq — clip-feed.sh, or the other kind's own writer) the next number is
# tried; the retry is bounded so a wedged directory cannot spin forever.
store_write_as() { # <work-file> <extension, e.g. clip or img>
  n=$(($(max_seq) + 1))
  tries=0
  while [ "$tries" -lt 100 ]; do
    if ln "$1" "$STORE/$(printf '%06d' "$n").$2" 2>/dev/null; then
      rm -f "$1"
      return 0
    fi
    n=$((n + 1)); tries=$((tries + 1))
  done
  rm -f "$1"
  return 1
}
store_write() { store_write_as "$WIP" clip; }
store_write_img() { store_write_as "$IMG_WIP" img; }

# Enforce a cap on one kind: delete its oldest entries until at most the
# given limit remain. Kinds are pruned independently — see IMAGES above for
# why images get their own (smaller) limit rather than sharing text's.
prune_kind() { # <extension> <cap>
  while :; do
    count=0; oldest=""
    for f in "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9]."$1"; do
      [ -e "$f" ] || continue
      count=$((count + 1))
      [ -n "$oldest" ] || oldest="$f"
    done
    [ "$count" -le "$2" ] && break
    rm -f "$oldest"
  done
}
prune() { prune_kind clip "$CAP"; }
prune_img() { prune_kind img "$IMG_CAP"; }

# One selection-change event: gate, read, re-check, dedup, write, prune.
handle_event() {
  mkdir -p "$STORE"   # recreated if deleted mid-session

  # No owner / hung owner / display vanished mid-event: nothing to store.
  targets || return 0

  # SECURITY GATE — must stay above read_sel.  A password-manager copy is
  # skipped without its payload ever being fetched; only TARGETS was read.
  if hinted; then
    return 0
  fi

  # Kind is decided from TARGETS content, not from read_sel's exit code —
  # see has_text_target's own comment for why that distinction matters.
  if has_text_target; then
    read_sel || return 0

    # TOCTOU RE-CHECK — the second half of the gate; see SECURITY above.  The
    # gate passed on whoever owned the selection THEN; the payload in $WIP
    # came from whoever owned it a few milliseconds LATER.  Ask who owns it
    # now and refuse to store a payload a password manager currently claims.
    # Fails closed: a timed-out or ownerless re-check drops the item too.
    if ! targets || hinted; then
      rm -f "$WIP"
      return 0
    fi

    # Dedup: X owners re-announce and re-serve identical content (and xclip
    # re-reads it); an entry identical to the newest TEXT entry is not a new
    # copy — never compared against the newest image, which is unrelated
    # content.
    last="$(newest_clip)"
    if [ -n "$last" ] && cmp -s "$WIP" "$last"; then
      rm -f "$WIP"
      return 0
    fi

    store_write || return 0
    prune
    return 0
  fi

  # No text target at all: see IMAGES above. $TGT is still the targets()
  # read from the top of this function, a few ms old at most — reused here
  # instead of a second X round-trip.
  handle_image_event
}

# Image half of handle_event, split out for clarity. Same gate/TOCTOU/dedup
# shape as the text path, applied to whichever image target the owner
# advertises.
handle_image_event() {
  if has_target image/png; then SRC_TARGET=image/png
  elif has_target image/bmp; then SRC_TARGET=image/bmp
  else return 0
  fi

  timeout "$T" env DISPLAY="$DPY" xclip -selection clipboard -t "$SRC_TARGET" -o \
    > "$IMG_RAW" 2>/dev/null 9>&-
  [ -s "$IMG_RAW" ] || { rm -f "$IMG_RAW"; return 0; }

  # TOCTOU RE-CHECK — see SECURITY above; applies identically to an image
  # payload as to a text one.
  if ! targets || hinted; then
    rm -f "$IMG_RAW"
    return 0
  fi

  if [ "$SRC_TARGET" = image/png ]; then
    mv "$IMG_RAW" "$IMG_WIP"
  else
    # xrdp-chansrv 0.10.x serves a Windows clipboard image as image/bmp
    # only (verified live; see clip-img-bridge.sh) — normalized to PNG here
    # so every stored `.img` entry is real PNG bytes regardless of source.
    "$MAGICK" "$IMG_RAW" "$IMG_WIP" 2>/dev/null || { rm -f "$IMG_RAW" "$IMG_WIP"; return 0; }
    rm -f "$IMG_RAW"
  fi
  [ -s "$IMG_WIP" ] || { rm -f "$IMG_WIP"; return 0; }

  last="$(newest_img)"
  if [ -n "$last" ] && cmp -s "$IMG_WIP" "$last"; then
    rm -f "$IMG_WIP"
    return 0
  fi

  store_write_img || return 0
  prune_img
}

# The poc012 shape, pipelined: clipnotify blocks until the CLIPBOARD owner
# changes, poll-free, and exits nonzero when the display goes away — which
# ends the loop cleanly.  The watcher for the NEXT event is spawned BEFORE
# the current event is handled: a bare `while clipnotify; do handle; done`
# is deaf for the whole of handle_event (three xclip round-trips), and a
# copy made in that window was measurably lost at 50ms spacing — poc012's
# single-read loop was simply fast enough to hide the gap.  With the next
# subscription already standing during the read, the un-subscribed window
# shrinks to one clipnotify startup (~ms): every copy gets its own handled
# iteration at 50ms spacing (all five land — the poc012 bar), and a burst
# faster than the read coalesces to the selection's newest state rather
# than dropping it.
env DISPLAY="$DPY" "$CN" -s clipboard 9>&- &
CN_PID=$!
while wait "$CN_PID"; do
  env DISPLAY="$DPY" "$CN" -s clipboard 9>&- &
  CN_PID=$!
  handle_event
done
