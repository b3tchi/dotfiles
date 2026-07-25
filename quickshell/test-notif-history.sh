#!/usr/bin/env bash
# test-notif-history.sh — verify the notification-history contract script
# (quickshell/qs-notif.sh): sp019 task 5, dotfiles-c5fd.5.
#
# STRUCTURE (load-bearing for task .6, dotfiles-c5fd.6, which APPENDS UI
# phases to this same file rather than starting a new suite):
#
#   PHASE 0 — list / dismiss, headless, no X, no daemon. Fixtures are plain
#             files written directly into an isolated store dir, exactly the
#             "seeding IS writing files" discipline test-clip-history.sh's
#             PHASE 0 and test-notif-store.sh both use.
#   PHASE 1 — toggle's session-derivation regression, Xvfb + a throwaway QML
#             stub exposing the `notifhistory` IPC target (NOT the real
#             NotifHistory.qml browser — that is task .6's own deliverable
#             and does not exist yet when this task lands). The derivation
#             logic under test (candidates()/session_key_of()/cmd_toggle) is
#             copied verbatim from qs-clip.sh, so a minimal stub that merely
#             ANSWERS the IPC target and shows a window is sufficient to
#             regression-test it — adapted 1:1 from test-clip-history.sh's
#             own PHASE 1.
#   PHASE 2 — reserved for task .6's UI scenarios against the real
#             NotifHistory.qml (NotifHistory.toggle-opens-newest-first,
#             enter-dismisses-stays-open, etc. — see sp019.md Task 6's
#             test_plan). Nothing below this task's PHASE 1 boundary marker
#             is written by task .5; task .6 appends after it.
#
# usage: quickshell/test-notif-history.sh
# env:   XVFB= XDOTOOL= QUICKSHELL=   (default: from PATH; PHASE 0 needs none)
#        TEST_DISPLAY=:95 TEST_DISPLAY2=:96
#        SELFTEST=1   (negative control: flips one expectation, MUST fail)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QS_NOTIF="$SCRIPT_DIR/qs-notif.sh"

XVFB="${XVFB:-Xvfb}"
XDOTOOL="${XDOTOOL:-xdotool}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
DPY="${TEST_DISPLAY:-:95}"
DPY2="${TEST_DISPLAY2:-:96}"

TMP="/tmp/qs-notif-history-test.$$"
STATE="$TMP/state"   # XDG_STATE_HOME stand-in
RUN="$TMP/run"        # XDG_RUNTIME_DIR stand-in
STORE="$STATE/qs-notif"
FIFO="$RUN/qs-notif.cmd"

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
  [ -n "${QS_PID:-}" ]    && kill "$QS_PID"    2>/dev/null
  [ -n "${QS2_PID:-}" ]   && kill "$QS2_PID"   2>/dev/null
  [ -n "${NOTIF_PID:-}" ] && kill "$NOTIF_PID" 2>/dev/null
  [ -n "${FIFO_READER_PID:-}" ] && kill "$FIFO_READER_PID" 2>/dev/null
  sleep 1
  [ -n "${XVFB_PID:-}" ]  && kill "$XVFB_PID"  2>/dev/null
  [ -n "${XVFB2_PID:-}" ] && kill "$XVFB2_PID" 2>/dev/null
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP" "$STATE" "$RUN"
chmod 700 "$RUN"

[ -r "$QS_NOTIF" ] || { echo "FATAL: $QS_NOTIF not readable" >&2; exit 1; }
command -v gawk    >/dev/null 2>&1 || { echo "FATAL: gawk not found (qs-notif.sh's preview_of needs it)" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "FATAL: timeout not found (qs-notif.sh dismiss needs it)" >&2; exit 1; }
command -v mkfifo  >/dev/null 2>&1 || { echo "FATAL: mkfifo not found" >&2; exit 1; }

NOW="$(date +%s)"

# --- store fixtures -----------------------------------------------------------
# Seeding IS writing files -- no daemon, no append call. Matches the
# qs-notif-store.sh contract byte-for-byte: line 1 header, line 2 summary,
# line 3+ raw body -- but written directly so a scenario can construct
# exactly the bytes it wants to assert on, independent of the store's own
# folding (qs-notif.sh's preview_of is what is under test here, not the
# store's append).

reset_store() { rm -rf "$STORE"; }
mk_store()    { mkdir -p "$STORE"; chmod 700 "$STORE"; }

write_entry() { # <seq> <epoch> <urgency> <app> <summary> <body>
  mk_store
  {
    printf '%s\t%s\t%s\n' "$2" "$3" "$4"
    printf '%s\n' "$5"
    printf '%s' "$6"
  } > "$STORE/$(printf '%06d' "$1").notif"
}

# qs-notif.sh run directly (list / dismiss) against the isolated XDG tree --
# exactly how a real quickshell instance's own environment would resolve it.
qsnotif() {
  env XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$RUN" sh "$QS_NOTIF" "$@"
}

echo "qs-notif: $QS_NOTIF"
echo "store:    $STORE"
echo "fifo:     $FIFO"

# ============================================================================
# PHASE 0 — qs-notif.sh list / dismiss, headless, no X, no daemon
# ============================================================================

# ---- empty-store-exit0 ------------------------------------------------------

scenario "empty-store-exit0: an absent store dir lists nothing and exits 0"
reset_store
out="$(qsnotif list)"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "no output" "" "$out"

scenario "empty-store-exit0: an empty (but existing) store dir lists nothing and exits 0"
mk_store
out="$(qsnotif list)"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "no output" "" "$out"

# ---- list-newest-first-deterministic -----------------------------------------

scenario "list-newest-first-deterministic: newest-first order, byte-identical across two calls"
reset_store
write_entry 1 "$NOW" normal app "alpha"   "alpha body"
write_entry 2 "$NOW" normal app "bravo"   "bravo body"
write_entry 3 "$NOW" normal app "charlie" "charlie body"
out1="$(qsnotif list)"
out2="$(qsnotif list)"
assert_eq "two consecutive calls over an unchanged store are byte-identical" "$out1" "$out2"
assert_eq "3 rows" "3" "$(printf '%s\n' "$out1" | wc -l | tr -d ' ')"
assert_eq "first row is the highest seq (000003)" "000003.notif" "$(printf '%s\n' "$out1" | sed -n 1p | cut -f1)"
assert_eq "last row is the lowest seq (000001)"   "000001.notif" "$(printf '%s\n' "$out1" | sed -n 3p | cut -f1)"

scenario "list: order survives reversed mtimes -- ordering is by filename, never mtime"
reset_store
write_entry 1 "$NOW" normal app "alpha" "a"
write_entry 2 "$NOW" normal app "bravo" "b"
write_entry 3 "$NOW" normal app "charlie" "c"
touch -d '2020-01-01' "$STORE/000003.notif"   # newest seq, oldest mtime
touch -d '2030-01-01' "$STORE/000001.notif"   # oldest seq, newest mtime
assert_eq "still seq order despite an mtime tie/reversal" "000003.notif" "$(qsnotif list | sed -n 1p | cut -f1)"

# ---- preview-fold-truncate-unicode -------------------------------------------

scenario "preview: summary + folded-body-first-line, tab in the summary does not break the id/preview separator"
reset_store
write_entry 1 "$NOW" normal app "$(printf 'hello\tworld')" "$(printf '\n\n  \nreal first line\nmore')"
line="$(qsnotif list)"
assert_eq "exactly one literal tab remains on the whole line (the id/preview separator)" \
  "1" "$(printf '%s' "$line" | tr -cd '\t' | wc -c | tr -d ' ')"
assert_eq "summary's tab folded to a space, leading blank body lines skipped, first real body line used" \
  "000001.notif	just now  hello world — real first line" "$line"

scenario "preview: a summary that is entirely whitespace falls back to the folded body line"
reset_store
write_entry 1 "$NOW" normal app "   " "the body line"
assert_eq "preview is the time + body line, no dangling separator" \
  "000001.notif	just now  the body line" "$(qsnotif list)"

scenario "preview: a whitespace-only summary AND an empty body renders (empty)"
reset_store
write_entry 1 "$NOW" normal app "   " ""
assert_eq "preview falls all the way back to (empty)" \
  "000001.notif	just now  (empty)" "$(qsnotif list)"

scenario "preview: unicode content produces a correct, non-mangled preview"
reset_store
write_entry 1 "$NOW" normal app "héllo → 世界" "🎉 ünïcodé body"
assert_eq "unicode preview intact" "000001.notif	just now  héllo → 世界 — 🎉 ünïcodé body" "$(qsnotif list)"

scenario "preview: QS_NOTIF_PREVIEW truncates on a CHARACTER boundary (multi-byte safe), never mid-byte"
reset_store
write_entry 1 "$NOW" normal app "héllo → 世界 ünïcodé long summary text here" "body irrelevant for this cut"
full="$(qsnotif list | cut -f2-)"
trunc="$(QS_NOTIF_PREVIEW=10 qsnotif list | cut -f2-)"
assert_eq "truncated preview is exactly 10 characters (gawk length(), UTF-8 char-aware)" \
  "10" "$(printf '%s' "$trunc" | wc -m | tr -d ' ')"
assert_eq "the last character is the ellipsis" "…" "$(printf '%s' "$trunc" | tail -c 3)"
assert_eq "the first 9 characters are an exact prefix of the untruncated preview (proves a real boundary cut, not garbage)" \
  "$(printf '%s' "$full" | head -c "$(printf '%s' "$full" | head -c 9 | wc -c)")" \
  "$(printf '%s' "$trunc" | head -c "$(( $(printf '%s' "$trunc" | wc -c) - 3 ))")"
assert_eq "the byte stream is still valid UTF-8 (no multi-byte sequence was split)" "0" \
  "$(printf '%s' "$trunc" | iconv -f utf-8 -t utf-8 >/dev/null 2>&1; echo $?)"

# ---- stray-file-skipped -------------------------------------------------------

scenario "stray-file-skipped: non-conforming filenames never appear in list"
reset_store
write_entry 1 "$NOW" normal app "alpha" "alpha body"
write_entry 2 "$NOW" normal app "bravo" "bravo body"
: > "$STORE/0000001.notif"     # 7 digits -- not the 6-digit shape
: > "$STORE/abcdef.notif"      # not digits at all
: > "$STORE/.wip.999"          # a writer work file
: > "$STORE/000003.notif.tmp"  # an in-flight tmp
assert_eq "only the two real entries are listed" "2" "$(qsnotif list | wc -l | tr -d ' ')"
assert_eq "the newest real entry is still first" "000002.notif" "$(qsnotif list | sed -n 1p | cut -f1)"

# ---- id-shape-reject -----------------------------------------------------------

scenario "id-shape-reject: path-traversal and 7-digit ids are refused before any fifo touch (fast rejection proves it)"
rm -f "$FIFO"; mkfifo "$FIFO"   # present but nobody ever reads it
t0=$(date +%s%N)
env XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$RUN" sh "$QS_NOTIF" dismiss '../../etc/passwd' 2>/dev/null
rc1=$?
env XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$RUN" sh "$QS_NOTIF" dismiss '1234567.notif' 2>/dev/null
rc2=$?
t1=$(date +%s%N)
elapsed_ms=$(( (t1 - t0) / 1000000 ))
assert_eq "path-traversal id refused (exit 1)" "1" "$rc1"
assert_eq "7-digit id refused (exit 1)" "1" "$rc2"
assert_eq "both rejections were fast -- never blocked opening the reader-less fifo" "yes" \
  "$([ "$elapsed_ms" -lt 500 ] && echo yes || echo no)"
rm -f "$FIFO"

# ---- dismiss-writes-fifo-line --------------------------------------------------

scenario "dismiss-writes-fifo-line: a reader holding the fifo open receives EXACTLY 'dismiss <id>'"
rm -f "$FIFO"; mkfifo "$FIFO"
OUT="$TMP/fifo-line.out"; rm -f "$OUT"
( cat "$FIFO" > "$OUT" ) &
READER_PID=$!
env XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$RUN" sh "$QS_NOTIF" dismiss 000042.notif
rc=$?
wait "$READER_PID"
assert_eq "exits 0" "0" "$rc"
assert_eq "the daemon side receives exactly one line: dismiss 000042.notif" "dismiss 000042.notif" "$(cat "$OUT")"
rm -f "$FIFO" "$OUT"

scenario "dismiss-writes-fifo-line: 'latest' is forwarded literally, never resolved by this script"
rm -f "$FIFO"; mkfifo "$FIFO"
OUT="$TMP/fifo-line2.out"; rm -f "$OUT"
( cat "$FIFO" > "$OUT" ) &
READER_PID=$!
env XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$RUN" sh "$QS_NOTIF" dismiss latest
rc=$?
wait "$READER_PID"
assert_eq "exits 0" "0" "$rc"
assert_eq "the literal word 'latest' reaches the daemon, unresolved here" "dismiss latest" "$(cat "$OUT")"
rm -f "$FIFO" "$OUT"

scenario "dismiss: a vanished entry (age-pruned between list and dismiss) still writes to the fifo -- this script never touches the store"
reset_store
rm -f "$FIFO"; mkfifo "$FIFO"
OUT="$TMP/fifo-line3.out"; rm -f "$OUT"
( cat "$FIFO" > "$OUT" ) &
READER_PID=$!
env XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$RUN" sh "$QS_NOTIF" dismiss 000099.notif
rc=$?
wait "$READER_PID"
assert_eq "exits 0 -- the fifo write succeeds regardless of whether the entry still exists" "0" "$rc"
assert_eq "the daemon side still receives the dismiss line" "dismiss 000099.notif" "$(cat "$OUT")"
rm -f "$FIFO" "$OUT"

# ---- dismiss-no-daemon-exit1-bounded (TIMED) -----------------------------------
#
# Determinism (learned from Task 1's rejection, per the task brief): the "no
# reader" case is produced BY CONSTRUCTION here -- a fifo that structurally
# never has a reader -- not by a race against a daemon that might or might not
# answer in time. The only genuinely timed part is proving the wait is
# BOUNDED. QS_NOTIF_FIFO_TIMEOUT is overridden to 1s (production default is
# 2s) so the assertion below proves the <2s contract with a full second of
# margin against scheduler/CPU-load jitter -- never asserting right at the
# 2s edge.

scenario "dismiss-no-daemon-exit1-bounded: no reader on the fifo -> exit 1, bounded, deterministic (not a timing race)"
rm -f "$FIFO"; mkfifo "$FIFO"
start_ns=$(date +%s%N)
out="$(env XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$RUN" QS_NOTIF_FIFO_TIMEOUT=1 sh "$QS_NOTIF" dismiss 000001.notif 2>&1)"
rc=$?
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
assert_eq "exits 1" "1" "$rc"
assert_ne "prints an error message" "" "$out"
assert_eq "completes well within the 2s spec bound (1s inner timeout + 1s margin)" "yes" \
  "$([ "$elapsed_ms" -lt 2000 ] && echo yes || echo no)"
assert_eq "and did not return implausibly instantly -- the open really blocked on the inner timeout" "yes" \
  "$([ "$elapsed_ms" -ge 900 ] && echo yes || echo no)"
rm -f "$FIFO"

# ---- xdg-unset ------------------------------------------------------------------

scenario "list: HOME and XDG_STATE_HOME both unset fails loudly (exit 78), not silently"
rc="$(env -u HOME -u XDG_STATE_HOME sh "$QS_NOTIF" list >/dev/null 2>&1; echo $?)"
assert_eq "list exits 78" "78" "$rc"

scenario "dismiss: XDG_RUNTIME_DIR unset (and no QS_NOTIF_FIFO override) fails loudly (exit 78)"
rc="$(env -u XDG_RUNTIME_DIR sh "$QS_NOTIF" dismiss latest >/dev/null 2>&1; echo $?)"
assert_eq "dismiss exits 78" "78" "$rc"

scenario "dismiss: QS_NOTIF_FIFO override bypasses the XDG_RUNTIME_DIR requirement"
ALT_FIFO="$TMP/alt.cmd"
rm -f "$ALT_FIFO"; mkfifo "$ALT_FIFO"
OUT="$TMP/alt-fifo.out"; rm -f "$OUT"
( cat "$ALT_FIFO" > "$OUT" ) &
READER_PID=$!
rc="$(env -u XDG_RUNTIME_DIR QS_NOTIF_FIFO="$ALT_FIFO" sh "$QS_NOTIF" dismiss 000001.notif >/dev/null 2>&1; echo $?)"
wait "$READER_PID"
assert_eq "exits 0 (XDG_RUNTIME_DIR is irrelevant once QS_NOTIF_FIFO is set)" "0" "$rc"
assert_eq "the override path received the line" "dismiss 000001.notif" "$(cat "$OUT")"
rm -f "$ALT_FIFO" "$OUT"

# ---- usage errors ---------------------------------------------------------------

scenario "dismiss: wrong argument count is a usage error"
rc="$(qsnotif dismiss 2>/dev/null; echo $?)"
assert_eq "no id given -> exit 1" "1" "$rc"

scenario "main: an unknown verb is a usage error"
rc="$(qsnotif frobnicate 2>/dev/null; echo $?)"
assert_eq "unknown verb -> exit 1" "1" "$rc"

# ============================================================================
# PHASE 1 — toggle: session derivation (Xvfb regression, adapted verbatim
#           from test-clip-history.sh's PHASE 1 -- target string only differs)
# ============================================================================
#
# candidates()/session_key_of()/cmd_toggle are copied from qs-clip.sh
# unmodified in spirit (only TARGET and the QS_NOTIF_DISPLAY override name
# differ), so this is a REGRESSION check on that shared mechanism, not new
# coverage: with two live quickshell instances and no environment match, the
# browser still refuses and NAMES the sessions rather than guessing which one
# to open on.
#
# The stub below is a THROWAWAY QML double exposing the `notifhistory` IPC
# target and a small window -- NOT the real NotifHistory.qml (task .6's
# deliverable, which does not exist when this task lands). It is sufficient
# to regression-test derivation because derivation never looks at what the
# target does, only whether a live instance answers it.

for tool in "$XVFB" "$XDOTOOL" "$QUICKSHELL"; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (XVFB=/XDOTOOL=/QUICKSHELL= to override)" >&2; exit 1; }
done

mkdir -p "$TMP/entry"
cat > "$TMP/entry/NotifStub.qml" <<'STUBEOF'
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Window

Scope {
    id: root

    IpcHandler {
        target: "notifhistory"
        function toggle(): void {
            if (win.visible) win.visible = false
            else win.visible = true
        }
        function open(): void { win.visible = true }
        function close(): void { win.visible = false }
    }

    Window {
        id: win
        visible: false
        width: 200
        height: 100
        title: "qs-notif"
    }
}
STUBEOF
cat > "$TMP/entry/shell.qml" <<'ENTRYEOF'
import Quickshell
ShellRoot { NotifStub {} }
ENTRYEOF

ISO=(XDG_CONFIG_HOME="$TMP/cfg" XDG_DATA_HOME="$TMP/data" XDG_CACHE_HOME="$TMP/cache" XDG_RUNTIME_DIR="$RUN")
mkdir -p "$TMP/cfg" "$TMP/data" "$TMP/cache"

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
  env DISPLAY="$1" "${ISO[@]}" "$QUICKSHELL" -p "$TMP/entry" >"$2" 2>&1 &
  printf '%s' $!
}
QS_PID="$(start_qs "$DPY"  "$TMP/qs.log")"
QS2_PID="$(start_qs "$DPY2" "$TMP/qs2.log")"

for i in $(seq 1 40); do
  a="$(env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$QS_PID"  show 2>/dev/null | grep -c 'notifhistory')"
  b="$(env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$QS2_PID" show 2>/dev/null | grep -c 'notifhistory')"
  [ "${a:-0}" -gt 0 ] && [ "${b:-0}" -gt 0 ] && { QS_UP=1; break; }
  sleep 0.5
done
[ -n "${QS_UP:-}" ] || { echo "FATAL: stub instances did not expose notifhistory" >&2; tail -20 "$TMP/qs.log" >&2; exit 1; }

win_on() { # <display> [tries]
  local d="$1" tries="${2:-40}" i id
  for i in $(seq 1 "$tries"); do
    id="$(env DISPLAY="$d" "$XDOTOOL" search --onlyvisible --name '^qs-notif$' 2>/dev/null | head -1)"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    sleep 0.25
  done
  return 1
}

gone_on() { # <display>
  local d="$1" i id
  for i in $(seq 1 40); do
    id="$(env DISPLAY="$d" "$XDOTOOL" search --onlyvisible --name '^qs-notif$' 2>/dev/null | head -1)"
    [ -z "$id" ] && return 0
    sleep 0.25
  done
  return 1
}

pid_for() { case "$1" in "$DPY") printf '%s' "$QS_PID" ;; *) printf '%s' "$QS2_PID" ;; esac; }

close_stub() { # <display>
  env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$(pid_for "$1")" call notifhistory close >/dev/null 2>&1
  gone_on "$1"
}

scenario "derivation: the browser opens on the display it was asked for"
close_stub "$DPY"
env DISPLAY="$DPY" "${ISO[@]}" QS_NOTIF_DISPLAY="DISPLAY=$DPY" sh "$QS_NOTIF" toggle >/dev/null 2>&1
WID="$(win_on "$DPY")"
assert_ne "a qs-notif window is mapped on $DPY" "" "$WID"
close_stub "$DPY"

scenario "derivation: a stale DISPLAY is refused rather than guessed at"
# Two sessions are live and the caller's DISPLAY belongs to neither. Guessing
# would put the browser on the display nobody is watching, so the script
# must decline and name the live sessions instead.
out="$(env DISPLAY=":987" "${ISO[@]}" sh "$QS_NOTIF" toggle 2>&1)"; rc=$?
assert_ne "exits non-zero" "0" "$rc"
assert_eq "no browser opened on $DPY"  "0" \
  "$(env DISPLAY="$DPY"  "$XDOTOOL" search --onlyvisible --name '^qs-notif$' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no browser opened on $DPY2" "0" \
  "$(env DISPLAY="$DPY2" "$XDOTOOL" search --onlyvisible --name '^qs-notif$' 2>/dev/null | wc -l | tr -d ' ')"
assert_ne "and it says which sessions it found" "" "$(printf '%s' "$out" | grep -o 'DISPLAY=:9[56]' | head -1)"

scenario "derivation: an inherited DISPLAY that DOES match a live session is honoured"
close_stub "$DPY2"
env DISPLAY="$DPY2" "${ISO[@]}" sh "$QS_NOTIF" toggle >/dev/null 2>&1
WID2="$(win_on "$DPY2")"
assert_ne "the browser opened on $DPY2" "" "$WID2"
assert_eq "and not on $DPY" "0" \
  "$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-notif$' 2>/dev/null | wc -l | tr -d ' ')"
close_stub "$DPY2"

# ============================================================================
# PHASE 1 boundary -- task .6 (dotfiles-c5fd.6) appends PHASE 2 (the real
# NotifHistory.qml UI scenarios) below this line. Nothing above is to be
# reordered or renumbered by that task.
# ============================================================================

# ============================================================================
# PHASE 2 -- the real NotifHistory.qml browser (sp019 task 6, dotfiles-c5fd.6)
# ============================================================================
#
# PHASE 1's stub instances (QS_PID/QS2_PID) are retired here -- they only
# ever existed to regression-test toggle's session derivation against a
# throwaway double, and this phase needs the notifhistory IPC target free on
# $DPY for the REAL browser.
#
# A harness-owned background loop stands in for the daemon on the FIFO
# (qs-notif.sh's `dismiss` contract only needs a READER for the write to
# succeed -- see qs-notif.sh's header -- so this loop reads each "dismiss
# <id>" line and, playing the daemon's part, removes the matching store file
# itself: that is what makes NotifHistory.qml's post-dismiss re-`list` show
# the entry actually gone, exactly as a real daemon round-trip would).

NOTIF_HISTORY_QML="$SCRIPT_DIR/config/NotifHistory.qml"
[ -r "$NOTIF_HISTORY_QML" ] || { echo "FATAL: $NOTIF_HISTORY_QML not readable" >&2; exit 1; }

kill "$QS_PID"  2>/dev/null; wait "$QS_PID"  2>/dev/null; QS_PID=""
kill "$QS2_PID" 2>/dev/null; wait "$QS2_PID" 2>/dev/null; QS2_PID=""

mkdir -p "$TMP/entry2"
ln -sf "$NOTIF_HISTORY_QML" "$TMP/entry2/NotifHistory.qml"
ln -sf "$SCRIPT_DIR/config/Common" "$TMP/entry2/Common"
cat > "$TMP/entry2/shell.qml" <<'ENTRYEOF'
import Quickshell
ShellRoot { NotifHistory {} }
ENTRYEOF

NOTIF_PID="$(env DISPLAY="$DPY" "${ISO[@]}" \
               XDG_STATE_HOME="$STATE" \
               QS_NOTIF_SH="$QS_NOTIF" \
               "$QUICKSHELL" -p "$TMP/entry2" >"$TMP/qs-phase2.log" 2>&1 & printf '%s' $!)"
for i in $(seq 1 40); do
  a="$(env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$NOTIF_PID" show 2>/dev/null | grep -c 'notifhistory')"
  [ "${a:-0}" -gt 0 ] && break
  sleep 0.25
done
[ "${a:-0}" -gt 0 ] || { echo "FATAL: the real NotifHistory instance did not expose notifhistory" >&2; tail -20 "$TMP/qs-phase2.log" >&2; exit 1; }

# --- daemon-stub FIFO reader --------------------------------------------------

FIFO_DELAY="$TMP/fifo-delay"
FIFO_READER_LOG="$TMP/fifo-reader.log"
printf '0' > "$FIFO_DELAY"
: > "$FIFO_READER_LOG"

start_daemon_stub() {
  rm -f "$FIFO"; mkfifo "$FIFO"
  ( while true; do
      d="$(cat "$FIFO_DELAY" 2>/dev/null)"; d="${d:-0}"
      case "$d" in ''|*[!0-9.]*) d=0 ;; esac
      [ "$d" != "0" ] && sleep "$d"
      if IFS= read -r line < "$FIFO" 2>/dev/null; then
        printf '%s\n' "$line" >> "$FIFO_READER_LOG"
        case "$line" in
          dismiss\ *)
            _id="${line#dismiss }"
            case "$_id" in
              [0-9][0-9][0-9][0-9][0-9][0-9].notif) rm -f "$STORE/$_id" ;;
            esac
            ;;
        esac
      fi
    done ) &
  FIFO_READER_PID=$!
}
stop_daemon_stub() {
  [ -n "${FIFO_READER_PID:-}" ] && kill "$FIFO_READER_PID" 2>/dev/null
  FIFO_READER_PID=""
  rm -f "$FIFO"
}
set_daemon_delay() { printf '%s' "$1" > "$FIFO_DELAY"; }
clear_fifo_reader_log() { : > "$FIFO_READER_LOG"; }
fifo_reader_lines() { wc -l < "$FIFO_READER_LOG" | tr -d ' '; }

# --- window + keyboard helpers ------------------------------------------------

win_notif() { # [tries]
  local tries="${1:-40}" i id
  for i in $(seq 1 "$tries"); do
    id="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-notif$' 2>/dev/null | head -1)"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    sleep 0.25
  done
  return 1
}

gone_notif() { # [tries]
  local tries="${1:-40}" i id
  for i in $(seq 1 "$tries"); do
    id="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-notif$' 2>/dev/null | head -1)"
    [ -z "$id" ] && return 0
    sleep 0.25
  done
  return 1
}

# A store entry file staying gone (not just "gone right now") -- proves a
# dismiss really landed, not a race about to be won the other way.
wait_gone() { # <path> [tries]
  local f="$1" tries="${2:-40}" i
  for i in $(seq 1 "$tries"); do
    [ ! -e "$f" ] && return 0
    sleep 0.1
  done
  return 1
}

# A store entry file staying present across a bounded window -- proves a
# dismiss did NOT fire, not just "hasn't yet".
stays_present() { # <path> [hold-ticks]
  local f="$1" hold="${2:-10}" i
  for i in $(seq 1 "$hold"); do
    [ ! -e "$f" ] && return 1
    sleep 0.1
  done
  return 0
}

browser_toggle() {
  env DISPLAY="$DPY" "${ISO[@]}" QS_NOTIF_DISPLAY="DISPLAY=$DPY" sh "$QS_NOTIF" toggle >/dev/null 2>&1
}
browser_close() {
  env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$NOTIF_PID" call notifhistory close >/dev/null 2>&1
  gone_notif >/dev/null
}
send() { env DISPLAY="$DPY" "$XDOTOOL" key --clearmodifiers "$@" 2>/dev/null; sleep 0.15; }
typ()  { env DISPLAY="$DPY" "$XDOTOOL" type --clearmodifiers "$1" 2>/dev/null; sleep 0.3; }
open_and_focus() {
  browser_close
  browser_toggle
  WID="$(win_notif)"
  [ -n "$WID" ] && env DISPLAY="$DPY" "$XDOTOOL" windowfocus "$WID" 2>/dev/null
  sleep 0.4
  printf '%s' "$WID"
}

start_daemon_stub

# ---- toggle-opens-newest-first + not-a-position (mutant pin) -----------------
#
# Seeds three entries, filters down to a NON-newest one by a substring unique
# to it, and dismisses via Enter. A "confirm handler fed filtered[0]"
# mutant -- ignoring the confirmed row and always acting on the newest
# overall entry -- would remove 000003.notif (the newest) instead; this
# scenario fails on that mutant because it asserts specifically on
# 000002.notif's file, not "some file disappeared".

scenario "toggle-opens-newest-first / enter-dismisses-stays-open: filtering onto a NON-newest row and confirming dismisses THAT row (mutant pin: not filtered[0]/newest)"
reset_store
write_entry 1 "$NOW" normal app "oldest-decoy" "irrelevant"
write_entry 2 "$NOW" normal app "unique-target-xyz" "irrelevant"
write_entry 3 "$NOW" normal app "newest-decoy" "irrelevant"
clear_fifo_reader_log
WID="$(open_and_focus)"
assert_ne "browser opened on $DPY" "" "$WID"
typ "unique-target"
send Return
assert_eq "the FILTERED (non-newest) entry's store file is gone" "0" \
  "$([ -e "$STORE/000002.notif" ] && echo 1 || echo 0)"
wait_gone "$STORE/000002.notif"
assert_eq "the entry the filter actually matched (000002.notif, not the newest 000003.notif) was dismissed" "yes" \
  "$([ ! -e "$STORE/000002.notif" ] && echo yes || echo no)"
assert_eq "the newest entry (000003.notif) was left untouched -- a filtered[0]/newest-only mutant would have removed THIS one instead" \
  "present" "$([ -e "$STORE/000003.notif" ] && echo present || echo MISSING)"
assert_ne "the picker STAYS OPEN after a successful dismiss (ClipHistory's publish would have closed it; dismiss never does)" "" \
  "$(win_notif 10)"

# ---- select-non-zero-row-under-filter (stronger mutant pin) -------------------
#
# The scenario above pins "confirm ignores the filter and always acts on the
# newest entry overall". It does NOT pin a narrower bug: a filter that
# matches MULTIPLE rows, confirm always acting on the FILTERED list's row 0
# regardless of which row is actually SELECTED (Down-navigated). All three
# entries below match the same filter substring, so the filtered list itself
# has 3 rows; one Down moves off row 0 onto row 1, and Enter must dismiss
# THAT row -- a "confirmCurrent() always uses filtered[0]" mutant would
# remove the row-0 entry (000003.notif) instead, exactly the divergence this
# scenario is built to catch (unlike the scenario above, where the filter had
# already narrowed to a single match and any positional bug within the
# filtered list could not have been observed).

scenario "select-non-zero-row-under-filter: Down-navigating within a multi-match filter, then Enter, dismisses the SELECTED row -- not filtered-list position 0"
reset_store
write_entry 1 "$NOW" normal app "match-alpha"   "irrelevant"
write_entry 2 "$NOW" normal app "match-bravo"   "irrelevant"
write_entry 3 "$NOW" normal app "match-charlie" "irrelevant"
clear_fifo_reader_log
WID="$(open_and_focus)"
assert_ne "browser opened" "" "$WID"
typ "match"
# Filtered list is newest-first, all three still match "match": row 0 =
# 000003.notif (charlie), row 1 = 000002.notif (bravo), row 2 = 000001.notif
# (alpha). One Down selects row 1.
send Down
send Return
assert_eq "row 1 (000002.notif) -- the one actually SELECTED -- was dismissed" "yes" \
  "$(wait_gone "$STORE/000002.notif" && echo yes || echo no)"
assert_eq "row 0 (000003.notif) was left untouched -- a filtered[0]-always mutant would have removed THIS one" \
  "present" "$([ -e "$STORE/000003.notif" ] && echo present || echo MISSING)"
assert_eq "row 2 (000001.notif) was left untouched" "present" \
  "$([ -e "$STORE/000001.notif" ] && echo present || echo MISSING)"
browser_close

# ---- enter-dismisses-stays-open (newest row, plain case) ---------------------

scenario "enter-dismisses-stays-open: Enter on the (newest, unfiltered) top row dismisses it and the window stays up"
reset_store
write_entry 1 "$NOW" normal app "alpha" "a"
write_entry 2 "$NOW" normal app "bravo" "b"
clear_fifo_reader_log
WID="$(open_and_focus)"
assert_ne "browser opened" "" "$WID"
send Return
assert_eq "the newest row's entry (000002.notif) is dismissed" "yes" \
  "$(wait_gone "$STORE/000002.notif" && echo yes || echo no)"
assert_ne "window is still mapped after the successful dismiss" "" "$(win_notif 10)"
assert_eq "the other entry (000001.notif) is untouched" "present" \
  "$([ -e "$STORE/000001.notif" ] && echo present || echo MISSING)"
browser_close

# ---- del-empty-filter-dismisses -----------------------------------------------

scenario "del-empty-filter-dismisses: Delete with an EMPTY filter dismisses the selected row and stays open"
reset_store
write_entry 1 "$NOW" normal app "solo entry" "body"
clear_fifo_reader_log
WID="$(open_and_focus)"
assert_ne "browser opened" "" "$WID"
send Delete
assert_eq "the entry is dismissed by a bare Delete (filter was empty)" "yes" \
  "$(wait_gone "$STORE/000001.notif" && echo yes || echo no)"
assert_ne "window stays open" "" "$(win_notif 10)"
browser_close

# ---- del-with-filter-edits-not-dismisses --------------------------------------

scenario "del-with-filter-edits-not-dismisses: Delete while the filter has text edits the filter, never dismisses"
reset_store
write_entry 1 "$NOW" normal app "keepme-entry" "body"
clear_fifo_reader_log
WID="$(open_and_focus)"
assert_ne "browser opened" "" "$WID"
typ "keep"
send Delete
assert_eq "the entry survives a Delete pressed while the filter is non-empty" "yes" \
  "$(stays_present "$STORE/000001.notif" 10 && echo yes || echo no)"
assert_eq "nothing reached the daemon-stub fifo (no dismiss line logged)" "0" "$(fifo_reader_lines)"
browser_close

# ---- reopen-resets-del-gate (regression: forceFocus's reset must clear the
#      Del-dismiss gate too, not just Combo's own visible search text) --------
#
# The scenario just above leaves the browser's internal Del-dismiss gate
# primed "non-empty" (its last keypress was a Delete with "keep" still in the
# filter). Closing does NOT reset that gate -- only a fresh show() does, via
# combo.forceFocus(). This reopens on a BRAND NEW entry and presses Delete
# immediately (search is genuinely empty this session): if the gate were
# left stale from the PREVIOUS session instead of being reset on reopen, this
# Delete would be wrongly swallowed as "filter is non-empty" and the entry
# would survive when it must not.

scenario "reopen-resets-del-gate: a fresh reopen's empty filter dismisses on Delete, unaffected by the PREVIOUS session's non-empty filter"
reset_store
write_entry 1 "$NOW" normal app "fresh-session-entry" "body"
clear_fifo_reader_log
WID="$(open_and_focus)"
assert_ne "browser reopened" "" "$WID"
send Delete
assert_eq "the entry is dismissed -- the gate reset on reopen, it did not inherit the prior session's non-empty state" \
  "yes" "$(wait_gone "$STORE/000001.notif" && echo yes || echo no)"
browser_close

# ---- esc-closes ----------------------------------------------------------------

scenario "esc-closes: Escape closes the browser without dismissing anything"
reset_store
write_entry 1 "$NOW" normal app "untouched" "body"
WID="$(open_and_focus)"
assert_ne "browser opened" "" "$WID"
send Escape
assert_eq "window closes on Escape" "closed" "$(gone_notif 20 && echo closed || echo open)"
assert_eq "the entry was never dismissed" "present" "$([ -e "$STORE/000001.notif" ] && echo present || echo MISSING)"

# ---- dismiss-fail-status-bar-row-kept -----------------------------------------
#
# Kill the daemon stub so qs-notif.sh's `dismiss` fifo write has no reader
# and times out (exit 1, bounded -- see qs-notif.sh's own dismiss contract).
# The row must survive and the +26px status bar must appear.

scenario "dismiss-fail-status-bar-row-kept: no daemon listening -> status bar shown, row kept, window stays open"
stop_daemon_stub
reset_store
write_entry 1 "$NOW" normal app "kept-on-failure" "body"
WID="$(open_and_focus)"
assert_ne "browser opened" "" "$WID"
eval "$(env DISPLAY="$DPY" "$XDOTOOL" getwindowgeometry --shell "$WID" 2>/dev/null)"
base_h="${HEIGHT:-0}"
send Return
sleep 1.2   # the fifo write has QS_NOTIF_FIFO_TIMEOUT (default 2s) to fail
assert_eq "the entry is KEPT (dismiss failed, never silently dropped)" "present" \
  "$([ -e "$STORE/000001.notif" ] && echo present || echo MISSING)"
still="$(win_notif 10)"
assert_ne "window is still open after the failed dismiss" "" "$still"
if [ -n "$still" ]; then
  eval "$(env DISPLAY="$DPY" "$XDOTOOL" getwindowgeometry --shell "$still" 2>/dev/null)"
  assert_eq "the one-line status bar adds exactly 26px" "$((base_h + 26))" "${HEIGHT:-0}"
fi
browser_close
start_daemon_stub

# ---- markup-renders-literally -------------------------------------------------
#
# A notification body containing HTML/markup must render as literal text
# (Fuzzy.highlight HTML-escapes before the RichText delegate renders it) --
# the same injection guard ClipHistory's richtext-escape scenario proves. An
# unescaped <img src=...> would make Qt attempt to LOAD the image, logging an
# open-error for a unique filename; escaping it renders the tag as inert text.

scenario "markup-renders-literally: an HTML-bearing entry lists/dismisses byte-exact, and its markup never gets parsed as real markup"
reset_store
IMG="qsnotif-escape-probe-$$.png"
write_entry 1 "$NOW" normal app "decoy" "irrelevant"
write_entry 2 "$NOW" normal app "<b>bold</b> markup entry <img src='/nonexistent/$IMG'>" "body"
clear_fifo_reader_log
WID="$(open_and_focus)"
assert_ne "browser opened with a markup entry present" "" "$WID"
sleep 0.6   # let the row render so an UNescaped <img> would attempt its load
send Return
assert_eq "the newest (markup) row was dismissed successfully -- markup does not break the pick" "yes" \
  "$(wait_gone "$STORE/000002.notif" && echo yes || echo no)"
assert_eq "no image-load was attempted for the unique probe name -- the markup was escaped, not parsed" \
  "0" "$(grep -c "$IMG" "$TMP/qs-phase2.log" | tr -d ' ')"
browser_close

# ---- busy-gate-double-enter ----------------------------------------------------
#
# Slow the daemon stub's read so the FIRST dismiss's fifo write stays
# in-flight; a second Enter arriving during that window must be swallowed by
# NotifHistory's busy gate -- exactly one "dismiss ..." line ever reaches the
# stub, and the store shows exactly one removal, not a race.

scenario "busy-gate-double-enter: two rapid Enters on one row -> exactly one dismiss reaches the daemon"
reset_store
write_entry 1 "$NOW" normal app "single-row" "body"
clear_fifo_reader_log
set_daemon_delay 1.2
WID="$(open_and_focus)"
assert_ne "browser opened" "" "$WID"
send Return
send Return
sleep 1.6
assert_eq "the daemon stub saw the dismiss line exactly once" "1" "$(fifo_reader_lines)"
assert_eq "the entry was dismissed (the one dismiss that got through succeeded)" "yes" \
  "$(wait_gone "$STORE/000001.notif" && echo yes || echo no)"
set_daemon_delay 0
browser_close

# ---- empty-after-last-dismiss ---------------------------------------------------
#
# Dismissing the LAST entry must still render a window: minVisibleRows:1
# holds a floor of one row for the empty-history placeholder, so the window
# geometry after the dismiss must be IDENTICAL to what a single row already
# produced (proving the floor held, not that the window shrank to nothing).

scenario "empty-after-last-dismiss: dismissing the only entry leaves the floor-of-one-row window rendered, not collapsed"
reset_store
write_entry 1 "$NOW" normal app "last one" "body"
WID="$(open_and_focus)"
assert_ne "browser opened with exactly one entry" "" "$WID"
eval "$(env DISPLAY="$DPY" "$XDOTOOL" getwindowgeometry --shell "$WID" 2>/dev/null)"
one_row_h="${HEIGHT:-0}"
send Return
assert_eq "the only entry is dismissed" "yes" "$(wait_gone "$STORE/000001.notif" && echo yes || echo no)"
still="$(win_notif 10)"
assert_ne "window is still rendered with zero entries left (empty-history placeholder, floor of one row)" "" "$still"
if [ -n "$still" ]; then
  eval "$(env DISPLAY="$DPY" "$XDOTOOL" getwindowgeometry --shell "$still" 2>/dev/null)"
  assert_eq "geometry is unchanged from the one-row height -- the floor held, the window did not collapse" \
    "$one_row_h" "${HEIGHT:-0}"
fi
browser_close

stop_daemon_stub

# ---- no-common-diff -------------------------------------------------------------
#
# This task's own contract: it consumes ft008 Combo but must never widen it.
# Proven by diffing against the merge-base with main -- everything this
# task's branch has done to config/Common/ since it forked, which must be
# nothing.

scenario "no-common-diff: config/Common/ is untouched since this branch forked from main"
REPO_ROOT="$SCRIPT_DIR/.."
_base="$(git -C "$REPO_ROOT" merge-base HEAD main 2>/dev/null)"
if [ -n "$_base" ]; then
  _diff="$(git -C "$REPO_ROOT" diff --name-only "$_base" -- quickshell/config/Common/ 2>/dev/null)"
  assert_eq "git diff --name-only vs merge-base(HEAD, main) touches nothing under config/Common/" "" "$_diff"
else
  echo "SKIP: could not resolve a merge-base with main (not fatal -- informational only)"
fi

# ---- adr0010 grep contract -------------------------------------------------------
#
# No pasteboard command and no action-invocation call anywhere in the
# browser's own source -- asserted IN-SUITE so a future edit that reaches
# for either fails the run, not just review.

scenario "adr0010 grep contract: NotifHistory.qml never mentions a pasteboard tool, a clipboard-set script, CLIPBOARD, or an action-invoke call"
_hits="$(grep -c -E 'xclip|clip-set|CLIPBOARD|invoke' "$NOTIF_HISTORY_QML" 2>/dev/null || true)"
assert_eq "zero hits for the forbidden clipboard/action-invoke surface" "0" "${_hits:-0}"

# ---- wiring: production shell.qml hosts the browser ------------------------------

scenario "wiring: the shipped shell.qml instantiates NotifHistory beside ClipHistory"
assert_eq "config/shell.qml contains NotifHistory {}" "1" \
  "$(grep -c '^[[:space:]]*NotifHistory[[:space:]]*{}' "$SCRIPT_DIR/config/shell.qml" | tr -d ' ')"

scenario "wiring: BOTH base i3 configs float qs-notif the same way they float qs-clip"
for f in "$SCRIPT_DIR/../i3/config" "$SCRIPT_DIR/../i3/config.common"; do
  assert_eq "$f has the qs-notif for_window float rule" "1" \
    "$(grep -c '^for_window \[title="qs-notif"\] floating enable, border none, move position center$' "$f" | tr -d ' ')"
done

kill "$NOTIF_PID" 2>/dev/null; wait "$NOTIF_PID" 2>/dev/null; NOTIF_PID=""

# ================= SELFTEST NEGATIVE CONTROL ================================
# SELFTEST=1 deliberately flips one expectation to a value the real script
# can never produce. If this run does not report a FAIL, the harness itself
# (assert_eq / PASS/FAIL bookkeeping) is broken and every green result above
# is meaningless.
if [ "${SELFTEST:-}" = "1" ]; then
  scenario "SELFTEST negative control: a deliberately wrong expectation must FAIL"
  reset_store
  write_entry 1 "$NOW" normal app "selftest" "selftest body"
  assert_eq "(SELFTEST) list row count is WRONGLY expected to be 99" "99" "$(qsnotif list | wc -l | tr -d ' ')"
fi

# ------------------------------------------------------------------ result ---

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
