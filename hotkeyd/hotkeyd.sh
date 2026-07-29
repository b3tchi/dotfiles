#!/bin/sh
# hotkeyd.sh — launcher for the global keybinding daemon (sp020 Task 5, ft011).
#
# usage: hotkeyd.sh start|stop|restart|status|check [display]
#
# Every consumer goes through this script, never hotkeyd.py directly: the
# session entry points call `start`, `hotkeyd-panic.sh` calls `stop`/`start`,
# and `check` is the validation path for hooks and for a human editing binds.py.
#
# THE i3 ESCAPE HATCH IS NO LONGER `restart` — it is `hotkeyd-panic.sh panic`,
# which hands the keyboard back to i3 instead of trying the daemon again. A
# restart only ever helped when the daemon was DEAD; it does nothing for a
# daemon that is alive and wrong, which is the failure this repo actually hit.
# `restart` stays as an ordinary operator verb.
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

# The panic latch (hotkeyd-panic.sh). While this link exists i3 is serving the
# fallback bind table, so a daemon starting behind it would contend for the same
# chords — and `start` is reached from an i3 `exec_always`, meaning any reload or
# xrdp reconnect would rearm one display without anyone asking. `start` refuses
# instead; `hotkeyd-panic.sh resume` is the only way back. Same env override as
# the panic script, for the suite's throwaway HOME.
I3_CONFIG_D="${HOTKEYD_I3_CONFIG_D:-$HOME/.i3/config.d}"
FALLBACK_LINK="$I3_CONFIG_D/zz-fallback-binds.conf"

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

# Is the panic latch set? `-L` before `-e` on purpose: `-e` follows the symlink
# and answers "no" for a link whose TARGET is gone, which is a dangling latch —
# still parsed by i3's glob, still a file `start` must refuse behind. One helper
# rather than the two byte-identical copies this used to carry at `start` and
# `status`, matching `linked()` in hotkeyd-panic.sh. They read the same path and
# so cannot disagree today; a predicate copied twice is one that eventually does.
linked() { [ -L "$FALLBACK_LINK" ] || [ -e "$FALLBACK_LINK" ]; }

# The daemon's pid, or empty. Identified by its own --display argument rather
# than by a pidfile: a pidfile can go stale after a SIGKILL and then lie about a
# daemon that is not there, which is the state the escape hatch exists for.
daemon_pid() {
    # Word-boundary match, NOT anchored to end of line: a daemon started by hand
    # with flags after --display (--binds while testing a table) would otherwise
    # be invisible to status and stop, and start would happily spawn a second
    # one beside it.
    pgrep -f "hotkeyd\.py .*--display $DPY_BASE( |\$)" 2>/dev/null | head -n 1
}

# Is that daemon SERVING, or merely alive? (dotfiles-hwds.28)
#
# daemon_pid() answers "a process matches", which a daemon serving the keyboard
# and one frozen mid-loop answer identically: both hold the flock, both keep the
# state socket bound so connections still complete out of the listen backlog,
# both match every pattern. Every verb below used to decide on that alone, so
# `status` said "running" at exit 0 for a daemon serving nothing and `start`
# refused to replace it — and since the nav cutover i3 no longer owns mode
# "nav", so that display got no nav at all, silently.
#
# Codes come straight from hotkeyd.py: 0 serving, 6 the run loop has stopped
# (reapable), 7 the display did not answer US (NOT reapable — see the constants
# in hotkeyd.py for why that distinction is a safety boundary and not a
# nicety). Output is relayed rather than reworded so there is one wording of the
# diagnosis, in the place that measured it.
health() {
    "$DAEMON" --health --display "$DPY_BASE" 2>&1
}

case "$VERB" in
    start)
        need_display
        need_runtime
        if linked; then
            die "session is PANICKED (fallback linked at $FALLBACK_LINK) — \
run hotkeyd-panic.sh resume" 4
        fi
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
        # HOTKEYD_BINDS names an alternative table. The pgrep pattern above was
        # already written for a daemon carrying flags after --display precisely
        # so a hand-started `--binds` run stays visible to status/stop; this
        # makes the same thing reachable through the launcher, which is what
        # `hotkeyd-panic.sh resume` needs to bring back the table that was
        # running before the panic rather than the shipped one.
        if [ -n "${HOTKEYD_BINDS:-}" ]; then
            env -u I3SOCK DISPLAY="$DPY_BASE" \
                setsid "$DAEMON" --display "$DPY_BASE" \
                --binds "$HOTKEYD_BINDS" >>"$LOG" 2>&1 &
        else
            env -u I3SOCK DISPLAY="$DPY_BASE" \
                setsid "$DAEMON" --display "$DPY_BASE" >>"$LOG" 2>&1 &
        fi
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
        # Reached on EVERY stop that found a daemon (the line above is a
        # compound `&&`, not a branch), but only load-bearing on the wedged ->
        # SIGKILL escalation, where the daemon never got to run its own
        # cleanup: a graceful SIGTERM unlinks the socket itself, so this is a
        # no-op there. A daemon already dead when stop was called exits at the
        # "not running" branch above and never reaches here; THAT socket is
        # reaped by the next daemon's own startup probe (layers.py
        # _reap_stale_socket), which is what makes a restart after a SIGKILL
        # work at all.
        rm -f "$SOCK"
        printf 'hotkeyd: stopped on %s\n' "$DPY_BASE"
        ;;

    restart)
        # An operator convenience, NOT the escape hatch — see the header. It
        # brings a dead or misbehaving daemon back on the same table; if the
        # table itself is the problem, restarting reinstates it. That is what
        # `hotkeyd-panic.sh panic` is for.
        "$0" stop "$DPY" >/dev/null 2>&1
        exec "$0" start "$DPY"
        ;;

    status)
        need_display
        need_runtime
        pid="$(daemon_pid)"
        if [ -n "$pid" ]; then
            # DAEMON + LATCH = CONTESTED, and it must not read as healthy
            # (dotfiles-hwds.21). The latch is not self-enforcing: `start`
            # refuses behind it, but hotkeyd.py run directly bypasses this
            # script entirely — and daemon_pid() above is deliberately written
            # to SEE such a daemon — while panic stops daemons and only THEN
            # links, so an `exec_always` firing in that window rearms a display
            # behind the fallback. Either ordering ends here: two X clients
            # holding overlapping chords, the one state the whole panic design
            # exists to prevent. Reporting "running … " at exit 0 is worse than
            # the bare "not running" below, because it ends the investigation.
            if linked; then
                # Adjacent quoted strings, not a backslash-newline: inside
                # SINGLE quotes a backslash is literal, so continuing the format
                # that way would print a stray `\` and a line break into the i3
                # log — which is where this now lands, autostart being armed.
                printf 'hotkeyd: CONTESTED on %s — daemon running (pid %s) '\
'BEHIND the panic fallback (linked at %s); i3 and the daemon both hold grabs, '\
'run hotkeyd-panic.sh panic\n' \
                    "$DPY_BASE" "$pid" "$FALLBACK_LINK"
                # The cure is PANIC, not resume. The latched state is the
                # working state — i3 owns the whole keyboard — so an ambiguous
                # session fails TOWARD the latch: panic stops every daemon on
                # the machine and relinks, and is idempotent, so it converges
                # from here. `resume` would drop the link with the rogue daemon
                # still up and leave nothing latched at all.
                #
                # Exit 4, the launcher's "the panic latch is set" code, the same
                # one `start` returns for the same reason. NOT 0, which is the
                # defect. NOT 1 either: 1 means "no daemon for this display" and
                # callers read it that way (test-launcher.sh asserts zero vs
                # non-zero on four paths, all of them latch-free), and here
                # there IS a daemon — a contested session is a different problem
                # from an absent one and gets a different code.
                exit 4
            fi
            # ALIVE IS NOT SERVING (dotfiles-hwds.28). Until now this branch
            # printed "running" at exit 0 on the strength of daemon_pid() alone,
            # which is a liveness check that cannot observe death: it answers
            # identically for a daemon serving the keyboard and one frozen
            # mid-loop. That is the dotfiles-hwds.19/.21 lesson a third time, and
            # here it did active harm — the operator (and the live verification
            # matrix) could not get the real answer out of the launcher, so they
            # went looking for it with `xdpyinfo`, which was not installed,
            # exited 127, and got read as a dead X server on a display whose
            # Xorg had been up for eleven days.
            hout="$(health)"; hrc=$?
            # A FOREIGN KEYBOARD GRAB IS NOT OURS TO RESTART (exit 8,
            # dotfiles-hwds.30). Every other health failure is the daemon's own
            # and `start` is the cure; this one is another client holding an
            # exclusive grab that bypasses every passive grab on the display,
            # and restarting only re-registers chords that stay bypassed.
            # Printing the "run start" suffix here would contradict the message
            # itself, which says restarting cannot fix it — and send whoever
            # reads it round a loop that never converges.
            if [ "$hrc" -eq 8 ]; then
                printf '%s (pid %s)\n' "$hout" "$pid"
                exit 8
            fi
            if [ "$hrc" -ne 0 ]; then
                # Name the pid as well as the reason: the cure is `start`, and
                # whoever is about to run it wants to know which process is
                # going to be replaced.
                printf '%s (pid %s) — run hotkeyd.sh start %s\n' \
                    "$hout" "$pid" "$DPY_BASE"
                # 6, not 0 and not 1. 0 is the defect being fixed. 1 means "no
                # daemon for this display" and callers read it that way
                # (test-launcher.sh asserts on that path); here there IS a
                # process, it is simply not serving — a different problem from
                # an absent one, so a different code, matching hotkeyd.py's own.
                exit 6
            fi
            printf 'hotkeyd: running on %s (pid %s, socket %s)\n' \
                "$DPY_BASE" "$pid" "$SOCK"
            exit 0
        fi
        # No daemon and the latch set is the QUIET half, and it is by design —
        # `start` refuses behind the link (see the FALLBACK_LINK note above) —
        # so a bare "not running" names the symptom and hides the cause. Once
        # autostart is armed, `start` runs from an i3 `exec_always` and its
        # refusal goes to the i3 log rather than to a terminal, which makes
        # `status` the diagnostic a person actually reads: it says the cause and
        # the cure on one line. The exit code is unchanged — still 1, as callers
        # expect for "no daemon"; only the message grows. Here the cure IS
        # `resume`: nothing contends, the session is simply parked in the
        # fallback, and resume is the only way back out.
        if linked; then
            printf 'hotkeyd: not running on %s — session is PANICKED '\
'(fallback linked at %s), run hotkeyd-panic.sh resume\n' \
                "$DPY_BASE" "$FALLBACK_LINK"
            exit 1
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
