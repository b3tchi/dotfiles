#!/bin/sh
# Quickshell bar startup — resolves I3SOCK and XDG_RUNTIME_DIR
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null

# Resolve I3SOCK if available and not set
if [ -n "$SWAYSOCK" ]; then
    : # Sway — SWAYSOCK already set by sway
elif [ -z "$I3SOCK" ] && command -v i3 >/dev/null 2>&1; then
    export I3SOCK="$(i3 --get-socketpath 2>/dev/null)"
fi

exec quickshell
