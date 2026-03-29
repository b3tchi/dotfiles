#!/bin/sh
# Toggle quickshell launcher via IPC
# Platform-aware: works on proot, native Linux, Wayland
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null

if [ "$1" = "start" ]; then
    # Start the resident launcher process (for X11 two-process mode)
    exec quickshell -p ~/.dotfiles/quickshell/launcher
fi

# Check if running on Wayland (launcher embedded in bar process)
if [ -n "$WAYLAND_DISPLAY" ]; then
    quickshell msg launcher toggle
else
    # X11: separate launcher process
    quickshell -p ~/.dotfiles/quickshell/launcher msg launcher toggle
fi
