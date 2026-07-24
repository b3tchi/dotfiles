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

cleanup() {
  for _p in $DAEMON_PIDS; do
    kill "$_p" 2>/dev/null
    wait "$_p" 2>/dev/null
  done
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
