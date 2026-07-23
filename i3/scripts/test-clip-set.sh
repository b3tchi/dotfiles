#!/usr/bin/env bash
# test-clip-set.sh — verify i3/scripts/clip-set.sh against the file-store
# backend (sp016 task 3, adapted from sp014 task 3 / dotfiles-92w.3).
#
# Runs entirely headless on its own pair of Xvfb displays with an isolated
# XDG_RUNTIME_DIR, so it never touches the live X session, the live
# clipboard, or the real $XDG_RUNTIME_DIR/clip-store.
#
# SEEDING = WRITING STORE FILES DIRECTLY. There is no daemon and no server to
# seed through (that was the whole point of the pivot away from clipcat): an
# entry is a file named "NNNNNN.clip" under
# $XDG_RUNTIME_DIR/clip-store/<display>/, so this harness creates that
# directory and drops files into it exactly as clip-store.sh (task 6) would
# have, then asks clip-set.sh to publish one of them by id.
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
#   Byte-exact comparisons that could be corrupted by shell command
#   substitution (trailing-newline stripping in particular -- the exact
#   defect class this task exists to fix, dotfiles-i9i) go through FILES,
#   never through a captured variable: xclip -o is redirected straight to a
#   file and `cmp`d against the seed file. Short plain-text markers with no
#   trailing whitespace are the only content compared via variables, as
#   before.
#
# usage: i3/scripts/test-clip-set.sh
# env:   XVFB=/path/to/Xvfb                        (default: from PATH)
#        TEST_DISPLAY=:93 TEST_DISPLAY2=:94
#        CLIP_SET=/path/to/clip-set.sh              (default: alongside this)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLIP_SET="${CLIP_SET:-$SCRIPT_DIR/clip-set.sh}"
XVFB="${XVFB:-Xvfb}"
DPY="${TEST_DISPLAY:-:93}"
DPY2="${TEST_DISPLAY2:-:94}"

TMP="/tmp/clip-set-test.$$"
XDGRUN="$TMP/xdgrun"           # isolated $XDG_RUNTIME_DIR -- never the real one

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
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  [ -n "${XVFB2_PID:-}" ] && kill "$XVFB2_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

sel_on() { # <display> <clipboard|primary>
  env DISPLAY="$1" timeout 10 xclip -selection "$2" -o 2>/dev/null
}

# Same as sel_on but to a FILE, byte for byte, for comparisons a variable
# capture would corrupt (trailing newlines, a bare single newline).
sel_to_file() { # <display> <clipboard|primary> <outfile>
  env DISPLAY="$1" timeout 10 xclip -selection "$2" -o > "$3" 2>/dev/null
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

# ------------------------------------------------------------ store seeding ---
#
# The next seq per source display is derived from the directory itself
# (highest existing NNNNNN.clip, +1) -- the same rule clip-store.sh's own
# newest_entry/store_write use -- rather than a counter kept in a shell
# variable. seed_content is always called as `id="$(seed_content ...)"`,
# i.e. inside a command substitution, which forks a SUBSHELL: a counter
# updated there is invisible to the parent shell the moment the subshell
# exits, so every call would see seq 0 again and every id would collide on
# 000001.clip (caught by this suite's own first draft -- the id-addressing
# scenario silently published the wrong entry because the "second" seed
# clobbered the first at the same filename). Reading the directory is
# stateless and immune to that.
store_dir() { printf '%s/clip-store/%s' "$XDGRUN" "$1"; }

# Write <content-file>'s bytes, exactly, as the next entry in <display>'s
# store. Prints the id (e.g. "000003.clip") used.
seed_content() { # <display> <content-file>
  local dpy="$1" src="$2" dir last f b n id
  dir="$(store_dir "$dpy")"
  mkdir -p "$dir"
  last=""
  for f in "$dir"/[0-9][0-9][0-9][0-9][0-9][0-9].clip; do
    [ -e "$f" ] && last="$f"
  done
  if [ -n "$last" ]; then
    b="${last##*/}"; b="${b%.clip}"
    n=$((10#$b + 1))
  else
    n=1
  fi
  id="$(printf '%06d.clip' "$n")"
  cp "$src" "$dir/$id"
  printf '%s' "$id"
}

# ------------------------------------------------------------- invocation ---
#
# clip-set.sh under test.
#
#   CLIP_SET_ENV_DISPLAY  -- what $DISPLAY the script inherits. Set WRONG
#     (:987, which does not exist) by default for every scenario: an
#     inherited DISPLAY must never be trusted for the WRITE fan-out (that
#     half of the design is unchanged from sp014), so anything that reached
#     a selection got there by enumerating sockets, not by inheriting.
#   CLIP_SET_ENV_SRC      -- CLIP_SET_SRC_DISPLAY override, i.e. which
#     store the id is read FROM. Defaults to $DPY (this suite's stand-in for
#     "the session the picker derived"). Empty string = do not set the
#     override at all -- used by scenarios proving the $2 positional
#     argument works on its own, and by the one proving that omitting BOTH
#     the override and the argument is a hard refusal ($DISPLAY is never
#     consulted as a fallback -- see clip-set.sh's own header).
#   CLIP_SET_ENV_XDG      -- $XDG_RUNTIME_DIR value. "UNSET" is a sentinel
#     meaning: do not export it at all (the one scenario that needs this).
CLIP_SET_ENV_DISPLAY=":987"
CLIP_SET_ENV_SRC="$DPY"
CLIP_SET_ENV_XDG="$XDGRUN"

run_set_in() { # <socket-dir> <id...>
  local dir="$1"; shift
  local -a envargs=(DISPLAY="$CLIP_SET_ENV_DISPLAY" CLIP_SET_SOCKET_DIR="$dir")
  [ -n "$CLIP_SET_ENV_SRC" ] && envargs+=(CLIP_SET_SRC_DISPLAY="$CLIP_SET_ENV_SRC")
  if [ "$CLIP_SET_ENV_XDG" = "UNSET" ]; then
    env -u XDG_RUNTIME_DIR "${envargs[@]}" sh "$CLIP_SET" "$@" 2>"$TMP/set.err"
  else
    envargs+=(XDG_RUNTIME_DIR="$CLIP_SET_ENV_XDG")
    env "${envargs[@]}" sh "$CLIP_SET" "$@" 2>"$TMP/set.err"
  fi
}
run_set() { run_set_in "$TMP/x11" "$@"; }

# ---------------------------------------------------------------- fixtures ---

mkdir -p "$TMP" "$XDGRUN"

command -v "$XVFB" >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=)"  >&2; exit 1; }
command -v xclip   >/dev/null 2>&1 || { echo "FATAL: xclip not found" >&2; exit 1; }
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

# A display number that is NOT live -- checked at runtime, not hardcoded.
# Sibling suites in this same spec (test-clip-store.sh :96, test-clip-history
# .sh :95/:96, test-clip-feed.sh :97/:98) run their own Xvfb on fixed numbers
# and may be executing concurrently on the same host, so a hardcoded "dead"
# number picked without checking can turn out to be very much alive on any
# given run -- this suite hit exactly that flakily (a real Xvfb was up on
# :95 from a sibling's run while this hardcoded :95 as its own dead filler).
# Scanned well clear of the low numbers every suite in this repo uses.
DEAD_NUM=195
while [ -e "/tmp/.X11-unix/X$DEAD_NUM" ] || [ -e "/tmp/.X${DEAD_NUM}-lock" ]; do
  DEAD_NUM=$((DEAD_NUM + 1))
done

# An empty socket dir, and one holding nothing but a dead socket name.
mkdir -p "$TMP/x11-empty" "$TMP/x11-dead"
: > "$TMP/x11-dead/X$DEAD_NUM"

echo "clip-set: $CLIP_SET"
echo "displays: $DPY $DPY2"
echo "xdg-runtime (isolated): $XDGRUN"

PLAIN='plain-entry-marker'
UNI='héllo → 世界 🎉 ünïcodé'

printf '%s' "$PLAIN" > "$TMP/plain.src"
printf '%s' "$UNI"   > "$TMP/uni.src"

# =============================== PHASE 1: byte-exact publish to both =========

scenario "both-displays-byte-exact: the entry lands on CLIPBOARD+PRIMARY of both sessions"
reset_selections
ID="$(seed_content "$DPY" "$TMP/plain.src")"
run_set "$ID"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_on_both "plain entry" "$PLAIN"

scenario "id-addressing: a specific id, not just the latest seeded one, is the one published"
reset_selections
A="$(seed_content "$DPY" "$TMP/plain.src")"
printf 'a-different-entry' > "$TMP/other.src"
B="$(seed_content "$DPY" "$TMP/other.src")"
# B is the newer seq; ask for A anyway.
run_set "$A"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_on_both "the requested id, not the newest" "$PLAIN"

scenario "multiline-byte-exact-round-trip: embedded real newlines and spacing survive whole"
reset_selections
printf '%s' $'first line\n  second line with  spaces\nthird' > "$TMP/multi.src"
ID="$(seed_content "$DPY" "$TMP/multi.src")"
run_set "$ID"; rc=$?
assert_eq "exits 0" "0" "$rc"
for d in "$DPY" "$DPY2"; do
  for s in clipboard primary; do
    sel_to_file "$d" "$s" "$TMP/multi.$d.$s.out"
    assert_eq "$d $s matches the seed file exactly" "same" \
      "$(cmp -s "$TMP/multi.src" "$TMP/multi.$d.$s.out" && echo same || echo DIFFERENT)"
  done
done
assert_eq "$DPY newline count preserved" "2" \
  "$(tr -cd '\n' < "$TMP/multi.$DPY.clipboard.out" | wc -c | tr -d ' ')"

scenario "literal-backslash-n-distinct-from-newline: a two-char backslash-n and a real newline publish distinctly"
reset_selections
printf '\\n' > "$TMP/litbs.src"    # two bytes: 0x5C 0x6E ("\" "n")
printf '\n'   > "$TMP/realnl.src"  # one byte:  0x0A
assert_eq "seed sanity: literal backslash-n is 2 bytes" "2" \
  "$(wc -c < "$TMP/litbs.src" | tr -d ' ')"
assert_eq "seed sanity: real newline is 1 byte" "1" \
  "$(wc -c < "$TMP/realnl.src" | tr -d ' ')"

LIT_ID="$(seed_content "$DPY" "$TMP/litbs.src")"
run_set "$LIT_ID"; rc=$?
assert_eq "literal backslash-n: exits 0" "0" "$rc"
sel_to_file "$DPY" clipboard "$TMP/litbs.out"
assert_eq "literal backslash-n published exactly (2 bytes, no real newline)" "same" \
  "$(cmp -s "$TMP/litbs.src" "$TMP/litbs.out" && echo same || echo DIFFERENT)"

reset_selections
NL_ID="$(seed_content "$DPY" "$TMP/realnl.src")"
run_set "$NL_ID"; rc=$?
assert_eq "real newline: exits 0" "0" "$rc"
sel_to_file "$DPY" clipboard "$TMP/realnl.out"
assert_eq "real newline published exactly (1 byte)" "same" \
  "$(cmp -s "$TMP/realnl.src" "$TMP/realnl.out" && echo same || echo DIFFERENT)"

assert_eq "the two entries are byte-distinct on the wire" "distinct" \
  "$(cmp -s "$TMP/litbs.out" "$TMP/realnl.out" && echo SAME-BUG || echo distinct)"

scenario "unicode: multibyte text and emoji are not mangled on either display"
reset_selections
ID="$(seed_content "$DPY" "$TMP/uni.src")"
run_set "$ID"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_on_both "unicode entry" "$UNI"
assert_eq "$DPY byte length preserved" "$(wc -c < "$TMP/uni.src" | tr -d ' ')" \
  "$(sel_on "$DPY" clipboard | wc -c | tr -d ' ')"
assert_eq "$DPY2 byte length preserved" "$(wc -c < "$TMP/uni.src" | tr -d ' ')" \
  "$(sel_on "$DPY2" clipboard | wc -c | tr -d ' ')"

scenario "huge-entry: a 1 MB entry transfers whole (INCR) to both displays, byte for byte"
reset_selections
# Not all-identical-byte filler: a repeated single byte would let an INCR
# chunking bug that duplicates or drops a whole chunk of IDENTICAL bytes
# still pass a byte-count check (and even a naive cmp, if the corruption
# happened to preserve length) -- vary it so a shifted/dropped/duplicated
# chunk is visible as a genuine content difference, not just a count.
{ for _i in $(seq 1 15625); do printf 'A%063d' "$_i"; done; } > "$TMP/big.src"
assert_eq "seed sanity: big.src really is 1000000 bytes" "1000000" \
  "$(wc -c < "$TMP/big.src" | tr -d ' ')"
ID="$(seed_content "$DPY" "$TMP/big.src")"
run_set "$ID"; rc=$?
assert_eq "exits 0" "0" "$rc"
for d in "$DPY" "$DPY2"; do
  for s in clipboard primary; do
    sel_to_file "$d" "$s" "$TMP/big.$d.$s.out"
    assert_eq "$d $s matches the seed file exactly (cmp, not just a byte count)" "same" \
      "$(cmp -s "$TMP/big.src" "$TMP/big.$d.$s.out" && echo same || echo DIFFERENT)"
  done
done

scenario "empty-entry: a zero-byte entry is a valid publish, not a guard failure"
reset_selections
: > "$TMP/empty.src"
ID="$(seed_content "$DPY" "$TMP/empty.src")"
run_set "$ID"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_on_both "empty entry" ""

scenario "no-explicit-source-refuses: DISPLAY is never trusted -- omitting both the arg and the override is a loud refusal, not a guess"
# The blocking gap this suite exists to close: a per-display store means
# the SAME id commonly exists, with DIFFERENT content, in more than one
# store (proven directly below). Falling back to an inherited $DISPLAY --
# even a perfectly live, correct one, as set here -- would make the wrong
# guess indistinguishable from the right one: both "succeed", exit 0, and
# publish SOMETHING. So this must refuse outright with neither signal given.
reset_selections
ID="$(seed_content "$DPY" "$TMP/plain.src")"
_saved_dpy="$CLIP_SET_ENV_DISPLAY"; _saved_src="$CLIP_SET_ENV_SRC"
CLIP_SET_ENV_DISPLAY="$DPY"   # a REAL, correct display -- must still not be used
CLIP_SET_ENV_SRC=""           # no CLIP_SET_SRC_DISPLAY override, and no $2 below
run_set "$ID"; rc=$?
CLIP_SET_ENV_DISPLAY="$_saved_dpy"; CLIP_SET_ENV_SRC="$_saved_src"
assert_eq "exits 1" "1" "$rc"
assert_eq "reason names the missing source display" "yes" \
  "$(grep -qi 'no source display' "$TMP/set.err" && echo yes || echo no)"
assert_untouched "no-explicit-source"

scenario "positional-src-arg-selects-store: \$2 alone (no env override) resolves the store"
reset_selections
ID="$(seed_content "$DPY" "$TMP/plain.src")"
_saved_src="$CLIP_SET_ENV_SRC"
CLIP_SET_ENV_SRC=""            # no env override -- prove the positional arg alone suffices
run_set "$ID" "$DPY"; rc=$?
CLIP_SET_ENV_SRC="$_saved_src"
assert_eq "exits 0" "0" "$rc"
assert_on_both "resolved via the positional \$2 argument" "$PLAIN"

scenario "screen-suffix-src-normalized: a :N.0-suffixed src display resolves the bare-display store (dotfiles-3x85)"
# Entry seeded under the BARE display's store (store_dir "$DPY" == .../clip-store/:93);
# clip-set.sh is told the src is "$DPY.0" -- the X-screen-suffixed form a raw
# $DISPLAY can carry -- and must still find it by stripping the suffix
# internally, exactly as clip-store.sh's writer does at the other end.
reset_selections
ID="$(seed_content "$DPY" "$TMP/plain.src")"
_saved_src="$CLIP_SET_ENV_SRC"
CLIP_SET_ENV_SRC="$DPY.0"
run_set "$ID"; rc=$?
CLIP_SET_ENV_SRC="$_saved_src"
assert_eq "exits 0 (found the entry under the bare-display store)" "0" "$rc"
assert_on_both "resolved via the :N.0-suffixed src display" "$PLAIN"

scenario "wrong-store-explicit-src-publishes-right-one: an id colliding across two stores is resolved by the explicit source, not guessed"
# THE anti-bug test: seed the identical filename in TWO stores with
# DIFFERENT content -- exactly the "000005.clip commonly exists in both"
# collision a per-display, independently-seq'd store creates by
# construction -- and prove the explicit source display, not enumeration
# order or ambient state, decides which one gets published.
reset_selections
mkdir -p "$(store_dir ":winA")" "$(store_dir ":winB")"
printf 'content-from-store-A' > "$(store_dir ":winA")/000001.clip"
printf 'content-from-store-B' > "$(store_dir ":winB")/000001.clip"
_saved_src="$CLIP_SET_ENV_SRC"

CLIP_SET_ENV_SRC=":winA"
run_set "000001.clip"; rc=$?
assert_eq "store A: exits 0" "0" "$rc"
assert_on_both "publishes store A's content, not store B's" "content-from-store-A"

reset_selections
CLIP_SET_ENV_SRC=":winB"
run_set "000001.clip"; rc=$?
assert_eq "store B: exits 0" "0" "$rc"
assert_on_both "publishes store B's content, not store A's" "content-from-store-B"

CLIP_SET_ENV_SRC="$_saved_src"

# ======================= PHASE 2: displays that are not there ================

scenario "dead-socket-among-live: a stale socket name is skipped, not fatal"
mkdir -p "$TMP/x11-mixed"
ln -sf "/tmp/.X11-unix/X${DPY#:}"  "$TMP/x11-mixed/X${DPY#:}"
ln -sf "/tmp/.X11-unix/X${DPY2#:}" "$TMP/x11-mixed/X${DPY2#:}"
: > "$TMP/x11-mixed/X$DEAD_NUM"
reset_selections
ID="$(seed_content "$DPY" "$TMP/plain.src")"
run_set_in "$TMP/x11-mixed" "$ID"; rc=$?
assert_eq "exits 0 despite the dead display" "0" "$rc"
assert_on_both "with a dead socket present" "$PLAIN"

scenario "survivor-display-still-succeeds: one session dying does not stop the other"
# Last of the "displays that are not there" phase, because it tears $DPY2
# down for good -- everything after this scenario has only ONE live display.
reset_selections
ID="$(seed_content "$DPY" "$TMP/plain.src")"
kill "$XVFB2_PID" 2>/dev/null
wait "$XVFB2_PID" 2>/dev/null
XVFB2_PID=""
for i in $(seq 1 20); do
  env DISPLAY="$DPY2" timeout 2 xclip -selection clipboard -o >/dev/null 2>&1 || break
  sleep 0.5
done
assert_eq "$DPY2 really is gone" "gone" \
  "$(env DISPLAY="$DPY2" timeout 2 xclip -selection clipboard -o >/dev/null 2>&1 && echo alive || echo gone)"
run_set "$ID"; rc=$?
assert_eq "exits 0 on the survivor alone" "0" "$rc"
assert_eq "$DPY clipboard holds the entry" "$PLAIN" "$(sel_on "$DPY" clipboard)"
assert_eq "$DPY primary holds the entry" "$PLAIN" "$(sel_on "$DPY" primary)"

# ============ PHASE 3: guards -- every precondition failure writes nothing ===
#
# Every one of these must be exit 1 (or, for the XDG_RUNTIME_DIR case, exit
# 78) specifically -- those are the codes that promise the clipboard was not
# touched, and downstream callers (qs-clip.sh, the picker) build against
# that promise. Only $DPY is live from here on (the previous scenario killed
# $DPY2 for good), so assert_untouched only checks $DPY -- but it is still
# the same "nothing was written" property, checked on both selections.
assert_untouched_dpy_only() { # <label>
  assert_eq "$1: $DPY clipboard untouched" "$SENTINEL" "$(sel_on "$DPY" clipboard)"
  assert_eq "$1: $DPY primary untouched"   "$SENTINEL" "$(sel_on "$DPY" primary)"
}

scenario "guards-write-nothing: unknown-id-exits-1-writes-nothing"
reset_selections
run_set "999999.clip"; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "reason names the unknown id" "yes" \
  "$(grep -qi 'no such entry' "$TMP/set.err" && echo yes || echo no)"
assert_untouched_dpy_only "unknown-id"

scenario "guards-write-nothing: bad-id format is refused before anything is written"
reset_selections
run_set "not-an-id"; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "explains itself" "yes" \
  "$(grep -qi 'NNNNNN.clip' "$TMP/set.err" && echo yes || echo no)"
assert_untouched_dpy_only "bad-id"

scenario "guards-write-nothing: missing argument is refused"
reset_selections
run_set; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "prints usage" "yes" \
  "$(grep -qi 'usage' "$TMP/set.err" && echo yes || echo no)"
assert_untouched_dpy_only "missing-arg"

scenario "guards-write-nothing: store dir absent entirely (a session that never captured anything)"
reset_selections
_saved_src="$CLIP_SET_ENV_SRC"
CLIP_SET_ENV_SRC=":96"   # no clip-store/:96 directory exists at all
run_set "000001.clip"; rc=$?
CLIP_SET_ENV_SRC="$_saved_src"
assert_eq "exits 1" "1" "$rc"
assert_untouched_dpy_only "store-dir-absent"

scenario "guards-write-nothing: no-display-at-all is a clean exit 1"
reset_selections
ID="$(seed_content "$DPY" "$TMP/plain.src")"
run_set_in "$TMP/x11-empty" "$ID"; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "reason names the missing display" "yes" \
  "$(grep -qi 'no live X display' "$TMP/set.err" && echo yes || echo no)"
assert_untouched_dpy_only "no-display"

scenario "guards-write-nothing: only-dead-displays (sockets with no server behind them) is exit 1"
reset_selections
ID="$(seed_content "$DPY" "$TMP/plain.src")"
run_set_in "$TMP/x11-dead" "$ID"; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "reason names the missing display" "yes" \
  "$(grep -qi 'no live X display' "$TMP/set.err" && echo yes || echo no)"
assert_untouched_dpy_only "only-dead"

scenario "guards-write-nothing: XDG_RUNTIME_DIR unset fails loudly (exit 78), not silently"
reset_selections
ID="$(seed_content "$DPY" "$TMP/plain.src")"
_saved_xdg="$CLIP_SET_ENV_XDG"
CLIP_SET_ENV_XDG="UNSET"
run_set "$ID"; rc=$?
CLIP_SET_ENV_XDG="$_saved_xdg"
assert_eq "exits 78" "78" "$rc"
assert_eq "reason names XDG_RUNTIME_DIR" "yes" \
  "$(grep -qi 'XDG_RUNTIME_DIR' "$TMP/set.err" && echo yes || echo no)"
assert_untouched_dpy_only "xdg-runtime-dir-unset"

# ------------------------------------------------------------------ result ---

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
