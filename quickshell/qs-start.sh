#!/bin/sh
# Kill this session's quickshell instances and restart bar + overlay.
# Session-scoped (per display) via qs-session.sh: a local i3 and an xrdp
# session each keep their own bar — restarts never kill the other session's.
. "$HOME/.dotfiles/quickshell/qs-session.sh"

# The notification-service daemon (sp019 tasks 1-3, dotfiles-c5fd.3) is a
# USER-LEVEL singleton — one process serves every session, unlike the bar,
# which is scoped per display via qs_kill_session above. A bare
# `qs_kill_session -x quickshell` would still match and kill it (its comm
# name is "quickshell" like any other instance, since it's launched as
# `quickshell -p .../notif`), tearing it down on every restart of whichever
# session happened to spawn it. Spare any same-session quickshell pid whose
# /proc/<pid>/cmdline carries the notif profile path — refinement delta 1;
# only the user-level flock section below may ever restart this pid.
QS_NOTIF_PROFILE_DIR="$HOME/.dotfiles/quickshell/notif"
for _qs_pid in $(pgrep -x quickshell 2>/dev/null); do
    qs_same_session "$_qs_pid" || continue
    tr '\0' ' ' < "/proc/$_qs_pid/cmdline" 2>/dev/null | grep -qF -- "$QS_NOTIF_PROFILE_DIR" && continue
    kill "$_qs_pid" 2>/dev/null
done
# The overlay used to spawn a detached key-monitor helper. It no longer does:
# hotkeyd owns the alt-tab gesture as a hold layer and qs-keymon.py is deleted
# (sp020, dotfiles-hwds.40), so there is nothing left here to reap and the
# sweep for it went with the file.
#
# ONE-TIME UPGRADE STEP, and the only thing that sweep was still buying: on a
# machine whose quickshell has NOT been restarted since this landed, the old
# process still has its detached listener, and that listener keeps driving the
# switcher alongside the daemon — every Tab cycles twice. Restarting quickshell
# does not reap it (that is why the sweep existed). Kill it by hand once:
#     pkill -f qs-keymon.py
# A log out, or any reboot, does the same.
#
# The older xinput+awk pipeline sweep stays: it predates qs-keymon.py, was
# never this cutover's to remove, and an orphan from that era is reaped by the
# same argument.
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

# Notification-service daemon (sp019 tasks 1-3): a single user-scoped
# `quickshell -p notif` process owns org.freedesktop.Notifications for ALL
# sessions (local + xrdp, adr0004) behind a USER-LEVEL flock — NOT the
# per-display qs_kill_session axis above, which is the wrong scope for a
# D-Bus name singleton. Every bar (Task 4) tails the state file this daemon
# writes. The first session up starts it; every later session's launch
# attempt below no-ops on the already-running instance. Unconditional even
# under QS_RDP=1 — the xrdp session may be the first one up.
QS_NOTIF_STORESH="$HOME/.dotfiles/quickshell/qs-notif-store.sh"
QS_NOTIF_STATE="$XDG_RUNTIME_DIR/qs-notif.state"
export QS_NOTIF_FILE="$QS_NOTIF_STATE"   # Bar.qml reads this
QS_NOTIF_LOCK="$XDG_RUNTIME_DIR/qs-notif-daemon.lock"
QS_NOTIF_HASH_FILE="$HOME/.cache/qs-notif-daemon.sha"
mkdir -p "$(dirname "$QS_NOTIF_HASH_FILE")"
# Hash-check restart (refinement delta 5): a `git pull` changes the QML/
# store source without bumping any mtime quickshell would notice, so a
# content hash decides whether to pkill+relaunch under the lock — mirrors
# the qs-stats-daemon rebuild guard above.
QS_NOTIF_HASH_NEW="$(cat "$QS_NOTIF_PROFILE_DIR"/*.qml "$QS_NOTIF_STORESH" 2>/dev/null | sha1sum | awk '{print $1}')"
QS_NOTIF_HASH_OLD="$(cat "$QS_NOTIF_HASH_FILE" 2>/dev/null || echo none)"
QS_NOTIF_CHANGED=""
if [ "$QS_NOTIF_HASH_NEW" != "$QS_NOTIF_HASH_OLD" ]; then
    QS_NOTIF_CHANGED=1
    echo "$QS_NOTIF_HASH_NEW" > "$QS_NOTIF_HASH_FILE"
fi
# flock so two sessions starting at once don't race the singleton check.
# Restart only when the hash changed; otherwise leave the running daemon
# alone — another session's bar may be reading it right now.
(
    flock -w 5 9 || exit 0
    if [ -n "$QS_NOTIF_CHANGED" ]; then
        pkill -f "quickshell -p $QS_NOTIF_PROFILE_DIR" 2>/dev/null
        sleep 0.2
    fi
    if ! pgrep -f "quickshell -p $QS_NOTIF_PROFILE_DIR" >/dev/null 2>&1; then
        # 9>&- — don't let the daemon inherit the lock fd (it would hold
        # the flock forever and stall every later session start)
        setsid quickshell -p "$QS_NOTIF_PROFILE_DIR" >/dev/null 2>"$XDG_RUNTIME_DIR/qs-notif-daemon.log" 9>&- &
    fi
) 9>"$QS_NOTIF_LOCK"

setsid quickshell &
# Over RDP the main instance hosts the overlay too (single process, gated by
# QS_RDP in config/shell.qml), so skip the separate overlay process there.
if [ "$QS_RDP" != "1" ]; then
    setsid quickshell -p "$HOME/.dotfiles/quickshell/overlay" &
fi
