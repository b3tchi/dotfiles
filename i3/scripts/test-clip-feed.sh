#!/usr/bin/env bash
# test-clip-feed.sh — verify the sp014 cross-display clipboard feeder
# (dotfiles-92w.2, i3/scripts/clip-feed.sh).
#
# Runs entirely headless on two throwaway Xvfb displays — a stand-in for the
# xrdp session (SRC) and one for the native session (DST) — with an isolated
# XDG_CONFIG_HOME for the DST copyq server, so it never touches the live X
# sessions, the live clipboard, or the real ~/.config/copyq.
#
# The feeder is deliberately launched with a bogus DISPLAY exported, so the
# suite fails if it ever starts trusting the inherited DISPLAY.
#
# Selections are owned by a python-xlib helper rather than `copyq copy`:
# copyq ignores clipboard changes it owns itself, so seeding through copyq
# would make every capture assertion a false pass.  The helper also publishes
# several MIME targets on one change, which xclip (one target per call)
# cannot do — needed for the password-manager-hint case.
#
# usage: i3/scripts/test-clip-feed.sh
# env:   COPYQ=/path/to/copyq  XVFB=/path/to/Xvfb  (default: from PATH)
#        SRC_DISPLAY=:98  DST_DISPLAY=:97
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FEEDER="$REPO_DIR/clip-feed.sh"
COPYQ="${COPYQ:-copyq}"
XVFB="${XVFB:-Xvfb}"
SRC="${SRC_DISPLAY:-:98}"
DST="${DST_DISPLAY:-:97}"

TMP="/tmp/clip-feed-test.$$"   # kept short: copyq's socket lives under $CFG
CFG="$TMP/cfg"
DAT="$TMP/data"
CCH="$TMP/cache"

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
  cq exit >/dev/null 2>&1
  [ -n "${OWNER_PID:-}" ] && kill "$OWNER_PID" 2>/dev/null
  [ -n "${SRC_PID:-}" ] && kill "$SRC_PID" 2>/dev/null
  [ -n "${DST_PID:-}" ] && kill "$DST_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# copyq client for the DST server.  The env here is the *test's* isolation,
# not the feeder's: the feeder itself calls a plain `copyq` and simply
# inherits whatever environment it was started in (copyq/dot.yaml contract).
cq() { env DISPLAY="$DST" XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" \
           XDG_CACHE_HOME="$CCH" "$COPYQ" "$@"; }

# Start an Xvfb on <display> and wait until it actually accepts connections.
# The socket file alone is not proof: a SIGKILLed Xvfb leaves its socket
# behind, so a restart would otherwise be declared up before it is.
start_xvfb() { # <display> <varname-for-pid>
  "$XVFB" "$1" -screen 0 800x600x24 >"$TMP/xvfb${1#:}.log" 2>&1 &
  local pid=$! i
  for i in $(seq 1 40); do
    if ! timeout 2 env DISPLAY="$1" xclip -selection clipboard -t TARGETS -o \
         2>&1 >/dev/null | grep -q "Can't open display"; then
      eval "$2=$pid"
      return 0
    fi
    sleep 0.5
  done
  echo "FATAL: Xvfb $1 did not start; see $TMP/xvfb${1#:}.log" >&2
  exit 1
}

start_server() {
  cq --start-server >"$TMP/server.log" 2>&1 &
  local i
  for i in $(seq 1 40); do
    cq eval 1 >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "FATAL: copyq server did not start; see $TMP/server.log" >&2
  cat "$TMP/server.log" >&2
  exit 1
}

# Start a feeder ($1 = script to run, default the real one).  DISPLAY is set
# to a display that does not exist: a feeder that trusts it captures nothing.
start_feeder() {
  env DISPLAY=:77 \
      XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" XDG_CACHE_HOME="$CCH" \
      CLIP_FEED_SRC="$SRC" CLIP_FEED_DST="$DST" \
      CLIP_FEED_LOCK="$TMP/feed.lock" \
      CLIP_FEED_POLL=0.5 CLIP_FEED_IDLE=5 CLIP_FEED_TIMEOUT=1 \
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

# Own SRC CLIPBOARD with <text>, advertising any further arguments as extra
# MIME targets (each serving the value "secret").  Returns once held.
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

# Own SRC CLIPBOARD with <benign-text>, handing the selection to a
# hint-bearing owner serving <secret-text> the moment the feeder's TARGETS
# gate has been answered.  See race-owner.py.  Returns once win1 holds it.
own_race_clipboard() { # <benign-text> <secret-text>
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
# secret in history" against it would be a green that proves nothing.  Every
# race scenario asserts this first.
race_fired() { grep -q '^handed$' "$TMP/owner.out" 2>/dev/null && echo fired || echo not-fired; }

# Wait until `copyq size` differs from <baseline>, or timeout.  Echoes size.
wait_size_change() { # <baseline> [seconds]
  local base="$1" limit="${2:-10}" i n
  for i in $(seq 1 $((limit * 5))); do
    n="$(cq size 2>/dev/null)"
    [ -n "$n" ] && [ "$n" != "$base" ] && { echo "$n"; return 0; }
    sleep 0.2
  done
  cq size 2>/dev/null
}

# Total CPU jiffies charged to <pid> and its reaped children.
cpu_jiffies() { # <pid>
  awk '{print $14 + $15 + $16 + $17}' "/proc/$1/stat" 2>/dev/null || echo ""
}

# --------------------------------------------------------------- fixtures ---

mkdir -p "$TMP" "$CFG/copyq" "$DAT" "$CCH"

# The DST server runs the shipped config through symlinks, exactly as rotz
# links it — so the hint-drop rule is ACTIVE on the receiving side.  That is
# the point of the laundering scenario below: `copyq add` bypasses automatic
# commands, so the destination's rule cannot save us and the feeder must
# filter for itself.
ln -s "$REPO_DIR/../../copyq/copyq.conf" "$CFG/copyq/copyq.conf"
ln -s "$REPO_DIR/../../copyq/commands.ini" "$CFG/copyq/copyq-commands.ini"

cat > "$TMP/clip-owner.py" <<'PYEOF'
"""Own the X CLIPBOARD advertising several targets at once.

Simulates a password manager (KeePassXC) publishing the text payload and the
`application/x-kde-passwordManagerHint` marker on one clipboard change --
which xclip cannot do (one target per invocation) and `copyq copy` cannot be
used for at all (copyq ignores clipboard changes it owns itself).

usage: clip-owner.py <text> [extra-mime ...]
"""
import sys
import Xlib.display
import Xlib.protocol.event
import Xlib.X
import Xlib.Xatom

text = sys.argv[1].encode()
extra = sys.argv[2:]

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
# "-" as the sole extra means: serve ONLY this MIME, no text targets at all
# (an image-style selection).
if extra[:1] == ["image/png"]:
    served = {d.get_atom("image/png"): text}
    extra = []
for mime in extra:
    served[d.get_atom(mime)] = b"secret"

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
    prop = e.property if e.property != Xlib.X.NONE else e.target
    ok = True
    if e.target == TARGETS:
        e.requestor.change_property(
            prop, Xlib.Xatom.ATOM, 32, [TARGETS] + list(served))
    elif e.target in served:
        # Logged so the suite can assert the STRONGER property of the first
        # gate: a hint-bearing selection has its payload never even requested,
        # not merely never fed.
        print("served-payload", flush=True)
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

    # THE RACE.  win1's TARGETS answer is on the wire and the feeder has
    # passed its gate.  Take the clipboard for the hint-bearing owner before
    # the feeder gets round to asking for the payload.
    if not handed and e.owner.id == win1.id and e.target == TARGETS:
        win2.set_selection_owner(SEL, Xlib.X.CurrentTime)
        d.sync()
        handed = d.get_selection_owner(SEL) == win2
        print("handed" if handed else "HANDOFF-FAILED", flush=True)
PYEOF

command -v "$COPYQ" >/dev/null 2>&1 || { echo "FATAL: copyq not found (set COPYQ=)" >&2; exit 1; }
command -v "$XVFB"  >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=)"  >&2; exit 1; }
command -v xclip    >/dev/null 2>&1 || { echo "FATAL: xclip not found" >&2; exit 1; }
command -v flock    >/dev/null 2>&1 || { echo "FATAL: flock not found" >&2; exit 1; }
python3 -c 'import Xlib' 2>/dev/null || { echo "FATAL: python-xlib missing" >&2; exit 1; }
[ -f "$FEEDER" ] || { echo "FATAL: feeder not found at $FEEDER" >&2; exit 1; }

start_xvfb "$DST" DST_PID
start_xvfb "$SRC" SRC_PID
start_server

echo "copyq: $("$COPYQ" --version 2>/dev/null | head -1)"
echo "src(xrdp stand-in): $SRC   dst(native stand-in): $DST   config: $CFG"

# ======================= PHASE 1: capture, dedup, filtering =================

start_feeder

scenario "cross-display-capture: a copy on SRC reaches the DST copyq history"
before="$(cq size)"
own_clipboard 'feed-marker-ONE'
size="$(wait_size_change "$before" 5)"
assert_eq "history grew by exactly one" "$((before + 1))" "$size"
assert_eq "newest DST item is the SRC copy" "feed-marker-ONE" "$(cq read 0)"

scenario "capture-latency: the copy lands within a second"
before="$(cq size)"
own_clipboard 'feed-marker-LATENCY'
start_ns="$(date +%s%N)"
for i in $(seq 1 40); do
  [ "$(cq size 2>/dev/null)" != "$before" ] && break
  sleep 0.05
done
elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
assert_eq "newest item is the latency marker" "feed-marker-LATENCY" "$(cq read 0)"
assert_eq "landed within 1000ms (took ${elapsed_ms}ms)" "true" \
  "$([ "$elapsed_ms" -lt 1000 ] && echo true || echo "false (${elapsed_ms}ms)")"

scenario "repeat-copy-deduped: re-owning with identical text adds nothing"
before="$(cq size)"
own_clipboard 'feed-marker-LATENCY'
sleep 3   # no size change is the expected outcome, so this cannot poll-and-exit
assert_eq "history size unchanged" "$before" "$(cq size)"

scenario "distinct-copy-after-repeat: a genuinely new copy still gets through"
before="$(cq size)"
own_clipboard 'feed-marker-TWO'
size="$(wait_size_change "$before" 5)"
assert_eq "history grew by one" "$((before + 1))" "$size"
assert_eq "newest item is the new copy" "feed-marker-TWO" "$(cq read 0)"

scenario "multiline-preserved: a multi-line copy is fed verbatim"
before="$(cq size)"
own_clipboard 'line-one
line-two'
wait_size_change "$before" 5 >/dev/null
assert_eq "both lines stored" "line-one
line-two" "$(cq read 0)"

scenario "secret-not-laundered: a hint-bearing SRC copy never enters DST history"
before="$(cq size)"
own_clipboard 'SECRET-PASSWORD-marker' application/x-kde-passwordManagerHint
sleep 4
assert_eq "history size unchanged" "$before" "$(cq size)"
assert_eq "newest item is still the previous copy" "line-one
line-two" "$(cq read 0)"
leaked=""
n="$(cq size)"
for ((i = 0; i < n; i++)); do
  cq read "$i" | grep -q 'SECRET-PASSWORD-marker' && leaked="row $i"
done
assert_eq "secret text appears in no history row" "" "$leaked"
# The first gate's distinct guarantee, which the post-read re-check cannot
# provide: the payload is never fetched at all, so it never touches a tmpfile.
assert_eq "the payload was never even requested from the owner" "not-requested" \
  "$(grep -q '^served-payload$' "$TMP/owner.out" && echo requested || echo not-requested)"

scenario "toctou-race: a hint-bearing owner taking the clipboard AFTER the gate passed still never reaches history"
# The scenario above proves the gate stops a selection that already carries
# the hint when the gate looks.  This one covers the residual window the gate
# structurally cannot close: TARGETS and the payload are two X requests, and
# ownership can flip between them.  race-owner.py makes that flip fire
# deterministically off the gate's own TARGETS request, so the feeder reads
# the payload from a password manager it never gated.
before="$(cq size)"
own_race_clipboard 'RACE-DECOY-benign' 'RACE-SECRET-marker'
sleep 4
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "history size unchanged" "$before" "$(cq size)"
assert_eq "newest item is still the previous copy" "line-one
line-two" "$(cq read 0)"
leaked=""
n="$(cq size)"
for ((i = 0; i < n; i++)); do
  cq read "$i" | grep -q 'RACE-SECRET-marker' && leaked="row $i"
done
assert_eq "raced secret appears in no history row" "" "$leaked"

scenario "image-skipped: a selection with no text target is not fed"
before="$(cq size)"
own_clipboard 'binary-image-marker' image/png
sleep 4
assert_eq "history size unchanged" "$before" "$(cq size)"
assert_eq "newest item is still the previous copy" "line-one
line-two" "$(cq read 0)"

scenario "empty-selection-skipped: an owner holding an empty string adds no row"
# Distinct from the image case, which xclip refuses outright: here the read
# succeeds with zero bytes, and `copyq add -` would happily append a blank
# history row.  This is what makes the feeder's -s check load-bearing.
before="$(cq size)"
own_clipboard ''
sleep 4
assert_eq "history size unchanged" "$before" "$(cq size)"
assert_eq "newest item is still the previous copy" "line-one
line-two" "$(cq read 0)"

scenario "double-start-guarded: a second feeder exits instead of double-feeding"
start_feeder            # FEED_PID now points at the second instance
sleep 1
second_alive="$(kill -0 "$FEED_PID" 2>/dev/null && echo alive || echo exited)"
assert_eq "second instance exited" "exited" "$second_alive"
FEED_PID=""
running="$(pgrep -f -- "$FEEDER" | wc -l)"
assert_eq "exactly one feeder process remains" "1" "$running"
FEED_PID="$(pgrep -f -- "$FEEDER" | head -1)"

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
before="$(cq size)"
own_clipboard 'feed-marker-AFTER-RESTART'
size="$(wait_size_change "$before" 15)"
assert_eq "history grew by one after SRC returned" "$((before + 1))" "$size"
assert_eq "newest item is the post-restart copy" "feed-marker-AFTER-RESTART" "$(cq read 0)"

scenario "start-with-src-absent: a feeder started before SRC exists still works"
stop_feeder
kill -9 "$SRC_PID" 2>/dev/null; wait "$SRC_PID" 2>/dev/null; SRC_PID=""
[ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; OWNER_PID=""; }
rm -f "/tmp/.X11-unix/X${SRC#:}"
start_feeder
assert_eq "feeder started cleanly with no SRC" "alive" \
  "$(kill -0 "$FEED_PID" 2>/dev/null && echo alive || echo dead)"
start_xvfb "$SRC" SRC_PID
before="$(cq size)"
own_clipboard 'feed-marker-COLD-START'
size="$(wait_size_change "$before" 15)"
assert_eq "the copy is captured once SRC appears" "$((before + 1))" "$size"
assert_eq "newest item is the cold-start copy" "feed-marker-COLD-START" "$(cq read 0)"

# ======================= PHASE 3: negative controls =========================
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
# The re-check's own isolated control is the raced scenario further down,
# which strips ONLY the re-check.
awk '/SECURITY GATE/,/^  fi$/ {next} /TOCTOU RE-CHECK/,/^    fi$/ {next} {print}' \
  "$FEEDER" > "$TMP/clip-feed-nohint.sh"
grep -qF -- "-qFx 'application/x-kde-passwordManagerHint'" "$TMP/clip-feed-nohint.sh" \
  && { echo "FATAL: patched feeder still contains the hint check" >&2; exit 1; }
grep -q 'copyq add' "$TMP/clip-feed-nohint.sh" \
  || { echo "FATAL: patched feeder lost its feed path" >&2; exit 1; }
rm -f "$TMP/feed.lock"
start_feeder "$TMP/clip-feed-nohint.sh"
before="$(cq size)"
own_clipboard 'SECRET-PASSWORD-marker' application/x-kde-passwordManagerHint
size="$(wait_size_change "$before" 10)"
assert_eq "hint-bearing copy IS fed when the check is absent" "$((before + 1))" "$size"
assert_eq "and its full text lands in DST history" "SECRET-PASSWORD-marker" "$(cq read 0)"
stop_feeder

scenario "CONTROL recheck-is-load-bearing: the raced secret IS fed without the post-read re-check"
# The phase-1 race scenario would pass just as well if the drop were coming
# from the FIRST gate rather than the re-check.  Strip only the re-check --
# leaving the first gate intact -- and the same race must leak.
stop_feeder
awk '/TOCTOU RE-CHECK/,/^    fi$/ {next} {print}' "$FEEDER" > "$TMP/clip-feed-norecheck.sh"
grep -qF 'TOCTOU RE-CHECK' "$TMP/clip-feed-norecheck.sh" \
  && { echo "FATAL: patched feeder still contains the re-check" >&2; exit 1; }
grep -qF 'SECURITY GATE' "$TMP/clip-feed-norecheck.sh" \
  || { echo "FATAL: patched feeder lost the FIRST gate too; control would prove nothing" >&2; exit 1; }
grep -q 'copyq add' "$TMP/clip-feed-norecheck.sh" \
  || { echo "FATAL: patched feeder lost its feed path" >&2; exit 1; }
rm -f "$TMP/feed.lock"
start_feeder "$TMP/clip-feed-norecheck.sh"
before="$(cq size)"
own_race_clipboard 'RACE-DECOY-benign' 'RACE-SECRET-CONTROL'
size="$(wait_size_change "$before" 10)"
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "raced secret IS fed when the re-check is absent" "$((before + 1))" "$size"
assert_eq "and its full text lands in DST history" "RACE-SECRET-CONTROL" "$(cq read 0)"
stop_feeder

scenario "CONTROL feeder-is-load-bearing: no capture at all with no feeder"
rm -f "$TMP/feed.lock"
before="$(cq size)"
own_clipboard 'no-feeder-running-marker'
sleep 4
assert_eq "history size unchanged with the feeder stopped" "$before" "$(cq size)"

# ------------------------------------------------------------------ result ---

printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
