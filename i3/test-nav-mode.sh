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
# The held-Shift INDICATOR is not tested here — it lives in the bar and is
# covered by quickshell/test-mode-bar.sh (nav / nav MOVE pill scenarios). This
# suite covers what i3 itself does: focus unshifted, move shifted, one mode.
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

scenario "Shift+hjkl MOVE the focused window, without leaving the mode"
xdotool key --clearmodifiers shift+h; sleep 0.5
assert_eq "Shift+h moves B left -> B A" "$(ids)" "$B $A"
assert_eq "focus follows the moved window" "$(focused)" "$B"
# Single-mode design (the Shift indicator is the bar's job): i3 must NOT flip
# into a second binding state, or the pill and the binds would disagree.
assert_eq "still in nav — Shift did not change the mode" "$(mode)" "nav"

scenario "after a move, unshifted keys go back to focusing (no sticky move)"
xdotool key l; sleep 0.4
assert_eq "l focuses A" "$(focused)" "$A"
assert_eq "layout unchanged by focus" "$(ids)" "$B $A"

scenario "arrow keys mirror hjkl in both roles"
xdotool key --clearmodifiers shift+Left; sleep 0.5
assert_eq "Shift+Left moves A left -> A B" "$(ids)" "$A $B"
xdotool key Right; sleep 0.4
assert_eq "Right focuses B" "$(focused)" "$B"

# The bar's Shift indicator is driven ENTIRELY by these events (quickshell
# Bar.qml noteBinding + test-mode-bar.sh, which replays this exact payload
# shape through a stubbed i3-msg). If i3 ever stopped reporting `mods`, or
# spelled Shift differently, the indicator would go dark and only this
# scenario — the one place a REAL i3 is asked — would notice.
scenario "i3's binding events report the mods it matched (the bar's only Shift signal)"
BIND_LOG="$TMP/bindings.log"
i3-msg -s "$I3SOCK" -t subscribe -m '["binding"]' > "$BIND_LOG" 2>&1 &
SUB_PID=$!
sleep 0.8
xdotool key h; sleep 0.4                       # bare    -> focus
xdotool key --clearmodifiers shift+j; sleep 0.4 # shifted -> move
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
    if b:
        out.append("%s:%s:%s" % (b.get("symbol"), ",".join(b.get("mods", [])), b.get("command")))
print("|".join(out))
PY
)"
assert_eq "bare h reports no mods, Shift+j reports mods=shift" \
  "$BIND_SUMMARY" "h::focus left|j:shift:move down"

scenario "q exits — including with Shift physically held down"
xdotool keydown shift; sleep 0.2
xdotool key --clearmodifiers q; sleep 0.4
assert_eq "Shift+q leaves nav" "$(mode)" "default"
xdotool keyup shift; sleep 0.2
BEFORE="$(focused)"
xdotool key h; sleep 0.4
assert_eq "bare h is inert once the mode is gone" "$(focused)" "$BEFORE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
