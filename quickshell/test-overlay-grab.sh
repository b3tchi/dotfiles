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
CONFIG_DIR="$SCRIPT_DIR/config"          # the SHIPPED config, shell.qml and all

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
  [ -n "${LOADQS_PID:-}" ] && kill "$LOADQS_PID" 2>/dev/null
  [ -n "${LOADX_PID:-}" ]  && kill "$LOADX_PID"  2>/dev/null
  [ -n "${GRAB_PID:-}" ] && kill "$GRAB_PID" 2>/dev/null
  [ -n "${PEER_PID:-}" ] && kill "$PEER_PID" 2>/dev/null
  [ -n "${QS2_PID:-}" ]  && kill "$QS2_PID"  2>/dev/null
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

# ============================================================================
# PHASE -1 — the SHIPPED shell.qml must still load these components
# ============================================================================
#
# THIS PHASE EXISTS BECAUSE EVERY OTHER PHASE MISSED A TOTAL OUTAGE. An
# earlier revision of this suite reported 14 passed / 0 failed, and an
# independent auditor reproduced 14/0, while the real shell put up
#
#     Failed to load configuration
#       caused by @shell.qml[40:5]: NotifHistory is not a type
#
# and both overlays were simply gone — strictly worse than the bug being
# fixed. The reason the suite could not see it: every phase below hosts the
# components from a THROWAWAY shell.qml written by this script, which proves
# the components work when this file instantiates them and proves nothing
# about whether config/shell.qml can. A QML suite that never loads the real
# entry point will hide that class of failure every single time.
#
# So this phase loads `config/shell.qml` ITSELF — the shipped file, hosting
# the shipped components the shipped way — and fails on any load error. It
# runs FIRST, and on its own short-lived X server, because a component that
# does not compile makes every assertion after it meaningless, and because
# the real shell.qml brings up bars and focus helpers that would otherwise
# contaminate the windows the later phases count.
#
# The config tree is COPIED, never run in place: quickshell watches its
# config directory and hot-reloads, and this suite must never be able to
# perturb a developer's live session.

LOAD_DPY="${LOAD_DISPLAY:-:$(( ${DPY#:} + 1 ))}"
LOAD_CFG="$TMP/shipped-config"

scenario "the SHIPPED config/shell.qml loads with these components"
if [ ! -r "$CONFIG_DIR/shell.qml" ]; then
  fail "config/shell.qml is readable" "readable" "missing at $CONFIG_DIR"
else
  python3 - "$CONFIG_DIR" "$LOAD_CFG" <<'CFGEOF'
import shutil, sys
# symlinks=False: resolve Common/ and anything else into real files, so the
# copy is self-contained and nothing points back at the repo.
shutil.copytree(sys.argv[1], sys.argv[2], symlinks=False)
CFGEOF

  "$XVFB" "$LOAD_DPY" -screen 0 1280x800x24 >"$TMP/xvfb-load.log" 2>&1 &
  LOADX_PID=$!
  for i in $(seq 1 40); do [ -e "/tmp/.X11-unix/X${LOAD_DPY#:}" ] && break; sleep 0.25; done
  sleep 0.5

  env DISPLAY="$LOAD_DPY" "${ISO[@]}" \
      QS_CLIP_SH="$QS_CLIP" QS_NOTIF_SH="$QS_NOTIF" \
      "$QUICKSHELL" -p "$LOAD_CFG" >"$TMP/load.log" 2>&1 &
  LOADQS_PID=$!
  for i in $(seq 1 60); do
    grep -qa -e "Configuration Loaded" -e "Failed to load configuration" \
      "$TMP/load.log" 2>/dev/null && break
    sleep 0.25
  done
  sleep 1

  loaded=0
  grep -qa "Configuration Loaded" "$TMP/load.log" 2>/dev/null && loaded=1
  # An error anywhere in the load beats a "Configuration Loaded" that may have
  # been printed for an earlier, partial pass.
  grep -qa -e "Failed to load configuration" -e "is not a type" \
           -e "unavailable" "$TMP/load.log" 2>/dev/null && loaded=0

  assert_eq "quickshell loaded the shipped shell.qml" "1" "$loaded"
  assert_eq "and reported no component-load error" "" \
    "$(grep -oa -e 'is not a type' -e 'Failed to load configuration' \
         -e 'Type [A-Za-z]* unavailable' "$TMP/load.log" 2>/dev/null | head -1)"
  [ "$loaded" -eq 1 ] || { echo "--- load log ---" >&2; cat "$TMP/load.log" >&2; }

  kill "$LOADQS_PID" 2>/dev/null; LOADQS_PID=""
  sleep 0.5
  kill "$LOADX_PID" 2>/dev/null; LOADX_PID=""
  sleep 0.3
fi

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

# --- a SECOND instance whose `active-window` cannot answer ---------------------
#
# PHASE 1.5 needs overlays wired to a backend that returns the "cannot tell"
# exit code. The overlays read QS_CLIP_SH / QS_NOTIF_SH once, at construction,
# so this has to be a separate quickshell instance rather than an env flip —
# and a separate entry DIRECTORY, because quickshell derives an instance id
# from the config path.
#
# The wrappers forward every verb verbatim and fail ONLY `active-window`, so
# the overlay is fully functional (it lists, it opens, it closes on Escape)
# and differs from the shipped one in exactly the one dimension under test.
cat > "$TMP/clip-noanswer.sh" <<WRAPEOF
#!/bin/sh
# Forwards everything; \`active-window\` exits 1 = "cannot tell".
[ "\${1:-}" = active-window ] && exit 1
exec sh "$QS_CLIP" "\$@"
WRAPEOF
cat > "$TMP/notif-noanswer.sh" <<WRAPEOF
#!/bin/sh
[ "\${1:-}" = active-window ] && exit 1
exec sh "$QS_NOTIF" "\$@"
WRAPEOF
chmod +x "$TMP/clip-noanswer.sh" "$TMP/notif-noanswer.sh"

ENTRY2="$TMP/entry2"
mkdir -p "$ENTRY2"
ln -sf "$SCRIPT_DIR/config/ClipHistory.qml"  "$ENTRY2/ClipHistory.qml"
ln -sf "$SCRIPT_DIR/config/NotifHistory.qml" "$ENTRY2/NotifHistory.qml"
ln -sf "$SCRIPT_DIR/config/Common"           "$ENTRY2/Common"
python3 - "$ENTRY/shell.qml" "$ENTRY2/shell.qml" <<'CPEOF'
import shutil, sys
shutil.copyfile(sys.argv[1], sys.argv[2])
CPEOF

env DISPLAY="$DPY" "${ISO[@]}" \
    QS_CLIP_SH="$TMP/clip-noanswer.sh" QS_NOTIF_SH="$TMP/notif-noanswer.sh" \
    "$QUICKSHELL" -p "$ENTRY2" >"$TMP/qs2.log" 2>&1 &
QS2_PID=$!
for i in $(seq 1 60); do
  n="$(env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$QS2_PID" show 2>/dev/null \
       | grep -c -e 'cliphistory' -e 'notifhistory')"
  [ "${n:-0}" -ge 2 ] && { QS2_UP=1; break; }
  sleep 0.5
done
[ -n "${QS2_UP:-}" ] \
  || { echo "FATAL: the cannot-tell instance did not come up" >&2; tail -30 "$TMP/qs2.log" >&2; exit 1; }

# --- helpers ------------------------------------------------------------------

mapped() { # <title> -> count of visible windows with that exact title
  env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name "^$1\$" 2>/dev/null | wc -l | tr -d ' '
}

open_overlay() { # <target> <title> [instance-pid]
  local pid="${3:-$QS_PID}"
  env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$pid" call "$1" open >/dev/null 2>&1
  local i
  for i in $(seq 1 40); do
    [ "$(mapped "$2")" -gt 0 ] && { sleep 0.6; return 0; }
    sleep 0.25
  done
  return 1
}

close_overlay() { # <target> <title> [instance-pid]
  local pid="${3:-$QS_PID}"
  env "${ISO[@]}" "$QUICKSHELL" ipc --pid "$pid" call "$1" close >/dev/null 2>&1
  local i
  for i in $(seq 1 20); do
    [ "$(mapped "$2")" -eq 0 ] && return 0
    sleep 0.25
  done
  return 1
}

# Give <title> the window manager's focus and PROVE it took: without real
# focus no FocusOut(NotifyGrab) is ever delivered, the probe never arms, and
# every grab-survival assertion below would pass vacuously. This guard is why
# the suite needs a real i3 rather than a bare Xvfb.
activate_and_prove() { # <title> -> "0" on success, else a diagnostic string
  local wid
  wid="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name "^$1\$" | head -1)"
  [ -n "$wid" ] || { printf 'no window titled %s' "$1"; return; }
  env DISPLAY="$DPY" "$XDOTOOL" windowactivate "$wid" 2>/dev/null
  sleep 0.6
  local seen rc
  seen="$(env DISPLAY="$DPY" "${ISO[@]}" sh "$QS_CLIP" active-window 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || [ "$seen" != "$1" ]; then
    printf 'wm reports active=%s rc=%s' "${seen:-<none>}" "$rc"
    return
  fi
  printf '0'
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
# PHASE 1.5 — "cannot tell" must FAIL CLOSED, in the QML
# ============================================================================
#
# PHASE 0 pins the SHELL half of the exit-code contract: the verb reports 1
# rather than "nobody" when it cannot answer. That is only half a contract.
# The other half lives in one line of each overlay — the `if (exitCode !== 0)`
# branch that stops "cannot tell" from reading as "somebody else has focus" —
# and nothing above exercises it, because everything above runs on a display
# where the verb CAN answer.
#
# Mutating that branch to hide anyway leaves PHASE 0/1/2 fully green while
# reproducing the original bug byte for byte on any display whose
# `active-window` cannot answer (no window manager advertising
# _NET_ACTIVE_WINDOW, no xdotool installed, the active window destroyed
# between the two reads). So it is shipped, load-bearing, and — until this
# phase — undefended.
#
# The overlays here are a SECOND instance wired to a backend that forwards
# every verb except `active-window`, which exits 1. Everything else about
# them is the shipped code path.
#
# THE TRAP THIS PHASE MUST NOT FALL INTO: on a display with no window manager
# the overlay never gains focus, so X never sends FocusOut(NotifyGrab), so the
# probe never arms and the assertion passes for the wrong reason. That is why
# this suite runs a real i3, and why `activate_and_prove` asserts the WM
# really considers the overlay active BEFORE the grab is taken — that guard is
# what makes the survival assertion mean something.

scenario "clip picker: a backend that CANNOT answer must not dismiss it (fail closed)"
close_overlay cliphistory qs-clip
close_overlay notifhistory qs-notif
open_overlay cliphistory qs-clip "$QS2_PID" \
  || { echo "FATAL: the cannot-tell picker did not open" >&2; exit 1; }
assert_eq "the window manager really has it focused (not a vacuous pass)" \
  "0" "$(activate_and_prove qs-clip)"
assert_eq "the backend really cannot answer" "1" \
  "$(env DISPLAY="$DPY" "${ISO[@]}" sh "$TMP/clip-noanswer.sh" active-window >/dev/null 2>&1; echo $?)"
held_grab_over qs-clip
assert_eq "still up while the grabbed key is held" "1" "$HELD_COUNT"
assert_eq "and after it is released" "1" "$(mapped qs-clip)"
close_overlay cliphistory qs-clip "$QS2_PID"

scenario "notif browser: a backend that CANNOT answer must not dismiss it (fail closed)"
open_overlay notifhistory qs-notif "$QS2_PID" \
  || { echo "FATAL: the cannot-tell browser did not open" >&2; exit 1; }
assert_eq "the window manager really has it focused (not a vacuous pass)" \
  "0" "$(activate_and_prove qs-notif)"
assert_eq "the backend really cannot answer" "1" \
  "$(env DISPLAY="$DPY" "${ISO[@]}" sh "$TMP/notif-noanswer.sh" active-window >/dev/null 2>&1; echo $?)"
held_grab_over qs-notif
assert_eq "still up while the grabbed key is held" "1" "$HELD_COUNT"
assert_eq "and after it is released" "1" "$(mapped qs-notif)"
close_overlay notifhistory qs-notif "$QS2_PID"

# ============================================================================
# PHASE 2 — a REAL focus change must still dismiss the overlay
# ============================================================================
#
# Without this, deleting focus-loss close outright would pass PHASE 1 — so
# this is the scenario that keeps the fix a DISCRIMINATOR rather than an
# opt-out. Focus moves to the peer window, which moves _NET_ACTIVE_WINDOW,
# the thing a grab does not touch.

scenario "notif browser: a real focus change still closes it"
open_overlay notifhistory qs-notif || { echo "FATAL: qs-notif did not reopen" >&2; exit 1; }
assert_eq "the browser is up and focused first" "0" "$(activate_and_prove qs-notif)"
focus_peer
assert_eq "the browser closed itself" "1" "$(closed_within qs-notif)"

scenario "clip picker: a real focus change still closes it"
open_overlay cliphistory qs-clip || { echo "FATAL: qs-clip did not reopen" >&2; exit 1; }
assert_eq "the picker is up and focused first" "0" "$(activate_and_prove qs-clip)"
focus_peer
assert_eq "the picker closed itself" "1" "$(closed_within qs-clip)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
