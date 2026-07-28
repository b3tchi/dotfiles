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
    # The sentinel is ours — we started it, so we reap it. Per-display, never a
    # bare `pkill -f hotkeyd.py`, which is the machine-wide reach this whole
    # file exists to keep out.
    pkill -f "hotkeyd\.py .*--display $XC" 2>/dev/null
    [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
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
# XC is the OUT-OF-SCOPE display: a real X server and a real daemon this suite
# is not entitled to touch, standing in for the caller's live :0/:10. See the
# sentinel block below.
XC="$(probe_free_display "$(( ${XB#:} + 1 ))")"
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

# `resume` enumerates local X displays to decide what to reload, because the
# unlink it performs is machine-wide (dotfiles-hwds.20). Point that enumeration
# at a throwaway directory naming ONLY this suite's two displays: left at the
# real /tmp/.X11-unix, every resume below would reload the CALLER'S own live i3
# sessions — the same class of accident the I3SOCK unset above prevents. Only
# display numbers come from here; i3-msg still connects through the real socket
# path from the DISPLAY it is handed.
export HOTKEYD_X11_UNIX="$T/x11-unix"
mkdir -p "$HOTKEYD_X11_UNIX"
: > "$HOTKEYD_X11_UNIX/X${XA#:}"
: > "$HOTKEYD_X11_UNIX/X${XB#:}"
# $XC is deliberately absent from that directory AND from the scope below.

# THE PROCESS HALF OF THE SANDBOX (dotfiles-hwds.23). Every override above
# fences the FILES panic touches — the link, the fallback source, the display
# enumeration `resume` reloads. None of them fences the PROCESSES it STOPS:
# `target_displays` pgreps every `hotkeyd.py .*--display` on the box, which is
# correct machine-wide recovery behaviour (the Task 10 / dotfiles-hwds.12
# requirement-4 decision) and is therefore NOT narrowed in production — but it
# reaches straight past HOME and X11_UNIX into the caller's live :0 and :10
# daemons, and panic then runs `hotkeyd.sh stop` on each. With autostart armed
# (a76e9a9) those daemons are real, so running this suite on the desktop ended
# the user's own hotkeyd for the rest of the session. The same enumeration is
# what makes two agent worktrees reap each other's daemons (dotfiles-f2be).
#
# HOTKEYD_PGREP_SCOPE is the allow-list of displays THIS RUN may touch. It is
# read by hotkeyd-panic.sh and by nothing else; production never sets it, which
# the guard near the end of this file asserts. It FILTERS the enumeration
# rather than replacing it, so the machine-wide cases below (section 8: a daemon
# on a display panic was not called with is still stopped) still have to
# DISCOVER their target by pgrep and remain real findings.
export HOTKEYD_PGREP_SCOPE="$XA $XB"

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
bindsym Mod4+Shift+r exec --no-startup-id $HERE/hotkeyd-panic.sh panic
EOF

for dpy in "$XA" "$XB" "$XC"; do
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

# --- the OUT-OF-SCOPE SENTINEL (dotfiles-hwds.23) ----------------------------
# A real hotkeyd daemon on a display this suite never declared. It stands in for
# the user's live :0/:10 — and for a sibling worktree's daemons (dotfiles-f2be)
# — and it is indistinguishable from them to `pgrep -af 'hotkeyd\.py
# .*--display'`, which is the enumeration under test. It is absent from
# HOTKEYD_PGREP_SCOPE and absent from HOTKEYD_X11_UNIX, so nothing in this file
# is entitled to stop it or to reload it.
#
# It stays up for the WHOLE FILE, across every panic below, and the last section
# asserts it is still up. That is the acceptance criterion of dotfiles-hwds.23
# in miniature and it is testable without going near the real daemons: if this
# survives, so does :0/:10.
#
# Started directly rather than through hotkeyd.sh, on its own XDG_RUNTIME_DIR:
# it must not share a lock or a socket with the daemons the suite drives, and it
# must not depend on the launcher this suite is simultaneously exercising.
# HOTKEYD_I3SOCK points at nothing because there is no i3 on $XC.
mkdir -p "$T/sentinel"
env -u I3SOCK DISPLAY="$XC" XDG_RUNTIME_DIR="$T/sentinel" \
    HOTKEYD_I3SOCK="$T/sentinel/no-i3.sock" \
    setsid "$HERE/hotkeyd.py" --display "$XC" >"$T/sentinel.log" 2>&1 &
for _t in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    [ "$(daemons_on "$XC")" = 1 ] && break
done
echo "panic: an out-of-scope daemon (stands in for the live :0/:10)"
[ "$(daemons_on "$XC")" = 1 ] \
    && ok "a daemon is up on $XC, outside this suite's scope" \
    || bad "setup: no sentinel daemon on $XC: $(tail -2 "$T/sentinel.log")"

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

# --- 2b: and it reached NOTHING outside the scope (dotfiles-hwds.23) ---------
# The first panic in this file has now run. $XC held a daemon throughout it and
# is not in HOTKEYD_PGREP_SCOPE, so panic must not have seen it. Failing here
# means the suite stops daemons it does not own — on the desktop that set is the
# user's live :0 and :10.
[ "$(daemons_on "$XC")" = 1 ] \
    && ok "panic left the out-of-scope daemon on $XC running" \
    || bad "panic stopped the daemon on $XC — on a real box that is the live \
:0/:10 session losing hotkeyd mid-flight"
# The state file drives resume's restart loop, so an out-of-scope display
# recorded here is also a resume that tries to start a daemon that was never
# ours — the exact dotfiles-f2be symptom, reported as a failure of THIS suite.
if grep -q "^$XC\$" "$XDG_RUNTIME_DIR/hotkeyd-panic.displays" 2>/dev/null; then
    bad "panic recorded $XC in its state file — resume will try to restart it"
else
    ok "and did not record $XC in the state file resume replays"
fi

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

# `status` is the other half of the same latch (dotfiles-hwds.19). Once
# autostart is armed, `start` is run by an i3 `exec_always` and the refusal
# above lands in the i3 log, never on anyone's terminal — `status` is what a
# person types, and a bare "not running" would name the symptom while hiding
# both the cause and the one command that undoes it. Asserted on the text, not
# on the exit code, because the exit code must NOT move: 1 already means "no
# daemon" and test-launcher.sh's callers read it that way.
out="$(DISPLAY="$XA" "$HERE/hotkeyd.sh" status "$XA" 2>&1)"; rc=$?
case "$out" in
    *PANICKED*"$LINK"*resume*)
        ok "status names the latch, the link and the cure while panicked" ;;
    *)  bad "status hid the panic latch: $out" ;;
esac
[ "$rc" -eq 1 ] \
    && ok "and status still exits 1 while panicked (unchanged for callers)" \
    || bad "status exit code moved to $rc while panicked"

# --- 5b: CONTESTED — a daemon ALIVE behind the latch (dotfiles-hwds.21) -------
# The latch is not self-enforcing, and the .19 argument that "a latched session
# has no daemon by construction" is overstated. Two reachable paths end with
# daemon + link:
#
#   1. hotkeyd.py invoked directly bypasses the launcher's latch check entirely —
#      and daemon_pid() is DELIBERATELY written to see such a daemon, so the repo
#      already treats a hand-started run as expected usage;
#   2. panic stops daemons and only THEN links, and `start` has its own window
#      between reading the link and the spawn completing. An i3 `exec_always`
#      firing in either window rearms one display behind the fallback — which is
#      why arming autostart widened this.
#
# That end state is precisely the contested state the whole panic design exists
# to prevent: two X clients holding overlapping chords. Reporting it as a healthy
# "running" at exit 0 is a worse diagnostic failure than the bare "not running"
# .19 fixed, because it tells the operator to stop looking.
echo "panic: status in the CONTESTED state (daemon alive behind the latch)"
env -u I3SOCK DISPLAY="$XA" setsid "$HERE/hotkeyd.py" \
    --display "$XA" --binds "$HOTKEYD_BINDS" >/dev/null 2>&1 &
sleep 1
[ "$(daemons_on "$XA")" = 1 ] \
    && ok "a hand-started daemon runs behind the fallback link" \
    || bad "setup: could not hand-start a daemon behind the link"

out="$(DISPLAY="$XA" "$HERE/hotkeyd.sh" status "$XA" 2>&1)"; rc=$?
case "$out" in
    *CONTESTED*"$LINK"*panic*)
        ok "status names the CONTESTED state, the link and the cure" ;;
    *)  bad "status reported a contested session as healthy: $out" ;;
esac
# 4 specifically. Not 0 — that is the bug, "healthy" for the one state the
# design forbids. Not 1 either: 1 means "no daemon" and callers read it that way
# (test-launcher.sh asserts it), while here there IS one. 4 is already the
# launcher's "the panic latch is set" code, which `start` returns for the same
# reason, so the latch has ONE code across the launcher.
[ "$rc" -eq 4 ] \
    && ok "and status exits 4 — the launcher's panic-latch code, not 0 or 1" \
    || bad "status exited $rc with a daemon running behind the fallback"

# The cure named must be `panic`, not `resume`. The latched state is the WORKING
# state — i3 owns the whole keyboard — so an ambiguous session has to fail TOWARD
# the latch. `resume` would drop the link while the rogue daemon is still up and
# leave nothing latched at all.
case "$out" in
    *resume*) bad "status told a contested session to resume — that unlatches" ;;
    *)        ok "and it does not advise resume, which would drop the latch" ;;
esac
DISPLAY="$XA" "$HERE/hotkeyd.sh" stop "$XA" >/dev/null 2>&1
sleep 0.5
[ "$(daemons_on "$XA")" = 0 ] || bad "teardown: the contested daemon survived"

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

# --- 8b: resume's RELOAD is machine-wide too (dotfiles-hwds.20) ---------------
# The other half of the Task 10 machine-wide decision, and the half that was
# missing. `resume` removes ONE shared link but reloads only the displays panic
# recorded in its state file — the caller's plus those that HAD a daemon. A
# display with no daemon is never in that set, yet it shares the config.d and can
# have parsed the fallback at any point in the panic window, for a reason nobody
# connected to hotkeyd. Unlinking does not retract grabs i3 has already taken;
# only a reload does. So that display keeps the fallback's grabs while the start
# latch it was protected by is gone — and the next daemon to come up there
# contends with them. Exactly the contested state Task 10 exists to eliminate,
# discovered during an outage.
#
# This needs a REAL i3 on the second display: get_config reports what i3 has
# LOADED, which is the thing that survives the unlink, and only a live i3 holds
# grabs to read back.
echo "panic: resume reloads displays panic never recorded"
SOCK_B="$T/i3-b.sock"
sed "s|ipc-socket $SOCK_A|ipc-socket $SOCK_B|" "$T/i3.conf" > "$T/i3-b.conf"
DISPLAY="$XB" i3 -c "$T/i3-b.conf" >/dev/null 2>&1 &
I3_PIDS+=($!)
sleep 1.5

if ! DISPLAY="$XB" i3-msg -t get_version >/dev/null 2>&1; then
    bad "setup: i3 did not start on $XB — the machine-wide resume case cannot run"
else
    i3_config_b() { python3 "$T/getconfig.py" "$SOCK_B" 2>/dev/null; }
    # Same real-effect oracle as who_answers, on the OTHER display's i3.
    who_answers_b() {
        DISPLAY="$XB" i3-msg 'workspace nobody' >/dev/null 2>&1
        DISPLAY="$XB" python3 "$T/tap.py" F10
        if   DISPLAY="$XB" i3-msg -t get_workspaces 2>/dev/null \
             | grep -q 'daemon-owns-it'; then printf 'daemon\n'
        elif DISPLAY="$XB" i3-msg -t get_workspaces 2>/dev/null \
             | grep -q 'i3-owns-it';     then printf 'i3\n'
        else                                  printf 'nobody\n'
        fi
    }

    # A daemon on XA ONLY. panic's target list is the caller's display plus every
    # display running a daemon, so XB is deliberately outside it — that is the
    # precondition, not an oversight.
    DISPLAY="$XA" "$HERE/hotkeyd.sh" start "$XA" >/dev/null 2>&1
    sleep 1
    panic panic >/dev/null 2>&1
    sleep 0.5
    [ -L "$LINK" ] && ok "panic on $XA linked the fallback ($XB has no daemon)" \
        || bad "setup: no link after panicking on $XA"
    [ "$(daemons_on "$XB")" = 0 ] || bad "setup: $XB should have had no daemon"

    # THE PANIC WINDOW. XB reloads for a reason of its own — $mod+Shift+c, a
    # quickshell restart, an xrdp reconnect — and its i3 parses the fallback that
    # panic linked into the shared directory.
    DISPLAY="$XB" i3-msg reload >/dev/null 2>&1
    sleep 0.5
    if i3_config_b | grep -q 'workspace i3-owns-it'; then
        ok "an unrelated reload on $XB pulled in the machine-wide fallback"
    else
        bad "setup: $XB did not pick up the fallback on its own reload"
    fi
    answer="$(who_answers_b)"
    [ "$answer" = i3 ] && ok "and $XB's i3 holds the fallback's grab" \
        || bad "setup: expected i3 on $XB to hold the chord, got: $answer"

    # resume's EXIT CODE IS asserted again (dotfiles-f2be, closed by
    # dotfiles-hwds.23). It used to be deliberately unasserted: `target_displays`
    # pgreps every hotkeyd.py on the box — correct for a machine-wide recovery
    # tool — so a daemon belonging to another checkout of this repo (a second
    # agent running this very suite) landed in the state file, and resume then
    # reported a real failure to restart a daemon that was never ours.
    # Reproduced: a run whose XA/XB were :81/:82 tried to start on :87 and
    # exited 1. HOTKEYD_PGREP_SCOPE removes the cause rather than the assertion
    # — the state file can now only ever name $XA/$XB — so a non-zero resume
    # here is a genuine failure once more, and the sentinel on $XC proves the
    # foreign-daemon case is handled rather than merely absent today.
    out="$(panic resume 2>&1)"; rc=$?
    sleep 1
    [ "$rc" -eq 0 ] \
        && ok "resume exits 0 — no foreign daemon can enter this suite's state" \
        || bad "resume exited $rc: $out"
    if i3_config_b | grep -q 'workspace i3-owns-it'; then
        bad "$XB's loaded table still carries the fallback after resume (rc=$rc) \
— the link is gone, its grabs are not, and the start latch went with it"
    else
        ok "resume reloaded $XB, which panic never recorded — its loaded table \
is fallback-free"
    fi
    # Read as a real WM effect, not only from the config dump: no daemon was
    # started on XB (it never had one), so after resume NOBODY may answer.
    answer="$(who_answers_b)"
    [ "$answer" = nobody ] \
        && ok "and nobody holds the chord on $XB — the stale grabs are gone" \
        || bad "expected no owner on $XB after resume (rc=$rc), got: $answer"

    DISPLAY="$XA" "$HERE/hotkeyd.sh" stop "$XA" >/dev/null 2>&1
    DISPLAY="$XB" "$HERE/hotkeyd.sh" stop "$XB" >/dev/null 2>&1
fi

# --- 8c: UNSCOPED, the enumeration is still machine-wide (dotfiles-hwds.23) ---
# The other half of the fix, and the half that must never regress. Every case
# above runs with HOTKEYD_PGREP_SCOPE set, so every case above exercises the
# FILTERED path — and none of them would notice `scoped` dropping displays when
# the variable is ABSENT, which is every production invocation. That failure
# mode is a panic that quietly stops nothing: the direction dotfiles-hwds.12
# forbids, because a daemon panic misses keeps holding grabs the fallback is
# about to ask i3 for. "It is only a filter" has to be a finding, not a comment.
#
# Exercising it honestly means running panic UNSCOPED — which on a real box
# reaches the caller's live :0/:10, i.e. the defect itself. So `pgrep` is stubbed
# on PATH for this ONE invocation: the shipped script runs unmodified and with
# no scope, but the only daemon it can discover is a `sleep` this section
# started, on a display that does not exist. The real pgrep is never called, so
# nothing real is reachable — the sandbox is the stub, not a narrowing of the
# code under test.
echo "panic: with no scope set, the enumeration is still machine-wide"
FAKE_DPY=":9998"
# Short-lived on purpose. It only has to outlive one panic (a second or two),
# and it is killed twice over — at the end of this section and again in
# cleanup — but a stand-in process that survives BOTH is a leak on a box that
# already collects orphaned Xvfbs, so it also expires on its own.
sleep 45 &
FAKE_PID=$!
mkdir -p "$T/stub"
cat > "$T/stub/pgrep" <<EOF
#!/bin/sh
# hotkeyd-panic.sh asks with -af and no display; hotkeyd.sh asks per display.
# Anything else is "no daemon", so no other display can be reached from here.
case "\$*" in
    *-af*)         printf '$FAKE_PID python3 hotkeyd.py --display $FAKE_DPY\n' ;;
    *"$FAKE_DPY"*) printf '$FAKE_PID\n' ;;
    *)             exit 1 ;;
esac
EOF
chmod +x "$T/stub/pgrep"
out="$(env -u HOTKEYD_PGREP_SCOPE PATH="$T/stub:$PATH" DISPLAY="$XA" \
       "$HERE/hotkeyd-panic.sh" panic 2>&1)"; rc=$?
sleep 0.5
[ "$rc" -eq 0 ] || bad "unscoped panic exited $rc: $out"
if kill -0 "$FAKE_PID" 2>/dev/null; then
    bad "an unscoped panic did NOT stop the daemon on $FAKE_DPY — the scope \
filter leaks into production and panic now misses daemons it must stop"
else
    ok "an unscoped panic still stops a daemon on a display it was not called \
with — the machine-wide guarantee is intact"
fi
if grep -q "^$FAKE_DPY\$" "$XDG_RUNTIME_DIR/hotkeyd-panic.displays" 2>/dev/null
then
    ok "and records it, so resume brings that display back too"
else
    bad "$FAKE_DPY reached the stop loop but not the state file resume replays"
fi
# Cleaned up by hand rather than with `resume`: resume would run `hotkeyd.sh
# start $FAKE_DPY` against a display that does not exist and report a failure
# this case is not about.
rm -f "$LINK" "$XDG_RUNTIME_DIR/hotkeyd-panic.displays"
DISPLAY="$XA" i3-msg reload >/dev/null 2>&1
kill "$FAKE_PID" 2>/dev/null

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

# --- 10: the sentinel survived the WHOLE suite (dotfiles-hwds.23) ------------
# THE ACCEPTANCE CRITERION. Every panic in this file — sections 2, 4, 7, 7b, 8,
# 8b, 9 — ran with a real daemon alive on $XC. If the process sandbox holds, it
# is still alive; if it does not, the suite has been stopping daemons it never
# started, and on the desktop that set is the user's live :0 and :10. Asserted
# at the END rather than only after the first panic, because it takes one
# unscoped enumeration anywhere in the file to break the guarantee.
echo "panic: nothing outside the scope was touched by any of the above"
[ "$(daemons_on "$XC")" = 1 ] \
    && ok "the out-of-scope daemon on $XC is still running after the full suite" \
    || bad "the daemon on $XC did not survive the suite — running this on the \
desktop stops the live :0/:10 daemons"

# The override only sandboxes anything if PRODUCTION never sets it. A session
# entry point, an i3 exec, or the launcher exporting it would silently narrow
# the machine-wide guarantee panic exists to provide — the one fix direction
# dotfiles-hwds.12 and dotfiles-f2be both rule out — and would do it invisibly,
# because every case in this file would keep passing.
scope_hits="$(grep -rl 'HOTKEYD_PGREP_SCOPE' "$HERE" "$HERE/../i3" 2>/dev/null \
    | grep -Ev '/(hotkeyd-panic|test-panic|test-hotkeyd|test-launcher)\.sh$' \
    || true)"
[ -z "$scope_hits" ] \
    && ok "no shipped file sets HOTKEYD_PGREP_SCOPE — it is test-only" \
    || bad "HOTKEYD_PGREP_SCOPE is set outside the suite, which narrows panic \
in production: $scope_hits"

echo
printf 'panic: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
