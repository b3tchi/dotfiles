#!/bin/sh
# Kill all quickshell instances and restart bar + overlay
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null

if [ -z "$I3SOCK" ] && command -v i3 >/dev/null 2>&1; then
    export I3SOCK="$(i3 --get-socketpath 2>/dev/null)"
fi

killall quickshell 2>/dev/null
sleep 0.5

setsid quickshell &
setsid quickshell -p "$HOME/.dotfiles/quickshell/overlay" &
