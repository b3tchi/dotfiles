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

    # I3SOCK pinned: i3-msg follows the AMBIENT $I3SOCK, which on a developer
    # machine points at their real session. Unpinned, this gate answers from
    # that i3 and passes even when the test i3 failed to start -- a gate that
    # cannot fail for its own reason (dotfiles-qvou).
    if ! DISPLAY="$XD" I3SOCK="$XSOCK" i3-msg -t get_version >/dev/null 2>&1; then
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
        # HOME/HOTKEYD_I3_CONFIG_D sandboxed: `status` consults the panic
        # latch, and unsandboxed it reads the operator's REAL ~/.i3/config.d.
        # A genuinely panicked session then flips this to a misleading
        # diagnostic during an outage (dotfiles-iul2).
        if DISPLAY=$D8 XDG_RUNTIME_DIR="$T8" HOME="$T8" \
           HOTKEYD_I3_CONFIG_D="$T8/config.d" "$HERE/hotkeyd.sh" status >/dev/null 2>&1
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
    # Restating a bind i3 still owns is the exact mistake a fallback built from
    # "the set i3 owns today" would make. The seed must be a chord i3 ACTUALLY
    # owns right now, or this guard silently stops proving anything.
    #
    # It was $mod+o until the nav cutover (dotfiles-hwds.16) moved that chord
    # out of i3 entirely, at which point the seed stopped being a duplicate and
    # the guard fired correctly. Derived from config.common rather than
    # hardcoded so the next cutover cannot quietly defang it the same way.
    #
    # THE PATTERN WIDENED at dotfiles-hwds.48/49: it read `\$mod\+[A-Za-z0-9]+`,
    # i.e. single-segment chords only, and the last two of those in
    # config.common ($mod+r and $mod+9) left with the resize migration and the
    # apps group. Everything i3 still owns carries a second modifier
    # ($mod+Shift+q, $mod+Shift+c, $mod+Shift+r, $mod+Ctrl+Shift+r), so the
    # seed came up empty and the stage failed for the right reason in the wrong
    # place — the third such expiry today. Allowing `+` inside the chord makes
    # the derivation match what "a chord i3 owns" now looks like.
    DUP_CHORD="$(grep -oE '^bindsym \$mod\+[A-Za-z0-9+]+ ' "$HERE/../i3/config.common" \
        | head -n1 | awk '{print $2}')"
    [ -n "$DUP_CHORD" ] || bad "stage 10: found no i3-owned chord to seed with"
    printf 'bindsym %s nop stage10-dup\n' "$DUP_CHORD" > "$C10/.i3/config.d/zz-dup.conf"
    out="$(HOME="$C10" i3 -C -c "$HERE/../i3/config" 2>&1)"
    if [ $? -ne 0 ] || printf '%s' "$out" | grep -qi 'duplicate'; then
        ok "a fallback restating a live i3 bind IS caught by this stage"
    else
        bad "i3 -C accepted a duplicate ($DUP_CHORD) — stage 10 proves nothing"
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

# --- stage 12: a mods-less layer is leavable one-handed (dotfiles-hwds.18) ---
# The unit suite can only assert which grabs were REQUESTED. This asserts they
# were OBTAINED and that X actually delivers `Ctrl+q` to the daemon: on a layer
# that declares no `mods` there is no modifier keysym grab, so no active grab
# routes the key — the passive mask variant is the only thing that can. No i3
# here on purpose: this is about X delivery, and the daemon must work without a
# window manager anyway.
echo "stage 12: mods-less layer, exit key with Ctrl held"
if ! command -v Xvfb >/dev/null || ! command -v xdotool >/dev/null; then
    printf '  \033[33mSKIP\033[0m Xvfb or xdotool missing\n'
else
    D12=""
    _b=$(( 40 + (($$ + 7) % 20) ))
    for _o in 0 1 2 3 4 5 6 7 8 9; do
        _n=$(( _b + _o ))
        [ -e "/tmp/.X${_n}-lock" ] || { D12=":$_n"; break; }
    done
    T12="$TMPD/t12"; mkdir -p "$T12"
    cat > "$T12/plain.py" <<EOF
import sys; sys.path.insert(0, "$HERE")
from binds import Bind, Layer, enter_layer
# No mods: the shape dotfiles-hwds.18 is about. validate() allows it.
BINDS = [Bind('\$mod+o', enter_layer('plain'))]
LAYERS = {'plain': Layer(binds=[Bind('h', 'focus left')], exit_keys=['q'])}
EOF
    Xvfb "$D12" -screen 0 640x480x24 >/dev/null 2>&1 &
    X12P=$!
    sleep 1.5
    if [ -z "$D12" ]; then
        bad "no free X display for the mods-less layer stage"
    else
        # HOTKEYD_I3SOCK points at nothing: there is no i3 on this display, and
        # this keeps the daemon from shelling out to `i3 --get-socketpath`.
        DISPLAY="$D12" XDG_RUNTIME_DIR="$T12" HOTKEYD_I3SOCK="$T12/no-i3.sock" \
            setsid python3 "$HERE/hotkeyd.py" --display "$D12" \
            --binds "$T12/plain.py" >"$T12/d.log" 2>&1 &
        d12=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d12="$(pgrep -f "hotkeyd.py --display $D12" | head -1)"
            [ -n "$d12" ] && break
        done
        python3 -u -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
for line in s.makefile():
    sys.stdout.write(line)
' "$T12/hotkeyd-${D12#:}.sock" >"$T12/state.log" 2>/dev/null &
        R12=$!
        sleep 0.5

        if [ -z "$d12" ]; then
            bad "mods-less daemon did not start: $(tail -2 "$T12/d.log")"
        else
            DISPLAY="$D12" xdotool key --clearmodifiers super+o
            sleep 0.6
            l12="$(tail -1 "$T12/state.log" 2>/dev/null)"
            case "$l12" in
                *'"layer":"plain"'*) ok "entered the mods-less layer" ;;
                *) bad "did not enter the layer (socket: ${l12:-<no line>})" ;;
            esac
            # Ctrl DOWN for the whole tap — no --clearmodifiers, which would
            # release the very modifier under test.
            DISPLAY="$D12" xdotool keydown ctrl
            sleep 0.2
            DISPLAY="$D12" xdotool key q
            sleep 0.6
            DISPLAY="$D12" xdotool keyup ctrl
            l12="$(tail -1 "$T12/state.log" 2>/dev/null)"
            [ "$l12" = '{"layer":"default","mod":null}' ] \
                && ok "Ctrl+q left the layer on a layer that declares no mods" \
                || bad "layer is a trap with Ctrl held (socket: ${l12:-<no line>})"
            grep -q "BadAccess" "$T12/d.log" \
                && bad "the exit-key grabs were REFUSED: $(grep -c BadAccess "$T12/d.log")" \
                || ok "every exit-key grab was obtained (zero BadAccess)"
            kill "$d12" 2>/dev/null
        fi
        kill "$R12" 2>/dev/null
    fi
    kill "$X12P" 2>/dev/null
fi

# --- stage 13: a display without XI2 fails fast, named (dotfiles-hwds.13) ---
# Grabs go through XI2 because a core KeyPress carries no source device. A
# display that cannot do XI2 must therefore say so and exit non-zero — never
# fall back to core grabs, which would leave the daemon running with no device
# attribution at all and nothing reporting it.
#
# The extension is refused through a sitecustomize shim on PYTHONPATH rather
# than a flag in hotkeyd.py: a production switch that disables XI2 is exactly
# the silent-fallback door this check exists to keep shut. The daemon runs as a
# REAL process with REAL argv against a REAL server.
echo "stage 13: a display without XI2 fails fast"
if ! command -v Xvfb >/dev/null; then
    printf '  \033[33mSKIP\033[0m Xvfb missing\n'
else
    D13=""
    _b=$(( 40 + (($$ + 13) % 20) ))
    for _o in 0 1 2 3 4 5 6 7 8 9; do
        _n=$(( _b + _o ))
        [ -e "/tmp/.X${_n}-lock" ] || { D13=":$_n"; break; }
    done
    T13="$TMPD/t13"; mkdir -p "$T13"
    cat > "$T13/sitecustomize.py" <<'EOF'
# Make python-xlib see the server exactly as it would see one built without
# XInput: absent from ListExtensions (which is the gate python-xlib itself
# uses, so the extension is never initialised) and absent from QueryExtension.
# Nothing in hotkeyd.py is touched.
import Xlib.display

_real_list = Xlib.display.Display.list_extensions
_real_query = Xlib.display.Display.query_extension


def _list(self):
    return [e for e in _real_list(self) if e != "XInputExtension"]


def _query(self, name):
    return None if name == "XInputExtension" else _real_query(self, name)


Xlib.display.Display.list_extensions = _list
Xlib.display.Display.query_extension = _query
EOF
    Xvfb "$D13" -screen 0 640x480x24 >/dev/null 2>&1 &
    X13P=$!
    sleep 1.5
    if [ -z "$D13" ]; then
        bad "no free X display for the XI2-absence stage"
    else
        out="$(DISPLAY=$D13 XDG_RUNTIME_DIR="$T13" PYTHONPATH="$T13" \
               HOTKEYD_I3SOCK="$T13/no-i3.sock" timeout 15 \
               python3 "$HERE/hotkeyd.py" --display "$D13" 2>&1)"
        rc=$?
        if [ "$rc" -eq 124 ]; then
            bad "daemon HUNG on a display without XI2"
        elif [ "$rc" -eq 0 ]; then
            bad "daemon reported success on a display without XI2 — it fell "\
"back to core grabs, which carry no source device"
        else
            ok "exits non-zero ($rc) on a display without XI2"
        fi
        printf '%s' "$out" | grep -qi 'XI2 unavailable' \
            && ok "the message names XI2" \
            || bad "no 'XI2 unavailable' in the output: $out"
        printf '%s' "$out" | grep -q 'XInputExtension' \
            && ok "and names the missing extension" \
            || bad "does not name the extension: $out"
        if printf '%s' "$out" | grep -q 'Traceback'; then
            bad "failed with a stack trace instead of a named error"
        else
            ok "no stack trace"
        fi
        # Nothing left behind to reap: the probe runs before the lock and the
        # state socket exist.
        if [ -e "$T13/hotkeyd-${D13#:}.sock" ]; then
            bad "left a state socket behind after refusing to start"
        else
            ok "left no state socket behind"
        fi
        # And the same tree on the SAME display, WITHOUT the shim, must start —
        # otherwise every check above would pass on a daemon that is simply
        # broken.
        DISPLAY=$D13 XDG_RUNTIME_DIR="$T13" HOTKEYD_I3SOCK="$T13/no-i3.sock" \
            setsid python3 "$HERE/hotkeyd.py" --display "$D13" \
            >"$T13/d.log" 2>&1 &
        d13=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d13="$(pgrep -f "hotkeyd.py --display $D13" | head -1)"
            [ -n "$d13" ] && break
        done
        if [ -n "$d13" ] && grep -q "chords grabbed on $D13 via XI2" \
                "$T13/d.log"; then
            ok "the same display DOES start the daemon without the shim"
        else
            bad "control case failed — the stage proves nothing: $(tail -2 "$T13/d.log")"
        fi
        [ -n "$d13" ] && kill "$d13" 2>/dev/null
    fi
    kill "$X13P" 2>/dev/null
fi


# ============================================================================
# stage 14: a foreign exclusive keyboard grab is reported, not swallowed
# ============================================================================
#
# dotfiles-hwds.30. An exclusive keyboard grab (XGrabKeyboard) bypasses every
# PASSIVE grab on the display, so while one is held no hotkeyd chord and no i3
# bind fires — and every other signal still says healthy: the loop turns, the
# display answers, the grabs are registered. On the real :0 that combination sat
# unnoticed for days and an afternoon went into suspecting the daemon, which was
# never the holder (it was a locked screensaver, which grabs by design).
#
# Two things are pinned here that the unit tests cannot reach, both being shell
# wiring that was written and verified by hand once:
#   1. `hotkeyd.sh status` exits 8 for this condition, not 0 and not 6.
#   2. It does NOT tell the operator to run `start`. The message says restarting
#      cannot fix it, so printing that suffix contradicts itself in one line and
#      sends whoever reads it round a loop that never converges.
echo "stage 14: a foreign keyboard grab is reported as NOT SERVING"
if ! command -v Xvfb >/dev/null; then
    printf '  \033[33mSKIP\033[0m Xvfb missing\n'
else
    D14=""
    _b=$(( 40 + (($$ + 14) % 20) ))
    for _o in 0 1 2 3 4 5 6 7 8 9; do
        _n=$(( _b + _o ))
        [ -e "/tmp/.X${_n}-lock" ] || { D14=":$_n"; break; }
    done
    T14="$TMPD/t14"; mkdir -p "$T14"
    if [ -z "$D14" ]; then
        bad "no free X display for the foreign-grab stage"
    else
        Xvfb "$D14" -screen 0 640x480x24 >/dev/null 2>&1 &
        X14P=$!
        sleep 1.5
        # A stand-in for the locker: takes an exclusive keyboard grab and holds
        # it until killed. Nothing else about it matters — X does not name the
        # holder, so any client will do.
        cat > "$T14/grabber.py" <<'GRABEOF'
import sys, time
from Xlib import X, display
d = display.Display(sys.argv[1])
r = d.screen().root.grab_keyboard(True, X.GrabModeAsync, X.GrabModeAsync,
                                  X.CurrentTime)
d.sync()
print("grab result", r, flush=True)
time.sleep(600)
GRABEOF
        # A fresh lock file so health sees a beating heartbeat: the point of the
        # stage is that everything ELSE looks healthy while the keyboard is gone.
        : > "$T14/hotkeyd-${D14#:}.lock"
        out="$(XDG_RUNTIME_DIR="$T14" timeout 20 \
               python3 "$HERE/hotkeyd.py" --health --display "$D14" 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            ok "control: an UNGRABBED display reports serving"
        else
            bad "control failed — the stage proves nothing (rc=$rc): $out"
        fi

        python3 "$T14/grabber.py" "$D14" >"$T14/grab.log" 2>&1 &
        G14P=$!
        sleep 1.5
        if grep -q "grab result 0" "$T14/grab.log"; then
            ok "the stand-in holds an exclusive keyboard grab"
        else
            bad "the stand-in did NOT get the grab: $(cat "$T14/grab.log")"
        fi

        out="$(XDG_RUNTIME_DIR="$T14" timeout 20 \
               python3 "$HERE/hotkeyd.py" --health --display "$D14" 2>&1)"
        rc=$?
        if [ "$rc" -eq 8 ]; then
            ok "--health exits 8 (keyboard grabbed) rather than 0"
        else
            bad "--health returned $rc for a grabbed keyboard: $out"
        fi
        case "$out" in
            *"NOT SERVING"*) ok "--health says NOT SERVING" ;;
            *) bad "--health did not say NOT SERVING: $out" ;;
        esac
        case "$out" in
            *lock*|*LOCK*) ok "--health names the usual holder (a locked screen)" ;;
            *) bad "--health gave no lead on who holds it: $out" ;;
        esac

        # A REAL daemon, started while the grab is already held. Two things ride
        # on it: the STARTUP WARNING (a daemon that logs "N chords grabbed" and
        # nothing else is the exact confident-and-inert line that misled the :0
        # investigation), and `hotkeyd.sh status`, which resolves the daemon by
        # pgrep against its argv — a stand-in process cannot stand in for that.
        cat > "$T14/one.py" <<EOF
import sys; sys.path.insert(0, "$HERE")
from binds import Bind
BINDS = [Bind('\$mod+F11', 'nop grabbed-stage')]
LAYERS = {}
EOF
        rm -f "$T14/hotkeyd-${D14#:}.lock"
        DISPLAY=$D14 XDG_RUNTIME_DIR="$T14" HOTKEYD_I3SOCK="$T14/no-i3.sock" \
            python3 "$HERE/hotkeyd.py" --display "$D14" \
            --binds "$T14/one.py" >"$T14/d.log" 2>&1 &
        D14P=$!
        d14=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d14="$(pgrep -f "hotkeyd.py --display $D14" | head -1)"
            [ -n "$d14" ] && break
        done
        if [ -z "$d14" ]; then
            bad "the daemon did not start on the grabbed display: $(tail -3 "$T14/d.log")"
        else
            ok "the daemon starts anyway (a grab is somebody else's and will end)"
            # WAIT for it. The warning lands AFTER the grab line, not with it:
            # the probe asks three times 300 ms apart before condemning, so a
            # grep fired the instant pgrep sees the pid reads a log that is
            # still one line short. Cost a false FAIL here before it was spotted.
            _warned=""
            for _t in 1 2 3 4 5 6 7 8 9 10; do
                grep -q "WARNING on $D14" "$T14/d.log" && { _warned=1; break; }
                sleep 0.5
            done
            if [ -n "$_warned" ]; then
                ok "and WARNS at startup that its chords are bypassed"
            else
                bad "startup logged no warning about the grab: $(tail -3 "$T14/d.log")"
            fi
            if grep -q "chords grabbed on $D14" "$T14/d.log"; then
                ok "control: it still reports the grabs it registered"
            else
                bad "no grab line at all — the stage is testing the wrong thing"
            fi

            sout="$(XDG_RUNTIME_DIR="$T14" timeout 25 \
                    sh "$HERE/hotkeyd.sh" status "$D14" 2>&1)"
            src=$?
            if [ "$src" -eq 8 ]; then
                ok "hotkeyd.sh status exits 8 too"
            else
                bad "hotkeyd.sh status returned $src: $sout"
            fi
            case "$sout" in
                *"NOT SERVING"*) ok "status relays NOT SERVING rather than 'running'" ;;
                *) bad "status did not say NOT SERVING: $sout" ;;
            esac
            case "$sout" in
                *"hotkeyd.sh start"*)
                    bad "status told the operator to run start, which cannot fix a foreign grab" ;;
                *) ok "status does NOT suggest a restart that cannot help" ;;
            esac
            kill "$d14" 2>/dev/null
        fi
        kill "$D14P" 2>/dev/null
        kill "$G14P" 2>/dev/null
        kill "$X14P" 2>/dev/null
    fi
fi


# ============================================================================
# stage 15: a daemon missing grabs reports DEGRADED, not "running"
# ============================================================================
#
# dotfiles-hwds.42, split out of the hwds.41 outage: the :10 daemon had lost
# the whole directional group and `hotkeyd.sh status` still printed
# "running on :10 (pid …, socket …)". Liveness was true, serving was not, and
# nothing in the tool could tell them apart — the loop turned, the display
# answered, the heartbeat was fresh, and half the binds were dead.
#
# Driven with a REAL daemon whose table asks for a chord the keymap cannot
# resolve, which is the same shape as a grab lost to an xrdp keymap reset: the
# chord stays WANTED and simply is not active.
echo "stage 15: missing grabs report DEGRADED"
if ! command -v Xvfb >/dev/null; then
    printf '  \033[33mSKIP\033[0m Xvfb missing\n'
else
    D15=""
    _b=$(( 40 + (($$ + 15) % 20) ))
    for _o in 0 1 2 3 4 5 6 7 8 9; do
        _n=$(( _b + _o ))
        [ -e "/tmp/.X${_n}-lock" ] || { D15=":$_n"; break; }
    done
    T15="$TMPD/t15"; mkdir -p "$T15"
    if [ -z "$D15" ]; then
        bad "no free X display for the degraded stage"
    else
        Xvfb "$D15" -screen 0 640x480x24 >/dev/null 2>&1 &
        X15P=$!
        sleep 1.5

        # CONTROL FIRST: a table that resolves completely must NOT be degraded,
        # or the stage cannot tell "detects damage" from "always complains".
        cat > "$T15/whole.py" <<EOF
import sys; sys.path.insert(0, "$HERE")
from binds import Bind
BINDS = [Bind('\$mod+F11', 'nop whole')]
LAYERS = {}
EOF
        DISPLAY=$D15 XDG_RUNTIME_DIR="$T15" HOTKEYD_I3SOCK="$T15/no-i3.sock" \
            python3 "$HERE/hotkeyd.py" --display "$D15" \
            --binds "$T15/whole.py" >"$T15/whole.log" 2>&1 &
        W15P=$!
        w15=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            w15="$(pgrep -f "hotkeyd.py --display $D15" | head -1)"
            [ -n "$w15" ] && break
        done
        if [ -z "$w15" ]; then
            bad "the control daemon did not start: $(tail -3 "$T15/whole.log")"
        else
            out="$(XDG_RUNTIME_DIR="$T15" timeout 25 \
                   sh "$HERE/hotkeyd.sh" status "$D15" 2>&1)"
            rc=$?
            if [ "$rc" -eq 0 ]; then
                ok "control: a fully-grabbed table reports running"
            else
                bad "control failed (rc=$rc) — the stage proves nothing: $out"
            fi
            kill "$w15" 2>/dev/null
            sleep 1
        fi
        kill "$W15P" 2>/dev/null

        # THE DAMAGED CASE, produced the way it actually happens. A typo in the
        # table cannot be used: `--check` refuses an unknown keysym before the
        # daemon starts, which is correct and means the config-error path never
        # reaches this state. The real cause (dotfiles-hwds.41) is a KEYMAP that
        # changes under a running daemon — routine on :10, where xrdp
        # reprograms it on every reconnect — leaving a chord wanted, resolvable
        # yesterday, and gone today.
        #
        # Reproduced by deleting F11's keysyms from the live server, which is a
        # real ChangeKeyboardMapping and makes the server emit a real
        # MappingNotify to every client, the daemon included.
        cat > "$T15/unmap.py" <<'UNMAPEOF'
import sys
from Xlib import X, XK, display
d = display.Display(sys.argv[1])
code = d.keysym_to_keycode(XK.string_to_keysym("F11"))
if not code:
    print("no keycode for F11", flush=True)
    raise SystemExit(1)
per = d.display.info.max_keycode - d.display.info.min_keycode
d.change_keyboard_mapping(code, [[X.NoSymbol] * 4])
d.sync()
print("unmapped F11 (keycode %d)" % code, flush=True)
UNMAPEOF
        rm -f "$T15/hotkeyd-${D15#:}.lock" "$T15/hotkeyd-${D15#:}.grabs"
        DISPLAY=$D15 XDG_RUNTIME_DIR="$T15" HOTKEYD_I3SOCK="$T15/no-i3.sock" \
            python3 "$HERE/hotkeyd.py" --display "$D15" \
            --binds "$T15/whole.py" >"$T15/holed.log" 2>&1 &
        H15P=$!
        h15=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            h15="$(pgrep -f "hotkeyd.py --display $D15" | head -1)"
            [ -n "$h15" ] && break
        done
        if [ -z "$h15" ]; then
            bad "the daemon did not start for the damaged case: $(tail -3 "$T15/holed.log")"
        else
            if [ -f "$T15/hotkeyd-${D15#:}.grabs" ]; then
                ok "it published a grab report while healthy"
            else
                bad "no grab report was written — status has nothing to read"
            fi

            python3 "$T15/unmap.py" "$D15" >"$T15/unmap.log" 2>&1
            if grep -q "unmapped F11" "$T15/unmap.log"; then
                ok "the live keymap lost F11 under the running daemon"
            else
                bad "could not unmap F11: $(cat "$T15/unmap.log")"
            fi
            # The daemon re-resolves on MappingNotify and republishes; give the
            # event a moment to land rather than racing it.
            _deg=""
            for _t in 1 2 3 4 5 6 7 8 9 10; do
                sleep 0.5
                grep -q 'nosuchkeysym\|F11' "$T15/hotkeyd-${D15#:}.grabs" 2>/dev/null \
                    && { _deg=1; break; }
            done

            out="$(XDG_RUNTIME_DIR="$T15" timeout 25 \
                   sh "$HERE/hotkeyd.sh" status "$D15" 2>&1)"
            rc=$?
            if [ "$rc" -eq 9 ]; then
                ok "status exits 9 (DEGRADED) rather than 0"
            else
                bad "status returned $rc for a daemon that lost a grab: $out"
            fi
            case "$out" in
                *DEGRADED*) ok "status says DEGRADED" ;;
                *) bad "status did not say DEGRADED: $out" ;;
            esac
            case "$out" in
                *F11*)
                    ok "and NAMES the missing chord (a count means diffing the table by hand)" ;;
                *) bad "status named no missing chord: $out" ;;
            esac
            kill "$h15" 2>/dev/null
        fi
        kill "$H15P" 2>/dev/null
        kill "$X15P" 2>/dev/null
    fi
fi

echo
printf 'hotkeyd: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
