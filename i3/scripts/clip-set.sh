#!/bin/sh
# clip-paste.sh — paste one copyq history row under the cursor (sp014 task 3).
#
# usage: clip-paste.sh <row>
#
#   <row>  copyq history index, 0 = newest. Digits only.
#
# CLI CONTRACT (task .4's quickshell picker invokes exactly this):
#
#   clip-paste.sh <row>
#     exit 0   entry is on CLIPBOARD+PRIMARY and the paste key was delivered
#              to the focused window
#     exit 1   nothing was pasted and NO selection was touched (bad row, no
#              focused window, empty entry, no usable display, missing tool)
#     stderr   one-line reason on failure; silent on success
#
#   The picked entry is deliberately LEFT on the clipboard afterwards — a
#   history pick is a copy as much as a paste, and the next ctrl-v should
#   repeat it. That is expected behaviour, not a leak of the picker's state.
#
# HOW IT PASTES, AND WHY NOT `xdotool type`
#
#   The entry is put on the X selections and then the *paste key* is
#   synthesized — we never retype the text. `xdotool type` walks the text
#   char by char, remapping the keyboard for characters the current layout
#   cannot reach: it mangles unicode/emoji, is agonizing for large entries,
#   and races the layout on non-qwerty keymaps (this is a dvorak desktop).
#   Synthesizing ctrl+v instead is one XTEST event whose payload is the X
#   selection, so the text arrives byte-exact regardless of layout, size, or
#   codepoint. `xdotool key` resolves the keysym against the *current* keymap,
#   so ctrl+v lands on dvorak's v key, not on qwerty's position.
#
# DISPLAY IS DERIVED, NEVER INHERITED
#
#   This script is fired from a picker that may have been started under a
#   different X server than the one the user is now looking at (native :0 vs
#   xrdp :10), and from long-lived parents whose DISPLAY went stale. An
#   inherited DISPLAY would set the wrong server's clipboard and send the key
#   into a session nobody is watching. So the display is resolved here: every
#   X socket under /tmp/.X11-unix is probed and the first one that actually
#   has a focused window is the session the user is in. Override with
#   CLIP_PASTE_DISPLAY=:N to pin one (used by the test harness).
#
# copyq is addressed as a plain `copyq read` per copyq/dot.yaml's client
# contract — no XDG_CONFIG_HOME juggling, or the socket path moves.
#
# Test: i3/scripts/test-clip-paste.sh (headless, Xvfb).
set -u

T=2                          # seconds before a single xclip call is abandoned
PROG="${0##*/}"

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }

# ------------------------------------------------------------------ args ---

[ $# -eq 1 ] || die "usage: $PROG <row>"
ROW="$1"
case "$ROW" in
  '' | *[!0-9]*) die "row must be a non-negative integer, got '$ROW'" ;;
esac

for tool in copyq xclip xdotool; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done

# --------------------------------------------------------------- display ---

# Id of the window holding input focus on display $1, or nonzero if there is
# none. i3 (EWMH) answers getactivewindow; a bare X server without a WM only
# answers getwindowfocus.
#
# "Nothing is focused" has TWO shapes and both must be rejected. If focus was
# never taken, X reports PointerRoot and xdotool errors out. But when the last
# focused client *exits*, focus reverts to its parent -- the ROOT window --
# and xdotool happily returns the root's id. Pasting into that means the
# clipboard is overwritten and a ctrl+v is fired into the desktop background,
# which is precisely the no-op-and-fail case. So the root id is fetched (a
# depth-0 search from root matches only root) and excluded.
focused_window() {
  _root="$(DISPLAY="$1" xdotool search --maxdepth 0 '' 2>/dev/null | head -1)"
  _win="$(DISPLAY="$1" xdotool getactivewindow 2>/dev/null \
          || DISPLAY="$1" xdotool getwindowfocus 2>/dev/null)" || return 1
  [ -n "$_win" ] || return 1
  [ -n "$_root" ] && [ "$_win" = "$_root" ] && return 1
  echo "$_win"
}

# Echo the display to act on. A caller-pinned CLIP_PASTE_DISPLAY is still
# probed -- pinning the wrong display should fail loudly, not paste blind.
derive_display() {
  candidates=""
  if [ -n "${CLIP_PASTE_DISPLAY:-}" ]; then
    candidates="$CLIP_PASTE_DISPLAY"
  else
    for sock in /tmp/.X11-unix/X*; do
      [ -e "$sock" ] || continue
      candidates="$candidates :${sock##*/tmp/.X11-unix/X}"
    done
  fi
  for dpy in $candidates; do
    if win="$(focused_window "$dpy")" && [ -n "$win" ]; then
      echo "$dpy $win"
      return 0
    fi
  done
  return 1
}

set -- $(derive_display) || true
DPY="${1:-}"
WIN="${2:-}"
[ -n "$DPY" ] && [ -n "$WIN" ] \
  || die "no focused window on any X display -- nothing to paste into"

# ----------------------------------------------------------------- entry ---

TMP="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$TMP"' EXIT

copyq read "$ROW" > "$TMP" 2>/dev/null || die "copyq read $ROW failed"
[ -s "$TMP" ] || die "history row $ROW is empty or does not exist"

# ------------------------------------------------------- class -> keystroke ---

# Terminals paste on ctrl+shift+v because ctrl+v is the terminal's own literal
# -next-character (^V); everything else is a plain ctrl+v. Matched on the
# window's class, lowercased, so WM_CLASS capitalisation does not matter.
# An unrecognised class falls through to ctrl+v -- GUI is the common case and
# a wrong ctrl+v in a terminal is a harmless ^V, while a wrong ctrl+shift+v in
# a GUI app is silently nothing.
keystroke_for_class() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    st | st-256color | xterm | uxterm | urxvt | rxvt* | wezterm | \
    org.wezfurlong.wezterm | alacritty | kitty | foot | footclient | \
    konsole | terminator | tilix | xfce4-terminal | gnome-terminal* | \
    ghostty | contour | qterminal | lxterminal | sakura | termite | \
    wezterm-gui)
      echo 'ctrl+shift+v' ;;
    *)
      echo 'ctrl+v' ;;
  esac
}

CLASS="$(DISPLAY="$DPY" xdotool getwindowclassname "$WIN" 2>/dev/null || true)"
KEY="$(keystroke_for_class "$CLASS")"

# --------------------------------------------------------- set selections ---

# Both selections: CLIPBOARD is what ctrl+v pastes, PRIMARY keeps
# middle-click and terminal-select behaviour consistent with the pick.
# xclip backgrounds itself as the selection owner and serves the entry for as
# long as it is asked to, so large entries transfer via INCR untouched.
for sel in clipboard primary; do
  timeout "$T" env DISPLAY="$DPY" xclip -selection "$sel" -i < "$TMP" \
    || die "could not set the $sel selection on $DPY"
done

# xclip forks before it owns the selection, so the key must not be sent until
# ownership is actually visible -- otherwise the paste requests the previous
# owner's contents. Compare a cheap prefix rather than the whole entry so a
# multi-megabyte pick does not pay for a full round trip here.
head -c 64 "$TMP" > "$TMP.head"
i=0
while [ "$i" -lt 40 ]; do
  if [ "$(timeout "$T" env DISPLAY="$DPY" xclip -selection clipboard -o \
          2>/dev/null | head -c 64 | cmp -s - "$TMP.head" && echo ok)" = ok ]; then
    break
  fi
  i=$((i + 1))
  sleep 0.05
done
rm -f "$TMP.head"
[ "$i" -lt 40 ] || die "clipboard ownership on $DPY did not settle"

# ------------------------------------------------------------ synth paste ---

# --clearmodifiers so a physically-held modifier (the picker was very likely
# dismissed with one down) cannot turn ctrl+v into ctrl+alt+v. XTEST, not
# --window: synthetic XSendEvent key events are ignored by most toolkits.
DISPLAY="$DPY" xdotool key --clearmodifiers "$KEY" \
  || die "could not synthesize $KEY on $DPY"
