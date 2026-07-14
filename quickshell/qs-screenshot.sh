#!/bin/sh
# Region screenshot via the quickshell selector overlay (region/shell.qml).
# Bound to $mod+Shift+s. Grab-only: drag-select a rectangle → it's cropped to
# ~/Pictures/screenshots AND copied to the clipboard (image/png), then the
# overlay quits. No persistent process, no single-instance server.
#
# Freeze-frame: capture the WHOLE screen first, then the overlay shows that
# frozen PNG fullscreen to select on — works over xrdp with no compositor
# (a live translucent overlay renders black without one). The crop comes from
# this frozen source. To annotate afterwards: `ksnip -e <saved file>`.
#
# Over xrdp there's no GPU/GL — force the software scene graph or quickshell
# segfaults (same reason the RDP bar sets it).
[ -n "$XRDP_SESSION" ] && export QT_QUICK_BACKEND=software

tmp="$(mktemp --tmpdir qs-shot-XXXXXX.png)" || exit 1
# full-screen grab (root window) — non-interactive
if ! import -window root "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    notify-send 'Screenshot' 'Failed to grab screen' 2>/dev/null
    exit 1
fi

export QS_SHOT_SRC="$tmp"
exec quickshell -p "$HOME/.dotfiles/quickshell/region"
