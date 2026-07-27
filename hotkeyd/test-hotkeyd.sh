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

# --- stage 9: panic / resume ------------------------------------------------
# Own file for the same reason as the launcher suite: it runs two Xvfb displays
# and a real i3, and it needs a throwaway HOME because panic links into
# ~/.i3/config.d. Kept behind this entry point so the gate stays one command.
echo "stage 9: panic / resume"
pout="$(bash "$HERE/test-panic.sh" 2>&1)"
prc=$?
printf '%s\n' "$pout" | sed -n 's/^  /    /p'
psummary="$(printf '%s' "$pout" | tail -1)"
if [ "$prc" -eq 0 ]; then
    ok "panic suite ($psummary)"
else
    bad "panic suite ($psummary)"
fi

# --- stage 10: i3 -C over the composed tree, fallback linked ----------------
# The fallback is a REAL i3 config file that i3 parses during an outage. A stub
# that rots is worse than nothing, because it is discovered exactly then. Its
# CONTENT is guarded by test_binds.py (it must be binds.py's chord set minus
# i3's); this is the other half — that the composed tree i3 will actually load,
# WITH the fallback in it, still parses. The specific failure being guarded is
# a duplicate keybinding: i3 treats one as a config ERROR rather than
# last-wins, so a fallback restating a live bind breaks the config it was meant
# to rescue. `zz-` settles glob order and grants no override.
echo "stage 10: i3 -C on the composed tree with the fallback linked"
if ! command -v i3 >/dev/null; then
    printf '  \033[33mSKIP\033[0m i3 missing\n'
else
    for overlay in native wsl; do
        C10="$TMPD/compose-$overlay"
        mkdir -p "$C10/.i3/config.d"
        ln -sfn "$HERE/.." "$C10/.dotfiles"
        ln -sfn "$HERE/../i3/config.d/$overlay.conf" \
            "$C10/.i3/config.d/$overlay.conf"
        out="$(HOME="$C10" i3 -C -c "$HERE/../i3/config" 2>&1)"
        rc=$?
        [ "$rc" -eq 0 ] \
            && ok "$overlay overlay parses clean without the fallback" \
            || bad "$overlay overlay: rc=$rc $out"

        ln -sfn "$HERE/../i3/config.d/zz-fallback-binds.conf" \
            "$C10/.i3/config.d/zz-fallback-binds.conf"
        out="$(HOME="$C10" i3 -C -c "$HERE/../i3/config" 2>&1)"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            bad "$overlay overlay FAILS i3 -C with the fallback linked: $out"
        elif printf '%s' "$out" | grep -qi 'duplicate'; then
            bad "$overlay overlay: duplicate keybinding with the fallback: $out"
        else
            ok "$overlay overlay parses clean WITH the fallback linked"
        fi
    done

    # Guard on the guard: prove this stage can actually see a duplicate. A
    # composed-tree check that passes no matter what the fallback says would
    # give the freshness rule no teeth at all.
    C10="$TMPD/compose-dup"
    mkdir -p "$C10/.i3/config.d"
    ln -sfn "$HERE/.." "$C10/.dotfiles"
    ln -sfn "$HERE/../i3/config.d/native.conf" "$C10/.i3/config.d/native.conf"
    # $mod+o is bound in i3/config.common — restating it is the exact mistake
    # a fallback built from "the set i3 owns today" would make.
    printf 'bindsym $mod+o mode "nav"\n' > "$C10/.i3/config.d/zz-dup.conf"
    out="$(HOME="$C10" i3 -C -c "$HERE/../i3/config" 2>&1)"
    if [ $? -ne 0 ] || printf '%s' "$out" | grep -qi 'duplicate'; then
        ok "a fallback restating a live i3 bind IS caught by this stage"
    else
        bad "i3 -C accepted a duplicate keybinding — stage 10 proves nothing"
    fi
fi

# --- stage 11: i3-mode / daemon-layer arbitration (dotfiles-hwds.10) --------
# The documented repro, run for real: `i3-msg 'mode "resize"'` then $mod+o used
# to log 11 BadAccess (i3's mode already holds passive grabs on nav's bare keys)
# while the daemon still published layer=nav — two owners, each looking healthy
# on its own side. So every case here asserts BOTH sides: i3's binding state AND
# the last line on the daemon's state socket.
echo "stage 11: i3-mode / daemon-layer arbitration"
if ! command -v Xvfb >/dev/null || ! command -v i3 >/dev/null \
        || ! command -v xdotool >/dev/null; then
    printf '  \033[33mSKIP\033[0m Xvfb, i3 or xdotool missing\n'
else
    # Take a display nobody has claimed, starting from a PID-derived offset. A
    # fixed number collides with any other X server on the box (a second copy of
    # this suite, a parallel worktree), and a collision here does not look like
    # one: the two runs fight over the same grab, and — worse — a suite that
    # cleans up with `pkill -f "hotkeyd.py.*--display :NN"` kills the other run's
    # daemon, which reads as "the daemon did not start".
    D11=""
    _b=$(( 40 + ($$ % 20) ))
    for _o in 0 1 2 3 4 5 6 7 8 9; do
        _n=$(( _b + _o ))
        [ -e "/tmp/.X${_n}-lock" ] || { D11=":$_n"; break; }
    done
    T11="$TMPD/t11"; mkdir -p "$T11"
    # This i3 gets its OWN ipc socket, and every i3-msg below is pinned to it.
    # Without that pin i3-msg follows the ambient $I3SOCK — the caller's real
    # session — so the stage would drive the developer's live i3 into a mode
    # and then assert against it. Ask how that was found.
    XSOCK11="$T11/i3-arb.sock"
    cat > "$T11/i3.conf" <<EOF
ipc-socket $XSOCK11
EOF
    cat >> "$T11/i3.conf" <<'EOF'
font pango:monospace 10
set $mod Mod4
# The colliding set measured on the real config: an i3 mode holding the bare
# keys the nav layer wants. $mod+o is deliberately NOT bound here — it is the
# daemon's entry chord.
mode "resize" {
        bindsym h resize shrink width 5 px
        bindsym j resize grow height 5 px
        bindsym k resize shrink height 5 px
        bindsym l resize grow width 5 px
        bindsym q mode "default"
        bindsym Escape mode "default"
        bindsym Return mode "default"
}
bindsym $mod+r mode "resize"
EOF
    Xvfb "$D11" -screen 0 640x480x24 >/dev/null 2>&1 &
    X11P=$!
    sleep 1.5
    DISPLAY="$D11" i3 -c "$T11/i3.conf" >/dev/null 2>&1 &
    I11P=$!
    sleep 1.5

    if [ -z "$D11" ]; then
        bad "no free X display for the arbitration stage"
    elif ! DISPLAY="$D11" I3SOCK="$XSOCK11" i3-msg -t get_version >/dev/null 2>&1;
    then
        bad "live i3 did not start on $D11"
    else
        DISPLAY="$D11" XDG_RUNTIME_DIR="$T11" setsid python3 "$HERE/hotkeyd.py" \
            --display "$D11" >"$T11/d.log" 2>&1 &
        d11=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d11="$(pgrep -f "hotkeyd.py --display $D11" | head -1)"
            [ -n "$d11" ] && break
        done
        # Read the state socket for the whole stage: the daemon's own claim
        # about who owns the keyboard, as a bar would see it.
        python3 -u -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
for line in s.makefile():
    sys.stdout.write(line)
' "$T11/hotkeyd-${D11#:}.sock" >"$T11/state.log" 2>/dev/null &
        R11=$!
        sleep 0.5

        state() { DISPLAY="$D11" I3SOCK="$XSOCK11" i3-msg -t get_binding_state \
                      2>/dev/null; }
        last()  { tail -1 "$T11/state.log" 2>/dev/null; }
        # Entering the mode is this stage's PRECONDITION, not its assertion, so
        # wait for i3 to report it rather than sleeping a guessed interval.
        enter_mode() {
            DISPLAY="$D11" I3SOCK="$XSOCK11" i3-msg "mode \"$1\"" >/dev/null 2>&1
            for _w in 1 2 3 4 5 6 7 8 9 10; do
                sleep 0.15
                printf '%s' "$(state)" | grep -q "\"$1\"" && return 0
            done
            return 1
        }

        # This stage owns three processes on a box that may be running other
        # copies of this suite. If one of them is gone the assertions below
        # measure nothing, so say THAT rather than emit five mysteries.
        alive() { kill -0 "$d11" 2>/dev/null && kill -0 "$I11P" 2>/dev/null; }

        if [ -z "$d11" ]; then
            bad "arbitration daemon did not start: $(tail -2 "$T11/d.log")"
        elif ! DISPLAY="$D11" I3SOCK="$XSOCK11" i3-msg -t get_version \
                >/dev/null 2>&1; then
            bad "i3 stopped answering on $D11 before the stage began"
        else
            # -- the repro: enter an i3 mode, then press the layer chord ------
            enter_mode resize
            DISPLAY="$D11" xdotool key --clearmodifiers super+o
            sleep 0.6
            bs="$(state)"; ls="$(last)"
            printf '%s' "$bs" | grep -q 'resize' \
                && ok "i3 holds mode resize" \
                || bad "i3 binding state is not resize: $bs"
            case "$ls" in
                *'"layer":"nav"'*)
                    bad "daemon published layer=nav while i3 holds a mode" ;;
                *) ok "daemon did NOT take the layer (socket: ${ls:-<no line>})" ;;
            esac
            if grep -q "BadAccess" "$T11/d.log"; then
                bad "BadAccess during the refused entry: $(grep -c BadAccess "$T11/d.log")"
            else
                ok "zero BadAccess — the grabs were never requested"
            fi
            grep -q "refusing to enter layer" "$T11/d.log" \
                && grep -q "resize" "$T11/d.log" \
                && ok "the refusal is logged, naming i3's mode" \
                || bad "no refusal naming the mode: $(tail -3 "$T11/d.log")"

            # -- the negative case: with i3 in default, entry must still work --
            enter_mode default
            DISPLAY="$D11" xdotool key --clearmodifiers super+o
            sleep 0.6
            bs="$(state)"; ls="$(last)"
            printf '%s' "$bs" | grep -q 'default' \
                && ok "i3 is back in the default binding state" \
                || bad "i3 binding state is not default: $bs"
            case "$ls" in
                *'"layer":"nav"'*)
                    ok "layer entry still succeeds when i3 owns no mode" ;;
                *) bad "arbitration refuses everything (socket: ${ls:-<no line>})" ;;
            esac
            grep -q "BadAccess" "$T11/d.log" \
                && bad "BadAccess on an ACCEPTED layer entry" \
                || ok "zero BadAccess on the accepted entry"

            # -- the other direction: i3 takes a mode while the layer is up ----
            # Sampled over a window, both sides each time: the invariant is that
            # they are never BOTH non-default, and that while i3 holds the mode
            # the daemon reports `default`. One sample after a fixed sleep would
            # miss a daemon that yields late — and would fail spuriously if
            # anything else on the box drops i3 back to default afterwards.
            n_before="$(grep -c '"layer":"default"' "$T11/state.log")"
            DISPLAY="$D11" I3SOCK="$XSOCK11" i3-msg 'mode "resize"' >/dev/null 2>&1
            agreed=0; overlap=0
            for _w in 1 2 3 4 5 6 7 8; do
                sleep 0.15
                bs="$(state)"; ls="$(last)"
                case "$bs" in
                    *resize*)
                        [ "$ls" = '{"layer":"default","mod":null}' ] && agreed=1
                        case "$ls" in *'"layer":"nav"'*) overlap=1 ;; esac ;;
                esac
            done
            n_after="$(grep -c '"layer":"default"' "$T11/state.log")"
            [ "$agreed" -eq 1 ] && [ "$overlap" -eq 0 ] \
                && ok "i3 entering a mode exits the layer (both sides agree)" \
                || bad "two owners: i3=$bs daemon=${ls:-<no line>}"
            [ "$((n_after - n_before))" -eq 1 ] \
                && ok "the takeover publishes exactly one default line" \
                || bad "published $((n_after - n_before)) default lines, want 1"
            alive || bad "the daemon or i3 died mid-stage — the results above " \
                         "measured a corpse (another copy of this suite?)"
            kill "$d11" 2>/dev/null
        fi
        kill "$R11" 2>/dev/null
    fi
    kill "$I11P" 2>/dev/null
    kill "$X11P" 2>/dev/null
fi

echo
printf 'hotkeyd: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
