#!/bin/sh
# qs-overlay.sh target resolution (dotfiles-hwds.45).
#
# WHAT BROKE AND WHY THIS EXISTS. qs_target_pid used to branch on the QS_RDP env
# var: set => the overlay lives in the main instance, unset => look for a
# separate `quickshell -p .../overlay` process. That made the answer depend on
# who spawned the CALLER instead of on what is actually running. i3/config-xrdp
# sets QS_RDP only as the `$qsenv` prefix on its own bindsym lines, so once
# hotkeyd owned $mod+Tab / $mod+w / $mod+d / $mod+p (dotfiles-hwds.40) every
# verb the daemon dispatched on the xrdp session arrived with QS_RDP unset, took
# the desktop branch, and died with "no quickshell instance" on a session that
# had one. Measured live on :10 before the fix.
#
# The suite therefore runs every case with QS_RDP DELIBERATELY UNSET — that is
# the daemon's environment, and the whole point is that resolution no longer
# needs it.
#
# No real quickshell here: the function only reads /proc/<pid>/cmdline and the
# session key from /proc/<pid>/environ, so stand-in processes named `quickshell`
# reproduce both shapes exactly and the suite needs no X server at all.
# NO `set -u` here, deliberately: sourcing qs-overlay.sh pulls in qs-session.sh,
# whose line 8 reads an unguarded `$SWAYSOCK` and aborts under nounset. That is
# a real bug with its own issue (dotfiles-0ov) — not this suite's to fix, and
# not something to paper over by exporting SWAYSOCK, which would send the whole
# file down its sway branch and test the wrong thing.

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
TMP="${TMPDIR:-/tmp}/qs-overlay-target.$$"
PASS=0; FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
scenario() { printf '\n[%s]\n' "$1"; }

cleanup() {
  [ -n "${MAIN_PID:-}" ]    && kill "$MAIN_PID"    2>/dev/null
  [ -n "${OVERLAY_PID:-}" ] && kill "$OVERLAY_PID" 2>/dev/null
  [ -n "${OTHER_PID:-}" ]   && kill "$OTHER_PID"   2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin"

# A stand-in named exactly `quickshell` — pgrep -x matches on comm, so the file
# name is what matters, not what it does. It must OUTLIVE the probes, hence the
# long sleep rather than a one-shot.
cat > "$TMP/bin/quickshell" <<'EOF'
#!/bin/sh
sleep 300
EOF
chmod +x "$TMP/bin/quickshell"

# The display these stand-ins claim, distinct from any real session on the box
# so a developer's own quickshell cannot be mistaken for one of ours.
FAKE_DPY=":9931"

# Launch a stand-in and leave its pid in $LAST_PID.
#
# NOT `pid="$(start_instance)"` — the EXIT trap fires when a command-substitution
# subshell ends, so `rm -rf "$TMP"` would delete the stand-in binary out from
# under the very process we just launched. Cost an unexplained empty first
# scenario before it was spotted.
# stdout/stderr go to /dev/null, and that is not tidiness: a stand-in that
# inherits the suite's stdout holds the pipe open, so `sh test-... | tail` never
# sees EOF and the run appears to hang long after the assertions finished.
start_instance() { # <args...>; sets LAST_PID
  env -u SWAYSOCK -u QS_RDP DISPLAY="$FAKE_DPY" "$TMP/bin/quickshell" "$@" \
      >/dev/null 2>&1 &
  LAST_PID=$!
}

# Load the helpers without dispatching a verb.
QS_OVERLAY_LIB=1
export QS_OVERLAY_LIB
# shellcheck source=/dev/null
DISPLAY="$FAKE_DPY" . "$HERE/qs-overlay.sh"
unset QS_OVERLAY_LIB

# qs-session.sh resolved the session key from the DISPLAY that was live when it
# was sourced; pin it explicitly so the probes compare against the fake display.
QS_DPY_VAR="DISPLAY"; QS_DPY_VAL="$FAKE_DPY"
DISPLAY="$FAKE_DPY"; export DISPLAY

# ---------------------------------------------------------------------------
scenario "RDP shape: only a main instance, QS_RDP unset — the daemon's case"
# This is the exact configuration that was broken: qs-start.sh skips the
# separate overlay process when QS_RDP=1, so the session has ONE quickshell and
# it hosts the overlay. A resolver that insists on `-p <overlay>` finds nothing.
start_instance; MAIN_PID="$LAST_PID"
sleep 0.6
assert_eq "resolves to the session's main instance" "$MAIN_PID" "$(qs_target_pid || echo NONE)"

# ---------------------------------------------------------------------------
scenario "desktop shape: a dedicated -p overlay process wins over the main one"
# Both shapes coexist on a desktop session (main bar + separate overlay host).
# The dedicated process must win regardless of pgrep's ordering, which is why
# the main instance is remembered rather than returned on sight.
start_instance -p "$HOME/.dotfiles/quickshell/overlay"; OVERLAY_PID="$LAST_PID"
sleep 0.6
assert_eq "prefers the dedicated overlay host" "$OVERLAY_PID" "$(qs_target_pid || echo NONE)"

kill "$OVERLAY_PID" 2>/dev/null; OVERLAY_PID=""
sleep 0.4
assert_eq "falls back to the main instance when it goes away" \
  "$MAIN_PID" "$(qs_target_pid || echo NONE)"

# ---------------------------------------------------------------------------
scenario "a -p instance that is NOT the overlay is never the target"
# The notification daemon runs as `quickshell -p .../notif` in the same session.
# Treating any -p process as the overlay would send switcher verbs to it.
start_instance -p "$HOME/.dotfiles/quickshell/notif"; OTHER_PID="$LAST_PID"
sleep 0.6
assert_eq "the notif profile is not mistaken for the overlay" \
  "$MAIN_PID" "$(qs_target_pid || echo NONE)"

kill "$MAIN_PID" 2>/dev/null; MAIN_PID=""
sleep 0.4
assert_eq "with only the notif profile left there is NO target" \
  "NONE" "$(qs_target_pid || echo NONE)"

# ---------------------------------------------------------------------------
scenario "another session's instance is never borrowed"
env -u SWAYSOCK -u QS_RDP DISPLAY=":9932" "$TMP/bin/quickshell" >/dev/null 2>&1 &
OTHER_SESSION_PID=$!
sleep 0.6
assert_eq "a quickshell on a different DISPLAY is not this session's overlay" \
  "NONE" "$(qs_target_pid || echo NONE)"
kill "$OTHER_SESSION_PID" 2>/dev/null

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
