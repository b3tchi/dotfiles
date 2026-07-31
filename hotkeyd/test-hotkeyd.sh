#!/usr/bin/env bash
# Runtime suite for hotkeyd (sp020). Task 2 (dotfiles-yvxs) covers the bind
# table + loader + --check; Tasks 3-4 extend this file with layer-engine,
# socket and grab cases.
#
# Bash rather than nushell per adr0002 condition 1 — this must run on a fresh
# box and in CI before any dotfiles link step has happened.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Daemon-under-test seam (dotfiles-2ats): every direct daemon invocation and
# every `pgrep`/`pkill` that identifies a running daemon goes through these two.
#
# CUT OVER TO GO AT dotfiles-ylmp.16. The python daemon is deleted from the tree
# and hotkeyd.sh no longer has an engine to choose between, so the documented
# invocation of this suite is now the bare
#   ./test-hotkeyd.sh
# with nothing exported. The two variables survive only so a build under test
# can be pointed at from elsewhere (CI, a bisect) without editing the suite; a
# caller that overrides HOTKEYD_BIN must override HOTKEYD_PROC_PAT to agree with
# the argv that build actually presents, or this suite's pgrep hunts for a
# process nothing started — a silent mismatch, not a skip.
HOTKEYD_BIN="${HOTKEYD_BIN:-$HERE/hotkeyd}"
HOTKEYD_PROC_PAT="${HOTKEYD_PROC_PAT:-hotkeyd}"

# FAIL FAST, LOUDLY, HERE. Every stage below either runs $HOTKEYD_BIN directly
# or goes through hotkeyd.sh (which resolves the same binary and dies 78 when it
# is missing). Without this the first symptom is stage 2 printing a shell
# "No such file or directory" and 40-odd stages failing for a reason none of
# them names. The binary is a build artifact, not a checked-in file.
if [ ! -x "${HOTKEYD_BIN%% *}" ]; then
    printf 'test-hotkeyd: %s is not executable — build it first:\n' \
        "${HOTKEYD_BIN%% *}" >&2
    printf '  cd %s && CGO_ENABLED=0 go build -o hotkeyd ./cmd/hotkeyd\n' \
        "$HERE" >&2
    exit 78
fi

# Stage 6's live-X suite (sp021 Task 14) drives cmd/livecheck, which takes
# `--display`/`--i3sock` and REQUIRES the display explicitly — it never inherits
# $DISPLAY, so it cannot land on a live session.
#
# Left empty on purpose (dotfiles-ylmp.16): cmd/livecheck is NOT built by
# `rotz install hotkeyd` and is not a checked-in binary, so a default PATH would
# be absent on every clean checkout and stage 6 would degrade into a skip — the
# one outcome this tree refuses (test-engine.sh's header). Empty means "build it
# on demand into this run's scratch dir", which is what stage 6 does, mirroring
# how test-engine.sh builds its table fixtures. Set it to test a prebuilt one.
HOTKEYD_LIVECHECK="${HOTKEYD_LIVECHECK:-}"

# Stage 1 runs the daemon's OWN unit suites. Parameterised so a caller can
# narrow the run (e.g. HOTKEYD_UNIT_CMD='go test ./cmd/hotkeyd'); the default is
# the whole module.
HOTKEYD_UNIT_CMD="${HOTKEYD_UNIT_CMD:-go test ./...}"

# The bind-table fixture seam: table_daemon(), which turns every "a daemon
# carrying THIS table" stage below into a purpose-built binary, because the
# daemon's table is compiled in and there is no way to hand it one at runtime.
# See test-engine.sh's header for why that is a build rather than a skip.
. "$HERE/test-engine.sh"

PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# --- stage 1: loader + engine unit suites ----------------------------------
echo "stage 1: bind table loader + layer engine (unit suites)"
# NOT optional and never skipped: a daemon whose own unit suites do not run has
# not been measured by this stage at all, and an empty runner would leave a
# blank where the coverage is supposed to be. An operator who narrowed the
# runner to nothing gets told so.
if [ -z "$HOTKEYD_UNIT_CMD" ]; then
    bad "HOTKEYD_UNIT_CMD is empty — the daemon's own unit suites did not run"
else
    uout="$( cd "$HERE" && eval "$HOTKEYD_UNIT_CMD" 2>&1 )"
    if [ $? -eq 0 ]; then
        ok "engine unit suites ($HOTKEYD_UNIT_CMD)"
    else
        bad "engine unit suites failed ($HOTKEYD_UNIT_CMD)"
        printf '%s\n' "$uout" | tail -25
    fi
fi

# --- stage 2: --check contract on the shipped table ------------------------
echo "stage 2: --check on the shipped table"
if out="$($HOTKEYD_BIN --check 2>&1)"; then
    ok "exits 0: $out"
else
    bad "shipped table does not validate: $out"
fi

# --- stage 3: --check rejects a seeded duplicate, naming the chord ---------
echo "stage 3: --check rejects a seeded fault"
TMP="$(mktemp -d)"
TMPD="$TMP"
trap 'rm -rf "$TMP"' EXIT
# Four faults in one table — a duplicate chord, an empty action, and a layer
# entry naming a layer that does not exist — so the assertions below can check
# that the diagnosis NAMES each one rather than just exiting non-zero.
cat > "$TMP/faulty.go" <<'EOF'
package main

import "hotkeyd/internal/bind"

func init() {
	Binds = []bind.Bind{
		{Chord: "Mod4+z", Actions: cmdAction("kill")},
		{Chord: "Mod4+z", Actions: cmdAction("nop dup")},
		{Chord: "Mod4+y", Actions: cmdAction("")},
		{Chord: "Mod4+o", Actions: []bind.Action{bind.EnterLayer{Layer: "ghost"}}},
	}
	Layers = map[string]bind.Layer{}
}
EOF
if ! table_daemon "$TMP/faulty.go" "$TMP" faulty; then
    bad "no daemon could be produced for the faulty table — stage 3 measured nothing"
else
    out="$($TBL_BIN --check 2>&1)"
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
fi

# --- stage 4: validation needs no X ---------------------------------------
echo "stage 4: --check works with no DISPLAY"
if out="$(env -u DISPLAY $HOTKEYD_BIN --check 2>&1)"; then
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
out="$(DISPLAY=:99 timeout 10 $HOTKEYD_BIN --display :99 2>&1)"
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
    # BUILD THE RIG (dotfiles-ylmp.16). cmd/livecheck is a test rig, not a
    # shipped artifact — `rotz install hotkeyd` never builds it and it is not
    # checked in — so this stage produces it rather than expecting it on disk.
    # Into the run's scratch dir, never into the source tree, for the same
    # reason test-engine.sh overlays its fixtures instead of writing them:
    # a stray binary beside the daemon is a thing that gets committed.
    # A build that fails FAILS the stage; it must never degrade into a skip,
    # which would report a green run that checked no live grab at all.
    if [ -z "$HOTKEYD_LIVECHECK" ]; then
        if ( cd "$HERE" && go build -o "$TMPD/livecheck" ./cmd/livecheck ) \
               >"$TMPD/livecheck-build.log" 2>&1; then
            HOTKEYD_LIVECHECK="$TMPD/livecheck"
        else
            bad "could not build cmd/livecheck — stage 6 measured nothing: $(tail -5 "$TMPD/livecheck-build.log")"
        fi
    fi
    # Mod4+F8 is the CORE-grab marker (sp021 Task 14): i3 grabs its own binds
    # with core XGrabKey, and `mark --add` makes it observable whether i3
    # actually received the key. That is what lets a live check measure "core
    # and XI2 passive grabs are separate conflict domains, and the later XI2
    # grabber wins delivery" without installing a core grabber of its own --
    # internal/x11 has no core GrabKey request and deliberately never will.
    printf 'font pango:monospace 10\nipc-socket %s\nbindsym Mod4+F11 nop taken-by-i3\nbindsym Mod4+F8 mark --add hotkeyd-live-i3-core\n' \
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
    if [ -z "$HOTKEYD_LIVECHECK" ]; then
        # The build failure above is already a FAIL. Nothing more to say here —
        # and nothing is quietly passed over.
        :
    elif ! DISPLAY="$XD" I3SOCK="$XSOCK" i3-msg -t get_version >/dev/null 2>&1;
    then
        bad "live i3 did not start on $XD"
    else
        out="$(DISPLAY="$XD" XDG_RUNTIME_DIR="$TMPD" I3SOCK="$XSOCK" \
               HOTKEYD_BIN="$HOTKEYD_BIN" \
               $HOTKEYD_LIVECHECK --display "$XD" --i3sock "$XSOCK" 2>&1)"
        rc=$?
        printf '%s\n' "$out" | while IFS= read -r line; do
            case "$line" in
                PASS*) printf '  \033[32m%s\033[0m\n' "$line" ;;
                FAIL*) printf '  \033[31m%s\033[0m\n' "$line" ;;
                SKIP*) printf '  \033[33m%s\033[0m\n' "$line" ;;
                *)     printf '    %s\n' "$line" ;;
            esac
        done
        n_pass=$(printf '%s' "$out" | grep -c '^PASS')
        n_fail=$(printf '%s' "$out" | grep -c '^FAIL')
        # SKIP is cmd/livecheck's third verdict (im009: a claim whose
        # precondition did not hold on this run is never PASS). Counted and
        # announced separately -- never folded into PASS, which is the whole
        # point, and never into FAIL, which would conflate "the rig lacks
        # xdotool" with "the daemon is broken".
        n_skip=$(printf '%s' "$out" | grep -c '^SKIP')
        PASS=$((PASS + n_pass))
        FAIL=$((FAIL + n_fail))
        [ "$n_skip" -gt 0 ] && printf '  \033[33m%s live claims were SKIPPED (precondition absent) — not passes\033[0m\n' "$n_skip"
        [ "$rc" -ne 0 ] && [ "$n_fail" -eq 0 ] && bad "live check exited $rc"
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

    # A layer with no exit_keys and no hold: entering it is a one-way door, so
    # validation must refuse the table before the daemon ever grabs anything.
    cat > "$T8/trap.go" <<'EOF'
package main

import "hotkeyd/internal/bind"

func init() {
	Binds = []bind.Bind{
		{Chord: "$mod+o", Actions: []bind.Action{bind.EnterLayer{Layer: "trap"}}},
	}
	Layers = map[string]bind.Layer{
		"trap": {Binds: []bind.Bind{{Chord: "h", Actions: cmdAction("focus left")}}},
	}
}
EOF
    if ! table_daemon "$T8/trap.go" "$T8" trap; then
        bad "no daemon could be produced for the trap table — the startup-refusal case measured nothing"
    else
        out="$(DISPLAY=$D8 XDG_RUNTIME_DIR="$T8" timeout 15 \
               $TBL_BIN --display "$D8" 2>&1)"
        rc=$?
        if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "exit_keys"; then
            ok "startup refuses an invalid table, naming the problem"
        else
            bad "startup accepted an invalid table (rc=$rc): $out"
        fi
    fi

    # The live daemon below runs the SHIPPED table, and the shipped binary IS
    # the shipped table: it is compiled in, so there is no file to copy and
    # nothing outside the process that could mutate it (dotfiles-ylmp.16).
    DISPLAY=$D8 XDG_RUNTIME_DIR="$T8" setsid $HOTKEYD_BIN \
        --display "$D8" >"$T8/d.log" 2>&1 &
    sleep 2
    dpid="$(pgrep -f "$HOTKEYD_PROC_PAT .*--display $D8" | head -1)"
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
        then ok "launcher's pgrep pattern finds a hand-started daemon"
        else bad "launcher's pgrep pattern misses a hand-started daemon"
        fi

        # SIGHUP. The contract is that a SIGHUP which does NOT end up
        # installing a table leaves the daemon alive and SAYS SO in the log —
        # the failure it guards is a stock SIGHUP disposition, which terminates
        # the process and takes every grab down with it.
        #
        # The table is compiled in, so SIGHUP is a documented no-op that says as
        # much (cmd/hotkeyd/daemon.go sighupMessage). Nothing outside the
        # process can put a bad table in front of a running daemon, so there is
        # no broken-table-reload case to write here at all; the equivalent —
        # a bad table refused before any grab is taken — is the trap fixture
        # above, at build time rather than at signal time (dotfiles-ylmp.16).
        kill -HUP "$dpid" 2>/dev/null; sleep 1.5
        if kill -0 "$dpid" 2>/dev/null; then
            ok "survives SIGHUP (compiled-in table: nothing to re-read)"
        else
            bad "SIGHUP KILLED the daemon"
        fi
        if grep -qi "SIGHUP is a no-op" "$T8/d.log"; then
            ok "a SIGHUP that installs no table says so in the log"
        else
            bad "SIGHUP was silent — an operator expecting a reload gets no signal: $(tail -3 "$T8/d.log")"
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
# that rots is worse than nothing, because it is discovered exactly then.
#
# THIS STAGE ONLY GUARDS THAT IT PARSES, not what it says. Its CONTENT — that
# it is the daemon's chord set minus i3's own — was guarded by test_binds.py,
# which the python cutover deleted with the rest of that suite, and nothing in
# the Go tree replaced it (dotfiles-ylmp.16: an open gap, deliberately recorded
# here rather than papered over with a pointer to a file that no longer
# exists). internal/i3/client_test.go only asserts that the panic link is
# VISIBLE through the include glob, which is a different claim.
#
# What this half does prove is that the composed tree i3 will actually load,
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
    # cleans up with `pkill -f "hotkeyd .*--display :NN"` kills the other run's
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
        DISPLAY="$D11" XDG_RUNTIME_DIR="$T11" setsid $HOTKEYD_BIN \
            --display "$D11" >"$T11/d.log" 2>&1 &
        d11=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d11="$(pgrep -f "$HOTKEYD_PROC_PAT --display $D11" | head -1)"
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
    # No mods on the layer: the shape dotfiles-hwds.18 is about. Validation
    # allows it, so the passive mask variant is the only thing that can route
    # the exit key.
    cat > "$T12/plain.go" <<'EOF'
package main

import "hotkeyd/internal/bind"

func init() {
	Binds = []bind.Bind{
		{Chord: "$mod+o", Actions: []bind.Action{bind.EnterLayer{Layer: "plain"}}},
	}
	Layers = map[string]bind.Layer{
		"plain": {
			Binds:    []bind.Bind{{Chord: "h", Actions: cmdAction("focus left")}},
			ExitKeys: []string{"q"},
		},
	}
}
EOF
    Xvfb "$D12" -screen 0 640x480x24 >/dev/null 2>&1 &
    X12P=$!
    sleep 1.5
    if [ -z "$D12" ]; then
        bad "no free X display for the mods-less layer stage"
    else
        # HOTKEYD_I3SOCK points at nothing: there is no i3 on this display, and
        # this keeps the daemon from shelling out to `i3 --get-socketpath`.
        table_daemon "$T12/plain.go" "$T12" plain \
            || bad "no daemon could be produced for the mods-less table"
        DISPLAY="$D12" XDG_RUNTIME_DIR="$T12" HOTKEYD_I3SOCK="$T12/no-i3.sock" \
            setsid $TBL_BIN --display "$D12" >"$T12/d.log" 2>&1 &
        d12=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d12="$(pgrep -f "$HOTKEYD_PROC_PAT --display $D12" | head -1)"
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
# THE REFUSAL IS NOT EXERCISED HERE BY A REAL XI2-LESS SERVER, because there
# isn't one to be had: Xvfb answers `-extension XInputExtension` with "can not
# be disabled" (measured, dotfiles-ylmp.15), and the daemon deliberately offers
# no flag to disable XI2 — a production switch for that is exactly the
# silent-fallback door this check exists to keep shut. Until dotfiles-ylmp.16
# the python daemon got there through a sitecustomize shim that monkeypatched
# python-xlib inside the daemon's own interpreter; a compiled binary has no
# equivalent hook, and that daemon is gone.
#
# So the claim is carried by NAMED tests instead of a skip, and this stage's job
# is to prove those tests actually ran (below). What it still drives for real,
# with a REAL process and REAL argv against a REAL server, is the control case:
# the same daemon on the same display DOES start when XI2 is present.
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
    Xvfb "$D13" -screen 0 640x480x24 >/dev/null 2>&1 &
    X13P=$!
    sleep 1.5
    if [ -z "$D13" ]; then
        bad "no free X display for the XI2-absence stage"
    else
        # THE NAMED REPLACEMENT for the XI2-less server nobody can build:
        # requireXI2's error arms driven against a fake source, PLUS the
        # daemon-level fail-fast tests (cmd/hotkeyd/xi2_failfast_test.go),
        # which drive the real Dispatch()/run() against a FAKE X SERVER that
        # answers QueryExtension("XInputExtension") with present=0. That file
        # is where the whole claim lands: exit 5 by name, the message naming
        # XI2 and the extension, no stack trace, nothing left behind, and no
        # hang. It is sp021 Task 1's prescription for exactly this case, and it
        # is not a skip: it is a different, executed test.
        #
        # GATE ON POSITIVE EVIDENCE THAT THOSE TESTS RAN. `go test -run X`
        # prints "ok <pkg> 0.004s [no tests to run]" and exits 0 when X matches
        # NOTHING, so `rc -eq 0` plus a grep for 'ok ' proves only that the
        # package compiles: rename or delete these tests and the stage would
        # still print PASS while measuring nothing. That is the vacuity this
        # whole tree is written against (test-engine.sh's header — a stage that
        # does not exercise what it claims must FAIL), and a stage standing in
        # for a mechanism that cannot be built is the worst place in the repo
        # to put another instance of it (audit gap 1, dotfiles-ylmp.15). -v
        # makes every test announce itself by name; count the PASS lines and
        # require the full set.
        xout="$( go -C "$HERE" test ./cmd/hotkeyd -count=1 -v \
                 -run 'TestRequireXI2|TestRun_XI2' 2>&1 )"
        xrc=$?
        nhelper="$(printf '%s\n' "$xout" | grep -c -- '--- PASS: TestRequireXI2')"
        ndaemon="$(printf '%s\n' "$xout" | grep -c -- '--- PASS: TestRun_XI2')"
        if [ "$xrc" -eq 0 ] && [ "$nhelper" -ge 4 ] && [ "$ndaemon" -ge 3 ]; then
            ok "XI2 absence is refused by name — $nhelper requireXI2 arms \
and $ndaemon daemon-level fail-fast tests (fake XI2-less X server: exit 5 by \
name, no stack trace, nothing left behind) ran and passed"
        else
            bad "the named XI2-absence replacement did not run clean — \
rc=$xrc, $nhelper/4 '--- PASS: TestRequireXI2' lines, $ndaemon/3 \
'--- PASS: TestRun_XI2' lines: $xout"
        fi
        # THE CONTROL, and it is the reason this stage still needs a real X
        # server: the same binary on the SAME display, with XI2 present, must
        # start. Without it the gate above could pass over a daemon that is
        # simply broken.
        DISPLAY=$D13 XDG_RUNTIME_DIR="$T13" HOTKEYD_I3SOCK="$T13/no-i3.sock" \
            setsid $HOTKEYD_BIN --display "$D13" \
            >"$T13/d.log" 2>&1 &
        d13=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d13="$(pgrep -f "$HOTKEYD_PROC_PAT --display $D13" | head -1)"
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
               $HOTKEYD_BIN --health --display "$D14" 2>&1)"
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
               $HOTKEYD_BIN --health --display "$D14" 2>&1)"
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
        cat > "$T14/one.go" <<'EOF'
package main

import "hotkeyd/internal/bind"

func init() {
	Binds = []bind.Bind{{Chord: "$mod+F11", Actions: cmdAction("nop grabbed-stage")}}
	Layers = map[string]bind.Layer{}
}
EOF
        table_daemon "$T14/one.go" "$T14" one \
            || bad "no daemon could be produced for the one-bind table"
        rm -f "$T14/hotkeyd-${D14#:}.lock"
        DISPLAY=$D14 XDG_RUNTIME_DIR="$T14" HOTKEYD_I3SOCK="$T14/no-i3.sock" \
            $TBL_BIN --display "$D14" >"$T14/d.log" 2>&1 &
        D14P=$!
        d14=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d14="$(pgrep -f "$HOTKEYD_PROC_PAT --display $D14" | head -1)"
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
        cat > "$T15/whole.go" <<'EOF'
package main

import "hotkeyd/internal/bind"

func init() {
	Binds = []bind.Bind{{Chord: "$mod+F11", Actions: cmdAction("nop whole")}}
	Layers = map[string]bind.Layer{}
}
EOF
        table_daemon "$T15/whole.go" "$T15" whole \
            || bad "no daemon could be produced for the whole table"
        DISPLAY=$D15 XDG_RUNTIME_DIR="$T15" HOTKEYD_I3SOCK="$T15/no-i3.sock" \
            $TBL_BIN --display "$D15" >"$T15/whole.log" 2>&1 &
        W15P=$!
        w15=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            w15="$(pgrep -f "$HOTKEYD_PROC_PAT --display $D15" | head -1)"
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
            $TBL_BIN --display "$D15" >"$T15/holed.log" 2>&1 &
        H15P=$!
        h15=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            h15="$(pgrep -f "$HOTKEYD_PROC_PAT --display $D15" | head -1)"
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


# ============================================================================
# stage 16: an old daemon is UNDETERMINED, a beating one that stopped is WEDGED
# ============================================================================
#
# dotfiles-hwds.29. The heartbeat lives in the lock file's mtime, and a daemon
# running the PREVIOUS build never touches that file after creating it — so the
# day the heartbeat shipped, `status` read two live, demonstrably serving
# daemons' START times and called them wedged ("last heartbeat 2131s ago").
# Every upgrade would repeat it, on the tool an operator consults during an
# outage.
#
# Worse: the unmerged reap-on-stale change would have made `start` KILL both.
# So the two verdicts must not share an exit code, and this stage pins that they
# do not. No X server needed — the whole question is the lock file.
echo "stage 16: heartbeat absence is not staleness"
T16="$TMPD/t16"; mkdir -p "$T16"
D16=":76"

# An OLD daemon: pid only, no marker, mtime far in the past (which for it is
# simply uptime).
printf '12345\n' > "$T16/hotkeyd-76.lock"
touch -d '2 hours ago' "$T16/hotkeyd-76.lock"
out="$(XDG_RUNTIME_DIR="$T16" timeout 20 \
       $HOTKEYD_BIN --health --display "$D16" 2>&1)"
rc=$?
if [ "$rc" -eq 10 ]; then
    ok "an unmarked lock is UNDETERMINED (exit 10)"
else
    bad "an unmarked lock returned $rc: $out"
fi
if [ "$rc" -eq 6 ]; then
    bad "…and it collected the REAPABLE verdict, which is the hwds.29 footgun"
fi
case "$out" in
    *UNDETERMINED*) ok "the message says UNDETERMINED" ;;
    *) bad "message did not say UNDETERMINED: $out" ;;
esac
case "$out" in
    *restart*) ok "and says how to get a definite answer" ;;
    *) bad "message offers no way forward: $out" ;;
esac

# A CURRENT daemon that actually stopped beating. The marker must not become a
# blanket amnesty — this is the case the heartbeat exists for.
printf '12345\nheartbeat=1\n' > "$T16/hotkeyd-76.lock"
touch -d '2 hours ago' "$T16/hotkeyd-76.lock"
out="$(XDG_RUNTIME_DIR="$T16" timeout 20 \
       $HOTKEYD_BIN --health --display "$D16" 2>&1)"
rc=$?
if [ "$rc" -eq 6 ]; then
    ok "a MARKED lock gone stale is still NOT SERVING (exit 6)"
else
    bad "a marked, stale lock returned $rc: $out"
fi

# And the marker is what the real daemon writes — not a constant that only the
# tests agree on. Re-pointed at the Go source at dotfiles-ylmp.16: the string
# lives in internal/proc/lock.go as `LockMarker`, which AcquireLock writes as
# line 2 of the lock file. The grep asks for the DECLARATION, not a bare
# occurrence, so a comment mentioning the old spelling cannot keep this green
# after the constant itself is renamed or its value changed.
printf '  ' >/dev/null
if grep -q 'LockMarker = "heartbeat=1"' "$HERE/internal/proc/lock.go"; then
    ok "the marker string is in the daemon, not only in the suite"
else
    bad "no 'LockMarker = \"heartbeat=1\"' in internal/proc/lock.go — the stage \
is testing a fiction"
fi


# ============================================================================
# stage 17: a daemon dying inside a hold layer hands the overlay back
# ============================================================================
#
# dotfiles-hwds.51, and specifically the WIRING rather than the method. The unit
# tests assert that the layer engine's ShutdownActions() returns the active
# layer's on_exit (internal/layer/engine.go); they cannot see whether the
# daemon's shutdown path actually DISPATCHES what it is handed
# (cmd/hotkeyd/daemon.go, the `for _, a := range d.engine.ShutdownActions()`
# loop), and a mutation that emptied that loop left them all green. This stage
# closes that: a real daemon, a real hold layer, a real SIGTERM.
#
# The on_exit action is a `touch` rather than the shipped switcher-cancel, so
# the assertion is a file on disk instead of an X window nobody is looking at.
echo "stage 17: shutdown inside a layer runs on_exit"
if ! command -v Xvfb >/dev/null || ! command -v xdotool >/dev/null; then
    printf '  \033[33mSKIP\033[0m Xvfb or xdotool missing\n'
else
    D17=""
    _b=$(( 40 + (($$ + 17) % 20) ))
    for _o in 0 1 2 3 4 5 6 7 8 9; do
        _n=$(( _b + _o ))
        [ -e "/tmp/.X${_n}-lock" ] || { D17=":$_n"; break; }
    done
    T17="$TMPD/t17"; mkdir -p "$T17"
    if [ -z "$D17" ]; then
        bad "no free X display for the shutdown stage"
    else
        Xvfb "$D17" -screen 0 640x480x24 >/dev/null 2>&1 &
        X17P=$!
        sleep 1.5
        MARK="$T17/on-exit-ran"
        cat > "$T17/hold.go" <<EOF
package main

import "hotkeyd/internal/bind"

func init() {
	Binds = []bind.Bind{{Chord: "Mod4+Tab", Actions: []bind.Action{
		bind.Run{Cmd: "true"}, bind.EnterLayer{Layer: "sw"}}}}
	Layers = map[string]bind.Layer{
		"sw": {
			Binds:         []bind.Bind{{Chord: "Tab", Actions: []bind.Action{bind.Run{Cmd: "true"}}}},
			ExitKeys:      []string{"q"},
			Hold:          "Mod4",
			OnHoldRelease: []bind.Action{bind.Run{Cmd: "true"}},
			OnExit:        []bind.Action{bind.Run{Cmd: "touch $MARK"}},
		},
	}
}
EOF
        table_daemon "$T17/hold.go" "$T17" hold \
            || bad "no daemon could be produced for the hold-layer table"
        DISPLAY=$D17 XDG_RUNTIME_DIR="$T17" HOTKEYD_I3SOCK="$T17/no-i3.sock" \
            $TBL_BIN --display "$D17" >"$T17/d.log" 2>&1 &
        d17=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d17="$(pgrep -f "$HOTKEYD_PROC_PAT --display $D17" | head -1)"
            [ -n "$d17" ] && break
        done
        if [ -z "$d17" ]; then
            bad "the daemon did not start: $(tail -3 "$T17/d.log")"
        else
            # Enter the layer and KEEP the modifier down, so the daemon is
            # inside it when the signal arrives — the restart-mid-gesture shape.
            DISPLAY=$D17 xdotool keydown super 2>/dev/null
            DISPLAY=$D17 xdotool key Tab 2>/dev/null
            sleep 1
            if grep -q "layer=default->sw" "$T17/d.log"; then
                ok "the daemon is inside the hold layer"
            else
                bad "never entered the layer — the stage proves nothing: $(tail -3 "$T17/d.log")"
            fi
            [ -e "$MARK" ] && bad "on_exit ran while the layer was still up"

            kill -TERM "$d17" 2>/dev/null
            _ran=""
            for _t in 1 2 3 4 5 6 7 8 9 10; do
                sleep 0.5
                [ -e "$MARK" ] && { _ran=1; break; }
            done
            if [ -n "$_ran" ]; then
                ok "SIGTERM inside the layer dispatched on_exit"
            else
                bad "the daemon exited without handing the overlay back"
            fi
            DISPLAY=$D17 xdotool keyup super 2>/dev/null
        fi

        # CONTROL: stopped while NOT in a layer, nothing must fire.
        rm -f "$MARK"
        DISPLAY=$D17 XDG_RUNTIME_DIR="$T17" HOTKEYD_I3SOCK="$T17/no-i3.sock" \
            $TBL_BIN --display "$D17" >"$T17/d2.log" 2>&1 &
        d17b=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d17b="$(pgrep -f "$HOTKEYD_PROC_PAT --display $D17" | head -1)"
            [ -n "$d17b" ] && break
        done
        if [ -n "$d17b" ]; then
            kill -TERM "$d17b" 2>/dev/null
            sleep 2
            if [ -e "$MARK" ]; then
                bad "on_exit fired for a daemon that was never in a layer"
            else
                ok "control: stopping an idle daemon dispatches nothing"
            fi
        else
            bad "the control daemon did not start"
        fi
        kill "$X17P" 2>/dev/null
    fi
fi

# ============================================================================
# stage 18: set-layer round trip (screenshot-drag -> state feed -> default)
# ============================================================================
#
# sp023 Task 4 (bd dotfiles-1m4t.4): the CLIENT-side `set-layer` verb, driven
# for real against a daemon carrying an External-declared layer. config.go's
# shipped table only gets its own "screenshot-drag": {External: true} entry
# at Task 5's cutover, so this stage builds its own tiny fixture table via
# table_daemon(), the same seam stage 12/14/17 already use, rather than
# waiting on that later task.
#
# The claim under test: `set-layer screenshot-drag` enters the layer over the
# NEW control socket (control.go, Task 3) with no chord and no i3 involved at
# all (HOTKEYD_I3SOCK points at nothing, matching stage 12's mods-less-layer
# stage); a FRESH `state-tail` client's FIRST line is the replay of that
# state (ft009's replay-on-connect contract, exercised here at the CLI);
# `set-layer default` clears it the same way, and the feed reflects that too.
# Every state-tail read is wrapped in `timeout`: state-tail blocks in Read()
# forever on an otherwise-quiet socket once it has its one line, and this
# stage only ever wants that first line per fresh connection.
echo "stage 18: set-layer round trip (screenshot-drag -> state feed -> default)"
if ! command -v Xvfb >/dev/null; then
    printf '  \033[33mSKIP\033[0m Xvfb missing\n'
else
    D18=""
    _b=$(( 40 + (($$ + 18) % 20) ))
    for _o in 0 1 2 3 4 5 6 7 8 9; do
        _n=$(( _b + _o ))
        [ -e "/tmp/.X${_n}-lock" ] || { D18=":$_n"; break; }
    done
    T18="$TMPD/t18"; mkdir -p "$T18"
    if [ -z "$D18" ]; then
        bad "no free X display for the set-layer stage"
    else
        # A signal-only external layer and NOTHING else -- no Binds, no
        # chords, matching plan decision 1 (Task 1/2's own fixtures).
        cat > "$T18/extern.go" <<'EOF'
package main

import "hotkeyd/internal/bind"

func init() {
	Binds = nil
	Layers = map[string]bind.Layer{
		"screenshot-drag": {External: true},
	}
}
EOF
        Xvfb "$D18" -screen 0 640x480x24 >/dev/null 2>&1 &
        X18P=$!
        sleep 1.5
        table_daemon "$T18/extern.go" "$T18" extern \
            || bad "no daemon could be produced for the external-layer table"
        # HOTKEYD_I3SOCK points at nothing: no i3 on this display, and this
        # stage's whole point is that set-layer needs none (plan decision 4
        # only matters once i3 IS in a mode, which this stage does not
        # exercise -- stage 11 already covers that arbitration).
        DISPLAY="$D18" XDG_RUNTIME_DIR="$T18" HOTKEYD_I3SOCK="$T18/no-i3.sock" \
            setsid $TBL_BIN --display "$D18" >"$T18/d.log" 2>&1 &
        D18P=$!
        d18=""
        for _t in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            d18="$(pgrep -f "$HOTKEYD_PROC_PAT --display $D18" | head -1)"
            [ -n "$d18" ] && break
        done
        if [ -z "$d18" ]; then
            bad "the external-layer daemon did not start: $(tail -3 "$T18/d.log")"
        else
            out="$(XDG_RUNTIME_DIR="$T18" $TBL_BIN set-layer screenshot-drag --display "$D18" 2>&1)"
            src=$?
            if [ "$src" -eq 0 ]; then
                ok "set-layer screenshot-drag exits 0"
            else
                bad "set-layer screenshot-drag failed (rc=$src): $out"
            fi

            l18="$(XDG_RUNTIME_DIR="$T18" timeout 5 $TBL_BIN state-tail "$D18" 2>/dev/null | head -1)"
            if [ "$l18" = '{"layer":"screenshot-drag","mod":null}' ]; then
                ok "a fresh state-tail client's FIRST line replays screenshot-drag"
            else
                bad "state-tail first line was: ${l18:-<empty>} (daemon log: $(tail -3 "$T18/d.log"))"
            fi

            out2="$(XDG_RUNTIME_DIR="$T18" $TBL_BIN set-layer default --display "$D18" 2>&1)"
            src2=$?
            if [ "$src2" -eq 0 ]; then
                ok "set-layer default exits 0"
            else
                bad "set-layer default failed (rc=$src2): $out2"
            fi

            l18b="$(XDG_RUNTIME_DIR="$T18" timeout 5 $TBL_BIN state-tail "$D18" 2>/dev/null | head -1)"
            if [ "$l18b" = '{"layer":"default","mod":null}' ]; then
                ok "the feed returns default after set-layer default"
            else
                bad "state-tail first line after clear was: ${l18b:-<empty>}"
            fi

            # Client-side pre-validation (us019 AC4 / adr0021), proven
            # end to end against the SAME live daemon: an undeclared name
            # is refused BY NAME without ever touching the control socket.
            out3="$(XDG_RUNTIME_DIR="$T18" $TBL_BIN set-layer not-a-real-layer --display "$D18" 2>&1)"
            src3=$?
            if [ "$src3" -eq 1 ]; then
                ok "an undeclared name is refused (exit 1), not attempted"
            else
                bad "set-layer not-a-real-layer returned $src3, want 1: $out3"
            fi
            case "$out3" in
                *"not-a-real-layer"*) ok "the refusal names the offending layer" ;;
                *) bad "the refusal did not name the layer: $out3" ;;
            esac

            kill "$d18" 2>/dev/null
        fi
        kill "$D18P" 2>/dev/null
        kill "$X18P" 2>/dev/null
    fi
fi

echo
printf 'hotkeyd: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
