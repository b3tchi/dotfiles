#!/usr/bin/env bash
# test-clip-integration.sh — verify the sp014 i3 wiring: the clipboard-history
# picker keybind in the base config, and the copyq/feeder autostarts in the
# platform overlays.  (dotfiles-92w.5.)
#
# WHAT THIS SUITE REFUSES TO DO, AND WHY
#
# The obvious way to test i3 config is `grep`, and a grep suite here is very
# nearly worthless: a pattern that matches its own explanatory comment passes,
# and a pattern that matches nothing at all also passes if nobody checks the
# match count.  Both failure modes have already been paid for in this epic.
# So:
#
#  * Comments are stripped before anything is matched.  i3 only honours `#` at
#    the start of a line, so that is exactly the rule applied.
#  * Every extraction asserts HOW MANY lines it matched, not just that it
#    matched.  A zero-match extraction fails loudly instead of vacuously.
#  * The "is the key actually bound, and bound only once" question is answered
#    by i3's OWN PARSER, not by a regex: a probe binding for the same combo is
#    appended to a copy of the config and i3 -C is asked whether that is a
#    duplicate.  A negative control (a combo that is genuinely unbound) proves
#    the detector does not simply always fire.
#  * The idempotency claims are answered by RUNNING the command strings lifted
#    out of the shipped config, twice, and counting processes — not by reading
#    the word "exec_always" and believing it.
#  * Section [mutation] re-runs the structural assertions against deliberately
#    broken copies and requires them to FAIL.  Each mutation first asserts its
#    own sed anchor actually matched (by line-count delta), because a mutation
#    whose anchor silently missed produces a fake "survivor".
#
# The live session is never touched.  i3 itself is only ever run as `i3 -C`
# (parse-and-exit) — a real i3 would run the base config's `pkill -x autocutsel`
# and `pkill -f qs-title-trim` autostarts and kill the user's live helpers.
# The keybind's command is exercised against a stub planted under a throwaway
# $HOME, so the real qs-clip.sh (which would find and toggle the user's live
# quickshell) never runs.  copyq and the feeder run on a throwaway Xvfb with
# an isolated XDG_CONFIG_HOME and a feeder source display that does not exist.
#
# THE FEEDER PATTERN, AND WHY IT IS A FULL PATH
#
# This suite starts and stops clip-feed.sh processes.  An earlier revision
# matched them on the BASENAME (`pgrep -f 'clip-feed\.sh$'`), which cannot tell
# this suite's feeder under $TMP from the PRODUCTION feeder that
# config.d/native.conf autostarts at ~/.i3/scripts/clip-feed.sh — the very
# deployment this task creates.  On a deployed machine that suite killed the
# live feeder, started its own, asserted "exactly 1" and went GREEN, while
# cross-display clipboard silently stayed dead until the next i3 reload (the
# autostart is exec_always, so nothing restarts it before then).  Merged task .2
# had already got this right — test-clip-feed.sh scopes with `pgrep -f -- "$FEEDER"`.
#
# So: every start/stop/count here is scoped to $FEED_PATH, an absolute path
# unique to this run ($TMP carries $$).  A feeder anywhere else is invisible to
# this suite and is never signalled.
#
# The basename pattern survives in exactly one place — foreign_feeders(), a
# preflight tripwire that ABORTS when it finds a feeder outside this run's path,
# and never kills one.  With full-path scoping a foreign feeder is already
# harmless, so this is defence in depth: if the scoping is ever regressed back
# to a basename match, the tripwire fires first and the suite refuses to run
# instead of destroying production.  Consequence, stated plainly: on a deployed
# machine you must stop your own feeder before running this suite.  That is the
# intended trade — a refusal to run is recoverable, a silent kill is not.
#
# [decoy-safety] proves the scoping holds, rather than trusting it: a decoy
# feeder is planted at an unrelated path and asserted still alive after the
# sections that start, stop and count feeders have all run.
#
# usage: i3/scripts/test-clip-integration.sh
# env:   COPYQ=  XVFB=  I3=   (default: from PATH)
#        TEST_DISPLAY=:95   TEST_FEED_SRC=:94   (throwaway displays)
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"   # <repo>/i3
BASE="$REPO_DIR/config"
NATIVE="$REPO_DIR/config.d/native.conf"
WSL="$REPO_DIR/config.d/wsl.conf"
FEEDER="$REPO_DIR/scripts/clip-feed.sh"

COPYQ="${COPYQ:-copyq}"
XVFB="${XVFB:-Xvfb}"
I3="${I3:-i3}"
DPY="${TEST_DISPLAY:-:95}"
FEED_SRC="${TEST_FEED_SRC:-:94}"     # deliberately a display that is not up

TMP="/tmp/clip-integration-test.$$"  # short: copyq's socket lives under $CFG

# The ONLY feeder this suite may ever signal or count.  Absolute, and unique to
# this run because $TMP carries $$.  See "THE FEEDER PATTERN" in the header.
FEED_PATH="$TMP/xhome/.i3/scripts/clip-feed.sh"
# The [decoy-safety] stand-in for a production feeder: basename identical,
# path unrelated.  Mirrors ~/.i3/scripts/clip-feed.sh, which is what
# config.d/native.conf autostarts.
DECOY_PATH="$TMP/prodsim/.i3/scripts/clip-feed.sh"

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
  stop_feeders
  # The decoy is ours, so it dies by PID — never by pattern.
  [ -n "${DECOY_PID:-}" ] && kill "$DECOY_PID" 2>/dev/null
  cq exit >/dev/null 2>&1
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

mkdir -p "$TMP"

# --------------------------------------------------------------- helpers ---

# i3 honours `#` only at the start of a line.  Everything downstream matches
# against this, so no assertion can ever be satisfied by its own comment.
uncomment() { grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$'; }

# Non-comment lines of <file> matching <ere>, one per line.
lines_matching() { # <file> <ere>
  uncomment "$1" | grep -E "$2" || true
}

count_matching() { # <file> <ere>
  lines_matching "$1" "$2" | grep -c . || true
}

# A throwaway ~/.i3 tree holding the base config plus exactly one overlay,
# mirroring what rotz links.  Echoes the fake HOME.
mk_home() { # <name> <overlay-path>
  local h="$TMP/$1"
  rm -rf "$h"
  mkdir -p "$h/.i3/config.d"
  cp "$BASE" "$h/.i3/config"
  cp "$2" "$h/.i3/config.d/$(basename "$2")"
  printf '%s\n' "$h"
}

# i3's own verdict on a config tree: its stderr, or empty when it is happy.
i3_errors() { # <fake-home>
  HOME="$1" "$I3" -C -c "$1/.i3/config" 2>&1 | grep -E '^[0-9].*- ERROR:' || true
}

# copyq servers on $DPY.  Counted from /proc rather than a bare `pgrep -c`,
# because a copyq session is TWO processes — the server (`copyq -s`) and the
# clipboard monitor (`copyq --clipboard-access monitorClipboard`) — and only
# the first is a server.  The DISPLAY filter keeps a stray copyq belonging to
# the user's real session from ever being counted.
count_copyq_servers() {
  local n=0 pid argv dpy
  for pid in $(pgrep -x copyq 2>/dev/null); do
    argv="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
    case "$argv" in *' -s '*) ;; *) continue ;; esac
    dpy="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
           | sed -n 's/^DISPLAY=//p' | head -1)"
    [ "$dpy" = "$DPY" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Feeders belonging to THIS run, matched on the full unique path.  A feeder at
# any other path — production's ~/.i3/scripts/clip-feed.sh above all — is not
# counted and, in stop_feeders, not signalled.
count_feeders() {
  pgrep -f -- "$FEED_PATH" 2>/dev/null | grep -c . || true
}

stop_feeders() {
  pkill -f -- "$FEED_PATH" 2>/dev/null
  return 0
}

# The tripwire: feeders matched by BASENAME that are not ours and not the
# decoy.  Reported, never killed.  Prints "<pid> <cmdline>" per line.
foreign_feeders() {
  local pid argv
  for pid in $(pgrep -f "clip-feed\.sh$" 2>/dev/null); do
    argv="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
    case "$argv" in
      *"$FEED_PATH"*|*"$DECOY_PATH"*) continue ;;
    esac
    printf '%s %s\n' "$pid" "$argv"
  done
}

cq() { env DISPLAY="$DPY" XDG_CONFIG_HOME="$TMP/cfg" XDG_DATA_HOME="$TMP/dat" \
           XDG_CACHE_HOME="$TMP/cch" "$COPYQ" "$@"; }

# ------------------------------------------------------------ preflight ----

for tool in "$I3" "$COPYQ" "$XVFB" flock; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (I3=/COPYQ=/XVFB= to override)" >&2; exit 1; }
done
for f in "$BASE" "$NATIVE" "$WSL" "$FEEDER"; do
  [ -r "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

# Tripwire — see "THE FEEDER PATTERN" in the header.  Nothing is killed; the
# suite refuses to run.  On a deployed machine the production feeder started by
# config.d/native.conf lands here, and stopping it yourself is the price of
# running this suite.
FOREIGN="$(foreign_feeders)"
if [ -n "$FOREIGN" ]; then
  {
    echo "FATAL: a clip-feed.sh is running outside this test run:"
    printf '  %s\n' "$FOREIGN"
    echo
    echo "Refusing to start. This suite never signals a feeder it did not start"
    echo "(killing the production feeder would break cross-display clipboard"
    echo "until the next i3 reload, silently and with a green test run)."
    echo "Stop it yourself and re-run."
  } >&2
  exit 1
fi

echo "=== sp014 i3 integration (dotfiles-92w.5) ==="

# The decoy stands in for a production feeder for the rest of the run: same
# basename, unrelated path, planted only AFTER the tripwire has cleared so it
# is never mistaken for one.  [decoy-safety] at the end asserts it survived.
mkdir -p "$(dirname "$DECOY_PATH")"
cat > "$DECOY_PATH" <<'DECOY'
#!/bin/sh
# Stand-in for the production feeder. Must outlive this suite.
while :; do sleep 1; done
DECOY
chmod +x "$DECOY_PATH"
"$DECOY_PATH" & DECOY_PID=$!
sleep 1

# =========================================================== [config-parse] ==
#
# Both platform trees must parse clean.  This is also the standing collision
# check: i3 reports a duplicate keybinding as a config ERROR, so a clean parse
# means nothing in the base config or either overlay binds the same combo
# twice — including the picker key this task adds.

scenario "config-parse: base + native.conf validates with no i3 errors"
H_NATIVE="$(mk_home native "$NATIVE")"
ERR="$(i3_errors "$H_NATIVE")"
assert_eq "native tree parses clean" "" "$ERR"

scenario "config-parse: base + wsl.conf validates with no i3 errors"
H_WSL="$(mk_home wsl "$WSL")"
ERR="$(i3_errors "$H_WSL")"
assert_eq "wsl tree parses clean" "" "$ERR"

# ================================================================ [keybind] ==
#
# "Is $mod+Shift+v bound to the picker?" is asked of i3's parser, not of grep.
# A probe binding for the same combo is appended to the overlay; if the base
# config really binds that combo, i3 must call the probe a duplicate.  The
# negative control uses a combo nothing binds, and must NOT produce one — that
# is what stops the positive case from being a detector that always fires.

probe_dup() { # <fake-home> <overlay-basename> <combo>  -> "dup" | "nodup"
  local h="$1" ov="$2" combo="$3"
  cp "$BASE" "$h/.i3/config"
  cp "$REPO_DIR/config.d/$ov" "$h/.i3/config.d/$ov"
  printf 'bindsym %s nop\n' "$combo" >> "$h/.i3/config.d/$ov"
  if i3_errors "$h" | grep -qi 'Duplicate keybinding'; then
    printf 'dup\n'
  else
    printf 'nodup\n'
  fi
}

scenario "keybind: i3 sees \$mod+Shift+v as already bound (native)"
assert_eq "probe on \$mod+Shift+v is a duplicate" \
  "dup" "$(probe_dup "$H_NATIVE" native.conf '$mod+Shift+v')"

scenario "keybind: negative control — an unbound combo is not a duplicate"
assert_eq "probe on \$mod+Shift+F12 is not a duplicate" \
  "nodup" "$(probe_dup "$H_NATIVE" native.conf '$mod+Shift+F12')"

scenario "keybind: i3 sees \$mod+Shift+v as already bound (wsl)"
assert_eq "probe on \$mod+Shift+v is a duplicate" \
  "dup" "$(probe_dup "$H_WSL" wsl.conf '$mod+Shift+v')"

# Restore the two trees the probes scribbled on.
H_NATIVE="$(mk_home native "$NATIVE")"
H_WSL="$(mk_home wsl "$WSL")"

# The command side: exactly one binding in the base config mentions qs-clip.sh,
# and it is on the picker key.  The count assertion is the point — a regex that
# matched nothing would otherwise sail through the string comparison below.
scenario "keybind: exactly one qs-clip.sh binding exists in the base config"
assert_eq "qs-clip.sh bindsym count" "1" "$(count_matching "$BASE" '^bindsym .*qs-clip\.sh')"

CLIP_BIND="$(lines_matching "$BASE" '^bindsym .*qs-clip\.sh')"
CLIP_KEY="$(printf '%s\n' "$CLIP_BIND" | awk '{print $2}')"
CLIP_CMD="$(printf '%s\n' "$CLIP_BIND" | sed -e 's/^bindsym [^ ]* exec //' -e 's/--no-startup-id //')"

scenario "keybind: the picker is on \$mod+Shift+v"
assert_eq "bound combo" '$mod+Shift+v' "$CLIP_KEY"

scenario "keybind: the picker binding lives in the BASE config, not an overlay"
assert_eq "native.conf qs-clip.sh lines" "0" "$(count_matching "$NATIVE" 'qs-clip\.sh')"
assert_eq "wsl.conf qs-clip.sh lines"    "0" "$(count_matching "$WSL" 'qs-clip\.sh')"

scenario "keybind: it opens the picker and pins no DISPLAY"
assert_eq "command" '~/.dotfiles/quickshell/qs-clip.sh toggle' "$CLIP_CMD"
# qs-clip.sh derives the session from the live quickshell instances; a DISPLAY
# forced in from i3 would defeat that (adr0004: two sessions are live at once).
assert_eq "no DISPLAY= in the binding" "0" \
  "$(printf '%s\n' "$CLIP_BIND" | grep -c 'DISPLAY=' || true)"
# Scope: this is a picker, not a paste tool.  qs-clip.sh's own subcommands are
# toggle/list/set; `paste` would be a different (rejected) feature.
assert_eq "command does not invoke a paste path" "0" \
  "$(printf '%s\n' "$CLIP_CMD" | grep -ci 'paste' || true)"

# The command string as shipped, actually executed.  $HOME points at a fake
# tree whose .dotfiles/quickshell/qs-clip.sh is a recorder, so tilde expansion
# and argv are exercised for real while the real qs-clip.sh — which would find
# and toggle the user's live quickshell — never runs.
scenario "keybind: executing the shipped command string calls the picker with 'toggle'"
STUBHOME="$TMP/stubhome"
mkdir -p "$STUBHOME/.dotfiles/quickshell"
cat > "$STUBHOME/.dotfiles/quickshell/qs-clip.sh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "$TMP/picker.argv"
STUB
chmod +x "$STUBHOME/.dotfiles/quickshell/qs-clip.sh"
rm -f "$TMP/picker.argv"
( HOME="$STUBHOME" sh -c "$CLIP_CMD" ) >/dev/null 2>&1
assert_eq "picker argv" "toggle" "$(cat "$TMP/picker.argv" 2>/dev/null)"

# ======================================================== [native-autostart] ==

scenario "native.conf: starts exactly one copyq server, on every reload"
assert_eq "copyq --start-server exec lines" "1" \
  "$(count_matching "$NATIVE" '^exec.*copyq --start-server')"
assert_eq "and it is exec_always (survives a reload)" "1" \
  "$(count_matching "$NATIVE" '^exec_always .*copyq --start-server')"

scenario "native.conf: starts the cross-display feeder"
assert_eq "clip-feed.sh exec lines" "1" \
  "$(count_matching "$NATIVE" '^exec.*clip-feed\.sh')"
assert_eq "and it is exec_always" "1" \
  "$(count_matching "$NATIVE" '^exec_always .*clip-feed\.sh')"

# The feeder's single-instance guard is an flock held on an open fd.  A
# pkill+restart (the mould used for clip-sync.sh) races that lock: the new
# feeder can see it still held by an inherited fd, conclude it is the
# duplicate, and exit — leaving none running.  See clip-feed.sh's header.
scenario "native.conf: the feeder is not pkill-restarted (would defeat its flock)"
assert_eq "pkill lines mentioning clip-feed" "0" \
  "$(count_matching "$NATIVE" 'pkill.*clip-feed')"

scenario "native.conf: copyq is invoked env-free (copyq/dot.yaml client contract)"
# The server socket lives inside the config dir, so an XDG_CONFIG_HOME or a
# DISPLAY forced on here would move the socket away from every client.
assert_eq "env-juggling on the copyq line" "0" \
  "$(lines_matching "$NATIVE" '^exec.*copyq --start-server' | grep -cE 'XDG_CONFIG_HOME|DISPLAY=' || true)"

# =========================================================== [wsl-autostart] ==

scenario "wsl.conf: starts exactly one copyq server, on every reload"
assert_eq "copyq --start-server exec lines" "1" \
  "$(count_matching "$WSL" '^exec.*copyq --start-server')"
assert_eq "and it is exec_always" "1" \
  "$(count_matching "$WSL" '^exec_always .*copyq --start-server')"

# WSL has a single display: its copies already reach its own server, and a
# feeder would have it watch the display it is serving.
scenario "wsl.conf: no feeder — single display"
assert_eq "clip-feed references" "0" "$(count_matching "$WSL" 'clip-feed')"

# ============================================================== [idempotent] ==
#
# The claims above are about text.  These run the extracted command strings for
# real, twice and three times, and count processes.

CQ_CMD="$(lines_matching "$NATIVE" '^exec_always .*copyq --start-server' \
          | sed 's/^exec_always --no-startup-id //')"
FEED_CMD="$(lines_matching "$NATIVE" '^exec_always .*clip-feed\.sh' \
            | sed 's/^exec_always --no-startup-id //')"

scenario "idempotent: the extracted command strings are the shipped ones"
assert_eq "copyq command" "copyq --start-server" "$CQ_CMD"
assert_eq "feeder command" '~/.i3/scripts/clip-feed.sh' "$FEED_CMD"

mkdir -p "$TMP/cfg" "$TMP/dat" "$TMP/cch"
"$XVFB" "$DPY" -screen 0 800x600x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 40); do
  timeout 2 env DISPLAY="$DPY" "$COPYQ" --help >/dev/null 2>&1
  [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break
  sleep 0.5
done
sleep 1

# The i3 autostart environment, reproduced: DISPLAY is inherited (the overlay
# is only ever included by the session it belongs to) and copyq is a bare
# `copyq`.  XDG_* is the TEST's isolation, not the config's.
i3_exec() { # <command-string>
  env DISPLAY="$DPY" HOME="$TMP/xhome" \
      XDG_CONFIG_HOME="$TMP/cfg" XDG_DATA_HOME="$TMP/dat" XDG_CACHE_HOME="$TMP/cch" \
      CLIP_FEED_SRC="$FEED_SRC" CLIP_FEED_DST="$DPY" \
      CLIP_FEED_LOCK="$TMP/feed.lock" \
      sh -c "$1" >/dev/null 2>&1 &
}

# The feeder resolves through ~/.i3/scripts, exactly as rotz links it.
mkdir -p "$TMP/xhome/.i3/scripts"
ln -sf "$FEEDER" "$TMP/xhome/.i3/scripts/clip-feed.sh"

scenario "idempotent: first i3 start brings up one copyq server"
i3_exec "$CQ_CMD"; sleep 4
assert_eq "servers on $DPY" "1" "$(count_copyq_servers)"

scenario "idempotent: simulated i3 config reload does not start a second server"
i3_exec "$CQ_CMD"; sleep 3
assert_eq "servers on $DPY after reload 1" "1" "$(count_copyq_servers)"
i3_exec "$CQ_CMD"; sleep 3
assert_eq "servers on $DPY after reload 2" "1" "$(count_copyq_servers)"

scenario "idempotent: the server that came up is usable as a history"
cq add "integration-probe" >/dev/null 2>&1
sleep 1
assert_eq "history holds the probe item" "integration-probe" \
  "$(cq eval -- 'str(read("text/plain", 0))' 2>/dev/null)"

scenario "idempotent: first i3 start brings up one feeder"
stop_feeders; sleep 1
i3_exec "$FEED_CMD"; sleep 2
assert_eq "feeders" "1" "$(count_feeders)"

scenario "idempotent: simulated i3 config reload does not start a second feeder"
i3_exec "$FEED_CMD"; sleep 2
assert_eq "feeders after reload 1" "1" "$(count_feeders)"
i3_exec "$FEED_CMD"; sleep 2
assert_eq "feeders after reload 2" "1" "$(count_feeders)"

# The feeder's SRC display does not exist here; it must idle rather than die,
# or a proot session (single display, same overlay) would lose it on the first
# poll and a native session would lose it whenever xrdp is down.
scenario "idempotent: the feeder survives an absent source display"
sleep 3
assert_eq "feeders still running with $FEED_SRC down" "1" "$(count_feeders)"

stop_feeders

# ================================================================ [mutation] ==
#
# Every structural assertion above is re-run against a deliberately broken copy
# and must FAIL.  Each mutation asserts its own anchor matched first — a sed
# that silently missed would otherwise report a fake "survivor".

MUT="$TMP/mut"
mkdir -p "$MUT"

# <label> <src> <sed-expr> <expected-line-delta> <recheck-ere> <expected-count-when-broken>
mutate_and_recheck() { # runs one mutation; asserts anchor + broken assertion
  local label="$1" src="$2" expr="$3" delta="$4" ere="$5" want="$6"
  local out="$MUT/$(basename "$src").mut"
  sed "$expr" "$src" > "$out"
  local before after got changed
  before="$(grep -c . "$src")"
  after="$(grep -c . "$out")"
  assert_eq "$label: sed anchor matched (line delta)" "$delta" "$((after - before))"
  # The line delta alone is NOT proof the anchor matched: a substitution
  # mutation has delta 0, and so does a sed that silently matched nothing —
  # which is how a mutant "survives" without ever having been applied.  Require
  # the bytes to differ as well.
  if cmp -s "$src" "$out"; then changed=no; else changed=yes; fi
  assert_eq "$label: sed anchor matched (file actually changed)" "yes" "$changed"
  got="$(count_matching "$out" "$ere")"
  if [ "$got" = "$want" ]; then
    pass "$label: assertion fails on the mutant (count $got)"
  else
    fail "$label: assertion fails on the mutant" "count $want" "count $got"
  fi
}

scenario "mutation: dropping the copyq autostart from native.conf"
mutate_and_recheck "drop-copyq" "$NATIVE" '/^exec_always .*copyq --start-server/d' \
  "-1" '^exec.*copyq --start-server' "0"

scenario "mutation: dropping the feeder autostart from native.conf"
mutate_and_recheck "drop-feeder" "$NATIVE" '/^exec_always .*clip-feed\.sh/d' \
  "-1" '^exec.*clip-feed\.sh' "0"

scenario "mutation: weakening copyq's exec_always to a one-shot exec"
mutate_and_recheck "weaken-exec" "$NATIVE" \
  's/^exec_always \(--no-startup-id copyq --start-server\)/exec \1/' \
  "0" '^exec_always .*copyq --start-server' "0"

scenario "mutation: giving WSL a feeder it must not have"
mutate_and_recheck "wsl-feeder" "$WSL" \
  '$a exec_always --no-startup-id ~/.i3/scripts/clip-feed.sh' \
  "1" 'clip-feed' "1"

scenario "mutation: dropping the picker keybind from the base config"
mutate_and_recheck "drop-keybind" "$BASE" '/^bindsym .*qs-clip\.sh/d' \
  "-1" '^bindsym .*qs-clip\.sh' "0"

# The keybind probe is parser-based, so its mutant has to be checked through
# i3 rather than through a count: with the binding gone, the probe combo must
# stop being a duplicate.
scenario "mutation: with the keybind gone, i3 no longer calls the probe a duplicate"
H_MUT="$TMP/muthome"
rm -rf "$H_MUT"; mkdir -p "$H_MUT/.i3/config.d"
sed '/^bindsym .*qs-clip\.sh/d' "$BASE" > "$H_MUT/.i3/config"
assert_eq "sed anchor matched (line delta)" "-1" \
  "$(( $(grep -c . "$H_MUT/.i3/config") - $(grep -c . "$BASE") ))"
cp "$NATIVE" "$H_MUT/.i3/config.d/native.conf"
printf 'bindsym $mod+Shift+v nop\n' >> "$H_MUT/.i3/config.d/native.conf"
if i3_errors "$H_MUT" | grep -qi 'Duplicate keybinding'; then
  fail "probe is not a duplicate once the keybind is gone" "nodup" "dup"
else
  pass "probe is not a duplicate once the keybind is gone"
fi

# ================================================================== [rotz] ==
#
# The overlay names ~/.i3/scripts/clip-feed.sh; rotz has to actually put it
# there or the autostart is a no-op that leaves no trace in any log.

scenario "rotz: clip-feed.sh is linked to the path native.conf names"
assert_eq "i3/dot.yaml link entries for clip-feed.sh" "1" \
  "$(grep -c '^ *scripts/clip-feed\.sh: ~/\.i3/scripts/clip-feed\.sh$' "$REPO_DIR/dot.yaml" || true)"

# ========================================================== [decoy-safety] ==
#
# A feeder at a path this run does not own must come through untouched.  The
# decoy has been running since before [config-parse], through every start,
# stop and count above — including the two unconditional stop_feeders calls.
#
# This section is the ONLY thing guarding the scoping, and that is worth
# spelling out because the obvious assumption is wrong.  Reverting the two
# helpers to the old basename pattern was measured, and the "feeders == 1"
# counts above stayed GREEN: stop_feeders kills the decoy before the first
# count runs, so exactly one feeder — ours — is left to count.  Only the
# survival assertion below fails.
#
# That is the original bug reproduced in miniature: green counts, dead feeder.
# Do not weaken these three assertions on the theory that the counts upstream
# already cover the scoping.  They do not.

scenario "decoy-safety: a feeder at an unrelated path survives the whole run"
if kill -0 "$DECOY_PID" 2>/dev/null; then
  pass "decoy (pid $DECOY_PID, $DECOY_PATH) still alive"
else
  fail "decoy still alive" "running" "killed by the suite"
fi

scenario "decoy-safety: the decoy was never counted as one of our feeders"
# Our feeders are all stopped by now, so a basename-scoped counter would
# report the decoy here and this would read 1.
assert_eq "count_feeders with only the decoy running" "0" "$(count_feeders)"

scenario "decoy-safety: the preflight tripwire does detect it (non-vacuous)"
# Re-run the tripwire with the decoy's exemption removed: it must name it.
# Without this, a tripwire that could never fire would look identical.
DETECTED="$(DECOY_PATH=/nonexistent/clip-feed.sh foreign_feeders | grep -c "^$DECOY_PID " || true)"
assert_eq "tripwire reports the decoy pid" "1" "$DETECTED"

# --------------------------------------------------------------- summary ---

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
