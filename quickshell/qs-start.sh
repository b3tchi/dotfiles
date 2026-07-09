#!/bin/sh
# Kill this session's quickshell instances and restart bar + overlay.
# Session-scoped (per display) via qs-session.sh: a local i3 and an xrdp
# session each keep their own bar — restarts never kill the other session's.
. "$HOME/.dotfiles/quickshell/qs-session.sh"

qs_kill_session -x quickshell
# The overlay spawns a detached keymon helper via setsid; clean it up too so
# $mod+Shift+d reloads don't leak helper processes across restarts. We sweep
# both the current python helper and the legacy xinput+awk pipeline so a
# partial upgrade or an orphan from an older quickshell version is cleaned up.
qs_kill_session -f 'qs-keymon.py'
qs_kill_session -f 'xinput test-xi2'
# focus helpers hold a flock — an orphan from a killed quickshell blocks
# respawns silently (new instances exit at the lock), so reap them too
qs_kill_session -f 'qs-focus-border.py'
qs_kill_session -f 'qs-focus-dim.py'
sleep 0.5

# Event-driven stats source for Bar.qml. Stats are system-wide, so ONE
# daemon is shared by all concurrent sessions (local + xrdp) — it writes an
# atomic state file every bar follows with `tail -F`, and it survives any
# single session's bar restart. Hash-check the source so a `git pull`
# triggers a rebuild even though git does not bump file mtimes.
QS_DAEMON="$HOME/.local/bin/qs-stats-daemon"
QS_STATE="${TMPDIR:-/tmp}/qs-stats.state"
export QS_STATS_FILE="$QS_STATE"   # Bar.qml reads this (has same-path fallback)
QS_SRC="$HOME/.dotfiles/quickshell/qs-stats-daemon.c"
QS_HASH_FILE="$HOME/.cache/qs-stats-daemon.sha"
QS_REBUILT=""
QS_CC=""
for cc in clang gcc cc; do
    if command -v "$cc" >/dev/null 2>&1; then QS_CC="$cc"; break; fi
done
if [ -f "$QS_SRC" ] && [ -n "$QS_CC" ]; then
    mkdir -p "$(dirname "$QS_DAEMON")" "$(dirname "$QS_HASH_FILE")"
    QS_HASH_NEW="$(sha1sum "$QS_SRC" | awk '{print $1}')"
    QS_HASH_OLD="$(cat "$QS_HASH_FILE" 2>/dev/null || echo none)"
    if [ ! -x "$QS_DAEMON" ] || [ "$QS_HASH_NEW" != "$QS_HASH_OLD" ]; then
        echo "Building qs-stats-daemon ($QS_CC)..."
        if "$QS_CC" -O2 -Wall -o "$QS_DAEMON" "$QS_SRC"; then
            chmod +x "$QS_DAEMON"
            echo "$QS_HASH_NEW" > "$QS_HASH_FILE"
            QS_REBUILT=1
        fi
    fi
fi
# flock so two sessions starting at once don't race the singleton check.
# Restart only after a rebuild (stale binary); otherwise leave the running
# daemon alone — another session's bar may be reading it right now.
if [ -x "$QS_DAEMON" ]; then
    (
        flock -w 5 9 || exit 0
        if [ -n "$QS_REBUILT" ]; then
            pkill -f "^$QS_DAEMON " 2>/dev/null
            sleep 0.2
        fi
        if ! pgrep -f "^$QS_DAEMON " >/dev/null 2>&1; then
            # 9>&- — don't let the daemon inherit the lock fd (it would
            # hold the flock forever and stall every later session start)
            setsid "$QS_DAEMON" "$QS_STATE" >/dev/null 2>"$XDG_RUNTIME_DIR/qs-stats.log" 9>&- &
        fi
    ) 9>"${TMPDIR:-/tmp}/qs-stats-daemon.lock"
fi

setsid quickshell &
# Over RDP the main instance hosts the overlay too (single process, gated by
# QS_RDP in config/shell.qml), so skip the separate overlay process there.
if [ "$QS_RDP" != "1" ]; then
    setsid quickshell -p "$HOME/.dotfiles/quickshell/overlay" &
fi
