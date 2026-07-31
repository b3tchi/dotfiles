#!/usr/bin/env bash
# test-mixed-estate.sh — the MIXED ESTATE: python serving one display and go
# serving another, at the same time, from ONE launcher table (sp021
# dotfiles-ylmp.15).
#
# WHY THIS IS ITS OWN FILE. test-hotkeyd.sh / test-launcher.sh / test-panic.sh
# each run ONE engine per run: HOTKEYD_ENGINE_DEFAULT is a single value and
# every display in the run gets it. That is exactly the shape the estate will
# NOT be in during the epic's rollout window — dotfiles-ylmp.15 puts go on :10
# while python keeps :0, and dotfiles-ylmp.16 finishes the job later. Every
# machine-wide behaviour in this tree has to survive that window:
#
#   - `hotkeyd-panic.sh panic` sweeps by pgrep over BOTH argv shapes
#     (dotfiles-pwaj) and must stop BOTH daemons, not just the ones whose
#     spelling it happened to be written for;
#   - `hotkeyd.sh start` must refuse behind the panic latch on BOTH, or an
#     i3 `exec_always` rearms one engine behind i3's fallback binds;
#   - `hotkeyd-panic.sh resume` must bring BOTH back, each as the engine its
#     display's table entry names — not both as whichever one ran last.
#
# HOW THE MIXED ESTATE IS BUILT. Not by hand-starting two daemons: that would
# prove the pgrep sweep works and nothing about the launcher, which is where
# the cutover actually happens. Instead this rehearses the cutover edit
# itself — a COPY of hotkeyd.sh with one extra `:N) printf 'go' ;;` arm in
# engine_for(), the same one line dotfiles-ylmp.15 will add for :10 and
# dotfiles-ylmp.16 for :0, pointed at a throwaway display. The shipped
# hotkeyd.sh is never modified and the live estate is never touched.
#
# Bash rather than nushell per adr0002 condition 1, same as the other suites.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_BIN="${HOTKEYD_GO_BIN:-$HERE/hotkeyd}"

PASS=0
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

export PYTHONDONTWRITEBYTECODE=1

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
# alone passes just as happily when :98 is served by python, so a broken
# cutover arm would be reported as a working one (audit gap 3,
# dotfiles-ylmp.15 — measured: it understated the mutation's blast radius by
# more than 3x). Every engine-named assertion below pairs the count with
# engine_on().
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
    pkill -f "$PAT .*--display ${XPY:-:99999}" 2>/dev/null
    pkill -f "$PAT .*--display ${XGO:-:99999}" 2>/dev/null
    for p in "${I3_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    for p in "${XVFB_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    rm -rf "$T"
}

# >= :85 by default: sibling agent worktrees have been observed using :61-:73
# and the other suites probe from :71 and :81. probe_free_display still walks
# forward from here, so a collision costs a display number, not a run.
XPY="$(probe_free_display "${HOTKEYD_MIXED_BASE:-85}")"
XGO="$(probe_free_display "$(( ${XPY#:} + 1 ))")"
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
: > "$HOTKEYD_X11_UNIX/X${XPY#:}"
: > "$HOTKEYD_X11_UNIX/X${XGO#:}"
export HOTKEYD_PGREP_SCOPE="$XPY $XGO"

# --- the cutover rehearsal --------------------------------------------------
# A copy of the shipped launcher whose engine_for() carries ONE extra arm.
# Every other file it needs is symlinked beside it, so the copy resolves
# $HERE to this directory and finds the real daemons, the real bind table and
# the real cmd/ tree (staleness_check reads it).
mkdir -p "$T/lnk"
for f in "$HERE"/*; do
    ln -sfn "$f" "$T/lnk/$(basename "$f")"
done
rm -f "$T/lnk/hotkeyd.sh"
awk -v dpy="$XGO" '
    { print }
    /^engine_for\(\) \{/ { getline; print; print "        " dpy ") printf '"'"'go'"'"' ;;" }
' "$HERE/hotkeyd.sh" > "$T/lnk/hotkeyd.sh"
chmod +x "$T/lnk/hotkeyd.sh"
LAUNCHER="$T/lnk/hotkeyd.sh"
# hotkeyd-panic.sh resolves its launcher as "$(dirname $0)/hotkeyd.sh", so
# invoking it through the symlink beside the patched copy makes panic/resume
# drive the PATCHED table -- which is the point: resume has to re-read the
# per-display arm, not remember what it stopped.
PANIC="$T/lnk/hotkeyd-panic.sh"

echo "mixed estate: python on $XPY, go on $XGO, one launcher table"
# Prove the patched table BEFORE anything is started. `check` resolves the
# same engine_for() `start` does and execs that binary's --check; the go
# daemon's own --check line names the compiled-in table, python's does not.
pyck="$(sh "$LAUNCHER" check "$XPY" 2>&1)"
gock="$(sh "$LAUNCHER" check "$XGO" 2>&1)"
[ "$pyck" != "$gock" ] \
    && ok "the launcher table resolves $XPY and $XGO to DIFFERENT binaries" \
    || bad "both displays resolved to the same binary — the cutover arm did \
not take, and everything below would test one engine twice: $pyck"

for dpy in "$XPY" "$XGO"; do
    Xvfb "$dpy" -screen 0 640x480x24 >/dev/null 2>&1 &
    XVFB_PIDS+=($!)
done
sleep 1.5
cat > "$T/i3.conf" <<EOF
font pango:monospace 10
include $HOTKEYD_I3_CONFIG_D/*.conf
bindsym Mod4+Shift+r exec --no-startup-id $HERE/hotkeyd-panic.sh panic
EOF
for dpy in "$XPY" "$XGO"; do
    DISPLAY="$dpy" i3 -c "$T/i3.conf" >/dev/null 2>&1 &
    I3_PIDS+=($!)
done
sleep 1.5
for dpy in "$XPY" "$XGO"; do
    DISPLAY="$dpy" i3-msg -t get_version >/dev/null 2>&1 \
        || bad "setup: i3 did not start on $dpy"
done

# --- 1: both engines live, at the same time, from one table -----------------
DISPLAY="$XPY" sh "$LAUNCHER" start "$XPY" >/dev/null 2>&1
DISPLAY="$XGO" sh "$LAUNCHER" start "$XGO" >/dev/null 2>&1
sleep 1
[ "$(engine_on "$XPY")" = python ] \
    && ok "$XPY is served by the PYTHON daemon" \
    || bad "setup: $XPY is served by $(engine_on "$XPY"), want python"
[ "$(engine_on "$XGO")" = go ] \
    && ok "$XGO is served by the GO daemon" \
    || bad "setup: $XGO is served by $(engine_on "$XGO"), want go"

# --- 2: check --ownership sees no BOTH row on either display ----------------
# Go-only: `check --ownership` is an sp021 capability with no hotkeyd.py
# counterpart. It reads i3's LOADED config over IPC and the compiled table, so
# it answers about whichever display it is pointed at regardless of which
# engine serves it.
echo "mixed estate: chord ownership"
for dpy in "$XPY" "$XGO"; do
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
DISPLAY="$XGO" i3-msg reload >/dev/null 2>&1
sout="$(DISPLAY="$XGO" "$GO_BIN" check --ownership --display "$XGO" 2>&1)"; src=$?
if [ "$src" -ne 0 ] && printf '%s' "$sout" | grep -q 'BOTH'; then
    ok "a chord i3 and the daemon BOTH hold IS reported (exit $src) — the check above can fail"
else
    bad "check --ownership exited $src and saw no BOTH row for a seeded \
collision — every 'no BOTH' verdict here proves nothing: $sout"
fi
rm -f "$SEED"
DISPLAY="$XGO" i3-msg reload >/dev/null 2>&1
sout="$(DISPLAY="$XGO" "$GO_BIN" check --ownership --display "$XGO" 2>&1)"; src=$?
[ "$src" -eq 0 ] \
    && ok "and clean again once the seed is removed" \
    || bad "check --ownership still non-zero ($src) after the seed was removed: $sout"

# --- 3: panic stops BOTH engines --------------------------------------------
# The counts are read BEFORE as well as after (dotfiles-ptd2): a "0 daemons"
# claim read through a pattern that was never shown live is a tautology.
# The ENGINE is read before as well, for the reason daemons_on()'s comment
# gives: these two assertions are the ones that say "the python daemon" and
# "the go daemon" out loud, so each has to have looked.
echo "mixed estate: panic sweeps both argv shapes"
before_py="$(daemons_on "$XPY")"; before_py_eng="$(engine_on "$XPY")"
before_go="$(daemons_on "$XGO")"; before_go_eng="$(engine_on "$XGO")"
DISPLAY="$XPY" sh "$PANIC" panic >/dev/null 2>&1
sleep 1
[ "$before_py" = 1 ] && [ "$before_py_eng" = python ] \
    && [ "$(daemons_on "$XPY")" = 0 ] \
    && ok "panic stopped the python daemon on $XPY (1 python -> 0)" \
    || bad "daemon on $XPY: $before_py $before_py_eng -> $(daemons_on "$XPY") \
$(engine_on "$XPY"), want 1 python -> 0 none"
[ "$before_go" = 1 ] && [ "$before_go_eng" = go ] \
    && [ "$(daemons_on "$XGO")" = 0 ] \
    && ok "panic stopped the go daemon on $XGO (1 go -> 0), a display it was \
not called with" \
    || bad "daemon on $XGO: $before_go $before_go_eng -> $(daemons_on "$XGO") \
$(engine_on "$XGO"), want 1 go -> 0 none"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
    ok "the fallback is linked at $LINK"
else
    bad "panic did not link the fallback"
fi

# --- 4: start refuses behind the latch, for BOTH engines --------------------
echo "mixed estate: start refuses behind the latch"
for dpy in "$XPY" "$XGO"; do
    sout="$(DISPLAY="$dpy" sh "$LAUNCHER" start "$dpy" 2>&1)"; src=$?
    if [ "$src" -eq 4 ] && [ "$(daemons_on "$dpy")" = 0 ]; then
        ok "start on $dpy refused with exit 4 and spawned nothing"
    else
        bad "start on $dpy exited $src leaving $(daemons_on "$dpy") daemon(s): $sout"
    fi
done

# --- 5: resume restores BOTH, each as its own engine ------------------------
# The engine each comes back as is engine_for()'s answer, not "whichever ran
# last": resume re-enters the launcher per display, so a table with a
# per-display arm has to be re-read correctly for the mixed estate to survive
# a panic at all.
echo "mixed estate: resume restores both engines"
DISPLAY="$XPY" sh "$PANIC" resume >/dev/null 2>&1
sleep 1
[ "$(engine_on "$XPY")" = python ] \
    && ok "$XPY came back as PYTHON after resume" \
    || bad "$XPY came back as $(engine_on "$XPY") after resume, want python"
[ "$(engine_on "$XGO")" = go ] \
    && ok "$XGO came back as GO after resume" \
    || bad "$XGO came back as $(engine_on "$XGO") after resume, want go"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
    bad "resume left the fallback linked at $LINK"
else
    ok "resume unlinked the fallback"
fi

DISPLAY="$XPY" sh "$LAUNCHER" stop "$XPY" >/dev/null 2>&1
DISPLAY="$XGO" sh "$LAUNCHER" stop "$XGO" >/dev/null 2>&1
sleep 0.5
[ "$(daemons_on "$XPY")" = 0 ] && [ "$(daemons_on "$XGO")" = 0 ] \
    && ok "both displays are clean at the end of the run" \
    || bad "strays left: $(daemons_on "$XPY") on $XPY, $(daemons_on "$XGO") on $XGO"

printf '\nmixed estate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
