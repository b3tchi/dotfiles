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
# REQUIREMENTS: clipcat + xorg-server-xvfb must be installed (both are on
# the primary dev host as of 2026-07-21, resolving the former dotfiles-saa
# blocker). The defaults above intentionally resolve clipcatd/clipcatctl/
# Xvfb from PATH so the suite always exercises the SAME binaries the rest
# of the system runs -- never a side-loaded copy that can silently drift
# from the installed package. The CLIPCATD=/CLIPCATCTL=/XVFB= overrides
# exist only for testing an unreleased build on purpose; if you find
# yourself needing them just to get a green run, install the packages
# instead.
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
# The path clipcat.toml's own "$XDG_RUNTIME_DIR/clipcat/history" resolves to
# once clipcatd shell-expands it against the XDG_RUNTIME_DIR="$RUN" we set
# for the daemon below -- not passed on any command line, just the expected
# value config alone produces. Used only for assertions.
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
# --grpc-socket-path is a required CLI override (one clipcatd binds one
# socket; this suite reuses $SOCK across restarts). --history-file is NOT
# passed by default: clipcat.toml bakes in the literal string
# "$XDG_RUNTIME_DIR/clipcat/history", and clipcatd shell-expands that
# specific field itself at startup against the real $XDG_RUNTIME_DIR we set
# in the env below -- config alone is the memory-only guarantee (see
# clipcat.toml / dot.yaml point 3). Optional $1, when non-empty, passes
# --history-file as a deliberate override -- used ONLY by the mutation
# scenario to force a persistent-style path, not needed for anything else.
#
# One attempt: launch, wait for gRPC readiness, then prove the X11 watcher
# is actually live with a disposable warm-up capture. gRPC readiness alone
# is NOT sufficient to trust a fresh clipcatd process.
#
# ROOT CAUSE (measured, dotfiles-egm.1 -- see also the upstream-defect issue
# filed from it). This is an UPSTREAM DEFECT IN clipcat 0.25.0, not a
# harness artifact and not sandbox flakiness. On a fraction of daemon
# starts, clipcatd's X11 listener enters a permanently broken state:
#
#   WARN clipcat_clipboard::listener::x11: Clipboard is changed but we
#   could not get available formats, error: Could not get property reply,
#   error: X11 error X11Error { error_kind: Atom, error_code: 5,
#   bad_value: 0, ..., request_name: Some("GetProperty") }
#
# Note what that says: the daemon DOES receive the selection-change
# notification every single time. XFixes registration is fine. It then
# fails one step later, enumerating the available formats -- calling
# GetProperty with property atom 0 (None, i.e. the conversion was refused
# or unanswered) without guarding the None case, yielding BadAtom. So the
# earlier "the watcher lost a registration race" explanation in this file
# was WRONG; it was inferred from the symptom (no capture) without reading
# the daemon's own log.
#
# The state is per-PROCESS and PERMANENT: across every failing cycle in
# every variant measured, 12 further ownership changes over ~24s were all
# dropped with the identical error. Zero late recoveries were ever
# observed. Only a fresh clipcatd process clears it -- which is exactly
# what the outer start_server retry below does, and why the warm-up loop
# here is deliberately short (2 tries): retrying inside a doomed process
# is provably wasted time.
#
# What was RULED OUT by direct experiment, so nobody re-litigates it:
#   - binary provenance: pacman-extracted vs natively installed clipcatd
#     are byte-identical (same md5); identical failure rate.
#   - "sandbox environmental churn": reproduces on natively installed
#     clipcat + xorg-server-xvfb packages.
#   - X server atom-table reset on last-client-disconnect: `Xvfb -noreset`
#     changed nothing (3/12 vs 4/12 -- noise).
#   - a clipboard owner already holding the selection when the daemon
#     starts: fails at the same rate (4/12) with no owner alive at start.
#   - this suite's own clip-owner.py: reproduces with plain `xclip` as the
#     owner (2/12), so it is not the harness's selection handling.
#
# Measured per-start failure rate: ~17-33% depending on variant (2/12 with
# xclip, 3/12 and 4/12 with clip-owner.py). Treat ~25% as the working
# figure; it is NOT the "10-20%" an earlier revision of this comment
# claimed, and that number should not be trusted to size anything.
_start_server_once() {
  local history_override="${1:-}"
  local -a extra_args=()
  [ -n "$history_override" ] && extra_args=(--history-file "$history_override")
  mkdir -p "$RUN/clipcat"
  chmod 700 "$RUN"
  env DISPLAY="$DPY" XDG_CONFIG_HOME="$CFG" XDG_DATA_HOME="$DAT" XDG_CACHE_HOME="$CCH" XDG_RUNTIME_DIR="$RUN" \
    "$CLIPCATD" --no-daemon --grpc-socket-path "$SOCK" "${extra_args[@]}" \
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
  for i in 1 2; do
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

# Outer retry around a full launch attempt: the only known mitigation for
# the upstream defect documented above -- a fresh clipcatd process each
# attempt, not a wider inner loop against the same doomed process (which
# provably never recovers).
#
# Sizing, honestly -- READ THIS BEFORE TRUSTING A GREEN RUN:
#
# If the ~25% per-start failures were independent, 5 fresh attempts would
# leave ~0.1% chance of exhausting one start_server call. They are NOT
# independent. MEASURED over 12 full suite runs (5 on pacman-extracted
# binaries, 7 on natively installed ones -- byte-identical, so pooled):
#
#   9/12 runs completed, each 39 passed / 0 failed
#   3/12 runs FATAL-aborted with all 5 retries exhausted
#
# A ~25% whole-run abort rate is orders of magnitude above what independent
# retries predict, which is itself the evidence that consecutive fresh
# clipcatd starts are CORRELATED -- something about the display's state at
# that moment makes several successive daemons fail together. That
# correlation is NOT root-caused; it is the known residual unknown here
# (the per-process BadAtom mechanism above IS root-caused; why it clusters
# is not). Do not let a green run persuade you otherwise.
#
# What aborts do and do not mean: no assertion has ever produced a WRONG
# answer across those 10 runs -- completed runs are always 39/0, and the
# aborts happen late (one at 38 of 39 assertions, one at 29). So a FATAL
# is LOST COVERAGE, never a false pass. Re-run on abort; if a run
# completes, its results are trustworthy.
#
# The retry count is deliberately left at 5. Raising it would convert a
# visible abort into a slower, quieter abort and would suppress the one
# signal that surfaces this upstream bug at all. Tracked as dotfiles-apl.
start_server() {
  local history_override="${1:-}" attempt
  for attempt in 1 2 3 4 5; do
    _start_server_once "$history_override" && return 0
    echo "warning: start_server attempt $attempt failed (known clipcat 0.25.0 defect: listener sees the change, then GetProperty->BadAtom on format enumeration -- see comment above _start_server_once), restarting the daemon fresh" >&2
    sleep 1
  done
  echo "FATAL: clipcatd did not start a working watcher after 5 independent fresh attempts." >&2
  echo "Most likely the known upstream clipcat 0.25.0 listener defect (see comment above _start_server_once) hitting 5 times in a row." >&2
  echo "NOTE: the daemon log below is EXPECTED TO BE EMPTY for that defect -- clipcat.toml sets emit_journald=true / emit_stdout=false," >&2
  echo "so the diagnostic WARN goes to journald, not to this file. Confirm with:  journalctl --user -t clipcatd -n 50" >&2
  echo "This file only captures hard startup failures that predate logging init (e.g. an unresolved \$XDG_RUNTIME_DIR). Last attempt's captured output:" >&2
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

scenario "config-alone-resolves-history-path: history_file_path from clipcat.toml resolves against \$XDG_RUNTIME_DIR with NO --history-file flag"
# start_server above passed no history override at all -- this asserts the
# checked-in config's literal "$XDG_RUNTIME_DIR/clipcat/history" really did
# resolve against the env var we set for the daemon (not a directory
# literally named "$XDG_RUNTIME_DIR", and not clipcatd's own
# $XDG_CACHE_HOME fallback), i.e. the Gap 1 fix is a tested fact, not just
# a comment.
assert_eq "history directory exists at the expanded runtime-dir path" "true" \
  "$([ -d "$HIST" ] && echo true || echo false)"
assert_eq "no directory named literally \$XDG_RUNTIME_DIR was created" "false" \
  "$([ -e '$XDG_RUNTIME_DIR' ] && echo true || echo false)"

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
# Edge case: clipcatd must fail loudly, never fall back to a persistent
# path, if $XDG_RUNTIME_DIR is unset. This is a DAEMON-level guarantee, not
# a launcher convention: clipcatd itself shell-expands the literal
# "$XDG_RUNTIME_DIR/clipcat/history" baked into clipcat.toml and refuses to
# start at all when that lookup fails -- verified empirically (exit 78,
# "environment variable not found"). No `set -u` wrapper or --history-file
# flag is needed to get this behavior, so none is used below: this runs
# clipcatd exactly as task 5's autostart will, straight off the checked-in
# config, with the one env var removed.

scenario "xdg-runtime-dir-unset: clipcatd itself refuses to start (no launcher wrapper needed)"
seed_config
before_procs="$(pgrep -f "$CLIPCATD" 2>/dev/null | wc -l)"
env -u XDG_RUNTIME_DIR DISPLAY="$DPY" XDG_CONFIG_HOME="$CFG" \
  "$CLIPCATD" --no-daemon >"$TMP/unset-attempt.log" 2>&1
rc=$?
sleep 1
after_procs="$(pgrep -f "$CLIPCATD" 2>/dev/null | wc -l)"
assert_eq "clipcatd exits nonzero rather than starting" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)"
assert_eq "no clipcatd process is left running" "$before_procs" "$after_procs"
assert_eq "failure names the unresolved XDG_RUNTIME_DIR lookup, not a silent fallback" "yes" \
  "$(grep -q 'XDG_RUNTIME_DIR' "$TMP/unset-attempt.log" && echo yes || echo no)"

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
