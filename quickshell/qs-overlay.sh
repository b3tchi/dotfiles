#!/bin/sh
# Quickshell overlay — launcher + switcher in single process.
# Session-scoped via qs-session.sh: with concurrent sessions (local + xrdp)
# a bare `quickshell msg` is ambiguous about which instance it reaches, so
# messages resolve THIS display's instance pid and target it via `ipc --pid`.
. "$HOME/.dotfiles/quickshell/qs-session.sh"

OVERLAY="$HOME/.dotfiles/quickshell/overlay"

# Pid of the instance hosting the overlay for this display. Over RDP
# (QS_RDP=1) that's the main/default instance — the overlay is embedded in it
# (single process, gated by QS_RDP in config/shell.qml). On desktop it's the
# separate `quickshell -p overlay` process.
qs_target_pid() {
    for _pid in $(pgrep -x quickshell 2>/dev/null); do
        qs_same_session "$_pid" || continue
        if [ "$QS_RDP" = "1" ]; then
            # main instance: cmdline has no -p
            tr '\0' '\n' <"/proc/$_pid/cmdline" | grep -Fxq -- '-p' && continue
        else
            tr '\0' '\n' <"/proc/$_pid/cmdline" | grep -Fxq -- "$OVERLAY" || continue
        fi
        echo "$_pid"
        return 0
    done
    return 1
}

qs_call() {
    _tpid="$(qs_target_pid)" || {
        echo "qs-overlay: no quickshell instance for $QS_DPY_VAR=$QS_DPY_VAL" >&2
        exit 1
    }
    exec quickshell ipc --pid "$_tpid" call "$@"
}

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
