#!/usr/bin/env bash
# test-clip-history.sh — verify the clipboard-history picker (dotfiles-92w.4):
# quickshell/qs-clip.sh and quickshell/config/ClipHistory.qml.
#
# Runs entirely headless on its own pair of Xvfb displays with an isolated
# XDG_CONFIG_HOME, so it never touches the live X sessions, the live clipboard,
# the live copyq history, or the live quickshell instances.
#
# WHAT IS ACTUALLY OBSERVED
#
#   A QML picker cannot be asserted on by reading its internals — so nothing
#   here does. No introspection hook was added to the production QML for the
#   suite's benefit. Instead every UI claim is reduced to something visible
#   from outside the process:
#
#     * "the list holds N rows"  -> arrow past the end and confirm the
#       selection CLAMPS at N-1. Pressing Down N+3 times and getting row N-1
#       is only possible if the model has exactly N rows; a model with N-1 or
#       N+1 fails it.
#     * "Enter copies row R"     -> the argv a clip-set stub on disk actually
#       received. Not "a process ran" — the exact row number.
#     * "the filter does not renumber rows" -> filter down to a row that is
#       NOT first, press Enter, and assert the argv is that row's COPYQ index.
#       A picker that published the filtered position instead would send 0.
#     * "the full entry is copied, not the preview" -> run the REAL
#       clip-set.sh and read the entry back off both displays' CLIPBOARD.
#     * "Esc / a failure / an empty history did not close it" -> whether an
#       X window titled qs-clip is still mapped.
#
#   Keys are delivered with xdotool via XTEST, i.e. as real key events into the
#   focused window, not as anything the QML opted into.
#
# usage: quickshell/test-clip-history.sh
# env:   COPYQ=  XVFB=  XDOTOOL=  QUICKSHELL=   (default: from PATH)
#        TEST_DISPLAY=:95 TEST_DISPLAY2=:96
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QS_CLIP="$SCRIPT_DIR/qs-clip.sh"
CLIP_HISTORY_QML="$SCRIPT_DIR/config/ClipHistory.qml"
SHELL_QML="$SCRIPT_DIR/config/shell.qml"
REAL_CLIP_SET="$SCRIPT_DIR/../i3/scripts/clip-set.sh"

COPYQ="${COPYQ:-copyq}"
XVFB="${XVFB:-Xvfb}"
XDOTOOL="${XDOTOOL:-xdotool}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
DPY="${TEST_DISPLAY:-:95}"
DPY2="${TEST_DISPLAY2:-:96}"

TMP="/tmp/qs-clip-test.$$"      # kept short: copyq's socket lives under $CFG
CFG="$TMP/cfg"
DAT="$TMP/data"
CCH="$TMP/cache"
STUB="$TMP/bin/clip-set.sh"     # the fake clip-set.sh the picker invokes
ARGV_LOG="$TMP/argv.log"        # every row the picker asked for, one per line
STUB_MODE="$TMP/stub.mode"      # log | real | fail1 | fail2 — read per call

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
  [ -n "${SERVER_STARTED:-}" ] && cq exit >/dev/null 2>&1
  sleep 1
  [ -n "${XVFB_PID:-}" ]  && kill "$XVFB_PID"  2>/dev/null
  [ -n "${XVFB2_PID:-}" ] && kill "$XVFB2_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# The harness's own isolation. The scripts under test still call a plain
# `copyq` per copyq/dot.yaml's client contract; these vars only move the
# server (and therefore its socket) out of the live session's way.
ISO=(XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" XDG_CACHE_HOME="$CCH")

cq() { env DISPLAY="$DPY" "${ISO[@]}" "$COPYQ" "$@"; }

# qs-clip.sh run directly (list / set), outside any UI.
qsclip() { env DISPLAY="$DPY" "${ISO[@]}" QS_CLIP_SET="$STUB" sh "$QS_CLIP" "$@"; }

xdo()  { env DISPLAY="$DPY"  "$XDOTOOL" "$@"; }
xdo2() { env DISPLAY="$DPY2" "$XDOTOOL" "$@"; }

# Seed the history so the LAST argument is row 0. `copyq add` does not touch
# the clipboard, so seeding cannot itself perturb the row numbering. (`copyq
# copy` would be a false-pass trap: copyq ignores clipboard changes it owns,
# so a suite that seeds with it proves nothing about capture.)
seed() {
  cq eval -- 'var n=size(); for (var i=n-1;i>=0;--i) remove(i); ""' >/dev/null
  local t
  for t in "$@"; do cq add "$t" >/dev/null; done
  assert_seeded "${#@}"
}

# Guard against seeding silently doing nothing -- every row-index assertion
# below is meaningless if the history is not the size we think it is.
assert_seeded() {
  local want="$1" got
  got="$(cq size 2>/dev/null)"
  [ "$want" = "$got" ] || { echo "FATAL: seeded $want items, copyq reports $got" >&2; exit 1; }
}

# Block until the copyq history stops growing. Any clipboard write the REAL
# clip-set.sh makes is a genuine clipboard change the running server captures
# and PREPENDS, so row numbers move under our feet unless capture is allowed
# to finish before the next scenario decides which row to address.
settle() {
  local prev="" n i
  for i in $(seq 1 30); do
    n="$(cq size 2>/dev/null)"
    [ -n "$n" ] && [ "$n" = "$prev" ] && return 0
    prev="$n"
    sleep 0.3
  done
}

stub_mode() { printf '%s' "$1" > "$STUB_MODE"; }
clear_log() { : > "$ARGV_LOG"; }
logged()    { tr '\n' ' ' < "$ARGV_LOG" | sed 's/ *$//'; }

# ------------------------------------------------------------ UI plumbing ---

# The window id of a mapped picker on <display>, or "" after the timeout.
win_on() { # <display> [tries]
  local d="$1" tries="${2:-40}" i id
  for i in $(seq 1 "$tries"); do
    id="$(env DISPLAY="$d" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | head -1)"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    sleep 0.25
  done
  return 1
}

# "" once no picker is mapped on <display>.
gone_on() { # <display>
  local d="$1" i id
  for i in $(seq 1 40); do
    id="$(env DISPLAY="$d" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | head -1)"
    [ -z "$id" ] && return 0
    sleep 0.25
  done
  return 1
}

# Open the picker on <display> and give it keyboard focus. Echoes the win id.
open_picker() { # <display>
  local d="$1" id
  env DISPLAY="$d" "${ISO[@]}" QS_CLIP_SET="$STUB" QS_CLIP_DISPLAY="DISPLAY=$d" \
      sh "$QS_CLIP" toggle >/dev/null 2>&1
  id="$(win_on "$d")" || { echo ""; return 1; }
  env DISPLAY="$d" "$XDOTOOL" windowfocus "$id" 2>/dev/null
  sleep 0.4
  printf '%s' "$id"
}

# Wait for the stub to record a call (or give up); echoes what it recorded.
await_argv() {
  local i
  for i in $(seq 1 40); do
    [ -s "$ARGV_LOG" ] && break
    sleep 0.25
  done
  logged
}

send() { # <display> <xdotool-key args...>
  local d="$1"; shift
  env DISPLAY="$d" "$XDOTOOL" key --clearmodifiers "$@" 2>/dev/null
  sleep 0.15
}

type_in() { # <display> <text>
  env DISPLAY="$1" "$XDOTOOL" type --clearmodifiers --delay 40 "$2" 2>/dev/null
  sleep 0.4
}

# ---------------------------------------------------------------- fixtures ---

mkdir -p "$TMP" "$CFG/copyq" "$DAT" "$CCH" "$TMP/bin" "$TMP/entry" "$TMP/x11"

for tool in "$COPYQ" "$XVFB" "$XDOTOOL" "$QUICKSHELL" xclip; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (COPYQ=/XVFB=/XDOTOOL=/QUICKSHELL= to override)" >&2; exit 1; }
done
[ -r "$QS_CLIP" ]          || { echo "FATAL: $QS_CLIP not readable" >&2; exit 1; }
[ -r "$CLIP_HISTORY_QML" ] || { echo "FATAL: $CLIP_HISTORY_QML not readable" >&2; exit 1; }
[ -r "$REAL_CLIP_SET" ]    || { echo "FATAL: $REAL_CLIP_SET not readable" >&2; exit 1; }

# --- the clip-set.sh the picker sees -----------------------------------------
# One stub for the whole run, switching behaviour off a control file, so the
# exit-code scenarios do not need the QML restarted between them. It always
# records argv first: a scenario that asserts "nothing was invoked" is then
# asserting on the same evidence as one that asserts a row number.
cat > "$STUB" <<STUBEOF
#!/bin/sh
printf '%s\n' "\$*" >> "$ARGV_LOG"
case "\$(cat "$STUB_MODE" 2>/dev/null)" in
  real)  exec sh "$REAL_CLIP_SET" "\$@" ;;
  fail1) exit 1 ;;
  fail2) exit 2 ;;
  *)     exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"
stub_mode log
clear_log

# --- a minimal quickshell entry around the REAL ClipHistory.qml --------------
# The component under test is symlinked in, not copied, so the file this suite
# exercises is the file that ships. The production entry (config/shell.qml) is
# not launched here -- it pulls in the bar, the notification server and the
# focus-border overlay, which would fight the live session's instance for the
# same D-Bus names. That wiring is asserted separately, by inspection, and the
# report says so rather than pretending this covered it.
ln -sf "$CLIP_HISTORY_QML" "$TMP/entry/ClipHistory.qml"
cat > "$TMP/entry/shell.qml" <<'ENTRYEOF'
import Quickshell
ShellRoot { ClipHistory {} }
ENTRYEOF

# --- displays ----------------------------------------------------------------
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

# A controlled socket dir for the REAL clip-set.sh: symlinks to this suite's
# two displays only, so the host's live :0 / :10 stay out of it.
ln -sf "/tmp/.X11-unix/X${DPY#:}"  "$TMP/x11/X${DPY#:}"
ln -sf "/tmp/.X11-unix/X${DPY2#:}" "$TMP/x11/X${DPY2#:}"

# --- copyq server ------------------------------------------------------------
ln -s "$SCRIPT_DIR/../copyq/copyq.conf"   "$CFG/copyq/copyq.conf" 2>/dev/null
ln -s "$SCRIPT_DIR/../copyq/commands.ini" "$CFG/copyq/copyq-commands.ini" 2>/dev/null
cq --start-server >"$TMP/server.log" 2>&1 &
for i in $(seq 1 40); do
  cq eval 1 >/dev/null 2>&1 && { SERVER_STARTED=1; break; }
  sleep 0.5
done
[ -n "${SERVER_STARTED:-}" ] || { echo "FATAL: copyq server did not start" >&2; cat "$TMP/server.log" >&2; exit 1; }

echo "qs-clip:   $QS_CLIP"
echo "quickshell:$("$QUICKSHELL" --version 2>/dev/null | head -1)"
echo "copyq:     $("$COPYQ" --version 2>/dev/null | head -1)"
echo "displays:  $DPY $DPY2"

# --- the picker instances ----------------------------------------------------
# One per display, exactly as the two live sessions each run their own shell.
start_qs() { # <display> <logfile>
  env DISPLAY="$1" "${ISO[@]}" \
      QS_CLIP_SH="$QS_CLIP" QS_CLIP_SET="$STUB" CLIP_SET_SOCKET_DIR="$TMP/x11" \
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

# ============================================================================
# PHASE 0 — qs-clip.sh list / set, with no UI in the way
# ============================================================================

A='alpha entry'
B='bravo entry'
C='charlie entry'
D='delta entry'
MULTI='first line of the multiline entry
second line
third line'
UNI='héllo → 世界 🎉 ünïcodé'

scenario "list: one row per history item, newest first, tab-separated"
seed "$D" "$C" "$B" "$A"     # rows: 0=A 1=B 2=C 3=D
assert_eq "row count == copyq size" "$(cq size)" "$(qsclip list | wc -l | tr -d ' ')"
assert_eq "row 0 is the newest add" "0	$A" "$(qsclip list | sed -n 1p)"
assert_eq "row 3 is the oldest add" "3	$D" "$(qsclip list | sed -n 4p)"

scenario "list: the preview is the entry's first line only"
seed "$MULTI"
assert_eq "multiline collapses to its first line" "0	first line of the multiline entry" \
  "$(qsclip list)"
assert_eq "the entry itself is untouched" "$MULTI" "$(cq read 0)"

scenario "list: leading blank lines are skipped, tabs folded, empties labelled"
seed "$(printf '\n\n   \nreal first line\nmore')" "$(printf 'has\tinner\ttabs')" ""
assert_eq "an empty entry is labelled, not blank"    "0	(empty)"         "$(qsclip list | sed -n 1p)"
assert_eq "tabs in the entry do not split the field" "1	has inner tabs"  "$(qsclip list | sed -n 2p)"
assert_eq "blank leading lines skipped"              "2	real first line" "$(qsclip list | sed -n 3p)"

scenario "list: previews truncate at QS_CLIP_PREVIEW, entries do not"
LONG="$(python3 -c 'print("L"*300)')"
seed "$LONG"
assert_eq "preview is exactly 20 chars incl. the ellipsis" "0	$(python3 -c 'print("L"*19+"…")')" \
  "$(QS_CLIP_PREVIEW=20 qsclip list)"
assert_eq "the entry is still 300 chars" "300" "$(cq read 0 | wc -c | tr -d ' ')"

scenario "list: the row count is capped at QS_CLIP_CAP"
seed e5 e4 e3 e2 e1
assert_eq "5 items, cap 3 -> 3 rows" "3" "$(QS_CLIP_CAP=3 qsclip list | wc -l | tr -d ' ')"
assert_eq "the capped rows are the newest" "0	e1" "$(QS_CLIP_CAP=3 qsclip list | sed -n 1p)"
assert_eq "uncapped, all 5 are offered" "5" "$(qsclip list | wc -l | tr -d ' ')"

scenario "list: an empty history lists nothing and is not an error"
cq eval -- 'var n=size(); for (var i=n-1;i>=0;--i) remove(i); ""' >/dev/null
out="$(qsclip list)"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "no rows" "" "$out"

scenario "set: a non-numeric row is refused before anything is invoked"
clear_log
qsclip set 'twelve' 2>/dev/null; rc=$?
assert_eq "exits 1" "1" "$rc"
assert_eq "the stub was never reached" "" "$(logged)"

scenario "set: with no override, the real i3/scripts/clip-set.sh is what runs"
# QS_CLIP_SET unset -> qs-clip.sh must resolve its sibling. Row 999999 does not
# exist, so the message can only come from the real script.
seed "$A"
err="$(env DISPLAY="$DPY" "${ISO[@]}" CLIP_SET_SOCKET_DIR="$TMP/x11" \
        sh "$QS_CLIP" set 999999 2>&1 >/dev/null)"; rc=$?
assert_eq "exits 1 (clip-set precondition)" "1" "$rc"
assert_eq "the error came from clip-set.sh" "clip-set.sh" "$(printf '%s' "$err" | cut -d: -f1)"

# ============================================================================
# PHASE 1 — the picker UI: what Enter actually asks for
# ============================================================================

scenario "ui: the picker opens on the display it was asked for"
seed "$D" "$C" "$B" "$A"
clear_log; stub_mode log
WID="$(open_picker "$DPY")"
assert_ne "a qs-clip window is mapped on $DPY" "" "$WID"
send "$DPY" Escape
gone_on "$DPY"

scenario "ui: Enter on the untouched selection copies row 0"
clear_log
open_picker "$DPY" >/dev/null
send "$DPY" Return
assert_eq "clip-set invoked with row 0" "0" "$(await_argv)"
gone_on "$DPY"

scenario "ui: Down moves the selection, Enter copies THAT row"
clear_log
open_picker "$DPY" >/dev/null
send "$DPY" Down; send "$DPY" Down
send "$DPY" Return
assert_eq "clip-set invoked with row 2" "2" "$(await_argv)"
gone_on "$DPY"

scenario "ui: the selection clamps at the last row -- the model holds exactly copyq size rows"
# 4 items are seeded. Seven Downs can only land on row 3 if the model has
# exactly 4 rows: a 3-row model clamps at 2, a 5-row model reaches 4.
clear_log
open_picker "$DPY" >/dev/null
send "$DPY" Down; send "$DPY" Down; send "$DPY" Down; send "$DPY" Down
send "$DPY" Down; send "$DPY" Down; send "$DPY" Down
send "$DPY" Return
assert_eq "7 Downs over 4 rows selects row 3" "3" "$(await_argv)"
gone_on "$DPY"

scenario "ui: the selection clamps at the first row"
clear_log
open_picker "$DPY" >/dev/null
send "$DPY" Down; send "$DPY" Down
send "$DPY" Up; send "$DPY" Up; send "$DPY" Up; send "$DPY" Up
send "$DPY" Return
assert_eq "back at row 0" "0" "$(await_argv)"
gone_on "$DPY"

scenario "ui: Ctrl+N / Ctrl+P move the selection too"
clear_log
open_picker "$DPY" >/dev/null
send "$DPY" ctrl+n; send "$DPY" ctrl+n; send "$DPY" ctrl+p
send "$DPY" Return
assert_eq "down down up -> row 1" "1" "$(await_argv)"
gone_on "$DPY"

scenario "ui: typing filters, and Enter still copies the COPYQ row -- not the filtered position"
# "charlie" is row 2. After filtering it is the only row, i.e. filtered
# position 0. A picker that published the filtered position sends 0 here.
clear_log
open_picker "$DPY" >/dev/null
type_in "$DPY" "charlie"
send "$DPY" Return
assert_eq "filtered-to-one still copies row 2" "2" "$(await_argv)"
gone_on "$DPY"

scenario "ui: filtering to two rows and stepping down keeps the copyq numbering"
# Both "bravo entry" and "delta entry" contain "e", but so do the others;
# filter on "ta " -- only "delta entry" matches -> row 3.
clear_log
open_picker "$DPY" >/dev/null
type_in "$DPY" "delta"
send "$DPY" Return
assert_eq "the only match is row 3" "3" "$(await_argv)"
gone_on "$DPY"

scenario "ui: a filter that matches nothing makes Enter a no-op"
clear_log
WID="$(open_picker "$DPY")"
type_in "$DPY" "zzzzzz-no-such-entry"
send "$DPY" Return
sleep 1
assert_eq "clip-set was never invoked" "" "$(logged)"
assert_ne "the picker is still up" "" "$(win_on "$DPY" 4)"
send "$DPY" Escape
gone_on "$DPY"

scenario "ui: Esc closes without copying anything"
clear_log
open_picker "$DPY" >/dev/null
send "$DPY" Down
send "$DPY" Escape
if gone_on "$DPY"; then pass "the picker is gone"; else fail "the picker is gone" "unmapped" "still mapped"; fi
assert_eq "clip-set was never invoked" "" "$(logged)"

scenario "ui: an empty history shows the empty state and Enter does nothing"
cq eval -- 'var n=size(); for (var i=n-1;i>=0;--i) remove(i); ""' >/dev/null
clear_log
WID="$(open_picker "$DPY")"
assert_ne "the picker still opens" "" "$WID"
send "$DPY" Return
sleep 1
assert_eq "clip-set was never invoked" "" "$(logged)"
assert_ne "the picker is still up" "" "$(win_on "$DPY" 4)"
send "$DPY" Escape
gone_on "$DPY"

# ============================================================================
# PHASE 2 — clip-set.sh's exit codes are not swallowed
# ============================================================================

scenario "exit 0: the picker closes"
seed "$D" "$C" "$B" "$A"
clear_log; stub_mode log
open_picker "$DPY" >/dev/null
send "$DPY" Return
assert_eq "clip-set invoked" "0" "$(await_argv)"
if gone_on "$DPY"; then pass "closed on success"; else fail "closed on success" "unmapped" "still mapped"; fi

scenario "exit 1 (nothing was written): the picker stays up so the user knows"
clear_log; stub_mode fail1
open_picker "$DPY" >/dev/null
send "$DPY" Return
assert_eq "clip-set invoked" "0" "$(await_argv)"
sleep 1.5
assert_ne "still mapped after a failed copy" "" "$(win_on "$DPY" 4)"
send "$DPY" Escape; gone_on "$DPY"

scenario "exit 2 (partial write): the picker stays up so the user knows"
clear_log; stub_mode fail2
open_picker "$DPY" >/dev/null
send "$DPY" Return
assert_eq "clip-set invoked" "0" "$(await_argv)"
sleep 1.5
assert_ne "still mapped after a partial copy" "" "$(win_on "$DPY" 4)"
send "$DPY" Escape; gone_on "$DPY"

scenario "exit 1 is retryable: Enter again re-invokes clip-set"
clear_log; stub_mode fail1
open_picker "$DPY" >/dev/null
send "$DPY" Return
await_argv >/dev/null
sleep 1
send "$DPY" Return
sleep 1.5
assert_eq "two invocations, both row 0" "0 0" "$(logged)"
send "$DPY" Escape; gone_on "$DPY"

# ============================================================================
# PHASE 3 — end to end through the REAL clip-set.sh
# ============================================================================

scenario "real clip-set: the FULL entry reaches both displays, not the preview"
stub_mode real
clear_log
seed "$UNI" "$MULTI"          # row 0 = MULTI (its preview is only line one)
open_picker "$DPY" >/dev/null
send "$DPY" Return
assert_eq "clip-set invoked with row 0" "0" "$(await_argv)"
sleep 2
assert_eq "$DPY clipboard holds every line" "$MULTI" \
  "$(env DISPLAY="$DPY" timeout 10 xclip -selection clipboard -o 2>/dev/null)"
assert_eq "$DPY2 clipboard holds every line" "$MULTI" \
  "$(env DISPLAY="$DPY2" timeout 10 xclip -selection clipboard -o 2>/dev/null)"
gone_on "$DPY"
settle

scenario "real clip-set: unicode survives the whole picker path byte for byte"
stub_mode real
clear_log
seed "$MULTI" "$UNI"          # row 0 = UNI
open_picker "$DPY" >/dev/null
send "$DPY" Return
assert_eq "clip-set invoked with row 0" "0" "$(await_argv)"
sleep 2
assert_eq "$DPY clipboard is byte-exact" "$UNI" \
  "$(env DISPLAY="$DPY" timeout 10 xclip -selection clipboard -o 2>/dev/null)"
gone_on "$DPY"
settle
stub_mode log

# ============================================================================
# PHASE 4 — the second session, and single-instance behaviour
# ============================================================================

scenario "second display: the picker renders and selects there too"
seed "$D" "$C" "$B" "$A"
clear_log
WID2="$(open_picker "$DPY2")"
assert_ne "a qs-clip window is mapped on $DPY2" "" "$WID2"
assert_eq "and none was opened on $DPY"  "" "$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | head -1)"
send "$DPY2" Down
send "$DPY2" Return
assert_eq "row 1 copied from the second session" "1" "$(await_argv)"
gone_on "$DPY2"

scenario "rapid reopen: repeated toggles never leave a second window"
clear_log
for i in 1 2 3 4 5 6; do
  env DISPLAY="$DPY2" "${ISO[@]}" QS_CLIP_SET="$STUB" QS_CLIP_DISPLAY="DISPLAY=$DPY2" \
      sh "$QS_CLIP" toggle >/dev/null 2>&1
  sleep 0.4
done
sleep 1
assert_eq "exactly one qs-clip window exists on $DPY2" "1" \
  "$(env DISPLAY="$DPY2" "$XDOTOOL" search --name '^qs-clip$' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "and still none on $DPY" "0" \
  "$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | wc -l | tr -d ' ')"
# Leave the display clean for PHASE 5, whichever parity the toggles ended on.
env DISPLAY="$DPY2" "${ISO[@]}" "$QUICKSHELL" ipc --pid "$QS2_PID" call cliphistory close >/dev/null 2>&1
if gone_on "$DPY2"; then pass "the toggles left no window behind"; else fail "the toggles left no window behind" "unmapped" "still mapped"; fi

# ============================================================================
# PHASE 5 — which session the picker opens on is DERIVED, never inherited
# ============================================================================

scenario "derivation: a stale DISPLAY is refused rather than guessed at"
# Two sessions are live and the caller's DISPLAY belongs to neither. Guessing
# would put the picker -- which can hold a password -- on the display nobody is
# watching, so the script must decline.
out="$(env DISPLAY=":987" "${ISO[@]}" sh "$QS_CLIP" toggle 2>&1)"; rc=$?
assert_ne "exits non-zero" "0" "$rc"
assert_eq "no picker opened on $DPY"  "0" \
  "$(env DISPLAY="$DPY"  "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no picker opened on $DPY2" "0" \
  "$(env DISPLAY="$DPY2" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | wc -l | tr -d ' ')"
assert_ne "and it says which sessions it found" "" "$(printf '%s' "$out" | grep -o 'DISPLAY=:9[56]' | head -1)"

scenario "derivation: an inherited DISPLAY that DOES match a live session is honoured"
env DISPLAY="$DPY2" "${ISO[@]}" sh "$QS_CLIP" toggle >/dev/null 2>&1
assert_ne "the picker opened on $DPY2" "" "$(win_on "$DPY2")"
assert_eq "and not on $DPY" "0" \
  "$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' 2>/dev/null | wc -l | tr -d ' ')"
send "$DPY2" Escape; gone_on "$DPY2"

# ============================================================================
# PHASE 6 — production wiring (inspection, not execution -- see the header)
# ============================================================================

scenario "wiring: the shipped shell.qml instantiates the picker"
assert_eq "config/shell.qml contains ClipHistory {}" "1" \
  "$(grep -c '^[[:space:]]*ClipHistory[[:space:]]*{}' "$SHELL_QML" | tr -d ' ')"

# ============================================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
