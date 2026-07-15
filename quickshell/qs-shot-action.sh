#!/bin/sh
# i3 "screenshot" mode key actions (a PanelWindow layer can't reliably receive
# keys, so Esc/w are i3 mode bindings). Reads the frozen grab path that
# qs-screenshot.sh recorded, dismisses the selector overlay, and:
#   cancel  — just discard.
#   whole   — save the whole frozen grab + copy its path to the clipboard.
# The i3 mode itself is exited by the binding (`mode default`) before this runs.
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
