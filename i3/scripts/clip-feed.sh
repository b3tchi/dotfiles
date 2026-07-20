#!/bin/sh
# clip-feed.sh — one-way clipboard feeder: CLIPBOARD on the xrdp display (:10)
# into the copyq history on the native display (:0).  [sp014 task 2]
#
# adr0004 gives this host two X servers at once: the native session on :0 and
# the xrdp session on :10.  Each owns its own X selections, so a copy made in
# the xrdp session is invisible to the native one.  copyq runs a single server,
# on :0, where the picker lives; this daemon watches :10 and pushes what is
# copied there into that history, giving one shared history across both.
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
#  * Every xclip call is wrapped in `timeout`.  A selection owner can hang (a
#    dead RDP client, an image payload) and a bare `xclip -o` blocks forever —
#    one stuck read wedged the whole clip-sync.sh loop until it was killed.
#  * History is fed with `copyq add`, never `copyq copy`: the feeder must not
#    steal the native CLIPBOARD out from under whoever is working on :0.
#    (`copyq copy` would not reach the history anyway — copyq ignores
#    clipboard changes it owns itself.)
#  * copyq is invoked as a plain `copyq` with no environment juggling, per the
#    contract in copyq/dot.yaml.
#
# SECURITY — password-manager copies.  copyq's hint-drop rule
# (copyq/commands.ini) is an *automatic command*: it only fires on clipboard
# changes the :0 server observes.  Items inserted with `copyq add` bypass
# automatic commands entirely, so a KeePassXC copy made on :10 would launder
# straight past that rule into history if this daemon just forwarded text.
# That is why the TARGETS list is inspected FIRST and a selection advertising
# application/x-kde-passwordManagerHint is skipped without its payload ever
# being read.  Do not move that check below the read, and do not remove it.
# test-clip-feed.sh asserts both the drop and, via a patched copy of this
# file, that the check is load-bearing.
#
# usage: i3/scripts/clip-feed.sh          (daemon; exits 0 if already running)
# env:   CLIP_FEED_SRC=:10   display watched for copies
#        CLIP_FEED_DST=:0    display whose copyq server receives them
#        CLIP_FEED_POLL=0.5  seconds between polls while SRC is up
#        CLIP_FEED_IDLE=5    seconds between polls while SRC is absent
#        CLIP_FEED_TIMEOUT=1 seconds before a single xclip call is abandoned
#        CLIP_FEED_LOCK=...  single-instance lock file
set -u

SRC="${CLIP_FEED_SRC:-:10}"
DST="${CLIP_FEED_DST:-:0}"
POLL="${CLIP_FEED_POLL:-0.5}"
IDLE="${CLIP_FEED_IDLE:-5}"
T="${CLIP_FEED_TIMEOUT:-1}"
LOCK="${CLIP_FEED_LOCK:-/tmp/clip-feed.$(id -u).lock}"

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

# The MIME targets the current SRC owner advertises.  Cheap, and it is the
# only thing read for a selection that turns out to be a secret or an image.
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
read_src() {
  timeout "$T" env DISPLAY="$SRC" xclip -selection clipboard -o \
    > "$NEW" 2>/dev/null 9>&- && [ -s "$NEW" ]
}

# Append to the DST copyq history without touching the DST clipboard.
feed_dst() {
  timeout "$T" env DISPLAY="$DST" copyq add - < "$NEW" >/dev/null 2>&1 9>&-
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

  # Text only.  An image or other binary selection has no text target; copying
  # it would put a blob (or xclip's error output) into the text history.
  if ! grep -qEx 'UTF8_STRING|STRING|TEXT|text/plain(;charset=.*)?' "$TGT"; then
    nap "$POLL"; continue
  fi

  # Dedup against the last item we fed: xclip reports the same content on
  # every tick, and without this the history would gain a copy twice a second.
  if read_src && ! cmp -s "$NEW" "$LAST"; then
    feed_dst && cp "$NEW" "$LAST"
  fi

  nap "$POLL"
done
