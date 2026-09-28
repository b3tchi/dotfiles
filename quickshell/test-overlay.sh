#!/usr/bin/env bash
# test-overlay.sh — consumer suite for the i3-dialog overlay (sp017 / ft008),
# launcher + projects phases (Task 3 / dotfiles-evnv.3) and the switcher phase
# (Task 4 / dotfiles-evnv.4). Sibling of
# test-clip-history.sh and test-combo.sh; same discipline — Xvfb display,
# isolated XDG_* dirs, a SANDBOXED $PATH of argv-recording stubs, named
# scenarios, and negative controls that fail on the specific mutant (a reverted
# `find -L`, a first-row publish). UI is observed indirectly (adr0002): logic is
# asserted through sh-visible effects — marker files a launched stub writes, the
# argv an i3-msg stub records, and mapped-window geometry read via xdotool.
#
# HOSTING (precedent: test-clip-history.sh PHASE 1.5)
#   Overlay.qml is hosted in the MAIN quickshell instance over RDP (QS_RDP=1);
#   on desktop it is a separate `quickshell -p overlay` process. Both host the
#   SAME Overlay.qml, so this suite loads it directly in a minimal profile
#   ($TMP/entry: a ShellRoot wrapping Overlay {}, plus symlinks to the real
#   Overlay.qml and Common/), driven by IPC + xdotool exactly as the shipped
#   `qs-overlay.sh` verbs would (launcher toggle / projects toggle). QS_RDP=1 is
#   set for fidelity though the minimal wrapper does not read it.
#
# THE find -L DRIFT-FIX (symlinked-bin-visible / broken-symlink-hidden)
#   The launcher scans $PATH with `find -L` so a symlink to a real binary
#   (rotz links ~/.local/bin) is followed to its target and listed; a broken
#   symlink's target never stats, so -type f skips it. Reverting to `find`
#   (no -L) makes the symlink itself type 'l' — invisible — and the
#   `symlinked-bin-visible` scenario then FAILS (its launched marker never
#   appears). That is the negative control for the fix.
#
# usage: quickshell/test-overlay.sh
# env:   XVFB= XDOTOOL= QUICKSHELL=   (default: from PATH)
#        TEST_DISPLAY=:97
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_QML="$SCRIPT_DIR/config/Overlay.qml"
COMMON_DIR="$SCRIPT_DIR/config/Common"
QS_OVERLAY_SH="$SCRIPT_DIR/qs-overlay.sh"

XVFB="${XVFB:-Xvfb}"
XDOTOOL="${XDOTOOL:-xdotool}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
DPY="${TEST_DISPLAY:-:97}"

TMP="/tmp/qs-overlay-test.$$"
ENTRY="$TMP/entry"              # minimal profile hosting Overlay {}
PBIN="$TMP/pbin"               # the SANDBOXED $PATH the launcher scans
IMPLS="$TMP/impls"            # symlink targets that live OUTSIDE $PBIN
MARKS="$TMP/marks"           # marker files launched stubs write
HOME_S="$TMP/home"          # sandbox $HOME (projects.yaml lives here)
I3DIR="$TMP/i3"            # i3-msg stub's argv log + canned get_workspaces
RUN="$TMP/run"
CFG="$TMP/cfg"
CCH="$TMP/cache"

PASS=0
FAIL=0

# ---------------------------------------------------------------- harness ---

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

scenario() { printf '\n[%s]\n' "$1"; }

assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "anything but '$2'" "$3"; fi; }

# KWI3 PHASE pids (rpc-server.js driver rigs + their own quickshell/Xvfb) —
# every one this script itself started, killed by exact pid only (AGENTS.md's
# own "never pkill -f" rule), same discipline as test-kwi3-backend.sh.
KWI3_PIDS=()

cleanup() {
  # Kill the whole quickshell process group so the i3-msg subscribe stub (a
  # blocking sleep) and any launched marker stub die with it.
  [ -n "${OV_QS_PID:-}" ] && kill -- -"$OV_QS_PID" 2>/dev/null
  [ -n "${OV_QS_PID:-}" ] && kill "$OV_QS_PID" 2>/dev/null
  [ -n "${QS_PID:-}" ] && kill -- -"$QS_PID" 2>/dev/null
  [ -n "${QS_PID:-}" ] && kill "$QS_PID" 2>/dev/null
  sleep 0.3
  [ -n "${OV_XVFB_PID:-}" ] && kill "$OV_XVFB_PID" 2>/dev/null
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  # Close any control-fifo fds this script opened for the KWI3 PHASE rigs
  # before killing the rigs themselves, so the fifo write end never blocks.
  exec 9>&- 2>/dev/null
  exec 10>&- 2>/dev/null
  local p
  for p in "${KWI3_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  sleep 0.2
  for p in "${KWI3_PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# Is display <1> up? BOTH SOCKET NAMESPACES (dotfiles-4ai2). An X server binds
# a socket FILE at /tmp/.X11-unix/X<n>, an ABSTRACT name @/tmp/.X11-unix/X<n>
# that lives only in the kernel socket table, or both -- and which it gets is
# not its choice: where /tmp/.X11-unix is a read-only mount (a WSLg host
# bind-mounts it from /mnt/wslg with WSLg's own X0 inside and nothing else) a
# server can create no file and binds the abstract socket alone. Waiting on the
# file therefore never succeeded here, and this suite's own Xvfb looked like it
# had failed to start while serving perfectly.
dpy_up() { # <display>
  [ -e "/tmp/.X11-unix/X${1#:}" ] && return 0
  grep -q "@/tmp/\.X11-unix/X${1#:}\$" /proc/net/unix 2>/dev/null
}

for tool in "$XVFB" "$XDOTOOL" "$QUICKSHELL" node; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (XVFB=/XDOTOOL=/QUICKSHELL= to override)" >&2; exit 1; }
done
# Absolute quickshell path: the host is launched with PATH=$PBIN (the sandbox),
# which does NOT contain quickshell, so `env` could not resolve it by name.
QS_BIN="$(command -v "$QUICKSHELL")"
[ -r "$OVERLAY_QML" ] || { echo "FATAL: $OVERLAY_QML not readable" >&2; exit 1; }
[ -d "$COMMON_DIR" ] || { echo "FATAL: $COMMON_DIR not a directory" >&2; exit 1; }

# ── KWI3 PHASE prerequisite (sp004 Task 14, kwi3-234.14) ────────────────────
# The kwi3 checkout providing i3kwin/test/rpc-server.js and its harness —
# same convention as test-kwi3-backend.sh's own KWI3_REPO (default matches
# kwi3/dot.yaml's clone path; override for a dev worktree).
KWI3_REPO="${KWI3_REPO:-$HOME/.local/src/kwi3}"
KWI3_RPC_SERVER="$KWI3_REPO/i3kwin/test/rpc-server.js"
[ -r "$KWI3_RPC_SERVER" ] || {
  echo "FATAL: $KWI3_RPC_SERVER not found." >&2
  echo "       Set KWI3_REPO=/path/to/kwi3 (sp004 Task 12's rpc-server.js)." >&2
  exit 1
}

mkdir -p "$ENTRY" "$PBIN" "$IMPLS" "$MARKS" "$HOME_S/.config/project" "$I3DIR" \
         "$RUN" "$CFG" "$CCH"
chmod 700 "$RUN"

# ── sandboxed $PATH ─────────────────────────────────────────────────────────
# $PBIN is the ONLY dir on the launcher's $PATH, so the scan is deterministic:
# every coreutil the Overlay's Processes shell out to is symlinked in (so the
# pipelines resolve), plus the launcher test bins. `echo $PATH` inside
# pathScanner therefore sees exactly $PBIN.
SLEEP_BIN="$(command -v sleep)"
# cat is needed by the i3-msg stub's get_tree case (serves $I3DIR/tree.json).
for t in sh tr xargs find sed sort grep setsid cat; do
  src="$(command -v "$t")" || { echo "FATAL: $t not found for the sandbox PATH" >&2; exit 1; }
  ln -sf "$src" "$PBIN/$t"
done

# --- launcher test bins -------------------------------------------------------
# Three real scripts whose names all end in "-mark"... actually "mark" so a
# fuzzy "mark" narrows to exactly these three (no coreutil is a supersequence of
# m-a-r-k). Equal fuzzy score => deterministic localeCompare order:
# alphamark, betamark, zzmark. Each writes a distinct marker when launched.
mk_mark_bin() { # <name>
  cat > "$PBIN/$1" <<EOF
#!/bin/sh
printf 'ran\n' > "$MARKS/$1"
EOF
  chmod +x "$PBIN/$1"
}
mk_mark_bin alphamark
mk_mark_bin betamark
mk_mark_bin zzmark

# A SYMLINK to a real binary that lives OUTSIDE $PBIN. With `find -L` this is
# followed and listed as `symlinkbin`; launching it writes its marker. This is
# the rotz-linked-bin case the drift-fix restores.
cat > "$IMPLS/symlinkbin-impl" <<EOF
#!/bin/sh
printf 'ran\n' > "$MARKS/symlinkbin"
EOF
chmod +x "$IMPLS/symlinkbin-impl"
ln -sf "$IMPLS/symlinkbin-impl" "$PBIN/symlinkbin"

# A BROKEN symlink — target does not exist. `find -L` must NOT list it.
ln -sf "$IMPLS/does-not-exist" "$PBIN/brokenbin"

# --- i3-msg stub --------------------------------------------------------------
# Serves canned get_workspaces + get_tree (the switcher scan), emits ONE
# window::focus event on -t subscribe then BLOCKS (the windowSubscriber, which
# seeds focusHistory so the MRU order is deterministic), and records every other
# argv line — projectsSwitch's `workspace <n>`, projectsNew's rename+create
# chain, and switcherFocus's `[con_id=<id>] focus`. get_workspaces / get_tree /
# subscribe are NOT recorded; the tree is served from $I3DIR/tree.json so a
# scenario can swap it (e.g. the zero-windows floor) between toggles.
WS_JSON='[{"name":"alpha","focused":false},{"name":"web","focused":true}]'
# Injected MRU event: window 102 (beta) becomes the most-recent focus, so after
# the scan sorts (focused alpha first, then history rank) the order is
# alpha(101) beta(102) gamma(103) and setIndex(1) preselects beta.
FOCUS_EVT='{"change":"focus","container":{"id":102}}'
cat > "$PBIN/i3-msg" <<EOF
#!/bin/sh
case "\$1" in
  -t)
    case "\$2" in
      get_workspaces) printf '%s' '$WS_JSON'; exit 0 ;;
      get_tree)       cat "$I3DIR/tree.json"; exit 0 ;;
      subscribe)      printf '%s\n' '$FOCUS_EVT'; exec "$SLEEP_BIN" 300 ;;
      *)              exit 0 ;;
    esac ;;
esac
printf '%s\n' "\$*" >> "$I3DIR/argv.log"
exit 0
EOF
chmod +x "$PBIN/i3-msg"
: > "$I3DIR/argv.log"

# --- canned get_tree (switcher phase) ----------------------------------------
# Three real windows across three workspaces, plus one EXCLUDED self-title
# (qs-launcher) the tree walk must drop. con ids 101/102/103/999; the walk keys
# MRU off `id`. Single line: windowScanner's SplitParser strips newlines, so
# any inter-token newline would be swallowed — keep it flat. TREE_FULL is the
# default; the zero-windows scenario swaps in an empty workspace and restores.
# kwi3-234.22: the RAW tree-walk order here is "web" (gamma) BEFORE "mail"
# (beta) — deliberately NOT alpha/beta/gamma — so the raw order at index 1 is
# gamma, not beta. FOCUS_EVT below still seeds beta (102) as the sole MRU
# history entry, so the real sort (focused-first, then MRU rank) still lands
# on alpha(0) beta(1) gamma(2): a no-op/disabled sort would instead preselect
# gamma at index 1, which is exactly the mutation this ordering is here to
# catch (see the mru-preselect-index-1 scenario below).
TREE_FULL='{"type":"root","nodes":[{"type":"workspace","name":"code","nodes":[{"type":"con","id":101,"window":1001,"name":"alpha","focused":true,"nodes":[]}]},{"type":"workspace","name":"web","nodes":[{"type":"con","id":103,"window":1003,"name":"gamma","focused":false,"nodes":[]},{"type":"con","id":999,"window":1999,"name":"qs-launcher","focused":false,"nodes":[]}]},{"type":"workspace","name":"mail","nodes":[{"type":"con","id":102,"window":1002,"name":"beta","focused":false,"nodes":[]}]}]}'
TREE_EMPTY='{"type":"root","nodes":[{"type":"workspace","name":"void","nodes":[]}]}'
printf '%s\n' "$TREE_FULL" > "$I3DIR/tree.json"

# --- projects.yaml ------------------------------------------------------------
# Scanner greps '^  [a-zA-Z]' and takes the key. Two projects: alpha (has a live
# workspace "alpha" per the canned get_workspaces) and beta (none).
cat > "$HOME_S/.config/project/projects.yaml" <<'EOF'
projects:
  alpha: {}
  beta: {}
EOF

# ── minimal profile hosting Overlay {} ──────────────────────────────────────
ln -sf "$OVERLAY_QML" "$ENTRY/Overlay.qml"
ln -sf "$COMMON_DIR"  "$ENTRY/Common"
# The kwi3test IpcHandler below is test-only scaffolding beside the real
# Overlay {} — never inside it — for the KWI3 PHASE further down (sp004 T14,
# kwi3-234.14): a bare "is Kwi3Client connected yet" poll (same shape as
# test-kwi3-backend.sh's own kwi3test target) and one deliberate direct call
# for the "stale id -> -32001, ignored, no crash" edge case, which is far too
# racy to prove by timing a real close against the switcher's own refresh.
cat > "$ENTRY/shell.qml" <<'EOF'
import Quickshell
import Quickshell.Io
import "./Common"
ShellRoot {
    Overlay {}
    IpcHandler {
        target: "kwi3test"
        function available(tag: string): void {
            console.log("KWI3TEST available " + tag + " " + (Kwi3Client.available ? "1" : "0"))
        }
        function focusStaleId(tag: string, id: int): void {
            Kwi3Client.call("window.focus", { id: id }, function (err, res) {
                console.log("KWI3TEST focus-stale " + tag + " " +
                    JSON.stringify({ err: err, res: res }))
            })
        }
        function gridModule(tag: string): void {
            console.log("KWI3TEST grid-module " + tag + " " +
                Kwi3Grid.moduleW + "x" + Kwi3Grid.moduleH + "x" + Kwi3Grid.rowHeight)
        }
    }
}
EOF

# ── launch quickshell under Xvfb :97 ────────────────────────────────────────
"$XVFB" "$DPY" -screen 0 1280x800x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 20); do
  dpy_up "$DPY" && break
  sleep 0.5
done
dpy_up "$DPY" || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

# setsid: quickshell becomes its own process-group leader so cleanup can reap
# the whole tree (the blocking i3-msg subscribe sleep especially). PATH is the
# sandbox ONLY; HOME is the sandbox home; SWAYSOCK unset => wmMsg is i3-msg and
# fontSize is the deterministic i3 value; QS_RDP=1 mirrors the main-instance
# host. (QS_NO_KEYMON is gone with qs-keymon.py — dotfiles-hwds.40 moved the
# switcher gesture into hotkeyd, so nothing respawns on this display any more.)
setsid env -u SWAYSOCK -u KWI3SOCK \
    DISPLAY="$DPY" HOME="$HOME_S" PATH="$PBIN" \
    QS_RDP=1 \
    XDG_CONFIG_HOME="$CFG" XDG_RUNTIME_DIR="$RUN" XDG_CACHE_HOME="$CCH" \
    "$QS_BIN" -p "$ENTRY" >"$TMP/qs.out" 2>&1 &
QS_PID=$!

ipc() { env XDG_CONFIG_HOME="$CFG" XDG_RUNTIME_DIR="$RUN" XDG_CACHE_HOME="$CCH" \
            "$QUICKSHELL" ipc --pid "$QS_PID" "$@" 2>/dev/null; }

for i in $(seq 1 40); do
  n="$(ipc show | grep -c 'launcher')"
  [ "${n:-0}" -gt 0 ] && { UP=1; break; }
  sleep 0.5
done
[ -n "${UP:-}" ] || {
  echo "FATAL: overlay host did not expose the 'launcher' IPC target" >&2
  tail -30 "$TMP/qs.out" >&2; exit 1; }

# ── xdotool helpers ─────────────────────────────────────────────────────────
win_on() { # <title>
  local i id
  for i in $(seq 1 40); do
    id="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name "^$1\$" 2>/dev/null | head -1)"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    sleep 0.25
  done
  return 1
}
gone_on() { # <title>
  local i id
  for i in $(seq 1 40); do
    id="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name "^$1\$" 2>/dev/null | head -1)"
    [ -z "$id" ] && return 0
    sleep 0.25
  done
  return 1
}
focuswin() { env DISPLAY="$DPY" "$XDOTOOL" windowfocus "$1" 2>/dev/null; sleep 0.3; }
key()      { env DISPLAY="$DPY" "$XDOTOOL" key --clearmodifiers "$@" 2>/dev/null; sleep 0.2; }
keyraw()   { env DISPLAY="$DPY" "$XDOTOOL" key "$@" 2>/dev/null; sleep 0.2; }
typ()      { env DISPLAY="$DPY" "$XDOTOOL" type --clearmodifiers "$1" 2>/dev/null; sleep 0.35; }
geom_h()   { local H; eval "$(env DISPLAY="$DPY" "$XDOTOOL" getwindowgeometry --shell "$1" 2>/dev/null)"; printf '%s' "${HEIGHT:-?}"; }
geom_w()   { local W; eval "$(env DISPLAY="$DPY" "$XDOTOOL" getwindowgeometry --shell "$1" 2>/dev/null)"; printf '%s' "${WIDTH:-?}"; }

clear_marks() { rm -f "$MARKS"/*; }
clear_i3log() { : > "$I3DIR/argv.log"; }
i3log()       { tr '\n' ';' < "$I3DIR/argv.log" | sed 's/;*$//'; }
marker_wait() { # <name>  -> 0 if marker appears
  local i
  for i in $(seq 1 40); do [ -e "$MARKS/$1" ] && return 0; sleep 0.25; done
  return 1
}

# Open the launcher and wait for the $PATH scan to populate (height climbs off
# the empty-list floor of 40). Sets $WID.
open_launcher() {
  ipc call launcher toggle >/dev/null 2>&1
  WID="$(win_on qs-launcher)" || { fail "$1 (launcher map)" "a qs-launcher window" "none"; return 1; }
  focuswin "$WID"
  local i h
  for i in $(seq 1 40); do
    h="$(geom_h "$WID")"
    [ "${h:-0}" -gt 40 ] 2>/dev/null && break
    sleep 0.25
  done
  return 0
}
close_launcher() { key Escape; gone_on qs-launcher || ipc call launcher toggle >/dev/null 2>&1; }

open_projects() {
  ipc call projects toggle >/dev/null 2>&1
  WID="$(win_on qs-projects)" || { fail "$1 (projects map)" "a qs-projects window" "none"; return 1; }
  focuswin "$WID"
  sleep 0.3
  return 0
}
close_projects() { key Escape; gone_on qs-projects || ipc call projects toggle >/dev/null 2>&1; }

# The switcher maps only AFTER the get_tree scan completes (windowScanner sets
# overlay.visible + the setIndex(1) MRU preselect in onExited), so a mapped
# qs-switcher window implies the model is loaded and index 1 is selected.
open_switcher() {
  ipc call switcher toggle >/dev/null 2>&1
  WID="$(win_on qs-switcher)" || { fail "$1 (switcher map)" "a qs-switcher window" "none"; return 1; }
  focuswin "$WID"
  sleep 0.3
  return 0
}
# search-mode entry via the IPC `search` verb (opens the switcher, then drops
# into switcher-search — the sway/not-yet-up path). Same qs-switcher title.
open_switcher_search() {
  ipc call switcher search >/dev/null 2>&1
  WID="$(win_on qs-switcher)" || { fail "$1 (switcher-search map)" "a qs-switcher window" "none"; return 1; }
  focuswin "$WID"
  sleep 0.4
  return 0
}
close_switcher() { ipc call switcher cancel >/dev/null 2>&1; gone_on qs-switcher; }

# expected launcher list size (same scan the QML runs), for the geometry formula
SCAN_N="$(echo "$PBIN" | tr ':' '\n' | xargs -I{} find -L {} -maxdepth 1 -executable -type f 2>/dev/null | sed 's|.*/||' | sort -u | wc -l | tr -d ' ')"

echo "overlay: $OVERLAY_QML"
echo "sandbox PATH: $PBIN  (scan lists $SCAN_N bins)"

# ============================================================================
# LAUNCHER PHASE
# ============================================================================

# ---- symlinked-bin-visible (the find -L regression control) -----------------
scenario "symlinked-bin-visible: a symlink to a real binary is listed and launches (fails on a reverted find -L)"
clear_marks
if open_launcher symlinked-bin-visible; then
  typ "symlinkbin"        # unique subsequence — only the symlinked bin matches
  key Return
  if marker_wait symlinkbin; then
    assert_eq "the symlinked bin launched (its marker was written)" "ran" "$(cat "$MARKS/symlinkbin" 2>/dev/null)"
  else
    fail "the symlinked bin launched (its marker was written)" "marker $MARKS/symlinkbin" "no marker (symlink not listed? find -L reverted?)"
  fi
  gone_on qs-launcher
fi

# ---- broken-symlink-hidden --------------------------------------------------
scenario "broken-symlink-hidden: a broken symlink is NOT listed (typing its name yields an empty list)"
if open_launcher broken-symlink-hidden; then
  typ "brokenbin"         # if it were listed, one row -> height 72; hidden -> 40
  sleep 0.3
  assert_eq "no row matches 'brokenbin' -> launcher collapses to the empty floor (32+0+8)" \
    "40" "$(geom_h "$WID")"
  close_launcher
fi

# ---- fuzzy-launch-non-first (adr0010 id-stability analog) -------------------
scenario "fuzzy-launch-non-first: a fuzzy subsequence + Down + Enter launches the SELECTED (non-first) bin"
clear_marks
if open_launcher fuzzy-launch-non-first; then
  typ "mark"              # narrows to alphamark(0), betamark(1), zzmark(2)
  key Down                # select betamark — the SECOND filtered row
  key Return
  if marker_wait betamark; then
    pass "the second filtered row (betamark) launched"
  else
    fail "the second filtered row (betamark) launched" "marker betamark" "none"
  fi
  assert_eq "the FIRST filtered row (alphamark) did NOT launch — not a first-row publish" \
    "" "$(cat "$MARKS/alphamark" 2>/dev/null)"
  assert_eq "the third row (zzmark) did NOT launch either" \
    "" "$(cat "$MARKS/zzmark" 2>/dev/null)"
  gone_on qs-launcher
fi

# ---- launcher-geometry (us015 AC1) ------------------------------------------
scenario "launcher-geometry: window is 480 wide and 32+min(n,8)*32+8 tall for the seeded n"
if open_launcher launcher-geometry; then
  cap=$(( SCAN_N < 8 ? SCAN_N : 8 ))
  exp_h=$(( 32 + cap * 32 + 8 ))
  assert_eq "height == 32 + min($SCAN_N,8)*32 + 8" "$exp_h" "$(geom_h "$WID")"
  assert_eq "width == 480" "480" "$(geom_w "$WID")"
  close_launcher
fi

# ---- empty-PATH-scan noop (edge) --------------------------------------------
# Nothing seeded to launch under a bogus filter -> Enter must not spawn anything.
scenario "empty-filter-enter-noop: Enter over a filter that matches nothing launches nothing"
clear_marks
if open_launcher empty-filter; then
  typ "zzznomatchqqq"
  key Return
  sleep 0.4
  assert_eq "no marker written — Enter over an empty filtered list is a no-op" \
    "0" "$(ls -1 "$MARKS" 2>/dev/null | wc -l | tr -d ' ')"
  close_launcher
fi

# ============================================================================
# PROJECTS PHASE
# ============================================================================

# ---- projects-switch-argv ---------------------------------------------------
scenario "projects-switch-argv: Enter on a project runs i3-msg workspace <name>"
clear_i3log
if open_projects projects-switch-argv; then
  typ "beta"              # narrows to beta (no live workspace -> switches to bare name)
  key Return
  gone_on qs-projects
  assert_eq "i3-msg received exactly 'workspace beta'" "workspace beta" "$(i3log)"
fi

# ---- projects-new-argv-chain ------------------------------------------------
scenario "projects-new-argv-chain: Shift+Enter renames the bare workspace then creates the next index"
clear_i3log
if open_projects projects-new-argv-chain; then
  typ "alpha"             # alpha HAS a live workspace "alpha" -> rename + create chain
  keyraw shift+Return
  gone_on qs-projects
  chain="$(i3log)"
  assert_ne "the rename step reached i3-msg (bare 'alpha' -> 'alpha_1')" "" "$(printf '%s' "$chain" | grep -o 'rename workspace')"
  assert_ne "the create step reached i3-msg (workspace alpha_2)" "" "$(printf '%s' "$chain" | grep -o 'workspace alpha_2')"
fi

# ---- missing-projects.yaml empty state (edge) -------------------------------
scenario "missing-projects-yaml: no registry -> empty projects list, dialog opens without crashing"
mv "$HOME_S/.config/project/projects.yaml" "$HOME_S/.config/project/projects.yaml.bak"
clear_i3log
if open_projects missing-projects-yaml; then
  assert_ne "the projects dialog still mapped (no crash on a missing registry)" "" "$WID"
  key Return              # empty list -> Enter is a no-op
  sleep 0.3
  assert_eq "Enter over the empty projects list invoked no i3-msg workspace switch" "" "$(i3log)"
  close_projects
fi
mv "$HOME_S/.config/project/projects.yaml.bak" "$HOME_S/.config/project/projects.yaml"

# ============================================================================
# SWITCHER PHASE
# ============================================================================
# Canned get_tree: alpha(101,focused) beta(102) gamma(103) + excluded
# qs-launcher(999) — RAW tree-walk order alpha, gamma, beta (kwi3-234.22: the
# "web"/gamma workspace comes before "mail"/beta in TREE_FULL on purpose). One
# injected window::focus for 102 seeds the MRU so the SORTED scan order is
# alpha, beta, gamma; setIndex(1) preselects beta(102) only because the sort
# ran — a no-op/disabled sort would leave the raw order and preselect gamma
# instead. Commit paths (IPC confirm / mod release) route through
# Combo.confirmCurrent(), so the focus argv carries the SELECTED filtered
# row's con id — never a positional index against the unfiltered list
# (adr0010).

confirm_and_capture() { # drives IPC confirm, waits for the switcher to close, echoes argv
  ipc call switcher confirm >/dev/null 2>&1
  gone_on qs-switcher
  sleep 0.2
  i3log
}

# ---- mru-preselect-index-1 --------------------------------------------------
scenario "mru-preselect-index-1: plain switcher preselects the previous MRU window (index 1 = beta/102)"
clear_i3log
if open_switcher mru-preselect-index-1; then
  assert_eq "confirm focuses the index-1 (preselected) window con_id=102" \
    "[con_id=102] focus" "$(confirm_and_capture)"
fi

# ---- excluded-titles-absent -------------------------------------------------
scenario "excluded-titles-absent: the qs-launcher self-title is filtered from the tree walk (3 rows, not 4)"
clear_i3log
if open_switcher excluded-titles-absent; then
  # plain height = 0(no input) + max(min(n,-1cap→n),1)*32 + 8. 3 real windows ->
  # 3*32+8=104; if qs-launcher leaked in it'd be 4*32+8=136.
  assert_eq "plain switcher height == 3*32+8 (excluded title absent)" "104" "$(geom_h "$WID")"
  close_switcher
fi

# ---- cycle-wraps-both-ends --------------------------------------------------
scenario "cycle-wraps-both-ends: next() wraps end->start and prev() wraps start->end (Combo cycle)"
# next from preselect(1=beta): ->2(gamma) ->wrap 0(alpha). confirm focuses 101.
clear_i3log
if open_switcher cycle-wraps-next; then
  ipc call switcher next >/dev/null 2>&1; sleep 0.2   # -> gamma(idx2)
  ipc call switcher next >/dev/null 2>&1; sleep 0.2   # -> wrap to alpha(idx0)
  assert_eq "two next() from index 1 wrapped past the end to alpha con_id=101" \
    "[con_id=101] focus" "$(confirm_and_capture)"
fi
# prev from preselect(1=beta): ->0(alpha) ->wrap 2(gamma). confirm focuses 103.
clear_i3log
if open_switcher cycle-wraps-prev; then
  ipc call switcher prev >/dev/null 2>&1; sleep 0.2   # -> alpha(idx0)
  ipc call switcher prev >/dev/null 2>&1; sleep 0.2   # -> wrap to gamma(idx2)
  assert_eq "two prev() from index 1 wrapped past the start to gamma con_id=103" \
    "[con_id=103] focus" "$(confirm_and_capture)"
fi

# ---- confirm-selected-con-id (the filtered-vs-unfiltered negative control) ---
scenario "confirm-selected-con-id: with a search filter active, confirm focuses the SELECTED filtered row"
# Search "gamma" narrows to gamma(103) alone; unfiltered index 0 is alpha(101).
# A mutant resolving the index against the UNFILTERED list would focus 101.
clear_i3log
if open_switcher_search confirm-selected-con-id; then
  typ "gamma"
  captured="$(confirm_and_capture)"
  assert_eq "confirm focuses the filtered row gamma con_id=103" \
    "[con_id=103] focus" "$captured"
  assert_ne "confirm did NOT focus the unfiltered-index-0 window (alpha con_id=101)" \
    "[con_id=101] focus" "$captured"
fi

# ---- search-filters-by-ws ---------------------------------------------------
scenario "search-filters-by-ws: a query matching only the workspace field selects that window"
# "mail" matches no name (alpha/beta/gamma) but IS beta's ws; filters to beta(102).
clear_i3log
if open_switcher_search search-filters-by-ws; then
  typ "mail"
  assert_eq "ws-only match narrows to beta and confirm focuses con_id=102" \
    "[con_id=102] focus" "$(confirm_and_capture)"
fi

# ---- zero-windows-noop ------------------------------------------------------
scenario "zero-windows-noop: an empty tree shows the 1-row floor and confirm is a no-op (no focus, no crash)"
printf '%s\n' "$TREE_EMPTY" > "$I3DIR/tree.json"
clear_i3log
if open_switcher zero-windows-noop; then
  assert_eq "empty switcher height == floor of 1 row (0+1*32+8=40)" "40" "$(geom_h "$WID")"
  ipc call switcher confirm >/dev/null 2>&1
  gone_on qs-switcher
  sleep 0.3
  assert_eq "confirm over the empty floor recorded no [con_id=...] focus" \
    "" "$(i3log | grep -o 'con_id')"
fi
printf '%s\n' "$TREE_FULL" > "$I3DIR/tree.json"

# ============================================================================
# IPC SURFACE (inspection) — verbs unchanged, qs-overlay.sh untouched
# ============================================================================

scenario "ipc-surface: launcher/switcher/projects targets are all exposed by the overlay"
targets="$(ipc show)"
assert_eq "launcher target present" "1" "$(printf '%s\n' "$targets" | grep -c 'launcher')"
assert_eq "switcher target present" "1" "$(printf '%s\n' "$targets" | grep -c 'switcher')"
assert_eq "projects target present" "1" "$(printf '%s\n' "$targets" | grep -c 'projects')"

# ============================================================================
# OVERLAY-PROFILE PHASE (T6 / dotfiles-evnv.6) — the deployed separate-process
# shape, native host.
# ============================================================================
# The phases above load config/Overlay.qml directly in a minimal $ENTRY profile
# with QS_RDP=1 — that proves the MAIN-instance host (adr0004 RDP mode). This
# phase proves the OTHER adr0004 mode: the desktop `quickshell -p overlay`
# SEPARATE process, booted through the SHIPPED overlay/ directory exactly as
# rotz deploys it —
#
#   $TMP/fake-config-link  (symlink, mimics ~/.config/quickshell-overlay)
#     -> repo quickshell/overlay/                 (the rotz deploy link target)
#          ├── shell.qml    thin ShellRoot { Overlay {} } wrapper (T6)
#          ├── Overlay.qml  relative symlink -> ../config/Overlay.qml
#          └── Common       relative symlink -> ../config/Common
#
# quickshell -p resolves the wrapper, which resolves `Overlay {}` and Overlay's
# own `import "./Common"` through the two in-repo RELATIVE symlinks. If the
# wrapper were left as the old 950-line duplicate this would still boot — but
# then overlay/shell.qml would have drifted again, which the dead-code sweep
# below rejects. If the symlinks were missing the `Overlay` type is unresolved
# and no launcher target ever appears: that is this phase's RED. No QS_RDP here
# (native path); isolated XDG_CACHE_HOME so a stale bytecode of the old shell
# cannot mask the rewrite. Same sandbox $PBIN/$HOME_S -> same deterministic
# SCAN_N -> the T3 launcher geometry (480 x 32+min(n,8)*32+8) still holds.

scenario "overlay-profile: quickshell -p boots the shipped overlay wrapper via a symlinked deploy path and answers launcher toggle with T3 geometry"

OV_DIR="$SCRIPT_DIR/overlay"           # the real repo overlay/ (committed symlinks + wrapper)
FAKE_LINK="$TMP/fake-config-link"      # mimics the rotz deploy link ~/.config/quickshell-overlay
OV_DPY=":98"
OV_RUN="$TMP/ov-run"                   # isolated runtime dir (own ipc socket)
OV_CCH="$TMP/ov-cache"                 # isolated cache — stale old-shell bytecode can't mask

ln -sf "$OV_DIR" "$FAKE_LINK"
mkdir -p "$OV_RUN" "$OV_CCH"
chmod 700 "$OV_RUN"

"$XVFB" "$OV_DPY" -screen 0 1280x800x24 >"$TMP/xvfb-ov.log" 2>&1 &
OV_XVFB_PID=$!
for i in $(seq 1 20); do
  dpy_up "$OV_DPY" && break
  sleep 0.5
done
if ! dpy_up "$OV_DPY"; then
  fail "overlay-profile Xvfb $OV_DPY started" "a display" "none"
else
  setsid env -u SWAYSOCK -u KWI3SOCK -u QS_RDP \
      DISPLAY="$OV_DPY" HOME="$HOME_S" PATH="$PBIN" \
      XDG_CONFIG_HOME="$CFG" XDG_RUNTIME_DIR="$OV_RUN" XDG_CACHE_HOME="$OV_CCH" \
      "$QS_BIN" -p "$FAKE_LINK" >"$TMP/qs-ov.out" 2>&1 &
  OV_QS_PID=$!

  ov_ipc() { env XDG_CONFIG_HOME="$CFG" XDG_RUNTIME_DIR="$OV_RUN" XDG_CACHE_HOME="$OV_CCH" \
                 "$QUICKSHELL" ipc --pid "$OV_QS_PID" "$@" 2>/dev/null; }

  OV_UP=""
  for i in $(seq 1 40); do
    n="$(ov_ipc show | grep -c 'launcher')"
    [ "${n:-0}" -gt 0 ] && { OV_UP=1; break; }
    sleep 0.5
  done
  if [ -z "$OV_UP" ]; then
    fail "the wrapper booted via -p and exposed the 'launcher' IPC target" \
         "launcher target through the symlinked deploy path" \
         "no launcher target (wrapper unresolved? Overlay/Common symlinks missing?)"
    tail -20 "$TMP/qs-ov.out" >&2
  else
    pass "quickshell -p on the symlinked deploy path exposed the launcher target"
    ov_ipc call launcher toggle >/dev/null 2>&1
    OV_WID=""
    for i in $(seq 1 40); do
      OV_WID="$(env DISPLAY="$OV_DPY" "$XDOTOOL" search --onlyvisible --name '^qs-launcher$' 2>/dev/null | head -1)"
      [ -n "$OV_WID" ] && break
      sleep 0.25
    done
    if [ -z "$OV_WID" ]; then
      fail "launcher window mapped through the native overlay-profile host" "a qs-launcher window" "none"
    else
      pass "launcher window mapped through the native overlay-profile host"
      # wait for the $PATH scan to lift height off the empty floor (40)
      for i in $(seq 1 40); do
        eval "$(env DISPLAY="$OV_DPY" "$XDOTOOL" getwindowgeometry --shell "$OV_WID" 2>/dev/null)"
        [ "${HEIGHT:-0}" -gt 40 ] 2>/dev/null && break
        sleep 0.25
      done
      eval "$(env DISPLAY="$OV_DPY" "$XDOTOOL" getwindowgeometry --shell "$OV_WID" 2>/dev/null)"
      cap=$(( SCAN_N < 8 ? SCAN_N : 8 ))
      exp_h=$(( 32 + cap * 32 + 8 ))
      assert_eq "overlay-profile launcher height == 32 + min($SCAN_N,8)*32 + 8 (T3 geometry, find -L scan)" \
        "$exp_h" "${HEIGHT:-?}"
      assert_eq "overlay-profile launcher width == 480" "480" "${WIDTH:-?}"
    fi
  fi
fi

# ============================================================================

# ============================================================================
# KWI3 PHASE (sp004 Task 14, kwi3-234.14) — the same Overlay.qml, driven
# against the REAL kwi3 core (i3kwin/test/rpc-server.js), not a hand-rolled
# stub — same discipline as i3kwin/test/floating-hooks.js and this repo's own
# test-kwi3-backend.sh: every criterion below reads what was actually SENT
# to the rig (a `CALL {...}` line, rpc-server.js's own logCalls), not only
# the rendered result, so a hook that mutates the UI right but skips/
# duplicates a call would still fail here.
#
# The rig is scripted over a control FIFO (a throwaway node fixture wrapping
# rpc-server.js's start(), NOT part of either repo) instead of argv/env,
# because the switcher/projects scenarios need named windows and named
# workspaces created AFTER quickshell is already up and subscribed — the
# i3-msg stub above manages this with a canned tree.json; the real core has
# no such file to swap, so this phase drives it live instead.
# ============================================================================

K_TMP="$TMP/kwi3"
mkdir -p "$K_TMP"
KWI3_DPY=":99"   # $DPY (:97) and $OV_DPY (:98) are both torn down by now.
# win_on/gone_on/focuswin/key/keyraw/typ/geom_h/geom_w all read the GLOBAL
# $DPY, not a parameter - reassigning it is what lets this phase reuse them
# unchanged instead of forking display-parameterised copies of each one.
DPY="$KWI3_DPY"

cat > "$K_TMP/rig-driver.js" <<'JSEOF'
'use strict';
// Throwaway fixture for test-overlay.sh's KWI3 PHASE, NOT part of either
// repo: a control-fifo wrapper around i3kwin/test/rpc-server.js's start(),
// so this suite can script the rig (open/close/focus named windows, switch
// workspaces) the same way it already scripts the i3-msg stub above — one
// line in, one line out, via a named pipe instead of argv/env.
//
// Protocol: one JSON object per line on stdin, one line of output per
// command on stdout — "OK {...}" or "ERR ...". Every RPC method invocation
// is ALSO logged ("CALL {...}", rpc-server.js's own opts.logCalls) so the
// bash suite can grep this same log for what the QML client under test
// actually sent — the "counted on the rig" success criterion.
const path = require('path');
const fs = require('fs');
const readline = require('readline');
const [rpcServerPath, sockPath] = process.argv.slice(2);
const root = path.join(path.dirname(rpcServerPath), '..');
const sources = fs.readdirSync(path.join(root, 'core'))
    .filter((f) => f.endsWith('.js'))
    .map((f) => path.join(root, 'core', f))
    .concat([path.join(root, 'adapters/kwin/contents/code/adapter.js')]);

require(rpcServerPath).start(sockPath, sources, { logCalls: true }).then((rig) => {
    const windows = {};
    function conId(w) { return rig.ctx.conOf(rig.ctx.windowInfo(w).id).id; }

    function handle(cmd) {
        switch (cmd.op) {
            case 'openWindow': {
                if (cmd.workspace) { rig.ctx.dispatch('workspace:' + cmd.workspace); }
                const w = rig.openWindow(cmd.title);
                windows[cmd.title] = w;
                return { id: conId(w) };
            }
            case 'focusWindow': {
                const w = windows[cmd.title];
                if (!w) { throw new Error('no such window: ' + cmd.title); }
                rig.ctx.focusWindowById(conId(w));
                return {};
            }
            case 'closeWindow': {
                const w = windows[cmd.title];
                if (!w) { throw new Error('no such window: ' + cmd.title); }
                rig.closeWindow(w);
                delete windows[cmd.title];
                return {};
            }
            case 'dispatch': {
                rig.ctx.dispatch(cmd.action);
                return {};
            }
            default:
                throw new Error('unknown op: ' + cmd.op);
        }
    }

    console.log(sockPath);
    const rl = readline.createInterface({ input: process.stdin });
    rl.on('line', (line) => {
        line = line.trim();
        if (!line) { return; }
        let cmd;
        try { cmd = JSON.parse(line); } catch (e) { console.log('ERR bad json: ' + line); return; }
        try {
            const result = handle(cmd);
            console.log('OK ' + JSON.stringify({ op: cmd.op, result: result }));
        } catch (e) {
            console.log('ERR ' + cmd.op + ': ' + e);
        }
    });

    process.on('SIGTERM', () => rig.stop().then(() => process.exit(0)));
}, (err) => { console.error('kwi3-rig-driver: ' + err); process.exit(1); });
JSEOF

k_wait_socket() { # <path> <timeout-s>
  local n=$(( ${2:-15} * 10 )) i
  for i in $(seq 1 "$n"); do [ -S "$1" ] && return 0; sleep 0.1; done
  return 1
}
k_last_id() { sed -n 's/.*"id":\([0-9]*\).*/\1/p' <<<"$1" | tail -1; }

"$XVFB" "$KWI3_DPY" -screen 0 1280x800x24 >"$K_TMP/xvfb.log" 2>&1 &
KWI3_XVFB_PID=$!
KWI3_PIDS+=("$KWI3_XVFB_PID")
for i in $(seq 1 20); do dpy_up "$KWI3_DPY" && break; sleep 0.5; done
if ! dpy_up "$KWI3_DPY"; then
  fail "KWI3 PHASE: Xvfb $KWI3_DPY started" "a display" "none"
else

# ---------------------------------------------------------------------------
# Rig 1: three real windows (alpha/beta/gamma) — switcher + launcher geometry
# ---------------------------------------------------------------------------
K1_SOCK="$K_TMP/rig1.sock"
K1_LOG="$K_TMP/rig1.log"
K1_FIFO="$K_TMP/rig1.fifo"
mkfifo "$K1_FIFO"
node "$K_TMP/rig-driver.js" "$KWI3_RPC_SERVER" "$K1_SOCK" <"$K1_FIFO" >"$K1_LOG" 2>&1 &
K1_PID=$!
KWI3_PIDS+=("$K1_PID")
exec 9>"$K1_FIFO"
k1_ctl() { echo "$1" >&9; sleep 0.3; tail -1 "$K1_LOG"; }
k1_mark() { K1_MARK="$(wc -l <"$K1_LOG" | tr -d ' ')"; }
k1_since() { tail -n +"$((K1_MARK + 1))" "$K1_LOG"; }

if ! k_wait_socket "$K1_SOCK" 20; then
  fail "KWI3 PHASE: rig 1 bound $K1_SOCK" "socket present" "missing"
  cat "$K1_LOG" >&2
else
  K1_CFG="$K_TMP/cfg1"; K1_RUN="$K_TMP/run1"; K1_CCH="$K_TMP/cache1"; K1_QSLOG="$K_TMP/qs1.log"
  mkdir -p "$K1_CFG" "$K1_RUN" "$K1_CCH"
  chmod 700 "$K1_RUN"
  setsid env -u SWAYSOCK \
      DISPLAY="$KWI3_DPY" HOME="$HOME_S" PATH="$PBIN" \
      QS_RDP=1 KWI3SOCK="$K1_SOCK" \
      XDG_CONFIG_HOME="$K1_CFG" XDG_RUNTIME_DIR="$K1_RUN" XDG_CACHE_HOME="$K1_CCH" \
      "$QS_BIN" -p "$ENTRY" >"$K1_QSLOG" 2>&1 &
  K1_QS_PID=$!
  KWI3_PIDS+=("$K1_QS_PID")
  k1_ipc() { env XDG_CONFIG_HOME="$K1_CFG" XDG_RUNTIME_DIR="$K1_RUN" XDG_CACHE_HOME="$K1_CCH" \
                 "$QUICKSHELL" ipc --pid "$K1_QS_PID" "$@" 2>/dev/null; }

  K1_UP=""
  for i in $(seq 1 40); do
    n="$(k1_ipc show | grep -c 'kwi3test')"
    [ "${n:-0}" -gt 0 ] && { K1_UP=1; break; }
    sleep 0.5
  done
  if [ -z "$K1_UP" ]; then
    fail "KWI3 PHASE: quickshell (rig 1) exposed the kwi3test IPC target" "target up" "not found"
    tail -30 "$K1_QSLOG" >&2
  else
    AVAIL=""
    for i in $(seq 1 30); do
      k1_ipc call kwi3test available "boot_$i" >/dev/null 2>&1
      sleep 0.2
      grep -aq "KWI3TEST available boot_$i 1" "$K1_QSLOG" && { AVAIL=1; break; }
    done
    if [ -z "$AVAIL" ]; then
      fail "KWI3 PHASE: Kwi3Client.available becomes true against rig 1" "1" "0"
    else
      # The rig has NO windows yet: quickshell was started on an empty
      # world on purpose, so the empty-list edge case runs first.
      scenario "kwi3-empty-window-list: the switcher opens on an empty tree.get, Enter sends NO window.focus and nothing crashes (edge case)"
      k1_mark
      k1_ipc call switcher toggle >/dev/null 2>&1
      KWID="$(win_on qs-switcher)" || fail "kwi3-empty-window-list (switcher map)" "a qs-switcher window" "none"
      if [ -n "${KWID:-}" ]; then
        pass "the switcher maps with an empty window list"
        assert_eq "exactly one tree.get fed it" "1" "$(k1_since | grep -c '"method":"tree.get"')"
        k1_ipc call switcher confirm >/dev/null 2>&1
        sleep 0.5
        assert_eq "Enter on an empty list sends no window.focus" "0" \
          "$(k1_since | grep -c '"method":"window.focus"')"
        assert_ne "quickshell still answers IPC after Enter on an empty list" "" "$(k1_ipc show)"
        if env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-switcher$' >/dev/null 2>&1; then
          k1_ipc call switcher toggle >/dev/null 2>&1
        fi
        gone_on qs-switcher || fail "kwi3-empty-window-list (switcher closes)" "no qs-switcher" "still mapped"
      fi

      # kwi3-234.22: created alpha, THEN gamma, THEN beta — deliberately not
      # creation-order alpha/beta/gamma — so the RAW tree.get order (windows
      # walk workspaces in num order, which follows creation order here) is
      # alpha, gamma, beta and the raw index-1 window is gamma, not beta.
      # The MRU seed below (focus beta, then focus gamma) makes gamma the
      # current focus and beta the prior one, so the real sort
      # (focused-first, then MRU rank) produces gamma(0) beta(1) alpha(2) —
      # beta still lands at index 1 only because the sort ran. A no-op/
      # disabled sort would instead leave the raw order's gamma at index 1,
      # which is exactly the mutation this creation order exists to catch.
      ALPHA_ID="$(k_last_id "$(k1_ctl '{"op":"openWindow","title":"alpha"}')")"
      GAMMA_ID="$(k_last_id "$(k1_ctl '{"op":"openWindow","title":"gamma","workspace":"web"}')")"
      BETA_ID="$(k_last_id "$(k1_ctl '{"op":"openWindow","title":"beta","workspace":"mail"}')")"

      # Seed MRU history AFTER Overlay has subscribed: beta then gamma
      # focused, in that order — gamma ends up current, beta the MRU-1 spot.
      k1_ctl '{"op":"focusWindow","title":"beta"}' >/dev/null
      k1_ctl '{"op":"focusWindow","title":"gamma"}' >/dev/null
      sleep 0.3

      scenario "kwi3-mru-preselect: switcher lists windows in focus-history order; Enter sends exactly one window.focus {id} (AC1, counted on the rig)"
      k1_mark
      k1_ipc call switcher toggle >/dev/null 2>&1
      KWID="$(win_on qs-switcher)" || fail "kwi3-mru-preselect (switcher map)" "a qs-switcher window" "none"
      if [ -n "${KWID:-}" ]; then
        focuswin "$KWID"
        sleep 0.3
        k1_ipc call switcher confirm >/dev/null 2>&1
        gone_on qs-switcher
        sleep 0.3
        n_focus="$(k1_since | grep -c '"method":"window.focus"')"
        assert_eq "exactly one window.focus call reached the rig" "1" "$n_focus"
        last="$(k1_since | grep '"method":"window.focus"' | tail -1)"
        assert_eq "it targets beta (con $BETA_ID) — the MRU index-1 preselect, proving the order" \
          "1" "$(grep -c "\"id\":$BETA_ID" <<<"$last")"
      fi

      scenario "kwi3-switcher-refreshes-on-close: closing a window while the switcher is open shrinks the list; Enter still lands on a LIVE window, never the closed one (edge case)"
      k1_ipc call switcher toggle >/dev/null 2>&1
      KWID="$(win_on qs-switcher)" || fail "kwi3-switcher-refreshes-on-close (switcher map)" "a qs-switcher window" "none"
      if [ -n "${KWID:-}" ]; then
        focuswin "$KWID"
        sleep 0.3
        H_BEFORE="$(geom_h "$KWID")"
        k1_mark
        k1_ctl '{"op":"closeWindow","title":"alpha"}' >/dev/null
        SHRUNK=""
        for i in $(seq 1 30); do
          H_NOW="$(geom_h "$KWID")"
          [ "${H_NOW:-0}" -lt "${H_BEFORE:-0}" ] 2>/dev/null && { SHRUNK=1; break; }
          sleep 0.2
        done
        [ -n "$SHRUNK" ] && pass "the switcher's own list (and window height) shrinks once the close is seen" \
          || fail "the switcher's own list shrinks on window.removed" "height < $H_BEFORE" "$H_NOW"
        k1_ipc call switcher confirm >/dev/null 2>&1
        gone_on qs-switcher
        sleep 0.3
        n_focus="$(k1_since | grep -c '"method":"window.focus"')"
        assert_eq "exactly one window.focus call reached the rig after the close" "1" "$n_focus"
        last="$(k1_since | grep '"method":"window.focus"' | tail -1)"
        assert_eq "the surviving preselect is NOT the closed alpha id" \
          "0" "$(grep -c "\"id\":$ALPHA_ID" <<<"$last")"
      fi

      scenario "kwi3-focus-stale-id-ignored: window.focus on an id that no longer exists answers -32001 and is ignored — no crash (edge case)"
      k1_ipc call kwi3test focusStaleId "staleA" "$ALPHA_ID" >/dev/null 2>&1
      STALE_FOUND=""
      for i in $(seq 1 30); do
        grep -aq "KWI3TEST focus-stale staleA " "$K1_QSLOG" && { STALE_FOUND=1; break; }
        sleep 0.2
      done
      if [ -n "$STALE_FOUND" ]; then
        line="$(grep -a 'KWI3TEST focus-stale staleA ' "$K1_QSLOG" | tail -1)"
        case "$line" in
          *'"code":-32001'*) pass "a stale id's window.focus answers -32001" ;;
          *) fail "a stale id's window.focus answers -32001" '"code":-32001' "$line" ;;
        esac
      else
        fail "the stale-id focusStaleId hook answered" "a KWI3TEST focus-stale line" "(timed out)"
      fi
      targets="$(k1_ipc show)"
      assert_ne "quickshell is still alive and answering IPC after the stale-id call (ignored, not fatal)" "" "$targets"

      scenario "kwi3-launcher-geometry: width and height are whole multiples of moduleW/moduleH, every row one rowHeight (AC2)"
      k1_ipc call kwi3test gridModule "g1" >/dev/null 2>&1
      sleep 0.3
      dims="$(grep -a 'KWI3TEST grid-module g1 ' "$K1_QSLOG" | tail -1 | awk '{print $NF}')"
      MW="${dims%%x*}"; rest="${dims#*x}"; MH="${rest%%x*}"; RH="${rest#*x}"
      k1_ipc call launcher toggle >/dev/null 2>&1
      LWID="$(win_on qs-launcher)" || fail "kwi3-launcher-geometry (launcher map)" "a qs-launcher window" "none"
      if [ -n "${LWID:-}" ]; then
        focuswin "$LWID"
        for i in $(seq 1 40); do
          h="$(geom_h "$LWID")"
          [ "${h:-0}" -gt 40 ] 2>/dev/null && break
          sleep 0.25
        done
        W="$(geom_w "$LWID")"; H="$(geom_h "$LWID")"
        if [ -n "$MW" ] && [ -n "$MH" ] && [ -n "$RH" ]; then
          assert_eq "width % moduleW == 0 ($MW)" "0" "$((W % MW))"
          assert_eq "height % moduleH == 0 ($MH)" "0" "$((H % MH))"
          cap=$(( SCAN_N < 8 ? SCAN_N : 8 ))
          pad_cells=$(( (8 * 2 + MH) / (MH * 2) )); [ "$pad_cells" -lt 1 ] && pad_cells=1
          exp_h=$(( RH + cap * RH + pad_cells * MH ))
          width_cells=$(( (480 * 2 + MW) / (MW * 2) ))
          exp_w=$(( width_cells * MW ))
          assert_eq "height == rowHeight + cap*rowHeight + pad, all whole cells" "$exp_h" "$H"
          assert_eq "width == whole modules of the historic 480px" "$exp_w" "$W"
        else
          fail "moduleW/moduleH/rowHeight were read from Kwi3Grid" "3 numbers" "$dims"
        fi
        key Escape
      fi
    fi
  fi
fi
kill "$K1_QS_PID" 2>/dev/null
kill "$K1_PID" 2>/dev/null
exec 9>&-

# ---------------------------------------------------------------------------
# Rig 2: projects — Enter -> workspace.focus; Shift+Enter -> rename then
# focus (AC1c); a project name with spaces AND a quote needs no shell
# escaping on this path (edge case; the old \\\" escaping is gone here).
# ---------------------------------------------------------------------------
K2_SOCK="$K_TMP/rig2.sock"
K2_LOG="$K_TMP/rig2.log"
K2_FIFO="$K_TMP/rig2.fifo"
mkfifo "$K2_FIFO"
node "$K_TMP/rig-driver.js" "$KWI3_RPC_SERVER" "$K2_SOCK" <"$K2_FIFO" >"$K2_LOG" 2>&1 &
K2_PID=$!
KWI3_PIDS+=("$K2_PID")
exec 10>"$K2_FIFO"
k2_ctl() { echo "$1" >&10; sleep 0.3; tail -1 "$K2_LOG"; }
k2_mark() { K2_MARK="$(wc -l <"$K2_LOG" | tr -d ' ')"; }
k2_since() { tail -n +"$((K2_MARK + 1))" "$K2_LOG"; }

if ! k_wait_socket "$K2_SOCK" 20; then
  fail "KWI3 PHASE: rig 2 bound $K2_SOCK" "socket present" "missing"
  cat "$K2_LOG" >&2
else
  # workspace "alpha" (a LIVE, non-current workspace with a window so it is
  # not reaped once we switch away — a project with a bare-name workspace,
  # for the rename chain) and current "web" (so alpha is not the focused
  # project and stays listed).
  k2_ctl '{"op":"dispatch","action":"workspace:alpha"}' >/dev/null
  k2_ctl '{"op":"openWindow","title":"alpha-term"}' >/dev/null
  k2_ctl '{"op":"dispatch","action":"workspace:web"}' >/dev/null
  k2_ctl '{"op":"openWindow","title":"web-term"}' >/dev/null

  K2_HOME="$K_TMP/home2"
  mkdir -p "$K2_HOME/.config/project"
  # "my \"proj\"" has no live workspace (projectsSwitch's straight
  # workspace.focus branch); "alpha" HAS one (the rename-chain branch).
  # Both a space and a literal quote in one key — the exact edge case named
  # in sp004 Task 14's edge_cases — flow through with no shell quoting at
  # all on this path (JSON params, not a shell command line).
  cat > "$K2_HOME/.config/project/projects.yaml" <<'YAMLEOF'
projects:
  alpha: {}
  my "proj": {}
YAMLEOF

  K2_CFG="$K_TMP/cfg2"; K2_RUN="$K_TMP/run2"; K2_CCH="$K_TMP/cache2"; K2_QSLOG="$K_TMP/qs2.log"
  mkdir -p "$K2_CFG" "$K2_RUN" "$K2_CCH"
  chmod 700 "$K2_RUN"
  setsid env -u SWAYSOCK \
      DISPLAY="$KWI3_DPY" HOME="$K2_HOME" PATH="$PBIN" \
      QS_RDP=1 KWI3SOCK="$K2_SOCK" \
      XDG_CONFIG_HOME="$K2_CFG" XDG_RUNTIME_DIR="$K2_RUN" XDG_CACHE_HOME="$K2_CCH" \
      "$QS_BIN" -p "$ENTRY" >"$K2_QSLOG" 2>&1 &
  K2_QS_PID=$!
  KWI3_PIDS+=("$K2_QS_PID")
  k2_ipc() { env XDG_CONFIG_HOME="$K2_CFG" XDG_RUNTIME_DIR="$K2_RUN" XDG_CACHE_HOME="$K2_CCH" \
                 "$QUICKSHELL" ipc --pid "$K2_QS_PID" "$@" 2>/dev/null; }

  K2_UP=""
  for i in $(seq 1 40); do
    n="$(k2_ipc show | grep -c 'kwi3test')"
    [ "${n:-0}" -gt 0 ] && { K2_UP=1; break; }
    sleep 0.5
  done
  if [ -z "$K2_UP" ]; then
    fail "KWI3 PHASE: quickshell (rig 2) exposed the kwi3test IPC target" "target up" "not found"
    tail -30 "$K2_QSLOG" >&2
  else
    AVAIL2=""
    for i in $(seq 1 30); do
      k2_ipc call kwi3test available "boot_$i" >/dev/null 2>&1
      sleep 0.2
      grep -aq "KWI3TEST available boot_$i 1" "$K2_QSLOG" && { AVAIL2=1; break; }
    done
    if [ -z "$AVAIL2" ]; then
      fail "KWI3 PHASE: Kwi3Client.available becomes true against rig 2" "1" "0"
    else
      scenario "kwi3-projects-switch-sends-focus: Enter on a project with no live workspace sends workspace.focus {name} — spaces and a literal quote need no escaping (AC1b + edge case)"
      k2_mark
      k2_ipc call projects toggle >/dev/null 2>&1
      PWID="$(win_on qs-projects)" || fail "kwi3-projects-switch-sends-focus (projects map)" "a qs-projects window" "none"
      if [ -n "${PWID:-}" ]; then
        focuswin "$PWID"
        sleep 0.4
        typ 'proj'   # narrows to "my \"proj\"" — "alpha" has no p/r/o/j subsequence match
        key Return
        gone_on qs-projects
        sleep 0.3
        n_focus="$(k2_since | grep -c '"method":"workspace.focus"')"
        assert_eq "exactly one workspace.focus call reached the rig" "1" "$n_focus"
        last="$(k2_since | grep '"method":"workspace.focus"' | tail -1)"
        assert_eq 'workspace.focus named "my \"proj\"" verbatim, quote and space intact' \
          "1" "$(grep -Fc '"name":"my \"proj\""' <<<"$last")"
      fi

      scenario "kwi3-projects-rename-chain: Shift+Enter on a project with a bare live workspace sends workspace.rename THEN workspace.focus, in that order (AC1c)"
      k2_mark
      k2_ipc call projects toggle >/dev/null 2>&1
      PWID="$(win_on qs-projects)" || fail "kwi3-projects-rename-chain (projects map)" "a qs-projects window" "none"
      if [ -n "${PWID:-}" ]; then
        focuswin "$PWID"
        sleep 0.4
        typ "alpha"
        keyraw shift+Return
        gone_on qs-projects
        sleep 0.4
        chain="$(k2_since | grep -E '"method":"(workspace.rename|workspace.focus)"')"
        n_rename="$(grep -c '"method":"workspace.rename"' <<<"$chain")"
        n_wfocus="$(grep -c '"method":"workspace.focus"' <<<"$chain")"
        assert_eq "exactly one workspace.rename call" "1" "$n_rename"
        assert_eq "exactly one workspace.focus call" "1" "$n_wfocus"
        rename_line="$(grep -n '"method":"workspace.rename"' <<<"$chain" | head -1 | cut -d: -f1)"
        focus_line="$(grep -n '"method":"workspace.focus"' <<<"$chain" | head -1 | cut -d: -f1)"
        if [ -n "$rename_line" ] && [ -n "$focus_line" ]; then
          [ "$rename_line" -lt "$focus_line" ] \
            && pass "workspace.rename reached the rig BEFORE workspace.focus" \
            || fail "workspace.rename reached the rig before workspace.focus" \
                    "rename line < focus line" "rename=$rename_line focus=$focus_line"
        fi
        assert_eq 'the rename targets "alpha_1"' "1" \
          "$(grep -Fc '"name":"alpha_1"' <<<"$chain")"
        assert_eq 'the focus targets "alpha_2"' "1" \
          "$(grep -Fc '"name":"alpha_2"' <<<"$chain")"
      fi
    fi
  fi
fi
kill "$K2_QS_PID" 2>/dev/null
kill "$K2_PID" 2>/dev/null
exec 10>&-

fi   # dpy_up "$KWI3_DPY"

# ---------------------------------------------------------------------------
# config.js vs the REAL core (sp004 Task 14 "Extra"; widened by kwi3-55l.2):
# ~/.dotfiles/kwi3/config.js loads through the real kwi3LoadErrors()/
# onWindowAdded seam with no collected errors, and a window titled
# qs-launcher/qs-projects/qs-switcher/qs-clip/qs-notif managed on a
# fake-kwin world ends up floating, undecorated, grid-snapped and focused —
# the same shape i3kwin/test/floating-hooks.js checks its own hooks with,
# run here against the ACTUAL file this repo ships rather than a fixture.
# qs-clip/qs-notif (the clipboard picker and notification-history browser,
# kwi3-55l.2) were added to this list because they used to open TILED on
# kwi3 — the rule's regex stopped at "switcher" — even though i3's own
# for_window rules have always floated them (i3/config.common: "qs-clip",
# "qs-notif", identical treatment to the launcher/projects/switcher lines).
# ---------------------------------------------------------------------------
scenario "kwi3-config-js-vs-real-core: ~/.dotfiles/kwi3/config.js applies Jan's runner rule through the real kwi3 core, with no collected load errors"
KWI3_CONFIG_JS="$SCRIPT_DIR/../kwi3/config.js"
cat > "$K_TMP/config-js-check.js" <<'JSEOF'
'use strict';
const path = require('path');
const fs = require('fs');
const KWI3_REPO = process.argv[2];
const CONFIG_JS = process.argv[3];
const h = require(path.join(KWI3_REPO, 'i3kwin/test/harness.js'));
const fake = require(path.join(KWI3_REPO, 'i3kwin/test/fake-kwin.js'));

const core = fs.readdirSync(path.join(KWI3_REPO, 'i3kwin/core'))
    .filter((f) => f.endsWith('.js'))
    .map((f) => path.join(KWI3_REPO, 'i3kwin/core', f));
const adapter = path.join(KWI3_REPO, 'i3kwin/adapters/kwin/contents/code/adapter.js');

const ctx = h.load(core.concat([adapter, CONFIG_JS]));
const world = h.makeWorld(ctx, {});
ctx.ensureRoot();

let pass = true;
function ok(cond, label) { if (!cond) { console.error('FAIL: ' + label); pass = false; } }
function eq(got, want, label) {
    if (JSON.stringify(got) !== JSON.stringify(want)) {
        console.error('FAIL: ' + label + ' - got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want));
        pass = false;
    }
}

eq(ctx.kwi3LoadErrors(), [], 'kwi3/config.js loads through the real core with no collected errors');

// Every title the runner rule is supposed to cover today (kwi3-55l.2 added
// clip/notif to the original launcher/projects/switcher set) - one window
// per title, all managed on the SAME world, the way "two runners in a row"
// is exercised elsewhere: this also proves a later title in the list is not
// somehow shadowed by an earlier one matching first.
const TITLES = ['qs-launcher', 'qs-projects', 'qs-switcher', 'qs-clip', 'qs-notif'];

const sent = { geometry: [], decorated: [], activate: [] };
const realGeom = ctx.host.setFrameGeometry;
ctx.host.setFrameGeometry = function (id, rect) {
    sent.geometry.push({ id: id, x: rect.x, y: rect.y, w: rect.width, h: rect.height });
    return realGeom.call(ctx.host, id, rect);
};
const realDecorated = ctx.host.setDecorated;
ctx.host.setDecorated = function (id, on) {
    sent.decorated.push({ id: id, on: on });
    return realDecorated.call(ctx.host, id, on);
};
const realActivate = ctx.host.activate;
ctx.host.activate = function (id) {
    sent.activate.push(id);
    return realActivate.call(ctx.host, id);
};

TITLES.forEach(function (title) {
    const w = fake.observe(fake.FakeWindow({
        caption: title, output: world.ws.activeScreen,
        desktops: [world.ws.currentDesktop], frameGeometry: fake.rect(0, 0, 400, 300)
    }), 'window');
    world.ws.windows.push(w);
    ctx.manage(w);

    const info = ctx.windowInfo(w);
    const entry = ctx.entryOf(info.id);
    const con = entry ? entry.con : null;

    eq(ctx.windowPlacement(info.id), 'floating', title + ' is floating (w.float())');
    ok(con && con.parent && con.parent.type === 'floating_con', title + ': wrapped in a floating_con');
    ok(con && con.noFrame === true, title + ': noFrame() marked the con');
    eq(sent.decorated.filter((e) => e.id === info.id && e.on === false).length, 1,
       title + ': cmdSetDecorated(id,false) sent exactly once (w.noFrame())');

    const originX = ctx.kwi3GridOriginX(), originY = ctx.kwi3GridOriginY();
    const geoms = sent.geometry.filter((e) => e.id === info.id);
    eq(geoms.length, 1, title + ': exactly one geometry write (w.moveTo(kwi3.grid.center(w)))');
    ok((geoms[0].x - originX) % ctx.MODULE_W === 0, title + ': x snapped to the tile grid');
    ok((geoms[0].y - originY) % ctx.MODULE_H === 0, title + ': y snapped to the tile grid');

    eq(sent.activate.filter((id) => id === info.id).length, 1,
       title + ': cmdActivate(id) sent exactly once (w.focus())');
    ok(world.ws.activeWindow === w, title + ': the host ends up with it active');
});

if (!pass) { process.exit(1); }
console.log('OK - kwi3/config.js applies Jan\'s runner rule against the real core (' + TITLES.join(', ') + ')');
JSEOF
if node "$K_TMP/config-js-check.js" "$KWI3_REPO" "$KWI3_CONFIG_JS" >"$K_TMP/config-js-check.log" 2>&1; then
  pass "kwi3/config.js applies Jan's runner rule (float/noFrame/moveTo/focus) through the real core to launcher/projects/switcher/clip/notif, no collected errors"
else
  fail "kwi3/config.js applies Jan's runner rule through the real core" "OK (exit 0)" "$(cat "$K_TMP/config-js-check.log")"
fi

# ---------------------------------------------------------------------------
# kwi3-55l.9: the non-Quickshell app float table (i3/config.common:316-342,
# ported into kwi3/config.js as KWI3_I3_FLOAT_RULES) applies against the REAL
# kwi3 core, same discipline as the runner-rule check just above.
#
# Driven from an EXPECTED table written here independently of config.js (the
# i3 source line, the i3 criterion key, the literal i3 string, whether i3 had
# `(?i)`), covering all 27 rows. Each row is proven to be keyed on the RIGHT
# field, not merely to match something (review rejection #1 of kwi3-55l.9:
# a title equal to the class let `class`->`title` swaps pass):
#   class rows: WM_CLASS class = the string, instance and title unrelated ->
#               floats; the string ONLY in the title (class/instance "foot")
#               -> tiles.
#   title rows: title = the string, class/instance "foot" -> floats; the
#               string ONLY in class AND instance (title "foot") -> tiles.
#   (?i) rows:  the positive uses a differently-cased value, so the `i` flag
#               has to be there; every other row's case-swapped value must
#               tile, so no stray `i` flag either.
# Plus a cross-check that config.js's table has exactly these 27 rows, each
# with exactly the expected single key, and the xterm negative control.
# ---------------------------------------------------------------------------
scenario "kwi3-i3-float-rules-vs-real-core: i3/config.common's non-Quickshell floating-enable rules (kwi3-55l.9) apply through the real kwi3 core, each keyed on the right field"
cat > "$K_TMP/i3-float-rules-check.js" <<'JSEOF'
'use strict';
const path = require('path');
const fs = require('fs');
const KWI3_REPO = process.argv[2];
const CONFIG_JS = process.argv[3];
const h = require(path.join(KWI3_REPO, 'i3kwin/test/harness.js'));
const fake = require(path.join(KWI3_REPO, 'i3kwin/test/fake-kwin.js'));

const core = fs.readdirSync(path.join(KWI3_REPO, 'i3kwin/core'))
    .filter((f) => f.endsWith('.js'))
    .map((f) => path.join(KWI3_REPO, 'i3kwin/core', f));
const adapter = path.join(KWI3_REPO, 'i3kwin/adapters/kwin/contents/code/adapter.js');
const SOURCES = core.concat([adapter, CONFIG_JS]);

let pass = true;
let checks = 0;
function eq(got, want, label) {
    checks++;
    if (JSON.stringify(got) !== JSON.stringify(want)) {
        console.error('FAIL: ' + label + ' - got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want));
        pass = false;
    }
}

// Transcribed by hand from i3/config.common:316-342 - NOT read from
// config.js. `value` is the i3 criterion string used literally as a window
// property; for `File Transfer*` the literal (with its `*`) is a string the
// unanchored regex matches, just as i3's PCRE does.
const EXPECTED = [
    { line: 316, key: 'title', value: 'alsamixer' },
    { line: 317, key: 'class', value: 'calamares' },
    { line: 318, key: 'class', value: 'Clipgrab' },
    { line: 319, key: 'title', value: 'File Transfer' },
    { line: 320, key: 'class', value: 'fpakman' },
    { line: 321, key: 'class', value: 'Galculator' },
    { line: 322, key: 'class', value: 'GParted' },
    { line: 323, key: 'title', value: 'i3_help' },
    { line: 324, key: 'class', value: 'Lightdm-settings' },
    { line: 325, key: 'class', value: 'Lxappearance' },
    { line: 326, key: 'class', value: 'Manjaro-hello' },
    { line: 327, key: 'class', value: 'Manjaro Settings Manager' },
    { line: 328, key: 'title', value: 'MuseScore: Play Panel' },
    { line: 329, key: 'class', value: 'Nitrogen' },
    { line: 330, key: 'class', value: 'Oblogout' },
    { line: 331, key: 'class', value: 'octopi' },
    { line: 332, key: 'title', value: 'About Pale Moon' },
    { line: 333, key: 'class', value: 'Pamac-manager' },
    { line: 334, key: 'class', value: 'Pavucontrol' },
    { line: 335, key: 'class', value: 'qt5ct' },
    { line: 336, key: 'class', value: 'Qtconfig-qt4' },
    { line: 337, key: 'class', value: 'Simple-scan' },
    { line: 338, key: 'class', value: 'System-config-printer.py', ci: true },
    { line: 339, key: 'class', value: 'Skype' },
    { line: 340, key: 'class', value: 'Timeset-gui' },
    { line: 341, key: 'class', value: 'virtualbox', ci: true },
    { line: 342, key: 'class', value: 'Xfburn' }
];

function swapCase(s) {
    return s.split('').map((c) => c === c.toUpperCase() ? c.toLowerCase() : c.toUpperCase()).join('');
}

// One fresh world per window: a placement answer can never be an artefact
// of an earlier window in the same run.
function placementOf(props) {
    const ctx = h.load(SOURCES);
    const world = h.makeWorld(ctx, {});
    ctx.ensureRoot();
    const w = fake.observe(fake.FakeWindow(Object.assign({
        output: world.ws.activeScreen,
        desktops: [world.ws.currentDesktop],
        frameGeometry: fake.rect(0, 0, 400, 300)
    }, props)), 'window');
    world.ws.windows.push(w);
    ctx.manage(w);
    return ctx.windowPlacement(ctx.windowInfo(w).id);
}

// --- cross-check against config.js's own table ---
const ctx0 = h.load(SOURCES);
h.makeWorld(ctx0, {});
ctx0.ensureRoot();
eq(ctx0.kwi3LoadErrors(), [], 'kwi3/config.js loads through the real core with no collected errors');
const TABLE = ctx0.KWI3_I3_FLOAT_RULES;
eq(Array.isArray(TABLE) ? TABLE.length : TABLE, EXPECTED.length, 'KWI3_I3_FLOAT_RULES has one row per i3 rule');
EXPECTED.forEach(function (e, i) {
    const row = TABLE && TABLE[i];
    eq(row ? Object.keys(row.match) : null, [e.key], ':' + e.line + ' row is keyed on exactly ' + e.key);
});

// --- behaviour, every row ---
const NEUTRAL = 'foot';
EXPECTED.forEach(function (e) {
    const tag = ':' + e.line + ' ' + e.key + '=' + JSON.stringify(e.value);
    const posValue = e.ci ? swapCase(e.value) : e.value;
    let pos, neg;
    if (e.key === 'class') {
        pos = { resourceClass: posValue, resourceName: 'unrelatedinst', caption: 'Unrelated window' };
        neg = { resourceClass: NEUTRAL, resourceName: NEUTRAL, caption: e.value };
    } else {
        pos = { resourceClass: NEUTRAL, resourceName: NEUTRAL, caption: posValue };
        neg = { resourceClass: e.value, resourceName: e.value, caption: NEUTRAL };
    }
    eq(placementOf(pos), 'floating', tag + ': the ' + e.key + (e.ci ? ' (differently cased: ' + JSON.stringify(posValue) + ')' : '') + ' floats it');
    eq(placementOf(neg), 'tiled', tag + ': the string only in the ' + (e.key === 'class' ? 'title' : 'class/instance') + ' leaves it tiled');

    if (!e.ci) {
        const swapped = Object.assign({}, pos);
        if (e.key === 'class') { swapped.resourceClass = swapCase(e.value); }
        else { swapped.caption = swapCase(e.value); }
        eq(placementOf(swapped), 'tiled', tag + ': case-sensitive in i3, so ' + JSON.stringify(swapCase(e.value)) + ' stays tiled');
    }
});

// The one deliberate narrowing: i3's `.` in System-config-printer.py is an
// unescaped PCRE dot (any char); config.js escapes it.
eq(placementOf({ resourceClass: 'System-config-printerXpy', resourceName: 'x', caption: 'x' }), 'tiled',
   ':338 escaped dot (deliberate narrowing vs i3): System-config-printerXpy stays tiled');

// Negative control: an ordinary xterm matches none of the rows.
eq(placementOf({ resourceClass: 'xterm', resourceName: 'xterm', caption: 'xterm' }), 'tiled',
   'xterm (non-matching control) stays tiled');

if (!pass) { process.exit(1); }
console.log('OK - kwi3/config.js\'s ported i3 float-rule table: ' + checks + ' checks over ' + EXPECTED.length + ' rows');
JSEOF
if node "$K_TMP/i3-float-rules-check.js" "$KWI3_REPO" "$KWI3_CONFIG_JS" >"$K_TMP/i3-float-rules-check.log" 2>&1; then
  pass "kwi3/config.js's ported i3/config.common float-rule table (kwi3-55l.9): all 27 rows float on the right field only, case rules hold, xterm tiles ($(tail -1 "$K_TMP/i3-float-rules-check.log"))"
else
  fail "kwi3/config.js's ported i3/config.common float-rule table applies through the real core, each row keyed on the right field" "OK (exit 0)" "$(cat "$K_TMP/i3-float-rules-check.log")"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
