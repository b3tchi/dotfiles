#!/bin/sh
# test-notif-store.sh -- verify the notification file-store backend
# (quickshell/qs-notif-store.sh): sp019 task 1, dotfiles-c5fd.1.
#
# Headless, no X: pure sh against an isolated XDG_STATE_HOME/XDG_RUNTIME_DIR
# tree under $TMP.  Never touches the live session's store.
#
# usage: quickshell/test-notif-store.sh
# env:   KEEP_TMP=1   (debug: skip deleting $TMP on exit)
#        SELFTEST=1   (negative control: flips one expectation, MUST fail)
set -u

REPO_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STORESH="$REPO_DIR/qs-notif-store.sh"

TMP="/tmp/notif-store-test.$$"
STATE="$TMP/state"   # XDG_STATE_HOME stand-in
RUN="$TMP/run"       # XDG_RUNTIME_DIR stand-in
SDIR="$STATE/qs-notif"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

assert_eq() { # <scenario> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

scenario() { printf '\n[%s]\n' "$1"; }

cleanup() {
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP" "$STATE" "$RUN"
chmod 700 "$RUN"

# --- frozen-clock shim -------------------------------------------------------
# prune() (store ~line 135) samples its OWN `date +%s`, independent of whatever
# "now" a fixture used to stamp its entries.  A wall-clock tick between fixture
# creation and prune shifts every age by +delta, which makes any exact-second
# age-boundary assertion nondeterministic.  This shim, placed FIRST on PATH only
# for the age-boundary scenarios (via run_store_frozen), makes `date +%s` return
# a fixed $FROZEN_NOW so the fixture and prune sample the SAME instant.  Only
# `date +%s` is intercepted; every other date call (and every other binary)
# falls through to the real one.
FROZEN_BIN="$TMP/frozenbin"
mkdir -p "$FROZEN_BIN"
cat > "$FROZEN_BIN/date" <<'SHIM'
#!/bin/sh
if [ "${1:-}" = "+%s" ] && [ -n "${FROZEN_NOW:-}" ]; then
  printf '%s\n' "$FROZEN_NOW"
else
  for _d in /usr/bin /bin /usr/local/bin; do
    [ -x "$_d/date" ] && exec "$_d/date" "$@"
  done
  exit 127
fi
SHIM
chmod +x "$FROZEN_BIN/date"

# Run the store script with an isolated XDG env.  Extra VAR=VAL assignments
# (if any) are given as leading args.
run_store() { # [VAR=VAL ...] -- <verb> [args...]
  env XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$RUN" "$@"
}

# Like run_store, but with the store's `date +%s` frozen to <frozen_epoch> so
# prune() measures ages against a clock the caller controls.  Any leading
# VAR=VAL args (e.g. QS_NOTIF_MAX_AGE=0) are consumed by env as assignments too.
run_store_frozen() { # <frozen_epoch> [VAR=VAL ...] -- <verb> [args...]
  _fn="$1"; shift
  env XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$RUN" \
      PATH="$FROZEN_BIN:$PATH" FROZEN_NOW="$_fn" "$@"
}

[ -f "$STORESH" ] || { echo "FATAL: store script not found at $STORESH" >&2; exit 1; }

# --------------------------------------------------------------- scenarios ---

NOW="$(date +%s)"

scenario "append-atomic-visible: an append lands as the next seq entry, atomically"
printf 'hello body' | run_store sh "$STORESH" append "$NOW" normal testapp "hello summary"
rc=$?
assert_eq "append exits 0" "0" "$rc"
assert_eq "entry 000001.notif exists" "yes" "$([ -f "$SDIR/000001.notif" ] && echo yes || echo no)"
assert_eq "store dir mode is 700" "700" "$(stat -c '%a' "$SDIR" 2>/dev/null)"
assert_eq "header line is correct" "$NOW	normal	testapp" "$(sed -n '1p' "$SDIR/000001.notif")"
assert_eq "summary line is correct" "hello summary" "$(sed -n '2p' "$SDIR/000001.notif")"
assert_eq "body line is correct" "hello body" "$(sed -n '3p' "$SDIR/000001.notif")"

scenario "seq-continues-after-restart: a second append (simulating a fresh process) continues the sequence"
printf 'body two' | run_store sh "$STORESH" append "$NOW" low other "second summary"
assert_eq "entry 000002.notif exists" "yes" "$([ -f "$SDIR/000002.notif" ] && echo yes || echo no)"
assert_eq "entry 000001.notif untouched" "hello body" "$(sed -n '3p' "$SDIR/000001.notif")"

scenario "octal-seq-008: continuing from seq 000008 does not hit a POSIX octal-arithmetic error"
rm -rf "$SDIR"
mkdir -p "$SDIR"
printf '%s\tnormal\tapp\nsummary\nbody\n' "$NOW" > "$SDIR/000008.notif"
printf 'body nine' | run_store sh "$STORESH" append "$NOW" normal app "ninth summary"
rc=$?
assert_eq "append after seq 008 exits 0 (no octal-arithmetic crash)" "0" "$rc"
assert_eq "entry 000009.notif exists" "yes" "$([ -f "$SDIR/000009.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

scenario "empty-body: an append with zero body bytes still succeeds"
printf '' | run_store sh "$STORESH" append "$NOW" normal app "empty body summary"
rc=$?
assert_eq "append with empty stdin exits 0" "0" "$rc"
assert_eq "entry 000001.notif exists" "yes" "$([ -f "$SDIR/000001.notif" ] && echo yes || echo no)"
assert_eq "header line present" "$NOW	normal	app" "$(sed -n '1p' "$SDIR/000001.notif")"
assert_eq "summary line present" "empty body summary" "$(sed -n '2p' "$SDIR/000001.notif")"
assert_eq "zero body lines" "" "$(sed -n '3,$p' "$SDIR/000001.notif")"
assert_eq "entry has exactly 2 lines" "2" "$(wc -l < "$SDIR/000001.notif" | tr -d ' ')"
rm -rf "$SDIR"

scenario "age-prune-on-write: entries older than QS_NOTIF_MAX_AGE are pruned on the next write"
mkdir -p "$SDIR"
old_epoch=$((NOW - 200000))   # older than the default 172800s cap
printf '%s\tnormal\told-app\nstale summary\nstale body\n' "$old_epoch" > "$SDIR/000001.notif"
printf 'fresh body' | run_store sh "$STORESH" append "$NOW" normal freshapp "fresh summary"
assert_eq "stale entry 000001.notif is gone" "no" "$([ -e "$SDIR/000001.notif" ] && echo yes || echo no)"
assert_eq "fresh entry 000002.notif remains" "yes" "$([ -f "$SDIR/000002.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

scenario "age-boundary-kept: an entry exactly at the cap is kept, one second past is pruned"
mkdir -p "$SDIR"
# The exact-second boundary (age == MAX_AGE kept, age == MAX_AGE+1 pruned) is
# only well-defined if the fixture's "now" equals the value prune() reads from
# its own `date +%s`.  Freeze both to the same fixed instant via the date shim
# (run_store_frozen) so the boundary is deterministic regardless of real
# wall-clock ticks or CPU-load-induced scheduling delay between the two.
frozen=1700000000
at_cap=$((frozen - 172800))     # age exactly MAX_AGE  -> kept  (prune uses strict >)
past_cap=$((frozen - 172801))   # age MAX_AGE + 1      -> pruned
printf '%s\tnormal\tapp-at-cap\nat-cap summary\nat-cap body\n' "$at_cap" > "$SDIR/000001.notif"
printf '%s\tnormal\tapp-past-cap\npast-cap summary\npast-cap body\n' "$past_cap" > "$SDIR/000002.notif"
printf 'trigger body' | run_store_frozen "$frozen" sh "$STORESH" append "$frozen" normal trigapp "trigger summary"
assert_eq "at-cap entry (age == MAX_AGE) is kept" "yes" "$([ -f "$SDIR/000001.notif" ] && echo yes || echo no)"
assert_eq "past-cap entry (age == MAX_AGE+1) is pruned" "no" "$([ -e "$SDIR/000002.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

scenario "age-prune-max-age-zero: QS_NOTIF_MAX_AGE=0 prunes anything strictly older than now, keeps the just-written entry"
mkdir -p "$SDIR"
# Contract under test (store ~line 140): prune drops an entry when
# (now - epoch) > MAX_AGE, a STRICT >.  With MAX_AGE=0 that means "strictly
# older than now is pruned; an entry stamped at now (age 0) is kept" -- the
# just-written entry survives ONLY because 0 > 0 is false.  That survival is a
# one-tick race against prune's independently-read clock, so freeze both to the
# same instant: the just-written entry is stamped at $frozen and prune reads
# $frozen, giving age 0 deterministically; the seeded entry is a full 100s in
# the past so it is unambiguously pruned.
frozen=1700000000
past=$((frozen - 100))
printf '%s\tnormal\told\nold summary\nold body\n' "$past" > "$SDIR/000001.notif"
printf 'zero-age body' | run_store_frozen "$frozen" QS_NOTIF_MAX_AGE=0 \
  sh "$STORESH" append "$frozen" normal zeroapp "zero-age summary"
assert_eq "the older entry (age 100 > 0) is pruned under MAX_AGE=0" "no" "$([ -e "$SDIR/000001.notif" ] && echo yes || echo no)"
assert_eq "the just-written entry (epoch == frozen now, age 0) survives" "yes" "$([ -f "$SDIR/000002.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

scenario "unicode-body-byte-exact: tabs, real newlines and unicode in the body survive byte-exact"
mkdir -p "$TMP/fix"
printf 'l\303\255n\304\223-ONE \342\230\203\thas\ttabs\nline-TWO\n\nline-FOUR-apr\303\250s-blank' > "$TMP/fix/mlt"
run_store sh "$STORESH" append "$NOW" normal unicodeapp "unicode summary" < "$TMP/fix/mlt"
# The body is everything from line 3 onward; extract it with tail and compare
# byte-for-byte against the fixture (sed/head would mangle a trailing
# newline-less file differently, so tail -n +3 is the exact inverse of how
# the store appended it).
tail -n +3 "$SDIR/000001.notif" > "$TMP/fix/mlt.got"
assert_eq "body bytes match the fixture exactly" "identical" \
  "$(cmp -s "$TMP/fix/mlt" "$TMP/fix/mlt.got" && echo identical || echo different)"
rm -rf "$SDIR"

scenario "store-dir-deleted: a store dir removed mid-session is recreated on next write"
printf 'recreated body' | run_store sh "$STORESH" append "$NOW" normal recreateapp "recreate summary"
assert_eq "store exists after first append" "yes" "$([ -d "$SDIR" ] && echo yes || echo no)"
rm -rf "$SDIR"
assert_eq "store dir removed" "no" "$([ -d "$SDIR" ] && echo yes || echo no)"
printf 'second body' | run_store sh "$STORESH" append "$NOW" normal recreateapp "second summary"
assert_eq "store dir recreated" "yes" "$([ -d "$SDIR" ] && echo yes || echo no)"
assert_eq "store dir mode is 700 after recreation" "700" "$(stat -c '%a' "$SDIR" 2>/dev/null)"
assert_eq "new entry starts fresh at 000001.notif (directory was truly gone)" "yes" \
  "$([ -f "$SDIR/000001.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

scenario "summary-whitespace-folded: control whitespace (tab/newline) in the summary is folded to spaces"
printf 'body for folding test' | run_store sh "$STORESH" append "$NOW" normal foldapp \
  "$(printf 'line one\twith tab\nline two')"
assert_eq "summary line has no raw tab or embedded newline" "line one with tab line two" \
  "$(sed -n '2p' "$SDIR/000001.notif")"
assert_eq "the body (line 3+) is untouched by the folding applied to the summary" \
  "body for folding test" "$(tail -n +3 "$SDIR/000001.notif")"
rm -rf "$SDIR"

scenario "dismiss-by-id: dismiss <id> removes exactly the named entry"
printf 'body one' | run_store sh "$STORESH" append "$NOW" normal app "summary one"
printf 'body two' | run_store sh "$STORESH" append "$NOW" normal app "summary two"
run_store sh "$STORESH" dismiss 000001.notif
rc=$?
assert_eq "dismiss exits 0" "0" "$rc"
assert_eq "entry 000001.notif is gone" "no" "$([ -e "$SDIR/000001.notif" ] && echo yes || echo no)"
assert_eq "entry 000002.notif remains" "yes" "$([ -f "$SDIR/000002.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

scenario "dismiss-latest: dismiss latest resolves to the highest seq entry"
printf 'body one' | run_store sh "$STORESH" append "$NOW" normal app "summary one"
printf 'body two' | run_store sh "$STORESH" append "$NOW" normal app "summary two"
run_store sh "$STORESH" dismiss latest
rc=$?
assert_eq "dismiss latest exits 0" "0" "$rc"
assert_eq "entry 000002.notif (the highest seq) is gone" "no" "$([ -e "$SDIR/000002.notif" ] && echo yes || echo no)"
assert_eq "entry 000001.notif remains" "yes" "$([ -f "$SDIR/000001.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

scenario "dismiss-missing-exit1: dismissing a nonexistent id exits 1, removing nothing"
printf 'body one' | run_store sh "$STORESH" append "$NOW" normal app "summary one"
run_store sh "$STORESH" dismiss 000099.notif
rc=$?
assert_eq "dismiss exits 1" "1" "$rc"
assert_eq "entry 000001.notif still present (nothing removed)" "yes" "$([ -f "$SDIR/000001.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

scenario "dismiss-id-shape-reject: a malformed id is refused before any path use"
mkdir -p "$SDIR"
printf '%s\tnormal\tapp\nvictim\nvictim body\n' "$NOW" > "$SDIR/000001.notif"
run_store sh "$STORESH" dismiss '../../etc/passwd'
rc1=$?
run_store sh "$STORESH" dismiss '1234567.notif'
rc2=$?
run_store sh "$STORESH" dismiss '000001.clip'
rc3=$?
assert_eq "path-traversal id rejected (exit != 0)" "yes" "$([ "$rc1" -ne 0 ] && echo yes || echo no)"
assert_eq "seven-digit id rejected (exit != 0)" "yes" "$([ "$rc2" -ne 0 ] && echo yes || echo no)"
assert_eq "wrong extension id rejected (exit != 0)" "yes" "$([ "$rc3" -ne 0 ] && echo yes || echo no)"
assert_eq "the legitimate entry was never touched" "yes" "$([ -f "$SDIR/000001.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

STATEFILE="$RUN/qs-notif.state"

scenario "state-atomic-rewrite: state rewrites the live-state file with exactly the four lines"
run_store sh "$STORESH" state 3 0 7 "$NOW" "hello there"
rc=$?
assert_eq "state exits 0" "0" "$rc"
assert_eq "line 1 is count" "count 3" "$(sed -n '1p' "$STATEFILE")"
assert_eq "line 2 is critical" "critical 0" "$(sed -n '2p' "$STATEFILE")"
assert_eq "line 3 is seq" "seq 7" "$(sed -n '3p' "$STATEFILE")"
assert_eq "line 4 is last" "last $NOW	hello there" "$(sed -n '4p' "$STATEFILE")"
assert_eq "exactly 4 lines, nothing extra" "4" "$(awk 'END{print NR}' "$STATEFILE")"
rm -f "$STATEFILE"

scenario "state-last-text-folded: control whitespace in the last text is folded like the summary"
run_store sh "$STORESH" state 1 1 2 "$NOW" "$(printf 'line one\twith tab\nline two')"
# The separator tab between epoch and text (the field delimiter, per the
# "last <epoch>\t<text>" contract) is intentional and must survive; only a
# tab/newline WITHIN the text itself is folded away.
assert_eq "last text has no raw tab or embedded newline within the text field" \
  "$(printf 'last %s\tline one with tab line two' "$NOW")" "$(sed -n '4p' "$STATEFILE")"
rm -f "$STATEFILE"

# --------------------------------------------------------------- xdg-unset ---

scenario "xdg-unset-exit78: state refuses to run with XDG_RUNTIME_DIR unset"
env -u XDG_RUNTIME_DIR XDG_STATE_HOME="$STATE" sh "$STORESH" state 1 0 1 "$NOW" "x"
rc=$?
assert_eq "state exits 78 (EX_CONFIG) with XDG_RUNTIME_DIR unset" "78" "$rc"

scenario "xdg-unset-exit78: append refuses with both HOME and XDG_STATE_HOME unset"
env -u HOME -u XDG_STATE_HOME XDG_RUNTIME_DIR="$RUN" sh "$STORESH" append "$NOW" normal app "s" < /dev/null
rc=$?
assert_eq "append exits 78 with HOME and XDG_STATE_HOME both unset" "78" "$rc"

scenario "xdg-unset-exit78: dismiss refuses with both HOME and XDG_STATE_HOME unset"
env -u HOME -u XDG_STATE_HOME XDG_RUNTIME_DIR="$RUN" sh "$STORESH" dismiss latest
rc=$?
assert_eq "dismiss exits 78 with HOME and XDG_STATE_HOME both unset" "78" "$rc"

scenario "state-atomic-rewrite-100x: a reader loop during 100 rewrites never sees a partial line set"
rm -f "$STATEFILE"
rm -f "$TMP/reader.stop" "$TMP/reader.bad"
(
  while [ ! -e "$TMP/reader.stop" ]; do
    if [ -f "$STATEFILE" ]; then
      lines="$(wc -l < "$STATEFILE" | tr -d ' ')"
      if [ -n "$lines" ] && [ "$lines" -ne 0 ] && [ "$lines" -ne 4 ]; then
        printf 'BAD lines=%s content=[%s]\n' "$lines" "$(tr '\n' '|' < "$STATEFILE")" >> "$TMP/reader.bad"
      elif [ "$lines" = "4" ]; then
        # a fully-written file must have all four line prefixes present
        grep -q '^count ' "$STATEFILE" || echo "BAD missing count prefix" >> "$TMP/reader.bad"
        grep -q '^critical ' "$STATEFILE" || echo "BAD missing critical prefix" >> "$TMP/reader.bad"
        grep -q '^seq ' "$STATEFILE" || echo "BAD missing seq prefix" >> "$TMP/reader.bad"
        grep -q '^last ' "$STATEFILE" || echo "BAD missing last prefix" >> "$TMP/reader.bad"
      fi
    fi
  done
) &
READER_PID=$!
i=1
while [ "$i" -le 100 ]; do
  run_store sh "$STORESH" state "$i" 0 "$i" "$NOW" "tick $i"
  i=$((i + 1))
done
touch "$TMP/reader.stop"
wait "$READER_PID" 2>/dev/null
assert_eq "no partial or malformed read observed across 100 rewrites" "" \
  "$([ -f "$TMP/reader.bad" ] && cat "$TMP/reader.bad" | tr '\n' ' ' || echo '')"
assert_eq "the final state reflects the last write" "count 100" "$(sed -n '1p' "$STATEFILE")"
rm -f "$STATEFILE"

scenario "collision-retry: two concurrent appends resolve the ln seq collision as a retry, both survive"
mkdir -p "$SDIR"
# Pre-seed the store at 000001 so both processes below race for 000002.
printf '%s\tnormal\tapp\nseed\nseed body\n' "$NOW" > "$SDIR/000001.notif"
# Two appends launched back-to-back without waiting for the first to finish
# writing its .wip file, so their store_write() newest_entry() reads are
# likely to both observe 000001 as the newest and both attempt 000002 --
# exactly the race the bounded ln-retry must resolve.
(printf 'concurrent body A' | run_store sh "$STORESH" append "$NOW" normal appA "concurrent A") &
CONC_PID1=$!
(printf 'concurrent body B' | run_store sh "$STORESH" append "$NOW" normal appB "concurrent B") &
CONC_PID2=$!
wait "$CONC_PID1"; rc1=$?
wait "$CONC_PID2"; rc2=$?
assert_eq "both concurrent appends exit 0" "0 0" "$rc1 $rc2"
assert_eq "three entries total exist (seed + two concurrent)" "3" \
  "$(n=0; for f in "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].notif; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n")"
assert_eq "concurrent A's payload is present somewhere in the store (not lost)" "present" \
  "$(grep -qF 'concurrent body A' "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].notif 2>/dev/null && echo present || echo absent)"
assert_eq "concurrent B's payload is present somewhere in the store (not lost)" "present" \
  "$(grep -qF 'concurrent body B' "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].notif 2>/dev/null && echo present || echo absent)"
rm -rf "$SDIR"

# ================= MUTATION CHECKS ==========================================
# Without these, the collision-retry and age-prune-on-write PASSes above would
# look identical whether the real design decision (ln over mv; prune-on-write)
# were present or not. Each mutant is a patched COPY of the shipped script,
# verified via grep to actually carry the intended change, run against the
# same scenario, and asserted to FAIL it -- proving the assertion is sensitive
# to the thing it claims to guard, not just to "did the script run".

scenario "MUTATION ln-to-mv: swapping ln for mv in store_write must fail collision-retry"
sed 's/if ln "\$_wip"/if mv "$_wip"/' "$STORESH" > "$TMP/qs-notif-store-mv.sh"
grep -qF 'if mv "$_wip"' "$TMP/qs-notif-store-mv.sh" \
  || { echo "FATAL: mutant does not contain the ln->mv swap" >&2; exit 1; }
grep -qF 'if ln "$_wip"' "$TMP/qs-notif-store-mv.sh" \
  && { echo "FATAL: mutant still contains the original ln call" >&2; exit 1; }
mkdir -p "$SDIR"
# FORCE the seq collision deterministically rather than hoping two lone appends
# interleave (which they do only ~90% of the time under load).  Two levers:
#   (1) seed the store with $MUT_SEED entries so newest_entry()'s directory scan
#       is slow -- every writer dwells in the scan long enough to overlap the
#       others, so they all read the SAME newest seq;
#   (2) block each of $MUT_W writers on a FIFO for its body, then release them
#       together, so none begins its scan until all are staged.
# All $MUT_W writers then compute the identical next-seq and target one name.
# Under `ln` (real store) every collision costs a bounded retry and all writers
# survive; under the `mv` mutant they clobber the shared target and entries are
# lost.  With this staging the mutant loses at least one entry on EVERY run.
MUT_SEED=400
MUT_W=8
mi=1
while [ "$mi" -le "$MUT_SEED" ]; do
  printf '%s\tnormal\tapp\nseed %s\nseed body\n' "$NOW" "$mi" > "$SDIR/$(printf '%06d' "$mi").notif"
  mi=$((mi + 1))
done
mj=1
while [ "$mj" -le "$MUT_W" ]; do
  mkfifo "$TMP/mfifo.$mj"
  ( run_store sh "$TMP/qs-notif-store-mv.sh" append "$NOW" normal "appM$mj" "mutant $mj" < "$TMP/mfifo.$mj" ) &
  mj=$((mj + 1))
done
# Release every blocked writer near-simultaneously: each background printf opens
# its FIFO for write (rendezvousing with the store's blocked stdin read), feeds
# the body, and closes -> EOF lets that writer fall through into store_write.
mj=1
while [ "$mj" -le "$MUT_W" ]; do
  ( printf 'mutant body %s' "$mj" > "$TMP/mfifo.$mj" ) &
  mj=$((mj + 1))
done
wait
mut_count="$(n=0; for f in "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].notif; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n")"
mut_expected=$((MUT_SEED + MUT_W))
mut_all_present=present
mj=1
while [ "$mj" -le "$MUT_W" ]; do
  grep -qF "mutant body $mj" "$SDIR"/[0-9][0-9][0-9][0-9][0-9][0-9].notif 2>/dev/null \
    || mut_all_present=absent
  mj=$((mj + 1))
done
assert_eq "the mutant LOSES an entry (mv clobbers on collision instead of retrying)" "yes" \
  "$([ "$mut_count" -lt "$mut_expected" ] || [ "$mut_all_present" = "absent" ] && echo yes || echo no)"
mj=1; while [ "$mj" -le "$MUT_W" ]; do rm -f "$TMP/mfifo.$mj"; mj=$((mj + 1)); done
rm -rf "$SDIR"

scenario "MUTATION no-prune: removing the prune call must fail age-prune-on-write"
awk '!/^  prune "\$_store"$/' "$STORESH" > "$TMP/qs-notif-store-noprune.sh"
grep -qF 'prune "$_store"' "$TMP/qs-notif-store-noprune.sh" \
  && { echo "FATAL: mutant still calls prune" >&2; exit 1; }
grep -qF 'cmd_append()' "$TMP/qs-notif-store-noprune.sh" \
  || { echo "FATAL: mutant lost cmd_append entirely; mutation would prove nothing" >&2; exit 1; }
mkdir -p "$SDIR"
old_epoch=$((NOW - 200000))
printf '%s\tnormal\told-app\nstale summary\nstale body\n' "$old_epoch" > "$SDIR/000001.notif"
printf 'fresh body' | run_store sh "$TMP/qs-notif-store-noprune.sh" append "$NOW" normal freshapp "fresh summary"
assert_eq "the stale entry SURVIVES when prune is removed (the mutation must fail the real check)" "yes" \
  "$([ -e "$SDIR/000001.notif" ] && echo yes || echo no)"
rm -rf "$SDIR"

# ================= SELFTEST NEGATIVE CONTROL ================================
# SELFTEST=1 deliberately flips one expectation to a value the real script
# can never produce. If this run does not report a FAIL, the harness itself
# (assert_eq / PASS/FAIL bookkeeping) is broken and every green result above
# is meaningless.
if [ "${SELFTEST:-}" = "1" ]; then
  scenario "SELFTEST negative control: a deliberately wrong expectation must FAIL"
  mkdir -p "$SDIR"
  printf 'selftest body' | run_store sh "$STORESH" append "$NOW" normal selftestapp "selftest summary"
  assert_eq "(SELFTEST) append exit code is WRONGLY expected to be 99" "99" "$?"
  rm -rf "$SDIR"
fi

# ------------------------------------------------------------------ result ---

printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
