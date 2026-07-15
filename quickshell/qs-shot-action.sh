#!/bin/sh
# i3 "screenshot" mode key actions (a PanelWindow layer can't reliably receive
# keys, so Esc/w are i3 mode bindings). Prefer IPC into the running region
# instance — the overlay then fades out and leaves the mode itself, exactly
# like the mouse actions, so every exit path looks the same:
#   cancel  — just discard.
#   whole   — save the whole frozen grab + copy its path to the clipboard.
if quickshell -p "$HOME/.dotfiles/quickshell/region" ipc call shot "$1" >/dev/null 2>&1; then
    exit 0
fi

# Fallback: no region instance answered (crashed / never started). Hard
# cleanup: kill any remnant, do the file work here, and reset the mode —
# without this a dead overlay would leave i3 stuck in the screenshot mode.
ptr="${XDG_RUNTIME_DIR:-/tmp}/qs-shot-src"
src="$(cat "$ptr" 2>/dev/null)"
pkill -f 'quickshell -p .*region' 2>/dev/null

case "$1" in
    whole)
        if [ -f "$src" ]; then
            dir="$HOME/Pictures/screenshots"
            mkdir -p "$dir"
            f="$dir/shot_$(date +%Y%m%d-%H%M%S).png"
            cp "$src" "$f" && printf %s "$f" | xclip -selection clipboard
        fi
        ;;
esac

rm -f "$src" "$ptr"
if [ -n "$SWAYSOCK" ]; then
    swaymsg mode default >/dev/null 2>&1
else
    i3-msg mode default >/dev/null 2>&1
fi
