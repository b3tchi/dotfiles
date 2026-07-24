#!/usr/bin/env bash
# test-overlay.sh — consumer suite for the i3-dialog overlay (sp017 / ft008),
# launcher + projects phases (Task 3 / dotfiles-evnv.3). Sibling of
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

cleanup() {
  # Kill the whole quickshell process group so the i3-msg subscribe stub (a
  # blocking sleep) and any launched marker stub die with it.
  [ -n "${QS_PID:-}" ] && kill -- -"$QS_PID" 2>/dev/null
  [ -n "${QS_PID:-}" ] && kill "$QS_PID" 2>/dev/null
  sleep 0.3
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

for tool in "$XVFB" "$XDOTOOL" "$QUICKSHELL"; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (XVFB=/XDOTOOL=/QUICKSHELL= to override)" >&2; exit 1; }
done
# Absolute quickshell path: the host is launched with PATH=$PBIN (the sandbox),
# which does NOT contain quickshell, so `env` could not resolve it by name.
QS_BIN="$(command -v "$QUICKSHELL")"
[ -r "$OVERLAY_QML" ] || { echo "FATAL: $OVERLAY_QML not readable" >&2; exit 1; }
[ -d "$COMMON_DIR" ] || { echo "FATAL: $COMMON_DIR not a directory" >&2; exit 1; }

mkdir -p "$ENTRY" "$PBIN" "$IMPLS" "$MARKS" "$HOME_S/.config/project" "$I3DIR" \
         "$RUN" "$CFG" "$CCH"
chmod 700 "$RUN"

# ── sandboxed $PATH ─────────────────────────────────────────────────────────
# $PBIN is the ONLY dir on the launcher's $PATH, so the scan is deterministic:
# every coreutil the Overlay's Processes shell out to is symlinked in (so the
# pipelines resolve), plus the launcher test bins. `echo $PATH` inside
# pathScanner therefore sees exactly $PBIN.
SLEEP_BIN="$(command -v sleep)"
for t in sh tr xargs find sed sort grep setsid; do
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
# Serves canned get_workspaces, BLOCKS on -t subscribe (the windowSubscriber),
# and records every other argv line (projectsSwitch's `workspace <n>` and
# projectsNew's rename+create chain). get_workspaces/subscribe are NOT recorded.
WS_JSON='[{"name":"alpha","focused":false},{"name":"web","focused":true}]'
cat > "$PBIN/i3-msg" <<EOF
#!/bin/sh
case "\$1" in
  -t)
    case "\$2" in
      get_workspaces) printf '%s' '$WS_JSON'; exit 0 ;;
      subscribe)      exec "$SLEEP_BIN" 300 ;;
      *)              exit 0 ;;
    esac ;;
esac
printf '%s\n' "\$*" >> "$I3DIR/argv.log"
exit 0
EOF
chmod +x "$PBIN/i3-msg"
: > "$I3DIR/argv.log"

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
cat > "$ENTRY/shell.qml" <<'EOF'
import Quickshell
ShellRoot { Overlay {} }
EOF

# ── launch quickshell under Xvfb :97 ────────────────────────────────────────
"$XVFB" "$DPY" -screen 0 1280x800x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 20); do
  [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break
  sleep 0.5
done
[ -e "/tmp/.X11-unix/X${DPY#:}" ] || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

# setsid: quickshell becomes its own process-group leader so cleanup can reap
# the whole tree (the blocking i3-msg subscribe sleep especially). PATH is the
# sandbox ONLY; HOME is the sandbox home; SWAYSOCK unset => wmMsg is i3-msg and
# fontSize is the deterministic i3 value; QS_NO_KEYMON=1 suppresses the keymon
# respawn on this keyboard-less display; QS_RDP=1 mirrors the main-instance host.
setsid env -u SWAYSOCK \
    DISPLAY="$DPY" HOME="$HOME_S" PATH="$PBIN" \
    QS_RDP=1 QS_NO_KEYMON=1 \
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
# IPC SURFACE (inspection) — verbs unchanged, qs-overlay.sh untouched
# ============================================================================

scenario "ipc-surface: launcher/switcher/projects targets are all exposed by the overlay"
targets="$(ipc show)"
assert_eq "launcher target present" "1" "$(printf '%s\n' "$targets" | grep -c 'launcher')"
assert_eq "switcher target present" "1" "$(printf '%s\n' "$targets" | grep -c 'switcher')"
assert_eq "projects target present" "1" "$(printf '%s\n' "$targets" | grep -c 'projects')"

# ============================================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
