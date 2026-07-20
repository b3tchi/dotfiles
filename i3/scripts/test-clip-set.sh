#!/usr/bin/env bash
# test-clip-set.sh — verify i3/scripts/clip-set.sh (dotfiles-92w.3).
#
# Runs entirely headless on its own pair of Xvfb displays with an isolated
# XDG_CONFIG_HOME, so it never touches the live X session, the live clipboard,
# or the real ~/.config/copyq.
#
# WHAT IS ACTUALLY OBSERVED (no "it exited 0" assertions)
#
#   clip-set.sh publishes an entry to every live display. So the observation
#   is made from the *outside*, on each display independently: what do
#   CLIPBOARD and PRIMARY on :93 and on :94 serve back, byte for byte, after
#   the script ran? Exit status is asserted only where the contract is about
#   exit status (the guard cases), and there it is always paired with an
#   assertion that the selections were left alone.
#
#   TWO displays are up for every scenario. That is not decoration: with a
#   single display, "set the clipboard on the one display" and "set it on all
#   of them" are indistinguishable, and the bug this suite exists to prevent
#   (enumeration order deciding which session gets the entry) cannot be seen.
#   Every content scenario asserts on BOTH displays, so a mutant that drops
#   the second write -- or the first -- fails an assertion.
#
# usage: i3/scripts/test-clip-set.sh
# env:   COPYQ=/path/to/copyq  XVFB=/path/to/Xvfb   (default: from PATH)
#        TEST_DISPLAY=:93 TEST_DISPLAY2=:94
#        CLIP_SET=/path/to/clip-set.sh              (default: alongside this)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLIP_SET="${CLIP_SET:-$SCRIPT_DIR/clip-set.sh}"
COPYQ="${COPYQ:-copyq}"
XVFB="${XVFB:-Xvfb}"
DPY="${TEST_DISPLAY:-:93}"
DPY2="${TEST_DISPLAY2:-:94}"

TMP="/tmp/clip-set-test.$$"     # kept short: copyq's socket lives under $CFG
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
  [ -n "${SERVER_STARTED:-}" ] && cq exit >/dev/null 2>&1
  sleep 1
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  [ -n "${XVFB2_PID:-}" ] && kill "$XVFB2_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

cq() { env DISPLAY="$DPY" XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" \
           XDG_CACHE_HOME="$CCH" "$COPYQ" "$@"; }

# clip-set.sh under test. XDG_* are exported for the *harness's* isolation
# (the script itself still calls a plain `copyq`, per copyq/dot.yaml's client
# contract). DISPLAY is deliberately exported WRONG -- an inherited DISPLAY
# must never be trusted, and :987 does not exist, so anything that reached a
# selection got there by enumerating sockets, not by inheriting.
run_set_in() { # <socket-dir> <args...>
  local dir="$1"; shift
  env DISPLAY=:987 XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" \
      XDG_CACHE_HOME="$CCH" CLIP_SET_SOCKET_DIR="$dir" \
      sh "$CLIP_SET" "$@" 2>"$TMP/set.err"
}

run_set() { run_set_in "$TMP/x11" "$@"; }

sel_on() { # <display> <clipboard|primary>
  env DISPLAY="$1" timeout 10 xclip -selection "$2" -o 2>/dev/null
}

# Take ownership of both selections on both displays away from whatever the
# previous scenario left behind, so no assertion can pass on a stale selection
# and "nothing was written" is a statement about a known prior value.
SENTINEL='SENTINEL-nothing-set'
reset_selections() {
  local d
  for d in "$DPY" "$DPY2"; do
    printf '%s' "$SENTINEL" | env DISPLAY="$d" timeout 5 xclip -selection clipboard -i
    printf '%s' "$SENTINEL" | env DISPLAY="$d" timeout 5 xclip -selection primary -i
  done
  sleep 0.5
}

# Assert all four selections still hold the sentinel -- i.e. the run under
# test performed ZERO selection writes.
assert_untouched() { # <label>
  assert_eq "$1: $DPY clipboard untouched"  "$SENTINEL" "$(sel_on "$DPY" clipboard)"
  assert_eq "$1: $DPY primary untouched"    "$SENTINEL" "$(sel_on "$DPY" primary)"
  assert_eq "$1: $DPY2 clipboard untouched" "$SENTINEL" "$(sel_on "$DPY2" clipboard)"
  assert_eq "$1: $DPY2 primary untouched"   "$SENTINEL" "$(sel_on "$DPY2" primary)"
}

# Assert the entry landed on BOTH displays, both selections. This is the
# assertion that kills a dropped-second-display mutant.
assert_on_both() { # <label> <expected>
  assert_eq "$1: $DPY clipboard"  "$2" "$(sel_on "$DPY" clipboard)"
  assert_eq "$1: $DPY primary"    "$2" "$(sel_on "$DPY" primary)"
  assert_eq "$1: $DPY2 clipboard" "$2" "$(sel_on "$DPY2" clipboard)"
  assert_eq "$1: $DPY2 primary"   "$2" "$(sel_on "$DPY2" primary)"
}

# Block until the copyq history stops growing. Every clipboard write this
# harness makes (the sentinel reset, and the run under test itself) is a
# genuine clipboard change that the running server captures and PREPENDS --
# so row numbers move under our feet unless we wait for capture to finish
# before deciding which row to address. (Getting this wrong is a silent
# wrong-row test, not an error.)
settle() {
  local prev="" n i
  for i in $(seq 1 40); do
    n="$(cq size 2>/dev/null)"
    [ -n "$n" ] && [ "$n" = "$prev" ] && return 0
    prev="$n"
    sleep 0.5
  done
}

# Clear the selections, let capture settle, then push <text...> onto the
# history so the LAST argument is row 0. `copyq add` does not touch the
# clipboard, so this cannot itself perturb the row numbering. (`copyq copy`
# would be a false-pass trap here: copyq ignores clipboard changes it owns.)
arm() {
  reset_selections
  settle
  local t
  for t in "$@"; do cq add "$t" >/dev/null; done
}

# arm() for an entry too large to survive argv (`copyq add "$(cat 1mb)"` dies
# with E2BIG). copyq's own scripting reads the payload off stdin instead.
arm_file() {
  reset_selections
  settle
  cq eval -- 'add(str(input()))' < "$1" >/dev/null
}

# ---------------------------------------------------------------- fixtures ---

mkdir -p "$TMP" "$CFG/copyq" "$DAT" "$CCH"

command -v "$COPYQ" >/dev/null 2>&1 || { echo "FATAL: copyq not found (set COPYQ=)" >&2; exit 1; }
command -v "$XVFB"  >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=)"  >&2; exit 1; }
command -v xclip    >/dev/null 2>&1 || { echo "FATAL: xclip not found" >&2; exit 1; }
[ -r "$CLIP_SET" ] || { echo "FATAL: $CLIP_SET not readable" >&2; exit 1; }

"$XVFB" "$DPY" -screen 0 800x600x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 20); do
  [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break
  sleep 0.5
done
[ -e "/tmp/.X11-unix/X${DPY#:}" ] || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

"$XVFB" "$DPY2" -screen 0 800x600x24 >"$TMP/xvfb2.log" 2>&1 &
XVFB2_PID=$!
for i in $(seq 1 20); do
  [ -e "/tmp/.X11-unix/X${DPY2#:}" ] && break
  sleep 0.5
done
[ -e "/tmp/.X11-unix/X${DPY2#:}" ] || { echo "FATAL: Xvfb $DPY2 did not start" >&2; exit 1; }

# The controlled socket directory handed to clip-set.sh via
# CLIP_SET_SOCKET_DIR. Symlinks, not copies -- the script only reads the NAMES
# to build ":93" / ":94"; the X connection itself still goes through the real
# socket. This keeps the host's live :0 / :10 out of the test.
mkdir -p "$TMP/x11"
ln -sf "/tmp/.X11-unix/X${DPY#:}"  "$TMP/x11/X${DPY#:}"
ln -sf "/tmp/.X11-unix/X${DPY2#:}" "$TMP/x11/X${DPY2#:}"

# An empty socket dir, and one holding nothing but a dead socket name.
mkdir -p "$TMP/x11-empty" "$TMP/x11-dead"
: > "$TMP/x11-dead/X95"

echo "clip-set: $CLIP_SET"
echo "copyq:    $("$COPYQ" --version 2>/dev/null | head -1)"
echo "displays: $DPY $DPY2"

# =============================== copyq server, seeded history ================

ln -s "$SCRIPT_DIR/../../copyq/copyq.conf" "$CFG/copyq/copyq.conf" 2>/dev/null
ln -s "$SCRIPT_DIR/../../copyq/commands.ini" "$CFG/copyq/copyq-commands.ini" 2>/dev/null
cq --start-server >"$TMP/server.log" 2>&1 &
for i in $(seq 1 40); do
  cq eval 1 >/dev/null 2>&1 && { SERVER_STARTED=1; break; }
  sleep 0.5
done
[ -n "${SERVER_STARTED:-}" ] || { echo "FATAL: copyq server did not start" >&2; cat "$TMP/server.log" >&2; exit 1; }

PLAIN='plain-entry-marker'
MULTI='first line
  second line with  spaces
third'
UNI='héllo → 世界 🎉 ünïcodé'

# ====================== PHASE 1: the entry reaches EVERY live display ========

scenario "both-displays: the entry lands on CLIPBOARD+PRIMARY of both sessions"
arm "$PLAIN"
run_set 0; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_on_both "plain entry" "$PLAIN"

scenario "row-addressing: an entry deeper in the history is the one published"
arm "$MULTI" "$UNI" "$PLAIN"     # rows: 0=PLAIN 1=UNI 2=MULTI
assert_eq "row 0 is the newest add" "$PLAIN" "$(cq read 0)"
assert_eq "row 2 is the oldest add" "$MULTI" "$(cq read 2)"
run_set 2; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_on_both "row 2, not row 0" "$MULTI"

scenario "multiline: newlines and interior spacing survive to both displays"
arm "$MULTI"
run_set 0
assert_on_both "multiline entry" "$MULTI"
# MULTI is 3 lines with no trailing newline, so exactly 2 newline bytes must
# be present -- a selection that flattened or doubled them fails here.
assert_eq "$DPY newline count preserved" "2" \
  "$(sel_on "$DPY" clipboard | tr -cd '\n' | wc -c | tr -d ' ')"
assert_eq "$DPY2 newline count preserved" "2" \
  "$(sel_on "$DPY2" clipboard | tr -cd '\n' | wc -c | tr -d ' ')"

scenario "unicode: multibyte text and emoji are not mangled on either display"
arm "$UNI"
run_set 0
assert_on_both "unicode entry" "$UNI"
assert_eq "$DPY byte length preserved" "$(printf '%s' "$UNI" | wc -c | tr -d ' ')" \
  "$(sel_on "$DPY" clipboard | wc -c | tr -d ' ')"
assert_eq "$DPY2 byte length preserved" "$(printf '%s' "$UNI" | wc -c | tr -d ' ')" \
  "$(sel_on "$DPY2" clipboard | wc -c | tr -d ' ')"

scenario "huge-entry: a 1 MB entry transfers whole (INCR) to both displays"
head -c 1000000 /dev/zero | tr '\0' 'H' > "$TMP/big.txt"
arm_file "$TMP/big.txt"
assert_eq "1 MB entry is in history at row 0" "1000000" "$(cq read 0 | wc -c | tr -d ' ')"
run_set 0; rc=$?
assert_eq "exits 0" "0" "$rc"
for d in "$DPY" "$DPY2"; do
  for s in clipboard primary; do
    assert_eq "$d $s holds all 1000000 bytes" "1000000" \
      "$(sel_on "$d" "$s" | wc -c | tr -d ' ')"
  done
done

# ======================= PHASE 2: displays that are not there ================

scenario "dead-socket-among-live: a stale socket name is skipped, not fatal"
# x11-mixed enumerates :93, :94 AND a :95 whose "socket" is a plain file no X
# server is behind. The run must still succeed on the two real ones.
mkdir -p "$TMP/x11-mixed"
ln -sf "/tmp/.X11-unix/X${DPY#:}"  "$TMP/x11-mixed/X${DPY#:}"
ln -sf "/tmp/.X11-unix/X${DPY2#:}" "$TMP/x11-mixed/X${DPY2#:}"
: > "$TMP/x11-mixed/X95"
arm "$PLAIN"
run_set_in "$TMP/x11-mixed" 0; rc=$?
assert_eq "exits 0 despite the dead display" "0" "$rc"
assert_on_both "with a dead socket present" "$PLAIN"

scenario "no-display-at-all: an empty socket dir is a clean exit 1"
arm "$PLAIN"
run_set_in "$TMP/x11-empty" 0; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "reason names the missing display" "yes" \
  "$(grep -qi 'no live X display' "$TMP/set.err" && echo yes || echo no)"
assert_untouched "no-display"

scenario "only-dead-displays: sockets with no server behind them are exit 1"
arm "$PLAIN"
run_set_in "$TMP/x11-dead" 0; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "reason names the missing display" "yes" \
  "$(grep -qi 'no live X display' "$TMP/set.err" && echo yes || echo no)"
assert_untouched "only-dead"

# ================================= PHASE 3: argument + row edge cases ========
#
# Every one of these must be exit 1 specifically -- exit 1 is the code that
# promises the clipboard was not touched, and task .4 builds against that.

scenario "bad-row: a non-numeric row is refused before anything is written"
arm "$PLAIN"
run_set abc; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "explains itself" "yes" \
  "$(grep -qi 'non-negative integer' "$TMP/set.err" && echo yes || echo no)"
assert_untouched "bad-row"

scenario "missing-row: no argument at all is refused"
arm "$PLAIN"
run_set; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "prints usage" "yes" \
  "$(grep -qi 'usage' "$TMP/set.err" && echo yes || echo no)"
assert_untouched "missing-row"

scenario "out-of-range-row: a row past the end of history writes nothing"
arm "$PLAIN"
run_set 9999; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_untouched "out-of-range"

scenario "empty-entry: an empty history row does not blank the clipboard"
reset_selections
settle
cq add "" >/dev/null 2>&1 || true
assert_eq "row 0 really is the empty entry" "" "$(cq read 0)"
run_set 0; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "reason names the empty row" "yes" \
  "$(grep -qi 'empty or does not exist' "$TMP/set.err" && echo yes || echo no)"
assert_untouched "empty-entry"

# ============ PHASE 4: a display disappearing underneath us (destructive) ====
#
# Last, because it tears $DPY2 down for good.

scenario "surviving-display: one session dying does not stop the other"
arm "$PLAIN"
kill "$XVFB2_PID" 2>/dev/null
wait "$XVFB2_PID" 2>/dev/null
XVFB2_PID=""
for i in $(seq 1 20); do
  env DISPLAY="$DPY2" timeout 2 xclip -selection clipboard -o >/dev/null 2>&1 || break
  sleep 0.5
done
assert_eq "$DPY2 really is gone" "gone" \
  "$(env DISPLAY="$DPY2" timeout 2 xclip -selection clipboard -o >/dev/null 2>&1 && echo alive || echo gone)"
run_set 0; rc=$?
assert_eq "exits 0 on the survivor alone" "0" "$rc"
assert_eq "$DPY clipboard holds the entry" "$PLAIN" "$(sel_on "$DPY" clipboard)"
assert_eq "$DPY primary holds the entry" "$PLAIN" "$(sel_on "$DPY" primary)"

# ------------------------------------------------------------------ result ---

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
