#!/usr/bin/env bash
# test-mixed-estate.sh — the MULTI-DISPLAY ESTATE: two X sessions, two daemons,
# one launcher, and the machine-wide panic sweep that has to find both
# (sp021 dotfiles-ylmp.15, re-scoped at dotfiles-ylmp.16).
#
# WAS THE MIXED ESTATE. Until dotfiles-ylmp.16 this file ran PYTHON on one
# display and GO on the other at the same time, to prove the epic's rollout
# window was survivable. That window is closed — python is deleted and every
# display resolves to the Go binary — so the two-ENGINE premise is gone.
#
# WHAT SURVIVES IT, AND WHY THIS FILE STILL EXISTS. Every machine-wide
# behaviour it was written to check is per-DISPLAY, not per-engine, and none of
# it is covered elsewhere against real daemons on two real displays:
#
#   - `hotkeyd-panic.sh panic` enumerates displays and sweeps by pgrep. It must
#     stop the daemon on a display it was NOT called with — the failure that
#     leaves one session latched behind i3's fallback while another still holds
#     grabs. test-panic.sh covers the sweep's pattern against a MOCKED process
#     table; this covers it against real daemons the launcher actually started.
#   - `hotkeyd.sh start` must refuse behind the panic latch on BOTH, or an i3
#     `exec_always` rearms one display behind i3's fallback binds.
#   - `hotkeyd-panic.sh resume` must bring BOTH back, per display, rather than
#     restoring only the one panic happened to be invoked from.
#   - `check --ownership` must answer about the display it is pointed at, on
#     each of two live i3s — with a seeded collision proving it can say no.
#
# THE CUTOVER REHEARSAL IS GONE WITH THE ENGINE TABLE. This used to run a COPY
# of hotkeyd.sh with one extra `:N) printf 'go' ;;` arm awk'd into engine_for(),
# rehearsing the very edit ylmp.15 and .16 would make. There is no engine_for()
# to patch any more, so the suite drives the SHIPPED launcher directly — which
# is strictly better evidence, since it is now the real thing under test rather
# than a patched copy of it.
#
# engine_on() below still distinguishes python from go by argv, and that is
# deliberate, not leftover: its job now is to prove a python daemon NEVER
# appears. hotkeyd.sh's daemon_pid() still matches the python argv shape (for
# leftover pre-cutover daemons), so "go" here is a measured answer, not a
# foregone one.
#
# Bash rather than nushell per adr0002 condition 1, same as the other suites.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_BIN="${HOTKEYD_GO_BIN:-$HERE/hotkeyd}"

PASS=0
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Same reason as test-panic.sh: an inherited I3SOCK would point every i3-msg
# here at the caller's own live session.
unset I3SOCK

if ! command -v Xvfb >/dev/null || ! command -v i3 >/dev/null; then
    echo "mixed-estate suite: Xvfb or i3 missing — skipped"
    exit 0
fi
if [ ! -x "$GO_BIN" ]; then
    echo "mixed-estate suite: no go daemon at $GO_BIN — build it with" \
         "'go build -o hotkeyd ./cmd/hotkeyd' (this suite exists to compare" \
         "the two engines; with one missing it would measure nothing)"
    exit 1
fi

T="$(mktemp -d)"
XVFB_PIDS=()
I3_PIDS=()

probe_free_display() { # <start-number>
    local n="$1"
    while [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X${n}-lock" ]; do
        n=$((n + 1))
    done
    printf ':%s' "$n"
}

# BOTH argv shapes, the same pattern hotkeyd-panic.sh's own sweep uses
# (dotfiles-pwaj). A pattern that saw only one engine would make every
# "stopped" assertion below true for the wrong reason.
#
# daemons_on() is deliberately ENGINE-BLIND — it counts daemons of either
# shape, which is what the "how many are running" questions need. It is
# therefore NOT sufficient on its own for any assertion whose LABEL names an
# engine: "panic stopped the go daemon on :98" read through daemons_on()
# alone passes just as happily when :98 is served by something else, so a
# broken resolution would be reported as a working one (audit gap 3,
# dotfiles-ylmp.15 — measured: it understated the mutation's blast radius by
# more than 3x). Every assertion below that claims WHICH daemon is serving
# pairs the count with engine_on().
PAT='hotkeyd(\.py)?'
daemons_on() { pgrep -f "$PAT .*--display $1" 2>/dev/null | wc -l; }
engine_on()  { # <display> -> python|go|none
    local a
    a="$(pgrep -af "$PAT .*--display $1" 2>/dev/null | head -1)"
    case "$a" in
        "")           printf 'none' ;;
        *hotkeyd.py*) printf 'python' ;;
        *)            printf 'go' ;;
    esac
}

cleanup() {
    pkill -f "$PAT .*--display ${XA:-:99999}" 2>/dev/null
    pkill -f "$PAT .*--display ${XB:-:99999}" 2>/dev/null
    for p in "${I3_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    for p in "${XVFB_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    rm -rf "$T"
}

# >= :85 by default: sibling agent worktrees have been observed using :61-:73
# and the other suites probe from :71 and :81. probe_free_display still walks
# forward from here, so a collision costs a display number, not a run.
XA="$(probe_free_display "${HOTKEYD_ESTATE_BASE:-85}")"
XB="$(probe_free_display "$(( ${XA#:} + 1 ))")"
trap cleanup EXIT

# --- the sandbox, identical in shape to test-panic.sh's --------------------
# Files: a throwaway HOME for the panic link, a fallback source that actually
# binds something, and a display-enumeration directory naming ONLY these two
# displays so `resume`'s machine-wide reload cannot reach the caller's live
# sessions. Processes: HOTKEYD_PGREP_SCOPE FILTERS panic's machine-wide
# enumeration down to these two, so the sweep still has to DISCOVER them.
export HOME="$T/home"
export XDG_RUNTIME_DIR="$T/run"
export HOTKEYD_I3_CONFIG_D="$HOME/.i3/config.d"
export HOTKEYD_FALLBACK_SRC="$T/zz-fallback-binds.conf"
mkdir -p "$HOTKEYD_I3_CONFIG_D" "$XDG_RUNTIME_DIR"
LINK="$HOTKEYD_I3_CONFIG_D/zz-fallback-binds.conf"
printf 'bindsym Mod4+F10 workspace i3-owns-it\n' > "$HOTKEYD_FALLBACK_SRC"

export HOTKEYD_X11_UNIX="$T/x11-unix"
mkdir -p "$HOTKEYD_X11_UNIX"
: > "$HOTKEYD_X11_UNIX/X${XA#:}"
: > "$HOTKEYD_X11_UNIX/X${XB#:}"
export HOTKEYD_PGREP_SCOPE="$XA $XB"

# --- the launcher under test ------------------------------------------------
# The SHIPPED hotkeyd.sh, reached through a directory of symlinks rather than
# directly. Two reasons the indirection stays now that there is no engine table
# to patch (dotfiles-ylmp.16):
#   - hotkeyd-panic.sh resolves its launcher as "$(dirname $0)/hotkeyd.sh", so
#     panic and resume must find the same launcher this suite drives;
#   - the symlinked directory resolves $HERE to itself, so the copy finds the
#     real daemon binary and the real cmd/ tree (staleness_check reads it).
# Nothing is rewritten: what runs here is the launcher that ships.
mkdir -p "$T/lnk"
for f in "$HERE"/*; do
    ln -sfn "$f" "$T/lnk/$(basename "$f")"
done
LAUNCHER="$T/lnk/hotkeyd.sh"
# hotkeyd-panic.sh resolves its launcher as "$(dirname $0)/hotkeyd.sh", so
# invoking it through the symlink beside the patched copy makes panic/resume
# drive the PATCHED table -- which is the point: resume has to re-read the
# per-display arm, not remember what it stopped.
PANIC="$T/lnk/hotkeyd-panic.sh"

echo "estate: two displays ($XA, $XB), one launcher, one engine"
# Prove the launcher resolves BEFORE anything is started. `check` resolves the
# same binary `start` would and execs its --check, so a non-zero here means the
# rest of the run would be testing nothing. Both displays must resolve to the
# SAME daemon and it must validate — the inverse of what this asserted before
# dotfiles-ylmp.16, when the whole point was that they resolved differently.
ack="$(sh "$LAUNCHER" check "$XA" 2>&1)"; arc=$?
bck="$(sh "$LAUNCHER" check "$XB" 2>&1)"; brc=$?
[ "$arc" -eq 0 ] && [ "$brc" -eq 0 ] && [ "$ack" = "$bck" ] \
    && ok "both displays resolve to the SAME validated daemon (one engine, \
no per-display table)" \
    || bad "$XA -> exit $arc '$ack'; $XB -> exit $brc '$bck'; want both exit 0 \
and identical"

for dpy in "$XA" "$XB"; do
    Xvfb "$dpy" -screen 0 640x480x24 >/dev/null 2>&1 &
    XVFB_PIDS+=($!)
done
sleep 1.5
cat > "$T/i3.conf" <<EOF
font pango:monospace 10
include $HOTKEYD_I3_CONFIG_D/*.conf
bindsym Mod4+Shift+r exec --no-startup-id $HERE/hotkeyd-panic.sh panic
EOF
for dpy in "$XA" "$XB"; do
    DISPLAY="$dpy" i3 -c "$T/i3.conf" >/dev/null 2>&1 &
    I3_PIDS+=($!)
done
sleep 1.5
for dpy in "$XA" "$XB"; do
    DISPLAY="$dpy" i3-msg -t get_version >/dev/null 2>&1 \
        || bad "setup: i3 did not start on $dpy"
done

# --- 1: both engines live, at the same time, from one table -----------------
DISPLAY="$XA" sh "$LAUNCHER" start "$XA" >/dev/null 2>&1
DISPLAY="$XB" sh "$LAUNCHER" start "$XB" >/dev/null 2>&1
sleep 1
# MEASURED, not assumed: engine_on() reads each daemon's own argv through the
# same dual-shape match hotkeyd.sh uses, so a python daemon WOULD be reported
# as python if one somehow appeared. "go" here is evidence that the estate is
# uniform, which is exactly what dotfiles-ylmp.16 claims.
[ "$(engine_on "$XA")" = go ] \
    && ok "$XA is served by the GO daemon" \
    || bad "setup: $XA is served by $(engine_on "$XA"), want go"
[ "$(engine_on "$XB")" = go ] \
    && ok "$XB is served by the GO daemon" \
    || bad "setup: $XB is served by $(engine_on "$XB"), want go"

# --- 2: check --ownership sees no BOTH row on either display ----------------
# Go-only: `check --ownership` is an sp021 capability with no hotkeyd.py
# counterpart. It reads i3's LOADED config over IPC and the compiled table, so
# it answers about whichever display it is pointed at regardless of which
# engine serves it.
echo "estate: chord ownership"
for dpy in "$XA" "$XB"; do
    oout="$(DISPLAY="$dpy" "$GO_BIN" check --ownership --display "$dpy" 2>&1)"
    orc=$?
    if [ "$orc" -ne 0 ]; then
        bad "check --ownership on $dpy exited $orc: $oout"
    elif printf '%s' "$oout" | grep -q 'BOTH'; then
        bad "check --ownership reports a BOTH row on $dpy: $(printf '%s' "$oout" | grep BOTH)"
    else
        ok "no chord is owned by BOTH i3 and the daemon on $dpy"
    fi
done

# GUARD ON THE GUARD. "No BOTH row" against an i3 that binds almost nothing is
# very nearly a tautology — and a tautology is exactly what a cutover gate
# must not accept as evidence. Seed a chord the DAEMON'S OWN compiled table
# holds ($mod+h, the global focus-left bind), reload i3 for real, and require
# the check to see the collision and exit non-zero. Then take the seed away
# and require it to come back clean, so the rest of the run continues from a
# state that was demonstrated, not assumed.
SEED="$HOTKEYD_I3_CONFIG_D/zz-ownership-seed.conf"
printf 'bindsym Mod4+h nop ownership-seed\n' > "$SEED"
DISPLAY="$XB" i3-msg reload >/dev/null 2>&1
sout="$(DISPLAY="$XB" "$GO_BIN" check --ownership --display "$XB" 2>&1)"; src=$?
if [ "$src" -ne 0 ] && printf '%s' "$sout" | grep -q 'BOTH'; then
    ok "a chord i3 and the daemon BOTH hold IS reported (exit $src) — the check above can fail"
else
    bad "check --ownership exited $src and saw no BOTH row for a seeded \
collision — every 'no BOTH' verdict here proves nothing: $sout"
fi
rm -f "$SEED"
DISPLAY="$XB" i3-msg reload >/dev/null 2>&1
sout="$(DISPLAY="$XB" "$GO_BIN" check --ownership --display "$XB" 2>&1)"; src=$?
[ "$src" -eq 0 ] \
    && ok "and clean again once the seed is removed" \
    || bad "check --ownership still non-zero ($src) after the seed was removed: $sout"

# --- 3: panic stops EVERY display's daemon ----------------------------------
# The counts are read BEFORE as well as after (dotfiles-ptd2): a "0 daemons"
# claim read through a pattern that was never shown live is a tautology.
# The ENGINE is read before as well, for the reason daemons_on()'s comment
# gives: these assertions say WHICH daemon was stopped out loud, so each has
# to have looked rather than assumed the estate is uniform.
echo "estate: panic sweeps every display, not just the one it was called with"
before_a="$(daemons_on "$XA")"; before_a_eng="$(engine_on "$XA")"
before_b="$(daemons_on "$XB")"; before_b_eng="$(engine_on "$XB")"
DISPLAY="$XA" sh "$PANIC" panic >/dev/null 2>&1
sleep 1
[ "$before_a" = 1 ] && [ "$before_a_eng" = go ] \
    && [ "$(daemons_on "$XA")" = 0 ] \
    && ok "panic stopped the daemon on $XA, the display it WAS called with (1 -> 0)" \
    || bad "daemon on $XA: $before_a $before_a_eng -> $(daemons_on "$XA") \
$(engine_on "$XA"), want 1 go -> 0 none"
# THE ONE THAT MATTERS. A panic that only reached its own display would leave
# $XB holding grabs while i3 serves the fallback on $XA — two X clients, one
# keyboard, which is the state the whole panic design exists to prevent.
[ "$before_b" = 1 ] && [ "$before_b_eng" = go ] \
    && [ "$(daemons_on "$XB")" = 0 ] \
    && ok "panic stopped the daemon on $XB too, a display it was NOT called with \
(1 -> 0)" \
    || bad "daemon on $XB: $before_b $before_b_eng -> $(daemons_on "$XB") \
$(engine_on "$XB"), want 1 go -> 0 none"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
    ok "the fallback is linked at $LINK"
else
    bad "panic did not link the fallback"
fi

# --- 4: start refuses behind the latch, for BOTH engines --------------------
echo "estate: start refuses behind the latch"
for dpy in "$XA" "$XB"; do
    sout="$(DISPLAY="$dpy" sh "$LAUNCHER" start "$dpy" 2>&1)"; src=$?
    if [ "$src" -eq 4 ] && [ "$(daemons_on "$dpy")" = 0 ]; then
        ok "start on $dpy refused with exit 4 and spawned nothing"
    else
        bad "start on $dpy exited $src leaving $(daemons_on "$dpy") daemon(s): $sout"
    fi
done

# --- 5: resume restores EVERY display, not just one -------------------------
# resume re-enters the launcher per display. Asserting on BOTH is what catches
# a resume that restored only the display it was invoked from and left the
# other one dead — a half-resumed estate reads as "recovered" to whoever ran
# the command and as "no keybindings at all" to whoever is sitting at the
# other session.
echo "estate: resume restores every display"
DISPLAY="$XA" sh "$PANIC" resume >/dev/null 2>&1
sleep 1
[ "$(engine_on "$XA")" = go ] \
    && ok "$XA came back after resume" \
    || bad "$XA came back as $(engine_on "$XA") after resume, want go"
[ "$(engine_on "$XB")" = go ] \
    && ok "$XB came back after resume too, a display resume was not invoked from" \
    || bad "$XB came back as $(engine_on "$XB") after resume, want go"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
    bad "resume left the fallback linked at $LINK"
else
    ok "resume unlinked the fallback"
fi

DISPLAY="$XA" sh "$LAUNCHER" stop "$XA" >/dev/null 2>&1
DISPLAY="$XB" sh "$LAUNCHER" stop "$XB" >/dev/null 2>&1
sleep 0.5
[ "$(daemons_on "$XA")" = 0 ] && [ "$(daemons_on "$XB")" = 0 ] \
    && ok "both displays are clean at the end of the run" \
    || bad "strays left: $(daemons_on "$XA") on $XA, $(daemons_on "$XB") on $XB"

printf '\nmulti-display estate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
