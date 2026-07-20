#!/usr/bin/env bash
# test-copyq.sh — verify the sp014 copyq backend (dotfiles-92w.1).
#
# Runs entirely headless on its own Xvfb display with an isolated
# XDG_CONFIG_HOME, so it never touches the live X session, the live clipboard,
# or the real ~/.config/copyq.
#
# The repo's copyq.conf / commands.ini are exercised through symlinks, exactly
# as rotz links them, so the test also catches copyq clobbering its own config.
#
# usage: copyq/test-copyq.sh
# env:   COPYQ=/path/to/copyq  XVFB=/path/to/Xvfb  (default: from PATH)
#        TEST_DISPLAY=:99                          (default: :99)
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COPYQ="${COPYQ:-copyq}"
XVFB="${XVFB:-Xvfb}"
DPY="${TEST_DISPLAY:-:99}"

TMP="/tmp/copyq-test.$$"      # kept short: copyq's socket lives under $CFG
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
  stop_server
  [ -n "${OWNER_PID:-}" ] && kill "$OWNER_PID" 2>/dev/null
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

cq() { env DISPLAY="$DPY" XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" \
           XDG_CACHE_HOME="$CCH" "$COPYQ" "$@"; }

start_server() {
  cq --start-server >"$TMP/server.log" 2>&1 &
  local i
  for i in $(seq 1 40); do
    cq eval 1 >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "FATAL: copyq server did not start; see $TMP/server.log" >&2
  cat "$TMP/server.log" >&2
  exit 1
}

stop_server() { cq exit >/dev/null 2>&1; sleep 2; }

# Seed the config dir. With no argument the repo files are symlinked in (the
# rotz layout). "--no-secret-rule" instead copies commands.ini with the
# hint-drop entry stripped -- used by the negative control.
seed_config() {
  rm -rf "$CFG"; mkdir -p "$CFG/copyq" "$DAT" "$CCH"
  if [ "${1:-}" = "--no-secret-rule" ]; then
    cp "$REPO_DIR/copyq.conf" "$CFG/copyq/copyq.conf"
    grep -v '^1\\' "$REPO_DIR/commands.ini" \
      | sed 's/^size=7$/size=7/' > "$CFG/copyq/copyq-commands.ini"
  else
    ln -s "$REPO_DIR/copyq.conf" "$CFG/copyq/copyq.conf"
    ln -s "$REPO_DIR/commands.ini" "$CFG/copyq/copyq-commands.ini"
  fi
}

# Put <text> on the clipboard, advertising the extra MIME targets given as
# further arguments (each served the value "secret"). Replaces any previous
# owner. Returns once the selection is held.
own_clipboard() {
  [ -n "${OWNER_PID:-}" ] && { kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; }
  env DISPLAY="$DPY" python3 "$TMP/clip-owner.py" "$@" >"$TMP/owner.out" 2>&1 &
  OWNER_PID=$!
  local i
  for i in $(seq 1 20); do
    grep -q owned "$TMP/owner.out" 2>/dev/null && return 0
    sleep 0.25
  done
  echo "FATAL: could not own clipboard; $(cat "$TMP/owner.out")" >&2
  exit 1
}

# Wait until `copyq size` differs from <baseline>, or timeout. Echoes the size.
wait_size_change() { # <baseline> [seconds]
  local base="$1" limit="${2:-15}" i n
  for i in $(seq 1 $((limit * 2))); do
    n="$(cq size 2>/dev/null)"
    [ -n "$n" ] && [ "$n" != "$base" ] && { echo "$n"; return 0; }
    sleep 0.5
  done
  cq size 2>/dev/null
}

# --------------------------------------------------------------- fixtures ---

mkdir -p "$TMP"

cat > "$TMP/clip-owner.py" <<'PYEOF'
"""Own the X CLIPBOARD advertising several targets at once.

Simulates a password manager (KeePassXC) publishing the text payload and the
`application/x-kde-passwordManagerHint` marker on one clipboard change --
which xclip cannot do (one target per invocation), PyGObject cannot do
(Gtk.Clipboard.set_with_data is not introspectable), and `copyq copy` cannot
be used for either (copyq ignores clipboard changes it owns itself).

usage: clip-owner.py <text> [extra-mime ...]
"""
import sys
import Xlib.display
import Xlib.protocol.event
import Xlib.X
import Xlib.Xatom

text = sys.argv[1].encode()
extra = sys.argv[2:]

d = Xlib.display.Display()
screen = d.screen()
win = screen.root.create_window(0, 0, 1, 1, 0, screen.root_depth)

SEL = d.get_atom("CLIPBOARD")
TARGETS = d.get_atom("TARGETS")

served = {
    d.get_atom("UTF8_STRING"): text,
    d.get_atom("text/plain"): text,
    Xlib.Xatom.STRING: text,
}
for mime in extra:
    served[d.get_atom(mime)] = b"secret"

win.set_selection_owner(SEL, Xlib.X.CurrentTime)
d.sync()
if d.get_selection_owner(SEL) != win:
    print("FAILED to own CLIPBOARD", file=sys.stderr)
    sys.exit(1)
print("owned", flush=True)

while True:
    e = d.next_event()
    if e.type != Xlib.X.SelectionRequest:
        continue
    prop = e.property if e.property != Xlib.X.NONE else e.target
    ok = True
    if e.target == TARGETS:
        e.requestor.change_property(
            prop, Xlib.Xatom.ATOM, 32, [TARGETS] + list(served))
    elif e.target in served:
        e.requestor.change_property(prop, e.target, 8, served[e.target])
    else:
        ok = False
    d.send_event(e.requestor, Xlib.protocol.event.SelectionNotify(
        time=e.time, requestor=e.requestor, selection=e.selection,
        target=e.target, property=prop if ok else Xlib.X.NONE))
    d.flush()
PYEOF

command -v "$COPYQ" >/dev/null 2>&1 || { echo "FATAL: copyq not found (set COPYQ=)" >&2; exit 1; }
command -v "$XVFB"  >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=)"  >&2; exit 1; }
python3 -c 'import Xlib' 2>/dev/null || { echo "FATAL: python-xlib missing" >&2; exit 1; }

"$XVFB" "$DPY" -screen 0 800x600x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 20); do
  [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break
  sleep 0.5
done
[ -e "/tmp/.X11-unix/X${DPY#:}" ] || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

echo "copyq: $("$COPYQ" --version 2>/dev/null | head -1)"
echo "display: $DPY   config: $CFG"

# =========================== PHASE 1: shipped config, server running ========

seed_config
start_server

scenario "plain-text-capture: a plain copy lands in history verbatim"
own_clipboard 'hello-plain-marker'
size="$(wait_size_change 0)"
assert_eq "history grew to 1 item" "1" "$size"
assert_eq "copyq read 0 returns the copied text" "hello-plain-marker" "$(cq read 0)"

scenario "secret-dropped: a copy carrying x-kde-passwordManagerHint is not stored"
before="$(cq size)"
own_clipboard 'SECRET-PASSWORD-marker' application/x-kde-passwordManagerHint
sleep 6   # no size change is the expected outcome, so this cannot poll-and-exit
assert_eq "history size unchanged" "$before" "$(cq size)"
assert_eq "newest item is still the previous plain copy" "hello-plain-marker" "$(cq read 0)"

scenario "large-text-not-truncated: a 3 MB copy is stored whole"
python3 -c "import sys; sys.stdout.write('M' * 3000000)" > "$TMP/big.txt"
before="$(cq size)"
env DISPLAY="$DPY" timeout 30 xclip -selection clipboard "$TMP/big.txt"
size="$(wait_size_change "$before" 30)"
assert_eq "history grew by one" "$((before + 1))" "$size"
assert_eq "stored byte count matches the source exactly" "3000000" "$(cq read 0 | wc -c)"

scenario "rapid-copies-ordered: two copies in quick succession keep their order"
before="$(cq size)"
own_clipboard 'rapid-ONE'; wait_size_change "$before" 15 >/dev/null
own_clipboard 'rapid-TWO'; wait_size_change "$((before + 1))" 15 >/dev/null
assert_eq "newest is the second copy" "rapid-TWO" "$(cq read 0)"
assert_eq "next-newest is the first copy" "rapid-ONE" "$(cq read 1)"

scenario "empty-clipboard: an empty copy does not crash or corrupt the server"
before="$(cq size)"
printf '' | env DISPLAY="$DPY" timeout 10 xclip -selection clipboard
sleep 3
assert_eq "server still responds" "2" "$(cq eval '1+1' 2>/dev/null)"
assert_eq "newest item is untouched" "rapid-TWO" "$(cq read 0)"

scenario "non-text-clipboard: an image target is not stored as a history item"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDRbinary-image-marker' > "$TMP/img.png"
before="$(cq size)"
env DISPLAY="$DPY" timeout 10 xclip -selection clipboard -t image/png "$TMP/img.png"
sleep 5
assert_eq "no text item was added for the image" "rapid-TWO" "$(cq read 0)"

scenario "config-not-clobbered: copyq leaves the rotz-linked repo files intact"
conf_before="$(md5sum < "$REPO_DIR/copyq.conf")"
cmds_before="$(md5sum < "$REPO_DIR/commands.ini")"
stop_server
assert_eq "copyq.conf unchanged after a server lifecycle" "$conf_before" "$(md5sum < "$REPO_DIR/copyq.conf")"
assert_eq "commands.ini unchanged after a server lifecycle" "$cmds_before" "$(md5sum < "$REPO_DIR/commands.ini")"
assert_eq "copyq.conf is still a symlink, not replaced by a real file" "symlink" \
  "$([ -L "$CFG/copyq/copyq.conf" ] && echo symlink || echo regular-file)"

# =========================== PHASE 2: nothing persisted to disk =============
# The server is stopped, so anything copyq intended to persist is now written.

scenario "no-disk-persistence: no copied payload reached the config dir"
leaked="$(grep -rlaE 'hello-plain-marker|rapid-TWO|SECRET-PASSWORD-marker|MMMMMMMMMM' "$CFG" 2>/dev/null | tr '\n' ' ')"
assert_eq "no file under the config dir contains item content" "" "$leaked"

biggest="$(find "$CFG" -name 'copyq_tab_*.dat' -printf '%s\n' 2>/dev/null | sort -n | tail -1)"
assert_eq "tab data file is absent or header-only (<=8 bytes)" "true" \
  "$([ -z "$biggest" ] || [ "$biggest" -le 8 ] && echo true || echo "false (${biggest} bytes)")"

scenario "restart-history-empty: a restarted server starts with no history"
start_server
assert_eq "copyq size is 0 after restart" "0" "$(cq size)"
stop_server

# =========================== PHASE 3: negative controls ====================
# Without these the phase-1 assertions are vacuous: they would pass just as
# well if copyq had never captured anything at all.

scenario "CONTROL secret-rule-is-load-bearing: same copy IS captured without the rule"
seed_config --no-secret-rule
start_server
own_clipboard 'SECRET-PASSWORD-marker' application/x-kde-passwordManagerHint
size="$(wait_size_change 0)"
assert_eq "hint-bearing copy is captured when the rule is absent" "1" "$size"
assert_eq "and its full text is readable" "SECRET-PASSWORD-marker" "$(cq read 0)"
stop_server

scenario "CONTROL store_items-is-load-bearing: history DOES survive restart when saving is on"
seed_config --no-secret-rule
sed -i 's/^1\\store_items=false$/1\\store_items=true/' "$CFG/copyq/copyq.conf"
start_server
own_clipboard 'persist-control-marker'
wait_size_change 0 >/dev/null
stop_server
start_server
assert_eq "item survives restart with store_items=true" "persist-control-marker" "$(cq read 0)"
stop_server

# ------------------------------------------------------------------ result ---

printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
