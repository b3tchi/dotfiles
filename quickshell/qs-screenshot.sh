#!/bin/sh
# Region screenshot launcher — raises hotkeyd's "screenshot" layer, runs the
# live selector (qs-region.py), then clears the layer when it exits.
#
# Bound to $mod+Shift+s. The selector shapes its window down to a rubber-band
# outline over the LIVE desktop: no frozen grab, no dim, and no opaque
# fullscreen window, so there is no blink. Drag or tap two corners; `w` takes
# the whole screen; Esc / right-click cancels. The crop lands in
# ~/Pictures/screenshots AND the image itself goes on the clipboard
# (image/png) — Ctrl+V into an image-aware target pastes the picture
# directly. To annotate afterwards: `ksnip -e <saved file>`.
#
# The screen is captured AFTER the selection, so nothing is grabbed up front
# and a cancel captures nothing. That is why this no longer pre-scrots to
# QS_SHOT_SRC, and why the unscoped ${XDG_RUNTIME_DIR}/qs-shot-src handoff is
# gone — it was shared by every display and clobbered across sessions
# (dotfiles-8xt).
#
# The "screenshot" LAYER exists ONLY so the bar paints its hint strip (Bar.qml
# modeHints) and qs-focus-border.py reddens the ring. It binds no keys and
# holds no grabs — the keys are handled inside the selector, which holds a
# pointer+keyboard grab of its own. That is also why we do NOT exec: the layer
# must be cleared once the selector exits, so this script has to outlive it.
#
# It was an i3 MODE until sp024 (`i3-msg mode screenshot` against a real
# `mode "screenshot" {}` block). One channel now, hotkeyd's, for both phases
# of the gesture — see the cleanup comment near the bottom.
#
# KNOWN LIMITATION, accepted at sp024: with the daemon unreachable (panic
# config linked, sway session, hotkeyd dead) the raise fails under `|| true`
# and NOTHING paints — no hint strip, no red ring, because no i3 mode exists
# to paint them either any more. The capture itself is unaffected: the
# selector's own seat grab owns the keys in-process. Pixels, never keys.
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

# CLAIM THE LAYER (dotfiles-b3d4). The kill above replaces the previous
# SELECTOR, but the previous LAUNCHER outlives it by design (see the no-exec
# note in the header) and would then run its unconditional clear at the bottom
# — wiping the layer THIS launch is about to raise. Two overlapping launches
# therefore flickered the strip and ring in and out.
#
# A pid token settles who owns the layer: the newest launch writes its own pid
# here, and only the launcher still named by the token clears on exit. An
# older, superseded launcher reads a pid that is not its own and declines. No
# extra kill is involved — widening qs_kill_session to match this script would
# match THIS process too, and pgrep-based self-slaughter is exactly the class
# of guard that goes wrong quietly.
#
# Session-scoped like every other runtime file here ($QS_SID, dotfiles-8xt), so
# native :0 and xrdp :10 never share a token. A crashed launcher leaves a stale
# token, which is harmless: the next launch overwrites it unconditionally.
QS_SHOT_OWNER="${XDG_RUNTIME_DIR:-/tmp}/qs-shot-owner.$QS_SID"
printf '%s\n' "$$" > "$QS_SHOT_OWNER" 2>/dev/null || true

# Raise the AIMING layer so the bar shows the hint strip and the focus ring
# goes red, then run the selector. Same spelling and the same `|| true`
# discipline as the clear at the bottom — see that comment for why both are
# load-bearing.
#
# The `wm_msg()` swaymsg/i3-msg shim that used to live here went with the i3
# mode (sp024): nothing in this script talks to the WM any more.
"$HOME/.dotfiles/hotkeyd/hotkeyd" set-layer screenshot >/dev/null 2>&1 || true

set +e
"$QS_DIR/qs-region.py" "$@"
status=$?
set -e

# Clear on EVERY exit path — capture, cancel, or crash. Without this the bar
# sits in "screenshot" forever, and the ring stays red.
#
# ONE call clears BOTH phases of the gesture (sp024). The selector raises a
# SECOND layer of its own, "screenshot-drag" (sp023), from its `_press` the
# moment a drag starts, and deliberately does NOT clear it — that process can
# be killed outright mid-drag, and this launcher is the one that outlives it.
# `set-layer default` clears whichever of the two is up: external -> external
# is a permitted transition and the clear does not name a layer, so no
# bookkeeping is needed here (pinned by internal/layer's
# TestExternalToExternalHandoff / "clear from second").
#
# Unconditional, on every path: clearing when nothing is set is an ok no-op
# (`set-layer default` exits 0 with nothing to clear), and a conditional clear
# would need drag state this script does not have.
#
# `|| true` under `set -e` is load-bearing TWICE over. The signal is cosmetic
# and the CAPTURE is what this script's exit status reports — a missing binary
# (unbuilt tree, exit 127), an absent daemon (exit 3) or a refusal (exit 1)
# must not turn a successful screenshot into a failed one, nor abort before
# the `exit "$status"` below.
#
# Spelled the same way qs-region.py spells it (and Bar.qml:304 before both):
# $HOME/.dotfiles/hotkeyd/hotkeyd, invoked directly with no wrapper script —
# sp023's "Consumer spawn discipline". ONE spelling across all three call
# sites of this signal (the raise above, this clear, and qs-region.py's drag
# raise), deliberately, rather than resolving the local ones through $QS_DIR.
#
# GUARDED BY THE OWNERSHIP TOKEN (dotfiles-b3d4). "Every exit path" still holds
# for the launcher that OWNS the layer; a superseded one skips the clear
# entirely, because the pid in the token is the newer launcher's and clearing
# here would strip the layer out from under a live selector. The owner removes
# the token as it clears, so the file never outlives the gesture it describes.
if [ "$(cat "$QS_SHOT_OWNER" 2>/dev/null || true)" = "$$" ]; then
    "$HOME/.dotfiles/hotkeyd/hotkeyd" set-layer default >/dev/null 2>&1 || true
    rm -f "$QS_SHOT_OWNER" 2>/dev/null || true
fi

exit "$status"
