#!/bin/sh
# Quickshell overlay — launcher + switcher in single process
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null

if [ -n "$SWAYSOCK" ]; then
    : # Sway — SWAYSOCK already set by sway
elif [ -z "$I3SOCK" ] && command -v i3 >/dev/null 2>&1; then
    export I3SOCK="$(i3 --get-socketpath 2>/dev/null)"
fi

OVERLAY="$HOME/.dotfiles/quickshell/overlay"

# Over RDP (QS_RDP=1) the overlay is embedded in the main/default quickshell
# instance (single process), so IPC targets it with no -p. Desktop keeps the
# separate `-p overlay` instance.
if [ "$QS_RDP" = "1" ]; then
    QS="quickshell"
else
    QS="quickshell -p $OVERLAY"
fi

case "$1" in
    start)            exec $QS ;;
    launcher)         $QS msg launcher toggle ;;
    switcher)         $QS msg switcher next ;;
    switcher-prev)    $QS msg switcher prev ;;
    switcher-confirm) $QS msg switcher confirm ;;
    switcher-cancel)  $QS msg switcher cancel ;;
    switcher-search)  $QS msg switcher search ;;
    projects)         $QS msg projects toggle ;;
    *)                echo "Usage: qs-overlay.sh {start|launcher|switcher|switcher-prev|switcher-confirm|switcher-cancel|switcher-search|projects}" ;;
esac
