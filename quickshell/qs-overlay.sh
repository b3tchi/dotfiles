#!/bin/sh
# Quickshell overlay — launcher + switcher in single process.
# Session-scoped via qs-session.sh: with concurrent sessions (local + xrdp)
# a bare `quickshell msg` is ambiguous about which instance it reaches, so
# messages resolve THIS display's instance pid and target it via `ipc --pid`.
. "$HOME/.dotfiles/quickshell/qs-session.sh"

OVERLAY="$HOME/.dotfiles/quickshell/overlay"

# Pid of the instance hosting the overlay for this display. Two session shapes:
# on desktop a separate `quickshell -p overlay` process hosts it; over RDP the
# MAIN instance does (single process, gated by QS_RDP in config/shell.qml, and
# qs-start.sh does not spawn the separate one there).
#
# DISCOVERED, NOT DECLARED (dotfiles-hwds.45). This used to branch on the
# QS_RDP env var, which made the answer depend on WHO SPAWNED THE CALLER rather
# than on what is running. i3/config-proot-xrdp sets QS_RDP only as the `$qsenv`
# prefix on its own bindsym lines, so once hotkeyd owned the overlay chords
# (dotfiles-hwds.40) every daemon-dispatched verb arrived with QS_RDP unset,
# took the desktop branch, and failed with "no quickshell instance" on a
# session that had one — the RDP session simply keeps it in the main process.
#
# Preference order, both shapes served with no env at all: a dedicated
# `-p <overlay>` process if this session runs one, else the session's main
# instance. qs-clip.sh / qs-notif.sh already resolve their target this way,
# which is why $mod+v and $mod+n never had this failure.
qs_target_pid() {
    _main=""
    for _pid in $(pgrep -x quickshell 2>/dev/null); do
        qs_same_session "$_pid" || continue
        if tr '\0' '\n' <"/proc/$_pid/cmdline" | grep -Fxq -- "$OVERLAY"; then
            echo "$_pid"                    # dedicated overlay process wins
            return 0
        fi
        # main instance = this session's quickshell with no -p profile at all.
        # Remembered rather than returned, so a dedicated process later in the
        # pgrep order still takes precedence.
        if [ -z "$_main" ] \
           && ! tr '\0' '\n' <"/proc/$_pid/cmdline" | grep -Fxq -- '-p'; then
            _main="$_pid"
        fi
    done
    [ -n "$_main" ] || return 1
    echo "$_main"
}

qs_call() {
    _tpid="$(qs_target_pid)" || {
        echo "qs-overlay: no quickshell instance for $QS_DPY_VAR=$QS_DPY_VAL" >&2
        exit 1
    }
    exec quickshell ipc --pid "$_tpid" call "$@"
}

# Sourcing this file with QS_OVERLAY_LIB=1 loads the helpers WITHOUT
# dispatching — how test-overlay-target.sh exercises qs_target_pid against
# both session shapes (dotfiles-hwds.45). Any other use runs the verb.
[ "${QS_OVERLAY_LIB:-}" = "1" ] && return 0

case "$1" in
    start)
        if [ "$QS_RDP" = "1" ]; then
            exec quickshell
        else
            exec quickshell -p "$OVERLAY"
        fi
        ;;
    launcher)         qs_call launcher toggle ;;
    switcher)         qs_call switcher next ;;
    switcher-prev)    qs_call switcher prev ;;
    switcher-confirm) qs_call switcher confirm ;;
    switcher-cancel)  qs_call switcher cancel ;;
    switcher-search)  qs_call switcher search ;;
    projects)         qs_call projects toggle ;;
    *)                echo "Usage: qs-overlay.sh {start|launcher|switcher|switcher-prev|switcher-confirm|switcher-cancel|switcher-search|projects}" ;;
esac
