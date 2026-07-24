#!/usr/bin/env bash
# test-mode-bar.sh — headless suite for the reusable i3/sway mode-hint bar
# (sp018 / ft009). Sibling of test-combo.sh; same discipline — Xvfb display,
# isolated XDG_* dirs, named scenarios, a self-test that MUST fail. UI is
# observed indirectly (adr0002): logic is asserted through sh-visible effects
# (here, CASE lines the QML prints on stdout/stderr).
#
# PHASE 0 (this file, sp018 Task 1 / dotfiles-80px.1): the
# Common/ModeBarTheme.qml constants + hints registry + resolve/hintsFor/
# displayName, extracted VERBATIM from config/Bar.qml's inline modeHints()
# and the pill display-name ternary. A throwaway harness config is written to
# $TMP, imports the repo's Common/ dir (symlinked by absolute path), evaluates
# a pinned scenario table, prints `CASE <name> <payload>` lines, and exits;
# quickshell runs it under Xvfb and this script asserts each expected line.
#
# The pin is byte-identical to Bar.qml's pre-refactor modeHints(): resize 6
# rows, screenshot 4 rows, system 8 rows, unknown -> [{key:"",label:<raw>}].
# The `system-long-name-resolves` scenario is the negative control — the
# system mode's IPC name is the full `$mode_system` string
# (`(l)ock, (e)xit, ...`, i3/config.common:255), matched via
# indexOf("(l)ock"), NOT equality; an equality-match mutant returns the
# fallback row for the long name and FAILS this scenario.
#
# usage: quickshell/test-mode-bar.sh
# env:   XVFB= QUICKSHELL=   (default: from PATH)
#        TEST_DISPLAY=:98
#        SELFTEST=1          flip one expectation wrong -> suite FAILS,
#                            proving the harness can actually fail.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/config/Common"

XVFB="${XVFB:-Xvfb}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
DPY="${TEST_DISPLAY:-:98}"
SELFTEST="${SELFTEST:-0}"

TMP="/tmp/qs-modebar-test.$$"
CFG="$TMP/cfg"
RUN="$TMP/run"
CCH="$TMP/cache"
CASES="$TMP/cases.txt"       # extracted `CASE <name> <payload>` lines

PASS=0
FAIL=0

# ---------------------------------------------------------------- harness ---

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

scenario() { printf '\n[%s]\n' "$1"; }

# payload for a CASE name — everything after "CASE <name> " on its line.
case_of() { # <name>
  sed -n "s/^CASE $1 //p" "$CASES" | head -1
}

assert_case() { # <name> <expected>
  local got; got="$(case_of "$1")"
  if [ "$2" = "$got" ]; then pass "$1"; else fail "$1" "$2" "$got"; fi
}

cleanup() {
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

for tool in "$XVFB" "$QUICKSHELL"; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "FATAL: $tool not found (XVFB=/QUICKSHELL= to override)" >&2; exit 1; }
done
[ -d "$COMMON_DIR" ] || { echo "FATAL: $COMMON_DIR not a directory" >&2; exit 1; }
[ -r "$COMMON_DIR/ModeBarTheme.qml" ] || { echo "FATAL: ModeBarTheme.qml missing" >&2; exit 1; }

mkdir -p "$TMP" "$CFG" "$RUN" "$CCH"
chmod 700 "$RUN"

# --- throwaway harness config in $TMP importing the repo's Common/ ----------
# Common is symlinked by ABSOLUTE path so the harness imports the exact dir
# under test (this worktree's), matching the Bar.qml consumer's `import
# "./Common"`.
ln -s "$COMMON_DIR" "$CFG/Common"

# The full $mode_system string from i3/config.common:255 — the system mode's
# real IPC name, matched by indexOf("(l)ock").
SYS='(l)ock, (e)xit, switch_(u)ser, (s)uspend, (h)ibernate, (r)eboot, (Shift+s)hutdown'

cat > "$CFG/shell.qml" <<QMLEOF
import Quickshell
import QtQuick
import "./Common"

ShellRoot {
  function emit(name, payload) { console.log("CASE " + name + " " + payload) }
  function j(v) { return JSON.stringify(v) }

  readonly property string sys: ${SYS@Q}

  Component.onCompleted: {
    // ---- ModeBarTheme: AC1 parity constants dumped as one JSON object ----
    emit("theme-constants", JSON.stringify({
      highlight: ModeBarTheme.highlight,
      pillBg:    ModeBarTheme.pillBg,
      fg:        ModeBarTheme.fg,
      muted:     ModeBarTheme.muted,
      font:      ModeBarTheme.font
    }))

    // ---- hints registry: byte-identical to Bar.qml's modeHints() ----
    emit("hints-resize-verbatim",     j(ModeBarTheme.hints["resize"]))
    emit("hints-screenshot-verbatim", j(ModeBarTheme.hints["screenshot"]))
    emit("hints-system-verbatim",     j(ModeBarTheme.hints["system"]))

    // ---- resolve: the full \$mode_system string routes to system via
    //      indexOf("(l)ock"), NOT equality (an equality mutant fails here) ----
    emit("system-long-name-resolves", j(ModeBarTheme.hintsFor(sys)))

    // ---- unknown mode -> fallback row [{key:"", label:<raw>}] ----
    emit("unknown-mode-fallback", j(ModeBarTheme.hintsFor("somefuture")))

    // ---- displayName ternary (resize/screenshot else system) ----
    emit("display-names", JSON.stringify([
      ModeBarTheme.displayName("resize"),
      ModeBarTheme.displayName("screenshot"),
      ModeBarTheme.displayName(sys),
      ModeBarTheme.displayName("somefuture"),
      ModeBarTheme.displayName("")
    ]))

    // ---- empty-string mode -> fallback row with empty label ----
    emit("empty-mode-fallback", j(ModeBarTheme.hintsFor("")))

    emit("DONE", "1")
    Qt.callLater(function() { Quickshell.exit(0) })
  }
}
QMLEOF

# --- run the harness under Xvfb, capture CASE lines -------------------------
"$XVFB" "$DPY" -screen 0 640x480x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for i in $(seq 1 20); do
  [ -e "/tmp/.X11-unix/X${DPY#:}" ] && break
  sleep 0.5
done
[ -e "/tmp/.X11-unix/X${DPY#:}" ] || { echo "FATAL: Xvfb $DPY did not start" >&2; exit 1; }

timeout 30 env -u SWAYSOCK DISPLAY="$DPY" \
  XDG_CONFIG_HOME="$CFG" XDG_RUNTIME_DIR="$RUN" XDG_CACHE_HOME="$CCH" \
  "$QUICKSHELL" -p "$CFG" >"$TMP/qs.out" 2>&1
# console.log lands on stderr with a colored " DEBUG qml: " prefix; strip
# everything up to and including "CASE " so the payload survives verbatim.
grep -a 'CASE ' "$TMP/qs.out" | sed 's/^.*CASE /CASE /' > "$CASES"

if ! grep -q '^CASE DONE 1$' "$CASES"; then
  echo "FATAL: harness did not run to completion (no DONE marker)" >&2
  echo "--- quickshell output (tail) ---" >&2
  tail -30 "$TMP/qs.out" >&2
  exit 1
fi

# ============================================================================
# PHASE 0 — ModeBarTheme constants + hints registry + resolve/displayName
# ============================================================================

scenario "ModeBarTheme — AC1 parity constants (sp018 / ft009 AC1)"
EXP_CONST='{"highlight":"#CB4B16","pillBg":"#152024","fg":"#FDF6E3","muted":"#707880","font":"Iosevka Nerd Font"}'
[ "$SELFTEST" = "1" ] \
  && EXP_CONST='{"highlight":"#999999","pillBg":"#152024","fg":"#FDF6E3","muted":"#707880","font":"Iosevka Nerd Font"}'
assert_case "theme-constants" "$EXP_CONST"

scenario "ModeBarTheme.hints — byte-identical to Bar.qml modeHints() (AC3/AC4)"
assert_case "hints-resize-verbatim" \
  '[{"key":"j","label":"←"},{"key":"k","label":"↓"},{"key":"l","label":"↑"},{"key":";","label":"→"},{"key":"←↓↑→","label":"arrows"},{"key":"Esc","label":"exit"}]'
assert_case "hints-screenshot-verbatim" \
  '[{"key":"drag","label":"select region"},{"key":"2-tap","label":"corners"},{"key":"w","label":"whole screen"},{"key":"Esc","label":"cancel"}]'
assert_case "hints-system-verbatim" \
  '[{"key":"l","label":"lock"},{"key":"e","label":"exit"},{"key":"u","label":"switch user"},{"key":"s","label":"suspend"},{"key":"h","label":"hibernate"},{"key":"r","label":"reboot"},{"key":"S-s","label":"shutdown"},{"key":"Esc","label":"cancel"}]'

scenario "resolve — full \$mode_system string routes to system via indexOf (AC4)"
# An equality-match mutant returns the fallback row for the long name instead.
assert_case "system-long-name-resolves" \
  '[{"key":"l","label":"lock"},{"key":"e","label":"exit"},{"key":"u","label":"switch user"},{"key":"s","label":"suspend"},{"key":"h","label":"hibernate"},{"key":"r","label":"reboot"},{"key":"S-s","label":"shutdown"},{"key":"Esc","label":"cancel"}]'

scenario "hintsFor — unknown + empty modes fall back verbatim (AC4)"
assert_case "unknown-mode-fallback" '[{"key":"","label":"somefuture"}]'
assert_case "empty-mode-fallback"   '[{"key":"","label":""}]'

scenario "displayName — resize/screenshot else system (AC4)"
assert_case "display-names" '["resize","screenshot","system","system","system"]'

# ============================================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
