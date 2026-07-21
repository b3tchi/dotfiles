#!/usr/bin/env bash
# test-clip-feed.sh — verify the cross-display clipboard feeder
# (i3/scripts/clip-feed.sh): sp014 dotfiles-92w.2, ported to the clipcat
# backend by sp016 dotfiles-egm.4.
#
# Runs entirely headless on two throwaway Xvfb displays — a stand-in for the
# xrdp session (SRC) and one for the native session (DST) — with an isolated
# XDG_CONFIG_HOME / XDG_RUNTIME_DIR for the DST clipcatd, so it never touches
# the live X sessions, the live clipboard, the real ~/.config/clipcat, or the
# live session's clipcat daemon.
#
# The feeder is deliberately launched with a bogus DISPLAY exported AND with
# XDG_RUNTIME_DIR unset, so the suite fails if it ever starts trusting the
# inherited DISPLAY or guessing the destination socket from the environment
# instead of taking CLIP_FEED_DST_SOCKET.
#
# Selections are owned by a python-xlib helper rather than a clipcatctl call:
# a clipcatctl insert/load does not re-trigger the daemon's watcher at all
# (poc010 Q3), so seeding through it would make every capture assertion a
# false pass.  The helper also publishes several MIME targets on one change,
# which xclip (one target per call) cannot do — needed for the
# password-manager-hint case.
#
# ------------------------------------------------------------------------
# WHY THIS SUITE IS STRUCTURALLY IMMUNE TO dotfiles-apl
# ------------------------------------------------------------------------
# clipcat 0.25.0 has an upstream listener defect (dotfiles-apl): on a
# fraction of daemon starts the X11 watcher dies permanently on
# GetProperty->BadAtom, and that daemon then silently records nothing for its
# whole lifetime.  clipcat/test-clipcat.sh has to fight it with a bounded
# fresh-restart retry, because everything it asserts arrives through the
# watcher.
#
# This suite does not, because the FEED PATH NEVER USES THE DST WATCHER.
# clip-feed.sh reads the SRC selection with xclip and hands the bytes to the
# DST daemon over gRPC (`clipcatctl load`), which by poc010 Q3 bypasses the
# watcher entirely.  A born-deaf DST daemon still accepts, stores and serves
# every fed clip.  So "the feeder didn't feed" and "the daemon was born deaf"
# are not confusable here: the latter cannot produce the former.
#
# That claim is not left as an assertion of faith — the diagnostic line
# printed after startup MEASURES the DST watcher's liveness on each run, so
# the record shows whether a given green run happened to have a deaf daemon
# (it should, sometimes, and the results should be identical either way).
# The daemon startup retry below is therefore bounded on gRPC readiness only,
# with no X11 warm-up gate; the retry exists for ordinary start failures, not
# for apl.
#
# usage: i3/scripts/test-clip-feed.sh
# env:   CLIPCATD=/path/to/clipcatd  CLIPCATCTL=/path/to/clipcatctl
#        XVFB=/path/to/Xvfb          (all default: from PATH)
#        SRC_DISPLAY=:98  DST_DISPLAY=:97
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FEEDER="$REPO_DIR/clip-feed.sh"
CLIPCATD="${CLIPCATD:-clipcatd}"
CLIPCATCTL="${CLIPCATCTL:-clipcatctl}"
XVFB="${XVFB:-Xvfb}"
SRC="${SRC_DISPLAY:-:98}"
DST="${DST_DISPLAY:-:97}"

# AF_UNIX socket paths are capped near 108 bytes (SUN_LEN), so $TMP is kept
# short — same reason clipcat/test-clipcat.sh does it.
TMP="/tmp/clip-feed-test.$$"
CFG="$TMP/cfg"    # XDG_CONFIG_HOME for the DST daemon
DAT="$TMP/data"
CCH="$TMP/cache"
RUN="$TMP/run"    # XDG_RUNTIME_DIR stand-in (tmpfs 0700 in production)
SOCK="$RUN/clipcat/grpc.sock"

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
  stop_server
  [ -n "${OWNER_PID:-}" ] && kill "$OWNER_PID" 2>/dev/null
  [ -n "${SRC_PID:-}" ] && kill "$SRC_PID" 2>/dev/null
  [ -n "${DST_PID:-}" ] && kill "$DST_PID" 2>/dev/null
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

# clipcatctl client for the DST daemon.  Always timeout-wrapped (adr0002).
# The env here is the *test's* isolation; the feeder gets its own environment
# in start_feeder and is deliberately given LESS than this.
cc() { timeout 10 env XDG_RUNTIME_DIR="$RUN" "$CLIPCATCTL" --server-endpoint "$SOCK" "$@"; }

# Read a selection on a given display.
xsel_of() { # <display> <selection>
  env DISPLAY="$1" timeout 5 xclip -selection "$2" -o 2>/dev/null
}

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

# The DST clipcatd.  Backgrounded by invoking the binary directly, never via
# a shell function or $(...) — otherwise $! is the subshell and the real
# daemon is orphaned (clipcat/test-clipcat.sh harness bugs #1/#2).
#
# Readiness is gRPC only, deliberately: see the dotfiles-apl note in the file
# header.  Every assertion in this suite reaches the daemon over gRPC, so a
# daemon whose X11 watcher is dead is still a perfectly good daemon here.
_start_server_once() {
  mkdir -p "$RUN/clipcat"
  chmod 700 "$RUN"
  env DISPLAY="$DST" XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" \
      XDG_CACHE_HOME="$CCH" XDG_RUNTIME_DIR="$RUN" \
    "$CLIPCATD" --no-daemon --grpc-socket-path "$SOCK" >"$TMP/server.log" 2>&1 &
  DAEMON_PID=$!
  local i
  for i in $(seq 1 40); do
    cc length >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  kill "$DAEMON_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  DAEMON_PID=""
  return 1
}

start_server() {
  local attempt
  for attempt in 1 2 3 4 5; do
    _start_server_once && return 0
    echo "warning: DST clipcatd start attempt $attempt failed; retrying fresh" >&2
    sleep 1
  done
  echo "FATAL: DST clipcatd did not become reachable after 5 attempts." >&2
  echo "NOTE: clipcat.toml sets emit_journald=true / emit_stdout=false, so the" >&2
  echo "daemon's own diagnostics go to journald:  journalctl --user -t clipcatd -n 50" >&2
  cat "$TMP/server.log" >&2
  exit 1
}

stop_server() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  kill -TERM "$DAEMON_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  DAEMON_PID=""
}

# Is the DST daemon's X11 watcher alive on this run?  DIAGNOSTIC ONLY — no
# assertion depends on the answer, which is exactly the point (see the
# dotfiles-apl note in the header).  Costs one throwaway capture, which is
# cleared afterwards.
#
# The xclip below MUST have its stdout redirected: xclip forks a background
# process to keep serving the selection, and that child inherits whatever
# stdout it was given.  This function is called inside a command
# substitution, so an un-redirected xclip child holds the substitution's pipe
# open forever and the whole suite hangs before its first assertion.
# (Observed.  Every other xclip-as-owner call in this file runs at statement
# level, where the inherited stdout is harmless.)
probe_dst_watcher() {
  local before after
  before="$(cc length 2>/dev/null)"
  printf '__watcher_probe_%s__' "$$" \
    | env DISPLAY="$DST" timeout 5 xclip -selection clipboard >/dev/null 2>&1
  sleep 3
  after="$(cc length 2>/dev/null)"
  # drop whatever the probe added and release the selection
  cc clear >/dev/null 2>&1
  [ "$before" != "$after" ] && echo alive || echo "deaf (known upstream defect dotfiles-apl)"
}

# Start a feeder ($1 = script to run, default the real one).
#
# DISPLAY is set to a display that does not exist and XDG_RUNTIME_DIR is
# REMOVED: a feeder that trusts either captures nothing / feeds nowhere.  The
# destination is named explicitly, exactly as task 5's autostart will name it.
start_feeder() {
  env -u XDG_RUNTIME_DIR DISPLAY=:77 \
      XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" XDG_CACHE_HOME="$CCH" \
      CLIP_FEED_SRC="$SRC" CLIP_FEED_DST_SOCKET="$SOCK" \
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

# ---- id-keyed history helpers (dotfiles-8il) --------------------------------
# `clipcatctl list` has NO stable or temporal order — three consecutive calls
# against unchanged history returned three different orderings.  So nothing
# here reads position 0, or any position: entries are found by content, which
# is also the spec's own rule (ids are content hashes, not row numbers).

# How many history entries have exactly this text as their (untruncated)
# preview.  Used for "landed exactly once".
count_content() { # <exact text>
  cc list 2>/dev/null | awk -v want="$1" -F': ' \
    '{ id=$1; sub(/^[^:]*: /, "", $0); if ($0 == want) n++ } END { print n + 0 }'
}

# id of the first entry whose full preview is exactly <text>; empty if none.
id_for_content() { # <exact text>
  cc list 2>/dev/null | while IFS= read -r line; do
    if [ "${line#*: }" = "$1" ]; then echo "${line%%: *}"; return; fi
  done
}

# id of the first entry whose preview STARTS WITH <prefix>.  For fixtures
# longer than clipcatctl's 100-char preview.
id_for_preview_prefix() { # <prefix>
  cc list 2>/dev/null | while IFS= read -r line; do
    case "${line#*: }" in
      "$1"*) echo "${line%%: *}"; return ;;
    esac
  done
}

# Does <text> appear anywhere in any history entry?  The leak check.
leaks() { # <text>
  local id
  cc list 2>/dev/null | cut -d: -f1 | while IFS= read -r id; do
    [ -n "$id" ] || continue
    cc get "$id" 2>/dev/null | grep -qF -- "$1" && { echo "id $id"; return; }
  done
}

# Wait until `clipcatctl length` differs from <baseline>, or timeout.
wait_length_change() { # <baseline> [seconds]
  local base="$1" limit="${2:-10}" i n
  for i in $(seq 1 $((limit * 5))); do
    n="$(cc length 2>/dev/null)"
    [ -n "$n" ] && [ "$n" != "$base" ] && { echo "$n"; return 0; }
    sleep 0.2
  done
  cc length 2>/dev/null
}

# Total CPU jiffies charged to <pid> and its reaped children.
cpu_jiffies() { # <pid>
  awk '{print $14 + $15 + $16 + $17}' "/proc/$1/stat" 2>/dev/null || echo ""
}

# --------------------------------------------------------------- fixtures ---

mkdir -p "$TMP" "$CFG/clipcat" "$DAT" "$CCH" "$RUN/clipcat"
chmod 700 "$RUN"

# The DST daemon runs the shipped config through a symlink, exactly as rotz
# links it — so `sensitive_mime_types` is ACTIVE on the receiving side.  That
# is the point of the laundering scenario below: a clipcatctl load bypasses
# the watcher (poc010 Q3), so the destination's own filter cannot save us and
# the feeder must filter for itself.
ln -s "$REPO_DIR/../../clipcat/clipcat.toml" "$CFG/clipcat/clipcatd.toml"

cat > "$TMP/clip-owner.py" <<'PYEOF'
"""Own the X CLIPBOARD advertising several targets at once.

Simulates a password manager (KeePassXC) publishing the text payload and the
`application/x-kde-passwordManagerHint` marker on one clipboard change --
which xclip cannot do (one target per invocation) and a clipcatctl load
cannot be used for at all (it bypasses the watcher, so it would exercise
nothing).

usage: clip-owner.py <text> [extra-mime ...]
       clip-owner.py --file <path> [extra-mime ...]
"""
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
# "image/png" as the sole extra means: serve ONLY this MIME, no text targets
# at all (an image-style selection).
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

This fixture is BACKEND-INDEPENDENT.  It tests the feeder's own gating
against the X protocol, not anything about copyq or clipcat, and survived
the sp016 backend swap unchanged for exactly that reason.

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

command -v "$CLIPCATD"   >/dev/null 2>&1 || { echo "FATAL: clipcatd not found (set CLIPCATD=)" >&2; exit 1; }
command -v "$CLIPCATCTL" >/dev/null 2>&1 || { echo "FATAL: clipcatctl not found (set CLIPCATCTL=)" >&2; exit 1; }
command -v "$XVFB"  >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=)"  >&2; exit 1; }
command -v xclip    >/dev/null 2>&1 || { echo "FATAL: xclip not found" >&2; exit 1; }
command -v flock    >/dev/null 2>&1 || { echo "FATAL: flock not found" >&2; exit 1; }
python3 -c 'import Xlib' 2>/dev/null || { echo "FATAL: python-xlib missing" >&2; exit 1; }
[ -f "$FEEDER" ] || { echo "FATAL: feeder not found at $FEEDER" >&2; exit 1; }

start_xvfb "$DST" DST_PID
start_xvfb "$SRC" SRC_PID
start_server

echo "clipcatd: $("$CLIPCATD" --version 2>/dev/null | head -1)"
echo "src(xrdp stand-in): $SRC   dst(native stand-in): $DST   socket: $SOCK"
echo "DST watcher on this run: $(probe_dst_watcher)  <- diagnostic only; no assertion below depends on it (see header)"

# ======================= PHASE 1: capture, dedup, filtering =================

start_feeder

scenario "cross-display-capture: a copy on SRC reaches the DST clipcat history exactly once"
before="$(cc length)"
own_clipboard 'feed-marker-ONE'
size="$(wait_length_change "$before" 5)"
assert_eq "history grew by exactly one" "$((before + 1))" "$size"
assert_eq "the SRC copy is present, byte-exact" "feed-marker-ONE" \
  "$(cc get "$(id_for_content 'feed-marker-ONE')" 2>/dev/null)"
# "exactly once" is its own assertion, not implied by the length delta: a
# feeder that fed twice while something else was removed would still show +1.
sleep 2
assert_eq "it appears exactly once, and stays once after another poll" "1" \
  "$(count_content 'feed-marker-ONE')"

scenario "dst-clipboard-untouched: feeding does NOT steal the DST session's clipboard"
# The founding constraint of this feeder (sp014): pushing into the history
# must never yank the clipboard out from under whoever is working on the
# native display.  `clipcatctl load`'s DEFAULT -k clipboard DOES exactly
# that, which is why clip-feed.sh uses -k secondary.  The MUTATION control in
# phase 4 proves this assertion is not vacuous.
# stdout redirected for the same reason as in probe_dst_watcher: xclip forks
# a child that keeps serving the selection, and that child would otherwise
# hold this script's stdout open — invisible until you pipe the suite's
# output somewhere and the pipe never closes.
printf 'DST-USER-SENTINEL' \
  | env DISPLAY="$DST" timeout 5 xclip -selection clipboard >/dev/null 2>&1
sleep 2
before="$(cc length)"
own_clipboard 'feed-marker-NOSTEAL'
wait_length_change "$before" 5 >/dev/null
sleep 1
assert_eq "the fed copy did land in history" "feed-marker-NOSTEAL" \
  "$(cc get "$(id_for_content 'feed-marker-NOSTEAL')" 2>/dev/null)"
assert_eq "DST CLIPBOARD still holds what the DST user put there" "DST-USER-SENTINEL" \
  "$(xsel_of "$DST" clipboard)"

scenario "capture-latency: the copy lands within a second"
before="$(cc length)"
own_clipboard 'feed-marker-LATENCY'
start_ns="$(date +%s%N)"
for i in $(seq 1 40); do
  [ "$(cc length 2>/dev/null)" != "$before" ] && break
  sleep 0.05
done
elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
assert_eq "the latency marker is in history" "feed-marker-LATENCY" \
  "$(cc get "$(id_for_content 'feed-marker-LATENCY')" 2>/dev/null)"
assert_eq "landed within 1000ms (took ${elapsed_ms}ms)" "true" \
  "$([ "$elapsed_ms" -lt 1000 ] && echo true || echo "false (${elapsed_ms}ms)")"

scenario "repeat-copy-deduped: re-owning with identical text adds nothing"
before="$(cc length)"
own_clipboard 'feed-marker-LATENCY'
sleep 3   # no length change is the expected outcome, so this cannot poll-and-exit
assert_eq "history length unchanged" "$before" "$(cc length)"
assert_eq "and the entry is still there exactly once" "1" \
  "$(count_content 'feed-marker-LATENCY')"

scenario "distinct-copy-after-repeat: a genuinely new copy still gets through"
before="$(cc length)"
own_clipboard 'feed-marker-TWO'
size="$(wait_length_change "$before" 5)"
assert_eq "history grew by one" "$((before + 1))" "$size"
assert_eq "the new copy is present, byte-exact" "feed-marker-TWO" \
  "$(cc get "$(id_for_content 'feed-marker-TWO')" 2>/dev/null)"

scenario "large-copy-fed: a 200 KB copy is carried whole"
# This is the scenario that forced `load -f` over `insert <DATA>`: insert
# puts the payload on argv, and Linux caps a single argv string at
# MAX_ARG_STRLEN (128 KiB), so this exact fixture fails at exec with
# "Argument list too long".  Measured, not assumed.
python3 -c "import sys; sys.stdout.write('BIGFEED' + 'B' * 200000)" >"$TMP/big.txt"
before="$(cc length)"
own_clipboard_file "$TMP/big.txt"
size="$(wait_length_change "$before" 15)"
assert_eq "history grew by one" "$((before + 1))" "$size"
big_id="$(id_for_preview_prefix 'BIGFEED')"
# `clipcatctl get` unconditionally appends exactly one trailing 0x0a to its
# output (egm.1 finding) -- the +1 below is that CLI artifact, not data loss.
assert_eq "stored byte count matches the source (+1 for get's trailing newline)" \
  "$(( $(wc -c <"$TMP/big.txt") + 1 ))" "$(cc get "$big_id" 2>/dev/null | wc -c)"

scenario "multiline-fed: a multi-line copy is carried across (see dotfiles-i9i)"
# KNOWN BACKEND LIMITATION, not a feeder bug: `clipcatctl get` irreversibly
# escapes embedded \n \r \t into literal two-character sequences
# (dotfiles-i9i, blocks dotfiles-egm.3).  So this asserts the escaped
# rendering, which is what the CLI can actually return.  Every byte-exactness
# assertion in this suite deliberately uses single-line fixtures for that
# reason; asserting raw multiline bytes through `get` would be asserting a
# known-false thing.
before="$(cc length)"
own_clipboard 'ml-line-one
ml-line-two'
size="$(wait_length_change "$before" 5)"
assert_eq "history grew by one" "$((before + 1))" "$size"
assert_eq "both lines were carried (rendered escaped by clipcatctl get)" \
  'ml-line-one\nml-line-two' \
  "$(cc get "$(id_for_preview_prefix 'ml-line-one')" 2>/dev/null)"

scenario "secret-not-laundered: a hint-bearing SRC copy never enters DST history"
# THIS FIXTURE IS NOT copyq-SPECIFIC and did not get dropped in the swap.
# It tests the FEEDER's first gate.  It matters MORE under clipcat, not less:
# a clipcatctl load bypasses the daemon's own sensitive_mime_types filter
# entirely (poc010 Q3), so on this path the feeder's two gates are the only
# thing between a password and the history.
before="$(cc length)"
own_clipboard 'SECRET-PASSWORD-marker' application/x-kde-passwordManagerHint
sleep 4
assert_eq "history length unchanged" "$before" "$(cc length)"
assert_eq "secret text appears in no history entry" "" "$(leaks 'SECRET-PASSWORD-marker')"
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
#
# Also not copyq-specific: nothing in it mentions a backend.
before="$(cc length)"
own_race_clipboard 'RACE-DECOY-benign' 'RACE-SECRET-marker'
sleep 4
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "history length unchanged" "$before" "$(cc length)"
assert_eq "raced secret appears in no history entry" "" "$(leaks 'RACE-SECRET-marker')"

scenario "image-skipped: a selection with no text target is not fed"
before="$(cc length)"
own_clipboard 'binary-image-marker' image/png
sleep 4
assert_eq "history length unchanged" "$before" "$(cc length)"
assert_eq "the image marker appears in no history entry" "" "$(leaks 'binary-image-marker')"

scenario "empty-selection-skipped: an owner holding an empty string adds no entry"
# Distinct from the image case, which xclip refuses outright: here the read
# succeeds with zero bytes.  This is what makes the feeder's -s check
# load-bearing -- and note it cannot be delegated to clipcat's own
# filter_text_min_length, which is a WATCHER-side filter this path bypasses.
before="$(cc length)"
own_clipboard ''
sleep 4
assert_eq "history length unchanged" "$before" "$(cc length)"

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

scenario "dst-daemon-unreachable: a feed fired at a dead daemon loses nothing"
# Edge case from the task: the DST daemon can be down when a copy happens.
# The feeder must not die, must not spin, must keep the single-instance lock
# (so the i3-reload restart path still behaves), and must feed the copy once
# the daemon is back.  It must also NOT mark the copy as fed -- $LAST is only
# updated on a successful feed, so the item is retried.
stop_server
own_clipboard 'feed-marker-WHILE-DST-DOWN'
before_j="$(cpu_jiffies "$FEED_PID")"
sleep 4
after_j="$(cpu_jiffies "$FEED_PID")"
assert_eq "feeder still alive with the daemon gone" "alive" \
  "$(kill -0 "$FEED_PID" 2>/dev/null && echo alive || echo dead)"
assert_eq "feeder did not busy-loop while feeds were failing (used $((after_j - before_j)) jiffies over 4s)" "true" \
  "$([ $((after_j - before_j)) -le 40 ] && echo true || echo "false ($((after_j - before_j)) jiffies)")"
# The lock is still held by the surviving feeder: a fresh instance must still
# refuse to start.  (If the failing feed had killed the feeder, or released
# the fd, this would come back "alive".)
start_feeder
sleep 1
assert_eq "the single-instance lock is still held" "exited" \
  "$(kill -0 "$FEED_PID" 2>/dev/null && echo alive || echo exited)"
FEED_PID="$(pgrep -f -- "$FEEDER" | head -1)"
start_server
size="$(wait_length_change 0 15)"
assert_eq "the copy made while DST was down is fed once DST returns" \
  "feed-marker-WHILE-DST-DOWN" \
  "$(cc get "$(id_for_content 'feed-marker-WHILE-DST-DOWN')" 2>/dev/null)"

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
before="$(cc length)"
own_clipboard 'feed-marker-AFTER-RESTART'
size="$(wait_length_change "$before" 15)"
assert_eq "history grew by one after SRC returned" "$((before + 1))" "$size"
assert_eq "the post-restart copy is present" "feed-marker-AFTER-RESTART" \
  "$(cc get "$(id_for_content 'feed-marker-AFTER-RESTART')" 2>/dev/null)"

scenario "start-with-src-absent: a feeder started before SRC exists still works"
stop_feeder
kill -9 "$SRC_PID" 2>/dev/null; wait "$SRC_PID" 2>/dev/null; SRC_PID=""
[ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; OWNER_PID=""; }
rm -f "/tmp/.X11-unix/X${SRC#:}"
start_feeder
assert_eq "feeder started cleanly with no SRC" "alive" \
  "$(kill -0 "$FEED_PID" 2>/dev/null && echo alive || echo dead)"
start_xvfb "$SRC" SRC_PID
before="$(cc length)"
own_clipboard 'feed-marker-COLD-START'
size="$(wait_length_change "$before" 15)"
assert_eq "the copy is captured once SRC appears" "$((before + 1))" "$size"
assert_eq "the cold-start copy is present" "feed-marker-COLD-START" \
  "$(cc get "$(id_for_content 'feed-marker-COLD-START')" 2>/dev/null)"

# ======================= PHASE 3: destination is named, never guessed =======

scenario "no-destination-refuses: the feeder will not run without a named socket"
# clipcat has no single well-known socket (clipcat/dot.yaml point 1) -- one
# clipcatd binds one socket and this host runs two.  Silently feeding the
# wrong session, or nowhere, is worse than refusing.
stop_feeder
rm -f "$TMP/feed.lock"
# Run in the FOREGROUND (this is the one place the feeder is expected to
# exit on its own) but under `timeout`: a feeder that wrongly proceeds into
# its poll loop would otherwise hang the suite forever instead of failing.
# rc 124 here means "did not refuse", which is exactly the failure to report.
timeout 10 env -u XDG_RUNTIME_DIR -u CLIP_FEED_DST_SOCKET DISPLAY=:77 \
    CLIP_FEED_LOCK="$TMP/feed-nosock.lock" \
    sh "$FEEDER" >"$TMP/nosock.out" 2>&1
rc=$?
assert_eq "exits 78 (EX_CONFIG), as clipcatd itself does on an unresolvable path" "78" "$rc"
assert_eq "and says what is missing" "yes" \
  "$(grep -q 'CLIP_FEED_DST_SOCKET' "$TMP/nosock.out" && echo yes || echo no)"

scenario "config-guards-the-no-steal-property: clipcat.toml keeps enable_secondary false"
# clip-feed.sh's -k secondary is only non-stealing because the DST daemon does
# not watch/own the SECONDARY selection.  If clipcat.toml ever enables it,
# the feeder would start yanking a selection again.  Asserted here so the
# coupling is caught in review rather than in daily use.
assert_eq "enable_secondary is false in the shipped config" "yes" \
  "$(grep -qE '^enable_secondary *= *false' "$REPO_DIR/../../clipcat/clipcat.toml" && echo yes || echo no)"
assert_eq "the feeder does feed with -k secondary" "yes" \
  "$(grep -qF 'load -k secondary' "$FEEDER" && echo yes || echo no)"

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
grep -qF -- "-qFx 'application/x-kde-passwordManagerHint'" "$TMP/clip-feed-nohint.sh" \
  && { echo "FATAL: patched feeder still contains the hint check" >&2; exit 1; }
grep -qF 'clipcatctl --server-endpoint' "$TMP/clip-feed-nohint.sh" \
  || { echo "FATAL: patched feeder lost its feed path" >&2; exit 1; }
rm -f "$TMP/feed.lock"
start_feeder "$TMP/clip-feed-nohint.sh"
before="$(cc length)"
own_clipboard 'SECRET-PASSWORD-marker' application/x-kde-passwordManagerHint
size="$(wait_length_change "$before" 10)"
assert_eq "hint-bearing copy IS fed when the check is absent" "$((before + 1))" "$size"
assert_eq "and its full text lands in DST history" "SECRET-PASSWORD-marker" \
  "$(cc get "$(id_for_content 'SECRET-PASSWORD-marker')" 2>/dev/null)"
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
grep -qF 'clipcatctl --server-endpoint' "$TMP/clip-feed-norecheck.sh" \
  || { echo "FATAL: patched feeder lost its feed path" >&2; exit 1; }
rm -f "$TMP/feed.lock"
start_feeder "$TMP/clip-feed-norecheck.sh"
before="$(cc length)"
own_race_clipboard 'RACE-DECOY-benign' 'RACE-SECRET-CONTROL'
size="$(wait_length_change "$before" 10)"
assert_eq "the handoff fired, so the race really was exercised" "fired" "$(race_fired)"
assert_eq "raced secret IS fed when the re-check is absent" "$((before + 1))" "$size"
assert_eq "and its full text lands in DST history" "RACE-SECRET-CONTROL" \
  "$(cc get "$(id_for_content 'RACE-SECRET-CONTROL')" 2>/dev/null)"
stop_feeder

scenario "MUTATION kind-clipboard-steals-the-DST-clipboard: the -k secondary choice is load-bearing"
# Proves the dst-clipboard-untouched assertion in phase 1 is not vacuous.
# Swap the ONE flag and the feeder starts yanking the DST session's clipboard
# on every copy made on SRC -- the exact behaviour `copyq add` was chosen over
# `copyq copy` to avoid, reintroduced by clipcatctl's DEFAULT kind.
stop_feeder
sed 's/load -k secondary/load -k clipboard/g' "$FEEDER" > "$TMP/clip-feed-kclip.sh"
grep -qF 'load -k secondary' "$TMP/clip-feed-kclip.sh" \
  && { echo "FATAL: patched feeder still feeds with -k secondary" >&2; exit 1; }
grep -qF 'load -k clipboard' "$TMP/clip-feed-kclip.sh" \
  || { echo "FATAL: patched feeder lost its feed path" >&2; exit 1; }
rm -f "$TMP/feed.lock"
printf 'DST-USER-SENTINEL-MUTATION' \
  | env DISPLAY="$DST" timeout 5 xclip -selection clipboard >/dev/null 2>&1
sleep 2
start_feeder "$TMP/clip-feed-kclip.sh"
before="$(cc length)"
own_clipboard 'feed-marker-STEALS'
wait_length_change "$before" 10 >/dev/null
sleep 1
assert_eq "the mutated feeder DOES steal the DST clipboard" "feed-marker-STEALS" \
  "$(xsel_of "$DST" clipboard)"
stop_feeder

scenario "CONTROL feeder-is-load-bearing: no capture at all with no feeder"
rm -f "$TMP/feed.lock"
before="$(cc length)"
own_clipboard 'no-feeder-running-marker'
sleep 4
assert_eq "history length unchanged with the feeder stopped" "$before" "$(cc length)"

# ------------------------------------------------------------------ result ---

printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
