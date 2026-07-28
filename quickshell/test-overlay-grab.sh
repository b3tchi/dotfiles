#!/bin/bash
# test-overlay-grab.sh — a HELD X passive grab must not dismiss a quickshell
# overlay, and a real focus change still must (dotfiles-hwds.31).
#
# THE BUG THIS PINS DOWN
#
#   $mod+v (clipboard picker) and $mod+n (notification browser) opened and
#   then dismissed themselves a few seconds later, for as long as hotkeyd was
#   running. It was not the binds (i3 dispatched them), not the scripts (rc
#   0), and not an overlay keyboard grab (there is no XGrabKeyboard anywhere
#   in quickshell — the overlays take FOCUS, not a grab).
#
#   It was this: ANY X client holding a per-chord PASSIVE grab — hotkeyd's
#   XIGrabKeycode set ([[ft011]]), i3's own binds, xbindkeys — puts the
#   server into an implicit ACTIVE grab for as long as the grabbed key is
#   HELD. X then sends `FocusOut(mode=NotifyGrab)` to whatever holds the
#   input focus, and Qt reports that window deactivated about 100 ms later.
#   The window never lost the input focus and `_NET_ACTIVE_WINDOW` never
#   moved; only the event routing changed. ClipHistory/NotifHistory used to
#   hide straight off Qt's `active` going false, so a held modifier killed
#   the overlay.
#
#   On the xrdp session that is every single $mod press: `i3wm.mod` is Mod1
#   there, and hotkeyd's nav layer grabs `Alt_L`/`Alt_R` — the very key you
#   hold to type any $mod chord.
#
# WHY THE HOLD DURATION IS THE POINT
#
#   The deactivation lasts exactly as long as the key is held (measured: a
#   2.5 s hold produced a 2.43 s deactivation, after which Qt re-activated
#   the window by itself). So no debounce/timeout can separate a grab from a
#   real focus change, and a test that held the key for only a few hundred ms
#   would pass against a naive debounce that does not actually fix this. The
#   hold below is deliberately LONGER than any plausible debounce.
#
# WHAT IS ACTUALLY OBSERVED
#
#   A real X server (Xvfb), a real i3 — needed because the fix asks the
#   WINDOW MANAGER who it considers active, and `xdotool getactivewindow`
#   refuses without a WM advertising `_NET_ACTIVE_WINDOW` — the real
#   ClipHistory.qml / NotifHistory.qml driven through their real IPC targets
#   and their real backing scripts, and a real XI2 passive grab taken with
#   the same `xinput_grab_keycode` call hotkeyd's XAdapter makes. Nothing
#   here is stubbed on the path under test; the assertion is whether the
#   overlay window is still mapped.
#
#   Both directions are asserted. "Survives a grab" alone would pass against
#   the trivial mutant that deletes focus-loss close entirely, so the
#   companion scenario checks that focusing another window still dismisses
#   the overlay.
#
# usage: quickshell/test-overlay-grab.sh
# env:   XVFB= XDOTOOL= QUICKSHELL= I3= TEST_DISPLAY=:97 HOLD_S=2.5
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QS_CLIP="$SCRIPT_DIR/qs-clip.sh"
QS_NOTIF="$SCRIPT_DIR/qs-notif.sh"

XVFB="${XVFB:-Xvfb}"
XDOTOOL="${XDOTOOL:-xdotool}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
I3BIN="${I3:-i3}"
DPY="${TEST_DISPLAY:-:97}"
HOLD_S="${HOLD_S:-2.5}"

# Short paths on purpose: quickshell's IPC socket and i3's IPC socket are
# both unix sockets, capped at 108 bytes of path.
TMP="/tmp/qs-ovg.$$"
RUN="$TMP/run"
ENTRY="$TMP/entry"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "anything but '$2'" "$3"; fi; }
scenario() { printf '\n[%s]\n' "$1"; }

cleanup() {
  [ -n "${GRAB_PID:-}" ] && kill "$GRAB_PID" 2>/dev/null
  [ -n "${PEER_PID:-}" ] && kill "$PEER_PID" 2>/dev/null
  [ -n "${QS_PID:-}" ]   && kill "$QS_PID"   2>/dev/null
  sleep 0.5
  [ -n "${I3_PID:-}" ]   && kill "$I3_PID"   2>/dev/null
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

for tool in "$XVFB" "$XDOTOOL" "$QUICKSHELL" "$I3BIN"; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (XVFB=/XDOTOOL=/QUICKSHELL=/I3= to override)" >&2; exit 1; }
done
python3 -c 'import Xlib.ext.xinput' 2>/dev/null \
  || { echo "FATAL: python-xlib with XInput is needed to hold the passive grab" >&2; exit 1; }
[ -r "$QS_CLIP" ]  || { echo "FATAL: $QS_CLIP not readable" >&2; exit 1; }
[ -r "$QS_NOTIF" ] || { echo "FATAL: $QS_NOTIF not readable" >&2; exit 1; }

mkdir -p "$TMP" "$RUN" "$ENTRY" "$TMP/cfg" "$TMP/data" "$TMP/cache"
chmod 700 "$RUN"

ISO=(XDG_CONFIG_HOME="$TMP/cfg" XDG_DATA_HOME="$TMP/data"
     XDG_CACHE_HOME="$TMP/cache" XDG_RUNTIME_DIR="$RUN"
     XDG_STATE_HOME="$TMP/state")

# --- the grab holder ----------------------------------------------------------
#
# hotkeyd's XAdapter.grab_key call, verbatim in shape: XIGrabKeycode against
# XIAllMasterDevices on the root window, async/async, owner_events true. It
# grabs and then just sleeps — a passive grab needs no event loop to keep the
# implicit active grab alive while the key is down, which is exactly why the
# daemon does not have to be doing anything for this to bite.
cat > "$TMP/holdgrab.py" <<'GRABEOF'
import sys, time
from Xlib import X, XK, display as xdisplay
from Xlib.ext import xinput

XI_ALL_MASTER_DEVICES = 1

d = xdisplay.Display(sys.argv[1])
d.xinput_query_version()
root = d.screen().root
code = d.keysym_to_keycode(XK.string_to_keysym(sys.argv[2]))
if not code:
    print("no keycode", file=sys.stderr, flush=True)
    raise SystemExit(1)
root.xinput_grab_keycode(
    XI_ALL_MASTER_DEVICES, X.CurrentTime, code,
    xinput.GrabModeAsync, xinput.GrabModeAsync, True,
    xinput.KeyPressMask | xinput.KeyReleaseMask, [0])
d.sync()
print("grabbed", flush=True)
time.sleep(float(sys.argv[3]))
GRABEOF

# --- X + i3 -------------------------------------------------------------------
#
# i3's ipc-socket is PINNED into the throwaway config: without it i3-msg (and
# anything else here) follows the caller's ambient $I3SOCK straight into the
# developer's real session.
XSOCK="$TMP/i3.sock"
cat > "$TMP/i3.conf" <<EOF
font pango:monospace 10
ipc-socket $XSOCK
default_border none
EOF

"$XVFB" "$DPY" -screen 0 1280x800x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 40); do [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break; sleep 0.25; done
[ -e "/tmp/.X11-unix/X${DPY#:}" ] || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }
sleep 0.5

DISPLAY="$DPY" "$I3BIN" -c "$TMP/i3.conf" >"$TMP/i3.log" 2>&1 &
I3_PID=$!
for i in $(seq 1 40); do [ -S "$XSOCK" ] && break; sleep 0.25; done
DISPLAY="$DPY" I3SOCK="$XSOCK" i3-msg -t get_version >/dev/null 2>&1 \
  || { echo "FATAL: i3 did not come up on $DPY" >&2; cat "$TMP/i3.log" >&2; exit 1; }

# A second REAL window to hand focus to in the "a real focus change still
# closes it" scenarios. No terminal emulator is guaranteed present on a host
# running these dotfiles, and i3's own `open` placeholder holds no X window
# (so it cannot become `_NET_ACTIVE_WINDOW`), which is exactly the property
# under test. python-xlib is already required by this suite for the grab, so
# the peer is a plain mapped top-level window with a known title.
cat > "$TMP/peer.py" <<'PEEREOF'
import sys, time
from Xlib import X, display as xdisplay

d = xdisplay.Display(sys.argv[1])
s = d.screen()
w = s.root.create_window(0, 0, 200, 120, 0, s.root_depth,
                         X.InputOutput, X.CopyFromParent,
                         background_pixel=s.black_pixel,
                         event_mask=X.StructureNotifyMask)
w.set_wm_name(sys.argv[2])
w.set_wm_class("grabpeer", "GrabPeer")
w.map()
d.sync()
print("mapped", flush=True)
while True:
    time.sleep(1)
PEEREOF

PEER_TITLE=grab-test-peer
DISPLAY="$DPY" python3 "$TMP/peer.py" "$DPY" "$PEER_TITLE" >"$TMP/peer.out" 2>&1 &
PEER_PID=$!
for i in $(seq 1 40); do
  grep -q mapped "$TMP/peer.out" 2>/dev/null && break
  sleep 0.25
done
grep -q mapped "$TMP/peer.out" 2>/dev/null \
  || { echo "FATAL: the peer window did not map" >&2; cat "$TMP/peer.out" >&2; exit 1; }
sleep 0.5
PEER_WID="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name "^$PEER_TITLE\$" | head -1)"
[ -n "$PEER_WID" ] || { echo "FATAL: the peer window is not searchable" >&2; exit 1; }

# --- the overlays -------------------------------------------------------------
ln -sf "$SCRIPT_DIR/config/ClipHistory.qml"  "$ENTRY/ClipHistory.qml"
ln -sf "$SCRIPT_DIR/config/NotifHistory.qml" "$ENTRY/NotifHistory.qml"
ln -sf "$SCRIPT_DIR/config/Common"           "$ENTRY/Common"
cat > "$ENTRY/shell.qml" <<'ENTRYEOF'
import Quickshell
ShellRoot {
    ClipHistory {}
    NotifHistory {}
}
ENTRYEOF

# One entry in each store so the lists are not empty (an empty list still
# opens a window, but a populated one is closer to the reported case).
mkdir -p "$RUN/clip-store/$DPY" "$TMP/state/qs-notif"
printf 'hello' > "$RUN/clip-store/$DPY/000001.clip"
printf '%s\t%s\t%s\nsummary\nbody\n' "$(date +%s)" normal test \
  > "$TMP/state/qs-notif/000001.notif"

env DISPLAY="$DPY" "${ISO[@]}" \
    QS_CLIP_SH="$QS_CLIP" QS_NOTIF_SH="$QS_NOTIF" \
    "$QUICKSHELL" -p "$ENTRY" >"$TMP/qs.log" 2>&1 &
QS_PID=$!
for i in $(seq 1 60); do
  n="$(env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$QS_PID" show 2>/dev/null \
       | grep -c -e 'cliphistory' -e 'notifhistory')"
  [ "${n:-0}" -ge 2 ] && { QS_UP=1; break; }
  sleep 0.5
done
[ -n "${QS_UP:-}" ] \
  || { echo "FATAL: overlays did not expose their IPC targets" >&2; tail -30 "$TMP/qs.log" >&2; exit 1; }

# --- helpers ------------------------------------------------------------------

mapped() { # <title> -> count of visible windows with that exact title
  env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name "^$1\$" 2>/dev/null | wc -l | tr -d ' '
}

open_overlay() { # <target> <title>
  env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$QS_PID" call "$1" open >/dev/null 2>&1
  local i
  for i in $(seq 1 40); do
    [ "$(mapped "$2")" -gt 0 ] && { sleep 0.6; return 0; }
    sleep 0.25
  done
  return 1
}

close_overlay() { # <target> <title>
  env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$QS_PID" call "$1" close >/dev/null 2>&1
  local i
  for i in $(seq 1 20); do
    [ "$(mapped "$2")" -eq 0 ] && return 0
    sleep 0.25
  done
  return 1
}

# Hold `Control_L` down for HOLD_S seconds with a passive grab registered on
# it by another client, and record whether <title> was still mapped DURING
# the hold. Deliberately NOT a command substitution: a subshell would swallow
# both the FATAL exit and the GRAB_PID bookkeeping.
HELD_COUNT=""
held_grab_over() { # <title> -> sets HELD_COUNT
  rm -f "$TMP/grab.out"
  env DISPLAY="$DPY" python3 "$TMP/holdgrab.py" "$DPY" Control_L \
      "$(awk -v h="$HOLD_S" 'BEGIN{print h + 3}')" >"$TMP/grab.out" 2>&1 &
  GRAB_PID=$!
  local i
  for i in $(seq 1 40); do
    grep -q grabbed "$TMP/grab.out" 2>/dev/null && break
    sleep 0.25
  done
  grep -q grabbed "$TMP/grab.out" 2>/dev/null \
    || { echo "FATAL: could not take the passive grab" >&2; cat "$TMP/grab.out" >&2; exit 1; }
  env DISPLAY="$DPY" "$XDOTOOL" keydown ctrl 2>/dev/null
  sleep "$HOLD_S"
  HELD_COUNT="$(mapped "$1")"
  env DISPLAY="$DPY" "$XDOTOOL" keyup ctrl 2>/dev/null
  kill "$GRAB_PID" 2>/dev/null; GRAB_PID=""
  wait "$GRAB_PID" 2>/dev/null
  sleep 0.5
}

# Move the window manager's focus to the peer window — a REAL focus change,
# which moves _NET_ACTIVE_WINDOW, the thing a grab never touches.
focus_peer() {
  env DISPLAY="$DPY" "$XDOTOOL" windowactivate "$PEER_WID" 2>/dev/null
  sleep 0.3
}

closed_within() { # <title> -> "1" if it went away, "0" if it did not
  local i
  for i in $(seq 1 24); do
    [ "$(mapped "$1")" -eq 0 ] && { printf '1'; return; }
    sleep 0.25
  done
  printf '0'
}

# ============================================================================
# PHASE 0 — the `active-window` verb both overlays ask
# ============================================================================
#
# Exit code IS the contract, and the failure direction is the whole point: a
# verb that cannot tell must say so (1) rather than report "nobody", because
# the caller hides on "somebody else" and a false "somebody else" is exactly
# the self-dismissing overlay this suite exists to prevent.

scenario "active-window: reports the title the window manager considers active"
close_overlay cliphistory qs-clip >/dev/null 2>&1
open_overlay cliphistory qs-clip || { echo "FATAL: qs-clip did not open" >&2; exit 1; }
WID="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' | head -1)"
env DISPLAY="$DPY" "$XDOTOOL" windowactivate "$WID" 2>/dev/null
sleep 0.5
out="$(env DISPLAY="$DPY" "${ISO[@]}" sh "$QS_CLIP" active-window 2>/dev/null)"; rc=$?
assert_eq "exits 0 when the answer is known" "0" "$rc"
assert_eq "and names the active window" "qs-clip" "$out"

scenario "active-window: says 'cannot tell' rather than 'nobody' when it has no display"
out="$(env -u DISPLAY "${ISO[@]}" sh "$QS_CLIP" active-window 2>/dev/null)"; rc=$?
assert_eq "exits non-zero" "1" "$rc"
assert_eq "and prints nothing" "" "$out"
out="$(env -u DISPLAY "${ISO[@]}" sh "$QS_NOTIF" active-window 2>/dev/null)"; rc=$?
assert_eq "qs-notif.sh agrees" "1" "$rc"

# ============================================================================
# PHASE 1 — a HELD passive grab must not dismiss the overlay
# ============================================================================

scenario "clip picker: survives a ${HOLD_S}s held passive grab (dotfiles-hwds.31)"
assert_eq "the picker is up before the grab" "1" "$(mapped qs-clip)"
held_grab_over qs-clip
assert_eq "and still up while the grabbed key is held" "1" "$HELD_COUNT"
assert_eq "and after it is released" "1" "$(mapped qs-clip)"

scenario "notif browser: survives a ${HOLD_S}s held passive grab (dotfiles-hwds.31)"
close_overlay cliphistory qs-clip
open_overlay notifhistory qs-notif || { echo "FATAL: qs-notif did not open" >&2; exit 1; }
WID="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-notif$' | head -1)"
env DISPLAY="$DPY" "$XDOTOOL" windowactivate "$WID" 2>/dev/null
sleep 0.5
assert_eq "the browser is up before the grab" "1" "$(mapped qs-notif)"
held_grab_over qs-notif
assert_eq "and still up while the grabbed key is held" "1" "$HELD_COUNT"
assert_eq "and after it is released" "1" "$(mapped qs-notif)"

# ============================================================================
# PHASE 2 — a REAL focus change must still dismiss the overlay
# ============================================================================
#
# Without this, deleting focus-loss close outright would pass PHASE 1 — so
# this is the scenario that keeps the fix a DISCRIMINATOR rather than an
# opt-out. Focus moves to the peer window, which moves _NET_ACTIVE_WINDOW,
# the thing a grab does not touch.

scenario "notif browser: a real focus change still closes it"
focus_peer
assert_eq "the browser closed itself" "1" "$(closed_within qs-notif)"

scenario "clip picker: a real focus change still closes it"
open_overlay cliphistory qs-clip || { echo "FATAL: qs-clip did not reopen" >&2; exit 1; }
WID="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-clip$' | head -1)"
env DISPLAY="$DPY" "$XDOTOOL" windowactivate "$WID" 2>/dev/null
sleep 0.6
assert_eq "the picker is up first" "1" "$(mapped qs-clip)"
focus_peer
assert_eq "the picker closed itself" "1" "$(closed_within qs-clip)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
