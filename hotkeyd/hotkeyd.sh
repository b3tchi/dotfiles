#!/bin/sh
# hotkeyd.sh — launcher for the global keybinding daemon (sp020 Task 5, ft011).
#
# usage: hotkeyd.sh start|stop|restart|status|check [display]
#
# Every consumer goes through this script, never hotkeyd.py directly: the i3
# escape-hatch bind calls `restart`, the session entry points call `start`, and
# `check` is the validation path for hooks and for a human editing binds.py.
#
# WHY SH AND NOT NUSHELL — [[adr0015]] declines the compiled-helper wrapper
# mandate for Python entry points, and the front-end convention for the X-session
# daemons is a thin shell launcher (qs-bar.sh / qs-notif.sh shape). Adding a
# nushell hop in front of a keystroke daemon would put nushell's startup cost on
# the restart path, which is exactly the path that matters during an outage.
#
# PER-DISPLAY, ALWAYS — native :0 and the xrdp :10 session are separate X
# servers with separate keyboards, so each gets its own daemon, its own lock and
# its own state socket. The screen suffix is stripped (":10.0" and ":10" are one
# session) with the same ${VAR%.*} canonicalization the clip-store scripts use
# (dotfiles-3x85); an RDP session presents DISPLAY=:10.0 and a bare ":10" from
# the i3 launcher must resolve to the SAME daemon, or a restart leaks the old one
# and two daemons fight over one keyboard.
set -u

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DAEMON="$HERE/hotkeyd.py"

VERB="${1:-status}"
DPY="${2:-${DISPLAY:-}}"
DPY_BASE="${DPY%.*}"
TAG="$(printf %s "${DPY_BASE#:}" | tr -c 'A-Za-z0-9' '_')"

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOCK="$RUNTIME/hotkeyd-$TAG.lock"
SOCK="$RUNTIME/hotkeyd-$TAG.sock"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/hotkeyd-$TAG.log"

die() { printf 'hotkeyd.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

need_display() {
    [ -n "$DPY_BASE" ] || die "no display: pass one, or set DISPLAY" 2
}

need_runtime() {
    [ -d "$RUNTIME" ] || die "runtime dir does not exist: $RUNTIME" 2
}

# The daemon's pid, or empty. Identified by its own --display argument rather
# than by a pidfile: a pidfile can go stale after a SIGKILL and then lie about a
# daemon that is not there, which is the state the escape hatch exists for.
daemon_pid() {
    pgrep -f "hotkeyd\.py .*--display $DPY_BASE\$" 2>/dev/null | head -n 1
}

case "$VERB" in
    start)
        need_display
        need_runtime
        pid="$(daemon_pid)"
        if [ -n "$pid" ]; then
            # Non-zero and loud: this is normally an i3 `exec_always` firing on a
            # config reload, and silently "succeeding" would hide a real
            # double-start. Nothing is spawned either way.
            die "already running on $DPY_BASE (pid $pid)" 3
        fi
        mkdir -p "$(dirname "$LOG")"
        # `env -u I3SOCK`: i3 exports its own socket into every process it
        # execs, and both daemons are started from ONE session's exec_always, so
        # the :10 daemon would inherit :0's socket. The daemon resolves the path
        # itself from its own X connection (dotfiles-hwds.6) — this just removes
        # the misleading value from the environment entirely.
        env -u I3SOCK DISPLAY="$DPY_BASE" \
            setsid "$DAEMON" --display "$DPY_BASE" >>"$LOG" 2>&1 &
        # Give it long enough to fail loudly (bad table, no X, lock held) rather
        # than reporting success for a process that died on startup.
        sleep 0.4
        pid="$(daemon_pid)"
        [ -n "$pid" ] || die "failed to start — see $LOG" 1
        printf 'hotkeyd: started on %s (pid %s)\n' "$DPY_BASE" "$pid"
        ;;

    stop)
        need_display
        pid="$(daemon_pid)"
        if [ -z "$pid" ]; then
            printf 'hotkeyd: not running on %s\n' "$DPY_BASE"
            exit 0                      # stopping a stopped daemon is success
        fi
        kill "$pid" 2>/dev/null
        i=0
        while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
            i=$((i + 1))
            sleep 0.1
        done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        # SIGTERM unlinks the socket on the way out; a SIGKILLed predecessor
        # leaves it behind, so sweep it here too. The daemon reaps a stale socket
        # on startup as well — belt and braces, because a leftover socket is the
        # thing that makes a restart fail.
        rm -f "$SOCK"
        printf 'hotkeyd: stopped on %s\n' "$DPY_BASE"
        ;;

    restart)
        # THE ESCAPE HATCH. i3 keeps exactly one hardcoded bind pointing here,
        # because grabs die with the process: if the daemon crashes while it owns
        # the bind table, the only way back is a key i3 still handles itself.
        "$0" stop "$DPY" >/dev/null 2>&1
        exec "$0" start "$DPY"
        ;;

    status)
        need_display
        need_runtime
        pid="$(daemon_pid)"
        if [ -n "$pid" ]; then
            printf 'hotkeyd: running on %s (pid %s, socket %s)\n' \
                "$DPY_BASE" "$pid" "$SOCK"
            exit 0
        fi
        printf 'hotkeyd: not running on %s\n' "$DPY_BASE"
        exit 1
        ;;

    check)
        # No display needed: validation is pure, which is what lets it run in a
        # pre-commit hook and on a headless box.
        exec "$DAEMON" --check
        ;;

    *)
        die "unknown verb: $VERB (start|stop|restart|status|check)" 64
        ;;
esac
