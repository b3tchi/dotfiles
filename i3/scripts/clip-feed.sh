#!/bin/sh
# clip-feed.sh — one-way clipboard feeder: CLIPBOARD on the xrdp display (:10)
# into the clipcat history owned by the native session's daemon (:0).
# [sp014 task 2; backend swapped copyq -> clipcat by sp016 task 4]
#
# adr0004 gives this host two X servers at once: the native session on :0 and
# the xrdp session on :10.  Each owns its own X selections, so a copy made in
# the xrdp session is invisible to the native one.  The picker lives on :0 and
# reads the clipcat daemon serving that session; this daemon watches :10 and
# pushes what is copied there into that history, giving one shared history
# across both.
#
# Direction is deliberately one-way.  :0 -> :10 is not needed (the picker
# pastes onto the active display, clip-paste.sh) and a two-way feeder would
# ping-pong its own writes.  Native-desktop only: WSL and proot run a single
# display and must not autostart this.
#
# Design constraints (sp014 "Anti-patterns"; the clip-sync.sh mould):
#
#  * Never trust the inherited DISPLAY.  Every X call carries an explicit
#    DISPLAY= naming the display it means, so the daemon behaves identically
#    started from an i3 autostart, a tmux pane, or a login shell.
#  * Never guess the destination clipcat socket either.  One clipcatd binds
#    exactly one socket and this host runs two of them (clipcat/dot.yaml
#    point 1), so the DST daemon is named by an explicit --server-endpoint
#    path, never derived from a DISPLAY.
#  * Every xclip call is wrapped in `timeout`.  A selection owner can hang (a
#    dead RDP client, an image payload) and a bare `xclip -o` blocks forever —
#    one stuck read wedged the whole clip-sync.sh loop until it was killed.
#    Every clipcatctl call is wrapped for the same reason (adr0002): a wedged
#    daemon must not wedge the feeder.
#  * History is fed WITHOUT touching any selection the user can see: the
#    feeder must not steal the native CLIPBOARD out from under whoever is
#    working on :0.  Under copyq that was `copyq add` (never `copyq copy`).
#    Under clipcat it is `clipcatctl load -k secondary` — see BACKEND below,
#    because the obvious call is a trap.
#
# ---------------------------------------------------------------- BACKEND ---
# Two measured facts about clipcat 0.25.0 shaped the feed call.  Both were
# verified empirically against the shipped clipcat/clipcat.toml; neither is
# what sp016 / clipcat/dot.yaml assumed when they said "swap `copyq add -`
# for `clipcatctl insert`".
#
# 1. `clipcatctl insert <DATA>` takes the payload as a COMMAND-LINE ARGUMENT.
#    Linux caps a single argv string at MAX_ARG_STRLEN (128 KiB), so a 200 KB
#    clip fails at exec with "Argument list too long" — measured.  The feeder
#    has to carry whatever the user copied, and multi-MB clips are ordinary
#    (clipcat/test-clipcat.sh itself ships a 3 MB fixture).  `clipcatctl load
#    -f <file>` performs the same insert reading from a file instead: 3 MB
#    verified fine.  It also keeps clipboard content out of /proc/<pid>/cmdline
#    on a path that by construction handles secrets.
#
# 2. `insert`/`load` with the DEFAULT `-k clipboard` DOES NOT merely seed the
#    history — it makes the DST daemon TAKE OWNERSHIP OF THE DST X CLIPBOARD.
#    Measured: the X CLIPBOARD on the daemon's display changed to the inserted
#    text the moment the call returned.  That is exactly the "steal the native
#    clipboard" behaviour `copyq add` was chosen over `copyq copy` to avoid,
#    and it would mean every copy made in the xrdp session silently yanked the
#    native session's clipboard.  (poc010 Q3 still holds — the insert does not
#    re-trigger the WATCHER, so nothing is double-recorded.  It asserts the X
#    selection, which is a different thing, and was missed.)
#
#    `-k secondary` is the fix: the clip is recorded in history, `list` and
#    `get` return it byte-exact like any other entry, and CLIPBOARD and
#    PRIMARY are both left untouched — measured.  This works because
#    clipcat.toml sets `enable_secondary = false` (and `enable_primary =
#    false`) in [watcher], so the daemon records the clip but never asserts
#    ownership of that selection.  THAT SETTING IS LOAD-BEARING HERE: turning
#    `enable_secondary = true` on would give this call back the stealing
#    behaviour.  test-clip-feed.sh asserts the config setting and asserts the
#    DST clipboard is untouched after a feed, with a mutation control showing
#    `-k clipboard` really does steal it.
#
# SECURITY — password-manager copies.  clipcat's own secret filter
# (`sensitive_mime_types` in clipcat.toml) is a WATCHER-side rule: it only
# fires on clipboard changes the DST daemon observes for itself.  Items
# arriving through insert/load bypass the watcher entirely (poc010 Q3), so a
# KeePassXC copy made on :10 would launder straight past that filter into
# history if this daemon just forwarded text.  This is the same hole `copyq
# add` had past copyq's automatic commands — the backend swap changed nothing
# about it.  That is why the TARGETS list is inspected FIRST and a selection
# advertising application/x-kde-passwordManagerHint is skipped without its
# payload ever being read.  Do not move that check below the read, and do not
# remove it.  On this path the feeder's own two gates are the ONLY filter
# there is.
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
#  * The secret payload does reach "$NEW", a mktemp file under /tmp, before it
#    is dropped.  Mode 0600, overwritten next poll, removed on exit — but it
#    is on disk for one poll.  Stopping that would need an atomic
#    TARGETS+payload fetch, which X does not provide.
#  * The re-check narrows the window, it does not eliminate it.  A THIRD
#    owner taking the clipboard between the payload read and the re-check
#    would present hint-free targets and the secret would be fed.  That needs
#    two ownership flips inside ~10ms; the single-flip case this file is
#    actually exposed to is covered.
#  * Only KDE/KeePassXC-style hint publishers are recognised at all.  A
#    password manager that advertises no hint is indistinguishable from a
#    normal copy at either check.  (dotfiles-cyg / sp015 is the actual fix;
#    the clipcat swap bought no security improvement here.)
#
# test-clip-feed.sh asserts the drop, the raced drop, and — via patched copies
# of this file — that BOTH checks are load-bearing.
#
# usage: i3/scripts/clip-feed.sh          (daemon; exits 0 if already running)
# env:   CLIP_FEED_SRC=:10          display watched for copies
#        CLIP_FEED_DST_SOCKET=...   clipcatd gRPC socket receiving them;
#                                   defaults to $XDG_RUNTIME_DIR/clipcat/
#                                   grpc.sock (clipcatd's own default when it
#                                   is started without --grpc-socket-path)
#        CLIP_FEED_POLL=0.5  seconds between polls while SRC is up
#        CLIP_FEED_IDLE=5    seconds between polls while SRC is absent
#        CLIP_FEED_TIMEOUT=1 seconds before a single xclip/clipcatctl call is
#                            abandoned
#        CLIP_FEED_LOCK=...  single-instance lock file
set -u

SRC="${CLIP_FEED_SRC:-:10}"
POLL="${CLIP_FEED_POLL:-0.5}"
IDLE="${CLIP_FEED_IDLE:-5}"
T="${CLIP_FEED_TIMEOUT:-1}"
LOCK="${CLIP_FEED_LOCK:-/tmp/clip-feed.$(id -u).lock}"

# The DST daemon is named, never guessed.  Refusing to start beats silently
# feeding the wrong session's history (or none at all), and mirrors clipcatd's
# own loud refusal — exit 78, EX_CONFIG — when it cannot resolve
# $XDG_RUNTIME_DIR for its history path.
if [ -n "${CLIP_FEED_DST_SOCKET:-}" ]; then
  SOCK="$CLIP_FEED_DST_SOCKET"
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  SOCK="$XDG_RUNTIME_DIR/clipcat/grpc.sock"
else
  echo "clip-feed.sh: no destination socket: set CLIP_FEED_DST_SOCKET or XDG_RUNTIME_DIR" >&2
  exit 78
fi

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
#    the backend appends an empty history row — so the `-s` test is what keeps
#    blank rows out.  (clipcat's own `filter_text_min_length = 1` would also
#    catch this one, but that is the WATCHER's filter and this path bypasses
#    the watcher; the `-s` check is what actually holds here.)
read_src() {
  timeout "$T" env DISPLAY="$SRC" xclip -selection clipboard -o \
    > "$NEW" 2>/dev/null 9>&- && [ -s "$NEW" ]
}

# Append to the DST clipcat history without touching any DST selection.
#
# `load -f` rather than `insert <data>`: the payload would otherwise ride on
# argv and die at 128 KiB.  `-k secondary` rather than the default
# `-k clipboard`: the default makes the daemon assert ownership of the DST X
# CLIPBOARD, i.e. steals it from the native session.  Both measured — see
# BACKEND in the header before changing either flag.
feed_dst() {
  timeout "$T" clipcatctl --server-endpoint "$SOCK" load -k secondary \
    -f "$NEW" >/dev/null 2>&1 9>&-
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
  if grep -qFx 'application/x-kde-passwordManagerHint' "$TGT"; then
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
    if ! targets || grep -qFx 'application/x-kde-passwordManagerHint' "$TGT"; then
      nap "$POLL"; continue
    fi
    feed_dst && cp "$NEW" "$LAST"
  fi

  nap "$POLL"
done
