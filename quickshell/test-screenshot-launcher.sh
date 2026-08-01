#!/bin/sh
# Regression suite for quickshell/qs-screenshot.sh's layer ownership
# (dotfiles-b3d4).
#
# The defect: two overlapping launches flickered the aiming strip and ring in
# and out. Each launch kills the previous SELECTOR but not the previous
# LAUNCHER, which outlives its own selector by design and then ran an
# unconditional `set-layer default` — clearing the layer the newer launch had
# just raised.
#
# What this pins is the ORDER OF EFFECTS on the layer channel, not the exit
# status: a superseded launcher must NOT clear, and the surviving one must.
#
# No X, no daemon, no i3. `hotkeyd` and the selector are both stubs on PATH:
# the real binary would need a live daemon, and the real selector needs a seat
# grab. What the launcher does with the layer signal is a shell-level property,
# so it is testable at shell level — the live gesture is smoke-tested by hand.
set -eu

QS_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LAUNCHER="$QS_DIR/qs-screenshot.sh"

pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2" >&2; }

# --- harness -----------------------------------------------------------------
# A fake $HOME so the launcher's hardcoded $HOME/.dotfiles/hotkeyd/hotkeyd
# spelling (sp023's one-spelling discipline) resolves to our stub instead of the
# real binary. Every set-layer call appends one line to $LOG, which IS the
# assertion surface.
setup() {
    TMP="$(mktemp -d)"
    LOG="$TMP/layer.log"
    : > "$LOG"

    mkdir -p "$TMP/home/.dotfiles/hotkeyd"
    cat > "$TMP/home/.dotfiles/hotkeyd/hotkeyd" <<EOF
#!/bin/sh
# stub hotkeyd: record "set-layer <name>", succeed silently
[ "\$1" = "set-layer" ] && printf '%s\n' "\$2" >> "$LOG"
exit 0
EOF
    chmod +x "$TMP/home/.dotfiles/hotkeyd/hotkeyd"

    # Stub session helper: the real one probes i3 --get-socketpath, which needs
    # a live WM. Only the two functions the launcher calls plus QS_SID matter.
    mkdir -p "$TMP/qs"
    cat > "$TMP/qs/qs-session.sh" <<'EOF'
QS_SID="test"
qs_same_session() { return 0; }
qs_kill_session() { :; }
EOF

    # Stub selector: stays up QS_TEST_HOLD seconds, so a second launch can
    # overlap a live first one. Written ONCE — rewriting either this or the
    # launcher while an instance is mid-flight corrupts that running shell,
    # since sh reads a script incrementally rather than slurping it.
    cat > "$TMP/qs/qs-region.py" <<'EOF'
#!/bin/sh
sleep "${QS_TEST_HOLD:-0.5}"
EOF
    chmod +x "$TMP/qs/qs-region.py"
    cp "$LAUNCHER" "$TMP/qs/qs-screenshot.sh"
    chmod +x "$TMP/qs/qs-screenshot.sh"
}

teardown() { rm -rf "$TMP"; }

# Run the launcher in the background against the stubs; set LAUNCH_PID.
#
# Deliberately NOT `pid="$(launch ...)"`. Command substitution waits for the
# stdout pipe to close, and a background job INHERITS that pipe — so the
# "background" launch would run to completion before the caller resumed, and
# the two instances could never overlap. That silently turns the regression
# case into two sequential launches, which pass a broken launcher. Hence the
# explicit >/dev/null and a global instead of a subshell (which would also put
# the job out of `wait`'s reach, as it is then not a child of this shell).
launch() {
    env HOME="$TMP/home" DISPLAY=":99" XDG_RUNTIME_DIR="$TMP" \
        QS_TEST_HOLD="$1" "$TMP/qs/qs-screenshot.sh" >/dev/null 2>&1 &
    LAUNCH_PID=$!
}

# --- case 1: a single launch raises once and clears once ----------------------
setup
launch 0.2; p1=$LAUNCH_PID
wait "$p1" 2>/dev/null || true
got="$(tr '\n' ' ' < "$LOG" | sed 's/ *$//')"
if [ "$got" = "screenshot default" ]; then
    ok "single launch raises then clears"
else
    no "single launch raises then clears" "want 'screenshot default', got '$got'"
fi
teardown

# --- case 2: THE REGRESSION ---------------------------------------------------
# Two overlapping launches. The first is still alive when the second starts and
# raises. The first must NOT clear when its selector ends — it no longer owns
# the layer. Expected: screenshot, screenshot, default (one trailing clear, and
# never a clear sitting between the second raise and the end).
#
# Against the pre-fix launcher this produced a 'default' in the MIDDLE — the
# superseded instance clearing a layer the live one had raised. That middle
# clear is the flicker.
setup
launch 0.6; p1=$LAUNCH_PID
sleep 0.2
launch 0.6; p2=$LAUNCH_PID
wait "$p1" 2>/dev/null || true
wait "$p2" 2>/dev/null || true
got="$(tr '\n' ' ' < "$LOG" | sed 's/ *$//')"
if [ "$got" = "screenshot screenshot default" ]; then
    ok "superseded launcher does not clear the live launcher's layer"
else
    no "superseded launcher does not clear the live launcher's layer" \
       "want 'screenshot screenshot default', got '$got'"
fi

# The layer must be DOWN at the end of the gesture, whichever instance won —
# a guard that silenced the middle clear by never clearing at all would pass
# the case above and strand the strip forever.
last="$(tail -n1 "$LOG" 2>/dev/null || true)"
if [ "$last" = "default" ]; then
    ok "the surviving launcher still clears on exit"
else
    no "the surviving launcher still clears on exit" "last line was '$last', want 'default'"
fi
teardown

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
