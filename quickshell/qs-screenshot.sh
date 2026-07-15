#!/bin/sh
# Region screenshot launcher — enters the i3 "screenshot" mode, runs the live
# selector (qs-region.py), then resets the mode when it exits.
#
# Bound to $mod+Shift+s. The selector shapes its window down to a rubber-band
# outline over the LIVE desktop: no frozen grab, no dim, and no opaque
# fullscreen window, so there is no blink. Drag or tap two corners; `w` takes
# the whole screen; Esc / right-click cancels. The crop lands in
# ~/Pictures/screenshots and its file PATH goes on the clipboard (text, like a
# tmux copy). To annotate afterwards: `ksnip -e <saved file>`.
#
# The screen is captured AFTER the selection, so nothing is grabbed up front
# and a cancel captures nothing. That is why this no longer pre-scrots to
# QS_SHOT_SRC, and why the unscoped ${XDG_RUNTIME_DIR}/qs-shot-src handoff is
# gone — it was shared by every display and clobbered across sessions
# (dotfiles-8xt).
#
# The i3 mode exists ONLY so the bar paints its hint strip (Bar.qml modeHints).
# The keys are handled inside the selector, which holds a pointer+keyboard
# grab. That is also why we do NOT exec: the mode must be reset once the
# selector exits, so this script has to outlive it.
set -eu

# Session scoping (QS_SID / qs_same_session / qs_kill_session). Sourced, never
# forked. Concurrent sessions of the same user (native :0, xrdp :10) must never
# kill or clobber each other — that is dotfiles-8xt, and re-deriving the display
# id by hand here is how the old script got it wrong.
QS_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
QS_SESSION_SH="$QS_DIR/qs-session.sh"

# Validate DISPLAY BEFORE sourcing the helper, not after: qs-session.sh probes
# `i3 --get-socketpath`, which fails without a display and — under `set -e` —
# kills this script silently, so a later check would never be reached. The
# script would still exit 1, but for the wrong reason and with no message.
# Do NOT fall back to :0 either: on a box running native :0 AND xrdp :10 that
# would fire the overlay onto the other session's screen.
if [ -z "${DISPLAY:-}" ]; then
    echo "qs-screenshot: DISPLAY is unset — refusing to guess" >&2
    exit 1
fi

if [ ! -r "$QS_SESSION_SH" ]; then
    echo "qs-screenshot: cannot read $QS_SESSION_SH — refusing to run unscoped" >&2
    exit 1
fi
# qs-session.sh dereferences $SWAYSOCK unguarded, so it aborts under `set -u`.
# Its other consumers (qs-start.sh, qs-overlay.sh) set no shell options, so this
# script is the first to hit it. Relax -u across the source only, rather than
# edit a shared helper from this task — filed as dotfiles-0ov.
set +u
. "$QS_SESSION_SH"
set -u

# MANDATORY. WSLg leaves a wayland-0 socket in XDG_RUNTIME_DIR and GTK
# auto-connects to it EVEN WITH WAYLAND_DISPLAY UNSET. The selector then maps
# onto an idle, invisible compositor: no error, no window on $DISPLAY, no
# events — and any measurement of it falsely passes. This cost hours in
# poc008; do not remove it because "WAYLAND_DISPLAY isn't set anyway".
GDK_BACKEND=x11
export GDK_BACKEND

# Already up on THIS display? Replace it rather than stack a second pointer
# grab. Scoped to our session: an overlay on another display is left alone.
qs_kill_session -f 'qs-region\.py'

wm_msg() {
    if [ -n "${SWAYSOCK:-}" ]; then swaymsg "$@"; else i3-msg "$@"; fi
}

# Enter the mode so the bar shows the hint strip, then run the selector.
wm_msg mode screenshot >/dev/null 2>&1 || true

set +e
"$QS_DIR/qs-region.py" "$@"
status=$?
set -e

# Reset the mode on EVERY exit path — capture, cancel, or crash. Without this
# the bar sits in "screenshot" forever (the dotfiles-ux1 failure class).
wm_msg mode default >/dev/null 2>&1 || true

exit "$status"
