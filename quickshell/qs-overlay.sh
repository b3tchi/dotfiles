#!/bin/sh
# Quickshell overlay — launcher + switcher in single process
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null

if [ -z "$I3SOCK" ] && command -v i3 >/dev/null 2>&1; then
    export I3SOCK="$(i3 --get-socketpath 2>/dev/null)"
fi

OVERLAY="$HOME/.dotfiles/quickshell/overlay"

case "$1" in
    start)            exec quickshell -p "$OVERLAY" ;;
    launcher)         quickshell -p "$OVERLAY" msg launcher toggle ;;
    switcher)         quickshell -p "$OVERLAY" msg switcher next ;;
    switcher-prev)    quickshell -p "$OVERLAY" msg switcher prev ;;
    switcher-confirm) quickshell -p "$OVERLAY" msg switcher confirm ;;
    switcher-cancel)  quickshell -p "$OVERLAY" msg switcher cancel ;;
    *)                echo "Usage: qs-overlay.sh {start|launcher|switcher|switcher-prev|switcher-confirm|switcher-cancel}" ;;
esac
