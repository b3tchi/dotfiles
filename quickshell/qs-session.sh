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
# Screen-suffix normalization: Qt canonicalizes DISPLAY to add the screen
# (":10" -> ":10.0") in every quickshell's environ, but the i3 launcher's
# DISPLAY is sometimes bare (":10"). An exact ^DISPLAY=:10$ match from a bare
# context then MISSES the running ":10.0" instances, so a restart's kill leaks
# the old bar and two bars stack up. Match the bare display followed by an
# OPTIONAL screen suffix so ":10" and ":10.0" are the same session either way.
# (Same ${VAR%.*} canonicalization as the clip-store scripts, dotfiles-3x85.)
# Only strip for X DISPLAY — WAYLAND_DISPLAY names carry no screen suffix.
QS_DPY_BASE="$QS_DPY_VAL"
[ "$QS_DPY_VAR" = DISPLAY ] && QS_DPY_BASE="${QS_DPY_VAL%.*}"
# Filename-safe id (":0" -> "_0") for per-session FIFOs/logs.
QS_SID="$(printf %s "${QS_DPY_BASE:-nodisplay}" | tr -c 'A-Za-z0-9' '_')"
# Regex-escaped bare value for the environ grep (displays like ":0" -> "\:0").
QS_DPY_RE="$(printf %s "$QS_DPY_BASE" | sed 's/[].*^$[\\]/\\&/g')"

# True if pid belongs to this session (environ carries our display). The
# trailing (\.[0-9]+)? tolerates the Qt-added screen suffix in either direction.
qs_same_session() {
    grep -zqsE "^$QS_DPY_VAR=$QS_DPY_RE(\.[0-9]+)?\$" "/proc/$1/environ" 2>/dev/null
}

# Kill only this session's processes. Args are passed to pgrep
# (-x name or -f pattern); other sessions' matches are left alone.
qs_kill_session() {
    for _pid in $(pgrep "$@" 2>/dev/null); do
        qs_same_session "$_pid" && kill "$_pid" 2>/dev/null
    done
}
