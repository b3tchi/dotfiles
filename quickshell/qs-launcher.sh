#!/bin/sh
# Quickshell launcher — platform-aware startup and toggle
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null

# Resolve I3SOCK if available and not set
if [ -z "$I3SOCK" ] && command -v i3 >/dev/null 2>&1; then
    export I3SOCK="$(i3 --get-socketpath 2>/dev/null)"
fi

if [ "$1" = "start" ]; then
    # Start the resident launcher process (X11 two-process mode)
    exec quickshell -p ~/.dotfiles/quickshell/launcher
fi

# Toggle launcher
if [ -n "$WAYLAND_DISPLAY" ]; then
    quickshell msg launcher toggle
else
    quickshell -p ~/.dotfiles/quickshell/launcher msg launcher toggle
fi
