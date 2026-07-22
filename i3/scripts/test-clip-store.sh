#!/usr/bin/env bash
# test-clip-store.sh — verify the file-store clipboard backend
# (i3/scripts/clip-store.sh): sp016 dotfiles-egm.6, the poc012 pivot.
#
# Runs entirely headless on a throwaway Xvfb display with an isolated
# XDG_RUNTIME_DIR (plus CONFIG/DATA/CACHE stand-ins), so it never touches
# the live X session, the live clipboard, or the live session's store under
# the real $XDG_RUNTIME_DIR/clip-store.
#
# The loop is deliberately launched with a bogus DISPLAY exported, so the
# suite fails if it ever starts trusting the inherited DISPLAY instead of
# taking CLIP_STORE_DISPLAY / $1.
#
# Selections are owned by python-xlib helpers rather than plain xclip where
# the scenario needs it: clip-owner.py publishes several MIME targets on one
# change (xclip cannot — one target per call; needed for the
# password-manager-hint cases) and logs every SelectionRequest target it
# receives, turning "payload never requested" from an assumption into a
# measurement (the test-clipcat.sh reqlog pattern).  race-owner.py is
# carried over from test-clip-feed.sh verbatim — it is backend-independent
# by design.  slow-owner.py serves the payload via deliberately slow INCR
# chunks, stretching the loop's payload read over ~2s so the atomicity of
# the write-then-link can be OBSERVED by a concurrent sampler instead of
# asserted on faith.
#
# clipnotify: the suite prefers the PATH binary (the one production runs).
# When it is absent — clipnotify is packaged in official `extra` but may not
# be installed on a dev host — a minimal stand-in is built from source into
# $TMP (XFixes subscribe, block for one selection event, exit; the same
# contract, and the same fallback poc012 used).  The suite prints which one
# a run used; a green run on the stand-in verifies the loop's logic, not the
# packaged binary.
#
# usage: i3/scripts/test-clip-store.sh
# env:   CLIPNOTIFY=/path/to/clipnotify  XVFB=/path/to/Xvfb (default: PATH)
#        TEST_DISPLAY=:96
#        KEEP_TMP=1   (debug: skip deleting $TMP on exit)
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STORESH="$REPO_DIR/clip-store.sh"
XVFB="${XVFB:-Xvfb}"
DPY="${TEST_DISPLAY:-:96}"

TMP="/tmp/clip-store-test.$$"
CFG="$TMP/cfg"    # XDG_CONFIG_HOME stand-in — must stay clean of content
DAT="$TMP/data"   # XDG_DATA_HOME stand-in — must stay clean of content
CCH="$TMP/cache"  # XDG_CACHE_HOME stand-in — must stay clean of content
RUN="$TMP/run"    # XDG_RUNTIME_DIR stand-in (tmpfs 0700 in production)
SDIR="$RUN/clip-store/$DPY"

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
  stop_loop
  [ -n "${SAMPLER_PID:-}" ] && kill "$SAMPLER_PID" 2>/dev/null
  [ -n "${OWNER_PID:-}" ] && kill "$OWNER_PID" 2>/dev/null
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

# Start an Xvfb on <display> and wait until it actually accepts connections.
# Waits for the display number to be FREE first: Xvfb refuses to start on a
# display whose /tmp/.X<n>-lock still exists, and a previous run of this
# same suite takes a moment to drop it (the test-clip-feed.sh lesson —
# running a suite twice back-to-back aborted otherwise).
start_xvfb() { # <display> <varname-for-pid>
  local i
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

# Start a store loop ($1 = script, default the real one; remaining args are
# extra VAR=VAL env assignments).  DISPLAY is set to a display that does not
# exist: a loop that trusts it captures nothing and the whole suite fails.
start_loop() { # [script [VAR=VAL ...]]
  local script="$STORESH"
  if [ $# -gt 0 ]; then script="$1"; shift; fi
  env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" \
      XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" XDG_CACHE_HOME="$CCH" \
      CLIPNOTIFY="$CN" CLIP_STORE_DISPLAY="$DPY" \
      "$@" sh "$script" >>"$TMP/loop.log" 2>&1 &
  LOOP_PID=$!
  sleep 1
}

# Kill the loop and its children by pid lineage — never by name (the
# dotfiles-92w.5 scoping rule; this epic watched clipse kill every process
# named 'st' via sloppy matching).  The blocked clipnotify child is found
# via pgrep -P before the parent dies and killed after, so no orphan keeps
# an X connection open between scenarios.
stop_loop() {
  [ -n "${LOOP_PID:-}" ] || return 0
  local kids k
  kids="$(pgrep -P "$LOOP_PID" 2>/dev/null)"
  kill "$LOOP_PID" 2>/dev/null
  wait "$LOOP_PID" 2>/dev/null
  for k in $kids; do kill "$k" 2>/dev/null; done
  LOOP_PID=""
}

# Own the CLIPBOARD with <text>, advertising any further arguments as extra
# MIME targets (each serving the value "secret").  Returns once held.
own_clipboard() { # <text> [extra-mime ...]
  [ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; }
  env DISPLAY="$DPY" python3 "$TMP/clip-owner.py" "$@" >"$TMP/owner.out" 2>&1 &
  OWNER_PID=$!
  local i
  for i in $(seq 1 20); do
    grep -q owned "$TMP/owner.out" 2>/dev/null && return 0
    sleep 0.25
  done
  echo "FATAL: could not own clipboard on $DPY; $(cat "$TMP/owner.out")" >&2
  exit 1
}

# Same, payload from <file> — for fixtures with real newlines/tabs/unicode
# that must arrive byte-exact.
own_clipboard_file() { # <file> [extra-mime ...]
  [ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; }
  env DISPLAY="$DPY" python3 "$TMP/clip-owner.py" --file "$@" >"$TMP/owner.out" 2>&1 &
  OWNER_PID=$!
  local i
  for i in $(seq 1 20); do
    grep -q owned "$TMP/owner.out" 2>/dev/null && return 0
    sleep 0.25
  done
  echo "FATAL: could not own clipboard on $DPY; $(cat "$TMP/owner.out")" >&2
  exit 1
}

# Own the CLIPBOARD with <benign-text>, handing the selection to a
# hint-bearing owner serving <secret-text> the moment the loop's TARGETS
# gate has been answered.  See race-owner.py.  Returns once win1 holds it.
own_race_clipboard() { # <benign-text> <secret-text>
  [ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; }
  env DISPLAY="$DPY" python3 "$TMP/race-owner.py" "$@" >"$TMP/owner.out" 2>&1 &
  OWNER_PID=$!
  local i
  for i in $(seq 1 20); do
    grep -q '^owned$' "$TMP/owner.out" 2>/dev/null && return 0
    sleep 0.25
  done
  echo "FATAL: could not own clipboard on $DPY; $(cat "$TMP/owner.out")" >&2
  exit 1
}

# Did the mid-read ownership handoff actually happen?  A race scenario whose
# handoff never fired is just an ordinary benign copy, and asserting "no
# secret in the store" against it would be a green that proves nothing.
race_fired() { grep -q '^handed$' "$TMP/owner.out" 2>/dev/null && echo fired || echo not-fired; }

reqlog_of_owner() { cat "$TMP/reqlog.$OWNER_PID" 2>/dev/null; }

# ---- store readers ----------------------------------------------------------
# These read the store exactly as consumers must: only ??????.clip names,
# lexicographic order == capture order, ids opaque.

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

# Wait until the store holds exactly <want> entries, or timeout.
wait_count() { # <want> [seconds]
  local want="$1" limit="${2:-10}" i
  for i in $(seq 1 $((limit * 10))); do
    [ "$(store_count)" = "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

# --------------------------------------------------------------- fixtures ---

mkdir -p "$TMP" "$CFG" "$DAT" "$CCH" "$RUN" "$TMP/fix" "$TMP/bin"
chmod 700 "$RUN"

cat >"$TMP/clip-owner.py" <<'PYEOF'
"""Own the X CLIPBOARD advertising several targets at once.

Simulates a password manager (KeePassXC) publishing the text payload and a
password-manager-hint MIME type on one clipboard change -- which xclip
cannot do (one target per invocation).  Every SelectionRequest target
received is appended to <this-script's-directory>/reqlog.<own-pid>, so a
caller can assert exactly what was requested, not just what was (or was
not) captured.

"image/png" as the sole extra means: serve ONLY that MIME, no text targets
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

cat >"$TMP/race-owner.py" <<'PYEOF'
"""Own CLIPBOARD benignly, then hand it to a hint-bearing owner the instant
the first TARGETS request has been answered.

This reproduces the TOCTOU window: the loop reads TARGETS and the payload
as two separate X requests (measured ~10-13ms apart), and X offers no way
to fetch them atomically.  A password-manager copy landing in that gap is
gated on the OLD owner and read from the NEW one.

Two windows on one connection:
  win1  benign text, TARGETS WITHOUT the password-manager hint -- what the
        loop's gate inspects, and correctly judges safe.
  win2  the secret, TARGETS WITH the hint -- the password manager that took
        the clipboard microseconds after the gate passed.

The handoff fires from inside the handler for win1's TARGETS reply, after
the SelectionNotify is flushed, so the loop's NEXT X request -- the payload
read -- is answered by win2.  That is precisely the race, made
deterministic: gate passed on win1, payload came from win2.

Prints "owned" once win1 holds the selection and "handed" once win2 does.
A scenario that never prints "handed" did not exercise the race and its
result means nothing; the suite asserts on it.

This fixture is BACKEND-INDEPENDENT.  It tests the capture path's own
gating against the X protocol, not anything about a backend, and has now
survived two backend swaps (copyq -> clipcat -> file store) unchanged for
exactly that reason.

usage: race-owner.py <benign-text> <secret-text>
"""
import sys
import Xlib.display
import Xlib.protocol.event
import Xlib.X
import Xlib.Xatom

benign = sys.argv[1].encode()
secret = sys.argv[2].encode()

d = Xlib.display.Display()
screen = d.screen()
win1 = screen.root.create_window(0, 0, 1, 1, 0, screen.root_depth)
win2 = screen.root.create_window(0, 0, 1, 1, 0, screen.root_depth)

SEL = d.get_atom("CLIPBOARD")
TARGETS = d.get_atom("TARGETS")
HINT = d.get_atom("application/x-kde-passwordManagerHint")
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

    # THE RACE.  win1's TARGETS answer is on the wire and the loop has
    # passed its gate.  Take the clipboard for the hint-bearing owner before
    # the loop gets round to asking for the payload.
    if not handed and e.owner.id == win1.id and e.target == TARGETS:
        win2.set_selection_owner(SEL, Xlib.X.CurrentTime)
        d.sync()
        handed = d.get_selection_owner(SEL) == win2
        print("handed" if handed else "HANDOFF-FAILED", flush=True)
PYEOF

cat >"$TMP/slow-owner.py" <<'PYEOF'
"""Own CLIPBOARD serving the payload via deliberately slow INCR transfers.

The X INCR protocol hands a large selection over in chunks, each gated on
the requestor deleting the previous chunk's property.  Sleeping between
chunks stretches the requestor's read over several seconds -- long enough
for a concurrent sampler to observe the store directory WHILE clip-store.sh
is mid-write, which is what turns "entries appear atomically" into a
measured fact: if the loop wrote the payload straight into its final
NNNNNN.clip name, the sampler would see the entry at partial sizes for the
whole transfer.

Writes the exact payload bytes to <payload-out> before owning, so the
caller can assert byte-exactness of whatever landed.

usage: slow-owner.py <size> <chunk> <delay-seconds> <payload-out>
"""
import sys
import time
import Xlib.display
import Xlib.protocol.event
import Xlib.X
import Xlib.Xatom

size = int(sys.argv[1])
chunk = int(sys.argv[2])
delay = float(sys.argv[3])
payload = (b"SLOWMARK-" + b"S" * size)[:size]
with open(sys.argv[4], "wb") as fh:
    fh.write(payload)

d = Xlib.display.Display()
screen = d.screen()
win = screen.root.create_window(0, 0, 1, 1, 0, screen.root_depth)

SEL = d.get_atom("CLIPBOARD")
TARGETS = d.get_atom("TARGETS")
INCR = d.get_atom("INCR")
UTF8 = d.get_atom("UTF8_STRING")
served = [UTF8, d.get_atom("text/plain"), Xlib.Xatom.STRING]

win.set_selection_owner(SEL, Xlib.X.CurrentTime)
d.sync()
if d.get_selection_owner(SEL) != win:
    print("FAILED to own CLIPBOARD", file=sys.stderr)
    sys.exit(1)
print("owned", flush=True)

transfers = {}
while True:
    e = d.next_event()
    if e.type == Xlib.X.SelectionRequest:
        prop = e.property if e.property != Xlib.X.NONE else e.target
        ok = True
        if e.target == TARGETS:
            e.requestor.change_property(
                prop, Xlib.Xatom.ATOM, 32, [TARGETS] + served)
        elif e.target in served:
            # Announce an INCR transfer: property of type INCR holding the
            # total size, then chunks fed on each PropertyDelete.
            e.requestor.change_attributes(event_mask=Xlib.X.PropertyChangeMask)
            e.requestor.change_property(prop, INCR, 32, [len(payload)])
            transfers[(e.requestor.id, prop)] = 0
        else:
            ok = False
        d.send_event(e.requestor, Xlib.protocol.event.SelectionNotify(
            time=e.time, requestor=e.requestor, selection=e.selection,
            target=e.target, property=prop if ok else Xlib.X.NONE))
        d.flush()
    elif e.type == Xlib.X.PropertyNotify and e.state == Xlib.X.PropertyDelete:
        key = (e.window.id, e.atom)
        if key not in transfers:
            continue
        off = transfers[key]
        data = payload[off:off + chunk]
        time.sleep(delay)
        e.window.change_property(e.atom, UTF8, 8, data)
        d.flush()
        if data:
            transfers[key] = off + len(data)
        else:
            del transfers[key]
            print("done", flush=True)
PYEOF

cat >"$TMP/bin/mini-clipnotify.c" <<'CEOF'
/* mini-clipnotify.c -- harness stand-in for clipnotify(1), built only when
 * the packaged binary is absent.  Same contract: subscribe to XFixes
 * selection events for the named selection, block until one arrives, exit
 * 0.  Exits nonzero when the display cannot be opened or dies (the default
 * Xlib IO error handler calls exit(1)), which is what ends the store loop
 * cleanly. */
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

# Byte-exact fixtures.  fix/litnl's content is the two-character sequence
# backslash-n where fix/realnl has a real 0x0a -- the case clipcatctl get
# rendered identically (dotfiles-i9i) and the store must keep distinct.
printf '%s' 'plain-marker-ONE' >"$TMP/fix/plain"
printf 'l\303\255n\304\223-ONE \342\230\203\thas\ttabs\nline-TWO\n\nline-FOUR-apr\303\250s-blank' >"$TMP/fix/mlt"
printf 'nl-DISTINCT-A\nnl-DISTINCT-B' >"$TMP/fix/realnl"
printf '%s' 'nl-DISTINCT-A\nnl-DISTINCT-B' >"$TMP/fix/litnl"
python3 -c "import sys; sys.stdout.write('BIGSTORE' + 'B' * 3000000)" >"$TMP/fix/big"

command -v "$XVFB" >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=)" >&2; exit 1; }
command -v xclip   >/dev/null 2>&1 || { echo "FATAL: xclip not found" >&2; exit 1; }
command -v flock   >/dev/null 2>&1 || { echo "FATAL: flock not found" >&2; exit 1; }
python3 -c 'import Xlib' 2>/dev/null || { echo "FATAL: python-xlib missing" >&2; exit 1; }
[ -f "$STORESH" ] || { echo "FATAL: store loop not found at $STORESH" >&2; exit 1; }

# Resolve clipnotify: PATH first (the production binary), source-built
# stand-in only as the harness fallback.
if [ -n "${CLIPNOTIFY:-}" ]; then
  CN="$CLIPNOTIFY"
  CN_KIND="override ($CN)"
elif command -v clipnotify >/dev/null 2>&1; then
  CN="clipnotify"
  CN_KIND="packaged (PATH)"
else
  command -v gcc >/dev/null 2>&1 || { echo "FATAL: clipnotify not installed and no gcc to build the stand-in" >&2; exit 1; }
  gcc -O2 -o "$TMP/bin/clipnotify" "$TMP/bin/mini-clipnotify.c" -lX11 -lXfixes \
    || { echo "FATAL: could not build the clipnotify stand-in (libXfixes headers?)" >&2; exit 1; }
  CN="$TMP/bin/clipnotify"
  CN_KIND="source-built stand-in (clipnotify not installed; install it for a packaged-binary run)"
fi

start_xvfb "$DPY" XVFB_PID

echo "display: $DPY   runtime: $RUN"
echo "clipnotify: $CN_KIND"

# ================= PHASE 1: capture, byte-exactness, gate ===================

start_loop

scenario "startup: the loop creates \$XDG_RUNTIME_DIR/clip-store/<display>/ 0700"
assert_eq "loop is running" "alive" \
  "$(kill -0 "$LOOP_PID" 2>/dev/null && echo alive || echo dead)"
assert_eq "store dir exists for the display" "yes" "$([ -d "$SDIR" ] && echo yes || echo no)"
assert_eq "store dir mode is 700" "700" "$(stat -c '%a' "$SDIR" 2>/dev/null)"
assert_eq "clip-store parent mode is 700" "700" "$(stat -c '%a' "$RUN/clip-store" 2>/dev/null)"

scenario "plain-capture-byte-exact: an external copy lands as the next seq file"
own_clipboard 'plain-marker-ONE'
wait_count 1 10
assert_eq "store holds one entry" "1" "$(store_count)"
assert_eq "the entry is the first seq file, 000001.clip" "000001.clip" \
  "$(basename "$(newest_path)" 2>/dev/null)"
assert_eq "entry bytes match the copy exactly" "identical" \
  "$(cmp -s "$TMP/fix/plain" "$(newest_path)" && echo identical || echo different)"
assert_eq "payload WAS requested for a plain copy (the reqlog instrument works)" "yes" \
  "$(reqlog_of_owner | grep -q 'REQ \(UTF8_STRING\|STRING\|text/plain\)' && echo yes || echo no)"

scenario "multiline-tabs-unicode-byte-exact: real newlines, tabs and unicode survive"
own_clipboard_file "$TMP/fix/mlt"
wait_count 2 10
assert_eq "store holds two entries" "2" "$(store_count)"
assert_eq "entry bytes match the fixture exactly" "identical" \
  "$(cmp -s "$TMP/fix/mlt" "$(newest_path)" && echo identical || echo different)"

scenario "literal-backslash-n-distinct: a two-char \\n sequence is not a newline (dotfiles-i9i)"
own_clipboard_file "$TMP/fix/realnl"
wait_count 3 10
real_entry="$(newest_path)"
own_clipboard_file "$TMP/fix/litnl"
wait_count 4 10
lit_entry="$(newest_path)"
assert_eq "real-newline entry is byte-exact" "identical" \
  "$(cmp -s "$TMP/fix/realnl" "$real_entry" && echo identical || echo different)"
assert_eq "literal-backslash-n entry is byte-exact" "identical" \
  "$(cmp -s "$TMP/fix/litnl" "$lit_entry" && echo identical || echo different)"
assert_eq "the two entries differ (distinct bytes stored distinctly)" "different" \
  "$(cmp -s "$real_entry" "$lit_entry" && echo identical || echo different)"

scenario "rapid-5x50ms-all-land: five copies at 50ms intervals all land, in order (poc012 bar)"
base="$(store_count)"
for i in 1 2 3 4 5; do
  printf 'rapid-%s' "$i" | env DISPLAY="$DPY" timeout 5 xclip -selection clipboard >/dev/null 2>&1
  sleep 0.05
done
wait_count "$((base + 5))" 15
assert_eq "all five landed as distinct entries" "$((base + 5))" "$(store_count)"
got=""
for f in $(entries_asc | tail -5); do
  got="$got $(cat "$f")"
done
assert_eq "and in capture order" " rapid-1 rapid-2 rapid-3 rapid-4 rapid-5" "$got"

scenario "dedup-consecutive: re-owning with identical text adds nothing"
base="$(store_count)"
own_clipboard 'dedup-marker'
wait_count "$((base + 1))" 10
assert_eq "the first copy landed" "$((base + 1))" "$(store_count)"
own_clipboard 'dedup-marker'
sleep 3   # no change is the expected outcome, so this cannot poll-and-exit
assert_eq "store count unchanged after the identical re-copy" "$((base + 1))" "$(store_count)"
assert_eq "the entry exists exactly once" "1" \
  "$(grep -lFx 'dedup-marker' "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].clip 2>/dev/null | wc -l)"

scenario "empty-selection-skipped: an owner holding an empty string adds no entry"
base="$(store_count)"
own_clipboard ''
sleep 3
assert_eq "store count unchanged" "$base" "$(store_count)"
assert_eq "loop still alive" "alive" \
  "$(kill -0 "$LOOP_PID" 2>/dev/null && echo alive || echo dead)"

scenario "image-owner-skipped: a selection with no text target is skipped, not crashed"
base="$(store_count)"
own_clipboard 'binary-image-marker' image/png
sleep 3
assert_eq "store count unchanged" "$base" "$(store_count)"
assert_eq "the image marker appears in no entry" "absent" "$(content_present 'binary-image-marker')"
assert_eq "loop still alive" "alive" \
  "$(kill -0 "$LOOP_PID" 2>/dev/null && echo alive || echo dead)"

scenario "owner-vanishes: an owner quitting after the event is a skip, not a crash"
base="$(store_count)"
own_clipboard 'vanish-marker'
wait_count "$((base + 1))" 10
base="$(store_count)"
kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; OWNER_PID=""
sleep 2   # the destroy event fires with nobody left to answer the read
assert_eq "store count unchanged after the ownerless event" "$base" "$(store_count)"
assert_eq "loop still alive" "alive" \
  "$(kill -0 "$LOOP_PID" 2>/dev/null && echo alive || echo dead)"

scenario "multi-MB-entry: a 3 MB copy is stored whole, byte-exact"
base="$(store_count)"
env DISPLAY="$DPY" timeout 30 xclip -selection clipboard "$TMP/fix/big" >/dev/null 2>&1
wait_count "$((base + 1))" 30
assert_eq "store grew by one" "$((base + 1))" "$(store_count)"
assert_eq "entry bytes match the 3 MB source exactly" "identical" \
  "$(cmp -s "$TMP/fix/big" "$(newest_path)" && echo identical || echo different)"

scenario "secret-dropped-bare-atom: a copy carrying bare x-kde-passwordManagerHint is not stored"
base="$(store_count)"
own_clipboard 'SECRET-bare-marker' x-kde-passwordManagerHint
sleep 3
assert_eq "store count unchanged" "$base" "$(store_count)"
assert_eq "the secret text appears in no entry" "absent" "$(content_present 'SECRET-bare-marker')"

scenario "payload-never-requested (bare atom): only TARGETS ever went to the owner"
assert_eq "no payload target was requested" "" \
  "$(reqlog_of_owner | grep -v '^REQ TARGETS$')"
assert_eq "TARGETS itself was requested (the gate did look)" "yes" \
  "$(reqlog_of_owner | grep -q '^REQ TARGETS$' && echo yes || echo no)"

scenario "secret-dropped-prefixed-atom: a copy carrying application/x-kde-passwordManagerHint is not stored"
base="$(store_count)"
own_clipboard 'SECRET-prefixed-marker' application/x-kde-passwordManagerHint
sleep 3
assert_eq "store count unchanged" "$base" "$(store_count)"
assert_eq "the secret text appears in no entry" "absent" "$(content_present 'SECRET-prefixed-marker')"

scenario "payload-never-requested (prefixed atom): only TARGETS ever went to the owner"
assert_eq "no payload target was requested" "" \
  "$(reqlog_of_owner | grep -v '^REQ TARGETS$')"
assert_eq "TARGETS itself was requested (the gate did look)" "yes" \
  "$(reqlog_of_owner | grep -q '^REQ TARGETS$' && echo yes || echo no)"

scenario "toctou-race: a hint-bearing owner taking the clipboard AFTER the gate passed still never reaches the store"
base="$(store_count)"
own_race_clipboard 'RACE-DECOY-benign' 'RACE-SECRET-marker'
sleep 3
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "store count unchanged (re-check dropped the raced payload)" "$base" "$(store_count)"
assert_eq "raced secret appears in no entry" "absent" "$(content_present 'RACE-SECRET-marker')"

scenario "store-dir-deleted: a store dir removed mid-session is recreated"
rm -rf "$SDIR"
own_clipboard 'recreated-marker'
wait_count 1 10
assert_eq "store recreated with one entry" "1" "$(store_count)"
assert_eq "recreated store dir mode is 700" "700" "$(stat -c '%a' "$SDIR" 2>/dev/null)"
assert_eq "the post-recreation entry is byte-exact" "recreated-marker" "$(cat "$(newest_path)")"

# ================= PHASE 2: atomicity, observed mid-write ===================

scenario "atomic-no-partial-reads: an entry is never visible at a partial size"
# A slow INCR owner stretches the payload read over ~2s while a sampler
# stats every visible entry every 30ms.  The entry must appear only at its
# full size — write-to-.tmp-then-link makes that structural, and the
# sampler would catch a loop that wrote into the final name directly.
stop_loop
start_loop "$STORESH" CLIP_STORE_TIMEOUT=20
base="$(store_count)"
rm -f "$TMP/atomic.stop" "$TMP/atomic.samples"
(
  while [ ! -e "$TMP/atomic.stop" ]; do
    echo TICK
    for f in "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
      [ -e "$f" ] && stat -c '%n %s' "$f"
    done
    sleep 0.03
  done > "$TMP/atomic.samples"
) &
SAMPLER_PID=$!
[ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; }
env DISPLAY="$DPY" python3 "$TMP/slow-owner.py" 1000000 65536 0.12 "$TMP/fix/slow-expected" \
  >"$TMP/owner.out" 2>&1 &
OWNER_PID=$!
for i in $(seq 1 20); do grep -q owned "$TMP/owner.out" 2>/dev/null && break; sleep 0.25; done
wait_count "$((base + 1))" 30
sleep 0.3          # let the sampler record the completed entry too
touch "$TMP/atomic.stop"
wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""
new="$(newest_path)"
full="$(stat -c '%s' "$new" 2>/dev/null)"
assert_eq "the slow entry landed" "$((base + 1))" "$(store_count)"
assert_eq "and is byte-exact" "identical" \
  "$(cmp -s "$TMP/fix/slow-expected" "$new" && echo identical || echo different)"
assert_eq "no sample ever saw it at a partial size" "" \
  "$(awk -v n="$new" -v s="$full" '$1 == n && $2 != s' "$TMP/atomic.samples")"
ticks_before="$(awk -v n="$new" '/^TICK$/ { t++ } $1 == n { print t; exit }' "$TMP/atomic.samples")"
assert_eq "the sampler really did watch during the transfer (>=20 ticks before it appeared; got ${ticks_before:-none})" "yes" \
  "$([ -n "$ticks_before" ] && [ "$ticks_before" -ge 20 ] && echo yes || echo no)"

# ================= PHASE 3: cap =============================================

scenario "cap-prunes-oldest: CLIP_STORE_CAP keeps the newest entries only"
stop_loop
start_loop "$STORESH" CLIP_STORE_CAP=3
for i in 1 2 3 4 5; do
  own_clipboard "caps-$i"
  sleep 0.4
done
sleep 2
assert_eq "exactly 3 entries remain" "3" "$(store_count)"
got=""
for f in $(entries_asc); do
  got="$got $(cat "$f")"
done
assert_eq "and they are the newest three, in order" " caps-3 caps-4 caps-5" "$got"

# ================= PHASE 4: single instance, display teardown ===============

scenario "flock-single-instance: a second loop on the same display exits at once"
stop_loop
start_loop
# The second instance takes the display as $1 — exercising the positional
# form task 5's autostart uses — and must lose the flock race and exit 0.
timeout 10 env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" CLIPNOTIFY="$CN" \
  sh "$STORESH" "$DPY" >"$TMP/second.out" 2>&1
rc=$?
assert_eq "second instance exited 0 (losing the race is not an error)" "0" "$rc"
assert_eq "exactly one loop process remains" "1" "$(pgrep -f -- "$STORESH" | wc -l)"
assert_eq "the first loop still holds the display" "alive" \
  "$(kill -0 "$LOOP_PID" 2>/dev/null && echo alive || echo dead)"

scenario "display-gone: the loop exits cleanly when the X server dies"
[ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; OWNER_PID=""; }
kill -TERM "$XVFB_PID" 2>/dev/null
wait "$XVFB_PID" 2>/dev/null; XVFB_PID=""
dead=no
for i in $(seq 1 80); do
  kill -0 "$LOOP_PID" 2>/dev/null || { dead=yes; break; }
  sleep 0.1
done
assert_eq "loop exited within 8s of the display dying (no busy-spin, no zombie)" "yes" "$dead"
wait "$LOOP_PID" 2>/dev/null
rc=$?
LOOP_PID=""
assert_eq "and exited 0 (clean end, not a crash)" "0" "$rc"

# ================= PHASE 5: negative controls and mutations =================
# Without these, every "nothing was stored" assertion above would pass just
# as well if the loop were broken and captured nothing at all.

start_xvfb "$DPY" XVFB_PID

scenario "CONTROL gates-are-load-bearing: the same hint-bearing copies ARE stored without them"
# A patched copy with BOTH the pre-read gate and the post-read re-check
# removed — they are defence in depth against the same hint, so stripping
# either alone leaves the other still dropping the copy and the control
# would assert nothing.  The re-check's own isolated control is the raced
# scenario below.  The bypass lives in the test, never in the shipped file.
awk '/SECURITY GATE/,/^  fi$/ {next} /TOCTOU RE-CHECK/,/^  fi$/ {next} {print}' \
  "$STORESH" >"$TMP/clip-store-nogate.sh"
grep -qE 'if hinted|\|\| hinted' "$TMP/clip-store-nogate.sh" \
  && { echo "FATAL: patched loop still calls the gate" >&2; exit 1; }
grep -qF 'store_write' "$TMP/clip-store-nogate.sh" \
  || { echo "FATAL: patched loop lost its write path" >&2; exit 1; }
stop_loop
start_loop "$TMP/clip-store-nogate.sh"
base="$(store_count)"
own_clipboard 'SECRET-CONTROL-bare' x-kde-passwordManagerHint
wait_count "$((base + 1))" 10
assert_eq "bare-atom copy IS stored when the gates are absent" "$((base + 1))" "$(store_count)"
assert_eq "and byte-exact" "yes" "$([ -n "$(entry_for_content 'SECRET-CONTROL-bare')" ] && echo yes || echo no)"
own_clipboard 'SECRET-CONTROL-prefixed' application/x-kde-passwordManagerHint
wait_count "$((base + 2))" 10
assert_eq "prefixed-atom copy IS stored when the gates are absent" "$((base + 2))" "$(store_count)"
assert_eq "and byte-exact" "yes" "$([ -n "$(entry_for_content 'SECRET-CONTROL-prefixed')" ] && echo yes || echo no)"

scenario "CONTROL recheck-is-load-bearing: the raced secret IS stored without the post-read re-check"
# The phase-1 race scenario would pass just as well if the drop were coming
# from the FIRST gate.  Strip only the re-check — leaving the first gate
# intact — and the same race must leak.
awk '/TOCTOU RE-CHECK/,/^  fi$/ {next} {print}' "$STORESH" >"$TMP/clip-store-norecheck.sh"
grep -qF 'TOCTOU RE-CHECK' "$TMP/clip-store-norecheck.sh" \
  && { echo "FATAL: patched loop still contains the re-check" >&2; exit 1; }
grep -qF 'SECURITY GATE' "$TMP/clip-store-norecheck.sh" \
  || { echo "FATAL: patched loop lost the FIRST gate too; control would prove nothing" >&2; exit 1; }
stop_loop
start_loop "$TMP/clip-store-norecheck.sh"
base="$(store_count)"
own_race_clipboard 'RACE-DECOY-control' 'RACE-SECRET-CONTROL'
wait_count "$((base + 1))" 10
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "raced secret IS stored when the re-check is absent" "$((base + 1))" "$(store_count)"
assert_eq "and its full text is in the store" "present" "$(content_present 'RACE-SECRET-CONTROL')"

scenario "MUTATION gate-after-read: payload-never-requested MUST fail when the gate moves below the read"
# Reorder the pre-read gate to run after read_sel (the task's mandated
# mutation).  The hint-bearing copy is still dropped — the checks all still
# run — but the payload has been fetched by then, so the instrumented
# reqlog assertion is what catches the reorder.  This proves that assertion
# is sensitive to gate ORDER, not merely to the drop.
awk '
  /SECURITY GATE/ { ingate = 1 }
  ingate { buf = buf $0 "\n"; if ($0 == "  fi") ingate = 0; next }
  { print }
  /^  read_sel \|\| return 0$/ { printf "%s", buf; buf = "" }
' "$STORESH" >"$TMP/clip-store-lategate.sh"
gate_line="$(grep -n 'if hinted' "$TMP/clip-store-lategate.sh" | head -1 | cut -d: -f1)"
read_line="$(grep -n 'read_sel || return 0' "$TMP/clip-store-lategate.sh" | head -1 | cut -d: -f1)"
{ [ -n "$gate_line" ] && [ -n "$read_line" ] && [ "$gate_line" -gt "$read_line" ]; } \
  || { echo "FATAL: mutant does not have the gate after the read; mutation would prove nothing" >&2; exit 1; }
stop_loop
start_loop "$TMP/clip-store-lategate.sh"
base="$(store_count)"
own_clipboard 'MUTANT-SECRET-marker' application/x-kde-passwordManagerHint
sleep 3
assert_eq "the payload IS requested under the reordered gate (the assertion fails as it must)" "requested" \
  "$(reqlog_of_owner | grep -q 'REQ \(UTF8_STRING\|STRING\|text/plain\)' && echo requested || echo not-requested)"
assert_eq "(the copy is still dropped — order, not outcome, is what the mutation flips)" "$base" "$(store_count)"

scenario "CONTROL loop-is-load-bearing: no capture at all with no loop"
stop_loop
base="$(store_count)"
own_clipboard 'no-loop-running-marker'
sleep 2
assert_eq "store count unchanged with the loop stopped" "$base" "$(store_count)"

# ================= PHASE 6: refusals and containment ========================

scenario "xdg-runtime-dir-unset: the loop refuses to start, loudly, with no fallback"
timeout 10 env -u XDG_RUNTIME_DIR DISPLAY=:77 CLIP_STORE_DISPLAY="$DPY" CLIPNOTIFY="$CN" \
  sh "$STORESH" >"$TMP/unset.out" 2>&1
rc=$?
assert_eq "exits 78 (EX_CONFIG), as clip-feed.sh and clipcatd before it" "78" "$rc"
assert_eq "and names what is missing" "yes" \
  "$(grep -q 'XDG_RUNTIME_DIR' "$TMP/unset.out" && echo yes || echo no)"

scenario "no-display-refuses: the loop will not run against a guessed display"
timeout 10 env -u CLIP_STORE_DISPLAY DISPLAY="$DPY" XDG_RUNTIME_DIR="$RUN" CLIPNOTIFY="$CN" \
  sh "$STORESH" >"$TMP/nodpy.out" 2>&1
rc=$?
assert_eq "exits 78 even with an inherited DISPLAY available to trust" "78" "$rc"
assert_eq "and says how to name one" "yes" \
  "$(grep -q 'CLIP_STORE_DISPLAY' "$TMP/nodpy.out" && echo yes || echo no)"

scenario "nothing-outside-runtime-dir: no clipboard content ever left \$XDG_RUNTIME_DIR"
markers='plain-marker-ONE|rapid-3|dedup-marker|vanish-marker|recreated-marker|SLOWMARK|BIGSTORE|caps-4|SECRET-bare-marker|SECRET-prefixed-marker|RACE-SECRET-marker'
assert_eq "no file under XDG_CONFIG_HOME contains item content" "" \
  "$(grep -rlaE "$markers" "$CFG" 2>/dev/null | tr '\n' ' ')"
assert_eq "no file under XDG_DATA_HOME contains item content" "" \
  "$(grep -rlaE "$markers" "$DAT" 2>/dev/null | tr '\n' ' ')"
assert_eq "no file under XDG_CACHE_HOME contains item content" "" \
  "$(grep -rlaE "$markers" "$CCH" 2>/dev/null | tr '\n' ' ')"
assert_eq "every .clip file in the sandbox lives under \$XDG_RUNTIME_DIR/clip-store" "" \
  "$(find "$TMP" -name '*.clip' 2>/dev/null | grep -v "^$RUN/clip-store/" | tr '\n' ' ')"
# Static containment: the shipped loop has no path escape hatch to reach for.
assert_eq "clip-store.sh contains no mktemp and no /tmp path (code, comments stripped)" "" \
  "$(sed 's/[[:space:]]*#.*//' "$STORESH" | grep -E 'mktemp|/tmp/' | tr '\n' ' ')"

# ------------------------------------------------------------------ result ---

printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
