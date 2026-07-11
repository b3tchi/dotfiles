# Shared session scoping for qs-start.sh / qs-overlay.sh — source, don't run.
# Concurrent sessions of the same user (local i3 on :0, xrdp Xvnc on :2, sway)
# are told apart by their display. Every kill / FIFO / IPC call is keyed on it
# so one session's restart never steals or kills another session's bar+overlay.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null

if [ -n "$SWAYSOCK" ]; then
    : # Sway — SWAYSOCK already set by sway
elif command -v i3 >/dev/null 2>&1; then
    # ALWAYS re-derive from DISPLAY (X root atom), even if I3SOCK is already
    # set: an inherited value may belong to a different session — e.g. a
    # restart issued from a shell inside the xrdp session targeting the
    # desktop display — which paints one session's focus frames / workspaces
    # onto the other session's bar and screen.
    _i3sock="$(i3 --get-socketpath 2>/dev/null)"
    [ -n "$_i3sock" ] && export I3SOCK="$_i3sock"
fi

# Session key: X11 DISPLAY when present (both native i3 and xrdp/Xvnc are
# X11), else WAYLAND_DISPLAY (sway). Children inherit the var, so matching
# it in /proc/<pid>/environ identifies "our" processes.
QS_DPY_VAR=DISPLAY
QS_DPY_VAL="$DISPLAY"
if [ -z "$QS_DPY_VAL" ]; then
    QS_DPY_VAR=WAYLAND_DISPLAY
    QS_DPY_VAL="$WAYLAND_DISPLAY"
fi
# Filename-safe id (":0" -> "_0") for per-session FIFOs/logs.
QS_SID="$(printf %s "${QS_DPY_VAL:-nodisplay}" | tr -c 'A-Za-z0-9' '_')"
# Regex-escaped value for the environ grep (displays like ":0.0" contain dots).
QS_DPY_RE="$(printf %s "$QS_DPY_VAL" | sed 's/[].*^$[\\]/\\&/g')"

# True if pid belongs to this session (environ carries our display).
qs_same_session() {
    grep -zqs "^$QS_DPY_VAR=$QS_DPY_RE\$" "/proc/$1/environ" 2>/dev/null
}

# Kill only this session's processes. Args are passed to pgrep
# (-x name or -f pattern); other sessions' matches are left alone.
qs_kill_session() {
    for _pid in $(pgrep "$@" 2>/dev/null); do
        qs_same_session "$_pid" && kill "$_pid" 2>/dev/null
    done
}
