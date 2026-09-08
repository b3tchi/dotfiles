#!/usr/bin/env bash
# test-clip-sync.sh — the PRIMARY<->CLIPBOARD mirror (clip-sync.sh), headless.
#
# WHY THIS SUITE EXISTS (dotfiles-rxlj).  clip-sync.sh shipped with neither a
# test nor the two guards every other script in the clip family carries, and
# both gaps bit in production on the same day:
#
#  * NO SEEDING.  The loop's last-seen state started EMPTY, so the very first
#    tick read PRIMARY, found it "changed" (anything differs from empty) and
#    published that stale selection over the CLIPBOARD — measured live: a
#    fresh Windows copy was replaced by an hours-old terminal selection one
#    second after the daemon came up.  That is the "paste gives old text"
#    report, and every restart of the loop reproduced it.  wsl.conf starts it
#    from `exec_always`, which re-runs on i3 `restart` ($mod+Shift+c) but NOT
#    on `reload` — probed on this host with a throwaway `exec_always ... touch
#    <marker>` overlay, whose marker a reload never created.
#  * NO DISPLAY ARGUMENT AND NO FLOCK.  The loop trusted an inherited
#    $DISPLAY and nothing stopped a second copy running.  A test-harness
#    instance left over on an Xvfb display (`DISPLAY=:89`) therefore OWNED
#    the job on a deployed machine while the real session's :10 selections
#    stopped mirroring entirely — invisible, because `pgrep clip-sync.sh`
#    still showed a live loop.  Every other script in the family (clip-store,
#    clip-img-bridge, clip-set, clip-feed) takes an explicit display and a
#    per-display flock precisely so this cannot happen.
#
# So the startup contract is asserted here as the FIRST scenario, and the
# "cannot be pointed at the wrong session" property is asserted by starting
# every loop with a deliberately WRONG inherited DISPLAY (`:77`, which does
# not exist) and passing the real one as an argument — the same instrument
# test-clip-store.sh uses.  A loop that trusts the environment syncs nothing
# and the whole suite goes red.
#
# WHICH SELECTION WINS AT STARTUP, AND WHY IT IS THE CLIPBOARD.  On the first
# tick the loop has observed no user action, so it cannot know which side is
# newer.  It must not guess in the direction that DESTROYS work: a CLIPBOARD
# entry is always an explicit copy, while PRIMARY is a side effect of merely
# dragging across text.  So the clipboard is authoritative at startup — it is
# published to PRIMARY, never overwritten by it — and after that first
# observation the ordinary last-writer-wins rule takes over.
#
# usage: i3/scripts/test-clip-sync.sh
# env:   XVFB=/path/to/Xvfb   TEST_DISPLAY=:95   KEEP_TMP=1
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Overridable ONLY so the mutation check below can point the suite at a
# deliberately broken copy; production and CI leave it unset.
SYNCSH="${SYNC_SH:-$REPO_DIR/clip-sync.sh}"
XVFB="${XVFB:-Xvfb}"
DPY="${TEST_DISPLAY:-:95}"

TMP="/tmp/clip-sync-test.$$"
RUN="$TMP/run"          # XDG_RUNTIME_DIR stand-in (where the flock lands)

PASS=0
FAIL=0

# ---------------------------------------------------------------- harness ---

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

assert_eq() { # <scenario> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

scenario() { printf '\n[%s]\n' "$1"; }

OWNERS=""   # pids of the xclip selection owners this suite forked

cleanup() {
  stop_loop
  local p
  for p in $OWNERS; do kill "$p" 2>/dev/null; done
  # The recorded pids are NOT enough: `xclip -i` forks a child to hold the
  # selection and the parent exits, so the surviving owner has a pid this
  # suite never saw.  Orphans matter here — they keep this run's stdout open,
  # which wedges any `... | tail` reading the suite, and they keep serving a
  # selection on the test display.  So owners are also reaped by their
  # DISPLAY, read from /proc: scoped to $DPY and NOTHING else, because a
  # blanket `pkill xclip` would strip the live session's clipboard owner
  # (the dotfiles-92w.5 scoping rule).
  for p in $(pgrep -x xclip 2>/dev/null); do
    grep -qx "DISPLAY=$DPY" <(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null) \
      && kill "$p" 2>/dev/null
  done
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

# Start an Xvfb on <display> and wait until it actually accepts connections.
# (Verbatim from test-clip-store.sh — including the wait for a stale
# /tmp/.X<n>-lock to go away, so the suite can be run twice back to back.)
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

# Start a sync loop.  DISPLAY is set to a display that does not exist: a loop
# that trusts the environment instead of its argument syncs nothing.  Extra
# args are appended to the script's own argv.
start_loop() { # [extra-arg ...]
  env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" \
      sh "$SYNCSH" "$@" >>"$TMP/loop.log" 2>&1 &
  LOOP_PID=$!
  sleep 2         # >= 2 poll intervals, so a seeding bug has shown itself
}

# Kill the loop and its children by pid lineage, never by name (the
# dotfiles-92w.5 scoping rule — a name match here would reach the PRODUCTION
# loop on the developer's own session).
stop_loop() {
  [ -n "${LOOP_PID:-}" ] || return 0
  local kids k
  kids="$(pgrep -P "$LOOP_PID" 2>/dev/null)"
  kill "$LOOP_PID" 2>/dev/null
  wait "$LOOP_PID" 2>/dev/null
  for k in $kids; do kill "$k" 2>/dev/null; done
  LOOP_PID=""
}

# Put <text> on selection <sel>, leaving a live owner behind (xclip -i forks
# and serves the selection until something else claims it).  Every owner pid
# is remembered so cleanup can reap it.
set_sel() { # <sel> <text>
  printf '%s' "$2" | env DISPLAY="$DPY" xclip -selection "$1" -i &
  OWNERS="$OWNERS $!"
  sleep 0.3
}

get_sel() { # <sel>
  timeout 2 env DISPLAY="$DPY" xclip -selection "$1" -o 2>/dev/null
}

# Own selection <sel> as an IMAGE (target image/png), the shape clip-set.sh
# publishes a picture pick with and qs-region.py a screenshot. Same live-owner
# discipline as set_sel: xclip forks and serves until something else claims it.
set_sel_img() { # <sel> <png-file>
  env DISPLAY="$DPY" xclip -selection "$1" -t image/png -i < "$2" &
  OWNERS="$OWNERS $!"
  sleep 0.3
}

# The target list the current owner of <sel> advertises, space separated.
targets_of() { # <sel>
  timeout 2 env DISPLAY="$DPY" xclip -selection "$1" -t TARGETS -o 2>/dev/null | tr '\n' ' '
}

# What an IMAGE-unaware consumer gets: the first bytes of a plain text read.
# xclip-as-owner answers any target with its payload, so this is how the raw
# PNG reached a paste in the first place (dotfiles-9i56).
first_bytes() { # <sel>
  timeout 2 env DISPLAY="$DPY" xclip -selection "$1" -o 2>/dev/null | head -c 4 | od -An -c | tr -s ' '
}

# How many loops are alive under $SYNCSH — counted from /proc, scoped to the
# full script path so a production loop at ~/.i3/scripts/clip-sync.sh is
# never mistaken for one of this suite's.
loop_count() {
  local n=0 p cmd
  for p in $(pgrep -f 'clip-sync\.sh' 2>/dev/null); do
    [ -r "/proc/$p/cmdline" ] || continue   # exited between pgrep and this read
    cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
    case "$cmd" in *"$SYNCSH"*) n=$((n + 1)) ;; esac
  done
  printf '%s\n' "$n"
}

# ------------------------------------------------------------------- setup ---

command -v "$XVFB" >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=)" >&2; exit 1; }
command -v xclip >/dev/null 2>&1 || { echo "FATAL: xclip not found" >&2; exit 1; }

mkdir -p "$RUN" || exit 1
chmod 700 "$RUN"
[ -r "$SYNCSH" ] || { echo "FATAL: $SYNCSH not readable" >&2; exit 1; }

start_xvfb "$DPY" XVFB_PID

# ------------------------------------------- the startup contract (rxlj) ---

scenario "startup: a stale PRIMARY must not clobber a newer CLIPBOARD"

set_sel primary   "STALE-PRIMARY-from-an-old-drag"
set_sel clipboard "FRESH-CLIPBOARD-an-explicit-copy"
start_loop "$DPY"

assert_eq "the explicit copy survives the loop coming up" \
  "FRESH-CLIPBOARD-an-explicit-copy" "$(get_sel clipboard)"
assert_eq "and PRIMARY converges onto it (clipboard is authoritative at startup)" \
  "FRESH-CLIPBOARD-an-explicit-copy" "$(get_sel primary)"
assert_eq "loop is running" "alive" \
  "$(kill -0 "$LOOP_PID" 2>/dev/null && echo alive || echo dead)"

# ------------------------------------------------ ordinary mirroring still ---

scenario "live: a CLIPBOARD change propagates to PRIMARY"

set_sel clipboard "copied-second"
sleep 2
assert_eq "PRIMARY follows the copy" "copied-second" "$(get_sel primary)"
assert_eq "CLIPBOARD unchanged by the mirror" "copied-second" "$(get_sel clipboard)"

scenario "live: a PRIMARY change propagates to CLIPBOARD"

set_sel primary "selected-third"
sleep 2
assert_eq "CLIPBOARD follows the selection" "selected-third" "$(get_sel clipboard)"
assert_eq "PRIMARY unchanged by the mirror" "selected-third" "$(get_sel primary)"

stop_loop

# ----------------------------------------- images are not text (dotfiles-9i56) ---
# THE MIRROR MUST NOT LAUNDER A PICTURE INTO TEXT. `get` is a bare `xclip -o`,
# and xclip-as-owner answers ANY target request with its payload — so a text
# read of an image/png selection hands back the raw PNG file, and `put`ting
# that on the other selection creates a UTF8_STRING whose content is a PNG.
# Measured on the deployed :10 session before the fix: a $mod+v picture pick
# was image/png at t+1s and UTF8_STRING for good at t+2s, one poll interval
# later, so every paste produced the literal bytes "\211PNG\r\n" and every
# check that ran immediately after the publish passed.
#
# A 1x1 PNG is enough: what is asserted is the TARGET the selection carries,
# never the pixels.
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==' \
  | base64 -d > "$TMP/one.png"
assert_eq "fixture is a real PNG" " 211 P N G" "$(head -c 4 "$TMP/one.png" | od -An -c | tr -s ' ')"

scenario "image: an image/png CLIPBOARD is left alone, not republished as text"

set_sel primary   "TEXT-PRIMARY-before-the-image"
set_sel clipboard "TEXT-CLIPBOARD-before-the-image"
start_loop "$DPY"
set_sel_img clipboard "$TMP/one.png"
sleep 3           # >= 4 poll intervals: the clobber landed within one

assert_eq "CLIPBOARD still advertises the image target" "yes" \
  "$(case "$(targets_of clipboard)" in *image/png*) echo yes ;; *) echo no ;; esac)"
assert_eq "CLIPBOARD does NOT advertise a text target" "no" \
  "$(case "$(targets_of clipboard)" in *UTF8_STRING*|*' STRING '*) echo yes ;; *) echo no ;; esac)"
# The PRIMARY side is where the laundering showed up first: the mirror read the
# image as text and wrote those bytes onto the other selection. Asserted on the
# FIRST BYTES rather than the whole value, for two reasons: the startup seed is
# entitled to have replaced PRIMARY's own text with the CLIPBOARD's (that is
# the documented clipboard-authoritative seed), and a command substitution
# carrying real PNG bytes drops NULs with a warning, so a full compare would
# report the failure in a mangled form. Either text marker starts "TEXT"; the
# clobber starts "\211PNG".
assert_eq "PRIMARY still holds text, not the PNG bytes" " T E X T" \
  "$(first_bytes primary)"

scenario "image: a real text copy after an image still mirrors (the skip must not wedge the loop)"

set_sel clipboard "TEXT-AFTER-THE-IMAGE"
sleep 2
assert_eq "PRIMARY follows the text copy" "TEXT-AFTER-THE-IMAGE" "$(get_sel primary)"
assert_eq "CLIPBOARD unchanged by the mirror" "TEXT-AFTER-THE-IMAGE" "$(get_sel clipboard)"

scenario "image: an image on PRIMARY is left alone too"

set_sel clipboard "TEXT-CLIPBOARD-second-round"
sleep 2
set_sel_img primary "$TMP/one.png"
sleep 3
assert_eq "PRIMARY still advertises the image target" "yes" \
  "$(case "$(targets_of primary)" in *image/png*) echo yes ;; *) echo no ;; esac)"
assert_eq "CLIPBOARD still holds text, not the PNG bytes" " T E X T" \
  "$(first_bytes clipboard)"
assert_eq "and it is still the copy that was there" "TEXT-CLIPBOARD-second-round" \
  "$(get_sel clipboard)"

stop_loop

# ------------------------------------------------------ which session (rxlj) ---

scenario "display: the loop serves its ARGUMENT, not the inherited DISPLAY"

# start_loop always exports DISPLAY=:77 (nonexistent).  The mirroring proven
# above therefore already required the argument to win; this scenario pins the
# converse — no argument and no env override is a loud refusal, not a silent
# loop syncing some other session.
# `timeout` is what keeps a REGRESSION from hanging the suite instead of
# reporting: a loop that does not refuse never returns, and an unbounded call
# here would look like a broken harness rather than the bug it is.  124 is
# timeout's own "still running" code and reads as the failure it is.
timeout 5 env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" sh "$SYNCSH" >"$TMP/nodpy.out" 2>&1
assert_eq "a bare call exits 78 (EX_CONFIG), like clip-store.sh" "78" "$?"
assert_eq "and says why" "yes" \
  "$(grep -qi 'display' "$TMP/nodpy.out" && echo yes || echo no)"

scenario "display: CLIP_SYNC_DISPLAY is accepted as the alternative to \$1"

env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" CLIP_SYNC_DISPLAY="$DPY" \
    sh "$SYNCSH" >>"$TMP/loop.log" 2>&1 &
LOOP_PID=$!
sleep 2
set_sel clipboard "env-routed"
sleep 2
assert_eq "the env-routed loop mirrors on the right display" "env-routed" "$(get_sel primary)"
stop_loop

# --------------------------------------------------- single instance (rxlj) ---

scenario "single-instance: a second loop on the same display exits 0 and does not run"

start_loop "$DPY"
first="$(loop_count)"
# Bounded for the same reason as the bare call above: without the guard, a
# loop that does not take a lock simply runs forever here.
timeout 5 env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" sh "$SYNCSH" "$DPY" >"$TMP/second.out" 2>&1
assert_eq "the loser exits 0 (an i3 reload re-running the autostart is normal)" "0" "$?"
assert_eq "and no second loop is left behind" "$first" "$(loop_count)"
assert_eq "the incumbent is still alive" "alive" \
  "$(kill -0 "$LOOP_PID" 2>/dev/null && echo alive || echo dead)"

scenario "single-instance: the lock is not held past the loop's death"

stop_loop
sleep 0.5
start_loop "$DPY"
assert_eq "a fresh loop can take the lock again" "alive" \
  "$(kill -0 "$LOOP_PID" 2>/dev/null && echo alive || echo dead)"
set_sel clipboard "after-restart"
sleep 2
assert_eq "and it mirrors" "after-restart" "$(get_sel primary)"
stop_loop

# -------------------------------------------------------------------- done ---

printf '\n%s\n' "-------------------------------------------------"
printf 'PASS %s   FAIL %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
