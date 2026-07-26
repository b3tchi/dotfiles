#!/usr/bin/env bash
# test-nav-mode.sh — runtime suite for the i3 "nav" mode (dotfiles-5u6m).
#
# Same discipline as quickshell/test-*.sh: a private Xvfb, an i3 started on the
# REAL config.common with its own IPC socket, named scenarios, exit 1 on any
# failure. What it pins is behaviour that `i3 -C` cannot see — a config that
# parses clean can still bind the wrong action, or bind nothing at all because
# a keysym silently failed to translate.
#
# Isolation matters here: i3-msg with no `-s` resolves the socket of whatever
# i3 owns the X root atom, so an unsocketed harness would drive the developer's
# LIVE session (and really would put it into nav mode). Every call below passes
# -s "$I3SOCK", and the config sets `ipc-socket` to match.
#
# Windows are two `st` terminals identified by X11 window id, not title: st
# rewrites its own title from the shell prompt, so titles are not stable.
#
# Scope: what i3 itself does — focus bare, move with Ctrl, and the two `nop`
# binds that publish held-Shift to the bar as binding events (there is ONE mode;
# the nop signal replaced a twin mode that had to duplicate every movement bind
# so a missed release could not strand the session somewhere destructive).
# How the bar PAINTS that is quickshell/test-mode-bar.sh's job; the focus-frame
# recolour is asserted here because it needs a real WM.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
DPY="${NAV_TEST_DISPLAY:-:94}"
I3SOCK="$TMP/i3.sock"
PASS=0
FAIL=0

cleanup() {
  [ -n "${I3_PID:-}" ] && kill "$I3_PID" 2>/dev/null
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

scenario() { printf '\n[%s]\n' "$1"; }
assert_eq() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$3" "$2"
    FAIL=$((FAIL + 1))
  fi
}

for bin in Xvfb xdotool i3 i3-msg st python3; do
  command -v "$bin" >/dev/null || { echo "FATAL: $bin not found" >&2; exit 1; }
done

# $mod is set by the INCLUDING file in this repo's layering (ft003), so the
# harness supplies it exactly as i3/config and i3/config-xrdp do.
cat > "$TMP/harness.conf" <<CONFEOF
set \$mod Mod4
ipc-socket $I3SOCK
include $SCRIPT_DIR/config.common
CONFEOF

Xvfb "$DPY" -screen 0 1280x800x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 20); do [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break; sleep 0.5; done
[ -e "/tmp/.X11-unix/X${DPY#:}" ] || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

DISPLAY="$DPY" i3 -c "$TMP/harness.conf" >"$TMP/i3.log" 2>&1 &
I3_PID=$!
for _ in $(seq 1 20); do [ -S "$I3SOCK" ] && break; sleep 0.5; done
[ -S "$I3SOCK" ] || { echo "FATAL: harness i3 did not come up" >&2; tail -5 "$TMP/i3.log" >&2; exit 1; }
export DISPLAY="$DPY"

# A keysym that fails to translate is only ever an i3 LOG line — `i3 -C` exits
# clean and the bind is silently dropped. Catching it needs the running log.
scenario "config loads with no key-translation errors (a dropped bind is log-only)"
assert_eq "no 'Could not translate' lines in the i3 log" \
  "$(grep -c 'Could not translate' "$TMP/i3.log")" "0"

i3-msg -s "$I3SOCK" 'exec st' >/dev/null; sleep 1.5
i3-msg -s "$I3SOCK" 'exec st' >/dev/null; sleep 1.5

# Tiled leaves in tree order == left-to-right on screen.
ids() { i3-msg -s "$I3SOCK" -t get_tree | python3 -c '
import sys, json
out = []
def walk(n):
    if n.get("window") and not n.get("nodes"): out.append(str(n["window"]))
    for c in n.get("nodes", []): walk(c)
walk(json.load(sys.stdin)); print(" ".join(out))'; }
focused() { i3-msg -s "$I3SOCK" -t get_tree | python3 -c '
import sys, json
def f(n):
    if n.get("focused") and n.get("window"): return str(n["window"])
    for c in n.get("nodes", []) + n.get("floating_nodes", []):
        r = f(c)
        if r: return r
print(f(json.load(sys.stdin)) or "none")'; }
mode() { i3-msg -s "$I3SOCK" -t get_binding_state \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["name"])'; }

ORDER="$(ids)"; A="${ORDER%% *}"; B="${ORDER##* }"

scenario "fixture: two tiled windows, focus on the second"
assert_eq "tree order is A B" "$(ids)" "$A $B"
assert_eq "focus starts on B" "$(focused)" "$B"

scenario "\$mod+o enters nav (and nav is sticky — no modifier held from here on)"
xdotool key super+o; sleep 0.4
assert_eq "binding state" "$(mode)" "nav"

scenario "unshifted hjkl FOCUS"
xdotool key h; sleep 0.4
assert_eq "h focuses left -> A" "$(focused)" "$A"
xdotool key l; sleep 0.4
assert_eq "l focuses right -> B" "$(focused)" "$B"
assert_eq "layout untouched by focusing" "$(ids)" "$A $B"

scenario "Ctrl+hjkl MOVE the focused window"
xdotool key --clearmodifiers ctrl+h; sleep 0.5
assert_eq "Ctrl+h moves B left -> B A" "$(ids)" "$B $A"
assert_eq "focus follows the moved window" "$(focused)" "$B"

# THE indicator contract: pressing Ctrl ALONE — before any hjkl — must already
# emit a signal, because the cue answers "what will the next keystroke do".
# i3 emits a binding event for `nop` like any other command, argument included,
# so the bar learns it without the WM changing state at all.
scenario "Ctrl alone emits nop nav-move-on, releasing it emits nav-move-off"
xdotool keyup ctrl 2>/dev/null; sleep 0.3
xdotool key q; sleep 0.3; xdotool key super+o; sleep 0.4
NOP_LOG="$TMP/nops.log"
i3-msg -s "$I3SOCK" -t subscribe -m '["binding"]' > "$NOP_LOG" 2>&1 &
NOP_SUB=$!
sleep 0.8
LAYOUT_BEFORE="$(ids)"
xdotool keydown ctrl; sleep 0.5
MODE_WHILE_HELD="$(mode)"
xdotool keyup ctrl; sleep 0.5
kill "$NOP_SUB" 2>/dev/null; sleep 0.3
NOPS="$(python3 "$SCRIPT_DIR/test-events.py" "$NOP_LOG" "nop ")"
assert_eq "the down/up pair reached the bar's stream" \
  "$NOPS" "nop nav-move-on|nop nav-move-off"
# The WM does not change state for the indicator: no second mode to strand in,
# and nothing churns when a client re-synthesises the modifier per keystroke.
assert_eq "the mode never left nav while Ctrl was held" "$MODE_WHILE_HELD" "nav"
assert_eq "still nav after the release" "$(mode)" "nav"
assert_eq "nop moved no window" "$(ids)" "$LAYOUT_BEFORE"

scenario "after a move, unshifted keys go back to focusing (no sticky move)"
xdotool key l; sleep 0.4
LAYOUT_NOW="$(ids)"
xdotool key h; sleep 0.4
assert_eq "layout unchanged by focusing" "$(ids)" "$LAYOUT_NOW"

scenario "arrow keys mirror hjkl in both roles"
# Expectations are derived from the CURRENT order, not the fixture's: earlier
# scenarios legitimately reshuffle the pair, and hardcoding A/B here would make
# this scenario fail for the wrong reason whenever one of them is edited.
xdotool key --clearmodifiers l; sleep 0.4          # focus the right-hand one
ORDER_NOW="$(ids)"; RIGHT="${ORDER_NOW##* }"; LEFT="${ORDER_NOW%% *}"
xdotool key --clearmodifiers ctrl+Left; sleep 0.5
assert_eq "Ctrl+Left swapped the pair" "$(ids)" "$RIGHT $LEFT"
xdotool keyup ctrl 2>/dev/null; sleep 0.4
xdotool key --clearmodifiers Right; sleep 0.4
assert_eq "Right focuses the right-hand window" "$(focused)" "$LEFT"

# --- focus-frame colour (dotfiles-5u6m) -------------------------------------
#
# quickshell/qs-focus-border.py draws the focus ring and already follows i3
# mode events, so the "you are in a key-capturing mode" cue lives there rather
# than in a second overlay. It is asserted HERE because this is the only
# harness with a real i3 and real windows for it to draw around.
#
# The assertion is on actual PIXELS (adr0002 — UI observed through sh-visible
# effects): screenshot the root window and count the ring's colour. Skipped
# where the helper's GTK stack is unavailable rather than failing the suite.
if ! command -v import >/dev/null; then
  echo; echo "SKIP: focus-frame colour needs ImageMagick's import (not installed)"
elif ! python3 -c 'import gi' 2>/dev/null; then
  echo; echo "SKIP: focus-frame colour needs python-gobject (not installed)"
else
  ring_pixels() { # <hex-without-#> -> pixel count of that exact colour
    import -window root "$TMP/shot.png" 2>/dev/null
    convert "$TMP/shot.png" -format %c histogram:info:- 2>/dev/null \
      | grep -i "#$1" | awk '{print $1}' | tr -d ':' | head -1
  }
  # leave nav so the helper starts in the default-mode colour
  xdotool key q 2>/dev/null; sleep 0.3
  DISPLAY="$DPY" python3 -u "$SCRIPT_DIR/../quickshell/qs-focus-border.py" \
    >"$TMP/border.log" 2>&1 &
  BORDER_PID=$!
  sleep 2.5
  i3-msg -s "$I3SOCK" 'focus left' >/dev/null; sleep 1.2

  scenario "focus frame is the normal colour in the default mode"
  TEAL_DEFAULT="$(ring_pixels 16A085)"
  RED_DEFAULT="$(ring_pixels CB4B16)"
  assert_eq "teal ring pixels present" "$([ "${TEAL_DEFAULT:-0}" -gt 0 ] && echo yes || echo no)" "yes"
  assert_eq "no red ring pixels yet" "$([ "${RED_DEFAULT:-0}" -gt 0 ] && echo yes || echo no)" "no"

  scenario "entering nav repaints the SAME frame red — the standing 'keys are captured' cue"
  xdotool key super+o; sleep 1.5
  TEAL_NAV="$(ring_pixels 16A085)"
  RED_NAV="$(ring_pixels CB4B16)"
  assert_eq "red ring pixels present in nav" "$([ "${RED_NAV:-0}" -gt 0 ] && echo yes || echo no)" "yes"
  assert_eq "teal is gone (recoloured, not a second ring)" "$([ "${TEAL_NAV:-0}" -gt 0 ] && echo yes || echo no)" "no"

  scenario "holding Ctrl keeps it red — the signal must not repaint the frame"
  xdotool keydown ctrl; sleep 1.2
  RED_TWIN="$(ring_pixels CB4B16)"
  assert_eq "still red while Ctrl is held" "$([ "${RED_TWIN:-0}" -gt 0 ] && echo yes || echo no)" "yes"
  xdotool keyup ctrl; sleep 0.6

  scenario "leaving the mode restores the normal colour"
  xdotool key q; sleep 1.5
  TEAL_BACK="$(ring_pixels 16A085)"
  RED_BACK="$(ring_pixels CB4B16)"
  assert_eq "teal ring is back" "$([ "${TEAL_BACK:-0}" -gt 0 ] && echo yes || echo no)" "yes"
  assert_eq "no red left behind" "$([ "${RED_BACK:-0}" -gt 0 ] && echo yes || echo no)" "no"

  kill "$BORDER_PID" 2>/dev/null
  xdotool key super+o; sleep 0.4    # the exit scenarios below expect nav
fi

# Besides the explicit nop pair, the bar corroborates from the mods of ordinary
# action bindings: one that ran as Ctrl+hjkl proves the modifier was down for
# that keystroke even if a nop went missing. If i3 ever stopped reporting
# `mods`, or spelled ctrl differently, only this scenario — the one place a
# REAL i3 is asked — would notice.
scenario "i3's binding events report the mods it matched (the bar's corroborating signal)"
BIND_LOG="$TMP/bindings.log"
i3-msg -s "$I3SOCK" -t subscribe -m '["binding"]' > "$BIND_LOG" 2>&1 &
SUB_PID=$!
sleep 0.8
xdotool key h; sleep 0.4                       # bare    -> focus
xdotool key --clearmodifiers ctrl+j; sleep 0.4 # shifted -> move
kill "$SUB_PID" 2>/dev/null
sleep 0.3
# Concatenated JSON objects, one per event — decode them in sequence.
BIND_SUMMARY="$(python3 - "$BIND_LOG" <<'PY'
import sys, json
raw = open(sys.argv[1]).read().strip()
dec, i, out = json.JSONDecoder(), 0, []
while i < len(raw):
    obj, i = dec.raw_decode(raw, i)
    while i < len(raw) and raw[i] in ' \n\r\t':
        i += 1
    b = obj.get("binding")
    # bindcode binds (the Shift-keycode twin flips) report symbol null — they
    # are asserted by the mode scenarios above, and including them here would
    # pin xdotool's modifier-synthesis order rather than i3's mods reporting.
    if b and b.get("symbol"):
        out.append("%s:%s:%s" % (b.get("symbol"), ",".join(b.get("mods", [])), b.get("command")))
print("|".join(out))
PY
)"
assert_eq "bare h reports no mods, Ctrl+j reports mods=ctrl" \
  "$BIND_SUMMARY" "h::focus left|j:ctrl:move down"

scenario "q exits — including with Ctrl physically held down"
xdotool keydown ctrl; sleep 0.2
xdotool key --clearmodifiers q; sleep 0.4
assert_eq "Ctrl+q leaves nav" "$(mode)" "default"
xdotool keyup ctrl; sleep 0.2
BEFORE="$(focused)"
xdotool key h; sleep 0.4
assert_eq "bare h is inert once the mode is gone" "$(focused)" "$BEFORE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
