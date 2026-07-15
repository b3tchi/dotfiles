#!/bin/sh
# Region screenshot via the quickshell selector overlay (region/shell.qml).
# Bound to $mod+Shift+s. Grab-only: drag-select (or tap two corners) → the
# region is cropped to ~/Pictures/screenshots and its file PATH is copied to
# the clipboard (text, like tmux copy). A slim in-overlay strip confirms, then
# the overlay quits. No persistent process, no single-instance server.
#
# Freeze-frame: capture the WHOLE screen first, then the overlay shows that
# frozen PNG fullscreen to select on — works over xrdp with no compositor
# (a live translucent overlay renders black without one). The crop comes from
# this frozen source. To annotate afterwards: `ksnip -e <saved file>`.
#
# Over xrdp there's no GPU/GL — force the software scene graph or quickshell
# segfaults (same reason the RDP bar sets it).
[ -n "$XRDP_SESSION" ] && export QT_QUICK_BACKEND=software

# Forward the status bar's geometry (QS_BAR_*) from the bar quickshell on THIS
# display, so the overlay lifts its confirmation strip above the bar instead of
# behind it. Best effort — the overlay falls back to the i3 default height.
_dpynum=${DISPLAY#:}; _dpynum=${_dpynum%%.*}
for _p in $(pgrep -x quickshell 2>/dev/null); do
    _e=$(tr '\0' '\n' < "/proc/$_p/environ" 2>/dev/null) || continue
    printf '%s\n' "$_e" | grep -q '^QS_SHOT_SRC=' && continue   # skip region instances
    case "$(printf '%s\n' "$_e" | sed -n 's/^DISPLAY=//p' | head -1)" in
        ":$_dpynum"|":$_dpynum."*) ;; *) continue ;;
    esac
    for _v in QS_BAR_HEIGHT QS_BAR_INSET_BOTTOM QS_BAR_INSET_TOP QS_BAR_INSET_AUTO; do
        _val=$(printf '%s\n' "$_e" | sed -n "s/^${_v}=//p" | head -1)
        [ -n "$_val" ] && export "${_v}=${_val}"
    done
    break
done

tmp="$(mktemp --tmpdir qs-shot-XXXXXX.png)" || exit 1
# full-screen grab — non-interactive. scrot (~0.2s) instead of ImageMagick's
# `import` (~0.6s) so the overlay pops up promptly.
if ! scrot -o "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    exit 1
fi

# Remember the window focused right now, so the overlay can hand keyboard
# focus back to it on close (and let it repaint behind the overlay before we
# unmap — avoids a wallpaper flash). i3 '[id=N]' matches this X11 window id.
export QS_PREV_WIN="$(xdotool getactivewindow 2>/dev/null || true)"

export QS_SHOT_SRC="$tmp"
exec quickshell -p "$HOME/.dotfiles/quickshell/region"
