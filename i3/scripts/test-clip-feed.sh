#!/usr/bin/env bash
# test-clip-feed.sh — verify the cross-display clipboard feeder
# (i3/scripts/clip-feed.sh): sp014 dotfiles-92w.2, ported to the clipcat
# backend by sp016 dotfiles-egm.4, ported again to the bespoke file-store
# backend by sp016 dotfiles-egm.7.
#
# Runs entirely headless on two throwaway Xvfb displays — a stand-in for the
# xrdp session (SRC) and one for the native session (DST) — with an isolated
# XDG_RUNTIME_DIR, so it never touches the live X sessions, the live
# clipboard, or the live session's store under the real
# $XDG_RUNTIME_DIR/clip-store.
#
# The feeder is deliberately launched with a bogus DISPLAY exported AND with
# XDG_RUNTIME_DIR pointed at the isolated tree, so the suite fails if it ever
# starts trusting the inherited DISPLAY instead of CLIP_FEED_SRC/CLIP_FEED_DST.
#
# Selections are owned by a python-xlib helper rather than a plain xclip call:
# the helper can publish several MIME targets on one change (xclip cannot —
# one target per invocation), which the password-manager-hint cases need, and
# it logs every SelectionRequest target it receives to a reqlog file, turning
# "the payload was never requested" from an assumption into a measurement
# (carried from test-clip-store.sh's clip-owner.py).
#
# ------------------------------------------------------------------------
# WHY THIS SUITE NO LONGER NEEDS A DAEMON AT ALL
# ------------------------------------------------------------------------
# Under the clipcat backend (task 4) this suite ran a real clipcatd and read
# the feeder's effect through clipcatctl, and had to fight dotfiles-apl (a
# fraction of daemon starts go permanently deaf) with a bounded restart retry
# and a diagnostic-only watcher probe.  The file-store backend has no daemon
# on the destination: the feeder writes `$XDG_RUNTIME_DIR/clip-store/<DST>/`
# directly, the exact directory clip-store.sh's own loop for that display
# writes into.  So this suite reads that directory with plain shell globs
# (store_count / entry_for_content / etc., carried from test-clip-store.sh),
# and the destination Xvfb display (DST) exists ONLY so the
# dst-selection-untouched scenario has a real X CLIPBOARD to assert nothing
# touched — no daemon, no gRPC socket, no watcher-liveness probe needed here
# any more.
#
# The concurrent-capture-seq-no-clobber scenario goes one step further and
# runs a REAL clip-store.sh loop against the DST display at the same time as
# the feeder, both writing into the same store directory — the actual
# integration point sp016 task 7 exists to prove safe (ln fails on a seq
# collision instead of clobbering; see clip-store.sh's WRITE section).
#
# usage: i3/scripts/test-clip-feed.sh
# env:   XVFB=/path/to/Xvfb  CLIPNOTIFY=/path/to/clipnotify  (default: PATH)
#        SRC_DISPLAY=:98  DST_DISPLAY=:97
#        KEEP_TMP=1   (debug: skip deleting $TMP on exit)
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FEEDER="$REPO_DIR/clip-feed.sh"
STORESH="$REPO_DIR/clip-store.sh"
XVFB="${XVFB:-Xvfb}"
SRC="${SRC_DISPLAY:-:98}"
DST="${DST_DISPLAY:-:97}"

# AF_UNIX socket paths are capped near 108 bytes (SUN_LEN); kept short as a
# carried convention even though this suite no longer opens any socket
# itself — clip-store.sh's own lock/store paths inherit whatever $TMP is.
TMP="/tmp/clip-feed-test.$$"
RUN="$TMP/run"    # XDG_RUNTIME_DIR stand-in (tmpfs 0700 in production)
SDIR="$RUN/clip-store/$DST"   # the destination store dir the feeder writes

PASS=0
FAIL=0

# ---------------------------------------------------------------- harness ---

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

assert_eq() { # <scenario> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

scenario() { printf '\n[%s]\n' "$1"; }

cleanup() {
  stop_feeder
  stop_loop
  [ -n "${OWNER_PID:-}" ] && kill "$OWNER_PID" 2>/dev/null
  [ -n "${SRC_PID:-}" ] && kill "$SRC_PID" 2>/dev/null
  [ -n "${DST_PID:-}" ] && kill "$DST_PID" 2>/dev/null
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

# Read a selection on a given display.
xsel_of() { # <display> <selection>
  env DISPLAY="$1" timeout 5 xclip -selection "$2" -o 2>/dev/null
}

# Start an Xvfb on <display> and wait until it actually accepts connections.
# The socket file alone is not proof: a SIGKILLed Xvfb leaves its socket
# behind, so a restart would otherwise be declared up before it is.
start_xvfb() { # <display> <varname-for-pid>
  local i
  # Wait for the display number to be FREE before claiming it.  Xvfb refuses
  # to start on a display whose /tmp/.X<n>-lock still exists, and a previous
  # run of this same suite takes a moment to drop it — running the suite twice
  # back-to-back aborted here otherwise (observed: 1 of 3 consecutive runs).
  for i in $(seq 1 20); do
    [ -e "/tmp/.X${1#:}-lock" ] || break
    sleep 0.5
  done
  "$XVFB" "$1" -screen 0 800x600x24 >"$TMP/xvfb${1#:}.log" 2>&1 &
  local pid=$!
  for i in $(seq 1 40); do
    if ! timeout 2 env DISPLAY="$1" xclip -selection clipboard -t TARGETS -o \
         2>&1 >/dev/null | grep -q "Can't open display"; then
      eval "$2=$pid"
      return 0
    fi
    sleep 0.5
  done
  echo "FATAL: Xvfb $1 did not start. Its own output follows; the usual cause" >&2
  echo "is a stale /tmp/.X${1#:}-lock from an earlier run that had not gone away yet." >&2
  cat "$TMP/xvfb${1#:}.log" >&2
  exit 1
}

# Start a feeder ($1 = script to run, default the real one).
#
# DISPLAY is set to a display that does not exist: a feeder that trusts it
# captures nothing.  XDG_RUNTIME_DIR points at the isolated tree -- it is
# mandatory now (the destination is a directory under it), not a fallback --
# and CLIP_FEED_DST names the destination display explicitly, exactly as
# task 5's autostart will.
start_feeder() {
  env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" \
      CLIP_FEED_SRC="$SRC" CLIP_FEED_DST="$DST" \
      CLIP_FEED_LOCK="$TMP/feed.lock" \
      CLIP_FEED_POLL=0.5 CLIP_FEED_IDLE=5 CLIP_FEED_TIMEOUT=5 \
      sh "${1:-$FEEDER}" >>"$TMP/feeder.log" 2>&1 &
  FEED_PID=$!
  sleep 1
}

stop_feeder() {
  [ -n "${FEED_PID:-}" ] || return 0
  kill "$FEED_PID" 2>/dev/null
  wait "$FEED_PID" 2>/dev/null
  FEED_PID=""
}

# A REAL clip-store.sh loop against the DST display, writing into the same
# store directory the feeder targets -- used only by
# concurrent-capture-seq-no-clobber, the scenario that proves the two
# writers share the directory safely.  Killed by pid lineage, never by name
# (dotfiles-92w.5).
start_loop() {
  env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" CLIPNOTIFY="$CN" \
      CLIP_STORE_DISPLAY="$DST" \
      sh "$STORESH" >>"$TMP/loop.log" 2>&1 &
  LOOP_PID=$!
  sleep 1
}

stop_loop() {
  [ -n "${LOOP_PID:-}" ] || return 0
  local kids k
  kids="$(pgrep -P "$LOOP_PID" 2>/dev/null)"
  kill "$LOOP_PID" 2>/dev/null
  wait "$LOOP_PID" 2>/dev/null
  for k in $kids; do kill "$k" 2>/dev/null; done
  LOOP_PID=""
}

# Own SRC CLIPBOARD with <text>, advertising any further arguments as extra
# MIME targets (each serving the value "secret").  Returns once held.  Every
# SelectionRequest target received is logged to reqlog.<owner-pid>.
own_clipboard() { # <text> [extra-mime ...]
  [ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; }
  env DISPLAY="$SRC" python3 "$TMP/clip-owner.py" "$@" >"$TMP/owner.out" 2>&1 &
  OWNER_PID=$!
  local i
  for i in $(seq 1 20); do
    grep -q owned "$TMP/owner.out" 2>/dev/null && return 0
    sleep 0.25
  done
  echo "FATAL: could not own clipboard on $SRC; $(cat "$TMP/owner.out")" >&2
  exit 1
}

# Own SRC CLIPBOARD with the contents of <file>.  Same helper, for fixtures
# too large to pass as an argument comfortably.
own_clipboard_file() { # <file> [extra-mime ...]
  [ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; }
  env DISPLAY="$SRC" python3 "$TMP/clip-owner.py" --file "$@" >"$TMP/owner.out" 2>&1 &
  OWNER_PID=$!
  local i
  for i in $(seq 1 20); do
    grep -q owned "$TMP/owner.out" 2>/dev/null && return 0
    sleep 0.25
  done
  echo "FATAL: could not own clipboard on $SRC; $(cat "$TMP/owner.out")" >&2
  exit 1
}

# Own SRC CLIPBOARD with <benign-text>, handing the selection to a
# hint-bearing owner serving <secret-text> the moment the feeder's TARGETS
# gate has been answered.  See race-owner.py.  Returns once win1 holds it.
# Optional 3rd arg names the hint atom the handoff owner advertises (default:
# prefixed; pass 'x-kde-passwordManagerHint' for the bare-atom race).
own_race_clipboard() { # <benign-text> <secret-text> [hint-atom]
  [ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; }
  env DISPLAY="$SRC" python3 "$TMP/race-owner.py" "$@" >"$TMP/owner.out" 2>&1 &
  OWNER_PID=$!
  local i
  for i in $(seq 1 20); do
    grep -q '^owned$' "$TMP/owner.out" 2>/dev/null && return 0
    sleep 0.25
  done
  echo "FATAL: could not own clipboard on $SRC; $(cat "$TMP/owner.out")" >&2
  exit 1
}

# Did the mid-poll ownership handoff actually happen?  A race scenario whose
# handoff never fired is just an ordinary benign copy, and asserting "no
# secret in the store" against it would be a green that proves nothing.
race_fired() { grep -q '^handed$' "$TMP/owner.out" 2>/dev/null && echo fired || echo not-fired; }

reqlog_of_owner() { cat "$TMP/reqlog.$OWNER_PID" 2>/dev/null; }

# ---- destination store readers ---------------------------------------------
# These read the store exactly as consumers must: only ??????.clip names,
# lexicographic order == capture order, ids opaque.  Carried from
# test-clip-store.sh, pointed at SDIR (the destination the feeder writes).

store_count() {
  local n=0 f
  for f in "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
    [ -e "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

newest_path() {
  local last="" f
  for f in "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
    [ -e "$f" ] && last="$f"
  done
  echo "$last"
}

entries_asc() { # entry paths, oldest first
  local f
  for f in "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
    [ -e "$f" ] && echo "$f"
  done
}

# Does <text> appear anywhere in any entry?  The leak check.
content_present() { # <text>
  grep -qF -- "$1" "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].clip 2>/dev/null \
    && echo present || echo absent
}

# Path of the entry whose full content is exactly <text>; empty if none.
entry_for_content() { # <exact text>
  local want="$1" f
  for f in "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
    [ -e "$f" ] || continue
    if [ "$(cat "$f")" = "$want" ]; then echo "$f"; return; fi
  done
}

# How many entries have exactly this text as their full content.  Used for
# "landed exactly once".
count_content() { # <exact text>
  local want="$1" n=0 f
  for f in "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
    [ -e "$f" ] || continue
    [ "$(cat "$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

# Wait until the store count differs from <baseline>, or timeout; echoes the
# count either way (mirrors the old wait_length_change against clipcatctl).
wait_store_change() { # <baseline> [seconds]
  local base="$1" limit="${2:-10}" i n
  for i in $(seq 1 $((limit * 10))); do
    n="$(store_count)"
    [ "$n" != "$base" ] && { echo "$n"; return 0; }
    sleep 0.1
  done
  store_count
}

# Total CPU jiffies charged to <pid> and its reaped children.
cpu_jiffies() { # <pid>
  awk '{print $14 + $15 + $16 + $17}' "/proc/$1/stat" 2>/dev/null || echo ""
}

# --------------------------------------------------------------- fixtures ---

mkdir -p "$TMP" "$RUN" "$TMP/fix"
chmod 700 "$RUN"

cat > "$TMP/clip-owner.py" <<'PYEOF'
"""Own the X CLIPBOARD advertising several targets at once.

Simulates a password manager (KeePassXC) publishing the text payload and the
password-manager-hint marker on one clipboard change -- which xclip cannot do
(one target per invocation).  Every SelectionRequest target received is
appended to <this-script's-directory>/reqlog.<own-pid>, so a caller can
assert exactly what was requested, not just what was (or was not) captured.

"image/png" as the sole extra means: serve ONLY this MIME, no text targets
at all (an image-style selection).

usage: clip-owner.py <text> [extra-mime ...]
       clip-owner.py --file <path> [extra-mime ...]
"""
import os
import sys
import Xlib.display
import Xlib.protocol.event
import Xlib.X
import Xlib.Xatom

argv = sys.argv[1:]
if argv[:1] == ["--file"]:
    with open(argv[1], "rb") as fh:
        text = fh.read()
    extra = argv[2:]
else:
    text = argv[0].encode()
    extra = argv[1:]

d = Xlib.display.Display()
screen = d.screen()
win = screen.root.create_window(0, 0, 1, 1, 0, screen.root_depth)

SEL = d.get_atom("CLIPBOARD")
TARGETS = d.get_atom("TARGETS")

served = {
    d.get_atom("UTF8_STRING"): text,
    d.get_atom("text/plain"): text,
    Xlib.Xatom.STRING: text,
}
if extra[:1] == ["image/png"]:
    served = {d.get_atom("image/png"): text}
    extra = []
for mime in extra:
    served[d.get_atom(mime)] = b"secret"

reqlog_path = os.path.join(os.path.dirname(sys.argv[0]), "reqlog." + str(os.getpid()))
reqlog = open(reqlog_path, "w")

win.set_selection_owner(SEL, Xlib.X.CurrentTime)
d.sync()
if d.get_selection_owner(SEL) != win:
    print("FAILED to own CLIPBOARD", file=sys.stderr)
    sys.exit(1)
print("owned", flush=True)

while True:
    e = d.next_event()
    if e.type != Xlib.X.SelectionRequest:
        continue
    print("REQ " + d.get_atom_name(e.target), file=reqlog, flush=True)
    prop = e.property if e.property != Xlib.X.NONE else e.target
    ok = True
    if e.target == TARGETS:
        e.requestor.change_property(
            prop, Xlib.Xatom.ATOM, 32, [TARGETS] + list(served))
    elif e.target in served:
        e.requestor.change_property(prop, e.target, 8, served[e.target])
    else:
        ok = False
    d.send_event(e.requestor, Xlib.protocol.event.SelectionNotify(
        time=e.time, requestor=e.requestor, selection=e.selection,
        target=e.target, property=prop if ok else Xlib.X.NONE))
    d.flush()
PYEOF

cat > "$TMP/race-owner.py" <<'PYEOF'
"""Own CLIPBOARD benignly, then hand it to a hint-bearing owner the instant
the first TARGETS request has been answered.

This reproduces the clip-feed.sh TOCTOU window: the feeder reads TARGETS and
the payload as two separate X requests (measured ~10-13ms apart), and X
offers no way to fetch them atomically.  A password-manager copy landing in
that gap is gated on the OLD owner and read from the NEW one.

Two windows on one connection:
  win1  benign text, TARGETS WITHOUT the password-manager hint -- what the
        feeder's gate inspects, and correctly judges safe.
  win2  the secret, TARGETS WITH the hint -- the password manager that took
        the clipboard microseconds after the gate passed.

The handoff fires from inside the handler for win1's TARGETS reply, after
the SelectionNotify is flushed, so the feeder's NEXT X request -- the payload
read -- is answered by win2.  That is precisely the race, made deterministic:
gate passed on win1, payload came from win2.

Prints "owned" once win1 holds the selection and "handed" once win2 does.
A scenario that never prints "handed" did not exercise the race and its
result means nothing; the suite asserts on it.

This fixture is BACKEND-INDEPENDENT.  It tests the feeder's own gating
against the X protocol, not anything about copyq, clipcat, or the file
store, and has now survived two backend swaps unchanged for exactly that
reason.

The hint atom served by win2 defaults to the prefixed spelling but takes an
optional 3rd argument so the SAME race can be replayed with the bare atom
(dotfiles-wtr) -- the feeder's gate must match both, mirroring
clip-store.sh's hinted().

usage: race-owner.py <benign-text> <secret-text> [hint-atom]
"""
import sys
import Xlib.display
import Xlib.protocol.event
import Xlib.X
import Xlib.Xatom

benign = sys.argv[1].encode()
secret = sys.argv[2].encode()
hint_atom_name = sys.argv[3] if len(sys.argv) > 3 else "application/x-kde-passwordManagerHint"

d = Xlib.display.Display()
screen = d.screen()
win1 = screen.root.create_window(0, 0, 1, 1, 0, screen.root_depth)
win2 = screen.root.create_window(0, 0, 1, 1, 0, screen.root_depth)

SEL = d.get_atom("CLIPBOARD")
TARGETS = d.get_atom("TARGETS")
HINT = d.get_atom(hint_atom_name)
UTF8 = d.get_atom("UTF8_STRING")
PLAIN = d.get_atom("text/plain")


def table(payload, hint):
    t = {UTF8: payload, PLAIN: payload, Xlib.Xatom.STRING: payload}
    if hint:
        t[HINT] = b"secret"
    return t


served = {win1.id: table(benign, False), win2.id: table(secret, True)}

win1.set_selection_owner(SEL, Xlib.X.CurrentTime)
d.sync()
if d.get_selection_owner(SEL) != win1:
    print("FAILED to own CLIPBOARD", file=sys.stderr)
    sys.exit(1)
print("owned", flush=True)

handed = False
while True:
    e = d.next_event()
    if e.type != Xlib.X.SelectionRequest:
        continue
    tbl = served.get(e.owner.id, {})
    prop = e.property if e.property != Xlib.X.NONE else e.target
    ok = True
    if e.target == TARGETS:
        e.requestor.change_property(
            prop, Xlib.Xatom.ATOM, 32, [TARGETS] + list(tbl))
    elif e.target in tbl:
        e.requestor.change_property(prop, e.target, 8, tbl[e.target])
    else:
        ok = False
    d.send_event(e.requestor, Xlib.protocol.event.SelectionNotify(
        time=e.time, requestor=e.requestor, selection=e.selection,
        target=e.target, property=prop if ok else Xlib.X.NONE))
    d.flush()

    # THE RACE.  win1's TARGETS answer is on the wire and the feeder has
    # passed its gate.  Take the clipboard for the hint-bearing owner before
    # the feeder gets round to asking for the payload.
    if not handed and e.owner.id == win1.id and e.target == TARGETS:
        win2.set_selection_owner(SEL, Xlib.X.CurrentTime)
        d.sync()
        handed = d.get_selection_owner(SEL) == win2
        print("handed" if handed else "HANDOFF-FAILED", flush=True)
PYEOF

cat >"$TMP/mini-clipnotify.c" <<'CEOF'
/* mini-clipnotify.c -- harness stand-in for clipnotify(1), built only when
 * the packaged binary is absent.  Same contract: subscribe to XFixes
 * selection events for the named selection, block until one arrives, exit
 * 0.  Exits nonzero when the display cannot be opened or dies, which is
 * what ends clip-store.sh's loop cleanly. */
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/Xfixes.h>

int main(int argc, char **argv) {
    const char *sel = "clipboard";
    int i;
    for (i = 1; i < argc - 1; i++)
        if (!strcmp(argv[i], "-s")) sel = argv[i + 1];
    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "mini-clipnotify: cannot open display\n"); return 1; }
    Atom a;
    if (!strcasecmp(sel, "clipboard")) a = XInternAtom(d, "CLIPBOARD", False);
    else if (!strcasecmp(sel, "primary")) a = XA_PRIMARY;
    else if (!strcasecmp(sel, "secondary")) a = XA_SECONDARY;
    else { fprintf(stderr, "mini-clipnotify: bad selection\n"); return 2; }
    int event_base, error_base;
    if (!XFixesQueryExtension(d, &event_base, &error_base)) {
        fprintf(stderr, "mini-clipnotify: no XFixes\n");
        return 1;
    }
    XFixesSelectSelectionInput(d, DefaultRootWindow(d), a,
        XFixesSetSelectionOwnerNotifyMask |
        XFixesSelectionWindowDestroyNotifyMask |
        XFixesSelectionClientCloseNotifyMask);
    XEvent ev;
    XNextEvent(d, &ev);
    XCloseDisplay(d);
    return 0;
}
CEOF

command -v "$XVFB"  >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=)"  >&2; exit 1; }
command -v xclip    >/dev/null 2>&1 || { echo "FATAL: xclip not found" >&2; exit 1; }
command -v flock    >/dev/null 2>&1 || { echo "FATAL: flock not found" >&2; exit 1; }
python3 -c 'import Xlib' 2>/dev/null || { echo "FATAL: python-xlib missing" >&2; exit 1; }
[ -f "$FEEDER" ]  || { echo "FATAL: feeder not found at $FEEDER" >&2; exit 1; }
[ -f "$STORESH" ] || { echo "FATAL: clip-store.sh not found at $STORESH" >&2; exit 1; }

# Resolve clipnotify for the concurrent-capture scenario's local loop: PATH
# first (the production binary), source-built stand-in only as a harness
# fallback (test-clip-store.sh's pattern).
if [ -n "${CLIPNOTIFY:-}" ]; then
  CN="$CLIPNOTIFY"
elif command -v clipnotify >/dev/null 2>&1; then
  CN="clipnotify"
else
  command -v gcc >/dev/null 2>&1 || { echo "FATAL: clipnotify not installed and no gcc to build the stand-in" >&2; exit 1; }
  gcc -O2 -o "$TMP/clipnotify" "$TMP/mini-clipnotify.c" -lX11 -lXfixes \
    || { echo "FATAL: could not build the clipnotify stand-in (libXfixes headers?)" >&2; exit 1; }
  CN="$TMP/clipnotify"
fi

start_xvfb "$DST" DST_PID
start_xvfb "$SRC" SRC_PID

echo "src(xrdp stand-in): $SRC   dst(native stand-in): $DST   run: $RUN"
echo "clipnotify: $CN"

# ======================= PHASE 1: capture, dedup, filtering =================

start_feeder

scenario "cross-display-capture: a copy on SRC reaches the DST store exactly once"
before="$(store_count)"
own_clipboard 'feed-marker-ONE'
size="$(wait_store_change "$before" 5)"
assert_eq "store grew by exactly one" "$((before + 1))" "$size"
assert_eq "the SRC copy is present, byte-exact" "feed-marker-ONE" \
  "$(cat "$(entry_for_content 'feed-marker-ONE')" 2>/dev/null)"
# "exactly once" is its own assertion, not implied by the count delta: a
# feeder that fed twice while something else was pruned would still show +1.
sleep 2
assert_eq "it appears exactly once, and stays once after another poll" "1" \
  "$(count_content 'feed-marker-ONE')"

scenario "dst-selection-untouched: feeding does NOT touch any DST X selection"
# The founding constraint of this feeder (sp014): pushing into the shared
# history must never yank the clipboard out from under whoever is working on
# the native display.  Under copyq that was `copyq add` (never `copyq
# copy`); under clipcat it needed a non-obvious flag (`-k secondary`).  The
# file-store backend makes this structural: nothing in clip-feed.sh runs an
# X call against DST at all, so there is no selection left to steal.  This
# scenario still asserts it behaviourally, not just by code inspection.
printf 'DST-USER-SENTINEL' \
  | env DISPLAY="$DST" timeout 5 xclip -selection clipboard >/dev/null 2>&1
sleep 2
before="$(store_count)"
own_clipboard 'feed-marker-NOSTEAL'
wait_store_change "$before" 5 >/dev/null
sleep 1
assert_eq "the fed copy did land in the store" "feed-marker-NOSTEAL" \
  "$(cat "$(entry_for_content 'feed-marker-NOSTEAL')" 2>/dev/null)"
assert_eq "DST CLIPBOARD still holds what the DST user put there" "DST-USER-SENTINEL" \
  "$(xsel_of "$DST" clipboard)"

scenario "capture-latency: the copy lands within a second"
before="$(store_count)"
own_clipboard 'feed-marker-LATENCY'
start_ns="$(date +%s%N)"
for i in $(seq 1 40); do
  [ "$(store_count)" != "$before" ] && break
  sleep 0.05
done
elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
assert_eq "the latency marker is in the store" "feed-marker-LATENCY" \
  "$(cat "$(entry_for_content 'feed-marker-LATENCY')" 2>/dev/null)"
assert_eq "landed within 1000ms (took ${elapsed_ms}ms)" "true" \
  "$([ "$elapsed_ms" -lt 1000 ] && echo true || echo "false (${elapsed_ms}ms)")"

scenario "repeat-copy-deduped: re-owning with identical text adds nothing"
before="$(store_count)"
own_clipboard 'feed-marker-LATENCY'
sleep 3   # no count change is the expected outcome, so this cannot poll-and-exit
assert_eq "store count unchanged" "$before" "$(store_count)"
assert_eq "and the entry is still there exactly once" "1" \
  "$(count_content 'feed-marker-LATENCY')"

scenario "distinct-copy-after-repeat: a genuinely new copy still gets through"
before="$(store_count)"
own_clipboard 'feed-marker-TWO'
size="$(wait_store_change "$before" 5)"
assert_eq "store grew by one" "$((before + 1))" "$size"
assert_eq "the new copy is present, byte-exact" "feed-marker-TWO" \
  "$(cat "$(entry_for_content 'feed-marker-TWO')" 2>/dev/null)"

scenario "multi-MB-copy-fed: a 3 MB copy is carried whole (no argv limit any more)"
# Task 4 discovered `clipcatctl insert <DATA>` capped at MAX_ARG_STRLEN
# (128 KiB) because the payload rode on argv, and had to switch to `load -f`.
# The file-store write never puts the payload on argv at all -- this is the
# edge case the task explicitly calls moot, proved with a fixture bigger
# than the old 200 KB one ever needed to be.
#
# Owned via a PLAIN xclip client here, not clip-owner.py: python-xlib's
# ChangeProperty encodes the request length in a 16-bit field with no
# INCR/BIG-REQUESTS chunking, so the fixture's own owner tops out around
# ~200 KB (measured -- a 3 MB serve raises "'H' format requires 0 <= number
# <= 65535" from python-xlib itself). Real xclip performs INCR properly,
# which is exactly why test-clip-store.sh's own 3 MB scenario uses it as
# the owner too. This is a test-fixture ceiling, not anything clip-feed.sh
# does -- the feeder's own read side (xclip -o) handles INCR fine either way.
python3 -c "import sys; sys.stdout.write('BIGFEED' + 'B' * 3000000)" >"$TMP/fix/big"
[ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; OWNER_PID=""; }
before="$(store_count)"
env DISPLAY="$SRC" timeout 30 xclip -selection clipboard "$TMP/fix/big" >/dev/null 2>&1
size="$(wait_store_change "$before" 20)"
assert_eq "store grew by one" "$((before + 1))" "$size"
assert_eq "stored bytes match the 3 MB source exactly" "identical" \
  "$(cmp -s "$TMP/fix/big" "$(newest_path)" && echo identical || echo different)"

scenario "multiline-fed: a multi-line copy is carried across byte-exact"
# UPGRADE over task 4: clipcatctl get irreversibly escaped embedded control
# characters (dotfiles-i9i), so that suite could only assert the escaped
# rendering.  A store entry is a plain file -- cat is exact -- so this now
# asserts the REAL bytes, not a known-lossy approximation.
printf 'ml-line-one\nml-line-two\ttabbed\nunicode-\303\251' >"$TMP/fix/ml"
before="$(store_count)"
own_clipboard_file "$TMP/fix/ml"
size="$(wait_store_change "$before" 5)"
assert_eq "store grew by one" "$((before + 1))" "$size"
assert_eq "the multiline/tab/unicode entry is byte-exact" "identical" \
  "$(cmp -s "$TMP/fix/ml" "$(newest_path)" && echo identical || echo different)"

scenario "literal-backslash-n-distinct: a two-char \\n sequence is not a newline (dotfiles-i9i)"
printf 'nl-DISTINCT-A\nnl-DISTINCT-B' >"$TMP/fix/realnl"
printf '%s' 'nl-DISTINCT-A\nnl-DISTINCT-B' >"$TMP/fix/litnl"
before="$(store_count)"
own_clipboard_file "$TMP/fix/realnl"
wait_store_change "$before" 5 >/dev/null
real_entry="$(newest_path)"
before="$(store_count)"
own_clipboard_file "$TMP/fix/litnl"
wait_store_change "$before" 5 >/dev/null
lit_entry="$(newest_path)"
assert_eq "real-newline entry is byte-exact" "identical" \
  "$(cmp -s "$TMP/fix/realnl" "$real_entry" && echo identical || echo different)"
assert_eq "literal-backslash-n entry is byte-exact" "identical" \
  "$(cmp -s "$TMP/fix/litnl" "$lit_entry" && echo identical || echo different)"
assert_eq "the two entries differ (distinct bytes stored distinctly)" "different" \
  "$(cmp -s "$real_entry" "$lit_entry" && echo identical || echo different)"

scenario "secret-not-laundered: a hint-bearing SRC copy never enters the DST store"
# THIS FIXTURE IS NOT BACKEND-SPECIFIC and has not been dropped across two
# swaps now.  It tests the FEEDER's first gate: whatever secret filter the
# destination's own capture path applies is a watcher-side rule that a
# direct file write bypasses entirely, so on this path the feeder's two
# gates are the only thing between a password and the shared store.
before="$(store_count)"
own_clipboard 'SECRET-PASSWORD-marker' application/x-kde-passwordManagerHint
sleep 4
assert_eq "store count unchanged" "$before" "$(store_count)"
assert_eq "secret text appears in no entry" "absent" "$(content_present 'SECRET-PASSWORD-marker')"
# The first gate's distinct guarantee, which the post-read re-check cannot
# provide: the payload is never fetched at all, so it never touches a
# scratch file.
assert_eq "no payload target was ever requested from the owner" "" \
  "$(reqlog_of_owner | grep -v '^REQ TARGETS$')"
assert_eq "TARGETS itself was requested (the gate did look)" "yes" \
  "$(reqlog_of_owner | grep -q '^REQ TARGETS$' && echo yes || echo no)"

scenario "secret-not-laundered-bare-atom: a bare-atom hint-bearing SRC copy never enters the DST store"
# dotfiles-wtr: the feeder's gate matched only the prefixed spelling; a
# password manager emitting just the bare 'x-kde-passwordManagerHint' atom
# (no 'application/' prefix -- clipcat's own default) would be dropped by
# clip-store.sh's loop on :0 but laundered straight across by this feeder
# from :10.  Same shape as secret-not-laundered above, bare atom instead.
before="$(store_count)"
own_clipboard 'BARE-SECRET-marker' x-kde-passwordManagerHint
sleep 4
assert_eq "store count unchanged" "$before" "$(store_count)"
assert_eq "bare-atom secret text appears in no entry" "absent" "$(content_present 'BARE-SECRET-marker')"
assert_eq "no payload target was ever requested from the owner" "" \
  "$(reqlog_of_owner | grep -v '^REQ TARGETS$')"
assert_eq "TARGETS itself was requested (the gate did look)" "yes" \
  "$(reqlog_of_owner | grep -q '^REQ TARGETS$' && echo yes || echo no)"

scenario "toctou-race: a hint-bearing owner taking the clipboard AFTER the gate passed still never reaches the store"
# The scenario above proves the gate stops a selection that already carries
# the hint when the gate looks.  This one covers the residual window the gate
# structurally cannot close: TARGETS and the payload are two X requests, and
# ownership can flip between them.  race-owner.py makes that flip fire
# deterministically off the gate's own TARGETS request, so the feeder reads
# the payload from a password manager it never gated.
before="$(store_count)"
own_race_clipboard 'RACE-DECOY-benign' 'RACE-SECRET-marker'
sleep 4
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "store count unchanged" "$before" "$(store_count)"
assert_eq "raced secret appears in no entry" "absent" "$(content_present 'RACE-SECRET-marker')"

scenario "toctou-race-bare-atom: a bare-atom hint-bearing owner taking the clipboard AFTER the gate passed still never reaches the store"
# dotfiles-wtr: same race as toctou-race above, but win2 advertises the bare
# 'x-kde-passwordManagerHint' atom instead of the prefixed one -- the
# re-check must fail closed on either spelling, same as the first gate does.
before="$(store_count)"
own_race_clipboard 'RACE-DECOY-benign' 'RACE-SECRET-BARE-marker' 'x-kde-passwordManagerHint'
sleep 4
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "store count unchanged" "$before" "$(store_count)"
assert_eq "bare-atom raced secret appears in no entry" "absent" "$(content_present 'RACE-SECRET-BARE-marker')"

scenario "image-skipped: a selection with no text target is not fed"
before="$(store_count)"
own_clipboard 'binary-image-marker' image/png
sleep 4
assert_eq "store count unchanged" "$before" "$(store_count)"
assert_eq "the image marker appears in no entry" "absent" "$(content_present 'binary-image-marker')"

scenario "empty-selection-skipped: an owner holding an empty string adds no entry"
# Distinct from the image case, which xclip refuses outright: here the read
# succeeds with zero bytes.  This is what makes the feeder's -s check
# load-bearing -- it cannot be delegated to the destination's own capture
# path, which this write bypasses entirely.
before="$(store_count)"
own_clipboard ''
sleep 4
assert_eq "store count unchanged" "$before" "$(store_count)"

scenario "double-start-guarded: a second feeder exits instead of double-feeding"
start_feeder            # FEED_PID now points at the second instance
sleep 1
second_alive="$(kill -0 "$FEED_PID" 2>/dev/null && echo alive || echo exited)"
assert_eq "second instance exited" "exited" "$second_alive"
FEED_PID=""
# Scoping rule (dotfiles-92w.5): match the ABSOLUTE test path, never a bare
# basename -- a bare `clip-feed.sh` would match the user's live feeder on a
# shared host.
running="$(pgrep -f -- "$FEEDER" | wc -l)"
assert_eq "exactly one feeder process remains" "1" "$running"
FEED_PID="$(pgrep -f -- "$FEEDER" | head -1)"

scenario "concurrent-capture-seq-no-clobber: feeder and a real local clip-store.sh loop write the same dir at once"
# The actual integration point sp016 task 7 exists to prove safe: clip-feed.sh
# and clip-store.sh are two separate processes that both write into
# $XDG_RUNTIME_DIR/clip-store/<DST>/.  A local capture on DST (handled by a
# REAL clip-store.sh loop, not a stand-in) and a fed copy from SRC are fired
# close together; both must land as distinct seq entries -- an `ln` collision
# must cost a retry, never a clobbered or dropped entry.
start_loop
base="$(store_count)"
# `wait` with no arguments waits for EVERY background job of this shell,
# including FEED_PID and LOOP_PID -- both long-running daemons that never
# exit on their own.  Waiting on the two just-launched job PIDs explicitly
# is what makes this scenario terminate instead of deadlocking forever.
own_clipboard 'CONC-SRC-marker' &
conc_src_job=$!
printf 'CONC-DST-marker' | env DISPLAY="$DST" timeout 5 xclip -selection clipboard >/dev/null 2>&1 &
conc_dst_job=$!
wait "$conc_src_job" "$conc_dst_job" 2>/dev/null
size="$(wait_store_change "$base" 10)"
sleep 1
assert_eq "store grew by exactly two (no clobber)" "$((base + 2))" "$(store_count)"
assert_eq "the fed SRC copy landed, byte-exact" "CONC-SRC-marker" \
  "$(cat "$(entry_for_content 'CONC-SRC-marker')" 2>/dev/null)"
assert_eq "the local DST copy landed, byte-exact" "CONC-DST-marker" \
  "$(cat "$(entry_for_content 'CONC-DST-marker')" 2>/dev/null)"
stop_loop

scenario "dst-store-dir-absent: the feeder recreates a removed destination store dir"
rm -rf "$SDIR"
before="$(store_count)"    # 0, the dir is gone
own_clipboard 'feed-marker-DIR-RECREATED'
size="$(wait_store_change "$before" 5)"
assert_eq "store grew by one after the dir was recreated" "$((before + 1))" "$size"
assert_eq "the copy is present, byte-exact" "feed-marker-DIR-RECREATED" \
  "$(cat "$(entry_for_content 'feed-marker-DIR-RECREATED')" 2>/dev/null)"
assert_eq "recreated store dir mode is 700" "700" "$(stat -c '%a' "$SDIR" 2>/dev/null)"
assert_eq "feeder still alive" "alive" \
  "$(kill -0 "$FEED_PID" 2>/dev/null && echo alive || echo dead)"

# ======================= PHASE 2: SRC teardown and recovery =================

scenario "src-teardown: feeder survives SRC dying and stays CPU-quiescent"
kill -9 "$SRC_PID" 2>/dev/null; wait "$SRC_PID" 2>/dev/null; SRC_PID=""
[ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; OWNER_PID=""; }
sleep 1
before_j="$(cpu_jiffies "$FEED_PID")"
sleep 3
after_j="$(cpu_jiffies "$FEED_PID")"
assert_eq "feeder still alive after SRC was killed" "alive" \
  "$(kill -0 "$FEED_PID" 2>/dev/null && echo alive || echo dead)"
# 1% of 3s at 100Hz is 3 jiffies; allow 5 for scheduling noise.
assert_eq "CPU quiescent over 3s (used ${after_j:-?}-${before_j:-?} jiffies)" "true" \
  "$([ -n "$after_j" ] && [ $((after_j - before_j)) -le 5 ] && echo true || echo "false ($((${after_j:-0} - ${before_j:-0})) jiffies)")"

scenario "src-returns: feeder resumes capturing when SRC comes back"
rm -f "/tmp/.X11-unix/X${SRC#:}"   # SIGKILL left the socket file behind
start_xvfb "$SRC" SRC_PID
before="$(store_count)"
own_clipboard 'feed-marker-AFTER-RESTART'
size="$(wait_store_change "$before" 15)"
assert_eq "store grew by one after SRC returned" "$((before + 1))" "$size"
assert_eq "the post-restart copy is present" "feed-marker-AFTER-RESTART" \
  "$(cat "$(entry_for_content 'feed-marker-AFTER-RESTART')" 2>/dev/null)"

scenario "start-with-src-absent: a feeder started before SRC exists still works"
stop_feeder
kill -9 "$SRC_PID" 2>/dev/null; wait "$SRC_PID" 2>/dev/null; SRC_PID=""
[ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; OWNER_PID=""; }
rm -f "/tmp/.X11-unix/X${SRC#:}"
start_feeder
assert_eq "feeder started cleanly with no SRC" "alive" \
  "$(kill -0 "$FEED_PID" 2>/dev/null && echo alive || echo dead)"
start_xvfb "$SRC" SRC_PID
before="$(store_count)"
own_clipboard 'feed-marker-COLD-START'
size="$(wait_store_change "$before" 15)"
assert_eq "the copy is captured once SRC appears" "$((before + 1))" "$size"
assert_eq "the cold-start copy is present" "feed-marker-COLD-START" \
  "$(cat "$(entry_for_content 'feed-marker-COLD-START')" 2>/dev/null)"

# ======================= PHASE 3: destination is named, never guessed =======

scenario "no-destination-refuses: daemon-era CLIP_FEED_DST_SOCKET is refused loudly, not ignored"
# sp016 task 7 edge case: a leftover CLIP_FEED_DST_SOCKET from the clipcat
# backend (task 4) must fail loudly with a migration message, never be
# silently ignored.  Run in the FOREGROUND under `timeout`: a feeder that
# wrongly proceeds into its poll loop would otherwise hang the suite forever
# instead of failing.  rc 124 here means "did not refuse", the failure to
# report.
stop_feeder
rm -f "$TMP/feed-nosock.lock"
timeout 10 env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" \
    CLIP_FEED_DST_SOCKET="$RUN/bogus.sock" \
    CLIP_FEED_LOCK="$TMP/feed-nosock.lock" \
    sh "$FEEDER" >"$TMP/nosock.out" 2>&1
rc=$?
assert_eq "exits 78 (EX_CONFIG) on the daemon-era variable" "78" "$rc"
assert_eq "and names the variable and points at the migration" "yes" \
  "$(grep -q 'CLIP_FEED_DST_SOCKET' "$TMP/nosock.out" && grep -q 'CLIP_FEED_DST' "$TMP/nosock.out" && echo yes || echo no)"

scenario "xdg-runtime-dir-unset: the feeder refuses to start, loudly, with no fallback"
timeout 10 env -u XDG_RUNTIME_DIR DISPLAY=:77 CLIP_FEED_SRC="$SRC" CLIP_FEED_DST="$DST" \
    CLIP_FEED_LOCK="$TMP/feed-nodir.lock" \
    sh "$FEEDER" >"$TMP/nodir.out" 2>&1
rc=$?
assert_eq "exits 78 (EX_CONFIG), as clip-store.sh does for the same variable" "78" "$rc"
assert_eq "and names what is missing" "yes" \
  "$(grep -q 'XDG_RUNTIME_DIR' "$TMP/nodir.out" && echo yes || echo no)"

scenario "no-dst-selection-call: the feeder never opens an X call against the destination"
# Static complement to dst-selection-untouched: the shipped feeder has no
# code path that could assert a DST selection even by accident.
assert_eq "no DISPLAY=\"\$DST\" (or equivalent) X call anywhere in the file" "" \
  "$(grep -E 'DISPLAY="\$DST"|DISPLAY=\$DST' "$FEEDER" | tr '\n' ' ')"

start_feeder

# ======================= PHASE 4: negative controls and mutations ===========
# Without these, the phase-1 "nothing was captured" assertions would pass just
# as well if the feeder were broken and captured nothing at all.

scenario "CONTROL hint-check-is-load-bearing: same copy IS fed without the checks"
stop_feeder
# A patched copy of the feeder with the hint filtering removed.  The bypass
# lives in the test, never in the shipped script.
#
# BOTH the pre-read gate and the post-read re-check have to go here: they are
# defence in depth against the same hint, so stripping either one alone leaves
# the other still dropping this copy and the control would assert nothing.
# The re-check's own isolated control is the raced scenario below, which
# strips ONLY the re-check.
awk '/SECURITY GATE/,/^  fi$/ {next} /TOCTOU RE-CHECK/,/^    fi$/ {next} {print}' \
  "$FEEDER" > "$TMP/clip-feed-nohint.sh"
grep -qE 'if hinted|\|\| hinted' "$TMP/clip-feed-nohint.sh" \
  && { echo "FATAL: patched feeder still calls the gate" >&2; exit 1; }
grep -qF 'feed_dst' "$TMP/clip-feed-nohint.sh" \
  || { echo "FATAL: patched feeder lost its feed path" >&2; exit 1; }
rm -f "$TMP/feed.lock"
start_feeder "$TMP/clip-feed-nohint.sh"
before="$(store_count)"
own_clipboard 'SECRET-PASSWORD-marker' application/x-kde-passwordManagerHint
size="$(wait_store_change "$before" 10)"
assert_eq "hint-bearing copy IS fed when the check is absent" "$((before + 1))" "$size"
assert_eq "and its full text lands in the store" "SECRET-PASSWORD-marker" \
  "$(cat "$(entry_for_content 'SECRET-PASSWORD-marker')" 2>/dev/null)"
# The task's mutation set names this precisely as "strip pre-check -> payload
# requested": with the pre-check gone, read_src() runs unconditionally, so
# the payload is fetched from the owner regardless of the hint -- the exact
# inverse of secret-not-laundered's "payload never even requested" assertion.
assert_eq "the payload WAS requested from the owner (the pre-check is what normally stops that)" "yes" \
  "$(reqlog_of_owner | grep -q 'REQ \(UTF8_STRING\|STRING\|text/plain\)' && echo yes || echo no)"
# Bare-atom negative control (dotfiles-wtr): with both checks stripped, a
# bare-atom hint-bearing copy must ALSO be fed -- proving
# secret-not-laundered-bare-atom's drop really comes from the gate matching
# the bare spelling, not some other accident of the harness.
before="$(store_count)"
own_clipboard 'BARE-SECRET-CONTROL-marker' x-kde-passwordManagerHint
size="$(wait_store_change "$before" 10)"
assert_eq "bare-atom hint-bearing copy IS fed when the check is absent" "$((before + 1))" "$size"
assert_eq "and its full text lands in the store" "BARE-SECRET-CONTROL-marker" \
  "$(cat "$(entry_for_content 'BARE-SECRET-CONTROL-marker')" 2>/dev/null)"
stop_feeder

scenario "CONTROL recheck-is-load-bearing: the raced secret IS fed without the post-read re-check"
# The phase-1 race scenario would pass just as well if the drop were coming
# from the FIRST gate rather than the re-check.  Strip only the re-check --
# leaving the first gate intact -- and the same race must leak.
awk '/TOCTOU RE-CHECK/,/^    fi$/ {next} {print}' "$FEEDER" > "$TMP/clip-feed-norecheck.sh"
grep -qF 'TOCTOU RE-CHECK' "$TMP/clip-feed-norecheck.sh" \
  && { echo "FATAL: patched feeder still contains the re-check" >&2; exit 1; }
grep -qF 'SECURITY GATE' "$TMP/clip-feed-norecheck.sh" \
  || { echo "FATAL: patched feeder lost the FIRST gate too; control would prove nothing" >&2; exit 1; }
grep -qF 'feed_dst' "$TMP/clip-feed-norecheck.sh" \
  || { echo "FATAL: patched feeder lost its feed path" >&2; exit 1; }
rm -f "$TMP/feed.lock"
start_feeder "$TMP/clip-feed-norecheck.sh"
before="$(store_count)"
own_race_clipboard 'RACE-DECOY-benign' 'RACE-SECRET-CONTROL'
size="$(wait_store_change "$before" 10)"
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "raced secret IS fed when the re-check is absent" "$((before + 1))" "$size"
assert_eq "and its full text lands in the store" "RACE-SECRET-CONTROL" \
  "$(cat "$(entry_for_content 'RACE-SECRET-CONTROL')" 2>/dev/null)"
# Bare-atom negative control (dotfiles-wtr): with the re-check stripped, a
# bare-atom raced secret must ALSO be fed -- proving toctou-race-bare-atom's
# drop really comes from the re-check matching the bare spelling, not
# vacuously true.
before="$(store_count)"
own_race_clipboard 'RACE-DECOY-benign' 'RACE-SECRET-BARE-CONTROL' 'x-kde-passwordManagerHint'
size="$(wait_store_change "$before" 10)"
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "bare-atom raced secret IS fed when the re-check is absent" "$((before + 1))" "$size"
assert_eq "and its full text lands in the store" "RACE-SECRET-BARE-CONTROL" \
  "$(cat "$(entry_for_content 'RACE-SECRET-BARE-CONTROL')" 2>/dev/null)"
stop_feeder

scenario "CONTROL feeder-is-load-bearing: no capture at all with no feeder"
rm -f "$TMP/feed.lock"
before="$(store_count)"
own_clipboard 'no-feeder-running-marker'
sleep 4
assert_eq "store count unchanged with the feeder stopped" "$before" "$(store_count)"

# ======================= PHASE 5: display screen-suffix normalization =======
# dotfiles-3x85: a raw X DISPLAY can carry a screen suffix (:0.0) while
# clip-feed.sh's own destination is normally the bare display the autostart
# passes (CLIP_FEED_DST=:0). The feeder must strip that suffix before it
# becomes a store-path component, or a caller naming the destination with the
# suffixed form silently feeds a store nothing else ever reads.

scenario "screen-suffix-dst-normalized: CLIP_FEED_DST=:N.0 feeds the bare-display store (dotfiles-3x85)"
rm -f "$TMP/feed-suffix.lock"
# The prior CONTROL scenario left SRC's clipboard owned (no feeder was
# running to consume it) -- clip-feed.sh is a POLLING loop, not event-driven,
# so a stale owner would be fed during THIS feeder's startup window, landing
# an entry before own_clipboard below ever runs and corrupting both the count
# and content assertions. Clear it first so the only owner during startup is
# none at all.
[ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; OWNER_PID=""; }
before="$(store_count)"
env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" \
    CLIP_FEED_SRC="$SRC" CLIP_FEED_DST="$DST.0" \
    CLIP_FEED_LOCK="$TMP/feed-suffix.lock" \
    CLIP_FEED_POLL=0.5 CLIP_FEED_IDLE=5 CLIP_FEED_TIMEOUT=5 \
    sh "$FEEDER" >>"$TMP/feeder-suffix.log" 2>&1 &
SUFFIX_FEED_PID=$!
sleep 1
own_clipboard 'suffix-dst-marker'
size="$(wait_store_change "$before" 5)"
assert_eq "store (\$SDIR, the bare-display dir) grew by one" "$((before + 1))" "$size"
assert_eq "the suffix-fed copy is present, byte-exact" "suffix-dst-marker" \
  "$(cat "$(entry_for_content 'suffix-dst-marker')" 2>/dev/null)"
assert_eq "no suffixed store dir was ever created" "no" \
  "$([ -d "$RUN/clip-store/$DST.0" ] && echo yes || echo no)"
kill "$SUFFIX_FEED_PID" 2>/dev/null; wait "$SUFFIX_FEED_PID" 2>/dev/null

# ------------------------------------------------------------------ result ---

printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
