#!/usr/bin/env bash
# test-nav-mode.sh — runtime suite for the NAV LAYER (dotfiles-5u6m, sp020 T14).
#
# Same discipline as quickshell/test-*.sh: a private Xvfb, an i3 started on the
# REAL config.common with its own IPC socket, named scenarios, exit 1 on any
# failure. What it pins is behaviour that `i3 -C` cannot see — a config that
# parses clean can still bind the wrong action, or bind nothing at all because
# a keysym silently failed to translate.
#
# WHAT CHANGED, AND WHY THIS FILE IS A RE-POINT RATHER THAN A REWRITE
# (dotfiles-8qju). nav used to be an i3 `mode "nav"` in config.common. The T14
# cutover (71f6c4a8, dotfiles-hwds.16) moved it wholesale into the daemon's
# `LAYERS["nav"]` — then hotkeyd/binds.py, now the compiled-in `Layers` of
# hotkeyd/cmd/hotkeyd/config.go (dotfiles-ylmp.16) — and the daemon serves it
# over XI2 grabs.
# Every assertion here that read the MECHANISM went stale with it — i3's binding
# state, and the twelve `nop nav-*` marker binds that faked held-modifier
# reporting — and the suite sat at 17 passed / 15 failed on main.
#
# The assertions worth keeping are the ones about EFFECTS: focus moves, windows
# move, widths change, and the pixels of the focus ring. Those are the oracle
# sp020 demands of a cutover ("Test assertions on log lines or 'the process is
# running' in place of the actual WM effect" is an auto-reject), and they are
# engine-agnostic by construction — a window either moved or it did not. So the
# harness gained a real daemon and a reader for its state socket, and the
# effect assertions are carried over verbatim.
#
# What is GONE is only what described the old engine: the `nop` marker pairs and
# i3's binding-event `mods` field. i3 has no nav binds left to report, and the
# daemon publishes modifier state AS state rather than as a side effect of a
# bind — so the two scenarios that used to reconstruct a held modifier now read
# it, which is strictly less indirect. Where a `nop` pair proved "the bar was
# told", `mod=move` proves "the bar can be told, and the value is right".
#
# TWO ORACLES, because the reverted T6 attempt had only one (sp020 T14
# test_plan). Behaviour is the first. OWNERSHIP is the second, asserted BEFORE
# any behaviour is believed: zero `BadAccess` in the daemon's log, and no nav
# bind left in i3's LOADED config. A green behaviour run on a display where the
# daemon holds no grabs — because i3 still owned the chords and the daemon's
# requests were refused — is a false pass, and this is what rules it out.
#
# BOTH SHAPES (dotfiles-i7na). `NAV_TEST_MOD` selects what `$mod` resolves to —
# Mod4 is the native `:0` shape, Mod1 the xrdp `:10` shape — and `--both` (the
# default when run with no argument) runs the whole file twice, once per shape,
# on separate displays.
#
# THE Mod1 RUN IS THE ONE THAT MATTERS. With `$mod` = Mod1, nav's Alt+hjkl
# resize chords ARE i3's global `$mod+hjkl` focus binds. That collision is what
# reverted T6 (fd9e9f2): the daemon took `BadAccess` on all eight and Alt+h fell
# through to i3 as a plain focus — which, on a directional chord, still LOOKS
# exactly like nav working. Behaviour assertions cannot tell the two apart,
# which is why the ownership oracle runs first and why this shape needed to
# exist at all. On Mod4 those chords are distinct and always were, so the Mod4
# run pins only the weaker claim that every grab was granted.
#
# Both engines must agree on `$mod` or the run is meaningless, so the harness
# supplies it to i3 via `set $mod` AND to the daemon via the `i3wm.mod` X
# resource — the same two sources a real session uses (ft003).
#
# Isolation matters here: i3-msg with no `-s` resolves the socket of whatever
# i3 owns the X root atom, so an unsocketed harness would drive the developer's
# LIVE session (and really would put it into nav). Every call below passes
# -s "$I3SOCK", the config sets `ipc-socket` to match, and I3SOCK is EXPORTED
# over any inherited value so that the helpers this suite spawns — the daemon,
# the focus-ring painter — cannot resolve their way back to the real session.
#
# Windows are two `st` terminals identified by X11 window id, not title: st
# rewrites its own title from the shell prompt, so titles are not stable.
#
# How the bar PAINTS the layer is quickshell/test-mode-bar.sh's job; the
# focus-frame recolour is asserted here because it needs a real WM.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOTKEYD_DIR="$SCRIPT_DIR/../hotkeyd"
TMP="$(mktemp -d)"
# THE $mod SHAPE UNDER TEST (dotfiles-i7na). Mod4 is the native `:0` shape;
# Mod1 is the xrdp `:10` shape, and it is the interesting one: with $mod=Mod1,
# nav's RESIZE chords (Alt+hjkl) ARE i3's global $mod+hjkl focus binds. That
# exact collision reverted T6 (fd9e9f2) — the daemon took BadAccess on all
# eight and Alt+h fell through to i3 as a focus, which on a directional chord
# still LOOKS like nav working. config.common claims the XI2 port resolves it
# and cites a measurement, but that measurement was a one-off note in a
# comment; this run is what re-asserts it.
# Run BOTH shapes unless the caller pinned one. Re-exec rather than loop
# in-process: every display, socket, temp dir and trap in this file is
# per-invocation, so a second shape in the same process would have to unwind and
# rebuild all of it — and a leaked Xvfb or i3 from run one would silently serve
# run two. Two clean processes cost a few seconds and cannot do that.
if [ -z "${NAV_TEST_MOD:-}" ] && [ "${1:-}" != "--one" ]; then
  rc=0
  for _m in Mod4 Mod1; do
    printf '\n========== $mod=%s (%s shape) ==========\n' "$_m" \
      "$([ "$_m" = Mod4 ] && echo ':0 native' || echo ':10 xrdp')"
    # Absolute, via SCRIPT_DIR: "$0" is whatever the caller typed, and
    # `bash test-nav-mode.sh` from inside i3/ makes it a bare relative name that
    # is not on PATH.
    NAV_TEST_MOD="$_m" bash "$SCRIPT_DIR/$(basename "$0")" --one || rc=1
  done
  [ "$rc" -eq 0 ] && printf '\nboth shapes passed\n' \
                  || printf '\nAT LEAST ONE SHAPE FAILED\n'
  exit "$rc"
fi
NAV_TEST_MOD="${NAV_TEST_MOD:-Mod4}"
case "$NAV_TEST_MOD" in
  Mod1|Mod4) ;;
  *) echo "FATAL: NAV_TEST_MOD must be Mod1 or Mod4, got '$NAV_TEST_MOD'" >&2
     exit 1 ;;
esac
# Per shape, so the two runs can never collide on a display or a socket.
case "$NAV_TEST_MOD" in
  Mod4) DPY_DEFAULT=":94" ;;
  Mod1) DPY_DEFAULT=":95" ;;
esac
DPY="${NAV_TEST_DISPLAY:-$DPY_DEFAULT}"
I3SOCK="$TMP/i3.sock"
export I3SOCK
PASS=0
FAIL=0

cleanup() {
  [ -n "${BORDER_PID:-}" ] && kill "$BORDER_PID" 2>/dev/null
  # Reaped by PID, never `pkill -f hotkeyd`: the developer's own :0/:10 daemons
  # match that pattern, and so do sibling checkouts running this file.
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

# python3 stays on this list. The daemon is Go now (dotfiles-ylmp.16), but every
# OTHER python3 use below is a generic helper — the i3 GET_CONFIG speaker, the
# get_tree readers, the state-socket reader, the X-resource writer — and none of
# them ever imported a hotkeyd module. Dropping it would only make those fail
# later and less legibly.
for bin in Xvfb xdotool i3 i3-msg st python3; do
  command -v "$bin" >/dev/null || { echo "FATAL: $bin not found" >&2; exit 1; }
done

# THE DAEMON IS A BUILT BINARY NOW (dotfiles-ylmp.16), not a script the
# interpreter finds for free. Checked HERE, next to the other binaries and
# before an Xvfb/i3/two-st fixture is spent, because a missing build must not
# reach the behaviour assertions: every one of them would fail at once and the
# run would read as "the nav layer is broken" when nothing was ever serving it.
HOTKEYD_BIN="$HOTKEYD_DIR/hotkeyd"
[ -x "$HOTKEYD_BIN" ] || {
  echo "FATAL: no hotkeyd binary at $HOTKEYD_BIN (the nav layer has no server)." >&2
  echo "       This suite does not build it. Either:" >&2
  echo "         rotz install hotkeyd            # what a real session gets" >&2
  echo "         (cd $HOTKEYD_DIR && go build -o hotkeyd ./cmd/hotkeyd)" >&2
  exit 1; }

# $mod is set by the INCLUDING file in this repo's layering (ft003), so the
# harness supplies it exactly as i3/config and i3/config-xrdp do.
cat > "$TMP/harness.conf" <<CONFEOF
set \$mod $NAV_TEST_MOD
ipc-socket $I3SOCK
include $SCRIPT_DIR/config.common
CONFEOF

# -noreset: an X server RESETS when its LAST client disconnects, discarding
# every root-window property with it. The i3wm.mod resource below is written
# by a short-lived python process that is, at that moment, the only client —
# so without this the resource is wiped the instant it is written. MEASURED:
# write, exit, read from a second process -> Mod4 every time. A real session
# never sees this because i3 holds a connection throughout.
Xvfb "$DPY" -noreset -screen 0 1280x800x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 20); do [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break; sleep 0.5; done
[ -e "/tmp/.X11-unix/X${DPY#:}" ] || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

# The daemon resolves `$mod` from the `i3wm.mod` X RESOURCE (ft003), the same
# source i3 reads on a real session — xrdp/xinitrc merges `i3wm.mod: Mod1`, and
# native merges nothing so the Mod4 default stands. The harness must supply it
# the same way or the two engines disagree about what `$mod+o` even is: i3 grabs
# Mod1+o from harness.conf while the daemon grabs Mod4+o, and the shape this run
# claims to test does not exist.
#
# WRITTEN WITH python-xlib, NOT `xrdb -merge`. MEASURED on this box: against an
# Xvfb display `xrdb -merge` EXITS 0 and writes nothing — `xrdb -query` comes
# back empty and `xprop -root RESOURCE_MANAGER` reports "not found", with or
# without -nocpp. A setup step that reports success and silently does nothing is
# how the first version of this run passed 40/40 while the daemon was still on
# Mod4. python-xlib was the daemon's own dependency when this was written; the
# Go daemon speaks X11 itself and depends on nothing here (dotfiles-ylmp.16), so
# python-xlib is now purely a harness dependency — python3 is on the preflight
# list above for the other helpers regardless. Its write is verified below
# rather than trusted.
python3 - "$DPY" "$NAV_TEST_MOD" <<'XRESEOF' || {
import sys
from Xlib import display as xdisplay, Xatom
dpy, mod = sys.argv[1], sys.argv[2]
d = xdisplay.Display(dpy)
d.screen().root.change_property(
    Xatom.RESOURCE_MANAGER, Xatom.STRING, 8,
    ("i3wm.mod:\t%s\n" % mod).encode())
d.sync()
XRESEOF
  echo "FATAL: could not set i3wm.mod on $DPY" >&2; exit 1; }

# The resource must be read back THROUGH THE DAEMON'S OWN RESOLVER — if it does
# not land, every behaviour assertion below runs against the wrong shape and
# still passes, which is precisely the false pass this suite exists to rule out.
# That read-back now happens AFTER the daemon starts; see the $mod agreement
# gate below the daemon launch (dotfiles-ylmp.16).

# What xdotool must press to produce $mod. The CONFIG side of the shape is not
# enough on its own: the injected chord has to move with it, or a Mod1 run keeps
# pressing Super and tests the Mod4 daemon it accidentally still has.
case "$NAV_TEST_MOD" in
  Mod4) XDO_MOD="super" ;;
  Mod1) XDO_MOD="alt" ;;
esac

DISPLAY="$DPY" i3 -c "$TMP/harness.conf" >"$TMP/i3.log" 2>&1 &
I3_PID=$!
for _ in $(seq 1 20); do [ -S "$I3SOCK" ] && break; sleep 0.5; done
[ -S "$I3SOCK" ] || { echo "FATAL: harness i3 did not come up" >&2; tail -5 "$TMP/i3.log" >&2; exit 1; }
export DISPLAY="$DPY"

# The daemon owns the nav layer now. Start it against THIS display with its own
# runtime dir, and point it at the harness i3 explicitly — HOTKEYD_I3SOCK is the
# one override the resolver trusts (dotfiles-hwds.6), precisely so a test can
# aim a daemon at a specific WM without the ambient environment deciding.
#
# No --binds: the table is COMPILED INTO the binary, dwm config.h style
# (hotkeyd/cmd/hotkeyd/check.go's package doc), so the shipped table is the only
# one there is and this suite runs exactly what a session runs.
export XDG_RUNTIME_DIR="$TMP"
HOTKEYD_SOCK="$TMP/hotkeyd-${DPY#:}.sock"
HOTKEYD_I3SOCK="$I3SOCK" DISPLAY="$DPY" \
  "$HOTKEYD_BIN" --display "$DPY" >"$TMP/hotkeyd.log" 2>&1 &
HOTKEYD_PID=$!
for _ in $(seq 1 20); do [ -S "$HOTKEYD_SOCK" ] && break; sleep 0.3; done
[ -S "$HOTKEYD_SOCK" ] || {
  echo "FATAL: hotkeyd did not come up on $DPY" >&2
  tail -5 "$TMP/hotkeyd.log" >&2; exit 1; }

# --- the $mod agreement gate (dotfiles-ylmp.16) ------------------------------
#
# WHAT THIS REPLACED, AND WHY IT MOVED. This used to run BEFORE i3 and the
# daemon, as a preflight: it imported hotkeyd.py and called `x_resource_mod` to
# RE-DERIVE what the daemon would resolve. The Go daemon has the same resolver
# (`ResolveMod`, hotkeyd/cmd/hotkeyd/grabs.go:537, called from main.go:105) but
# does not expose it on the CLI, and nothing else does either: `--check` is
# headless by contract so it has no display to resolve against, and
# `check --ownership` deliberately reports EVERY entry in bind.ModResolutions
# rather than this display's one (hotkeyd/cmd/hotkeyd/ownership.go:239). So
# there is no out-of-process way to re-derive it.
#
# Reading the daemon's own startup line is strictly BETTER than re-deriving,
# and would have been the right shape even while hotkeyd.py existed: it reports
# what the running daemon ACTUALLY resolved and then grabbed with, so a resolver
# that drifted from the copy the harness re-implemented — or a daemon that read
# the resource before the harness wrote it — cannot slip through. The cost is
# that it can only be asserted once the daemon is up, which is why it sits here
# rather than at the top.
#
# The line is emitted by daemonLog (hotkeyd/cmd/hotkeyd/main.go:163) and reads:
#   hotkeyd: 70 chords grabbed on :94 via XI2 ($mod=Mod4)
# It is printed AFTER the state socket is bound (buildPublisher, main.go:131),
# so the socket wait above does not imply the line has landed — hence its own
# wait rather than a bare grep.
#
# Still FATAL, never a warning: a run whose daemon resolved the other $mod is
# testing a shape it does not claim to test, and on the Mod1 shape that is
# exactly the T6 false pass (Alt+h falling through to i3's focus bind) the
# suite exists to catch.
for _ in $(seq 1 20); do
  grep -q 'chords grabbed on .* via XI2 (\$mod=' "$TMP/hotkeyd.log" && break
  sleep 0.3
done
RESOLVED="$(sed -n 's/.*via XI2 (\$mod=\([^)]*\)).*/\1/p' "$TMP/hotkeyd.log" | head -1)"
[ -n "$RESOLVED" ] || {
  echo "FATAL: the daemon never logged its grab summary on $DPY, so what it" >&2
  echo "       resolved \$mod to is unknown — refusing to run $NAV_TEST_MOD blind" >&2
  tail -5 "$TMP/hotkeyd.log" >&2; exit 1; }
[ "$RESOLVED" = "$NAV_TEST_MOD" ] || {
  echo "FATAL: daemon resolves \$mod=$RESOLVED but this run is $NAV_TEST_MOD" >&2
  exit 1; }

# i3's config AS LOADED, including everything the include pulled in. `i3-msg -t
# get_config` drops the `included_configs` array from the reply and config.common
# arrives through an include, so i3-msg alone would report nav missing however
# badly the cutover had gone. This speaks GET_CONFIG (type 9) and prints the
# whole reply, variables already substituted — so `$mod+o` reads as `Mod4+o`.
cat > "$TMP/getconfig.py" <<'PYEOF'
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
    print(inc.get("variable_replaced_contents") or inc.get("raw_contents", ""))
PYEOF
# stderr is NOT swallowed. A read that fails must say why on the terminal; a
# silent empty string is what made every negative assertion below pass over a
# dead i3.
i3_config() { python3 "$TMP/getconfig.py" "$I3SOCK"; }

# --- oracle 2: OWNERSHIP, asserted before any behaviour is believed ----------
#
# sp020's anti-pattern list, quoted as written (the table it calls binds.py is
# hotkeyd/cmd/hotkeyd/config.go since dotfiles-ylmp.16; the rule is unchanged):
# "A chord present in both i3/config.common and binds.py at any commit
# boundary. It double-fires; migration is cutover, not duplication."
# And its Task 14 criterion: "the daemon obtains every grab it
# requests: zero BadAccess, asserted, not logged. This is the assertion whose
# absence let the reverted cutover merge green." That criterion names an
# `:10`-shaped display and this harness is Mod4, so what follows is the
# criterion's MECHANISM on the shape available here, not the criterion met —
# see the shape note in the header.
#
# Both are read here, at startup, because every scenario below is meaningless
# without them. If i3 still owned `mode "nav"`, `super+o` would enter i3's mode
# and every focus/move assertion would pass while testing the wrong engine —
# which is exactly the state this file was in before the re-point.
scenario "ownership: i3 has no nav left, and the daemon was refused nothing"
LOADED="$(i3_config)"

# POSITIVE CONTROL, and it runs FIRST because the three assertions after it are
# all NEGATIVE — each passes when a pattern is ABSENT, so an empty read
# satisfies every one of them. That is not hypothetical: pointed at an
# unreachable socket, `LOADED` is zero bytes and all three report 0, i.e. PASS,
# on a session that is already broken. It was also hit live, on a run where the
# harness i3 had died — four green ownership assertions over a dead WM. The
# `-S "$I3SOCK"` gate at startup does not close it, because the socket FILE
# outlives the process that bound it.
#
# Same discipline the layer reads get below, where a read that finds nothing
# says `unpublished` instead of falling back to `default`: a read that returned
# nothing must FAIL, not satisfy.
#
# Two markers, because there are two ways to read nothing useful. `ipc-socket`
# comes from harness.conf and proves the reply arrived at all. The panic bind
# comes from config.common and proves the INCLUDE was resolved — without it the
# reply is well-formed but carries none of the text the negatives search, so
# they would pass while looking at nothing. The panic bind is the right marker
# because sp020 lists migrating it out of i3 as an auto-reject, so it is the one
# line in that file guaranteed to stay put.
top_marker="$(printf '%s\n' "$LOADED" \
  | grep -cE '^[[:space:]]*ipc-socket[[:space:]]')"
inc_marker="$(printf '%s\n' "$LOADED" \
  | grep -cE "^[[:space:]]*bindsym[[:space:]]+([$]mod|$NAV_TEST_MOD)[+]Shift[+]r[[:space:]]")"
assert_eq "the GET_CONFIG reply arrived (top-level marker present)" \
  "$([ "$top_marker" -gt 0 ] && echo yes || echo no)" "yes"
assert_eq "and it carries the INCLUDED config.common (panic bind present)" \
  "$([ "$inc_marker" -gt 0 ] && echo yes || echo no)" "yes"

if [ "$top_marker" -gt 0 ] && [ "$inc_marker" -gt 0 ]; then
  assert_eq "i3's loaded config defines no \`mode \"nav\"\` block" \
    "$(printf '%s\n' "$LOADED" | grep -cE '^[[:space:]]*mode[[:space:]]+"nav"')" "0"
  assert_eq "i3's loaded config binds no entry chord for it" \
    "$(printf '%s\n' "$LOADED" | grep -cE "^[[:space:]]*bindsym[[:space:]]+([$]mod|$NAV_TEST_MOD)[+]o([[:space:]]|$)")" "0"
  # Matched as a BIND STATEMENT, not as a string. The reply carries comments
  # verbatim and config.common's cutover note names the markers in prose, so a
  # bare `grep -c 'nop nav-'` reports 1 on a correctly cut-over tree — measured.
  # What must be gone is a live marker bind, which is what this pattern reads.
  assert_eq "no \`nop nav-\` marker bind survives in i3's loaded config" \
    "$(printf '%s\n' "$LOADED" | grep -cE '^[[:space:]]*bind(sym|code)[[:space:]].*nop[[:space:]]+nav-')" "0"
else
  # Reported as failures, not skipped, and the count stays at five either way:
  # "the pattern is absent from a config we could not read" is not a finding
  # about ownership, and letting it score as one is the whole defect.
  assert_eq "i3's loaded config defines no \`mode \"nav\"\` block" \
    "unreadable config" "0"
  assert_eq "i3's loaded config binds no entry chord for it" \
    "unreadable config" "0"
  assert_eq "no \`nop nav-\` marker bind survives in i3's loaded config" \
    "unreadable config" "0"
fi

assert_eq "zero BadAccess in the daemon log at startup (every base grab taken)" \
  "$(grep -c 'BadAccess' "$TMP/hotkeyd.log")" "0"

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
#
# A read that finds NOTHING prints `unpublished`. The obvious alternative —
# treat "no state on the wire" as `default`, since that is what a session with
# no layer looks like — makes "Ctrl+q leaves nav" pass against a daemon that
# died, never bound its socket, or had its layer entry silently refused.
# `unpublished` matches no expectation, so those read as failures. It is not a
# theoretical case: with i3 holding `mode "nav"` again, the daemon publishes
# nothing at all and this is the value every layer read returns (measured).
# The publisher sends on CHANGE only, so nothing is on the wire until the first
# transition; no assertion here reads layer state before one has happened.
_state_field() { # <field>
  python3 - "$HOTKEYD_SOCK" "$1" <<'PYEOF'
import json, socket, sys
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(2)
buf = b""
try:
    c.connect(sys.argv[1])
    while b"\n" not in buf:
        chunk = c.recv(4096)
        if not chunk:
            break
        buf += chunk
except OSError:
    buf = b""
finally:
    c.close()
if not buf.strip():
    # Never "default": nothing was published, which is a finding, not a state.
    print("unpublished")
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
xdotool key "$XDO_MOD+o"; sleep 0.4
assert_eq "the daemon publishes layer=nav" "$(mode)" "nav"

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
# answers "what will the next keystroke do". i3 needed twelve bindcode `nop`
# marker binds to fake this, since it cannot report a held modifier; the daemon
# sees the modifier directly and publishes {"layer":"nav","mod":"move"}.
scenario "Ctrl alone publishes the move layer, releasing it publishes back"
xdotool keyup ctrl 2>/dev/null; sleep 0.3
xdotool key q; sleep 0.3; xdotool key "$XDO_MOD+o"; sleep 0.5
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

scenario "ALT is a third layer: Alt+hjkl RESIZE, and the layer still never changes"
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
assert_eq "still one layer throughout" "$(mode)" "nav"

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
# quickshell/qs-focus-border.py draws the focus ring and now follows HOTKEYD's
# layer feed rather than i3 mode events (dotfiles-hwds.9): nav left i3 in the
# cutover, so the "you are in a key-capturing mode" cue had to move with it —
# `COLOR_MODES` is `{'screenshot'}` now, and any non-default LAYER colours the
# ring. Asserted HERE because this is the only harness with a real i3, real
# windows to draw around, AND a real daemon publishing layers.
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
  # leave nav so the helper starts in the default-layer colour
  xdotool key q 2>/dev/null; sleep 0.3
  # XDG_RUNTIME_DIR is already this harness's TMP (the daemon's socket lives
  # there), so the helper resolves the same per-display socket the daemon bound.
  DISPLAY="$DPY" XDG_RUNTIME_DIR="$TMP" \
    python3 -u "$SCRIPT_DIR/../quickshell/qs-focus-border.py" \
    >"$TMP/border.log" 2>&1 &
  BORDER_PID=$!
  sleep 2.5
  i3-msg -s "$I3SOCK" 'focus left' >/dev/null; sleep 1.2

  scenario "focus frame is the normal colour in the default layer"
  TEAL_DEFAULT="$(ring_pixels 16A085)"
  RED_DEFAULT="$(ring_pixels CB4B16)"
  assert_eq "teal ring pixels present" "$([ "${TEAL_DEFAULT:-0}" -gt 0 ] && echo yes || echo no)" "yes"
  assert_eq "no red ring pixels yet" "$([ "${RED_DEFAULT:-0}" -gt 0 ] && echo yes || echo no)" "no"

  scenario "entering the nav LAYER repaints the SAME frame red (from the daemon feed)"
  xdotool key "$XDO_MOD+o"; sleep 1.5
  TEAL_NAV="$(ring_pixels 16A085)"
  RED_NAV="$(ring_pixels CB4B16)"
  assert_eq "red ring pixels present in nav" "$([ "${RED_NAV:-0}" -gt 0 ] && echo yes || echo no)" "yes"
  assert_eq "teal is gone (recoloured, not a second ring)" "$([ "${TEAL_NAV:-0}" -gt 0 ] && echo yes || echo no)" "no"

  scenario "holding Ctrl keeps it red — a mod change must not repaint the frame"
  xdotool keydown ctrl; sleep 1.2
  RED_TWIN="$(ring_pixels CB4B16)"
  assert_eq "still red while Ctrl is held" "$([ "${RED_TWIN:-0}" -gt 0 ] && echo yes || echo no)" "yes"
  xdotool keyup ctrl; sleep 0.6

  scenario "leaving the layer restores the normal colour"
  xdotool key q; sleep 1.5
  TEAL_BACK="$(ring_pixels 16A085)"
  RED_BACK="$(ring_pixels CB4B16)"
  assert_eq "teal ring is back" "$([ "${TEAL_BACK:-0}" -gt 0 ] && echo yes || echo no)" "yes"
  assert_eq "no red left behind" "$([ "${RED_BACK:-0}" -gt 0 ] && echo yes || echo no)" "no"

  kill "$BORDER_PID" 2>/dev/null
  BORDER_PID=
  xdotool key "$XDO_MOD+o"; sleep 0.4    # the exit scenarios below expect nav
fi

# The old suite asserted i3's binding events reported the mods it matched — the
# bar's corroborating signal when a `nop` went missing. Both the signal and the
# thing it corroborated are gone: i3 has no nav binds to report, and the daemon
# publishes modifier state as state rather than as a side effect of a bind.
# What replaces it is the pair of scenarios above, which read that state
# directly, plus the daemon suite's own coverage of the guard that expires a
# hold whose release was lost (hotkeyd/internal/layer/reconcile_test.go, the Go
# port of test_layers.py's reconciliation block — dotfiles-ylmp.16).

scenario "q exits — including with Ctrl physically held down"
xdotool keydown ctrl; sleep 0.2
xdotool key --clearmodifiers q; sleep 0.4
assert_eq "Ctrl+q leaves nav" "$(mode)" "default"
xdotool keyup ctrl; sleep 0.2
BEFORE="$(focused)"
xdotool key h; sleep 0.4
assert_eq "bare h is inert once the layer is gone" "$(focused)" "$BEFORE"

# Re-read at the END, after every layer entry and both sublayers. Layer chords
# are grabbed at ENTRY, not at startup, so the startup check above cannot see a
# refused `Ctrl+h` or `Alt+l`. A BadAccess on those is the T6 failure MODE: the
# daemon asks, i3 already owns the chord, the request is refused, and the
# keystroke falls through to i3 — which on a directional chord still LOOKS like
# nav working. On this Mod4 shape the specific T6 chords do not collide, so what
# this catches is any OTHER refusal; the run that would reproduce T6 itself is
# the Mod1 one (dotfiles-i7na).
scenario "ownership: no grab was refused across the whole session"
assert_eq "zero BadAccess in the daemon log after all three layers ran" \
  "$(grep -c 'BadAccess' "$TMP/hotkeyd.log")" "0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
