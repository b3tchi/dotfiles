#!/usr/bin/env bash
# Launcher lifecycle suite (sp020 Task 5, dotfiles-6tx4).
#
# Drives hotkeyd.sh against throwaway Xvfb displays — never the caller's own.
# Two displays run at once because the whole point of the scoping is that :0 and
# :10 hold separate daemons with separate locks and sockets, and a bug there is
# invisible with a single display.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

export PYTHONDONTWRITEBYTECODE=1
RUNTIME="$(mktemp -d)"

# `start` refuses while the panic fallback is linked (hotkeyd-panic.sh). Point
# the latch at a throwaway dir so this suite never reads — or is blocked by —
# the caller's real ~/.i3/config.d. The panic path itself is covered by
# test-panic.sh.
export HOTKEYD_I3_CONFIG_D="$RUNTIME/i3-config.d"

# Probe for free displays rather than hardcoding: several suites in this repo run
# their own Xvfbs on fixed low numbers and may be running concurrently. Same
# helper shape as i3/scripts/test-clip-integration.sh.
probe_free_display() { # <start-number>
    local n="$1"
    while [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X${n}-lock" ]; do
        n=$((n + 1))
    done
    printf ':%s' "$n"
}
XA="$(probe_free_display 71)"
XB="$(probe_free_display "$(( ${XA#:} + 1 ))")"
TAG_A="${XA#:}"
TAG_B="${XB#:}"
XVFB_PIDS=()

cleanup() {
    for dpy in "$XA" "$XB"; do
        DISPLAY="$dpy" XDG_RUNTIME_DIR="$RUNTIME" \
            "$HERE/hotkeyd.sh" stop >/dev/null 2>&1
    done
    for p in "${XVFB_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    rm -rf "$RUNTIME"
}
trap cleanup EXIT

if ! command -v Xvfb >/dev/null; then
    echo "launcher suite: Xvfb missing — skipped"
    exit 0
fi

for dpy in "$XA" "$XB"; do
    Xvfb "$dpy" -screen 0 640x480x24 >/dev/null 2>&1 &
    XVFB_PIDS+=($!)
done
sleep 1.5

run() { DISPLAY="$1" XDG_RUNTIME_DIR="$RUNTIME" "$HERE/hotkeyd.sh" "${@:2}"; }

# --- verbs -----------------------------------------------------------------
echo "launcher: verbs"
run "$XA" status >/dev/null 2>&1 && bad "status is 0 while stopped" \
    || ok "status exits non-zero while stopped"

out="$(run "$XA" start 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "start exits 0" || bad "start exited $rc: $out"
sleep 1
run "$XA" status >/dev/null 2>&1 && ok "status exits 0 while running" \
    || bad "status non-zero while running"

# --- one daemon per display, distinct runtime files -------------------------
echo "launcher: per-display scoping"
run "$XB" start >/dev/null 2>&1
sleep 1
n_a=$(pgrep -f "hotkeyd.py.*--display $XA" 2>/dev/null | wc -l)
n_b=$(pgrep -f "hotkeyd.py.*--display $XB" 2>/dev/null | wc -l)
[ "$n_a" = 1 ] && ok "exactly one daemon on $XA" || bad "$n_a daemons on $XA"
[ "$n_b" = 1 ] && ok "exactly one daemon on $XB" || bad "$n_b daemons on $XB"
[ -e "$RUNTIME/hotkeyd-$TAG_A.sock" ] && [ -e "$RUNTIME/hotkeyd-$TAG_B.sock" ] \
    && ok "each display has its own state socket" \
    || bad "sockets missing: $(ls "$RUNTIME" | tr '\n' ' ')"
[ -e "$RUNTIME/hotkeyd-$TAG_A.lock" ] && [ -e "$RUNTIME/hotkeyd-$TAG_B.lock" ] \
    && ok "each display has its own lock" || bad "locks missing"

# --- idempotent start -------------------------------------------------------
echo "launcher: start when already running"
out="$(run "$XA" start 2>&1)"; rc=$?
sleep 0.5
n=$(pgrep -f "hotkeyd.py.*--display $XA" 2>/dev/null | wc -l)
[ "$n" = 1 ] && ok "second start did not spawn a duplicate" \
    || bad "$n daemons after a second start"
[ "$rc" -ne 0 ] && ok "second start reports non-zero ($rc)" \
    || bad "second start silently reported success"

# --- restart / escape hatch -------------------------------------------------
echo "launcher: restart after SIGKILL (the escape-hatch path)"
pkill -9 -f "hotkeyd.py.*--display $XA"
sleep 0.5
run "$XA" status >/dev/null 2>&1 && bad "status still 0 after SIGKILL" \
    || ok "status reports the daemon is gone after SIGKILL"
out="$(run "$XA" restart 2>&1)"; rc=$?
sleep 1
n=$(pgrep -f "hotkeyd.py.*--display $XA" 2>/dev/null | wc -l)
[ "$rc" -eq 0 ] && [ "$n" = 1 ] \
    && ok "restart recovers a SIGKILLed daemon" \
    || bad "restart rc=$rc daemons=$n: $out"

# The i3 escape-hatch bind must invoke EXACTLY this path — a bind that drifts
# from the script is discovered during an outage, which is the worst moment.
#
# RE-POINTED AT PANIC (sp020 Task 10). This used to assert `hotkeyd.sh restart`.
# The escape hatch is now `hotkeyd-panic.sh panic`, because a restart only ever
# recovered a DEAD daemon and this bind exists just as much for one that is
# alive and wrong. Asserting the old string would now pass only if the old,
# insufficient bind were still there.
COMMON="$HERE/../i3/config.common"
BIND_LINE="$(grep -n 'bindsym $mod+Shift+r .*hotkeyd-panic\.sh panic' \
             "$COMMON" || true)"
if [ -n "$BIND_LINE" ]; then
    ok "i3 base config binds \$mod+Shift+r to hotkeyd-panic.sh panic"
else
    bad "no panic bind calling hotkeyd-panic.sh panic in i3/config.common"
fi

# And the superseded one must be GONE, not merely joined. Two escape hatches is
# one too many: the restart bind would still be reachable, still reinstate the
# table that broke the session, and still look like the recovery key.
if grep -q '^[[:space:]]*bind\(sym\|code\).*hotkeyd\.sh restart' "$COMMON"; then
    bad "the superseded 'hotkeyd.sh restart' escape hatch is still bound"
else
    ok "the superseded restart escape hatch is gone from i3/config.common"
fi

# restart takes the display as an ARGUMENT — the i3 escape-hatch bind runs with
# whatever DISPLAY i3 exports, but a human debugging one session passes it
# explicitly. run() exports DISPLAY, so this calls the script directly with
# DISPLAY unset to prove the argument alone is enough.
echo "launcher: restart honours an explicit display argument"
DISPLAY= XDG_RUNTIME_DIR="$RUNTIME" "$HERE/hotkeyd.sh" restart "$XA" >/dev/null 2>&1
rc=$?
sleep 1
n=$(pgrep -f "hotkeyd.py.*--display $XA" 2>/dev/null | wc -l)
[ "$rc" -eq 0 ] && [ "$n" = 1 ] \
    && ok "restart with an explicit display and no DISPLAY env" \
    || bad "restart rc=$rc daemons=$n with an explicit display argument"

# --- stop -------------------------------------------------------------------
echo "launcher: stop"
run "$XA" stop >/dev/null 2>&1
sleep 0.5
n=$(pgrep -f "hotkeyd.py.*--display $XA" 2>/dev/null | wc -l)
[ "$n" = 0 ] && ok "stop ends the daemon" || bad "$n daemons still running"
[ ! -e "$RUNTIME/hotkeyd-$TAG_A.sock" ] && ok "stop leaves no stale socket" \
    || bad "stale socket left behind"
n_b=$(pgrep -f "hotkeyd.py.*--display $XB" 2>/dev/null | wc -l)
[ "$n_b" = 1 ] && ok "stopping $XA left $XB alone" \
    || bad "stop crossed sessions: $n_b daemons on $XB"

out="$(run "$XA" stop 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "stop when not running exits cleanly" \
    || bad "stop on a stopped daemon exited $rc: $out"

# --- check ------------------------------------------------------------------
echo "launcher: check"
run "$XA" check >/dev/null 2>&1 && ok "check validates the shipped table" \
    || bad "check failed on the shipped table"
DISPLAY= XDG_RUNTIME_DIR="$RUNTIME" "$HERE/hotkeyd.sh" check >/dev/null 2>&1 \
    && ok "check works with DISPLAY unset" || bad "check needs a display"

# --- an IDLE daemon whose X server dies (dotfiles-hwds.28) ------------------
# dotfiles-hwds.28 was filed on the hypothesis that adr0014 fail-fast is
# implemented on the EVENT path only, so a daemon blocked waiting for an event
# that will never come cannot learn its connection is gone. Measured across five
# death modes (SIGTERM/SIGKILL, with and without a real i3, immediately and after
# 15 s of idling), that is false: the daemon exits in about a second every time.
#
# It survives because the idle branch has TWO independent observers of the X
# connection, and either one is enough: d.pending_events() answers a zero-timeout
# select + recv on the X fd and raises ConnectionClosedError at EOF, and the fd
# is also in the select() wait set, where d.fileno() re-raises the same stored
# error. Confirmed by mutation — swallowing the first alone still exits; the
# daemon only outlives its server once BOTH are removed.
#
# This case exists to keep it that way. Nothing else in the suite notices if the
# idle path stops touching X, and that change looks like a harmless optimisation.
echo "launcher: an idle daemon exits when its X server dies (adr0014)"
XC="$(probe_free_display "$(( ${XB#:} + 1 ))")"
Xvfb "$XC" -screen 0 640x480x24 >/dev/null 2>&1 &
XC_PID=$!
XVFB_PIDS+=("$XC_PID")
sleep 1.5
run "$XC" start >/dev/null 2>&1
sleep 1
idle_pid="$(pgrep -f "hotkeyd.py.*--display $XC" 2>/dev/null | head -1)"
if [ -z "$idle_pid" ]; then
    bad "no daemon started on $XC"
else
    # Deliberately NOTHING is injected: the whole claim is about a daemon that
    # is not pumping events.
    sleep 3
    kill "$XC_PID" 2>/dev/null
    waited=0
    while [ "$waited" -lt 12 ] && kill -0 "$idle_pid" 2>/dev/null; do
        sleep 1; waited=$((waited + 1))
    done
    if kill -0 "$idle_pid" 2>/dev/null; then
        bad "the idle daemon outlived its X server by >${waited}s"
        kill -9 "$idle_pid" 2>/dev/null
    else
        ok "the idle daemon exited ${waited}s after its X server died"
    fi
fi

# --- a daemon that is ALIVE but NOT SERVING (dotfiles-hwds.28) --------------
# `status` answered from daemon_pid() alone, which a daemon serving the keyboard
# and one frozen mid-loop answer identically: both hold the flock, both keep the
# state socket bound so connections still complete out of the listen backlog,
# both match every process pattern. So it printed "running" at exit 0 for a
# daemon serving nothing.
#
# That is a liveness check that cannot observe death, and here it did active
# harm rather than merely being useless: the operator (and the live verification
# matrix) could not get the real answer out of the launcher, so they went looking
# for it with `xdpyinfo`, which was not installed on that machine, exited 127,
# and got read as a dead X server — on a display whose Xorg had been up for
# eleven days with a healthy daemon attached. dotfiles-hwds.19/.21, third time.
#
# The specimen is synthesised by FREEZING the daemon with SIGSTOP and then
# replacing its X server, which is precisely the state pgrep cannot tell from
# health. SIGSTOP targets the one pid this suite started; nothing here
# pattern-kills (dotfiles-8xt).
echo "launcher: a daemon that is alive but not serving"
XD="$(probe_free_display "$(( ${XC#:} + 1 ))")"
TAG_D="${XD#:}"
Xvfb "$XD" -screen 0 640x480x24 >/dev/null 2>&1 &
XD_PID=$!
XVFB_PIDS+=("$XD_PID")
sleep 1.5
run "$XD" start >/dev/null 2>&1
sleep 1
stale_pid="$(pgrep -f "hotkeyd.py.*--display $XD" 2>/dev/null | head -1)"
if [ -z "$stale_pid" ]; then
    bad "no daemon started on $XD"
else
    kill -STOP "$stale_pid" 2>/dev/null
    kill "$XD_PID" 2>/dev/null           # the session that daemon belonged to
    sleep 1
    Xvfb "$XD" -screen 0 640x480x24 >/dev/null 2>&1 &   # ... and the next one
    XD_PID2=$!
    XVFB_PIDS+=("$XD_PID2")
    sleep 6                              # outlast the heartbeat window

    out="$(run "$XD" status 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        ok "status is non-zero for a daemon that is not serving (rc=$rc)"
    else
        bad "status reported healthy (rc=0) for a frozen daemon: $out"
    fi
    # A bare non-zero exit during an outage ends the investigation instead of
    # directing it, which is half of what the .19/.21 lesson is about.
    if printf '%s' "$out" | grep -qi 'not serving'; then
        ok "status names the condition rather than just failing"
    else
        bad "status gave no actionable reason: $out"
    fi
    if printf '%s' "$out" | grep -q "$stale_pid"; then
        ok "status names the pid that is not serving"
    else
        bad "status did not name the offending pid: $out"
    fi
    kill -CONT "$stale_pid" 2>/dev/null
    run "$XD" stop >/dev/null 2>&1
fi

# --- degraded environments --------------------------------------------------
echo "launcher: degraded environments"
out="$(DISPLAY= XDG_RUNTIME_DIR="$RUNTIME" "$HERE/hotkeyd.sh" start 2>&1)"; rc=$?
# rc 2 specifically, not merely non-zero: "failed to start" is also non-zero,
# and it would mean the launcher TRIED rather than refused.
[ "$rc" -eq 2 ] && ok "start with no DISPLAY refuses (rc=2, did not try)" \
    || bad "expected rc=2 refusal, got rc=$rc: $out"
out="$(DISPLAY="$XA" XDG_RUNTIME_DIR=/nonexistent-dir-xyz \
       "$HERE/hotkeyd.sh" status 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "status with an unwritable runtime dir refuses" \
    || bad "status claimed success with a bogus runtime dir"

run "$XB" stop >/dev/null 2>&1
echo
printf 'launcher: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
