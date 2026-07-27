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
# Scope: the nav layer's real effects — focus bare, move with Ctrl, resize with
# Alt — which are unchanged by the T6 cutover (sp020, dotfiles-zgs4). What
# changed underneath is the MECHANISM: the layer left i3 entirely and is now
# owned by hotkeyd, so this harness starts the daemon against its own display
# and reads layer state from the daemon's socket instead of i3's binding state.
#
# The point of re-pointing rather than rewriting: these assertions are about
# WINDOWS moving, and they must keep passing across a change of engine. Anything
# that only made sense for the i3 implementation (the `nop` marker-bind pairs,
# i3's binding-event mods) is gone with the implementation it described.
#
# How the bar PAINTS the layer is quickshell/test-mode-bar.sh's job.
#
# DEVIATION from sp020 Task 6's fifth criterion ("no `nop nav-` string remains
# anywhere in i3/ or quickshell/"): the i3/ half is done — this suite was the
# last holder and is now clean. The quickshell/ half is NOT, deliberately.
# Bar.qml still parses `nop nav-move-on/off` (config/Bar.qml noteBinding) and
# quickshell/test-mode-bar.sh still asserts that parsing. Deleting either now
# would break a green suite for a consumer whose cutover is T7's whole job
# (dotfiles-hwds.2), so the strings leave with the code that reads them, in T7 —
# together with qs-focus-border.py, the second consumer T7's file list missed
# (dotfiles-hwds.9). Until then those binds simply never fire, because i3 no
# longer has them to emit.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
DPY="${NAV_TEST_DISPLAY:-:94}"
I3SOCK="$TMP/i3.sock"
PASS=0
FAIL=0

cleanup() {
  [ -n "${HOTKEYD_PID:-}" ] && kill "$HOTKEYD_PID" 2>/dev/null
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

HOTKEYD_DIR="$SCRIPT_DIR/../hotkeyd"

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

# The daemon owns the nav layer now. Start it against THIS display with its own
# runtime dir, and point it at the harness i3 explicitly — HOTKEYD_I3SOCK is the
# one override the resolver trusts (dotfiles-hwds.6), precisely so a test can
# aim a daemon at a specific WM without the ambient environment deciding.
export XDG_RUNTIME_DIR="$TMP"
HOTKEYD_I3SOCK="$I3SOCK" DISPLAY="$DPY" \
  python3 "$HOTKEYD_DIR/hotkeyd.py" --display "$DPY" >"$TMP/hotkeyd.log" 2>&1 &
HOTKEYD_PID=$!
for _ in $(seq 1 20); do [ -S "$TMP/hotkeyd-${DPY#:}.sock" ] && break; sleep 0.3; done
[ -S "$TMP/hotkeyd-${DPY#:}.sock" ] || {
  echo "FATAL: hotkeyd did not come up on $DPY" >&2
  tail -5 "$TMP/hotkeyd.log" >&2; exit 1; }

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
# Layer state comes from the DAEMON now, not i3's binding state: i3 has no nav
# mode any more. Connecting replays the current state as the first line, which
# is what makes a one-shot read like this possible at all.
_state_field() { # <field>
  python3 - "$TMP/hotkeyd-${DPY#:}.sock" "$1" <<'PYEOF'
import json, socket, sys
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(2)
try:
    c.connect(sys.argv[1])
    buf = b""
    while b"\n" not in buf:
        chunk = c.recv(4096)
        if not chunk:
            break
        buf += chunk
finally:
    c.close()
if not buf.strip():
    print("none")
else:
    v = json.loads(buf.split(b"\n")[0]).get(sys.argv[2])
    print(v if v else ("default" if sys.argv[2] == "layer" else "none"))
PYEOF
}
mode() { _state_field layer; }
# The held modifier as the bar reads it: "move", "resize" or "none".
held_mod() { _state_field mod; }

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

# THE indicator contract, unchanged in meaning and much cheaper to keep: holding
# Ctrl ALONE — before any hjkl — must already publish the layer, because the cue
# answers "what will the next keystroke do". i3 needed SIX bindcode `nop` marker
# binds to fake this, since it cannot report a held modifier; the daemon sees the
# modifier directly and publishes {"layer":"nav","mod":"move"}.
scenario "Ctrl alone publishes the move layer, releasing it publishes back"
xdotool keyup ctrl 2>/dev/null; sleep 0.3
xdotool key q; sleep 0.3; xdotool key super+o; sleep 0.5
LAYOUT_BEFORE="$(ids)"
xdotool keydown ctrl; sleep 0.5
MOD_WHILE_HELD="$(held_mod)"
LAYER_WHILE_HELD="$(mode)"
xdotool keyup ctrl; sleep 0.5
MOD_AFTER="$(held_mod)"
assert_eq "held Ctrl publishes mod=move" "$MOD_WHILE_HELD" "move"
assert_eq "releasing it publishes mod=none" "$MOD_AFTER" "none"
# The layer itself never changes for the indicator: no second layer to strand
# in, and nothing churns when a client re-synthesises the modifier per keystroke.
assert_eq "the layer never left nav while Ctrl was held" "$LAYER_WHILE_HELD" "nav"
assert_eq "still nav after the release" "$(mode)" "nav"
assert_eq "the modifier alone moved no window" "$(ids)" "$LAYOUT_BEFORE"

# Width of the focused window, for the resize layer.
fwidth() { i3-msg -s "$I3SOCK" -t get_tree | python3 -c '
import sys, json
def f(n):
    if n.get("focused") and n.get("window"): return n["rect"]["width"]
    for c in n.get("nodes", []) + n.get("floating_nodes", []):
        r = f(c)
        if r: return r
print(f(json.load(sys.stdin)) or 0)'; }

scenario "ALT is a third layer: Alt+hjkl RESIZE, and the mode still never changes"
# The base config sets `workspace_layout tabbed`, where every window fills the
# tab area and a width resize is a silent no-op — the resize layer is only
# observable in a split container, so put the workspace in one first.
i3-msg -s "$I3SOCK" 'layout splith' >/dev/null; sleep 0.5
W_BEFORE="$(fwidth)"
LAYOUT_BEFORE="$(ids)"
xdotool key --clearmodifiers alt+l; sleep 0.5
W_WIDER="$(fwidth)"
[ "${W_WIDER:-0}" -gt "${W_BEFORE:-0}" ] \
  && assert_eq "Alt+l made the focused window wider" "wider" "wider" \
  || assert_eq "Alt+l made the focused window wider" "$W_BEFORE -> $W_WIDER" "wider"
xdotool key --clearmodifiers alt+h; sleep 0.5
assert_eq "Alt+h took the width back" "$(fwidth)" "$W_BEFORE"
assert_eq "resizing reordered nothing" "$(ids)" "$LAYOUT_BEFORE"
assert_eq "still one mode throughout" "$(mode)" "nav"

scenario "Alt alone publishes the resize layer, and moves/resizes nothing"
W_IDLE="$(fwidth)"
xdotool keydown alt; sleep 0.5
MOD_ALT="$(held_mod)"
xdotool keyup alt; sleep 0.5
assert_eq "held Alt publishes mod=resize" "$MOD_ALT" "resize"
assert_eq "releasing it publishes mod=none" "$(held_mod)" "none"
assert_eq "the modifier alone changed no geometry" "$(fwidth)" "$W_IDLE"

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
# SKIPPED PENDING dotfiles-hwds.9, and deliberately left in place rather than
# deleted: quickshell/qs-focus-border.py paints the red "keys are captured" ring
# off i3 MODE events (COLOR_MODES = {'nav'}), and the T6 cutover removed the i3
# nav mode those events came from. The ring is therefore stale-teal in nav until
# that helper is re-pointed at the daemon's state socket — the same cutover the
# bar gets in T7, on a second consumer sp020's task list did not name.
#
# These four scenarios assert real PIXELS (import + histogram) and are the only
# coverage of that cue, so they come back with hwds.9 rather than being rewritten
# into something weaker now.
echo
echo "SKIP: focus-frame colour scenarios — qs-focus-border.py still follows i3"
echo "      mode events, which the T6 cutover removed (dotfiles-hwds.9)"

# The old suite asserted i3's binding events reported the mods it matched — the
# bar's corroborating signal when a `nop` went missing. Both the signal and the
# thing it corroborated are gone: i3 has no nav binds to report, and the daemon
# publishes modifier state as state rather than as a side effect of a bind.
# What replaces it is the pair of scenarios above, which read that state
# directly, plus the daemon suite's own coverage of the guard that expires a
# hold whose release was lost (hotkeyd/test_layers.py).

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
