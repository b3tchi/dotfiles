#!/bin/sh
# test-notif-daemon.sh -- verify the notification daemon profile
# (quickshell/notif/shell.qml): sp019 task 2, dotfiles-c5fd.2.
#
# Every scenario runs the REAL quickshell binary hosting the REAL
# NotificationServer, wrapped in `dbus-run-session` so the daemon owns
# org.freedesktop.Notifications on an ISOLATED session bus -- NEVER the
# live user bus. XDG_RUNTIME_DIR / XDG_STATE_HOME are isolated per scenario
# under $TMP. QT_QPA_PLATFORM=offscreen is tried first (this profile hosts
# no Window/PanelWindow, so no real display is needed); Xvfb is the fallback
# if quickshell ever refuses to start offscreen.
#
# Determinism: every wait is a bounded POLL loop (wait_ready / wait_bus_owner
# / wait_fifo / wait_file_contains), never a fixed sleep sized to "should be
# enough" -- assertions must hold under CPU load, not just on an idle box.
#
# usage: quickshell/test-notif-daemon.sh
# env:   KEEP_TMP=1   (debug: skip deleting $TMP on exit)
#        SELFTEST=1   (negative control: flips one expectation, MUST fail)
set -u

REPO_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STORESH="$REPO_DIR/qs-notif-store.sh"
QMLDIR="$REPO_DIR/notif"

TMP="/tmp/notif-daemon-test.$$"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

assert_eq() { # <scenario> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

scenario() { printf '\n[%s]\n' "$1"; }

DAEMON_PIDS=""
# BAR PHASE (Task 4) background processes -- populated only if that phase runs.
BAR_XVFB_PID=""
BAR_QS_PID=""
BAR_READER_PID=""

cleanup() {
  for _p in $DAEMON_PIDS; do
    kill "$_p" 2>/dev/null
    wait "$_p" 2>/dev/null
  done
  [ -n "$BAR_READER_PID" ] && kill "$BAR_READER_PID" 2>/dev/null
  [ -n "$BAR_QS_PID" ]     && kill "$BAR_QS_PID"     2>/dev/null
  [ -n "$BAR_XVFB_PID" ]   && kill "$BAR_XVFB_PID"   2>/dev/null
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP"

[ -f "$STORESH" ] || { echo "FATAL: store script not found at $STORESH" >&2; exit 1; }
[ -f "$QMLDIR/shell.qml" ] || { echo "FATAL: daemon profile not found at $QMLDIR/shell.qml" >&2; exit 1; }
command -v dbus-run-session >/dev/null 2>&1 || { echo "FATAL: dbus-run-session not found" >&2; exit 1; }
command -v quickshell >/dev/null 2>&1 || { echo "FATAL: quickshell not found on PATH" >&2; exit 1; }

# --------------------------------------------------------------- helpers ---

# Does quickshell start a windowless ShellRoot under QT_QPA_PLATFORM=offscreen?
# Probes once; every later scenario reuses the decision via $QPA_MODE.
pick_qpa() {
  _pd="$TMP/qpa-probe"
  mkdir -p "$_pd"
  printf 'import Quickshell\nShellRoot {}\n' > "$_pd/probe.qml"
  QT_QPA_PLATFORM=offscreen quickshell -p "$_pd/probe.qml" >"$_pd/out.log" 2>&1 &
  _pp=$!
  sleep 1
  if kill -0 "$_pp" 2>/dev/null; then
    kill "$_pp" 2>/dev/null; wait "$_pp" 2>/dev/null
    echo offscreen
  else
    wait "$_pp" 2>/dev/null
    echo xvfb
  fi
}
QPA_MODE="$(pick_qpa)"
printf 'QPA mode: %s\n' "$QPA_MODE"

# Launch one daemon instance with an isolated XDG tree. Echoes its pid.
start_daemon() { # <run_dir> <state_dir> <ready_file> <fifo_path>
  _rd="$1" _sd="$2" _rf="$3" _fifo="$4"
  mkdir -p "$_rd" "$_sd"
  chmod 700 "$_rd"
  if [ "$QPA_MODE" = "offscreen" ]; then
    env XDG_RUNTIME_DIR="$_rd" XDG_STATE_HOME="$_sd" QS_NOTIF_FIFO="$_fifo" \
        QS_NOTIF_STORE_SCRIPT="$STORESH" QS_NOTIF_READY_FILE="$_rf" \
        QT_QPA_PLATFORM=offscreen quickshell -p "$QMLDIR" >"$_rd/daemon.log" 2>&1 &
  else
    env XDG_RUNTIME_DIR="$_rd" XDG_STATE_HOME="$_sd" QS_NOTIF_FIFO="$_fifo" \
        QS_NOTIF_STORE_SCRIPT="$STORESH" QS_NOTIF_READY_FILE="$_rf" \
        xvfb-run -a quickshell -p "$QMLDIR" >"$_rd/daemon.log" 2>&1 &
  fi
  echo $!
}

wait_ready() { # <ready_file> [<max_tenths>]
  _rf="$1"; _n="${2:-100}"; _i=0
  while [ "$_i" -lt "$_n" ]; do
    [ -e "$_rf" ] && return 0
    _i=$((_i + 1)); sleep 0.1
  done
  return 1
}

wait_bus_owner() { # [<max_tenths>]
  _n="${1:-100}"; _i=0
  while [ "$_i" -lt "$_n" ]; do
    dbus-send --session --print-reply --dest=org.freedesktop.DBus \
      /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner \
      string:org.freedesktop.Notifications >/dev/null 2>&1 && return 0
    _i=$((_i + 1)); sleep 0.1
  done
  return 1
}

wait_fifo() { # <fifo_path> [<max_tenths>]
  _fp="$1"; _n="${2:-100}"; _i=0
  while [ "$_i" -lt "$_n" ]; do
    [ -p "$_fp" ] && return 0
    _i=$((_i + 1)); sleep 0.1
  done
  return 1
}

wait_file_matches() { # <file> <grep-pattern> [<max_tenths>]
  _f="$1" _pat="$2" _n="${3:-100}"; _i=0
  while [ "$_i" -lt "$_n" ]; do
    grep -q "$_pat" "$_f" 2>/dev/null && return 0
    _i=$((_i + 1)); sleep 0.1
  done
  return 1
}

wait_count() { # <store_dir> <expected_count> [<max_tenths>]
  _d="$1" _want="$2" _n="${3:-100}"; _i=0
  while [ "$_i" -lt "$_n" ]; do
    _n_entries=0
    for _f in "$_d"/[0-9][0-9][0-9][0-9][0-9][0-9].notif; do
      [ -e "$_f" ] && _n_entries=$((_n_entries + 1))
    done
    [ "$_n_entries" -eq "$_want" ] && return 0
    _i=$((_i + 1)); sleep 0.1
  done
  return 1
}

stop_daemon() { # <pid>
  [ -n "$1" ] || return 0
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
}

# Fully self-contained: start one daemon inside an isolated dbus-run-session,
# wait for it to be ready + own the bus + have its FIFO up, run the caller's
# body (a shell snippet referencing $RUN/$STATE/$FIFO/$READY/$SDIR/$STATEFILE),
# then tear the daemon down. Everything happens inside ONE dbus-run-session so
# notify-send/FIFO writes issued by the body reach the SAME isolated bus the
# daemon owns.
with_daemon() { # <scenario_dir> <body_script_path>
  _sdir="$1" _body="$2"
  _run="$_sdir/run"; _state="$_sdir/state"; _ready="$_run/ready"; _fifo="$_run/notif.cmd"
  mkdir -p "$_run" "$_state"
  cat > "$_sdir/wrapper.sh" <<WRAP
#!/bin/sh
set -u
export XDG_RUNTIME_DIR="$_run"
export XDG_STATE_HOME="$_state"
export QS_NOTIF_FIFO="$_fifo"
export QS_NOTIF_STORE_SCRIPT="$STORESH"
export QS_NOTIF_READY_FILE="$_ready"
export QPA_MODE="$QPA_MODE"
if [ "\$QPA_MODE" = "offscreen" ]; then
  QT_QPA_PLATFORM=offscreen quickshell -p "$QMLDIR" >"$_run/daemon.log" 2>&1 &
else
  xvfb-run -a quickshell -p "$QMLDIR" >"$_run/daemon.log" 2>&1 &
fi
QSPID=\$!
i=0; while [ \$i -lt 100 ]; do [ -e "$_ready" ] && break; i=\$((i + 1)); sleep 0.1; done
i=0; while [ \$i -lt 100 ]; do
  dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.freedesktop.Notifications >/dev/null 2>&1 && break
  i=\$((i + 1)); sleep 0.1
done
i=0; while [ \$i -lt 100 ]; do [ -p "$_fifo" ] && break; i=\$((i + 1)); sleep 0.1; done
RUN="$_run"; STATE="$_state"; FIFO="$_fifo"; SDIR="$_state/qs-notif"; STATEFILE="$_run/qs-notif.state"
. "$_body"
kill \$QSPID 2>/dev/null
wait \$QSPID 2>/dev/null
WRAP
  chmod +x "$_sdir/wrapper.sh"
  timeout 30 dbus-run-session -- sh "$_sdir/wrapper.sh"
}

# --------------------------------------------------------------- scenarios ---

scenario "notify-lands-in-store: a plain notification appends exactly one store entry"
S="$TMP/s1"; mkdir -p "$S"
cat > "$S/body.sh" <<'EOF'
notify-send "Hello" "world body" >/dev/null 2>&1
EOF
with_daemon "$S" "$S/body.sh"
wait_count "$S/state/qs-notif" 1 50
assert_eq "exactly one store entry landed" "yes" "$([ -f "$S/state/qs-notif/000001.notif" ] && echo yes || echo no)"
assert_eq "summary line correct" "Hello" "$(sed -n '2p' "$S/state/qs-notif/000001.notif" 2>/dev/null)"
assert_eq "body line correct" "world body" "$(sed -n '3p' "$S/state/qs-notif/000001.notif" 2>/dev/null)"

scenario "state-tracks-count: two notifications land, count in the live-state file is 2"
S="$TMP/s2"; mkdir -p "$S"
cat > "$S/body.sh" <<'EOF'
notify-send "One" "b1" >/dev/null 2>&1
sleep 0.3
notify-send "Two" "b2" >/dev/null 2>&1
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 2" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
EOF
with_daemon "$S" "$S/body.sh"
assert_eq "state file shows count 2" "count 2" "$(sed -n '1p' "$S/run/qs-notif.state" 2>/dev/null)"

scenario "critical-flag-cycle: a critical notification sets critical 1; dismissing it (the only critical) flips it back to 0"
S="$TMP/s3"; mkdir -p "$S"
cat > "$S/body.sh" <<'EOF'
notify-send -u critical "Crit" "crit body" >/dev/null 2>&1
_i=0; while [ $_i -lt 50 ]; do grep -q "^critical 1" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
echo "CRIT1=$(sed -n '2p' "$STATEFILE")" >> "$RUN/checkpoints"
printf 'dismiss latest\n' > "$FIFO"
_i=0; while [ $_i -lt 50 ]; do grep -q "^critical 0" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
echo "CRIT2=$(sed -n '2p' "$STATEFILE")" >> "$RUN/checkpoints"
EOF
with_daemon "$S" "$S/body.sh"
assert_eq "critical flipped to 1 on arrival" "CRIT1=critical 1" "$(sed -n '1p' "$S/run/checkpoints" 2>/dev/null)"
assert_eq "critical flipped back to 0 after dismissing the only critical entry" "CRIT2=critical 0" "$(sed -n '2p' "$S/run/checkpoints" 2>/dev/null)"
assert_eq "the store entry is gone after dismiss" "no" "$([ -e "$S/state/qs-notif/000001.notif" ] && echo yes || echo no)"

scenario "fifo-dismiss-id: dismiss <id> removes exactly the named store entry and decrements count"
S="$TMP/s4"; mkdir -p "$S"
cat > "$S/body.sh" <<'EOF'
notify-send "First" "b1" >/dev/null 2>&1
sleep 0.3
notify-send "Second" "b2" >/dev/null 2>&1
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 2" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
printf 'dismiss 000001.notif\n' > "$FIFO"
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 1" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
EOF
with_daemon "$S" "$S/body.sh"
assert_eq "entry 000001.notif is gone" "no" "$([ -e "$S/state/qs-notif/000001.notif" ] && echo yes || echo no)"
assert_eq "entry 000002.notif remains" "yes" "$([ -f "$S/state/qs-notif/000002.notif" ] && echo yes || echo no)"
assert_eq "state count dropped to 1" "count 1" "$(sed -n '1p' "$S/run/qs-notif.state" 2>/dev/null)"

scenario "fifo-dismiss-latest: dismiss latest targets the highest-seq entry, twice in a row"
S="$TMP/s5"; mkdir -p "$S"
cat > "$S/body.sh" <<'EOF'
notify-send "First" "b1" >/dev/null 2>&1
sleep 0.3
notify-send "Second" "b2" >/dev/null 2>&1
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 2" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
printf 'dismiss latest\n' > "$FIFO"
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 1" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
printf 'dismiss latest\n' > "$FIFO"
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 0" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
EOF
with_daemon "$S" "$S/body.sh"
assert_eq "entry 000002.notif (highest seq) removed first" "no" "$([ -e "$S/state/qs-notif/000002.notif" ] && echo yes || echo no)"
assert_eq "entry 000001.notif removed second (latest re-resolved after the first dismissal)" "no" "$([ -e "$S/state/qs-notif/000001.notif" ] && echo yes || echo no)"
assert_eq "final count is 0" "count 0" "$(sed -n '1p' "$S/run/qs-notif.state" 2>/dev/null)"

scenario "fifo-garbage-ignored: malformed FIFO lines are dropped without crashing the reader"
S="$TMP/s6"; mkdir -p "$S"
cat > "$S/body.sh" <<'EOF'
printf 'nonsense line\n' > "$FIFO"
sleep 0.2
printf 'dismiss\n' > "$FIFO"
sleep 0.2
printf 'bogus verb 000001.notif\n' > "$FIFO"
sleep 0.2
printf 'dismiss ../../etc/passwd\n' > "$FIFO"
sleep 0.2
printf 'dismiss 1234567.notif\n' > "$FIFO"
sleep 0.2
echo "ALIVE=$(kill -0 $QSPID 2>/dev/null && echo yes || echo no)" >> "$RUN/checkpoints"
# a legitimate notify + dismiss afterward must still work -- proves the
# reader loop was never wedged by the garbage above
notify-send "Recovers" "body" >/dev/null 2>&1
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 1" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
printf 'dismiss latest\n' > "$FIFO"
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 0" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
EOF
with_daemon "$S" "$S/body.sh"
assert_eq "daemon survives a stream of malformed FIFO lines" "ALIVE=yes" "$(sed -n '1p' "$S/run/checkpoints" 2>/dev/null)"
assert_eq "a real notify+dismiss after the garbage still works" "count 0" "$(sed -n '1p' "$S/run/qs-notif.state" 2>/dev/null)"

scenario "burst-10-monotonic: 10 notifications inside 1s all land, seq strictly monotonic, final count 10"
S="$TMP/s7"; mkdir -p "$S"
cat > "$S/body.sh" <<'EOF'
_k=1
while [ "$_k" -le 10 ]; do
  notify-send "Burst $_k" "body $_k" >/dev/null 2>&1 &
  _k=$((_k + 1))
done
wait
_i=0; while [ $_i -lt 100 ]; do grep -q "^count 10" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
EOF
with_daemon "$S" "$S/body.sh"
assert_eq "final count is 10" "count 10" "$(sed -n '1p' "$S/run/qs-notif.state" 2>/dev/null)"
n=0
gap=no
prev=0
for f in "$S/state/qs-notif"/[0-9][0-9][0-9][0-9][0-9][0-9].notif; do
  [ -e "$f" ] || continue
  n=$((n + 1))
  b="${f##*/}"; b="${b%.notif}"
  cur=$((10#$b))
  if [ "$prev" -ne 0 ] && [ "$cur" -ne $((prev + 1)) ]; then gap=yes; fi
  prev="$cur"
done
assert_eq "exactly 10 store entries exist" "10" "$n"
assert_eq "seq numbers are gap-free / strictly monotonic (000001..000010)" "no" "$gap"

scenario "markup-folded-state-raw-store: a markup body is stripped/folded in state but kept raw in the store"
S="$TMP/s8"; mkdir -p "$S"
cat > "$S/body.sh" <<'EOF'
notify-send "MarkSum" "line one <b>bold</b>
line two" >/dev/null 2>&1
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 1" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
EOF
with_daemon "$S" "$S/body.sh"
assert_eq "the stored body keeps the raw markup tag" "yes" \
  "$(grep -qF '<b>bold</b>' "$S/state/qs-notif/000001.notif" 2>/dev/null && echo yes || echo no)"
assert_eq "the state 'last' text has no angle-bracket markup" "no" \
  "$(grep -qF '<b>' "$S/run/qs-notif.state" 2>/dev/null && echo yes || echo no)"
assert_eq "the state 'last' text has no raw newline (folded to a space)" "yes" \
  "$([ "$(sed -n '4p' "$S/run/qs-notif.state" 2>/dev/null | wc -l)" = "1" ] && echo yes || echo no)"

scenario "owns-bus-name: a second daemon on the same bus never becomes the owner"
S="$TMP/s9"; mkdir -p "$S"
RUN_A="$S/run-a"; RUN_B="$S/run-b"; STATE_SHARED="$S/state"
mkdir -p "$RUN_A" "$RUN_B" "$STATE_SHARED"
chmod 700 "$RUN_A" "$RUN_B"
cat > "$S/wrapper.sh" <<WRAP
#!/bin/sh
set -u
export XDG_STATE_HOME="$STATE_SHARED"
export QS_NOTIF_STORE_SCRIPT="$STORESH"

export XDG_RUNTIME_DIR="$RUN_A"
export QS_NOTIF_FIFO="$RUN_A/notif.cmd"
export QS_NOTIF_READY_FILE="$RUN_A/ready"
if [ "$QPA_MODE" = "offscreen" ]; then
  QT_QPA_PLATFORM=offscreen quickshell -p "$QMLDIR" >"$RUN_A/daemon.log" 2>&1 &
else
  xvfb-run -a quickshell -p "$QMLDIR" >"$RUN_A/daemon.log" 2>&1 &
fi
PID_A=\$!
i=0; while [ \$i -lt 100 ]; do [ -e "$RUN_A/ready" ] && break; i=\$((i+1)); sleep 0.1; done
i=0; while [ \$i -lt 100 ]; do
  dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.freedesktop.Notifications >/dev/null 2>&1 && break
  i=\$((i+1)); sleep 0.1
done

export XDG_RUNTIME_DIR="$RUN_B"
export QS_NOTIF_FIFO="$RUN_B/notif.cmd"
export QS_NOTIF_READY_FILE="$RUN_B/ready"
if [ "$QPA_MODE" = "offscreen" ]; then
  QT_QPA_PLATFORM=offscreen quickshell -p "$QMLDIR" >"$RUN_B/daemon.log" 2>&1 &
else
  xvfb-run -a quickshell -p "$QMLDIR" >"$RUN_B/daemon.log" 2>&1 &
fi
PID_B=\$!
i=0; while [ \$i -lt 100 ]; do [ -e "$RUN_B/ready" ] && break; i=\$((i+1)); sleep 0.1; done
sleep 0.5

notify-send "OnlyOne" "single owner should get this" >/dev/null 2>&1
i=0; while [ \$i -lt 50 ]; do
  n=0
  for f in "$STATE_SHARED/qs-notif"/[0-9][0-9][0-9][0-9][0-9][0-9].notif; do [ -e "\$f" ] && n=\$((n+1)); done
  [ "\$n" -ge 1 ] && break
  i=\$((i+1)); sleep 0.1
done

kill \$PID_A \$PID_B 2>/dev/null
wait \$PID_A \$PID_B 2>/dev/null
WRAP
chmod +x "$S/wrapper.sh"
timeout 30 dbus-run-session -- sh "$S/wrapper.sh"
n=0
for f in "$S/state/qs-notif"/[0-9][0-9][0-9][0-9][0-9][0-9].notif; do [ -e "$f" ] && n=$((n + 1)); done
assert_eq "exactly one store entry exists (only the real bus owner processed the notification)" "1" "$n"

# ==================================================================================
# LAUNCH PHASE (sp019 task 3, dotfiles-c5fd.3): exercises the REAL
# quickshell/qs-start.sh guard block -- the user-level flock singleton launch,
# the hash-check restart, and the kill-sweep's notif-daemon cmdline exclusion
# -- fully sandboxed:
#   - HOME points at a throwaway dir whose .dotfiles is a SYMLINK to this
#     worktree's own repo root, so qs-start.sh's hardcoded $HOME/.dotfiles/...
#     paths resolve to the code under test (not a real ~/.dotfiles install).
#   - PATH is prepended with a stub bin dir: `quickshell` records its argv to
#     LAUNCH_LOG and sleeps (stands in for the real binary, discoverable by
#     pgrep exactly like the real one); `clang`/`gcc`/`cc` stubs always fail
#     so the UNRELATED qs-stats-daemon C build/launch section fully no-ops --
#     that section's `${TMPDIR:-/tmp}` paths are not sandboxed, so skipping it
#     avoids ever touching a real system's live stats daemon.
#   - DISPLAY is a unique throwaway value per scenario so qs_same_session
#     (real, unmodified qs-session.sh) never matches a real desktop session's
#     processes -- the kill-sweep can never reach outside the sandbox.
#   - SWAYSOCK is stubbed non-empty so qs-session.sh's own i3-detection
#     branch (`command -v i3 && i3 --get-socketpath`) is skipped -- on a
#     fake DISPLAY, invoking the REAL i3 binary blocks for many seconds on
#     an X connection attempt that can never succeed. This is a pre-existing,
#     unmodified qs-session.sh code path; skipping it is purely a sandbox
#     concern, not a functional change under test.
#   - Every wait below is a bounded POLL loop, but the bound is deliberately
#     generous (up to ~90s): this box's `pgrep` was empirically measured at
#     5-6s PER CALL under its current load (`uptime` load average was ~168
#     against 8 cores when this was diagnosed) -- qs_kill_session alone
#     issues 5 pgrep calls per qs-start.sh run, so a single invocation can
#     legitimately take 30-40s here. That is an environment characteristic
#     (see bd notes), not a bug in the guard being tested.
scenario "dotyaml/notif-link-syntax: dot.yaml declares the notif profile link (smoke-checked via yq, rotz itself is never invoked)"
DOTYAML="$REPO_DIR/dot.yaml"
if command -v yq >/dev/null 2>&1; then
  LINK_VAL="$(yq -r '.linux.links.notif' "$DOTYAML" 2>/dev/null)"
else
  LINK_VAL="$(grep -E '^\s+notif:' "$DOTYAML" 2>/dev/null | sed -E 's/^\s+notif:\s*//')"
fi
assert_eq "dot.yaml links.notif points at ~/.config/quickshell-notif" "~/.config/quickshell-notif" "$LINK_VAL"

scenario "LAUNCH PHASE setup"
QS_START="$REPO_DIR/qs-start.sh"
[ -f "$QS_START" ] || { echo "FATAL: qs-start.sh not found at $QS_START" >&2; exit 1; }
DOTFILES_ROOT="$(cd -- "$REPO_DIR/.." && pwd)"

LSTUB="$TMP/launch-stub-bin"
mkdir -p "$LSTUB"
cat > "$LSTUB/quickshell" <<'STUB'
#!/bin/sh
# Deliberately NOT `exec sleep 300`: exec REPLACES this process's own image,
# which would blank /proc/<pid>/cmdline from "quickshell -p ..." to
# "sleep 300" the instant it runs -- invisible to every `pgrep -f
# "quickshell -p ..."` check in qs-start.sh (and in this harness), causing
# spurious double-spawns that have nothing to do with the guard under test.
# A plain (non-exec'd) `sleep` forks a child and this script's own process
# blocks in wait(), keeping its ORIGINAL argv/cmdline intact throughout --
# exactly like the real long-running quickshell binary never re-execs.
printf '%s %s\n' "$(date +%s)" "$*" >> "$LAUNCH_LOG" 2>/dev/null
echo "$$" >> "$LAUNCH_LOG.pids" 2>/dev/null
sleep 300
STUB
chmod +x "$LSTUB/quickshell"
for _fakecc in clang gcc cc; do
  printf '#!/bin/sh\nexit 1\n' > "$LSTUB/$_fakecc"
  chmod +x "$LSTUB/$_fakecc"
done

# Bounded poll: <max_seconds> <check-command...>. Sleeps 0.5s between tries
# (see the "generous timeouts" note above for why this box needs ~90s
# headroom for pgrep-backed checks).
wait_for() { # <max_seconds> <cmd...>
  _max="$1"; shift
  _n=$(( _max * 2 ))
  _k=0
  while [ "$_k" -lt "$_n" ]; do
    "$@" >/dev/null 2>&1 && return 0
    _k=$((_k + 1)); sleep 0.5
  done
  return 1
}

# Runs the real qs-start.sh once, fully sandboxed. Args: <sandbox_dir> <display>
run_launch() { # <sandbox_dir> <display>
  _sb="$1" _dpy="$2"
  _home="$_sb/home"
  mkdir -p "$_home/.cache" "$_home/.local/bin" "$_sb/run" "$_sb/tmp"
  # -sfn (no-dereference, force): atomically replaces any existing symlink
  # in place rather than following it -- a plain check-then-act race here
  # (two concurrent run_launch calls sharing one sandbox, as
  # parallel-start-single does deliberately) would otherwise let a SECOND
  # `ln -s` treat the FIRST call's already-created symlink as a directory
  # target and place a stray link INSIDE the resolved dotfiles root instead
  # of failing safely.
  ln -sfn "$DOTFILES_ROOT" "$_home/.dotfiles"
  env -i \
    HOME="$_home" \
    XDG_RUNTIME_DIR="$_sb/run" \
    TMPDIR="$_sb/tmp" \
    DISPLAY="$_dpy" \
    SWAYSOCK="/dev/null" \
    PATH="$LSTUB:/usr/bin:/bin" \
    LAUNCH_LOG="$_sb/launch.log" \
    sh "$QS_START" >"$_sb/qs-start.out" 2>&1
}

# The exact hash qs-start.sh's own hash-check computes -- mirrored here only
# to seed/verify the cache file, never to bypass the real computation.
notif_hash() { # <notif_profile_dir>
  cat "$1"/*.qml "$DOTFILES_ROOT/quickshell/qs-notif-store.sh" 2>/dev/null | sha1sum | awk '{print $1}'
}

# Kills every stub `quickshell` pid this sandbox ever spawned (tracked via
# LAUNCH_LOG.pids above) -- precise PID-based cleanup, never a name/pattern
# pkill: the shell's PATH lookup leaves argv[0] as the bare "quickshell" it
# was invoked as, so a path-based pkill pattern never matches these, and an
# unscoped `pkill -x quickshell` would risk killing a REAL desktop session's
# live bar. Safe to call on a sandbox dir with no pids file (no-op).
cleanup_sb_pids() { # <sandbox_dir>...
  for _sbd in "$@"; do
    for _p in $(cat "$_sbd/launch.log.pids" 2>/dev/null); do
      kill "$_p" 2>/dev/null
    done
  done
}

scenario "launch/second-start-noop: two sequential qs-start.sh runs spawn the notif daemon exactly once"
SB="$TMP/launch-noop"; mkdir -p "$SB/tmp"
DPY=":9001"
run_launch "$SB" "$DPY"
NOTIF_PATH="$SB/home/.dotfiles/quickshell/notif"
wait_for 90 grep -qF -- "$NOTIF_PATH" "$SB/launch.log"
run_launch "$SB" "$DPY"
sleep 1
SECOND_COUNT=$(grep -cF -- "$NOTIF_PATH" "$SB/launch.log" 2>/dev/null || echo 0)
assert_eq "exactly one notif-daemon spawn logged after two sequential starts" "1" "$SECOND_COUNT"
cleanup_sb_pids "$SB"

scenario "launch/parallel-start-single: two concurrent qs-start.sh runs (real flock) spawn the notif daemon exactly once, green under CPU load"
run_parallel_once() { # <sandbox_dir> <display> -> prints spawn count
  _sb="$1" _dpy="$2"
  mkdir -p "$_sb/tmp"
  run_launch "$_sb" "$_dpy" &
  _p1=$!
  run_launch "$_sb" "$_dpy" &
  _p2=$!
  wait "$_p1" "$_p2"
  _np="$_sb/home/.dotfiles/quickshell/notif"
  wait_for 90 grep -qF -- "$_np" "$_sb/launch.log"
  grep -cF -- "$_np" "$_sb/launch.log" 2>/dev/null || echo 0
}
LOAD_PIDS=""
_ncpu="$( (command -v nproc >/dev/null 2>&1 && nproc) || echo 4)"
_li=0
while [ "$_li" -lt "$_ncpu" ]; do
  yes >/dev/null 2>&1 &
  LOAD_PIDS="$LOAD_PIDS $!"
  _li=$((_li + 1))
done
ALL_OK=yes
for _rep in 1 2; do
  SBP="$TMP/launch-parallel-$_rep"
  N="$(run_parallel_once "$SBP" ":900$((1 + _rep))")"
  [ "$N" = "1" ] || ALL_OK="no(rep$_rep=$N)"
  cleanup_sb_pids "$SBP"
done
for _lp in $LOAD_PIDS; do kill "$_lp" 2>/dev/null; done
assert_eq "exactly one spawn across repeated parallel-start trials under CPU load" "yes" "$ALL_OK"

scenario "launch/hash-same-leaves-pid: unchanged source across two runs leaves the daemon pid untouched"
SB="$TMP/launch-hash-same"; mkdir -p "$SB/tmp"
DPY=":9010"
run_launch "$SB" "$DPY"
NOTIF_PATH="$SB/home/.dotfiles/quickshell/notif"
wait_for 90 pgrep -f -- "quickshell -p $NOTIF_PATH"
PID1="$(pgrep -f -- "quickshell -p $NOTIF_PATH" | head -1)"
run_launch "$SB" "$DPY"
sleep 1
PID2="$(pgrep -f -- "quickshell -p $NOTIF_PATH" | head -1)"
assert_eq "daemon pid is unchanged when the source hash is unchanged" "yes" "$([ -n "$PID1" ] && [ "$PID1" = "$PID2" ] && echo yes || echo no)"
kill "$PID1" 2>/dev/null; kill "$PID2" 2>/dev/null

scenario "launch/hash-change-restarts: a stale cached hash forces pkill+respawn under the lock"
SB="$TMP/launch-hash-change"; mkdir -p "$SB/tmp"
DPY=":9011"
run_launch "$SB" "$DPY"
NOTIF_PATH="$SB/home/.dotfiles/quickshell/notif"
wait_for 90 pgrep -f -- "quickshell -p $NOTIF_PATH"
PID1="$(pgrep -f -- "quickshell -p $NOTIF_PATH" | head -1)"
# Corrupt the CACHED hash so the next run believes the source changed,
# without touching any real repo file.
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$SB/home/.cache/qs-notif-daemon.sha"
run_launch "$SB" "$DPY"
_i=0; while [ $_i -lt 180 ]; do
  _p="$(pgrep -f -- "quickshell -p $NOTIF_PATH" | head -1)"
  [ -n "$_p" ] && [ "$_p" != "$PID1" ] && break
  _i=$((_i + 1)); sleep 0.5
done
PID2="$(pgrep -f -- "quickshell -p $NOTIF_PATH" | head -1)"
assert_eq "daemon pid changes after a hash mismatch (restarted)" "yes" "$([ -n "$PID2" ] && [ "$PID1" != "$PID2" ] && echo yes || echo no)"
CUR_HASH="$(notif_hash "$NOTIF_PATH")"
assert_eq "hash cache is rewritten to the correct value after restart" "$CUR_HASH" "$(cat "$SB/home/.cache/qs-notif-daemon.sha" 2>/dev/null)"
kill "$PID1" 2>/dev/null; kill "$PID2" 2>/dev/null

scenario "launch/sweep-spares-daemon: kill-sweep kills a same-display quickshell pid but spares the notif-profile pid"
SB="$TMP/launch-sweep"; mkdir -p "$SB/tmp" "$SB/home/.cache" "$SB/home/.local/bin" "$SB/run"
ln -sfn "$DOTFILES_ROOT" "$SB/home/.dotfiles"
DPY=":9012"
NOTIF_PATH="$SB/home/.dotfiles/quickshell/notif"
# Pre-seed the hash cache with the CURRENT correct value so the launch
# section's OWN hash-check doesn't also pkill+relaunch this pid -- isolating
# the assertion to the sweep's behavior only.
notif_hash "$NOTIF_PATH" > "$SB/home/.cache/qs-notif-daemon.sha"
env -i HOME="$SB/home" XDG_RUNTIME_DIR="$SB/run" DISPLAY="$DPY" LAUNCH_LOG="$SB/launch.log" "$LSTUB/quickshell" >/dev/null 2>&1 &
DIER=$!
env -i HOME="$SB/home" XDG_RUNTIME_DIR="$SB/run" DISPLAY="$DPY" LAUNCH_LOG="$SB/launch.log" "$LSTUB/quickshell" -p "$NOTIF_PATH" >/dev/null 2>&1 &
SURVIVOR=$!
_i=0; while [ $_i -lt 100 ]; do kill -0 "$DIER" 2>/dev/null && kill -0 "$SURVIVOR" 2>/dev/null && [ -r "/proc/$DIER/environ" ] && break; _i=$((_i + 1)); sleep 0.1; done
run_launch "$SB" "$DPY"
_i=0; while [ $_i -lt 180 ]; do kill -0 "$DIER" 2>/dev/null || break; _i=$((_i + 1)); sleep 0.5; done
assert_eq "the fake same-display quickshell pid is killed by the sweep" "no" "$(kill -0 "$DIER" 2>/dev/null && echo yes || echo no)"
assert_eq "the fake notif-profile pid survives the sweep" "yes" "$(kill -0 "$SURVIVOR" 2>/dev/null && echo yes || echo no)"
kill "$SURVIVOR" 2>/dev/null
cleanup_sb_pids "$SB"

# ==================================================================================
# BAR PHASE (sp019 task 4, dotfiles-c5fd.4): Consumers -- the server is ripped
# out of config/shell.qml; config/Bar.qml becomes a READ-ONLY consumer that
# tails the daemon's live-state file, exactly the qs-stats daemonMode source
# model. Every scenario below drives the REAL config/Bar.qml (symlinked into
# a throwaway harness dir, Common/ alongside it -- test-mode-bar.sh PHASE 2
# precedent) under Xvfb, with a SANDBOXED-PATH i3-msg stub (empty
# get_workspaces, subscribe blocks forever) so no real i3/sway is needed.
# QS_NOTIF_FILE/QS_NOTIF_FIFO point at harness-owned files; state-file
# rewrites are hand-written here in the EXACT shape qs-notif-store.sh's
# `state` verb produces (count/critical/seq/last, tmp+rename), never through
# the real daemon -- this phase is Bar.qml's consumer contract in isolation.
#
# AC3 grep contract is asserted HERE against the shipped shell.qml/Bar.qml,
# so reintroducing the server, the notif-state properties, or the
# dismissNotif*/tickerFinished signal wiring fails the RUN, not just review.
# ==================================================================================

SHELL_QML="$REPO_DIR/config/shell.qml"
BAR_QML="$REPO_DIR/config/Bar.qml"
COMMON_DIR="$REPO_DIR/config/Common"

scenario "grep-contract: shell.qml has no server, Bar.qml has no signal wiring, Variants pass no notif props (AC3)"
a3() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
a3 "shell.qml: NotificationServer/notifSrv/Notifications import/trackCurrent/dismissLatest/_currentNotif all gone" \
  "0" "$(grep -cE 'NotificationServer|notifSrv|Quickshell\.Services\.Notifications|trackCurrent|dismissLatest|_currentNotif' "$SHELL_QML" | tr -d ' ')"
a3 "shell.qml: the Bar {} Variants block passes no notif properties" \
  "0" "$(grep -cE 'notifCount:|notifText:|notifSeq:|hasCritical:' "$SHELL_QML" | tr -d ' ')"
a3 "shell.qml: no dismissNotif/dismissNotifSilent/tickerFinished signal wiring remains" \
  "0" "$(grep -cE 'onDismissNotif|onTickerFinished' "$SHELL_QML" | tr -d ' ')"
a3 "Bar.qml: the dismissNotif/dismissNotifSilent/tickerFinished signals are gone (their props were only fed externally)" \
  "0" "$(grep -cE 'signal dismissNotif|signal tickerFinished' "$BAR_QML" | tr -d ' ')"
a3 "Bar.qml: derives its notif state from tail -F on QS_NOTIF_FILE" \
  "1" "$(grep -cE 'QS_NOTIF_FILE' "$BAR_QML" | tr -d ' ')"
a3 "Bar.qml: writes dismisses to QS_NOTIF_FIFO, not back to shell.qml" \
  "1" "$(grep -cE 'QS_NOTIF_FIFO' "$BAR_QML" | tr -d ' ')"

BAR_XVFB_BIN="${XVFB:-Xvfb}"
BAR_QS_BIN_NAME="${QUICKSHELL:-quickshell}"
BARDPY="${BAR_TEST_DISPLAY:-:99}"

for tool in "$BAR_XVFB_BIN" "$BAR_QS_BIN_NAME"; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (XVFB=/QUICKSHELL= to override)" >&2; exit 1; }
done
[ -r "$BAR_QML" ] || { echo "FATAL: $BAR_QML not readable" >&2; exit 1; }
[ -d "$COMMON_DIR" ] || { echo "FATAL: $COMMON_DIR not a directory" >&2; exit 1; }

BCFG="$TMP/bar-cfg"
BPBIN="$TMP/bar-pbin"
BRUN="$TMP/bar-run"
BCACHE="$TMP/bar-cache"
BSTATE="$BRUN/qs-notif.state"    # harness-owned -- hand-written, never the real daemon
BFIFO="$BRUN/qs-notif.cmd"
BREADLOG="$TMP/bar-fifo-reads.log"
BCASES="$TMP/bar-cases.txt"
mkdir -p "$BCFG" "$BPBIN" "$BRUN" "$BCACHE"
chmod 700 "$BRUN"
: > "$BREADLOG"
: > "$BCASES"

ln -s "$COMMON_DIR" "$BCFG/Common"
ln -s "$BAR_QML" "$BCFG/Bar.qml"

BAR_QS_BIN="$(command -v "$BAR_QS_BIN_NAME")"
# PATH is EXCLUSIVELY this sandbox dir (test-mode-bar.sh PHASE 2 precedent),
# so every real coreutil the Bar's OTHER (unrelated) Processes shell out to
# -- sh itself (notifFeedProc/notifDismiss/statsProc/... are all `sh -c`),
# plus the stats/net/vol/bat probes, all harmless no-ops here -- must be
# symlinked in explicitly or quickshell logs "binary could not be found"
# and every Process, including the ones under test, silently never starts.
for _t in sh cat sleep tr awk df grep sed cut head timeout mv rm date mkfifo iwgetid ip pactl tail; do
  _src="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_src" "$BPBIN/$_t"
done
cat > "$BPBIN/i3-msg" <<'STUBEOF'
#!/bin/sh
case "$1" in
  -t)
    case "$2" in
      get_workspaces) printf '%s' '[]'; exit 0 ;;
      subscribe) exec sleep 300 ;;
      *) exit 0 ;;
    esac ;;
esac
exit 0
STUBEOF
chmod +x "$BPBIN/i3-msg"
ln -sf "$BPBIN/i3-msg" "$BPBIN/swaymsg"

cat > "$BCFG/shell.qml" <<'HOSTEOF'
import Quickshell
import Quickshell.Io
import QtQuick
import "./Common"

ShellRoot {
  id: host
  function emit(n, p) { console.log("CASE " + n + " " + p) }

  function rootOf(w) { return (w && w.contentItem) ? w.contentItem : w }
  function findByName(item, name) {
    if (!item) return null
    var kids = item.children
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i]
      if (c.objectName === name) return c
      var f = findByName(c, name)
      if (f) return f
    }
    return null
  }

  IpcHandler {
    target: "notifprobe"
    function dumpc(name: string): void {
      var r = host.rootOf(bar)
      var tt = host.findByName(r, "notifTickerText")
      host.emit(name + ".count",    bar.notifCount)
      host.emit(name + ".text",     bar.notifText)
      host.emit(name + ".critical", bar.hasCritical ? "1" : "0")
      host.emit(name + ".ticker",   bar.tickerActive ? "1" : "0")
      host.emit(name + ".seq",      bar.notifSeq)
      host.emit(name + ".tx",       tt ? Math.round(tt.x) : "-99999")
    }
    function dismiss(): void { bar.requestDismiss() }
    function bye(): void { Quickshell.exit(0) }
  }

  Bar {
    id: bar
    screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }
}
HOSTEOF

start_xvfb_bar() { # <display> <logfile>
  "$BAR_XVFB_BIN" "$1" -screen 0 1280x800x24 >"$2" 2>&1 &
  _pid=$!
  _i=0
  while [ "$_i" -lt 40 ]; do
    [ -e "/tmp/.X11-unix/X${1#:}" ] && break
    _i=$((_i + 1)); sleep 0.5
  done
  [ -e "/tmp/.X11-unix/X${1#:}" ] || { echo "FATAL: Xvfb $1 did not start" >&2; exit 1; }
  printf '%s' "$_pid"
}
BAR_XVFB_PID="$(start_xvfb_bar "$BARDPY" "$TMP/bar-xvfb.log")"

# Persistent background reader on the harness FIFO -- mirrors the daemon's
# own reader shape (read line-wise in a loop) so a dismiss write from
# Bar.qml always finds a reader and never blocks past its own 2s timeout.
# Bail with `|| exit 1` if the FIFO ever vanishes (this dir gets torn down
# at cleanup) and floor the iteration with a trailing `sleep 0.2` -- the
# exact dotfiles-rfzs fork-bomb fix applied to the real daemon's own FIFO
# reader (quickshell/notif/shell.qml): without both guards, a missing FIFO
# makes `cat` return instantly on ENOENT and the loop burns two forks per
# iteration with nothing to block on.
mkfifo -m 0600 "$BFIFO"
( while :; do [ -p "$BFIFO" ] || exit 1; timeout 3 cat "$BFIFO" >> "$BREADLOG" 2>/dev/null; sleep 0.2; done ) &
BAR_READER_PID=$!

env -u SWAYSOCK DISPLAY="$BARDPY" PATH="$BPBIN" \
    XDG_CONFIG_HOME="$BCFG" XDG_RUNTIME_DIR="$BRUN" XDG_CACHE_HOME="$BCACHE" \
    QS_NOTIF_FILE="$BSTATE" QS_NOTIF_FIFO="$BFIFO" \
    "$BAR_QS_BIN" -p "$BCFG" >"$TMP/bar-qs.out" 2>&1 &
BAR_QS_PID=$!

refresh_cases() { grep -a 'CASE ' "$TMP/bar-qs.out" 2>/dev/null | sed 's/^.*CASE /CASE /' > "$BCASES"; }
barprobe() { # <name>
  env XDG_CONFIG_HOME="$BCFG" XDG_RUNTIME_DIR="$BRUN" XDG_CACHE_HOME="$BCACHE" \
      "$BAR_QS_BIN_NAME" ipc --pid "$BAR_QS_PID" call notifprobe dumpc "$1" >/dev/null 2>&1
}
bar_dismiss() {
  env XDG_CONFIG_HOME="$BCFG" XDG_RUNTIME_DIR="$BRUN" XDG_CACHE_HOME="$BCACHE" \
      "$BAR_QS_BIN_NAME" ipc --pid "$BAR_QS_PID" call notifprobe dismiss >/dev/null 2>&1
}
bar_ipc_show() {
  env XDG_CONFIG_HOME="$BCFG" XDG_RUNTIME_DIR="$BRUN" XDG_CACHE_HOME="$BCACHE" \
      "$BAR_QS_BIN_NAME" ipc --pid "$BAR_QS_PID" show 2>/dev/null
}
bar_case() { # <name.field> -- payload of the LAST matching "CASE <name.field> ..." line so far
  sed -n "s/^CASE $1 //p" "$BCASES" | tail -1
}
bar_assert() { # <scenario> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}
# Bounded poll: waits until dumpc's LATEST snapshot for <name> shows the
# given field at the given value, or gives up after <max_seconds>. Every
# iteration issues a FRESH dumpc call so the snapshot advances with real
# state, not a fixed sleep sized to "should be enough" under load.
wait_case() { # <max_seconds> <name> <field> <expected>
  _max="$1" _cn="$2" _fd="$3" _exp="$4"
  _n=$(( _max * 4 )); _k=0
  while [ "$_k" -lt "$_n" ]; do
    barprobe "$_cn"; sleep 0.15; refresh_cases
    [ "$(bar_case "${_cn}.${_fd}")" = "$_exp" ] && return 0
    _k=$((_k + 1))
  done
  return 1
}

BAR_UP=""
_i=0
while [ "$_i" -lt 80 ]; do
  n="$(bar_ipc_show | grep -c 'notifprobe')"
  [ "${n:-0}" -gt 0 ] && { BAR_UP=1; break; }
  _i=$((_i + 1)); sleep 0.5
done

if [ -z "$BAR_UP" ]; then
  fail "BAR PHASE host exposed the 'notifprobe' IPC target" "a notifprobe target" "none (host did not boot)"
  tail -30 "$TMP/bar-qs.out" >&2
else
  # Atomic tmp+rename rewrite in the EXACT shape qs-notif-store.sh's `state`
  # verb produces -- consumers must see this, never a partial file.
  write_state() { # <count> <critical> <seq> <epoch> <text>
    _wtmp="${BSTATE}.tmp.$$"
    {
      printf 'count %s\n' "$1"
      printf 'critical %s\n' "$2"
      printf 'seq %s\n' "$3"
      printf 'last %s\t%s\n' "$4" "$5"
    } > "$_wtmp"
    mv -f "$_wtmp" "$BSTATE"
  }

  scenario "no-daemon-clean-boot: state file absent at boot -> count 0, no ticker, muted bell"
  wait_case 10 "boot" "count" "0"
  bar_assert "boot: count 0"          "0" "$(bar_case boot.count)"
  bar_assert "boot: text empty"       ""  "$(bar_case boot.text)"
  bar_assert "boot: not critical"     "0" "$(bar_case boot.critical)"
  bar_assert "boot: ticker inactive"  "0" "$(bar_case boot.ticker)"

  scenario "bar-follows-state: writing count/critical/seq/last makes the ticker text + count appear (AC3)"
  EPOCH1="$(date +%s)"
  write_state 1 0 1 "$EPOCH1" "first notification"
  wait_case 20 "s1" "seq" "1"
  bar_assert "s1: seq reaches 1"        "1" "$(bar_case s1.seq)"
  bar_assert "s1: count reaches 1"      "1" "$(bar_case s1.count)"
  bar_assert "s1: not critical"         "0" "$(bar_case s1.critical)"
  bar_assert "s1: ticker became active" "1" "$(bar_case s1.ticker)"
  case "$(bar_case s1.text)" in
    *"first notification") pass "s1: text carries the relative-time-prefixed body" ;;
    *) fail "s1: text carries the relative-time-prefixed body" "*first notification" "$(bar_case s1.text)" ;;
  esac

  scenario "critical-immediate: a critical arrival flips hasCritical the same instant, independent of ticker state (edge case)"
  EPOCH2="$(date +%s)"
  write_state 2 1 2 "$EPOCH2" "urgent thing"
  wait_case 20 "s2" "critical" "1"
  bar_assert "s2: hasCritical flips to 1 while the ticker is still active" "1" "$(bar_case s2.critical)"
  bar_assert "s2: ticker still active (color binds hasCritical, not ticker state)" "1" "$(bar_case s2.ticker)"

  scenario "seq-gate-no-double-ticker: rewriting the SAME seq updates text but never restarts the animation"
  barprobe "before"; sleep 0.3; refresh_cases
  TX_BEFORE="$(bar_case before.tx)"
  # Same seq (2), different text -- an idempotent-per-line dismiss/
  # staterefresh-style rewrite. A correct gate leaves the animation running
  # (x keeps decreasing toward the negative implicitWidth target); a mutant
  # that restarts on every "last" line snaps x back up toward the ticker
  # area's full width the instant the rewrite lands.
  EPOCH3="$(date +%s)"
  write_state 1 0 2 "$EPOCH3" "urgent thing (updated)"
  _k=0; UPDATED=""
  while [ $_k -lt 60 ]; do
    barprobe "after"; sleep 0.15; refresh_cases
    case "$(bar_case after.text)" in *"updated)") UPDATED=1; break ;; esac
    _k=$((_k + 1))
  done
  bar_assert "seq-gate: notifText updates even though seq is unchanged (idempotent per-line set)" "1" "${UPDATED:-0}"
  bar_assert "seq-gate: notifSeq is still 2 (never bumped by the rewrite)" "2" "$(bar_case after.seq)"
  TX_AFTER="$(bar_case after.tx)"
  bar_assert "seq-gate: ticker x did not jump back up (no restart) after the same-seq rewrite" \
    "no-jump" "$([ "${TX_AFTER:-0}" -le "${TX_BEFORE:-0}" ] && echo no-jump || echo JUMPED)"

  scenario "embedded-tab-in-text: only the FIRST tab splits epoch from text (a stray literal tab stays part of the text)"
  EPOCH4="$(date +%s)"
  WEIRD_TEXT="weird$(printf '\t')text"
  _wtmp2="${BSTATE}.tmp.embed"
  {
    printf 'count %s\n' 1
    printf 'critical %s\n' 0
    printf 'seq %s\n' 3
    printf 'last %s\t%s\n' "$EPOCH4" "$WEIRD_TEXT"
  } > "$_wtmp2"
  mv -f "$_wtmp2" "$BSTATE"
  wait_case 20 "s3" "seq" "3"
  case "$(bar_case s3.text)" in
    *"weird"*"text") pass "embedded-tab: text after the first tab (including the stray literal tab) survives intact" ;;
    *) fail "embedded-tab: text after the first tab (including the stray literal tab) survives intact" "*weird<TAB>text" "$(bar_case s3.text)" ;;
  esac

  scenario "dismiss-roundtrip: requesting a dismiss (the bell/ticker click path) writes 'dismiss latest' to the FIFO"
  : > "$BREADLOG"
  bar_dismiss
  _k=0; FOUND=""
  while [ $_k -lt 40 ]; do
    grep -qx 'dismiss latest' "$BREADLOG" 2>/dev/null && { FOUND=1; break; }
    _k=$((_k + 1)); sleep 0.15
  done
  bar_assert "dismiss-roundtrip: the harness FIFO reader saw the literal 'dismiss latest' line" "1" "${FOUND:-0}"

  env XDG_CONFIG_HOME="$BCFG" XDG_RUNTIME_DIR="$BRUN" XDG_CACHE_HOME="$BCACHE" \
      "$BAR_QS_BIN_NAME" ipc --pid "$BAR_QS_PID" call notifprobe bye >/dev/null 2>&1
fi

kill "$BAR_READER_PID" 2>/dev/null
BAR_READER_PID=""
kill "$BAR_QS_PID" 2>/dev/null
BAR_QS_PID=""
sleep 0.5
kill "$BAR_XVFB_PID" 2>/dev/null
BAR_XVFB_PID=""

# ================= SELFTEST NEGATIVE CONTROL ================================
# SELFTEST=1 deliberately flips one expectation to a value the daemon can
# never produce. If this run does not report a FAIL, the harness itself
# (assert_eq / PASS/FAIL bookkeeping) is broken and every green result above
# is meaningless.
if [ "${SELFTEST:-}" = "1" ]; then
  scenario "SELFTEST negative control: a deliberately wrong expectation must FAIL"
  S="$TMP/selftest"; mkdir -p "$S"
  cat > "$S/body.sh" <<'EOF'
notify-send "Selftest" "body" >/dev/null 2>&1
_i=0; while [ $_i -lt 50 ]; do grep -q "^count 1" "$STATEFILE" 2>/dev/null && break; _i=$((_i+1)); sleep 0.1; done
EOF
  with_daemon "$S" "$S/body.sh"
  assert_eq "(SELFTEST) count is WRONGLY expected to be 999" "count 999" "$(sed -n '1p' "$S/run/qs-notif.state" 2>/dev/null)"
fi

# ------------------------------------------------------------------ result ---

printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
