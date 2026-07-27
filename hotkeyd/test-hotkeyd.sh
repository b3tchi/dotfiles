#!/usr/bin/env bash
# Runtime suite for hotkeyd (sp020). Task 2 (dotfiles-yvxs) covers the bind
# table + loader + --check; Tasks 3-4 extend this file with layer-engine,
# socket and grab cases.
#
# Bash rather than nushell per adr0002 condition 1 — this must run on a fresh
# box and in CI before any dotfiles link step has happened.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# No .pyc files. Python validates a cached module by (source mtime, size) with
# ONE-SECOND granularity, so editing binds.py within the same second that its
# bytecode was written makes the stale cache look fresh — and the suite then
# tests the previous version of the code while reporting on the current one.
# Hit during this task's own mutation testing: a restored file kept running the
# mutant. A test suite that can silently grade the wrong source is worse than
# no suite, and the cache buys nothing here.
export PYTHONDONTWRITEBYTECODE=1
rm -rf "$HERE/__pycache__"

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# --- stage 1: loader + engine unit suites ----------------------------------
echo "stage 1: bind table loader + layer engine (pytest)"
if ! command -v python3 >/dev/null; then
    bad "python3 missing"
else
    for suite in test_binds.py test_layers.py test_daemon.py; do
        out="$(cd "$HERE" && python3 -m pytest "$suite" -q 2>&1)"
        if [ $? -eq 0 ]; then
            ok "$suite ($(printf '%s' "$out" | tail -1))"
        else
            bad "$suite"
            printf '%s\n' "$out" | tail -25
        fi
    done
fi

# --- stage 2: --check contract on the shipped table ------------------------
echo "stage 2: --check on the shipped table"
if out="$(python3 "$HERE/hotkeyd.py" --check 2>&1)"; then
    ok "exits 0: $out"
else
    bad "shipped table does not validate: $out"
fi

# --- stage 3: --check rejects a seeded duplicate, naming the chord ---------
echo "stage 3: --check rejects a seeded fault"
TMP="$(mktemp -d)"
TMPD="$TMP"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/faulty.py" <<EOF
import sys; sys.path.insert(0, "$HERE")
from binds import Bind, Layer, enter_layer
BINDS = [Bind('Mod4+z', 'kill'), Bind('Mod4+z', 'nop dup'),
         Bind('Mod4+y', ''), Bind('Mod4+o', enter_layer('ghost'))]
LAYERS = {}
EOF
out="$(python3 "$HERE/hotkeyd.py" --check --binds "$TMP/faulty.py" 2>&1)"
rc=$?
if [ $rc -ne 0 ]; then
    ok "exits non-zero ($rc)"
else
    bad "faulty table validated clean — the validator is not load-bearing"
fi
for token in 'Mod4+z' 'Mod4+y' 'ghost'; do
    if printf '%s' "$out" | grep -q -- "$token"; then
        ok "names $token"
    else
        bad "does not name $token (a bare non-zero exit is not actionable)"
    fi
done

# --- stage 4: validation needs no X ---------------------------------------
echo "stage 4: --check works with no DISPLAY"
if out="$(env -u DISPLAY python3 "$HERE/hotkeyd.py" --check 2>&1)"; then
    ok "headless: $out"
else
    bad "needs an X display: $out"
fi

# --- stage 5: the daemon fails fast on a dead display ----------------------
# NEVER run the daemon against the caller's own DISPLAY: it would grab every
# chord in the table out from under the live i3 session for as long as the test
# runs. :99 has no server, so this exercises the startup path and the adr0014
# fail-fast exit without touching anything real.
echo "stage 5: daemon fails fast on an unreachable display"
out="$(DISPLAY=:99 timeout 10 python3 "$HERE/hotkeyd.py" --display :99 2>&1)"
rc=$?
if [ "$rc" -eq 124 ]; then
    bad "daemon hung against a dead display instead of failing fast"
elif [ "$rc" -ne 0 ]; then
    ok "exits non-zero ($rc) without hanging"
else
    bad "daemon reported success against a display that does not exist"
fi


# --- stage 6: live X — real grabs, real dispatch ---------------------------
# Everything above runs against fakes. These stages are the ones that would have
# caught poc013's findings, so they use a real X server and a real i3.
echo "stage 6: live X (Xvfb + i3)"
if ! command -v Xvfb >/dev/null || ! command -v i3 >/dev/null; then
    printf '  \033[33mSKIP\033[0m Xvfb or i3 missing\n'
else
    XD=":89"
    XSOCK="/tmp/i3-hotkeyd-test-$$.sock"
    XCFG="$TMPD/i3-live.conf"
    mkdir -p "$TMPD"
    printf 'font pango:monospace 10\nipc-socket %s\nbindsym Mod4+F11 nop taken-by-i3\n' \
        "$XSOCK" > "$XCFG"
    Xvfb "$XD" -screen 0 800x600x24 >/dev/null 2>&1 &
    XVFB_PID=$!
    sleep 1.5
    DISPLAY="$XD" i3 -c "$XCFG" >/dev/null 2>&1 &
    I3_PID=$!
    sleep 1.5

    if ! DISPLAY="$XD" i3-msg -t get_version >/dev/null 2>&1; then
        bad "live i3 did not start on $XD"
    else
        out="$(DISPLAY="$XD" XDG_RUNTIME_DIR="$TMPD" I3SOCK="$XSOCK" \
               python3 "$HERE/live_check.py" 2>&1)"
        rc=$?
        printf '%s\n' "$out" | while IFS= read -r line; do
            case "$line" in
                PASS*) printf '  \033[32m%s\033[0m\n' "$line" ;;
                FAIL*) printf '  \033[31m%s\033[0m\n' "$line" ;;
                *)     printf '    %s\n' "$line" ;;
            esac
        done
        n_pass=$(printf '%s' "$out" | grep -c '^PASS')
        n_fail=$(printf '%s' "$out" | grep -c '^FAIL')
        PASS=$((PASS + n_pass))
        FAIL=$((FAIL + n_fail))
        [ "$rc" -ne 0 ] && [ "$n_fail" -eq 0 ] && bad "live_check.py exited $rc"
    fi
    kill "$I3_PID" 2>/dev/null
    kill "$XVFB_PID" 2>/dev/null
    rm -f "$XSOCK"
fi

# --- stage 7: launcher lifecycle -------------------------------------------
# Own file because it runs two Xvfb displays at once and drives real daemon
# processes; kept behind this entry point so the post-merge gate stays one
# command.
echo "stage 7: launcher lifecycle"
lout="$(bash "$HERE/test-launcher.sh" 2>&1)"
lrc=$?
printf '%s\n' "$lout" | sed -n 's/^  /    /p'
lsummary="$(printf '%s' "$lout" | tail -1)"
if [ "$lrc" -eq 0 ]; then
    ok "launcher suite ($lsummary)"
else
    bad "launcher suite ($lsummary)"
fi

# --- stage 8: daemon-level table handling ----------------------------------
# The run_daemon zone had ZERO coverage in any style, which is exactly why the
# SIGHUP kill and the skipped startup validation shipped. These drive a REAL
# daemon against a throwaway display, so a regression in either fails here
# rather than being discovered during an outage.
echo "stage 8: daemon load path (real process, throwaway display)"
if ! command -v Xvfb >/dev/null; then
    printf '  \033[33mSKIP\033[0m Xvfb missing\n'
else
    D8=":87"
    Xvfb "$D8" -screen 0 640x480x24 >/dev/null 2>&1 &
    X8=$!
    sleep 1.5
    T8="$TMPD/t8"; mkdir -p "$T8"

    cat > "$T8/trap.py" <<EOF
import sys; sys.path.insert(0, "$HERE")
from binds import Bind, Layer, enter_layer
BINDS = [Bind('\$mod+o', enter_layer('trap'))]
LAYERS = {'trap': Layer(binds=[Bind('h', 'focus left')], exit_keys=[])}
EOF
    out="$(DISPLAY=$D8 XDG_RUNTIME_DIR="$T8" timeout 15 \
           python3 "$HERE/hotkeyd.py" --display "$D8" --binds "$T8/trap.py" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "exit_keys"; then
        ok "startup refuses an invalid table, naming the problem"
    else
        bad "startup accepted an invalid table (rc=$rc): $out"
    fi

    cp "$HERE/binds.py" "$T8/live.py"
    DISPLAY=$D8 XDG_RUNTIME_DIR="$T8" setsid python3 "$HERE/hotkeyd.py" \
        --display "$D8" --binds "$T8/live.py" >"$T8/d.log" 2>&1 &
    sleep 2
    dpid="$(pgrep -f "hotkeyd.py .*--display $D8" | head -1)"
    if [ -z "$dpid" ]; then
        bad "daemon did not start on $D8: $(tail -2 "$T8/d.log")"
    else
        ok "daemon started with a valid table"
        if DISPLAY=$D8 XDG_RUNTIME_DIR="$T8" "$HERE/hotkeyd.sh" status >/dev/null 2>&1
        then ok "launcher finds a daemon started with extra flags"
        else bad "launcher's pgrep pattern misses a flag-carrying daemon"
        fi

        echo "LAYERS = {}" > "$T8/live.py"
        kill -HUP "$dpid" 2>/dev/null; sleep 1.5
        if kill -0 "$dpid" 2>/dev/null; then
            ok "survives SIGHUP with a table missing BINDS"
        else
            bad "SIGHUP with a broken table KILLED the daemon"
        fi

        cp "$HERE/binds.py" "$T8/live.py"
        printf "\nBINDS = BINDS + [Bind('\$mod+o', 'nop dup')]\n" >> "$T8/live.py"
        kill -HUP "$dpid" 2>/dev/null; sleep 1.5
        if kill -0 "$dpid" 2>/dev/null; then
            ok "survives SIGHUP with a validation-invalid table"
        else
            bad "SIGHUP with a duplicate chord KILLED the daemon"
        fi
        if grep -q "reload REFUSED" "$T8/d.log"; then
            ok "refused reloads say so and name the offender"
        else
            bad "no 'reload REFUSED' in the log: $(tail -3 "$T8/d.log")"
        fi
        kill "$dpid" 2>/dev/null
    fi
    kill "$X8" 2>/dev/null
fi

echo
printf 'hotkeyd: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
