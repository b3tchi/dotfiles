#!/usr/bin/env bash
# test-clipd-x.sh — end-to-end test of `clipd agent x <display>` (sp039
# Task 4) against a throwaway Xvfb.
#
# Never touches a live session: the agent serves TEST_DISPLAY (default :94;
# the live :40 / :10 are refused outright), XDG_RUNTIME_DIR and
# CLIPD_CONFIG_DIR point into $TMP, and every process this script starts is
# recorded at spawn and killed by that pid only — never by name.
#
# Every agent is started with a WRONG inherited DISPLAY (:77, no server),
# so an agent that trusts the environment captures nothing and fails the
# suite.
#
# Selections are owned by python-xlib helpers where xclip cannot model the
# case: clip-owner.py advertises several targets at once (password-manager
# hint, image/bmp-only) and logs every SelectionRequest it receives, so
# "payload never requested" is measured, not assumed; hung-owner.py owns
# CLIPBOARD and never answers.
#
# Entries are decrypted with the `age` CLI using the test identity, only
# inside $TMP, to compare against the fixture that was copied.
#
# usage: clipd/test-clipd-x.sh
# env:   TEST_DISPLAY=:94  XVFB=Xvfb  KEEP_TMP=1 (debug: keep $TMP)
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
XVFB="${XVFB:-Xvfb}"
DPY="${TEST_DISPLAY:-:94}"
TMP="${TMPDIR:-/tmp}/clipd-x-test.$$"
RUN="$TMP/run"
CFG="$TMP/cfg"
FOLDER="$RUN/clipd/folder"
CLIPD="$TMP/clipd"

case "$DPY" in
  :40|:10|:0) echo "FATAL: refusing to test on live display $DPY" >&2; exit 1 ;;
esac

PASS=0
FAIL=0
PIDS=()     # every background pid this script spawned
AGENT_PID=""

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
scenario() { printf '\n[%s]\n' "$1"; }

spawn() { # <cmd...>: run in background, record pid in SPAWNED and PIDS
  "$@" &
  SPAWNED=$!
  PIDS+=("$SPAWNED")
}

stop_pid() { # <pid>: kill one pid we spawned, plus its direct children
  local p="$1" kids k mine=""
  for k in "${PIDS[@]}"; do [ "$k" = "$p" ] && mine=1; done
  [ -n "$mine" ] || { echo "BUG: stop_pid on foreign pid $p" >&2; return 1; }
  kids="$(pgrep -P "$p" 2>/dev/null)"
  kill "$p" 2>/dev/null
  wait "$p" 2>/dev/null
  for k in $kids; do kill "$k" 2>/dev/null; done
}

cleanup() {
  local p
  for p in "${PIDS[@]}"; do
    [ "$p" = "${XVFB_PID:-}" ] && continue
    kill -0 "$p" 2>/dev/null && stop_pid "$p"
  done
  [ -n "${XVFB_PID:-}" ] && { kill "$XVFB_PID" 2>/dev/null; wait "$XVFB_PID" 2>/dev/null; }
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

for b in "$XVFB" xclip clipnotify python3 age go; do
  command -v "$b" >/dev/null 2>&1 || { echo "FATAL: $b not found" >&2; exit 1; }
done
python3 -c 'import Xlib' 2>/dev/null || { echo "FATAL: python-xlib missing" >&2; exit 1; }

mkdir -p "$TMP" "$FOLDER" "$CFG"
chmod 700 "$RUN"
(cd "$HERE" && go build -o "$CLIPD" ./cmd/clipd) || { echo "FATAL: build failed" >&2; exit 1; }

# ---------------------------------------------------------------- fixtures --

cat >"$TMP/clip-owner.py" <<'PYEOF'
"""Own CLIPBOARD advertising several targets; log every request target.

usage: clip-owner.py <payload-file> <reqlog> <target> [target ...]
Every listed target serves the payload file's bytes.
"""
import sys
import Xlib.X, Xlib.Xatom, Xlib.display, Xlib.protocol.event

payload = open(sys.argv[1], "rb").read()
reqlog = open(sys.argv[2], "w")
d = Xlib.display.Display()
win = d.screen().root.create_window(0, 0, 1, 1, 0, d.screen().root_depth)
SEL, TARGETS = d.get_atom("CLIPBOARD"), d.get_atom("TARGETS")
served = {d.get_atom(t): payload for t in sys.argv[3:]}
win.set_selection_owner(SEL, Xlib.X.CurrentTime)
d.sync()
if d.get_selection_owner(SEL) != win:
    sys.exit("FAILED to own CLIPBOARD")
print("owned", flush=True)
while True:
    e = d.next_event()
    if e.type == Xlib.X.SelectionClear:
        sys.exit(0)
    if e.type != Xlib.X.SelectionRequest:
        continue
    print("REQ " + d.get_atom_name(e.target), file=reqlog, flush=True)
    prop = e.property if e.property != Xlib.X.NONE else e.target
    ok = True
    if e.target == TARGETS:
        e.requestor.change_property(prop, Xlib.Xatom.ATOM, 32, [TARGETS] + list(served))
    elif e.target in served:
        e.requestor.change_property(prop, e.target, 8, served[e.target])
    else:
        ok = False
    d.send_event(e.requestor, Xlib.protocol.event.SelectionNotify(
        time=e.time, requestor=e.requestor, selection=e.selection,
        target=e.target, property=prop if ok else Xlib.X.NONE))
    d.flush()
PYEOF

cat >"$TMP/hung-owner.py" <<'PYEOF'
"""Own CLIPBOARD and never answer a SelectionRequest (a dead RDP client)."""
import sys, time
import Xlib.X, Xlib.display
d = Xlib.display.Display()
win = d.screen().root.create_window(0, 0, 1, 1, 0, d.screen().root_depth)
win.set_selection_owner(d.get_atom("CLIPBOARD"), Xlib.X.CurrentTime)
d.sync()
print("owned", flush=True)
while True:
    time.sleep(60)
PYEOF

# ----------------------------------------------------------------- helpers --

start_xvfb() {
  local i
  for i in $(seq 1 20); do [ -e "/tmp/.X${DPY#:}-lock" ] || break; sleep 0.5; done
  [ -e "/tmp/.X${DPY#:}-lock" ] && { echo "FATAL: $DPY in use (set TEST_DISPLAY)" >&2; exit 1; }
  spawn "$XVFB" "$DPY" -screen 0 320x240x24 >"$TMP/xvfb.log" 2>&1
  XVFB_PID=$SPAWNED
  for i in $(seq 1 40); do
    timeout 2 xclip -display "$DPY" -selection clipboard -t TARGETS -o 2>&1 >/dev/null \
      | grep -q "Can't open display" || return 0
    sleep 0.25
  done
  echo "FATAL: Xvfb $DPY did not start" >&2; cat "$TMP/xvfb.log" >&2; exit 1
}

# An array, not a function: spawn must record the clipd pid itself (env
# execs it), not a subshell's.
AENV=(env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" CLIPD_CONFIG_DIR="$CFG" CLIPD_DEVICE=testhost CLIPD_DISPLAY=)

start_agent() {
  spawn "${AENV[@]}" "$CLIPD" agent x "$DPY" >>"$TMP/agent.log" 2>&1
  AGENT_PID=$SPAWNED
  # ready once the startup heartbeat exists
  local i
  for i in $(seq 1 40); do
    [ -e "$FOLDER/hb-testhost.age" ] && return 0
    sleep 0.1
  done
  echo "FATAL: agent wrote no heartbeat"; cat "$TMP/agent.log"; exit 1
}

OWNER_PID=""
OWN_N=0
own() { # <payload-string> <target...>: python owner; sets REQLOG
  [ -n "$OWNER_PID" ] && stop_pid "$OWNER_PID"
  OWN_N=$((OWN_N + 1))
  printf '%s' "$1" >"$TMP/payload.$OWN_N"; shift
  REQLOG="$TMP/reqlog.$OWN_N"
  : >"$REQLOG"
  spawn env DISPLAY="$DPY" python3 "$TMP/clip-owner.py" "$TMP/payload.$OWN_N" "$REQLOG" "$@" >"$TMP/owner.out" 2>&1
  OWNER_PID=$SPAWNED
  local i
  for i in $(seq 1 40); do grep -q owned "$TMP/owner.out" 2>/dev/null && return 0; sleep 0.05; done
  echo "FATAL: owner failed: $(cat "$TMP/owner.out")"; exit 1
}

own_text() { own "$1" UTF8_STRING STRING text/plain; }

entries() { find "$FOLDER" -maxdepth 1 -regextype posix-extended -regex '.*/[0-9a-f]{16}\.age' | sort; }
count() { entries | wc -l | tr -d ' '; }

wait_count() { # <n> <seconds>: poll until count == n
  local end=$(( $(date +%s%N) + ${2%.*}000000000 ))
  while [ "$(date +%s%N)" -lt "$end" ]; do
    [ "$(count)" = "$1" ] && return 0
    sleep 0.05
  done
  return 1
}

decrypt_field() { # <file> <field>: data is base64-decoded, written raw
  age -d -i "$CFG/identity.txt" "$1" | python3 -c '
import base64, json, sys
e = json.load(sys.stdin)
f = sys.argv[1]
v = base64.b64decode(e["data"]) if f == "data" else str(e[f]).encode()
sys.stdout.buffer.write(v)' "$2"
}

newest() { ls -t $(entries) 2>/dev/null | head -1; }

# --------------------------------------------------------------- scenarios --

"${AENV[@]}" "$CLIPD" keygen >/dev/null || { echo "FATAL: keygen"; exit 1; }
start_xvfb

scenario "display contract"
code=0; env DISPLAY="$DPY" XDG_RUNTIME_DIR="$RUN" CLIPD_CONFIG_DIR="$CFG" CLIPD_DISPLAY= \
  "$CLIPD" agent x >/dev/null 2>"$TMP/nodpy.err" || code=$?
assert_eq "no display arg, valid DISPLAY inherited → exit 78" 78 "$code"
assert_eq "nothing written by the refused agent" 0 "$(count)"

start_agent
code=0; timeout 5 env DISPLAY=:77 XDG_RUNTIME_DIR="$RUN" CLIPD_CONFIG_DIR="$CFG" \
  CLIPD_DISPLAY="$DPY" "$CLIPD" agent x >/dev/null 2>"$TMP/second.err" || code=$?
assert_eq "second agent for the same display (via CLIPD_DISPLAY) exits 0" 0 "$code"
assert_eq "...saying another agent serves it" yes \
  "$(grep -q 'another agent serves' "$TMP/second.err" && echo yes || echo no)"

scenario "plain text copy"
TEXT="$(printf 'hello žluťoučký kůň\ttab')"
own_text "$TEXT"
wait_count 1 5
assert_eq "exactly one .age entry" 1 "$(count)"
F="$(newest)"
assert_eq "decrypts to the copied text, byte-exact" "$(printf '%s' "$TEXT" | od -An -tx1)" \
  "$(decrypt_field "$F" data | od -An -tx1)"
assert_eq "mime" "text/plain;charset=utf-8" "$(decrypt_field "$F" mime)"
assert_eq "origin" "testhost" "$(decrypt_field "$F" origin)"
assert_eq "ciphertext holds no plaintext" no "$(grep -qF 'hello' "$F" && echo yes || echo no)"

scenario "dedupe: same content copied again"
own_text "$TEXT"
sleep 1
assert_eq "no second entry" 1 "$(count)"

scenario "password-manager hint"
for hint in application/x-kde-passwordManagerHint x-kde-passwordManagerHint; do
  own "pm-secret-$hint" UTF8_STRING STRING "$hint"
  sleep 1
  assert_eq "$hint: no entry written" 1 "$(count)"
  assert_eq "$hint: owner was asked for TARGETS only" "REQ TARGETS" "$(sort -u "$REQLOG")"
done
BASE="$(count)"

scenario "image/bmp-only owner"
own "BMfake" image/bmp
sleep 1
assert_eq "no entry" "$BASE" "$(count)"
assert_eq "only TARGETS requested (no laundering into text)" "REQ TARGETS" "$(sort -u "$REQLOG")"

scenario "image/png"
printf '\x89PNG\r\n\x1a\nnot-really-a-png' >"$TMP/fake.png"
own "$(cat "$TMP/fake.png")" image/png UTF8_STRING
wait_count $((BASE + 1)) 5
assert_eq "one entry" $((BASE + 1)) "$(count)"
assert_eq "png preferred over text" image/png "$(decrypt_field "$(newest)" mime)"
assert_eq "text target never requested" no "$(grep -q 'REQ UTF8_STRING' "$REQLOG" && echo yes || echo no)"
BASE="$(count)"

scenario "hung owner"
[ -n "$OWNER_PID" ] && stop_pid "$OWNER_PID"; OWNER_PID=""
spawn env DISPLAY="$DPY" python3 "$TMP/hung-owner.py" >"$TMP/hung.out" 2>&1
HUNG_PID=$SPAWNED
for i in $(seq 1 40); do grep -q owned "$TMP/hung.out" && break; sleep 0.05; done
sleep 0.2
t0=$(date +%s%N)
own_text "after-the-hang"
if wait_count $((BASE + 1)) 2; then
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  pass "next copy processed within 2 s (${ms} ms)"
else
  fail "next copy processed within 2 s" $((BASE + 1)) "$(count)"
fi
assert_eq "it holds the next copy" "after-the-hang" "$(decrypt_field "$(newest)" data)"
assert_eq "timeout logged as metadata" yes "$(grep -q 'timed out' "$TMP/agent.log" && echo yes || echo no)"
stop_pid "$HUNG_PID"
BASE="$(count)"

scenario "burst: 20 copies in ~1 s"
[ -n "$OWNER_PID" ] && stop_pid "$OWNER_PID"; OWNER_PID=""
BURST=()
for i in $(seq -w 1 20); do
  printf 'burst-%s' "$i" >"$TMP/b.$i"
  spawn xclip -display "$DPY" -selection clipboard -quiet -i "$TMP/b.$i" >/dev/null 2>&1
  BURST+=("$SPAWNED")
  sleep 0.05
done
sleep 1.5
for f in $(entries); do decrypt_field "$f" data; echo; done | grep '^burst-' | sort >"$TMP/burst.got"
assert_eq "no content written twice" 0 "$(uniq -d "$TMP/burst.got" | wc -l | tr -d ' ')"
assert_eq "final copy captured" yes "$(grep -qx 'burst-20' "$TMP/burst.got" && echo yes || echo no)"
printf '  INFO  %s of 20 burst copies captured (X keeps only the newest; overwritten ones are unrecoverable)\n' \
  "$(wc -l <"$TMP/burst.got" | tr -d ' ')"
for p in "${BURST[@]}"; do kill -0 "$p" 2>/dev/null && stop_pid "$p"; done

scenario "agent health"
assert_eq "agent still running" alive "$(kill -0 "$AGENT_PID" 2>/dev/null && echo alive || echo dead)"
leak=no
for s in "hello" "pm-secret" "after-the-hang" "burst-"; do
  grep -qF "$s" "$TMP/agent.log" && leak="$s"
done
assert_eq "no payload text in the agent log" no "$leak"

scenario "SIGTERM"
kids="$(pgrep -P "$AGENT_PID")"
kill -TERM "$AGENT_PID"; wait "$AGENT_PID"; code=$?
assert_eq "agent exits 0 on SIGTERM" 0 "$code"
sleep 0.3
alive=0; for k in $kids; do kill -0 "$k" 2>/dev/null && alive=$((alive + 1)); done
assert_eq "no clipnotify child left behind" 0 "$alive"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
