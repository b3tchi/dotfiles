#!/bin/sh
# clip-feed.sh — one-way clipboard feeder: CLIPBOARD on the xrdp display (:10)
# into the file-store the native session's own clip-store.sh loop writes.
# [sp014 task 2; backend swapped copyq -> clipcat by sp016 task 4; clipcat ->
#  bespoke file store by sp016 task 7]
#
# adr0004 gives this host two X servers at once: the native session on :0 and
# the xrdp session on :10.  Each owns its own X selections, so a copy made in
# the xrdp session is invisible to the native one.  The picker lives on :0 and
# reads the store clip-store.sh's :0 loop maintains; this feeder watches :10
# and writes what is copied there into that SAME store directory, giving one
# shared history across both displays.
#
# Direction is deliberately one-way.  :0 -> :10 is not needed (the picker
# pastes onto the active display, clip-paste.sh) and a two-way feeder would
# ping-pong its own writes.  Native-desktop only: WSL and proot run a single
# display and must not autostart this.
#
# Design constraints (sp014 "Anti-patterns"; the clip-sync.sh mould):
#
#  * Never trust the inherited DISPLAY.  Every X call carries an explicit
#    DISPLAY= naming the display it means, so the feeder behaves identically
#    started from an i3 autostart, a tmux pane, or a login shell.
#  * Never guess the destination store directory either.  It is named by an
#    explicit CLIP_FEED_DST display, never derived from CLIP_FEED_SRC or an
#    inherited DISPLAY — this host runs two X servers and the wrong guess
#    would feed nowhere anyone reads, or (worse) the xrdp session's own store.
#  * Every xclip call is wrapped in `timeout`.  A selection owner can hang (a
#    dead RDP client, an image payload) and a bare `xclip -o` blocks forever —
#    one stuck read wedged the whole clip-sync.sh loop until it was killed.
#  * History is fed WITHOUT touching any selection the user can see: the
#    feeder must not steal the native CLIPBOARD out from under whoever is
#    working on :0.  Under copyq that was `copyq add` (never `copyq copy`);
#    under clipcat it took a non-obvious flag (`-k secondary`) to avoid a trap
#    — see WRITE below.  Writing a store file structurally cannot own a
#    selection at all, so this property no longer depends on picking the
#    right flag; there is no flag to pick.
#
# ------------------------------------------------------------------ WRITE ---
# The destination is `$XDG_RUNTIME_DIR/clip-store/<CLIP_FEED_DST>/` — the
# EXACT directory clip-store.sh's own loop for that display writes into (see
# that file for the store contract in full).  This feeder is a second writer
# into the same directory, so the write path matches clip-store.sh's shape
# deliberately, not by convention:
#
#  * Atomic publish is `ln`, not `mv`: the payload goes to a `.tmp` file
#    INSIDE the destination store dir and is link(2)ed into its final
#    NNNNNN.clip name.  `ln` FAILS on an existing name rather than clobbering
#    it, so a seq raced by clip-store.sh's own loop on that display (a local
#    capture landing at the same instant) costs this feeder a retry, not a
#    corrupted or lost entry — see concurrent-capture-seq-no-clobber in the
#    test suite.  The `.tmp` name (`.feed.wip.tmp`) is deliberately distinct
#    from clip-store.sh's own `.wip.tmp` so the two writers never touch the
#    same work file.
#  * Dedup on the write is against the store's OWN current newest entry —
#    the same comparison clip-store.sh's loop makes — not a private cache, so
#    a fed copy identical to whatever the native session's OWN loop most
#    recently captured is not double-stored either.
#  * The destination dir is created (and re-created if removed mid-session)
#    on every feed attempt, exactly as clip-store.sh's handle_event does —
#    "destination store absent" is not a special case, just an empty
#    directory that mkdir -p fixes.
#  * CLIP_FEED_DST_CAP prunes the destination the same way clip-store.sh's
#    own CLIP_STORE_CAP does, so a feeder running alone (the native loop
#    idle) cannot grow that store unbounded either.
#
# No selection is ever asserted on CLIP_FEED_DST: nothing in this file runs
# an X call against it, targeted or otherwise.  The old backend's
# no-clipboard-stealing property (Task 4's `-k secondary` finding) is
# therefore structural now, not a flag choice — see dst-selection-untouched
# in the test suite, which still asserts it behaviourally.
#
# REMOVED: CLIP_FEED_DST_SOCKET, the clipcatd gRPC socket from the pre-pivot
# backend (sp016 task 4).  There is no daemon and no socket any more.  Setting
# this variable is refused loudly (exit 78), not silently ignored — see the
# migration check below, before the single-instance lock is even taken.
#
# SECURITY — password-manager copies.  Whatever secret filter the
# destination's OWN capture path applies (clip-store.sh's TARGETS gate, or
# clipcat's `sensitive_mime_types` before it) is a WATCHER-side rule: it only
# fires on clipboard changes that path observes for itself.  A file this
# feeder writes directly bypasses that watcher entirely, so a KeePassXC copy
# made on :10 would launder straight past the destination's own filter into
# the shared store if this feeder just forwarded text.  This is the same hole
# every backend swap on this path has had past its own automatic filters —
# the backend changed, the exposure didn't.  That is why the TARGETS list is
# inspected FIRST and a selection advertising a password-manager hint is
# skipped without its payload ever being read.  Do not move that check below
# the read, and do not remove it.  On this path the feeder's own two gates
# are the ONLY filter there is.  BOTH hint spellings are matched -- bare
# `x-kde-passwordManagerHint` and prefixed
# `application/x-kde-passwordManagerHint`, the same two clip-store.sh's own
# hinted() gates -- so a password manager emitting only the bare atom is
# dropped here too, not just at the native store's own capture path
# (dotfiles-wtr).
#
# The gate is checked TWICE, and the second check is not redundant.  TARGETS
# and the payload are separate X protocol requests — measured 10-13ms apart —
# and X offers no way to fetch them atomically.  Against a ~520ms poll that is
# a ~2% window per copy in which a password manager can take the clipboard
# AFTER the gate passed on the previous owner, so the payload read returns the
# secret.  Re-checking TARGETS after the read and before the feed closes that:
# the password manager still owns the selection at re-check time and still
# advertises the hint, so the item is dropped.  (dotfiles-l6s.)
#
# RESIDUAL EXPOSURE, stated plainly rather than papered over:
#  * The secret payload does reach "$NEW", a scratch file under
#    $XDG_RUNTIME_DIR/clip-feed/ (tmpfs, mode 0600), before it is dropped —
#    one poll's lifetime, overwritten next tick, removed on exit.  This used
#    to be a mktemp file under /tmp; requiring XDG_RUNTIME_DIR unconditionally
#    (this task) closed that — nothing this file creates lives outside
#    $XDG_RUNTIME_DIR any more.  Stopping the exposure entirely would need an
#    atomic TARGETS+payload fetch, which X does not provide.
#  * The re-check narrows the window, it does not eliminate it.  A THIRD
#    owner taking the clipboard between the payload read and the re-check
#    would present hint-free targets and the secret would be fed.  That needs
#    two ownership flips inside ~10ms; the single-flip case this file is
#    actually exposed to is covered.
#  * Only KDE/KeePassXC-style hint publishers are recognised at all.  A
#    password manager that advertises no hint is indistinguishable from a
#    normal copy at either check.  (dotfiles-cyg / sp015 is the actual fix;
#    no backend swap on this path has bought any security improvement here.)
#
# test-clip-feed.sh asserts the drop, the raced drop, and — via patched copies
# of this file — that BOTH checks are load-bearing, for BOTH hint spellings.
#
# usage: i3/scripts/clip-feed.sh          (daemon; exits 0 if already running)
# env:   CLIP_FEED_SRC=:10          display watched for copies
#        CLIP_FEED_DST=:0           display naming the destination store dir
#                                   ($XDG_RUNTIME_DIR/clip-store/<CLIP_FEED_DST>/),
#                                   the same directory clip-store.sh's own
#                                   loop for that display writes into
#        CLIP_FEED_DST_CAP=100      destination entries kept (oldest pruned)
#        CLIP_FEED_POLL=0.5  seconds between polls while SRC is up
#        CLIP_FEED_IDLE=5    seconds between polls while SRC is absent
#        CLIP_FEED_TIMEOUT=1 seconds before a single xclip call is
#                            abandoned
#        CLIP_FEED_LOCK=...  single-instance lock file
set -u

SRC="${CLIP_FEED_SRC:-:10}"
DST="${CLIP_FEED_DST:-:0}"
# X DISPLAY may carry a screen suffix (`:0.0`); clip-store.sh keys the store
# dir on the bare display, so strip the screen here too or a raw display
# passed as the destination would feed a store nothing else reads. In sh
# globs `.` is literal: `:0.0` -> `:0`, bare `:0` unchanged.
DST="${DST%.*}"
CAP="${CLIP_FEED_DST_CAP:-100}"
POLL="${CLIP_FEED_POLL:-0.5}"
IDLE="${CLIP_FEED_IDLE:-5}"
T="${CLIP_FEED_TIMEOUT:-1}"
LOCK="${CLIP_FEED_LOCK:-/tmp/clip-feed.$(id -u).lock}"

# Daemon-era plumbing, refused loudly rather than silently ignored (sp016
# task 7 edge case).  A feeder that quietly dropped this would look like it
# started fine while feeding nothing anyone can find.
if [ -n "${CLIP_FEED_DST_SOCKET:-}" ]; then
  echo "clip-feed.sh: CLIP_FEED_DST_SOCKET is set but no longer used -- the destination is a file store now, not a clipcatd socket (sp016 task 7). Unset it and set CLIP_FEED_DST=<display> instead (default :0); see i3/scripts/clip-store.sh for the store contract." >&2
  exit 78
fi

# The destination is named, never guessed -- mirrors clipcatd's own loud
# refusal (and clip-store.sh's) when $XDG_RUNTIME_DIR cannot be resolved:
# exit 78, EX_CONFIG.  No persistent-path fallback exists to fall back to.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  echo "clip-feed.sh: XDG_RUNTIME_DIR is unset; refusing to fall back to a persistent path" >&2
  exit 78
fi

ROOT="$XDG_RUNTIME_DIR/clip-store"
STORE="$ROOT/$DST"

# Single-instance guard.  i3 autostarts re-run on config reload, and a second
# feeder would double every captured item.  flock releases the lock when the
# process dies, so a crashed feeder leaves nothing stale behind (a pidfile
# would).  Losing the race is the normal case, not an error: exit quietly.
exec 9>"$LOCK" || exit 1
flock -n 9 || exit 0

# Every child below closes fd 9 (`9>&-`).  The lock lives on the open file
# description, not the process, so a forked `sleep` or `xclip` that inherits
# the fd keeps holding the lock after this shell is killed — a feeder
# restarted within one poll of the old one being killed (i3 config reload)
# would then see the lock held, decide it was the duplicate, and exit,
# leaving no feeder running at all.  Observed; do not drop the `9>&-`.

# Scratch files live under $XDG_RUNTIME_DIR too now (0700, tmpfs) rather than
# a bare /tmp mktemp -- see RESIDUAL EXPOSURE above.  TMPDIR steers mktemp
# here without changing any of its call sites below.
SCRATCH="$XDG_RUNTIME_DIR/clip-feed"
umask 077
mkdir -p "$SCRATCH" || exit 1
chmod 700 "$SCRATCH"
TMPDIR="$SCRATCH"; export TMPDIR

NEW="$(mktemp)"; LAST="$(mktemp)"; TGT="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$NEW" "$LAST" "$TGT" "$ERR"' EXIT
: > "$LAST"          # last content successfully fed, for dedup

# Is the source X server there at all?  Checked before every poll so that a
# torn-down :10 costs one stat(2) and a long sleep rather than a process spawn
# every tick — this is what keeps the daemon at ~0% CPU while xrdp is down,
# and what lets it pick straight back up when the session returns.
src_up() { [ -e "/tmp/.X11-unix/X${SRC#:}" ]; }

# The MIME targets the current SRC owner advertises.  Cheap, and for a
# selection that turns out to be a secret it is the ONLY thing ever read.
targets() {
  timeout "$T" env DISPLAY="$SRC" xclip -selection clipboard -t TARGETS -o \
    > "$TGT" 2> "$ERR" 9>&-
}

# Does the advertised TARGETS list carry a password-manager hint, in either
# spelling?  Same gate shape as clip-store.sh's hinted() -- bare
# `x-kde-passwordManagerHint` and prefixed
# `application/x-kde-passwordManagerHint` are both matched (clipcat defaulted
# to bare, the shipped copyq rule used prefixed; neither is verified against
# a real emitter -- dotfiles-cyg / sp015 remain the actual fix).  Matching
# only the prefixed form here would let a bare-only emitter launder straight
# through this feeder even though clip-store.sh's own loop on :0 already
# drops it (dotfiles-wtr).
hinted() {
  grep -qFx -e 'x-kde-passwordManagerHint' \
            -e 'application/x-kde-passwordManagerHint' "$TGT"
}

# Did the last xclip fail because the X server is gone, rather than because
# nobody currently owns the selection?  The two are worth telling apart: an
# unowned clipboard is the normal idle state and must keep polling fast enough
# to catch the next copy within a second, while a dead server should back off.
# Killing Xvfb with SIGKILL leaves the socket file behind, so src_up() alone
# does not catch every teardown.
src_gone() { grep -q "Can't open display" "$ERR"; }

# Read SRC CLIPBOARD as text; nonzero on timeout, error, or empty selection.
#
# Both failure modes matter and they are separate:
#  * A non-text selection (an image copy) has no text target to hand over, so
#    xclip itself exits nonzero and nothing is fed.  An explicit TARGETS
#    text-target filter was written here and then removed as dead code —
#    deleting it changed no test outcome, because this path already covers the
#    image-only owner, and a mixed owner (image plus a text/plain URL, as
#    browsers publish) advertises a text target and should feed the URL.
#  * An owner holding an EMPTY string succeeds, and an empty file handed to
#    the destination store would create a blank entry — so the `-s` test is
#    what keeps blank entries out (the store loop's own capture path applies
#    no minimum-length filter of its own either; the `-s` check here is what
#    actually holds).
read_src() {
  timeout "$T" env DISPLAY="$SRC" xclip -selection clipboard -o \
    > "$NEW" 2>/dev/null 9>&- && [ -s "$NEW" ]
}

# Path of the newest entry in the destination store (highest seq); empty when
# the store is empty or absent.  Same construction as clip-store.sh's own
# newest_entry(): pathname expansion is sorted, so the last match is newest.
dst_newest() {
  ne=""
  for f in "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
    [ -e "$f" ] && ne="$f"
  done
  printf '%s' "$ne"
}

# Enforce the cap on the destination store: delete oldest entries until at
# most CLIP_FEED_DST_CAP remain.  Same shape as clip-store.sh's prune(), so a
# feeder running with the native loop idle cannot grow that store unbounded.
prune_dst() {
  while :; do
    count=0; oldest=""
    for f in "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
      [ -e "$f" ] || continue
      count=$((count + 1))
      [ -n "$oldest" ] || oldest="$f"
    done
    [ "$count" -le "$CAP" ] && break
    rm -f "$oldest"
  done
}

# Write "$NEW" into the destination store as the next seq entry -- the SAME
# atomic write clip-store.sh's loop performs (see WRITE in the header):
# `.tmp` inside the store dir, `ln`ed into its final name, retried on a
# collision.  Dedup is against the store's own current newest entry, not a
# private cache -- so a fed copy identical to whatever the native session's
# OWN loop most recently captured is skipped too, the same as clip-store.sh
# would skip it for itself.  Never asserts any DST X selection: this is a
# file write, nothing here opens a DISPLAY= call against $DST.
feed_dst() {
  mkdir -p "$STORE" 2>/dev/null || return 1
  chmod 700 "$ROOT" "$STORE" 2>/dev/null

  last="$(dst_newest)"
  if [ -n "$last" ] && cmp -s "$NEW" "$last"; then
    return 0
  fi

  wip="$STORE/.feed.wip.tmp"
  cp "$NEW" "$wip" 2>/dev/null || return 1

  if [ -n "$last" ]; then
    b="${last##*/}"; b="${b%.clip}"
    n="${b#"${b%%[!0]*}"}"; [ -n "$n" ] || n=0
    n=$((n + 1))
  else
    n=1
  fi
  tries=0
  while [ "$tries" -lt 100 ]; do
    if ln "$wip" "$STORE/$(printf '%06d' "$n").clip" 2>/dev/null; then
      rm -f "$wip"
      return 0
    fi
    n=$((n + 1)); tries=$((tries + 1))
  done
  rm -f "$wip"
  return 1
}

# `sleep` is an external command too, so it also has to drop the lock fd.
nap() { sleep "$1" 9>&-; }

while :; do
  if ! src_up; then nap "$IDLE"; continue; fi

  # No owner / hung owner / server vanished mid-poll: nothing to do this tick.
  if ! targets; then
    if src_gone; then nap "$IDLE"; else nap "$POLL"; fi
    continue
  fi

  # SECURITY GATE — must stay above read_src.  A password-manager copy is
  # skipped without its payload ever being fetched.
  if hinted; then
    nap "$POLL"; continue
  fi

  # Dedup against the last item we fed: xclip reports the same content on
  # every tick, and without this the history would gain a copy twice a second.
  if read_src && ! cmp -s "$NEW" "$LAST"; then
    # TOCTOU RE-CHECK — the second half of the security gate; see the header.
    # The gate above passed on whoever owned the selection THEN; the payload
    # in "$NEW" came from whoever owned it a few milliseconds LATER.  Ask who
    # owns it now, and refuse to publish a payload that a password manager is
    # currently claiming.  Fails CLOSED: a re-check that times out or finds no
    # owner drops the item too.  "$LAST" is deliberately not updated, so a
    # legitimate copy dropped by a hung owner is simply re-fed next poll.
    if ! targets || hinted; then
      nap "$POLL"; continue
    fi
    if feed_dst; then
      cp "$NEW" "$LAST"
      prune_dst
    fi
  fi

  nap "$POLL"
done
