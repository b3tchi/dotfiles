#!/usr/bin/env bash
# test-clip-history.sh — verify the clipboard-history picker's backend layer
# (quickshell/qs-clip.sh) against the file-store backend (sp016 task 2,
# dotfiles-egm.2 — the clipcat-backend-swap pivot).
#
# REWRITTEN for the file-store backend. The prior revision (sp014 task .4,
# dotfiles-92w.4) drove `qs-clip.sh list`/`set` through a live copyq daemon
# AND exercised the full keyboard-driven UI (ClipHistory.qml + xdotool),
# because under copyq both concerns lived on one code path. They no longer
# do: `list`/`set` now read/write a plain directory of files, no daemon
# involved ("seeding" is just writing files), which is what PHASE 0 below
# tests directly and exhaustively, per sp016 Task 2's test_plan.
#
# WHAT WAS REMOVED, THEN RESTORED (dotfiles-g5b)
#
#   The old PHASE 1-4 (sp014 task .4, dotfiles-92w.4) drove ClipHistory.qml
#   with xdotool and asserted on the exact row value the picker sent to a
#   stubbed/real clip-set.sh (Down, Down, Enter -> row "2", etc). When this
#   suite was first rewritten for the file-store backend (sp016 Task 2,
#   dotfiles-egm.2), that coverage was deliberately DROPPED rather than kept
#   passing on a bug: ClipHistory.qml's listProc.onRead did
#   `parseInt(data.substring(0, tab))` and accept() re-stringified that
#   NUMBER. Under copyq, ids were small integers and this round-tripped
#   losslessly. Under the file store, ids are opaque filenames like
#   "000004.clip" — parseInt("000004.clip") is 4, a silent truncation to the
#   numeric seq prefix, dropping ".clip" entirely. Keeping the old UI
#   scenarios would have meant asserting on that truncated number as if it
#   were correct, baking a real bug into the suite as a passing contract — so
#   task .2 filed the fix as dotfiles-g5b (its own files_touched being
#   qs-clip.sh + this suite only, not ClipHistory.qml) and left the gap
#   documented rather than papered over.
#
#   dotfiles-g5b (this task) owns quickshell/config/ClipHistory.qml: the
#   parseInt is gone, entry.row now carries the raw string id end to end, and
#   PHASE 1.5 below restores the keyboard-driven end-to-end scenario against
#   the fixed QML — selecting a NON-newest entry and asserting the FULL id
#   reaches (a stub for) clip-set.sh, closing the exact gap this comment used
#   to describe as open.
#
#   What was NEVER dropped: `toggle`'s session-derivation logic
#   (candidates()/session_key_of()/cmd_toggle) does not depend on the id
#   format at all, only on which quickshell instance answers the
#   `cliphistory` IPC target, and stayed regression-tested throughout (PHASE 1
#   below).
#
# WHAT IS ACTUALLY OBSERVED (PHASE 0)
#
#   No X server, no daemon. A "store" is a plain directory; a "capture" is
#   `printf '%s' <bytes> > store/NNNNNN.clip`. `qs-clip.sh list`/`set` are run
#   directly against that directory (DISPLAY + XDG_RUNTIME_DIR point at it)
#   with `QS_CLIP_SET` stubbed to a script that records its exact argv and
#   returns a controllable exit code — the same "assert on what actually
#   reached it" discipline test-clip-set.sh and test-clip-store.sh use
#   elsewhere in this epic. A scenario that asserts "id X was requested"
#   fails on a mutant that forwards a different id (position, first-seeded,
#   truncated) — see the "not-a-position" scenario.
#
# usage: quickshell/test-clip-history.sh
# env:   XVFB= XDOTOOL= QUICKSHELL=   (default: from PATH; PHASE 0 needs none
#        of them — only PHASE 1's session-derivation regression does)
#        TEST_DISPLAY=:95 TEST_DISPLAY2=:96
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QS_CLIP="$SCRIPT_DIR/qs-clip.sh"
CLIP_HISTORY_QML="$SCRIPT_DIR/config/ClipHistory.qml"
SHELL_QML="$SCRIPT_DIR/config/shell.qml"

XVFB="${XVFB:-Xvfb}"
XDOTOOL="${XDOTOOL:-xdotool}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
DPY="${TEST_DISPLAY:-:95}"
DPY2="${TEST_DISPLAY2:-:96}"

TMP="/tmp/qs-clip-test.$$"
CFG="$TMP/cfg"
DAT="$TMP/data"
CCH="$TMP/cache"
RUN="$TMP/run"                  # XDG_RUNTIME_DIR stand-in (tmpfs 0700 in prod)
STORE="$RUN/clip-store/$DPY"    # the store PHASE 0 reads/writes directly
STUB="$TMP/bin/clip-set.sh"     # the fake clip-set.sh qs-clip.sh invokes
ARGV_LOG="$TMP/argv.log"        # every id the script asked clip-set.sh for
STUB_MODE="$TMP/stub.mode"      # log | fail1 | fail2 — read per call

PASS=0
FAIL=0

# ---------------------------------------------------------------- harness ---

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

assert_eq() { # <scenario> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

assert_ne() { # <scenario> <not-expected> <actual>
  if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "anything but '$2'" "$3"; fi
}

scenario() { printf '\n[%s]\n' "$1"; }

cleanup() {
  [ -n "${QS_PID:-}" ]  && kill "$QS_PID"  2>/dev/null
  [ -n "${QS2_PID:-}" ] && kill "$QS2_PID" 2>/dev/null
  sleep 1
  [ -n "${XVFB_PID:-}" ]  && kill "$XVFB_PID"  2>/dev/null
  [ -n "${XVFB2_PID:-}" ] && kill "$XVFB2_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP" "$CFG" "$DAT" "$CCH" "$RUN" "$TMP/bin"
chmod 700 "$RUN"

[ -r "$QS_CLIP" ] || { echo "FATAL: $QS_CLIP not readable" >&2; exit 1; }
command -v gawk >/dev/null 2>&1 \
  || { echo "FATAL: gawk not found (qs-clip.sh's preview_of needs it)" >&2; exit 1; }

# --- the clip-set.sh qs-clip.sh sees ------------------------------------------
# One stub for the whole run, switching behaviour off a control file, so the
# exit-code scenarios do not need anything restarted between them. It always
# records argv first: a scenario asserting "nothing was invoked" is asserting
# on the same evidence as one asserting a specific id.
cat > "$STUB" <<STUBEOF
#!/bin/sh
printf '%s\n' "\$*" >> "$ARGV_LOG"
case "\$(cat "$STUB_MODE" 2>/dev/null)" in
  fail1) exit 1 ;;
  fail2) exit 2 ;;
  *)     exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

stub_mode() { printf '%s' "$1" > "$STUB_MODE"; }
clear_log() { : > "$ARGV_LOG"; }
logged()    { tr '\n' ' ' < "$ARGV_LOG" | sed 's/ *$//'; }
stub_mode log
clear_log

# --- store fixtures ------------------------------------------------------------
# Seeding IS writing files -- no daemon, no copyq, nothing to start. Content is
# written with `printf '%s'`, never `echo`/here-strings, so a fixture's exact
# bytes (embedded tabs, real newlines, a literal two-character `\n`, unicode)
# land on disk untouched -- exactly the discipline clip-store.sh itself uses,
# and the discipline the prior clipcat backend could NOT meet (dotfiles-i9i).

reset_store() { rm -rf "$STORE"; }
mk_store()    { mkdir -p "$STORE"; chmod 700 "$STORE"; }

# Write entry <seq> with content <bytes>, creating the store dir if needed.
write_entry() { # <seq> <content>
  mk_store
  printf '%s' "$2" > "$STORE/$(printf '%06d' "$1").clip"
}

# qs-clip.sh run directly (list / set), pointed at $STORE via DISPLAY +
# XDG_RUNTIME_DIR -- exactly how a real quickshell instance's own environment
# would resolve it, no extra plumbing needed.
qsclip() {
  env DISPLAY="$DPY" XDG_RUNTIME_DIR="$RUN" QS_CLIP_SET="$STUB" sh "$QS_CLIP" "$@"
}

echo "qs-clip: $QS_CLIP"
echo "store:   $STORE"

# ============================================================================
# PHASE 0 — qs-clip.sh list / set against the file store, no X, no daemon
# ============================================================================

# ---- list: emptiness and absence are not errors -----------------------------

scenario "list: an absent store dir lists nothing and is not an error"
reset_store
out="$(qsclip list)"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "no output" "" "$out"

scenario "list: an empty (but existing) store dir lists nothing and is not an error"
mk_store
out="$(qsclip list)"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "no output" "" "$out"

# ---- list-deterministic-two-calls-identical ---------------------------------

scenario "list-deterministic-two-calls-identical"
reset_store
write_entry 1 "alpha"; write_entry 2 "bravo"; write_entry 3 "charlie"
out1="$(qsclip list)"
out2="$(qsclip list)"
assert_eq "two consecutive calls over an unchanged store are byte-identical" "$out1" "$out2"

# ---- list-newest-first-by-seq -----------------------------------------------

scenario "list-newest-first-by-seq"
reset_store
write_entry 1 "alpha"; write_entry 2 "bravo"; write_entry 3 "charlie"; write_entry 4 "delta"
assert_eq "row count == store entry count" "4" "$(qsclip list | wc -l | tr -d ' ')"
assert_eq "first row is the highest seq"    "000004.clip	delta" "$(qsclip list | sed -n 1p)"
assert_eq "last row is the lowest seq"      "000001.clip	alpha" "$(qsclip list | sed -n 4p)"

scenario "list: order survives reversed mtimes -- ordering is by filename, never mtime"
reset_store
write_entry 1 "alpha"; write_entry 2 "bravo"; write_entry 3 "charlie"
touch -d '2020-01-01' "$STORE/000003.clip"   # newest seq, oldest mtime
touch -d '2030-01-01' "$STORE/000001.clip"   # oldest seq, newest mtime
assert_eq "still seq order despite an mtime tie/reversal" "000003.clip	charlie" "$(qsclip list | sed -n 1p)"

# ---- preview-is-first-nonblank-line -----------------------------------------

scenario "preview-is-first-nonblank-line"
reset_store
write_entry 1 "$(printf '\n\n   \nreal first line\nmore')"
write_entry 2 "$(printf 'has\tinner\ttabs')"
write_entry 3 ""
assert_eq "3 entries listed" "3" "$(qsclip list | wc -l | tr -d ' ')"
assert_eq "an empty entry is labelled, not blank"    "000003.clip	(empty)"         "$(qsclip list | sed -n 1p)"
assert_eq "tabs in the entry do not split the field" "000002.clip	has inner tabs"  "$(qsclip list | sed -n 2p)"
assert_eq "leading blank lines skipped"              "000001.clip	real first line" "$(qsclip list | sed -n 3p)"
assert_eq "the full multi-line entry on disk is untouched" \
  "$(printf '\n\n   \nreal first line\nmore')" "$(cat "$STORE/000001.clip")"

scenario "list: previews truncate at QS_CLIP_PREVIEW; the stored entry does not"
reset_store
LONG="$(printf 'L%.0s' $(seq 1 300))"
write_entry 1 "$LONG"
want="000001.clip	$(printf 'L%.0s' $(seq 1 19))…"
assert_eq "preview is 19 chars + an ellipsis" "$want" "$(QS_CLIP_PREVIEW=20 qsclip list)"
assert_eq "the stored entry is still 300 bytes" "300" "$(wc -c < "$STORE/000001.clip" | tr -d ' ')"

scenario "list: unicode content produces a correct, non-mangled preview"
reset_store
write_entry 1 "héllo → 世界 🎉 ünïcodé"
assert_eq "unicode preview intact" "000001.clip	héllo → 世界 🎉 ünïcodé" "$(qsclip list)"

# ---- tab-in-entry-does-not-break-protocol -----------------------------------

scenario "tab-in-entry-does-not-break-protocol"
reset_store
write_entry 1 "$(printf 'left\tright')"
line="$(qsclip list)"
assert_eq "exactly one literal tab remains -- the id/preview separator" \
  "1" "$(printf '%s' "$line" | tr -cd '\t' | wc -c | tr -d ' ')"
assert_eq "the entry's own tab was folded to a space" "000001.clip	left right" "$line"

# ---- literal-backslash-n-vs-real-newline-distinct (the poc012 case) --------

scenario "literal-backslash-n-vs-real-newline-distinct"
reset_store
write_entry 1 "before\\nafter"                    # literal 2-char \n, one line
printf 'before\nafter' > "$STORE/000002.clip"     # a REAL newline byte
assert_eq "a literal backslash-n is NOT a line break -- whole entry previews" \
  "000001.clip	before\\nafter" "$(qsclip list | sed -n 2p)"
assert_eq "a real newline IS a line break -- only the first line previews" \
  "000002.clip	before" "$(qsclip list | sed -n 1p)"
assert_ne "the two previews are distinct" \
  "$(qsclip list | sed -n 2p)" "$(qsclip list | sed -n 1p)"

# ---- cap-exceeded ------------------------------------------------------------

scenario "list: entries beyond QS_CLIP_CAP are not offered"
reset_store
write_entry 1 "e1"; write_entry 2 "e2"; write_entry 3 "e3"; write_entry 4 "e4"; write_entry 5 "e5"
assert_eq "5 entries, cap 3 -> 3 rows" "3" "$(QS_CLIP_CAP=3 qsclip list | wc -l | tr -d ' ')"
assert_eq "the capped rows are the newest" "000005.clip	e5" "$(QS_CLIP_CAP=3 qsclip list | sed -n 1p)"
assert_eq "uncapped, all 5 are offered" "5" "$(qsclip list | wc -l | tr -d ' ')"

# ---- tmp-file-skipped --------------------------------------------------------

scenario "tmp-file-skipped"
reset_store
write_entry 1 "alpha"; write_entry 2 "bravo"
: > "$STORE/000003.clip.tmp"    # a mid-write entry (writer's in-flight tmp)
: > "$STORE/.wip.tmp"           # clip-store.sh's own work file name
: > "$STORE/.tgt"               # clip-store.sh's own work file name
assert_eq "only the two real entries are counted" "2" "$(qsclip list | wc -l | tr -d ' ')"
assert_eq "the newest REAL entry is still first"   "000002.clip	bravo" "$(qsclip list | sed -n 1p)"

# ---- set-publishes-the-selected-id-not-a-position ---------------------------

scenario "set-publishes-the-selected-id-not-a-position"
reset_store
write_entry 1 "alpha"; write_entry 2 "bravo"; write_entry 3 "charlie"
clear_log; stub_mode log
qsclip set 000002.clip; rc=$?
assert_eq "exits 0 (stub's default)" "0" "$rc"
assert_eq "clip-set.sh received the SELECTED id -- not the newest (000003.clip), not the first-seeded (000001.clip), not a position (0/1/2)" \
  "000002.clip" "$(logged)"

# ---- stale-id-exits-1-publishes-nothing -------------------------------------

scenario "stale-id-exits-1-publishes-nothing"
reset_store
write_entry 1 "alpha"
clear_log; stub_mode log
qsclip set 000099.clip 2>/dev/null; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "clip-set.sh was never invoked -- nothing published" "" "$(logged)"

scenario "set: a malformed id is refused before anything is invoked (path-injection guard)"
clear_log
qsclip set '../000001.clip' 2>/dev/null; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "clip-set.sh was never invoked" "" "$(logged)"

scenario "set: a non-numeric argument is refused before anything is invoked"
clear_log
qsclip set 'twelve' 2>/dev/null; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "clip-set.sh was never invoked" "" "$(logged)"

# ---- set: clip-set.sh's exit code propagates verbatim -----------------------

scenario "set: exit 0/1/2 all propagate through qs-clip.sh unchanged"
reset_store
write_entry 1 "alpha"
clear_log; stub_mode log
qsclip set 000001.clip >/dev/null 2>&1
assert_eq "exit 0 propagates" "0" "$?"
clear_log; stub_mode fail1
qsclip set 000001.clip >/dev/null 2>&1
assert_eq "exit 1 propagates" "1" "$?"
clear_log; stub_mode fail2
qsclip set 000001.clip >/dev/null 2>&1
assert_eq "exit 2 propagates" "2" "$?"
stub_mode log

# ---- $XDG_RUNTIME_DIR unset: fail loudly, never a silent empty list --------

scenario "list/set: XDG_RUNTIME_DIR unset fails loudly (exit 78), not silently"
reset_store; write_entry 1 "alpha"
rc="$(env -u XDG_RUNTIME_DIR DISPLAY="$DPY" sh "$QS_CLIP" list >/dev/null 2>&1; echo $?)"
assert_eq "list exits 78" "78" "$rc"
clear_log
rc="$(env -u XDG_RUNTIME_DIR DISPLAY="$DPY" QS_CLIP_SET="$STUB" sh "$QS_CLIP" set 000001.clip >/dev/null 2>&1; echo $?)"
assert_eq "set exits 78" "78" "$rc"
assert_eq "clip-set.sh was never invoked" "" "$(logged)"

scenario "list: DISPLAY unset is a plain usage error (exit 1) -- distinct from the loud 78"
rc="$(env -u DISPLAY XDG_RUNTIME_DIR="$RUN" sh "$QS_CLIP" list >/dev/null 2>&1; echo $?)"
assert_eq "exits 1, not 78" "1" "$rc"

# ============================================================================
# PHASE 1 — session derivation (toggle) is unchanged by the backend swap
# ============================================================================
#
# cmd_toggle / candidates() / session_key_of() are untouched by this task.
# This is a REGRESSION check, not new coverage: with two live quickshell
# instances and no environment match, the picker still refuses and names the
# sessions rather than guessing which one to open on -- the property that
# matters most on a host where a wrong guess opens a picker (which can hold a
# password) where nobody is looking.

for tool in "$XVFB" "$XDOTOOL" "$QUICKSHELL"; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (XVFB=/XDOTOOL=/QUICKSHELL= to override)" >&2; exit 1; }
done
[ -r "$CLIP_HISTORY_QML" ] || { echo "FATAL: $CLIP_HISTORY_QML not readable" >&2; exit 1; }

mkdir -p "$TMP/entry"
ln -sf "$CLIP_HISTORY_QML" "$TMP/entry/ClipHistory.qml"
cat > "$TMP/entry/shell.qml" <<'ENTRYEOF'
import Quickshell
ShellRoot { ClipHistory {} }
ENTRYEOF

ISO=(XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" XDG_CACHE_HOME="$CCH" XDG_RUNTIME_DIR="$RUN")

start_xvfb() { # <display> <logfile>
  "$XVFB" "$1" -screen 0 1280x800x24 >"$2" 2>&1 &
  local pid=$! i
  for i in $(seq 1 20); do
    [ -e "/tmp/.X11-unix/X${1#:}" ] && break
    sleep 0.5
  done
  [ -e "/tmp/.X11-unix/X${1#:}" ] || { echo "FATAL: Xvfb $1 did not start" >&2; exit 1; }
  printf '%s' "$pid"
}
XVFB_PID="$(start_xvfb "$DPY"  "$TMP/xvfb.log")"
XVFB2_PID="$(start_xvfb "$DPY2" "$TMP/xvfb2.log")"

start_qs() { # <display> <logfile>
  env DISPLAY="$1" "${ISO[@]}" \
      QS_CLIP_SH="$QS_CLIP" QS_CLIP_SET="$STUB" \
      "$QUICKSHELL" -p "$TMP/entry" >"$2" 2>&1 &
  printf '%s' $!
}
QS_PID="$(start_qs "$DPY"  "$TMP/qs.log")"
QS2_PID="$(start_qs "$DPY2" "$TMP/qs2.log")"

for i in $(seq 1 40); do
  a="$(env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$QS_PID"  show 2>/dev/null | grep -c 'cliphistory')"
  b="$(env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$QS2_PID" show 2>/dev/null | grep -c 'cliphistory')"
  [ "${a:-0}" -gt 0 ] && [ "${b:-0}" -gt 0 ] && { QS_UP=1; break; }
  sleep 0.5
done
[ -n "${QS_UP:-}" ] || { echo "FATAL: picker instances did not expose cliphistory" >&2; tail -20 "$TMP/qs.log" >&2; exit 1; }

win_on() { # <display> [tries]
  local d="$1" tries="${2:-40}" i id
  for i in $(seq 1 "$tries"); do
    id="$(env DISPLAY="$d" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | head -1)"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    sleep 0.25
  done
  return 1
}

gone_on() { # <display>
  local d="$1" i id
  for i in $(seq 1 40); do
    id="$(env DISPLAY="$d" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | head -1)"
    [ -z "$id" ] && return 0
    sleep 0.25
  done
  return 1
}

pid_for() { case "$1" in "$DPY") printf '%s' "$QS_PID" ;; *) printf '%s' "$QS2_PID" ;; esac; }

close_picker() { # <display>
  env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$(pid_for "$1")" call cliphistory close >/dev/null 2>&1
  gone_on "$1"
}

send() { local d="$1"; shift; env DISPLAY="$d" "$XDOTOOL" key --clearmodifiers "$@" 2>/dev/null; sleep 0.15; }

scenario "derivation: the picker opens on the display it was asked for"
close_picker "$DPY"
env DISPLAY="$DPY" "${ISO[@]}" QS_CLIP_SET="$STUB" QS_CLIP_DISPLAY="DISPLAY=$DPY" sh "$QS_CLIP" toggle >/dev/null 2>&1
WID="$(win_on "$DPY")"
assert_ne "a qs-clip window is mapped on $DPY" "" "$WID"
[ -n "$WID" ] && env DISPLAY="$DPY" "$XDOTOOL" windowfocus "$WID" 2>/dev/null
sleep 0.4
send "$DPY" Escape
if ! gone_on "$DPY"; then
  # Escape needs real keyboard focus on the window; close via IPC as a
  # fallback so the next scenario is not contaminated by a stray window.
  close_picker "$DPY"
fi

scenario "derivation: a stale DISPLAY is refused rather than guessed at"
# Two sessions are live and the caller's DISPLAY belongs to neither. Guessing
# would put the picker -- which can hold a password -- on the display nobody
# is watching, so the script must decline.
out="$(env DISPLAY=":987" "${ISO[@]}" sh "$QS_CLIP" toggle 2>&1)"; rc=$?
assert_ne "exits non-zero" "0" "$rc"
assert_eq "no picker opened on $DPY"  "0" \
  "$(env DISPLAY="$DPY"  "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no picker opened on $DPY2" "0" \
  "$(env DISPLAY="$DPY2" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | wc -l | tr -d ' ')"
assert_ne "and it says which sessions it found" "" "$(printf '%s' "$out" | grep -o 'DISPLAY=:9[56]' | head -1)"

scenario "derivation: an inherited DISPLAY that DOES match a live session is honoured"
close_picker "$DPY2"
env DISPLAY="$DPY2" "${ISO[@]}" QS_CLIP_SET="$STUB" sh "$QS_CLIP" toggle >/dev/null 2>&1
WID2="$(win_on "$DPY2")"
assert_ne "the picker opened on $DPY2" "" "$WID2"
assert_eq "and not on $DPY" "0" \
  "$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | wc -l | tr -d ' ')"
close_picker "$DPY2"

# ============================================================================
# PHASE 1.5 — end-to-end keyboard-driven publish (dotfiles-g5b regression)
# ============================================================================
#
# Restores the coverage debt the file-level comment above documents: PHASE
# 1-4 of the pre-pivot suite drove the REAL ClipHistory.qml picker with
# xdotool and asserted on the id it sent to (a stub for) clip-set.sh, but
# were removed rather than kept passing on a truncated number, because
# fixing that required editing ClipHistory.qml -- out of egm.2's
# files_touched. This task (dotfiles-g5b) owns that file, so the scenario
# is restored here, against the fixed QML.
#
# Selecting a NON-newest entry is the point: the old bug
# (`parseInt("000004.clip") === 4`) truncated any id to its leading numeric
# run, and asserting only on the newest row risks an accidental pass if that
# row's id happens to survive truncation by coincidence (e.g. a
# single-digit-losing case that still resolves to *some* existing file).
# Moving off row 0 first and asserting the FULL filename closes that gap.
#
# qs-clip.sh's cmd_set currently execs `clip-set.sh <id>` bare -- it does not
# yet forward the source display (see clip-set.sh's own header comment:
# wiring that through is sp016 task 5's job, dotfiles-egm.5, not this one's).
# So this scenario asserts on exactly what qs-clip.sh forwards TODAY: one
# argument, the full id. When egm.5 lands the display argument, this
# scenario's argv assertion should grow a second field to match.

scenario "picker: keyboard-driven select of a NON-newest entry publishes its FULL id, untruncated (dotfiles-g5b)"
close_picker "$DPY"
reset_store
write_entry 1 "alpha"
write_entry 2 "bravo"
write_entry 3 "charlie"
clear_log; stub_mode log

env DISPLAY="$DPY" "${ISO[@]}" QS_CLIP_SET="$STUB" QS_CLIP_DISPLAY="DISPLAY=$DPY" sh "$QS_CLIP" toggle >/dev/null 2>&1
WID="$(win_on "$DPY")"
assert_ne "picker opened on $DPY" "" "$WID"
[ -n "$WID" ] && env DISPLAY="$DPY" "$XDOTOOL" windowfocus "$WID" 2>/dev/null
sleep 0.4

# list is newest-first: 000003.clip (row 0, newest), 000002.clip (row 1),
# 000001.clip (row 2, oldest). One Down moves selection off the newest row
# onto 000002.clip -- a NON-newest entry, deliberately.
send "$DPY" Down
send "$DPY" Return

gone_on "$DPY"   # exit 0 from the stub closes the picker (setProc.onExited)
assert_eq "clip-set.sh (stub) received the SELECTED entry's FULL untruncated id -- not a parseInt-truncated number ('2'), not the newest id (000003.clip), not a bare list position (0/1)" \
  "000002.clip" "$(logged)"

close_picker "$DPY"

# ============================================================================
# PHASE 2 — production wiring (inspection, not execution)
# ============================================================================

scenario "wiring: the shipped shell.qml instantiates the picker"
assert_eq "config/shell.qml contains ClipHistory {}" "1" \
  "$(grep -c '^[[:space:]]*ClipHistory[[:space:]]*{}' "$SHELL_QML" | tr -d ' ')"

# ============================================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
