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
#
# NEWEST WINS within a shape (dotfiles-72f7). A session recreated on the same
# display number can find the previous session's quickshell still alive,
# orphaned, with the same DISPLAY in its environ; its X server is gone and an
# ipc call to it hangs forever. pgrep lists lowest pid first, which is the OLD
# one, so of several matches the one started last is taken - by start time
# (/proc/<pid>/stat field 22), not pid, because pids wrap.
qs_start_time() {
    # Strip through the ")" closing comm first: comm may contain spaces.
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20
}

qs_target_pid() {
    _ovl=""; _ovl_t=-1; _main=""; _main_t=-1
    for _pid in $(pgrep -x quickshell 2>/dev/null); do
        qs_same_session "$_pid" || continue
        _t="$(qs_start_time "$_pid")"
        [ -n "$_t" ] || continue            # exited since pgrep
        if tr '\0' '\n' <"/proc/$_pid/cmdline" | grep -Fxq -- "$OVERLAY"; then
            [ "$_t" -gt "$_ovl_t" ] && { _ovl="$_pid"; _ovl_t="$_t"; }
        # main instance = this session's quickshell with no -p profile at all.
        elif ! tr '\0' '\n' <"/proc/$_pid/cmdline" | grep -Fxq -- '-p'; then
            [ "$_t" -gt "$_main_t" ] && { _main="$_pid"; _main_t="$_t"; }
        fi
    done
    # A dedicated overlay process wins over the main instance.
    [ -n "$_ovl" ] && { echo "$_ovl"; return 0; }
    [ -n "$_main" ] || return 1
    echo "$_main"
}

qs_call() {
    _tpid="$(qs_target_pid)" || {
        echo "qs-overlay: no quickshell instance for $QS_DPY_VAR=$QS_DPY_VAL" >&2
        exit 1
    }
    # Bounded: a target that stopped answering must cost one lost keypress,
    # not one more hung process per keypress (dotfiles-72f7).
    exec timeout 5 quickshell ipc --pid "$_tpid" call "$@"
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
