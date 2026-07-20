#!/usr/bin/env bash
# test-clip-paste.sh — verify i3/scripts/clip-paste.sh (dotfiles-92w.3).
#
# Runs entirely headless on its own Xvfb display with an isolated
# XDG_CONFIG_HOME, so it never touches the live X session, the live clipboard,
# or the real ~/.config/copyq.
#
# WHAT IS ACTUALLY OBSERVED (no "it exited 0" assertions)
#
#   The fixture `paste-target.py` is a real X client: it owns a window with a
#   settable WM_CLASS, takes input focus, and *implements paste* -- on a
#   ctrl+v / ctrl+shift+v KeyPress it converts the CLIPBOARD selection (INCR
#   included) and appends the received bytes to a buffer file, exactly as a
#   real editor would at its cursor.
#
#   So each end-to-end scenario asserts on effect, not on exit status:
#     - which modifier combo the *focused window* received (class -> keystroke)
#     - what text that window pulled out of the selection (== the copyq entry)
#     - what CLIPBOARD and PRIMARY hold afterwards
#
#   The one thing this cannot prove headlessly is caret placement inside a
#   third-party GUI -- "lands at cursor" is the pasting application's own
#   behaviour once the key arrives. What is proven is that the correct key
#   reaches the focused window and that the selection it reads is byte-exact.
#
# usage: i3/scripts/test-clip-paste.sh
# env:   COPYQ=/path/to/copyq  XVFB=/path/to/Xvfb   (default: from PATH)
#        TEST_DISPLAY=:93                           (default: :93)
#        CLIP_PASTE=/path/to/clip-paste.sh          (default: alongside this)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLIP_PASTE="${CLIP_PASTE:-$SCRIPT_DIR/clip-paste.sh}"
COPYQ="${COPYQ:-copyq}"
XVFB="${XVFB:-Xvfb}"
DPY="${TEST_DISPLAY:-:93}"

TMP="/tmp/clip-paste-test.$$"   # kept short: copyq's socket lives under $CFG
CFG="$TMP/cfg"
DAT="$TMP/data"
CCH="$TMP/cache"

PASS=0
FAIL=0

# ---------------------------------------------------------------- harness ---

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

assert_eq() { # <scenario> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

scenario() { printf '\n[%s]\n' "$1"; }

cleanup() {
  stop_target
  [ -n "${SERVER_STARTED:-}" ] && cq exit >/dev/null 2>&1
  sleep 1
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

cq() { env DISPLAY="$DPY" XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" \
           XDG_CACHE_HOME="$CCH" "$COPYQ" "$@"; }

# clip-paste.sh under test. XDG_* are exported for the *harness's* isolation
# (the script itself still calls a plain `copyq`, per copyq/dot.yaml's client
# contract). DISPLAY is deliberately exported WRONG -- an inherited DISPLAY
# must never be trusted, so the script has to derive the real one.
run_paste() { # <row> [extra env assignments...]
  env DISPLAY=:987 XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" \
      XDG_CACHE_HOME="$CCH" CLIP_PASTE_DISPLAY="$DPY" \
      sh "$CLIP_PASTE" "$@" 2>"$TMP/paste.err"
}

sel() { # <clipboard|primary>  -> current selection content on the test display
  env DISPLAY="$DPY" timeout 10 xclip -selection "$1" -o 2>/dev/null
}

# Take ownership of both selections away from anything the previous scenario
# left behind, so an assertion can never pass on a stale selection.
reset_selections() {
  printf 'SENTINEL-nothing-pasted' | env DISPLAY="$DPY" timeout 5 xclip -selection clipboard -i
  printf 'SENTINEL-nothing-pasted' | env DISPLAY="$DPY" timeout 5 xclip -selection primary -i
  sleep 0.5
}

# Block until the copyq history stops growing. Every clipboard write this
# harness makes (the sentinel reset, and the paste under test itself) is a
# genuine clipboard change that the running server captures and PREPENDS --
# so row numbers move under our feet unless we wait for capture to finish
# before deciding which row to address. (Getting this wrong is a silent
# wrong-row test, not an error.)
settle() {
  local prev="" n i
  for i in $(seq 1 40); do
    n="$(cq size 2>/dev/null)"
    [ -n "$n" ] && [ "$n" = "$prev" ] && return 0
    prev="$n"
    sleep 0.5
  done
}

# Clear the selections, let capture settle, then push <text...> onto the
# history so the LAST argument is row 0. `copyq add` does not touch the
# clipboard, so this cannot itself perturb the row numbering.
arm() {
  reset_selections
  settle
  local t
  for t in "$@"; do cq add "$t" >/dev/null; done
}

# arm() for an entry too large to survive argv (`copyq add "$(cat 1mb)"` dies
# with E2BIG). copyq's own scripting reads the payload off stdin instead.
arm_file() {
  reset_selections
  settle
  cq eval -- 'add(str(input()))' < "$1" >/dev/null
}

# ------------------------------------------------------ paste-target fixture ---

start_target() { # <wm_class>
  stop_target
  : > "$TMP/target.combo"
  : > "$TMP/target.buffer"
  : > "$TMP/target.out"
  env DISPLAY="$DPY" python3 "$TMP/paste-target.py" "$1" \
      "$TMP/target.combo" "$TMP/target.buffer" >"$TMP/target.out" 2>&1 &
  TARGET_PID=$!
  local i
  for i in $(seq 1 40); do
    grep -q ready "$TMP/target.out" 2>/dev/null && { sleep 0.3; return 0; }
    sleep 0.25
  done
  echo "FATAL: paste-target did not come up; $(cat "$TMP/target.out")" >&2
  exit 1
}

stop_target() {
  [ -n "${TARGET_PID:-}" ] && { kill "$TARGET_PID" 2>/dev/null; wait "$TARGET_PID" 2>/dev/null; }
  TARGET_PID=""
}

# Wait for the target to finish handling a paste (combo recorded AND the
# selection transfer completed), then echo the combo it saw.
await_paste() {
  local i
  for i in $(seq 1 80); do
    if [ -s "$TMP/target.combo" ] && grep -q . "$TMP/target.done" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done
  cat "$TMP/target.combo" 2>/dev/null
}

# ---------------------------------------------------------------- fixtures ---

mkdir -p "$TMP" "$CFG/copyq" "$DAT" "$CCH"

cat > "$TMP/paste-target.py" <<'PYEOF'
"""A minimal X client that really pastes, used to observe clip-paste.sh.

Owns a window with a chosen WM_CLASS (so xdotool's class detection has
something to detect), holds the input focus, and on a ctrl+v / ctrl+shift+v
KeyPress converts the CLIPBOARD selection -- INCR transfers included -- and
appends the bytes it receives to a buffer file, the way an editor would insert
at its caret. The modifier combo it saw is written to a separate file so the
class -> keystroke mapping can be asserted on the *receiving* end rather than
on the sending command line.

usage: paste-target.py <wm_class> <combo-file> <buffer-file>
"""
import sys

import Xlib.display
import Xlib.X
import Xlib.Xatom

wm_class, combo_path, buffer_path = sys.argv[1], sys.argv[2], sys.argv[3]
done_path = combo_path.rsplit(".", 1)[0] + ".done"
open(done_path, "w").close()

d = Xlib.display.Display()
screen = d.screen()
win = screen.root.create_window(
    0, 0, 400, 300, 0, screen.root_depth,
    event_mask=Xlib.X.KeyPressMask | Xlib.X.PropertyChangeMask)
win.set_wm_name("paste-target")
win.set_wm_class(wm_class.lower(), wm_class)
win.map()
d.sync()
win.set_input_focus(Xlib.X.RevertToParent, Xlib.X.CurrentTime)
d.sync()

CLIPBOARD = d.get_atom("CLIPBOARD")
UTF8 = d.get_atom("UTF8_STRING")
INCR = d.get_atom("INCR")
DEST = d.get_atom("CLIP_PASTE_TEST")

CTRL, SHIFT = 1 << 2, 1 << 0
V_KEYCODE = d.keysym_to_keycode(0x076)  # XK_v, on the CURRENT keymap


def read_property():
    """Read DEST off our window, following an INCR transfer if offered."""
    r = win.get_full_property(DEST, Xlib.X.AnyPropertyType,
                              sizehint=1 << 20)
    if r is None:
        return b""
    if r.property_type == INCR:
        win.delete_property(DEST)
        d.flush()
        chunks = []
        while True:
            e = d.next_event()
            if (e.type != Xlib.X.PropertyNotify or e.atom != DEST
                    or e.state != Xlib.X.PropertyNewValue):
                continue
            part = win.get_full_property(DEST, Xlib.X.AnyPropertyType,
                                         sizehint=1 << 20)
            win.delete_property(DEST)
            d.flush()
            data = b"" if part is None else bytes(bytearray(part.value))
            if not data:
                return b"".join(chunks)
            chunks.append(data)
    win.delete_property(DEST)
    d.flush()
    return bytes(bytearray(r.value))


def paste():
    win.convert_selection(CLIPBOARD, UTF8, DEST, Xlib.X.CurrentTime)
    d.flush()
    while True:
        e = d.next_event()
        if e.type == Xlib.X.SelectionNotify:
            if e.property == Xlib.X.NONE:
                return b""
            return read_property()


print("ready", flush=True)
while True:
    e = d.next_event()
    if e.type != Xlib.X.KeyPress or e.detail != V_KEYCODE:
        continue
    if not e.state & CTRL:
        continue
    combo = "ctrl+shift+v" if e.state & SHIFT else "ctrl+v"
    data = paste()
    with open(buffer_path, "ab") as f:
        f.write(data)
    with open(combo_path, "a") as f:
        f.write(combo + "\n")
    with open(done_path, "w") as f:
        f.write("1\n")
PYEOF

command -v "$COPYQ" >/dev/null 2>&1 || { echo "FATAL: copyq not found (set COPYQ=)" >&2; exit 1; }
command -v "$XVFB"  >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=)"  >&2; exit 1; }
command -v xdotool  >/dev/null 2>&1 || { echo "FATAL: xdotool not found" >&2; exit 1; }
command -v xclip    >/dev/null 2>&1 || { echo "FATAL: xclip not found" >&2; exit 1; }
python3 -c 'import Xlib' 2>/dev/null || { echo "FATAL: python-xlib missing" >&2; exit 1; }
[ -r "$CLIP_PASTE" ] || { echo "FATAL: $CLIP_PASTE not readable" >&2; exit 1; }

"$XVFB" "$DPY" -screen 0 800x600x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 20); do
  [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break
  sleep 0.5
done
[ -e "/tmp/.X11-unix/X${DPY#:}" ] || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

echo "clip-paste: $CLIP_PASTE"
echo "copyq:      $("$COPYQ" --version 2>/dev/null | head -1)"
echo "display:    $DPY"

# ============================== PHASE 0: no window, nothing to paste into ====

# Deliberately first, while the Xvfb display still has no client windows.
scenario "no-active-window: exits nonzero and leaves the selections untouched"
reset_selections
run_paste 0
rc=$?
assert_eq "exit status is nonzero" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo 0)"
assert_eq "clipboard was not overwritten" "SENTINEL-nothing-pasted" "$(sel clipboard)"
assert_eq "primary was not overwritten" "SENTINEL-nothing-pasted" "$(sel primary)"
assert_eq "reason names the missing window" "yes" \
  "$(grep -qi 'no focused window' "$TMP/paste.err" && echo yes || echo no)"

# =============================== copyq server, seeded history ================

ln -s "$SCRIPT_DIR/../../copyq/copyq.conf" "$CFG/copyq/copyq.conf" 2>/dev/null
ln -s "$SCRIPT_DIR/../../copyq/commands.ini" "$CFG/copyq/copyq-commands.ini" 2>/dev/null
cq --start-server >"$TMP/server.log" 2>&1 &
for i in $(seq 1 40); do
  cq eval 1 >/dev/null 2>&1 && { SERVER_STARTED=1; break; }
  sleep 0.5
done
[ -n "${SERVER_STARTED:-}" ] || { echo "FATAL: copyq server did not start" >&2; cat "$TMP/server.log" >&2; exit 1; }

# Seed known rows. `copyq add` inserts at row 0, so the LAST add is row 0.
# (Seeding via `copyq add` is sound here because nothing in this file asserts
# on clipboard *capture* -- capture is dotfiles-92w.1's contract, and copyq
# ignores changes it owns itself, which makes `copyq copy` a false-pass trap.)
PLAIN='plain-entry-marker'
MULTI='first line
  second line with  spaces
third'
UNI='héllo → 世界 🎉 ünïcodé'

scenario "row-addressing: an entry deeper in the history is the one pasted"
arm "$MULTI" "$UNI" "$PLAIN"     # rows: 0=PLAIN 1=UNI 2=MULTI
assert_eq "row 0 is the newest add" "$PLAIN" "$(cq read 0)"
assert_eq "row 2 is the oldest add" "$MULTI" "$(cq read 2)"
start_target firefox
run_paste 2
await_paste >/dev/null
assert_eq "row 2, not row 0, reached the window" "$MULTI" "$(cat "$TMP/target.buffer")"
stop_target

# ================= PHASE 1: class -> keystroke, observed at the receiver =====

scenario "class-to-keystroke: the focused window's class picks the paste key"
for probe in "st ctrl+shift+v" "wezterm ctrl+shift+v" "Alacritty ctrl+shift+v" \
             "firefox ctrl+v" "Code ctrl+v" "SomeUnknownApp ctrl+v"; do
  set -- $probe
  klass="$1"; want="$2"
  arm "$PLAIN"
  start_target "$klass"
  run_paste 0
  got="$(await_paste)"
  assert_eq "class '$klass' -> $want" "$want" "$got"
  stop_target
done

# ======================= PHASE 2: end-to-end paste into the focused window ===

scenario "plain-entry: the focused window receives the entry verbatim"
arm "$PLAIN"
start_target firefox
run_paste 0
await_paste >/dev/null
assert_eq "window pasted the entry" "$PLAIN" "$(cat "$TMP/target.buffer")"
assert_eq "CLIPBOARD holds the entry" "$PLAIN" "$(sel clipboard)"
assert_eq "PRIMARY holds the entry" "$PLAIN" "$(sel primary)"
stop_target

scenario "multiline: newlines and interior spacing survive the round trip"
arm "$MULTI"
start_target st
run_paste 0
await_paste >/dev/null
assert_eq "window pasted every line unchanged" "$MULTI" "$(cat "$TMP/target.buffer")"
# MULTI is 3 lines with no trailing newline, so exactly 2 newline bytes must
# have made it across -- a paste that flattened or doubled them fails here.
assert_eq "newline count preserved" "2" "$(tr -cd '\n' < "$TMP/target.buffer" | wc -c | tr -d ' ')"
stop_target

scenario "unicode: multibyte text and emoji are not mangled"
arm "$UNI"
start_target firefox
run_paste 0
await_paste >/dev/null
assert_eq "window pasted the unicode entry byte-exact" "$UNI" "$(cat "$TMP/target.buffer")"
assert_eq "byte length preserved" "$(printf '%s' "$UNI" | wc -c)" \
  "$(wc -c < "$TMP/target.buffer" | tr -d ' ')"
stop_target

scenario "huge-entry: a 1 MB entry transfers whole (INCR) without truncation"
python3 -c "import sys; sys.stdout.write('H' * 1000000)" > "$TMP/big.txt"
arm_file "$TMP/big.txt"
assert_eq "1 MB entry is in history at row 0" "1000000" "$(cq read 0 | wc -c | tr -d ' ')"
start_target firefox
run_paste 0
await_paste >/dev/null
assert_eq "window received all 1000000 bytes" "1000000" \
  "$(wc -c < "$TMP/target.buffer" | tr -d ' ')"
assert_eq "CLIPBOARD holds all 1000000 bytes" "1000000" "$(sel clipboard | wc -c | tr -d ' ')"
stop_target

# ================================= PHASE 3: argument + row edge cases ========

scenario "bad-row: non-numeric and missing arguments are refused"
arm "$PLAIN"
start_target firefox
run_paste abc; rc=$?
assert_eq "non-numeric row exits nonzero" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo 0)"
assert_eq "non-numeric row explains itself" "yes" \
  "$(grep -qi 'non-negative integer' "$TMP/paste.err" && echo yes || echo no)"
run_paste; rc=$?
assert_eq "missing row exits nonzero" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo 0)"
assert_eq "no key was delivered for a bad row" "" "$(cat "$TMP/target.combo")"
assert_eq "clipboard untouched by a bad row" "SENTINEL-nothing-pasted" "$(sel clipboard)"
stop_target

scenario "out-of-range-row: a row past the end of history is a no-op"
arm "$PLAIN"
start_target firefox
run_paste 9999; rc=$?
assert_eq "exits nonzero" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo 0)"
assert_eq "no key was delivered" "" "$(cat "$TMP/target.combo")"
assert_eq "clipboard untouched" "SENTINEL-nothing-pasted" "$(sel clipboard)"
stop_target

scenario "empty-entry: an empty history row pastes nothing rather than blanking"
reset_selections
settle
cq add "" >/dev/null 2>&1 || true
assert_eq "row 0 really is the empty entry" "" "$(cq read 0)"
start_target firefox
run_paste 0; rc=$?
assert_eq "exits nonzero" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo 0)"
assert_eq "no key was delivered" "" "$(cat "$TMP/target.combo")"
assert_eq "clipboard still holds the previous content" "SENTINEL-nothing-pasted" "$(sel clipboard)"
stop_target

# ------------------------------------------------------------------ result ---

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
