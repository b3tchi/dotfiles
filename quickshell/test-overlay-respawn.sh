#!/usr/bin/env bash
# test-overlay-respawn.sh — regression test for the kwi3-234.14 onExited
# Qt.binding fix in Overlay.qml's windowSubscriber Process (kwi3-55l.5, sp004
# retro from kwi3-234.14's own audit).
#
# THE BUG (kwi3-234.14, see Overlay.qml's own comment on windowSubscriber):
# a plain `onExited: running = true` is an IMPERATIVE assignment, and QML
# permanently drops a property's declarative BINDING the first time it is
# imperatively assigned — including the assignment the Process framework
# itself makes (`running -> false`) the moment the underlying process exits,
# which happens BEFORE onExited ever runs. So restoring "keep running"
# afterwards needs onExited to re-arm a live binding
# (`running = Qt.binding(function () { return !Kwi3Client.configured })`),
# not a frozen snapshot of what the guard happened to read at that instant —
# otherwise a guard that later says "stop" is silently ignored forever, which
# is exactly the unbounded respawn loop kwi3-234.14 found and fixed.
#
# WHY THIS FILE EXISTS: test-overlay.sh's own i3-msg subscribe stub never
# exits (`exec sleep 300` after the one seeded event), so the exit -> onExited
# -> rebind path has zero coverage in that suite. This file exercises it
# directly, extracting the REAL `running:`/`onExited:` lines out of
# config/Overlay.qml (never hand-copied — see below) so a future edit to
# either line is picked up automatically rather than silently drifting out of
# sync with what ships.
#
# WHY A STAND-IN Kwi3Client, NOT THE REAL SINGLETON: the real
# Kwi3Client.configured (config/Common/Kwi3Client.qml) is derived once from
# $KWI3SOCK and is PROVABLY CONSTANT for a whole quickshell session — verified
# empirically while writing this test: reverting the fix and re-running it
# against the real Overlay.qml with $KWI3SOCK held fixed for the process's
# whole life produces BYTE-IDENTICAL respawn counts to the fixed version,
# because a Qt.binding re-evaluated against an expression that never changes
# is indistinguishable from a plain snapshot of that same expression's
# current value. The bug is only OBSERVABLE when the guard's value changes
# after the process has already started and exited once — exactly what
# happened historically when this Process was gated on Kwi3Client.available
# (kwi3-234.14's original fix target: `available` flips false -> true
# asynchronously as the socket connects) before kwi3-234.18 moved the gate to
# the constant `configured` specifically to remove that race. So this file
# substitutes a `Kwi3Client` id exposing the SAME property name (`configured`)
# but one this suite can legitimately flip mid-run with a Timer, reproducing
# the historical race deterministically instead of racing a live connect.
# Extraction is what keeps this honest: whatever Overlay.qml's onExited line
# actually says — the fix, a future variant, or a reversion back to a plain
# assignment — is what gets spliced into the fixture and exercised here.
#
# Sandboxing discipline matches test-overlay.sh: its own Xvfb display, its own
# isolated $HOME/$XDG_*_HOME (never Jan's), never touches a live display.
#
# usage: quickshell/test-overlay-respawn.sh
# env:   XVFB= QUICKSHELL=   (default: from PATH)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_QML="$SCRIPT_DIR/config/Overlay.qml"

XVFB="${XVFB:-Xvfb}"
QUICKSHELL="${QUICKSHELL:-quickshell}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
scenario() { printf '\n[%s]\n' "$1"; }

for tool in "$XVFB" "$QUICKSHELL"; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (XVFB=/QUICKSHELL= to override)" >&2; exit 1; }
done
[ -r "$OVERLAY_QML" ] || { echo "FATAL: $OVERLAY_QML not readable" >&2; exit 1; }

# ── extract the REAL running:/onExited: lines from windowSubscriber ────────
# Anchored to the start of the (trimmed) line so neither pattern can match a
# comment mentioning the same text (Overlay.qml's own explanatory comment
# above windowSubscriber quotes `onExited: running = true` inside backticks,
# never at the start of a line). The onExited pattern intentionally does NOT
# constrain what follows `running = ` — it must extract whatever is actually
# there, correct or reverted, so this fixture stays honest to the shipped
# file rather than to what this test expects to find.
RUNNING_LINE_RAW="$(grep -E '^[[:space:]]*running: !Kwi3Client\.configured[[:space:]]*$' "$OVERLAY_QML" | sed 's/^[[:space:]]*//')"
ONEXITED_LINE_RAW="$(grep -E '^[[:space:]]*onExited: running = ' "$OVERLAY_QML" | sed 's/^[[:space:]]*//')"

# QML ids must start lowercase, so the fixture's stand-in object can't be
# `id: Kwi3Client` — rename ONLY that identifier (never the condition or the
# rebind logic) to `kwi3Client` in both extracted lines. Purely a casing fix
# for the fixture's local object; the real Overlay.qml keeps referencing the
# real (uppercase, pragma Singleton) Kwi3Client unchanged.
RUNNING_LINE="${RUNNING_LINE_RAW//Kwi3Client/kwi3Client}"
ONEXITED_LINE="${ONEXITED_LINE_RAW//Kwi3Client/kwi3Client}"

n_running="$(printf '%s' "$RUNNING_LINE" | grep -c . || true)"
n_onexited="$(printf '%s' "$ONEXITED_LINE" | grep -c . || true)"
if [ "$n_running" -ne 1 ]; then
  echo "FATAL: expected exactly one 'running: !Kwi3Client.configured' line in $OVERLAY_QML, found $n_running" >&2
  echo "       (windowSubscriber's running: condition may have been renamed/moved — update this test's extraction pattern)" >&2
  exit 1
fi
if [ "$n_onexited" -ne 1 ]; then
  echo "FATAL: expected exactly one 'onExited: running = ...' line in $OVERLAY_QML, found $n_onexited" >&2
  exit 1
fi
echo "extracted from Overlay.qml: $RUNNING_LINE"
echo "extracted from Overlay.qml: $ONEXITED_LINE"

TMP="/tmp/qs-overlay-respawn-test.$$"
mkdir -p "$TMP"
KILL_PIDS=()
cleanup() {
  local p
  for p in "${KILL_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  sleep 0.2
  for p in "${KILL_PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# Same both-namespaces check as test-overlay.sh (dotfiles-4ai2): a WSLg host
# binds /tmp/.X11-unix read-only from /mnt/wslg, so a server there may only
# ever expose the abstract socket name, never the file.
dpy_up() { # <display>
  [ -e "/tmp/.X11-unix/X${1#:}" ] && return 0
  grep -q "@/tmp/\.X11-unix/X${1#:}\$" /proc/net/unix 2>/dev/null
}

DPY_BASE=190

# run_case <case-name> <extra-qml-block> <stub-shell-body>
# Builds a minimal ShellRoot around ONE Process carrying the extracted
# running:/onExited: lines, boots it under its own Xvfb + isolated
# HOME/XDG_*_HOME, and leaves $CASE_LOG naming the invocation log the stub
# writes to (one line per invocation). Caller polls/reads that file, then
# calls stop_case.
run_case() { # <name> <qml-preamble-lines> <stub-body>
  local name="$1" preamble="$2" stub="$3"
  local dir="$TMP/$name"
  mkdir -p "$dir/entry" "$dir/home" "$dir/run" "$dir/cch" "$dir/cfg"
  chmod 700 "$dir/run"
  CASE_LOG="$dir/invocations.log"
  : > "$CASE_LOG"

  {
    printf 'import Quickshell\nimport Quickshell.Io\nimport QtQuick\n\n'
    printf 'ShellRoot {\n'
    printf '%s\n' "$preamble"
    printf '    Process {\n'
    printf '        id: windowSubscriber\n'
    printf '        %s\n' "$RUNNING_LINE"
    printf '        command: ["sh", "-c", "%s"]\n' "$stub"
    printf '        %s\n' "$ONEXITED_LINE"
    printf '    }\n'
    printf '}\n'
  } > "$dir/entry/shell.qml"

  DPY_BASE=$((DPY_BASE + 1))
  CASE_DPY=":$DPY_BASE"
  "$XVFB" "$CASE_DPY" -screen 0 320x240x24 >"$dir/xvfb.log" 2>&1 &
  CASE_XVFB_PID=$!
  KILL_PIDS+=("$CASE_XVFB_PID")
  local i
  for i in $(seq 1 20); do dpy_up "$CASE_DPY" && break; sleep 0.3; done
  if ! dpy_up "$CASE_DPY"; then
    fail "$name (Xvfb $CASE_DPY started)" "a display" "none"
    return 1
  fi

  setsid env -u SWAYSOCK -u KWI3SOCK \
      DISPLAY="$CASE_DPY" HOME="$dir/home" LOGFILE="$CASE_LOG" \
      XDG_RUNTIME_DIR="$dir/run" XDG_CACHE_HOME="$dir/cch" XDG_CONFIG_HOME="$dir/cfg" \
      "$QUICKSHELL" -p "$dir/entry" >"$dir/qs.log" 2>&1 &
  local launcher_pid=$!
  KILL_PIDS+=("$launcher_pid")
  # setsid forks rather than exec-replacing in some sandboxes (observed here:
  # the backgrounded launcher stays a distinct process from quickshell) — so
  # resolve the real child if there is one, and track BOTH pids for cleanup.
  sleep 0.3
  local child
  child="$(pgrep -P "$launcher_pid" 2>/dev/null | head -1)"
  if [ -n "$child" ]; then KILL_PIDS+=("$child"); fi
  return 0
}

wait_for_count() { # <logfile> <min-count> <timeout-s> -> 0 if reached
  local n=$(( ${3:-10} * 5 )) i
  for i in $(seq 1 "$n"); do
    [ "$(wc -l < "$1" 2>/dev/null || echo 0)" -ge "$2" ] && return 0
    sleep 0.2
  done
  return 1
}

count_of() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

# ============================================================================
# Scenario 1: the subscribed process exiting once causes exactly one
# respawn — the literal "exit/rebind path is never exercised" gap. The guard
# never changes here (the i3/sway "always resubscribe" contract), so this
# scenario alone cannot distinguish the fix from a reversion (see the file
# header) — it proves the mechanism functions in the first place, which
# test-overlay.sh's forever-blocking stub has never done.
# ============================================================================
scenario "exit-triggers-one-respawn: the subscribed process exiting once causes exactly one respawn, then settles"
# Invocation 1 exits quickly (racing nothing — this is the deliberate exit
# test-overlay.sh's own stub never produces); invocation 2+ blocks like a
# real subscribe that succeeded, so the count settles instead of growing
# forever regardless of guard state.
STUB1='c=$(( $(wc -l < $LOGFILE 2>/dev/null || echo 0) + 1 )); echo invoked $c >> $LOGFILE; if [ $c -le 1 ]; then sleep 0.1; exit 0; else exec sleep 300; fi'
if run_case "settle" "    QtObject { id: kwi3Client; property bool configured: false }" "$STUB1"; then
  if wait_for_count "$CASE_LOG" 1 5; then
    if wait_for_count "$CASE_LOG" 2 5; then
      sleep 1
      c="$(count_of "$CASE_LOG")"
      assert_settle_ok=""
      [ "$c" = "2" ] && assert_settle_ok=1
      if [ -n "$assert_settle_ok" ]; then
        pass "exactly one respawn occurred (2 invocations total) and it settled"
      else
        fail "exactly one respawn occurred (2 invocations total) and it settled" "2" "$c"
      fi
    else
      fail "the process respawned after its first exit" "a 2nd invocation within 5s" "timed out (still $(count_of "$CASE_LOG"))"
    fi
  else
    fail "the process started at all" "a 1st invocation within 5s" "timed out"
  fi
fi

# ============================================================================
# Scenario 2: the actual kwi3-234.14 regression. The guard flips from "keep
# running" to "stop" WHILE the process is alive/exiting — the shape of the
# historical bug (Kwi3Client.available flipping after the async connect,
# before this Process was regated onto the constant `configured` in
# kwi3-234.18). A frozen `running = true` (the reverted code) ignores the
# flip and keeps respawning; the fix's re-armed binding reacts to it and the
# invocation count stops growing. THIS is the scenario that fails when the
# fix is reverted — see the worktree notes for the actual revert-and-rerun
# proof.
# ============================================================================
scenario "guard-flip-stops-respawn: once the guard says stop, respawning stops instead of running away (kwi3-234.14)"
STUB2='echo invoked >> $LOGFILE; sleep 0.05; exit 0'
PREAMBLE2='    QtObject { id: kwi3Client; property bool configured: false }
    Timer { interval: 500; running: true; repeat: false; onTriggered: kwi3Client.configured = true }'
if run_case "regression" "$PREAMBLE2" "$STUB2"; then
  if wait_for_count "$CASE_LOG" 1 5; then
    # Let the guard flip (500ms) plus one in-flight process settle.
    sleep 1.0
    c_after_flip="$(count_of "$CASE_LOG")"
    sleep 1.5
    c_later="$(count_of "$CASE_LOG")"
    growth=$((c_later - c_after_flip))
    if [ "$growth" -le 1 ]; then
      pass "respawning stopped once the guard flipped (growth after settle: $growth, count $c_after_flip -> $c_later)"
    else
      fail "respawning stopped once the guard flipped" "growth <= 1 after settling" "growth=$growth ($c_after_flip -> $c_later) — unbounded respawn loop"
    fi
  else
    fail "the process started at all" "a 1st invocation within 5s" "timed out"
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
