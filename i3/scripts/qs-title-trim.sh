#!/bin/sh
# Trim long PrusaSlicer titles: "*file - PrusaSlicer-2.8.1 based on Slic3r" → "*file - PrusaSlicer"

trim_all() {
    for wid in $(xdotool search --class PrusaSlicer 2>/dev/null); do
        title=$(xdotool getwindowname "$wid" 2>/dev/null)
        case "$title" in
            *" - PrusaSlicer-"*)
                short="${title%% - PrusaSlicer-*} - PrusaSlicer"
                xdotool set_window --name "$short" "$wid" 2>/dev/null
                ;;
        esac
    done
}

# Trim existing windows
trim_all

# Watch for window events and re-trim
i3-msg -t subscribe -m '["window"]' | while read -r _; do
    trim_all
done
