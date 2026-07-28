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
