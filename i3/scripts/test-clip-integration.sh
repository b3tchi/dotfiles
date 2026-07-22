#!/usr/bin/env bash
# test-clip-integration.sh — verify the ft007 i3 wiring: the clipboard-history
# picker keybind in the base config, and the clip-store.sh / clip-feed.sh
# autostarts in the platform overlays.  (sp014 dotfiles-92w.5, rewritten for
# the sp016 file-store backend by dotfiles-egm.5; absorbs dotfiles-t74.)
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
#    out of the shipped config, twice, and counting processes from /proc — not
#    by reading the word "exec_always" and believing it.
#  * Section [mutation] re-runs the structural assertions against deliberately
#    broken copies and requires them to FAIL.  Each mutation first asserts its
#    own sed anchor actually matched — by line-count delta AND by byte
#    comparison (a substitution has delta 0, and so does a sed that silently
#    matched nothing; dotfiles-92w.4) — because a mutation whose anchor missed
#    produces a fake "survivor".
#
# THE t74 FENCE — THE ISOLATED RUNTIME DIR, AND THE CANARY THAT PROVES IT
#
# The live session's clipboard store lives under the real
# $XDG_RUNTIME_DIR/clip-store/<display>/.  Every component this harness
# starts — store loops, the feeder — resolves its store through
# XDG_RUNTIME_DIR, so the harness overrides it to a throwaway dir under $TMP
# for every single process it launches.  That is the fence dotfiles-t74
# demanded: no harness-started component can ever write into, prune, or dedup
# against the live session's store.
#
# And the fence is PROVEN, not assumed: before anything runs, a canary entry
# is planted in the REAL runtime dir at the exact store path a harness
# component would damage if the isolation were ever dropped
# ($XDG_RUNTIME_DIR/clip-store/<this suite's test display>/).  At the end of
# the run the canary must be byte-identical and alone in its directory, and
# the real store root must hold no new display dirs.  The canary display is a
# throwaway Xvfb number, so planting it adds nothing any live consumer reads
# (live pickers read only their own session's display dir).
#
# The copyq-era revision of this suite set CLIP_FEED_DST as dead env plumbing
# (nothing read it — the old feeder wrote through `copyq add`).  The variable
# is LIVE again in the file-store feeder (it names the destination store
# subdirectory), so the harness sets it deliberately below, to this run's own
# test display — under the isolated runtime dir, per the fence.
#
# THE SCOPING PATTERN, AND WHY EVERY MATCH IS A FULL PATH
#
# This suite starts and stops clip-feed.sh and clip-store.sh processes.  An
# earlier revision matched feeders on the BASENAME (`pgrep -f
# 'clip-feed\.sh$'`), which cannot tell this suite's feeder under $TMP from
# the PRODUCTION feeder autostarted at ~/.i3/scripts/clip-feed.sh.  On a
# deployed machine that suite killed the live feeder, started its own,
# asserted "exactly 1" and went GREEN, while cross-display clipboard silently
# stayed dead until the next i3 reload.  The same hazard now exists for store
# loops, which production autostarts at ~/.i3/scripts/clip-store.sh.
#
# So: every start/stop/count here is scoped to $FEED_PATH / $STORE_PATH,
# absolute paths unique to this run ($TMP carries $$).  A feeder or loop
# anywhere else is invisible to this suite and is never signalled.
#
# The basename pattern survives in exactly one place — foreign_clip_procs(),
# a preflight tripwire that ABORTS when it finds a feeder or store loop
# outside this run's paths, and never kills one.  With full-path scoping a
# foreign process is already harmless, so this is defence in depth: if the
# scoping is ever regressed back to a basename match, the tripwire fires
# first and the suite refuses to run instead of destroying production.
# Consequence, stated plainly: on a deployed machine you must stop your own
# feeder and store loops before running this suite.  That is the intended
# trade — a refusal to run is recoverable, a silent kill is not.
#
# [decoy-safety] proves the scoping holds rather than trusting it: decoy
# processes with production basenames are planted at unrelated paths and
# asserted still alive after every section that starts, stops and counts.
#
# clipnotify: the store loop needs it.  The suite prefers the PATH binary
# (the one production runs); when absent, the same minimal stand-in
# test-clip-store.sh uses is built from source into $TMP (XFixes subscribe,
# block for one event, exit — the poc012 fallback).  The suite prints which
# one a run used.
#
# usage: i3/scripts/test-clip-integration.sh
# env:   XVFB=  I3=   (default: from PATH)
#        CLIPNOTIFY=/path/to/clipnotify   (default: PATH, else source-built)
#        TEST_DISPLAY_A= TEST_DISPLAY_B=  (default: probed free, from :91)
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"   # <repo>/i3
BASE="$REPO_DIR/config"
NATIVE="$REPO_DIR/config.d/native.conf"
WSL="$REPO_DIR/config.d/wsl.conf"
FEEDER="$REPO_DIR/scripts/clip-feed.sh"
STORESH="$REPO_DIR/scripts/clip-store.sh"

XVFB="${XVFB:-Xvfb}"
I3="${I3:-i3}"

TMP="/tmp/clip-integration-test.$$"
RUN="$TMP/run"                 # the ISOLATED XDG_RUNTIME_DIR (the t74 fence)
XHOME="$TMP/xhome"             # fake $HOME whose ~/.i3/scripts is this repo's

# The ONLY feeder/loops this suite may ever signal or count.  Absolute, and
# unique to this run because $TMP carries $$.  See "THE SCOPING PATTERN".
FEED_PATH="$XHOME/.i3/scripts/clip-feed.sh"
STORE_PATH="$XHOME/.i3/scripts/clip-store.sh"
# The [decoy-safety] stand-ins for production processes: basenames identical
# to what config.d/native.conf autostarts at ~/.i3/scripts/, paths unrelated.
DECOY_FEED="$TMP/prodsim/.i3/scripts/clip-feed.sh"
DECOY_STORE="$TMP/prodsim/.i3/scripts/clip-store.sh"

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
  stop_loops
  # The decoys are ours, so they die by PID — never by pattern.
  [ -n "${DECOY_FEED_PID:-}" ]  && kill "$DECOY_FEED_PID"  2>/dev/null
  [ -n "${DECOY_STORE_PID:-}" ] && kill "$DECOY_STORE_PID" 2>/dev/null
  [ -n "${XVFB_A_PID:-}" ] && kill "$XVFB_A_PID" 2>/dev/null
  [ -n "${XVFB_B_PID:-}" ] && kill "$XVFB_B_PID" 2>/dev/null
  # Canary teardown: remove ONLY what this run planted, and only when its
  # directory holds nothing else (extra files there are evidence of a broken
  # fence and must survive for inspection).
  if [ -n "${CANARY_FILE:-}" ] && [ -f "$CANARY_FILE" ]; then
    rm -f "$CANARY_FILE"
    rmdir "$CANARY_DIR" 2>/dev/null
    [ "${REAL_ROOT_CREATED:-no}" = yes ] && rmdir "$REAL_ROOT" 2>/dev/null
  fi
  rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

mkdir -p "$TMP" "$RUN" "$XHOME/.i3/scripts" "$TMP/bin"
chmod 700 "$RUN"

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

# Feeders belonging to THIS run, matched on the full unique path.  A feeder
# at any other path — production's ~/.i3/scripts/clip-feed.sh above all — is
# not counted and, in stop_feeders, not signalled.
count_feeders() {
  pgrep -f -- "$FEED_PATH" 2>/dev/null | grep -c . || true
}

stop_feeders() {
  pkill -f -- "$FEED_PATH" 2>/dev/null
  return 0
}

# Store loops belonging to THIS run, per display.  Matched on the full
# unique $STORE_PATH first, then attributed to a display via the
# CLIP_STORE_DISPLAY in each process's OWN environment (/proc) — the loops'
# argv is the shipped string verbatim (`... :0`), so argv alone cannot tell
# the redirected test loops apart.
loop_pids_for() { # <display>
  local pid dpy
  for pid in $(pgrep -f -- "$STORE_PATH" 2>/dev/null); do
    dpy="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
           | sed -n 's/^CLIP_STORE_DISPLAY=//p' | head -1)"
    [ "$dpy" = "$1" ] && printf '%s\n' "$pid"
  done
}

count_loops() { # <display>
  loop_pids_for "$1" | grep -c . || true
}

# Kill by pid lineage, never by name (the clipse lesson: this epic watched a
# backend kill every process named 'st' via sloppy matching).  Children (the
# blocked clipnotify) are collected before the parent dies and killed after.
kill_loop_pid() { # <pid>
  local kids k
  kids="$(pgrep -P "$1" 2>/dev/null)"
  kill "$1" 2>/dev/null
  for k in $kids; do kill "$k" 2>/dev/null; done
}

stop_loops() {
  local pid
  for pid in $(pgrep -f -- "$STORE_PATH" 2>/dev/null); do
    kill_loop_pid "$pid"
  done
  return 0
}

# The tripwire: clip-feed.sh / clip-store.sh processes matched by BASENAME
# that are not ours and not the decoys.  Reported, never killed.
foreign_clip_procs() {
  local pid argv
  for pid in $(pgrep -f 'clip-feed\.sh$|clip-store\.sh' 2>/dev/null); do
    argv="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
    # Only shell invocations of the scripts count; this very test process
    # (and its pgrep children) mention the names in their argv too.
    case "$argv" in
      *clip-feed.sh*|*clip-store.sh*) : ;;
      *) continue ;;
    esac
    case "$argv" in
      *"$FEED_PATH"*|*"$STORE_PATH"*|*"$DECOY_FEED"*|*"$DECOY_STORE"*) continue ;;
      *test-clip-integration.sh*|*pgrep*|*grep*) continue ;;
    esac
    printf '%s %s\n' "$pid" "$argv"
  done
}

# ------------------------------------------------------------ preflight ----

for tool in "$I3" "$XVFB" flock xclip; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (I3=/XVFB= to override)" >&2; exit 1; }
done
for f in "$BASE" "$NATIVE" "$WSL" "$FEEDER" "$STORESH"; do
  [ -r "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

# Tripwire — see "THE SCOPING PATTERN" in the header.  Nothing is killed;
# the suite refuses to run.  On a deployed machine the production feeder and
# store loops autostarted by the overlays land here, and stopping them
# yourself is the price of running this suite.
#
# CLIP_TEST_ACK_FOREIGN=1 is the explicit operator override for when the
# production processes cannot be stopped: the suite proceeds, and the acked
# pids become REAL production decoys — [decoy-safety] at the end asserts
# every one of them survived the whole run, so an ack does not weaken the
# scoping guarantee, it upgrades the synthetic-decoy proof to the real
# thing.  The default (unset — every CI run) still aborts.
ACKED_FOREIGN_PIDS=""
FOREIGN="$(foreign_clip_procs)"
if [ -n "$FOREIGN" ]; then
  if [ -n "${CLIP_TEST_ACK_FOREIGN:-}" ]; then
    {
      echo "WARNING: proceeding past foreign clip processes (CLIP_TEST_ACK_FOREIGN):"
      printf '  %s\n' "$FOREIGN"
      echo "Their survival is asserted at the end of the run."
    } >&2
    ACKED_FOREIGN_PIDS="$(printf '%s\n' "$FOREIGN" | awk '{print $1}')"
  else
    {
      echo "FATAL: a clip-feed.sh or clip-store.sh is running outside this test run:"
      printf '  %s\n' "$FOREIGN"
      echo
      echo "Refusing to start. This suite never signals a process it did not start"
      echo "(killing the production feeder or a store loop would break the live"
      echo "clipboard history until the next i3 reload, silently and with a green"
      echo "test run). Stop it yourself and re-run, or re-run with"
      echo "CLIP_TEST_ACK_FOREIGN=1 to proceed with their survival asserted."
    } >&2
    exit 1
  fi
fi

# Free test displays, probed rather than hardcoded: sibling suites in this
# repo run their own Xvfbs on fixed low numbers (:93-:98) and may be running
# concurrently.
probe_free_display() { # <start-number>
  local n="$1"
  while [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X${n}-lock" ]; do
    n=$((n + 1))
  done
  printf ':%s' "$n"
}
DPY_A="${TEST_DISPLAY_A:-$(probe_free_display 91)}"
DPY_B="${TEST_DISPLAY_B:-$(probe_free_display $(( ${DPY_A#:} + 1 )))}"
# The feeder's watched source display: deliberately one that is NOT up.
FEED_SRC="$(probe_free_display 190)"

# Resolve clipnotify: PATH first (the production binary), source-built
# stand-in only as the harness fallback (same stand-in as test-clip-store.sh).
cat >"$TMP/bin/mini-clipnotify.c" <<'CEOF'
/* mini-clipnotify.c -- harness stand-in for clipnotify(1), built only when
 * the packaged binary is absent.  Same contract: subscribe to XFixes
 * selection events for the named selection, block until one arrives, exit
 * 0.  Exits nonzero when the display cannot be opened or dies. */
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/Xfixes.h>

int main(int argc, char **argv) {
    const char *sel = "clipboard";
    int i;
    for (i = 1; i < argc - 1; i++)
        if (!strcmp(argv[i], "-s")) sel = argv[i + 1];
    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "mini-clipnotify: cannot open display\n"); return 1; }
    Atom a;
    if (!strcasecmp(sel, "clipboard")) a = XInternAtom(d, "CLIPBOARD", False);
    else if (!strcasecmp(sel, "primary")) a = XA_PRIMARY;
    else if (!strcasecmp(sel, "secondary")) a = XA_SECONDARY;
    else { fprintf(stderr, "mini-clipnotify: bad selection\n"); return 2; }
    int event_base, error_base;
    if (!XFixesQueryExtension(d, &event_base, &error_base)) {
        fprintf(stderr, "mini-clipnotify: no XFixes\n");
        return 1;
    }
    XFixesSelectSelectionInput(d, DefaultRootWindow(d), a,
        XFixesSetSelectionOwnerNotifyMask |
        XFixesSelectionWindowDestroyNotifyMask |
        XFixesSelectionClientCloseNotifyMask);
    XEvent ev;
    XNextEvent(d, &ev);
    XCloseDisplay(d);
    return 0;
}
CEOF
if [ -n "${CLIPNOTIFY:-}" ]; then
  CN="$CLIPNOTIFY"
  CN_KIND="override ($CN)"
elif command -v clipnotify >/dev/null 2>&1; then
  CN="clipnotify"
  CN_KIND="packaged (PATH)"
else
  command -v gcc >/dev/null 2>&1 || { echo "FATAL: clipnotify not installed and no gcc to build the stand-in" >&2; exit 1; }
  gcc -O2 -o "$TMP/bin/clipnotify" "$TMP/bin/mini-clipnotify.c" -lX11 -lXfixes \
    || { echo "FATAL: could not build the clipnotify stand-in (libXfixes headers?)" >&2; exit 1; }
  CN="$TMP/bin/clipnotify"
  CN_KIND="source-built stand-in (clipnotify not installed; install it for a packaged-binary run)"
fi

echo "=== ft007 i3 integration (sp016 dotfiles-egm.5) ==="
echo "displays: $DPY_A $DPY_B (feeder src, absent: $FEED_SRC)"
echo "clipnotify: $CN_KIND"
echo "isolated runtime dir: $RUN"

# --- the t74 canary, planted before anything else runs ----------------------
# See "THE t74 FENCE" in the header.  If the real XDG_RUNTIME_DIR is unset,
# there is no live store a broken fence could damage — every store component
# refuses to run at all without it (exit 78) — so there is nothing to plant.
REAL_XDG="${XDG_RUNTIME_DIR:-}"
CANARY_FILE=""
if [ -n "$REAL_XDG" ] && [ -d "$REAL_XDG" ] && [ -w "$REAL_XDG" ]; then
  REAL_ROOT="$REAL_XDG/clip-store"
  if [ -d "$REAL_ROOT" ]; then REAL_ROOT_CREATED=no; else REAL_ROOT_CREATED=yes; fi
  ROOT_LISTING_PRE="$(ls -1A "$REAL_ROOT" 2>/dev/null)"
  CANARY_DIR="$REAL_ROOT/$DPY_A"
  if [ -e "$CANARY_DIR" ]; then
    echo "FATAL: $CANARY_DIR already exists in the LIVE runtime dir (stale" >&2
    echo "canary from an aborted run, or something live uses this display)." >&2
    echo "Refusing to plant the canary over it; inspect and remove it first." >&2
    exit 1
  fi
  mkdir -p "$CANARY_DIR"
  CANARY_FILE="$CANARY_DIR/000001.clip"
  printf 'live-store canary %s — a harness component that touches this file has broken the t74 fence' "$$" \
    > "$CANARY_FILE"
  cp "$CANARY_FILE" "$TMP/canary.expected"
fi

# The decoys stand in for production processes for the rest of the run: same
# basenames, unrelated paths, planted only AFTER the tripwire has cleared so
# they are never mistaken for foreign.  [decoy-safety] asserts they survived.
mkdir -p "$(dirname "$DECOY_FEED")"
cat > "$DECOY_FEED" <<'DECOY'
#!/bin/sh
# Stand-in for the production feeder. Must outlive this suite.
while :; do sleep 1; done
DECOY
chmod +x "$DECOY_FEED"
sed 's/feeder/store loop/' "$DECOY_FEED" > "$DECOY_STORE"
chmod +x "$DECOY_STORE"
"$DECOY_FEED" & DECOY_FEED_PID=$!
"$DECOY_STORE" :0 & DECOY_STORE_PID=$!
sleep 1

# =========================================================== [config-parse] ==
#
# Both platform trees must parse clean.  This is also the standing collision
# check: i3 reports a duplicate keybinding as a config ERROR, so a clean parse
# means nothing in the base config or either overlay binds the same combo
# twice — including the picker key.

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
# "Is $mod+v bound to the picker?" is asked of i3's parser, not of grep.
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

scenario "keybind: i3 sees \$mod+v as already bound (native)"
assert_eq "probe on \$mod+v is a duplicate" \
  "dup" "$(probe_dup "$H_NATIVE" native.conf '$mod+v')"

scenario "keybind: negative control — an unbound combo is not a duplicate"
assert_eq "probe on \$mod+Shift+F12 is not a duplicate" \
  "nodup" "$(probe_dup "$H_NATIVE" native.conf '$mod+Shift+F12')"

scenario "keybind: i3 sees \$mod+v as already bound (wsl)"
assert_eq "probe on \$mod+v is a duplicate" \
  "dup" "$(probe_dup "$H_WSL" wsl.conf '$mod+v')"

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

scenario "keybind: the whole bindsym line is byte-identical to the golden"
# The picker keybind ($mod+v as of the post-sp016 rebind) is proven by BYTE
# comparison against the golden line, not by inspecting fragments of it. (Was
# $mod+Shift+v through sp014/sp016; user-rebound to $mod+v afterward.)
printf '%s' 'bindsym $mod+v exec --no-startup-id ~/.dotfiles/quickshell/qs-clip.sh toggle' \
  > "$TMP/keybind.golden"
printf '%s' "$CLIP_BIND" > "$TMP/keybind.actual"
if cmp -s "$TMP/keybind.golden" "$TMP/keybind.actual"; then
  pass "the \$mod+v line has no diff"
else
  fail "the \$mod+v line has no diff" \
    "$(cat "$TMP/keybind.golden")" "$CLIP_BIND"
fi

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

scenario "native.conf: starts exactly one store loop per display, on every reload"
assert_eq "clip-store.sh exec lines" "2" \
  "$(count_matching "$NATIVE" '^exec.*clip-store\.sh')"
assert_eq "both are exec_always (survive a reload)" "2" \
  "$(count_matching "$NATIVE" '^exec_always .*clip-store\.sh')"
assert_eq "exactly one names :0"  "1" "$(count_matching "$NATIVE" '^exec_always .*clip-store\.sh :0$')"
assert_eq "exactly one names :10" "1" "$(count_matching "$NATIVE" '^exec_always .*clip-store\.sh :10$')"

scenario "native.conf: starts the cross-display feeder"
assert_eq "clip-feed.sh exec lines" "1" \
  "$(count_matching "$NATIVE" '^exec.*clip-feed\.sh')"
assert_eq "and it is exec_always" "1" \
  "$(count_matching "$NATIVE" '^exec_always .*clip-feed\.sh')"

# The single-instance guards are flocks held on open fds.  A pkill+restart
# (the mould used for clip-sync.sh) races those locks: the new process can
# see the lock still held by an inherited fd, conclude it is the duplicate,
# and exit — leaving nothing running.  See clip-feed.sh's header.
scenario "native.conf: no pkill-restart around the loops or the feeder (would defeat their flocks)"
assert_eq "pkill lines mentioning clip-feed"  "0" "$(count_matching "$NATIVE" 'pkill.*clip-feed')"
assert_eq "pkill lines mentioning clip-store" "0" "$(count_matching "$NATIVE" 'pkill.*clip-store')"

# The scripts fail LOUDLY (exit 78) when XDG_RUNTIME_DIR is unset — i3's
# exec does not run under set -u, so the refusal is theirs, and the config
# must not swallow it.
scenario "native.conf: nothing swallows the loud XDG_RUNTIME_DIR refusal"
assert_eq "no '|| true' on any clip line" "0" \
  "$(lines_matching "$NATIVE" 'clip-(store|feed)\.sh' | grep -c '|| *true' || true)"

# =========================================================== [wsl-autostart] ==

scenario "wsl.conf: starts exactly one store loop, on every reload"
assert_eq "clip-store.sh exec lines" "1" \
  "$(count_matching "$WSL" '^exec.*clip-store\.sh')"
assert_eq "and it is exec_always" "1" \
  "$(count_matching "$WSL" '^exec_always .*clip-store\.sh')"
assert_eq "and it names :10 explicitly (the xrdp session display)" "1" \
  "$(count_matching "$WSL" '^exec_always .*clip-store\.sh :10$')"

# WSL has a single display: its copies already land in its own store, and a
# feeder would have it watch the display it is already serving.
scenario "wsl-has-no-feeder"
assert_eq "clip-feed references" "0" "$(count_matching "$WSL" 'clip-feed')"

scenario "wsl.conf: nothing swallows the loud XDG_RUNTIME_DIR refusal"
assert_eq "no '|| true' on the clip line" "0" \
  "$(lines_matching "$WSL" 'clip-store\.sh' | grep -c '|| *true' || true)"

# ========================================= [no-legacy-backend-started] ==
#
# The decommission criterion: no copyq server and no clipcatd is started by
# ANY config — base or overlay.  Comments are stripped first, so the rollback
# documentation in the overlays cannot satisfy or violate this.

scenario "no-legacy-backend-started-by-any-config"
for f in "$BASE" "$NATIVE" "$WSL"; do
  assert_eq "$(basename "$f"): no copyq lines"   "0" "$(count_matching "$f" 'copyq')"
  assert_eq "$(basename "$f"): no clipcat lines" "0" "$(count_matching "$f" 'clipcat')"
done

# ============================================================== [idempotent] ==
#
# The claims above are about text.  These run the extracted command strings
# for real, twice and three times, and count processes from /proc.
#
# Redirection, stated openly: the shipped strings name the production
# displays (:0, :10) and the production runtime dir.  Executing them
# UNMODIFIED — argv and all — under CLIP_STORE_DISPLAY / XDG_RUNTIME_DIR
# overrides redirects each loop to this run's Xvfb and isolated store,
# through the script's own documented precedence (env wins over $1).  The
# feeder is redirected the same way through its own env contract
# (CLIP_FEED_SRC/CLIP_FEED_DST — the latter LIVE config since the file-store
# pivot: it names the destination store subdir under the isolated $RUN).
# DISPLAY is set to a display that does not exist, so the suite fails if any
# component ever starts trusting the inherited DISPLAY.

STORE0_CMD="$(lines_matching "$NATIVE" '^exec_always .*clip-store\.sh :0$' \
              | sed 's/^exec_always --no-startup-id //')"
STORE10_CMD="$(lines_matching "$NATIVE" '^exec_always .*clip-store\.sh :10$' \
               | sed 's/^exec_always --no-startup-id //')"
FEED_CMD="$(lines_matching "$NATIVE" '^exec_always .*clip-feed\.sh' \
            | sed 's/^exec_always --no-startup-id //')"
WSL_STORE_CMD="$(lines_matching "$WSL" '^exec_always .*clip-store\.sh :10$' \
                 | sed 's/^exec_always --no-startup-id //')"

scenario "idempotent: the extracted command strings are the shipped ones"
assert_eq "native :0 loop"  '~/.i3/scripts/clip-store.sh :0'  "$STORE0_CMD"
assert_eq "native :10 loop" '~/.i3/scripts/clip-store.sh :10' "$STORE10_CMD"
assert_eq "feeder command"  '~/.i3/scripts/clip-feed.sh'      "$FEED_CMD"
assert_eq "wsl loop"        '~/.i3/scripts/clip-store.sh :10' "$WSL_STORE_CMD"

# The loops resolve through ~/.i3/scripts, exactly as rotz links it.
ln -sf "$FEEDER"  "$FEED_PATH"
ln -sf "$STORESH" "$STORE_PATH"

start_xvfb() { # <display> <logfile>
  "$XVFB" "$1" -screen 0 800x600x24 >"$2" 2>&1 &
  local pid=$! i
  for i in $(seq 1 40); do
    if ! timeout 2 env DISPLAY="$1" xclip -selection clipboard -t TARGETS -o \
         2>&1 >/dev/null | grep -q "Can't open display"; then
      printf '%s' "$pid"
      return 0
    fi
    sleep 0.5
  done
  echo "FATAL: Xvfb $1 did not start" >&2
  cat "$2" >&2
  exit 1
}
XVFB_A_PID="$(start_xvfb "$DPY_A" "$TMP/xvfb-a.log")"
XVFB_B_PID="$(start_xvfb "$DPY_B" "$TMP/xvfb-b.log")"

# The i3 autostart environment, reproduced — with the redirection env
# documented above.  <display> is the test display standing in for the
# shipped argv's production display.
i3_exec_store() { # <command-string> <display>
  env DISPLAY=:77 HOME="$XHOME" XDG_RUNTIME_DIR="$RUN" \
      CLIPNOTIFY="$CN" CLIP_STORE_DISPLAY="$2" \
      sh -c "$1" >>"$TMP/loops.log" 2>&1 &
}
i3_exec_feed() { # <command-string>
  env DISPLAY=:77 HOME="$XHOME" XDG_RUNTIME_DIR="$RUN" \
      CLIP_FEED_SRC="$FEED_SRC" CLIP_FEED_DST="$DPY_A" \
      CLIP_FEED_LOCK="$TMP/feed.lock" \
      sh -c "$1" >>"$TMP/feed.log" 2>&1 &
}

scenario "one-loop-per-display-after-reload"
i3_exec_store "$STORE0_CMD"  "$DPY_A"
i3_exec_store "$STORE10_CMD" "$DPY_B"
sleep 2
assert_eq "first start: one loop on $DPY_A" "1" "$(count_loops "$DPY_A")"
assert_eq "first start: one loop on $DPY_B" "1" "$(count_loops "$DPY_B")"
# Simulated i3 config reload: exec_always re-runs every line.
i3_exec_store "$STORE0_CMD"  "$DPY_A"
i3_exec_store "$STORE10_CMD" "$DPY_B"
sleep 2
assert_eq "after reload 1: still one loop on $DPY_A" "1" "$(count_loops "$DPY_A")"
assert_eq "after reload 1: still one loop on $DPY_B" "1" "$(count_loops "$DPY_B")"
i3_exec_store "$STORE0_CMD"  "$DPY_A"
i3_exec_store "$STORE10_CMD" "$DPY_B"
sleep 2
assert_eq "after reload 2: still one loop on $DPY_A" "1" "$(count_loops "$DPY_A")"
assert_eq "after reload 2: still one loop on $DPY_B" "1" "$(count_loops "$DPY_B")"

scenario "idempotent: the loop that came up actually captures into the isolated store"
PROBE="integration-probe-$$"
printf '%s' "$PROBE" | timeout 5 env DISPLAY="$DPY_A" xclip -selection clipboard -i
CAPTURED=""
for _ in $(seq 1 20); do
  if [ -f "$RUN/clip-store/$DPY_A/000001.clip" ]; then
    CAPTURED="$(cat "$RUN/clip-store/$DPY_A/000001.clip")"
    break
  fi
  sleep 0.5
done
assert_eq "the copy landed as the first store entry, byte-exact" "$PROBE" "$CAPTURED"

scenario "killed-loop-restarts-on-reload"
A_PID="$(loop_pids_for "$DPY_A" | head -1)"
kill_loop_pid "$A_PID"
sleep 1
assert_eq "the $DPY_A loop is dead" "0" "$(count_loops "$DPY_A")"
# The stale lock file is still on disk — flock's liveness rides the open fd,
# not the file, so a leftover file must not block the restart.
assert_eq "its lock file is still on disk (stale)" "yes" \
  "$([ -e "$RUN/clip-store/$DPY_A.lock" ] && echo yes || echo no)"
assert_eq "the $DPY_B loop was not collateral damage" "1" "$(count_loops "$DPY_B")"
i3_exec_store "$STORE0_CMD" "$DPY_A"   # the next reload re-runs the line
sleep 2
assert_eq "one loop on $DPY_A again" "1" "$(count_loops "$DPY_A")"

scenario "idempotent: first i3 start brings up one feeder"
stop_feeders; sleep 1
i3_exec_feed "$FEED_CMD"; sleep 2
assert_eq "feeders" "1" "$(count_feeders)"

scenario "idempotent: simulated i3 config reload does not start a second feeder"
i3_exec_feed "$FEED_CMD"; sleep 2
assert_eq "feeders after reload 1" "1" "$(count_feeders)"
i3_exec_feed "$FEED_CMD"; sleep 2
assert_eq "feeders after reload 2" "1" "$(count_feeders)"

# The feeder's SRC display does not exist here; it must idle rather than die,
# or a proot session (single display, same overlay) would lose it on the first
# poll and a native session would lose it whenever xrdp is down.
scenario "idempotent: the feeder survives an absent source display"
sleep 3
assert_eq "feeders still running with $FEED_SRC down" "1" "$(count_feeders)"

stop_feeders

# The wsl overlay's single loop, same execution discipline.  The native
# loops are stopped first so the count is unambiguously the wsl line's.
scenario "wsl: the single loop is idempotent across reloads"
stop_loops; sleep 1
i3_exec_store "$WSL_STORE_CMD" "$DPY_B"
sleep 2
assert_eq "one loop on $DPY_B" "1" "$(count_loops "$DPY_B")"
i3_exec_store "$WSL_STORE_CMD" "$DPY_B"
sleep 2
assert_eq "still one after a reload" "1" "$(count_loops "$DPY_B")"
stop_loops

# Behavioural complement to the text-level decommission check: after every
# extracted autostart has actually run, no copyq server and no clipcatd may
# exist on either test display.
scenario "no-legacy-backend-process-after-executing-all-autostarts"
LEGACY=0
for pid in $(pgrep -x copyq 2>/dev/null; pgrep -x clipcatd 2>/dev/null); do
  dpy="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
         | sed -n 's/^DISPLAY=//p' | head -1)"
  case "$dpy" in "$DPY_A"|"$DPY_B"|:77) LEGACY=$((LEGACY + 1)) ;; esac
done
assert_eq "copyq/clipcatd processes on the test displays" "0" "$LEGACY"

# ================================================================ [mutation] ==
#
# Every structural assertion above is re-run against a deliberately broken
# copy and must FAIL.  Each mutation asserts its own anchor matched first —
# by line delta AND byte comparison (dotfiles-92w.4): a substitution has
# delta 0, and so does a sed that silently matched nothing, which is how a
# mutant "survives" without ever having been applied.

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
  if cmp -s "$src" "$out"; then changed=no; else changed=yes; fi
  assert_eq "$label: sed anchor matched (file actually changed)" "yes" "$changed"
  got="$(count_matching "$out" "$ere")"
  if [ "$got" = "$want" ]; then
    pass "$label: assertion fails on the mutant (count $got)"
  else
    fail "$label: assertion fails on the mutant" "count $want" "count $got"
  fi
}

scenario "mutation: dropping the :0 store loop from native.conf"
mutate_and_recheck "drop-loop-0" "$NATIVE" '/^exec_always .*clip-store\.sh :0$/d' \
  "-1" '^exec.*clip-store\.sh :0$' "0"

scenario "mutation: dropping the :10 store loop from native.conf"
mutate_and_recheck "drop-loop-10" "$NATIVE" '/^exec_always .*clip-store\.sh :10$/d' \
  "-1" '^exec.*clip-store\.sh :10$' "0"

scenario "mutation: dropping the feeder autostart from native.conf"
mutate_and_recheck "drop-feeder" "$NATIVE" '/^exec_always .*clip-feed\.sh/d' \
  "-1" '^exec.*clip-feed\.sh' "0"

scenario "mutation: weakening a store loop's exec_always to a one-shot exec"
mutate_and_recheck "weaken-exec" "$NATIVE" \
  's/^exec_always \(--no-startup-id ~\/\.i3\/scripts\/clip-store\.sh :0\)$/exec \1/' \
  "0" '^exec_always .*clip-store\.sh :0$' "0"

scenario "mutation: giving WSL a feeder it must not have"
mutate_and_recheck "wsl-feeder" "$WSL" \
  '$a exec_always --no-startup-id ~/.i3/scripts/clip-feed.sh' \
  "1" 'clip-feed' "1"

scenario "mutation: dropping the wsl store loop"
mutate_and_recheck "wsl-drop-loop" "$WSL" '/^exec_always .*clip-store\.sh :10$/d' \
  "-1" '^exec.*clip-store\.sh' "0"

scenario "mutation: resurrecting a copyq autostart must trip the decommission check"
mutate_and_recheck "resurrect-copyq" "$NATIVE" \
  '$a exec_always --no-startup-id copyq --start-server' \
  "1" 'copyq' "1"

scenario "mutation: dropping the picker keybind from the base config"
mutate_and_recheck "drop-keybind" "$BASE" '/^bindsym .*qs-clip\.sh/d' \
  "-1" '^bindsym .*qs-clip\.sh' "0"

scenario "mutation: a one-byte change to the keybind line must fail the byte comparison"
sed 's/^bindsym $mod+v exec/bindsym $mod+Shift+b exec/' "$BASE" > "$MUT/config.keymut"
if cmp -s "$BASE" "$MUT/config.keymut"; then
  fail "keybind byte-mutation applied" "bytes differ" "sed matched nothing"
else
  pass "keybind byte-mutation applied (bytes differ)"
fi
MUT_BIND="$(lines_matching "$MUT/config.keymut" '^bindsym .*qs-clip\.sh')"
printf '%s' "$MUT_BIND" > "$TMP/keybind.mutant"
if cmp -s "$TMP/keybind.golden" "$TMP/keybind.mutant"; then
  fail "byte comparison catches the mutant line" "different from golden" "identical"
else
  pass "byte comparison catches the mutant line"
fi

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
# The overlays name ~/.i3/scripts/clip-store.sh and ~/.i3/scripts/clip-feed.sh;
# rotz has to actually put them there or the autostarts are no-ops that leave
# no trace in any log.

scenario "rotz: clip-feed.sh is linked to the path native.conf names"
assert_eq "i3/dot.yaml link entries for clip-feed.sh" "1" \
  "$(grep -c '^ *scripts/clip-feed\.sh: ~/\.i3/scripts/clip-feed\.sh$' "$REPO_DIR/dot.yaml" || true)"

scenario "rotz: clip-store.sh is linked to the path both overlays name"
assert_eq "i3/dot.yaml link entries for clip-store.sh" "1" \
  "$(grep -c '^ *scripts/clip-store\.sh: ~/\.i3/scripts/clip-store\.sh$' "$REPO_DIR/dot.yaml" || true)"

# ==================================================== [live-store-canary] ==
#
# The t74 fence, proven.  The canary was planted in the REAL runtime dir
# before anything ran, at the exact store path a harness component would
# write to if the XDG_RUNTIME_DIR isolation were ever dropped.  Every loop
# start, capture, prune and feed above has happened since; the canary must
# be untouched and alone, and the real store root must have gained nothing.

scenario "live-store-canary-untouched"
if [ -n "$CANARY_FILE" ]; then
  assert_eq "the canary file still exists" "yes" \
    "$([ -f "$CANARY_FILE" ] && echo yes || echo no)"
  assert_eq "its bytes are identical to what was planted" "identical" \
    "$(cmp -s "$CANARY_FILE" "$TMP/canary.expected" && echo identical || echo different)"
  assert_eq "it is alone in its directory (nothing captured/fed/pruned beside it)" \
    "000001.clip" "$(ls -1A "$CANARY_DIR" 2>/dev/null)"
  ROOT_LISTING_POST="$(ls -1A "$REAL_ROOT" 2>/dev/null | grep -vFx "$DPY_A" || true)"
  assert_eq "the live store root gained no other display dirs" \
    "$ROOT_LISTING_PRE" "$ROOT_LISTING_POST"
else
  # No real runtime dir in this environment: every store component refuses to
  # start without one (exit 78), so there is no live store a broken fence
  # could reach.  Nothing to assert against — recorded, not silently skipped.
  pass "no real XDG_RUNTIME_DIR in this environment — no live store exists to fence (components refuse loudly without it)"
fi

# ========================================================== [decoy-safety] ==
#
# Processes at paths this run does not own must come through untouched.  The
# decoys have been running since before [config-parse], through every start,
# stop and count above — including the unconditional stop_feeders/stop_loops
# calls.
#
# This section is the ONLY thing guarding the scoping, and that is worth
# spelling out because the obvious assumption is wrong.  Reverting the
# helpers to a basename pattern was measured (in the copyq-era suite): the
# "== 1" counts above stayed GREEN — the stop calls killed the decoy before
# the first count ran, leaving exactly one process, ours, to count.  Only
# the survival assertions below fail.  That is the original bug reproduced
# in miniature: green counts, dead production process.  Do not weaken these
# assertions on the theory that the counts upstream already cover the
# scoping.  They do not.

scenario "decoy-safety: a feeder at an unrelated path survives the whole run"
if kill -0 "$DECOY_FEED_PID" 2>/dev/null; then
  pass "feeder decoy (pid $DECOY_FEED_PID, $DECOY_FEED) still alive"
else
  fail "feeder decoy still alive" "running" "killed by the suite"
fi

scenario "decoy-safety: a store loop at an unrelated path survives the whole run"
if kill -0 "$DECOY_STORE_PID" 2>/dev/null; then
  pass "store decoy (pid $DECOY_STORE_PID, $DECOY_STORE) still alive"
else
  fail "store decoy still alive" "running" "killed by the suite"
fi

scenario "decoy-safety: the decoys were never counted as ours"
# Our feeders and loops are all stopped by now, so basename-scoped counters
# would report the decoys here.
assert_eq "count_feeders with only the decoy running" "0" "$(count_feeders)"
assert_eq "count_loops($DPY_A) with only the decoy running" "0" "$(count_loops "$DPY_A")"
assert_eq "count_loops(:0) with only the decoy running" "0" "$(count_loops ':0')"

if [ -n "$ACKED_FOREIGN_PIDS" ]; then
  scenario "decoy-safety: every ACKED production process survived the whole run"
  for fpid in $ACKED_FOREIGN_PIDS; do
    if kill -0 "$fpid" 2>/dev/null; then
      pass "acked foreign pid $fpid still alive"
    else
      fail "acked foreign pid $fpid still alive" "running" "gone (killed by the suite, or exited on its own mid-run)"
    fi
  done
fi

scenario "decoy-safety: the preflight tripwire does detect them (non-vacuous)"
# Re-run the tripwire with the decoys' exemptions removed: it must name both.
# Without this, a tripwire that could never fire would look identical.
DETECTED_FEED="$(DECOY_FEED=/nonexistent/clip-feed.sh DECOY_STORE=/nonexistent/clip-store.sh \
                 foreign_clip_procs | grep -c "^$DECOY_FEED_PID " || true)"
DETECTED_STORE="$(DECOY_FEED=/nonexistent/clip-feed.sh DECOY_STORE=/nonexistent/clip-store.sh \
                  foreign_clip_procs | grep -c "^$DECOY_STORE_PID " || true)"
assert_eq "tripwire reports the feeder decoy pid" "1" "$DETECTED_FEED"
assert_eq "tripwire reports the store decoy pid"  "1" "$DETECTED_STORE"

# --------------------------------------------------------------- summary ---

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
