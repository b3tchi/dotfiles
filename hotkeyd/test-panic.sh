#!/usr/bin/env bash
# Panic / resume suite (sp020 Task 10, dotfiles-hwds.12).
#
# THE LOAD-BEARING ASSERTION IS OWNERSHIP TRANSFER, not an exit code. Every case
# reads who answers a chord BEFORE and AFTER, and it reads it as a real WM
# effect: the daemon's action and i3's fallback bind switch to DIFFERENTLY NAMED
# workspaces, so the focused workspace names whichever of the two actually
# received the keystroke. A script that returned 0 while changing nothing fails
# here. (Workspaces rather than marks because `mark` needs a focused container
# and this session deliberately has no windows.)
#
# Ownership is also read from `i3-msg -t get_config` — the config i3 has
# LOADED, including the files it pulled in through the config.d glob. Not
# `get_tree`, which returns the window tree and knows nothing about binds.
#
# The daemon under test is seeded ALIVE AND WRONG — holding a grab on the chord
# the fallback wants — because that is the state panic exists for. A dead daemon
# is the easy half and is covered separately below.
#
# Bash rather than nushell per adr0002 condition 1, same as the other two
# runtime suites: this must run on a fresh box before any link step.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

export PYTHONDONTWRITEBYTECODE=1

# NEVER let an inherited I3SOCK reach anything here. i3 exports its socket into
# every process it execs, so a suite run from a terminal inside the caller's own
# i3 would have every `i3-msg` in this file talk to the REAL session — reading
# the wrong bind table, and switching the user's live workspaces while doing it.
# Unset, i3-msg resolves the socket from the root window of whatever DISPLAY it
# is handed, which is the throwaway one.
unset I3SOCK

T="$(mktemp -d)"
XVFB_PIDS=()
I3_PIDS=()

probe_free_display() { # <start-number>
    local n="$1"
    while [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X${n}-lock" ]; do
        n=$((n + 1))
    done
    printf ':%s' "$n"
}

cleanup() {
    pkill -f "hotkeyd\.py .*--display $XA" 2>/dev/null
    pkill -f "hotkeyd\.py .*--display $XB" 2>/dev/null
    for p in "${I3_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    for p in "${XVFB_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    rm -rf "$T"
}

if ! command -v Xvfb >/dev/null || ! command -v i3 >/dev/null; then
    echo "panic suite: Xvfb or i3 missing — skipped"
    exit 0
fi

XA="$(probe_free_display 81)"
XB="$(probe_free_display "$(( ${XA#:} + 1 ))")"
trap cleanup EXIT

# --- throwaway session -------------------------------------------------------
# HOME is fake so the link lands in a temp config.d; the fallback SOURCE is a
# test one that actually binds a chord. The shipped fallback is empty on
# purpose (see its header: today binds.py owns only $mod+o and i3 still owns it
# too), so using it here could not show ownership moving at all. Its CONTENT is
# guarded elsewhere — test_binds.py diffs it against binds.py, and stage 10
# runs `i3 -C` over the composed tree with it linked.
export HOME="$T/home"
export XDG_RUNTIME_DIR="$T/run"
export HOTKEYD_I3_CONFIG_D="$HOME/.i3/config.d"
export HOTKEYD_FALLBACK_SRC="$T/zz-fallback-binds.conf"
mkdir -p "$HOTKEYD_I3_CONFIG_D" "$XDG_RUNTIME_DIR"
LINK="$HOTKEYD_I3_CONFIG_D/zz-fallback-binds.conf"

printf 'bindsym Mod4+F10 workspace i3-owns-it\n' > "$HOTKEYD_FALLBACK_SRC"

# The daemon's table. Its action is an i3 command, so a keystroke the daemon
# receives moves the session exactly the way i3's own bind would — one
# observable, two possible authors, and the workspace name says which.
cat > "$T/daemon-binds.py" <<EOF
import sys; sys.path.insert(0, "$HERE")
from binds import Bind
BINDS = [Bind('Mod4+F10', 'workspace daemon-owns-it')]
LAYERS = {}
EOF
export HOTKEYD_BINDS="$T/daemon-binds.py"

# XTEST injection. A real key through the real server is the only way to learn
# who holds the passive grab; asking either side what it thinks it grabbed just
# reports intent. Python per adr0015 — X clients are Python in this tree.
cat > "$T/tap.py" <<'EOF'
import sys, time
from Xlib import X, XK, display as xdisplay
from Xlib.ext import xtest
d = xdisplay.Display()
mod = d.keysym_to_keycode(XK.string_to_keysym("Super_L"))
key = d.keysym_to_keycode(XK.string_to_keysym(sys.argv[1]))
xtest.fake_input(d, X.KeyPress, mod)
xtest.fake_input(d, X.KeyPress, key)
xtest.fake_input(d, X.KeyRelease, key)
xtest.fake_input(d, X.KeyRelease, mod)
d.sync()
time.sleep(0.4)
EOF

# Ownership as i3 has LOADED it. `i3-msg -t get_config` prints only the
# top-level config's text — it drops the `included_configs` array from the
# reply, and the fallback arrives through the config.d glob, so i3-msg alone
# would report the fallback missing however well panic worked. This speaks
# GET_CONFIG (type 9) to the same socket and prints the whole reply, main
# config plus every included file, variables already substituted. It is
# get_config; it is not get_tree, which returns windows and knows nothing
# about binds.
cat > "$T/getconfig.py" <<'EOF'
import json, socket, struct, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(b"i3-ipc" + struct.pack("=II", 0, 9))
hdr = b""
while len(hdr) < 14:
    hdr += s.recv(14 - len(hdr))
ln = struct.unpack("=II", hdr[6:14])[0]
buf = b""
while len(buf) < ln:
    buf += s.recv(ln - len(buf))
d = json.loads(buf)
print(d.get("config", ""))
for inc in d.get("included_configs", []):
    print("# --- included:", inc.get("path"))
    print(inc.get("variable_replaced_contents") or inc.get("raw_contents", ""))
EOF

SOCK_A="$T/i3-a.sock"
cat > "$T/i3.conf" <<EOF
font pango:monospace 10
ipc-socket $SOCK_A
include $HOTKEYD_I3_CONFIG_D/*.conf
bindsym Mod4+Shift+F12 exec --no-startup-id $HERE/hotkeyd-panic.sh panic
EOF

for dpy in "$XA" "$XB"; do
    Xvfb "$dpy" -screen 0 640x480x24 >/dev/null 2>&1 &
    XVFB_PIDS+=($!)
done
sleep 1.5
DISPLAY="$XA" i3 -c "$T/i3.conf" >/dev/null 2>&1 &
I3_PIDS+=($!)
sleep 1.5

if ! DISPLAY="$XA" i3-msg -t get_version >/dev/null 2>&1; then
    echo "panic suite: i3 did not start on $XA — skipped"
    exit 0
fi

ws()         { DISPLAY="$XA" i3-msg -t get_workspaces 2>/dev/null; }
tap()        { DISPLAY="$XA" python3 "$T/tap.py" "$1"; }
i3_config()  { python3 "$T/getconfig.py" "$SOCK_A" 2>/dev/null; }
daemons_on() { pgrep -f "hotkeyd\.py .*--display $1" 2>/dev/null | wc -l; }
panic()      { DISPLAY="$XA" "$HERE/hotkeyd-panic.sh" "$@"; }

# Park on a neutral workspace, press the chord, and report who answered.
# Empty workspaces are destroyed on leaving, so the focused one is the only
# name in the reply — no accumulation to filter.
who_answers() {
    DISPLAY="$XA" i3-msg 'workspace nobody' >/dev/null 2>&1
    tap F10
    if ws | grep -q 'daemon-owns-it'; then printf 'daemon\n'
    elif ws | grep -q 'i3-owns-it';   then printf 'i3\n'
    else                                   printf 'nobody\n'
    fi
}

# --- 1: the daemon is ALIVE AND WRONG, holding the chord i3 wants ------------
echo "panic: a daemon that is alive and holding the chord"
DISPLAY="$XA" "$HERE/hotkeyd.sh" start "$XA" >/dev/null 2>&1
sleep 1
[ "$(daemons_on "$XA")" = 1 ] && ok "daemon running on $XA" \
    || bad "daemon did not start on $XA"

answer="$(who_answers)"
[ "$answer" = daemon ] \
    && ok "the DAEMON answers Mod4+F10 before panic (real workspace switch)" \
    || bad "expected the daemon to answer the chord, got: $answer"

# --- 1b: the ordering is load-bearing, demonstrated ---------------------------
# Reloading i3 with the fallback in place while the daemon is STILL ALIVE is
# the contested state panic's stop-first ordering avoids: i3 asks for a chord
# another client already holds, gets BadAccess, and silently does not own it.
# Asserting that this DOES go wrong is what makes "no contested window" a
# finding rather than a hope — without it, panic could reload before stopping
# and every other case here would still pass.
echo "panic: the stop-before-reload ordering is load-bearing"
ln -sfn "$HOTKEYD_FALLBACK_SRC" "$LINK"
DISPLAY="$XA" i3-msg reload >/dev/null 2>&1
sleep 0.5
answer="$(who_answers)"
[ "$answer" = daemon ] \
    && ok "reloading i3 while the daemon lives does NOT transfer the chord" \
    || bad "expected the live daemon to keep the chord, got: $answer"
rm -f "$LINK"
DISPLAY="$XA" i3-msg reload >/dev/null 2>&1
sleep 0.5

# --- 2: panic transfers ownership --------------------------------------------
echo "panic: ownership transfer"
out="$(panic panic 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || bad "panic exited $rc: $out"
sleep 1
[ "$(daemons_on "$XA")" = 0 ] && ok "panic stopped the daemon on $XA" \
    || bad "daemon survived panic on $XA"
[ -L "$LINK" ] && ok "fallback is linked into the shared config.d" \
    || bad "no fallback link at $LINK"

# Ownership as i3 has LOADED it — get_config, not get_tree (which is windows).
if i3_config | grep -q 'workspace i3-owns-it'; then
    ok "i3's loaded config (get_config) now carries the fallback bind"
else
    bad "get_config does not show the fallback bind after reload"
fi

answer="$(who_answers)"
[ "$answer" = i3 ] \
    && ok "I3 now answers Mod4+F10 — ownership actually transferred" \
    || bad "expected i3 to answer after panic, got: $answer"

# --- 3: no contested window --------------------------------------------------
# i3 could only have taken that passive grab because the daemon had already
# released it — X refuses a second client the same chord. Combined with 1b
# (where the live daemon kept it), i3 answering is proof of the ordering, and
# the daemon being gone is proof no second owner remains.
[ "$(daemons_on "$XA")" = 0 ] \
    && ok "no second grab holder is left anywhere on $XA" \
    || bad "a daemon survived panic and contends with the fallback"

# --- 4: idempotence ----------------------------------------------------------
echo "panic: idempotence and degenerate inputs"
panic panic >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "a second panic exits 0" || bad "second panic exited $rc"
n_links=$(find "$HOTKEYD_I3_CONFIG_D" -name 'zz-fallback-binds.conf*' | wc -l)
[ "$n_links" = 1 ] && ok "a second panic left exactly one link" \
    || bad "$n_links fallback links after two panics"
answer="$(who_answers)"
[ "$answer" = i3 ] && ok "i3 still answers after a second panic" \
    || bad "the second panic broke the fallback, got: $answer"

# --- 5: start is latched off while panicked ----------------------------------
out="$(DISPLAY="$XA" "$HERE/hotkeyd.sh" start "$XA" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "hotkeyd.sh start refuses while panicked (rc=$rc)" \
    || bad "start rearmed a daemon behind the fallback"
[ "$(daemons_on "$XA")" = 0 ] && ok "and spawned nothing" \
    || bad "a daemon is running behind the fallback"

# --- 6: resume round-trip ----------------------------------------------------
echo "panic: resume"
out="$(panic resume 2>&1)"; rc=$?
sleep 1
[ "$rc" -eq 0 ] || bad "resume exited $rc: $out"
[ ! -e "$LINK" ] && [ ! -L "$LINK" ] && ok "resume removed the link" \
    || bad "fallback link survived resume"
if i3_config | grep -q 'workspace i3-owns-it'; then
    bad "get_config still carries the fallback bind after resume"
else
    ok "i3's loaded config dropped the fallback bind"
fi
[ "$(daemons_on "$XA")" = 1 ] && ok "resume brought the daemon back" \
    || bad "no daemon after resume"

answer="$(who_answers)"
[ "$answer" = daemon ] \
    && ok "the DAEMON answers Mod4+F10 again — round-trip complete" \
    || bad "expected the daemon to hold its grab after resume, got: $answer"

out="$(panic resume 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "resume with no link in place exits 0" \
    || bad "second resume exited $rc: $out"

# --- 7: panic with the daemon ALREADY DEAD -----------------------------------
echo "panic: daemon already dead"
pkill -9 -f "hotkeyd\.py .*--display $XA"
sleep 0.5
[ "$(daemons_on "$XA")" = 0 ] || bad "daemon still alive after SIGKILL"
out="$(panic panic 2>&1)"; rc=$?
sleep 0.5
[ "$rc" -eq 0 ] || bad "panic on a dead daemon exited $rc: $out"
[ -L "$LINK" ] && ok "panic still relinked with no daemon to stop" \
    || bad "no link after panicking on a dead daemon"
answer="$(who_answers)"
[ "$answer" = i3 ] \
    && ok "i3 owns the chord after panicking on a dead daemon" \
    || bad "expected i3 to own the chord on a dead-daemon panic, got: $answer"
panic resume >/dev/null 2>&1
sleep 1

# --- 7b: an inherited I3SOCK must not steer the reload -----------------------
# This script is EXECED BY AN i3 BIND in real use, so it inherits that i3's
# I3SOCK. If the reload trusted it, every display in the machine-wide loop
# would reload the caller's i3 and the others would keep stale binds — the
# dotfiles-hwds.6 defect, in the one script that must work during an outage.
# A bogus value here is indistinguishable from "the wrong display's socket".
echo "panic: an inherited I3SOCK does not steer the reload"
DISPLAY="$XA" "$HERE/hotkeyd.sh" start "$XA" >/dev/null 2>&1
sleep 1
out="$(DISPLAY="$XA" I3SOCK="$T/not-a-socket" \
       "$HERE/hotkeyd-panic.sh" panic 2>&1)"; rc=$?
sleep 0.5
[ "$rc" -eq 0 ] || bad "panic with a bogus I3SOCK exited $rc: $out"
if i3_config | grep -q 'workspace i3-owns-it'; then
    ok "i3 on $XA reloaded despite a bogus inherited I3SOCK"
else
    bad "the reload followed I3SOCK instead of DISPLAY — wrong i3 reloaded"
fi
answer="$(who_answers)"
[ "$answer" = i3 ] && ok "and it owns the chord" \
    || bad "expected i3 to own the chord, got: $answer"
panic resume >/dev/null 2>&1
sleep 1
DISPLAY="$XA" "$HERE/hotkeyd.sh" stop "$XA" >/dev/null 2>&1

# --- 8: MACHINE-WIDE, not per-display ----------------------------------------
# The Task 10 decision. ~/.i3/config.d/ is one shared directory, so the link
# panic makes on ONE display is a file the OTHER display's i3 parses on its next
# reload. If panic left that display's daemon running, that later reload would
# recreate the contested state. So panic stops every daemon on the machine, and
# this asserts it on the display that was NOT panicked.
echo "panic: machine-wide daemon stop"
DISPLAY="$XA" "$HERE/hotkeyd.sh" start "$XA" >/dev/null 2>&1
DISPLAY="$XB" "$HERE/hotkeyd.sh" start "$XB" >/dev/null 2>&1
sleep 1
if [ "$(daemons_on "$XA")" = 1 ] && [ "$(daemons_on "$XB")" = 1 ]; then
    ok "a daemon on each of $XA and $XB"
else
    bad "setup: $(daemons_on "$XA") on $XA, $(daemons_on "$XB") on $XB"
fi
panic panic >/dev/null 2>&1
sleep 1
[ "$(daemons_on "$XB")" = 0 ] \
    && ok "panicking on $XA also stopped the daemon on $XB" \
    || bad "the $XB daemon survived — a later reload there would contest the \
fallback this panic linked"
[ "$(daemons_on "$XA")" = 0 ] && ok "and the caller's own daemon is gone" \
    || bad "the $XA daemon survived"

out="$(panic resume 2>&1)"; rc=$?
sleep 1
if [ "$(daemons_on "$XA")" = 1 ] && [ "$(daemons_on "$XB")" = 1 ]; then
    ok "resume restarted the daemon on BOTH displays panic stopped"
else
    bad "resume rc=$rc left $(daemons_on "$XA") on $XA, $(daemons_on "$XB") on $XB"
fi
DISPLAY="$XA" "$HERE/hotkeyd.sh" stop "$XA" >/dev/null 2>&1
DISPLAY="$XB" "$HERE/hotkeyd.sh" stop "$XB" >/dev/null 2>&1

# --- 9: degraded environments ------------------------------------------------
echo "panic: degraded environments"
RO="$T/readonly"
mkdir -p "$RO"
chmod a-w "$RO"
out="$(DISPLAY="$XA" HOTKEYD_I3_CONFIG_D="$RO/config.d" \
       "$HERE/hotkeyd-panic.sh" panic 2>&1)"; rc=$?
chmod u+w "$RO"
[ "$rc" -ne 0 ] && ok "panic refuses loudly when config.d is unwritable (rc=$rc)" \
    || bad "panic claimed success with an unwritable config.d"

out="$(DISPLAY= HOTKEYD_I3_CONFIG_D="$T/nowhere" \
       "$HERE/hotkeyd-panic.sh" panic 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "panic with no display refuses (rc=2, did not try)" \
    || bad "expected rc=2 refusal with no display, got rc=$rc: $out"

out="$(DISPLAY="$XA" HOTKEYD_FALLBACK_SRC="$T/missing.conf" \
       "$HERE/hotkeyd-panic.sh" panic 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "panic refuses when the fallback table is missing (rc=2)" \
    || bad "panic linked a nonexistent fallback: rc=$rc $out"

out="$(DISPLAY="$XA" "$HERE/hotkeyd-panic.sh" wat 2>&1)"; rc=$?
[ "$rc" -eq 64 ] && ok "an unknown verb exits 64" || bad "unknown verb rc=$rc"

DISPLAY="$XA" "$HERE/hotkeyd-panic.sh" status >/dev/null 2>&1 \
    && bad "status reports PANICKED with no link" \
    || ok "status exits non-zero when not panicked"

echo
printf 'panic: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
