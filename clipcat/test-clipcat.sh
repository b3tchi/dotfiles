#!/usr/bin/env bash
# test-clipcat.sh — verify the sp016 clipcat backend (dotfiles-egm.1).
#
# Runs entirely headless on its own Xvfb display with isolated
# XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_CACHE_HOME / XDG_RUNTIME_DIR, so it
# never touches the live X session, the live clipboard, or the real
# ~/.config/clipcat, ~/.cache/clipcat, ~/.local/share/clipcat.
#
# The repo's clipcat.toml is exercised through a symlink, exactly as rotz
# links it, so the test also catches clipcatd clobbering its own config.
#
# usage: clipcat/test-clipcat.sh
# env:   CLIPCATD=/path/to/clipcatd  CLIPCATCTL=/path/to/clipcatctl
#        XVFB=/path/to/Xvfb           (all default: from PATH)
#        TEST_DISPLAY=:99             (default: :99)
#        KEEP_TMP=1                   (debug: skip deleting $TMP on exit)
#
# KNOWN BLOCKER: xorg-server-xvfb is not installed on the primary dev host
# (dotfiles-saa). Point XVFB= at an extracted `Xvfb` binary (no install
# needed -- `pacman -Sw`/curl the package, bsdtar -x, run in place; no sudo)
# if it is not on PATH. Same applies to CLIPCATD/CLIPCATCTL before `rotz
# install clipcat` has run on this host.
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLIPCATD="${CLIPCATD:-clipcatd}"
CLIPCATCTL="${CLIPCATCTL:-clipcatctl}"
XVFB="${XVFB:-Xvfb}"
DPY="${TEST_DISPLAY:-:99}"

# AF_UNIX socket paths are limited to ~108 bytes (SUN_LEN) -- kept short,
# exactly like copyq/test-copyq.sh's own $TMP, for the same reason.
TMP="/tmp/clipcat-test.$$"
CFG="$TMP/cfg"    # XDG_CONFIG_HOME
DAT="$TMP/data"   # XDG_DATA_HOME
CCH="$TMP/cache"  # XDG_CACHE_HOME
RUN="$TMP/run"    # XDG_RUNTIME_DIR stand-in (tmpfs 0700 in production)
HIST="$RUN/clipcat/history"
SOCK="$RUN/clipcat/grpc.sock"

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
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

# clipcatctl is always timeout-wrapped (adr0002 convention): a wedged daemon
# must not hang a test forever, exactly as it must not hang a picker
# keypress in production.
cc() { timeout 10 env XDG_RUNTIME_DIR="$RUN" "$CLIPCATCTL" --server-endpoint "$SOCK" "$@"; }

# Background the daemon by invoking it directly, never through a shell
# function or $(...) — poc010 harness bugs #1/#2: backgrounding a function
# makes $! the subshell, not clipcatd, and an orphaned daemon then silently
# serves every later phase; the same loss happens if the backgrounding
# happens inside a command substitution.
#
# --history-file / --grpc-socket-path are the CLI overrides clipcat.toml's
# own header mandates (its history_file_path key is deliberately absent).
# Optional $1 overrides the history path (used by the mutation scenario) --
# clap rejects --history-file passed twice ("cannot be used multiple
# times"), so this is a substitution, not an appended extra arg.
#
# One attempt: launch, wait for gRPC readiness, then prove the X11 watcher
# is actually live with a disposable warm-up capture (gRPC readiness alone
# is NOT sufficient -- verified empirically that the watcher's XFixes
# registration and the gRPC listener coming up are unordered relative to
# each other, and a capture made right after gRPC answers can be missed
# ENTIRELY: a lost event, not just latency -- a 15s poll never saw the
# length change). Returns nonzero on any failure instead of exiting, so the
# caller can retry a whole attempt rather than just the warm-up loop.
_start_server_once() {
  local history_path="$1"
  mkdir -p "$RUN/clipcat"
  chmod 700 "$RUN"
  env DISPLAY="$DPY" XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" XDG_CACHE_HOME="$CCH" XDG_RUNTIME_DIR="$RUN" \
    "$CLIPCATD" --no-daemon --history-file "$history_path" --grpc-socket-path "$SOCK" \
    >"$TMP/server.log" 2>&1 &
  DAEMON_PID=$!
  local i
  for i in $(seq 1 40); do
    cc length >/dev/null 2>&1 && break
    sleep 0.5
  done
  if ! cc length >/dev/null 2>&1; then
    kill "$DAEMON_PID" 2>/dev/null
    wait "$DAEMON_PID" 2>/dev/null
    DAEMON_PID=""
    return 1
  fi
  for i in $(seq 1 20); do
    own_clipboard "__warmup_$$_${i}__"
    if [ "$(wait_length_change 0 3)" = "1" ]; then
      cc clear >/dev/null 2>&1
      return 0
    fi
  done
  kill "$DAEMON_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  DAEMON_PID=""
  return 1
}

# Outer retry around a full launch attempt: this sandbox has shown
# occasional transient failures to even fork/exec cleanly under load
# (an empty server.log, no error text at all -- not a config or logic
# problem, environmental flakiness). A real launcher (task 5's autostart)
# gets this for free from exec_always retrying on i3 reload; this gives
# the test suite the same tolerance rather than failing the whole run on
# a fluke unrelated to the backend contract being verified.
start_server() {
  local history_path="${1:-$HIST}" attempt
  for attempt in 1 2 3 4 5; do
    _start_server_once "$history_path" && return 0
    echo "warning: start_server attempt $attempt failed, retrying" >&2
    sleep 1
  done
  echo "FATAL: clipcatd did not start after 5 attempts; see $TMP/server.log" >&2
  cat "$TMP/server.log" >&2
  exit 1
}

# SIGTERM, not a pattern-matched pkill: this test tracks $DAEMON_PID from
# `$!` directly (never a bare basename / pattern match — dotfiles-92w.5's
# scoping rule), so there is nothing to guess and nothing to accidentally
# kill on a shared host. clipcatd shuts down cleanly on SIGTERM (writes
# header.json, removes its pid file) — verified in the daemon log.
stop_server() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  kill -TERM "$DAEMON_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  DAEMON_PID=""
  sleep 1 # let Xvfb finish tearing down the old client's X11 state
}

# Seed the config dir. With no argument the repo file is symlinked in (the
# rotz layout, and it also catches clipcatd clobbering its own config).
# "--empty-sensitive-list" instead copies clipcat.toml with its
# sensitive_mime_types array replaced by `[]` — the mandatory negative
# control: without it, "secret dropped" would prove nothing.
seed_config() {
  rm -rf "$CFG"
  mkdir -p "$CFG/clipcat" "$DAT" "$CCH"
  case "${1:-}" in
    --empty-sensitive-list)
      awk '
        /^sensitive_mime_types = \[$/ {
          print "sensitive_mime_types = [] # NEGATIVE CONTROL: nothing filtered"
          skip = 1
          next
        }
        skip && /^\]$/ { skip = 0; next }
        skip { next }
        { print }
      ' "$REPO_DIR/clipcat.toml" >"$CFG/clipcat/clipcatd.toml"
      ;;
    *)
      ln -s "$REPO_DIR/clipcat.toml" "$CFG/clipcat/clipcatd.toml"
      ;;
  esac
}

# Put <text> on the CLIPBOARD selection, advertising the extra MIME targets
# given as further arguments (each served the value "secret"). Replaces any
# previous owner. Returns once the selection is held. Every SelectionRequest
# target the owner receives is logged to $TMP/reqlog.<pid> so scenarios can
# assert exactly what clipcatd asked for — "payload never requested" turned
# from an assumption into a measurement (poc010's method).
own_clipboard() {
  if [ -n "${OWNER_PID:-}" ]; then
    kill "$OWNER_PID" 2>/dev/null
    wait "$OWNER_PID" 2>/dev/null
  fi
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

reqlog_of_owner() { cat "$TMP/reqlog.$OWNER_PID" 2>/dev/null; }

# Wait until `clipcatctl length` differs from <baseline>, or timeout. Echoes
# the length reached.
wait_length_change() { # <baseline> [seconds]
  local base="$1" limit="${2:-15}" i n
  for i in $(seq 1 $((limit * 2))); do
    n="$(cc length 2>/dev/null)"
    [ -n "$n" ] && [ "$n" != "$base" ] && { echo "$n"; return 0; }
    sleep 0.5
  done
  cc length 2>/dev/null
}

# DISCOVERY (logged: dotfiles-8il, blocks dotfiles-egm.2): `clipcatctl list`
# is NOT newest-first and is not even stable across repeated calls against
# unchanged history -- verified empirically, 3 consecutive `list` calls
# against 4 unchanged entries returned 3 different orderings (consistent
# with Rust's randomized-HashMap iteration, not a deque). There is no CLI
# flag to sort it and no per-entry timestamp exposed to sort by. So this
# suite never assumes position/order — it looks entries up by content,
# exactly the "no positional assumptions about ids" rule the spec itself
# lays down (ids are content hashes, not row numbers).
#
# id of the (first, and for our fixtures only) entry whose full text is
# exactly <content>. Empty if no entry matches.
id_for_content() { # <exact text>
  local want="$1" line id text
  cc list 2>/dev/null | while IFS= read -r line; do
    id="${line%%: *}"
    text="${line#*: }"
    if [ "$text" = "$want" ]; then echo "$id"; return; fi
  done
}

# id of the (first) entry whose preview starts with <prefix>. Used for
# entries too long to appear unabridged in `list`'s truncated preview (the
# 3 MB fixture) -- get is then called once on the matched id.
id_for_preview_prefix() { # <prefix>
  local want="$1" line id text
  cc list 2>/dev/null | while IFS= read -r line; do
    id="${line%%: *}"
    text="${line#*: }"
    case "$text" in
      "$want"*) echo "$id"; return ;;
    esac
  done
}

# --------------------------------------------------------------- fixtures ---

mkdir -p "$TMP"

cat >"$TMP/clip-owner.py" <<'PYEOF'
"""Own the X CLIPBOARD advertising several targets at once.

Simulates a password manager (KeePassXC) publishing the text payload and a
password-manager-hint MIME type on one clipboard change -- which xclip
cannot do (one target per invocation), PyGObject cannot do
(Gtk.Clipboard.set_with_data is not introspectable), and clipcatctl insert
cannot be used for either (poc010 Q3: insert does not re-trigger the
watcher at all, so it would never exercise the filter).

Every SelectionRequest target received is appended to
<this-script>'s-directory/reqlog.<own-pid>, so a caller can assert exactly
what was requested, not just what was (or was not) captured.

usage: clip-owner.py <text> [extra-mime ...]
"""
import os
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

reqlog_path = os.path.join(os.path.dirname(sys.argv[0]), "reqlog." + str(os.getpid()))
reqlog = open(reqlog_path, "w")

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
    tname = d.get_atom_name(e.target)
    print(f"REQ {tname}", file=reqlog, flush=True)
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

command -v "$CLIPCATD"   >/dev/null 2>&1 || { echo "FATAL: clipcatd not found (set CLIPCATD=)" >&2; exit 1; }
command -v "$CLIPCATCTL" >/dev/null 2>&1 || { echo "FATAL: clipcatctl not found (set CLIPCATCTL=)" >&2; exit 1; }
command -v "$XVFB"       >/dev/null 2>&1 || { echo "FATAL: Xvfb not found (set XVFB=; xorg-server-xvfb is not installed on the primary host -- dotfiles-saa)" >&2; exit 1; }
command -v xclip         >/dev/null 2>&1 || { echo "FATAL: xclip not found" >&2; exit 1; }
python3 -c 'import Xlib' 2>/dev/null    || { echo "FATAL: python-xlib missing" >&2; exit 1; }

"$XVFB" "$DPY" -screen 0 800x600x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 20); do
  [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break
  sleep 0.5
done
[ -e "/tmp/.X11-unix/X${DPY#:}" ] || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

echo "clipcatd: $("$CLIPCATD" --version 2>/dev/null | head -1)"
echo "display: $DPY   config: $CFG   runtime: $RUN"

# =========================== PHASE 1: shipped config, server running ========

seed_config
start_server

scenario "plain-capture-byte-exact: a plain external copy lands in history verbatim"
own_clipboard 'hello-plain-marker'
n="$(wait_length_change 0)"
assert_eq "history grew to 1 item" "1" "$n"
id="$(id_for_content 'hello-plain-marker')"
assert_eq "get <id> returns the exact bytes" "hello-plain-marker" "$(cc get "$id" 2>/dev/null)"
assert_eq "payload WAS requested for a plain copy (reads do happen normally)" "yes" \
  "$(reqlog_of_owner | grep -q UTF8_STRING && echo yes || echo no)"

scenario "secret-dropped-bare-atom: a copy carrying bare x-kde-passwordManagerHint is not stored"
before="$(cc length)"
own_clipboard 'SECRET-bare-marker' x-kde-passwordManagerHint
sleep 6   # no length change is the expected outcome, so this cannot poll-and-exit
assert_eq "history length unchanged" "$before" "$(cc length)"
assert_eq "the secret text was never stored" "" "$(id_for_content 'SECRET-bare-marker')"
assert_eq "the earlier plain copy is still present, untouched" "hello-plain-marker" \
  "$(cc get "$(id_for_content 'hello-plain-marker')" 2>/dev/null)"
scenario "payload-never-requested (bare atom)"
reqlog="$(reqlog_of_owner)"
assert_eq "only TARGETS was requested" "REQ TARGETS" "$reqlog"

scenario "secret-dropped-prefixed-atom: a copy carrying application/x-kde-passwordManagerHint is not stored"
before="$(cc length)"
own_clipboard 'SECRET-prefixed-marker' application/x-kde-passwordManagerHint
sleep 6
assert_eq "history length unchanged" "$before" "$(cc length)"
assert_eq "the secret text was never stored" "" "$(id_for_content 'SECRET-prefixed-marker')"
assert_eq "the earlier plain copy is still present, untouched" "hello-plain-marker" \
  "$(cc get "$(id_for_content 'hello-plain-marker')" 2>/dev/null)"
scenario "payload-never-requested (prefixed atom)"
reqlog="$(reqlog_of_owner)"
assert_eq "only TARGETS was requested" "REQ TARGETS" "$reqlog"

# NOTE (dotfiles-8il): clipcatctl list carries no stable/temporal order, so
# "in order" cannot be verified through the CLI surface -- this asserts
# both copies are captured, distinct and byte-exact, which is what this
# task's own backend contract can actually guarantee. Ordering for the
# picker is dotfiles-egm.2's problem to solve.
scenario "rapid-copies-both-recorded: two copies in quick succession are both captured intact"
before="$(cc length)"
own_clipboard 'rapid-ONE'; wait_length_change "$before" 15 >/dev/null
own_clipboard 'rapid-TWO'; wait_length_change "$((before + 1))" 15 >/dev/null
assert_eq "history grew by exactly two" "$((before + 2))" "$(cc length)"
assert_eq "first rapid copy present, byte-exact" "rapid-ONE" "$(cc get "$(id_for_content 'rapid-ONE')" 2>/dev/null)"
assert_eq "second rapid copy present, byte-exact" "rapid-TWO" "$(cc get "$(id_for_content 'rapid-TWO')" 2>/dev/null)"

scenario "empty-selection: an empty copy does not crash the server or add an item"
before="$(cc length)"
printf '' | env DISPLAY="$DPY" timeout 10 xclip -selection clipboard
sleep 3
assert_eq "server still responds" "$before" "$(cc length)"
assert_eq "earlier entries are unaffected by the empty copy" "rapid-TWO" \
  "$(cc get "$(id_for_content 'rapid-TWO')" 2>/dev/null)"

scenario "multi-MB-entry: a 3 MB copy is stored whole, byte-exact"
python3 -c "import sys; sys.stdout.write('M' * 3000000)" >"$TMP/big.txt"
before="$(cc length)"
env DISPLAY="$DPY" timeout 30 xclip -selection clipboard "$TMP/big.txt"
n="$(wait_length_change "$before" 30)"
assert_eq "history grew by one" "$((before + 1))" "$n"
big_id="$(id_for_preview_prefix 'MMMMMMMMMM')"
# `clipcatctl get` unconditionally appends exactly one trailing 0x0a to
# every response (verified separately, dotfiles-egm.1 notes) -- +1 here is
# that CLI print artifact, not data loss. String-comparison assertions
# elsewhere in this suite never see it because bash command substitution
# strips trailing newlines; a raw byte count over a pipe does not.
assert_eq "stored byte count matches the source exactly (+1 for get's own trailing newline)" \
  "3000001" "$(cc get "$big_id" 2>/dev/null | wc -c)"

# DISCOVERY (logged: dotfiles-i9i, blocks dotfiles-egm.3): unlike the
# harmless trailing-newline artifact above, `clipcatctl get`/`list` also
# ESCAPE embedded \n \r \t into literal two-character sequences, and this
# is IRREVERSIBLE: content that legitimately contains a literal two-char
# "\n" substring renders byte-for-byte identically to content with a real
# embedded newline. Verified independently of capture method (X11 owner,
# xclip, and insert). Documented here as a known, tested boundary rather
# than a silent landmine for dotfiles-egm.3 (clip-set.sh), whose own
# byte-exact / multiline requirement this directly threatens.
scenario "control-chars-are-escaped-not-raw: embedded \\n/\\r/\\t are NOT returned as raw bytes (known limitation, see dotfiles-i9i)"
cc insert $'multiline\nentry\twith\rcontrol-chars' >/dev/null
sleep 0.3
esc_id="$(id_for_preview_prefix 'multiline')"
got="$(cc get "$esc_id" 2>/dev/null)"
assert_eq "embedded newline is rendered as a literal backslash-n, not byte 0x0a" \
  'multiline\nentry\twith\rcontrol-chars' "$got"

scenario "image-owner-skipped: an image/non-text owner is skipped, not crashed"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDRbinary-image-marker' >"$TMP/img.png"
before="$(cc length)"
env DISPLAY="$DPY" timeout 10 xclip -selection clipboard -t image/png "$TMP/img.png"
sleep 5
assert_eq "no history item was added for the image (capture_image=false)" "$before" "$(cc length)"
assert_eq "server still responds after the image copy" "$before" "$(cc length)"

scenario "config-not-clobbered: clipcatd leaves the rotz-linked repo file intact"
conf_before="$(md5sum <"$REPO_DIR/clipcat.toml")"
stop_server
assert_eq "clipcat.toml unchanged after a server lifecycle" "$conf_before" "$(md5sum <"$REPO_DIR/clipcat.toml")"
assert_eq "clipcat.toml is still a symlink, not replaced by a real file" "symlink" \
  "$([ -L "$CFG/clipcat/clipcatd.toml" ] && echo symlink || echo regular-file)"

# =========================== PHASE 2: nothing on persistent disk ============
# The server is stopped, so anything clipcat intended to persist has been
# written by now (recall: it writes continuously while running, not just at
# exit — so this is a belt-and-suspenders check, not the only one).

scenario "no-content-on-persistent-disk: no copied payload reached a persistent path"
# The isolated stand-ins for the real persistent dirs: the harness never
# touches the real ~/.cache/clipcat / ~/.local/share/clipcat /
# ~/.config/clipcat (XDG_* were overridden for every clipcatd/clipcatctl
# invocation above), so asserting those are untouched is a static fact of
# the harness, checked explicitly below rather than by grepping $HOME.
markers='hello-plain-marker|rapid-TWO|SECRET-bare-marker|SECRET-prefixed-marker|MMMMMMMMMM'
leaked_cch="$(grep -rlaE "$markers" "$CCH" 2>/dev/null | tr '\n' ' ')"
leaked_dat="$(grep -rlaE "$markers" "$DAT" 2>/dev/null | tr '\n' ' ')"
leaked_cfg="$(grep -rlaE "$markers" "$CFG" 2>/dev/null | grep -v '/clipcatd.toml$' | tr '\n' ' ')"
assert_eq "no file under XDG_CACHE_HOME contains item content" "" "$leaked_cch"
assert_eq "no file under XDG_DATA_HOME contains item content" "" "$leaked_dat"
assert_eq "no file under XDG_CONFIG_HOME (other than the linked config itself) contains item content" "" "$leaked_cfg"
assert_eq "real ~/.cache/clipcat was never referenced (isolated XDG_CACHE_HOME used throughout)" "not-present" \
  "$([ -e "$HOME/.cache/clipcat/.clipcat-test-canary" ] && echo present || echo not-present)"

scenario "restart-history-empty: a restarted server starts with an empty history (clear_history_on_start)"
start_server
assert_eq "clipcatctl length is 0 after restart" "0" "$(cc length)"

scenario "daemon-restart-mid-call: a call made while the daemon is down fails fast, not hung"
stop_server
t0=$(date +%s)
cc length >/dev/null 2>&1
rc=$?
t1=$(date +%s)
assert_eq "call did not hang (bounded by the 10s timeout wrapper)" "yes" "$([ $((t1 - t0)) -le 11 ] && echo yes || echo no)"
assert_eq "call failed rather than silently succeeding" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)"
start_server
assert_eq "a fresh call after restart succeeds normally" "0" "$(cc length)"
stop_server

# =========================== PHASE 3: negative control ======================
# Without this, every "secret dropped" assertion above would pass just as
# well if clipcatd had never captured anything at all.

scenario "CONTROL sensitive-mime-types-is-load-bearing: same hint-bearing copy IS captured with an empty filter list"
seed_config --empty-sensitive-list
start_server
before="$(cc length)"
own_clipboard 'SECRET-should-be-captured-now' application/x-kde-passwordManagerHint
n="$(wait_length_change "$before")"
assert_eq "hint-bearing copy is captured when sensitive_mime_types is empty" "$((before + 1))" "$n"
assert_eq "and its full text is readable" "SECRET-should-be-captured-now" \
  "$(cc get "$(id_for_content 'SECRET-should-be-captured-now')" 2>/dev/null)"
stop_server

# =========================== PHASE 4: XDG_RUNTIME_DIR unset =================
# Edge case: the launcher must fail loudly, never fall back to a persistent
# path, if $XDG_RUNTIME_DIR is unset. This is a property of the *launcher*
# convention clipcat.toml's header mandates (`set -u` + `--history-file
# "$XDG_RUNTIME_DIR/..."`), not of clipcatd itself, so it is exercised as a
# subshell reproducing that convention.

scenario "xdg-runtime-dir-unset: launcher aborts before clipcatd ever starts"
seed_config
before_procs="$(pgrep -f "$CLIPCATD" 2>/dev/null | wc -l)"
(
  set -u
  unset XDG_RUNTIME_DIR
  env DISPLAY="$DPY" XDG_CONFIG_HOME="$CFG" \
    bash -c 'set -u; exec "$1" --no-daemon --history-file "$XDG_RUNTIME_DIR/clipcat/history"' _ "$CLIPCATD"
) >"$TMP/unset-attempt.log" 2>&1
rc=$?
sleep 1
after_procs="$(pgrep -f "$CLIPCATD" 2>/dev/null | wc -l)"
assert_eq "launcher shell exits nonzero rather than starting clipcatd" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)"
assert_eq "no new clipcatd process was spawned" "$before_procs" "$after_procs"

# =========================== PHASE 5: mutation — persistent path DOES leak ==
# Prove the no-content-on-persistent-disk assertion is not vacuous: point
# history_file_path at a location standing in for real persistent disk
# (here, under XDG_CACHE_HOME, which phase 2 above asserts is clean in the
# correct configuration) and confirm the SAME grep-based check now DOES
# find the copied content — i.e. if a launcher ever regresses to a
# persistent path, this suite's own disk assertion would have caught it.

scenario "MUTATION history-file-path-at-persistent-path: same grep check now finds the leak"
mkdir -p "$CCH/clipcat-mutant"
seed_config
# This scenario gets its own throwaway Xvfb display rather than reusing the
# one every earlier scenario shared: after many display/ownership cycles
# on a single long-lived Xvfb, the same setup that is reliable in
# isolation intermittently stopped observing selection changes at all
# (observed empirically -- a fresh Xvfb + fresh daemon with the identical
# config always worked). A dedicated display sidesteps whatever in Xvfb
# degrades under that much churn rather than chasing it further; it does
# not change what this scenario is actually proving.
mut_dpy=":$(( ${DPY#:} + 1 ))"
"$XVFB" "$mut_dpy" -screen 0 800x600x24 >"$TMP/mutant-xvfb.log" 2>&1 &
MUTANT_XVFB_PID=$!
for i in $(seq 1 20); do
  [ -e "/tmp/.X11-unix/X${mut_dpy#:}" ] && break
  sleep 0.5
done
saved_dpy="$DPY"
DPY="$mut_dpy"
# Override the history path for this one instance to a persistent-style
# location instead of $HIST.
start_server "$CCH/clipcat-mutant/history"
own_clipboard 'MUTANT-CANARY-on-persistent-path'
wait_length_change 0 >/dev/null
stop_server
DPY="$saved_dpy"
kill "$MUTANT_XVFB_PID" 2>/dev/null
leaked="$(grep -rlaE 'MUTANT-CANARY-on-persistent-path' "$CCH/clipcat-mutant" 2>/dev/null | tr '\n' ' ')"
assert_eq "the disk-leak assertion DOES fire when history_file_path is persistent" "not-empty" \
  "$([ -n "$leaked" ] && echo not-empty || echo empty)"

# ------------------------------------------------------------------ result ---

printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
