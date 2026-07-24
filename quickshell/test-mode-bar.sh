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
# PHASE 1 (this file, sp018 Task 2 / dotfiles-80px.2): the ModeBar component
# (Common/ModeBar.qml). A persistent quickshell host (precedent: test-combo.sh
# PHASE 1) wraps a ModeBar in a bar-height window with an IpcHandler that sets
# `mode`/`fontSize` and a `dumpc` call that walks the render tree (by
# objectName) and prints CASE lines carrying the observed geometry deltas and
# per-element colour/renderType. Named scenarios: default-invisible,
# resize (pill + 6 hints), screenshot (4 hints), system-long-name (pill reads
# "system"), unknown-fallback (pill "system" + one raw-name row), fontsize-22
# (the prop propagates to every Text), mode-flip-no-stale (default->resize->
# default->screenshot rebuilds the Repeater with no leftover rows), plus
# geometry-deltas grouped over the resize dump. Colours are asserted by
# comparing the rendered value against ModeBarTheme.* — a hardcoded literal in
# ModeBar that drifts from the theme FAILS the colour assertions. The pill
# width delta (14), underline height (2) and pill/hints gap (4) are pinned so a
# padding/geometry-retune mutant fails.
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
  [ -n "${QS_PID:-}" ]   && kill "$QS_PID"   2>/dev/null
  sleep 0.3
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
# PHASE 1 — the ModeBar component (Common/ModeBar.qml): render structure,
#           parity geometry (pill width delta 14, underline 2, gap 4), colours
#           bound to ModeBarTheme, NativeRendering, and mode-flip freshness.
#           Precedent: test-combo.sh PHASE 1 (persistent Window + IpcHandler).
# ============================================================================

[ -r "$COMMON_DIR/ModeBar.qml" ] || { echo "FATAL: ModeBar.qml missing" >&2; exit 1; }

CFG1="$TMP/cfg1"                 # PHASE 1 host config (separate from PHASE 0)
mkdir -p "$CFG1"
ln -s "$COMMON_DIR" "$CFG1/Common"

# --- the persistent host: a bar-height window wrapping ModeBar, driven by IPC.
# ModeBar is instantiated with ONLY its two api_surface props (mode, fontSize)
# — matching the real Bar.qml consumer. `dumpc(name)` walks the render tree by
# objectName and console.logs `CASE <name>.<field> <value>` lines; the geometry
# deltas and colour/renderType booleans are the behavioural assertions.
cat > "$CFG1/shell.qml" <<'HOSTEOF'
import Quickshell
import Quickshell.Io
import QtQuick
import "./Common"

ShellRoot {
  id: host
  property string mode: "default"
  property int fontSize: 16

  function emit(n, p) { console.log("CASE " + n + " " + p) }
  function j(v) { return JSON.stringify(v) }
  // Normalise both sides through the SAME String() path so a rendered colour
  // compares equal to a ModeBarTheme.* string iff they are the same colour;
  // a hardcoded literal in ModeBar that drifts fails this.
  function sameColour(c, s) { return String(c) === String(Qt.color(s)) }

  // Recursive objectName lookup over the visual child tree.
  function findChild(item, name) {
    if (!item) return null
    var kids = item.children
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i]
      if (c.objectName === name) return c
      var f = findChild(c, name)
      if (f) return f
    }
    return null
  }
  // The hint Rows, in model order (strip children with objectName "hintRow").
  function hintRows(mb) {
    var strip = findChild(mb, "strip")
    var out = []
    if (!strip) return out
    var kids = strip.children
    for (var i = 0; i < kids.length; i++)
      if (kids[i].objectName === "hintRow") out.push(kids[i])
    return out
  }

  function dump(name) {
    var pill = findChild(mb, "pill")
    var pl   = findChild(mb, "pillLabel")
    var ul   = findChild(mb, "underline")
    var gap  = findChild(mb, "gap")
    var rows = hintRows(mb)

    var data = []
    for (var i = 0; i < rows.length; i++) {
      var k = findChild(rows[i], "hk"), l = findChild(rows[i], "hl")
      data.push({ key: k ? k.text : null, label: l ? l.text : null })
    }

    emit(name + ".visible", mb.visible ? "1" : "0")
    emit(name + ".pill",    pl ? pl.text : "?")
    emit(name + ".delta",   pill && pl ? (pill.width - pl.implicitWidth) : -1)
    emit(name + ".underlineH", ul ? ul.height : -1)
    emit(name + ".gapW",    gap ? gap.width : -1)
    emit(name + ".hints",   j(data))

    var hk = rows.length ? findChild(rows[0], "hk") : null
    var hl = rows.length ? findChild(rows[0], "hl") : null
    emit(name + ".colors", j({
      pillBg:    sameColour(pill.color, ModeBarTheme.pillBg),
      underline: sameColour(ul.color,   ModeBarTheme.highlight),
      pillLabel: sameColour(pl.color,   ModeBarTheme.fg),
      key:       hk ? sameColour(hk.color, ModeBarTheme.highlight) : true,
      label:     hl ? sameColour(hl.color, ModeBarTheme.fg)        : true
    }))
    emit(name + ".native", j({
      pill:  pl.renderType === Text.NativeRendering,
      key:   hk ? hk.renderType === Text.NativeRendering : true,
      label: hl ? hl.renderType === Text.NativeRendering : true
    }))
    emit(name + ".bold",  j({ pill: pl.font.bold, key: hk ? hk.font.bold : true }))
    emit(name + ".font",  pl.font.family)
    emit(name + ".px",    pl.font.pixelSize)
  }

  IpcHandler {
    target: "modebar"
    function setmode(m: string): void { host.mode = m }
    function setfont(n: int): void    { host.fontSize = n }
    function dumpc(name: string): void { host.dump(name) }
    function bye(): void { Quickshell.exit(0) }
  }

  Window {
    id: win
    visible: true
    width: 900
    height: 40
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    color: "#222D31"
    title: "qs-modebar"

    // Consumer parity: ONLY mode + fontSize set, anchored bottom-of-bar as the
    // real Bar.qml overlay Row is (left/top/bottom, leftMargin 8).
    ModeBar {
      id: mb
      anchors { left: parent.left; top: parent.top; bottom: parent.bottom; leftMargin: 8 }
      mode: host.mode
      fontSize: host.fontSize
    }
  }
}
HOSTEOF

# --- launch the persistent host on the PHASE-0 Xvfb (:98 still up) -----------
env -u SWAYSOCK DISPLAY="$DPY" \
    XDG_CONFIG_HOME="$CFG1" XDG_RUNTIME_DIR="$RUN" XDG_CACHE_HOME="$CCH" \
    "$QUICKSHELL" -p "$CFG1" >"$TMP/qs1.out" 2>&1 &
QS_PID=$!

ipc() { env XDG_CONFIG_HOME="$CFG1" XDG_RUNTIME_DIR="$RUN" XDG_CACHE_HOME="$CCH" \
            "$QUICKSHELL" ipc --pid "$QS_PID" "$@" 2>/dev/null; }

for i in $(seq 1 40); do
  n="$(ipc show 2>/dev/null | grep -c 'modebar')"
  [ "${n:-0}" -gt 0 ] && { MB_UP=1; break; }
  sleep 0.5
done
[ -n "${MB_UP:-}" ] || {
  echo "FATAL: modebar host did not expose the 'modebar' IPC target" >&2
  tail -30 "$TMP/qs1.out" >&2; exit 1; }

setmodei() { ipc call modebar setmode "$1" >/dev/null 2>&1; }
setfont()  { ipc call modebar setfont "$1" >/dev/null 2>&1; }
dumpc()    { ipc call modebar dumpc "$1"   >/dev/null 2>&1; }
# set a mode, let the scene lay out + compute Text metrics, then dump.
flip1()    { setmodei "$1"; sleep 0.5; dumpc "$2"; sleep 0.2; }

flip1 "default"    "default-invisible"
flip1 "resize"     "resize"
flip1 "screenshot" "screenshot"
flip1 "$SYS"       "system-long-name"
flip1 "somefuture" "unknown-fallback"

# fontSize propagation: the host passes a different size (phone/sway differ).
setfont 22; sleep 0.2; flip1 "resize" "fontsize-22"; setfont 16; sleep 0.2

# mode-flip-no-stale: default->resize->default->screenshot, then dump; the
# Repeater must hold screenshot's 4 rows with no leftover resize rows.
setmodei "default";    sleep 0.2
setmodei "resize";     sleep 0.2
setmodei "default";    sleep 0.2
setmodei "screenshot"; sleep 0.5
dumpc "mode-flip-no-stale"; sleep 0.3

# collect PHASE 1 CASE lines (append; PHASE 0 names never collide with these).
grep -a 'CASE ' "$TMP/qs1.out" | sed 's/^.*CASE /CASE /' >> "$CASES"
ipc call modebar bye >/dev/null 2>&1

# --- PHASE 1 assertions ------------------------------------------------------

scenario "default-invisible: mode 'default' -> not visible (ft009 AC4)"
assert_case "default-invisible.visible" "0"

scenario "resize-pill-and-hints: pill 'resize' + 6 verbatim hint rows (AC1/AC4)"
assert_case "resize.visible" "1"
assert_case "resize.pill"    "resize"
assert_case "resize.hints" \
  '[{"key":"j","label":"←"},{"key":"k","label":"↓"},{"key":"l","label":"↑"},{"key":";","label":"→"},{"key":"←↓↑→","label":"arrows"},{"key":"Esc","label":"exit"}]'

scenario "screenshot-hints: pill 'screenshot' + 4 verbatim hint rows (AC4)"
assert_case "screenshot.visible" "1"
assert_case "screenshot.pill"    "screenshot"
assert_case "screenshot.hints" \
  '[{"key":"drag","label":"select region"},{"key":"2-tap","label":"corners"},{"key":"w","label":"whole screen"},{"key":"Esc","label":"cancel"}]'

scenario "system-long-name: the full \$mode_system string -> pill reads 'system' (AC4)"
assert_case "system-long-name.visible" "1"
assert_case "system-long-name.pill"    "system"
assert_case "system-long-name.hints" \
  '[{"key":"l","label":"lock"},{"key":"e","label":"exit"},{"key":"u","label":"switch user"},{"key":"s","label":"suspend"},{"key":"h","label":"hibernate"},{"key":"r","label":"reboot"},{"key":"S-s","label":"shutdown"},{"key":"Esc","label":"cancel"}]'

scenario "unknown-fallback: unknown mode -> pill 'system' + one raw-name hint row (AC4)"
assert_case "unknown-fallback.visible" "1"
assert_case "unknown-fallback.pill"    "system"
assert_case "unknown-fallback.hints"   '[{"key":"","label":"somefuture"}]'

scenario "geometry-deltas: pill width = label + 14, underline 2px, gap 4px (AC1)"
EXP_DELTA=14
[ "$SELFTEST" = "1" ] && EXP_DELTA=99   # self-test: a padding-retune mutant fails
assert_case "resize.delta"      "$EXP_DELTA"
assert_case "resize.underlineH" "2"
assert_case "resize.gapW"       "4"
assert_case "screenshot.delta"  "14"

scenario "colours bound to ModeBarTheme + Text.NativeRendering + bold (AC1)"
# A hardcoded literal in ModeBar that drifts from the theme flips one of these
# to false and fails.
assert_case "resize.colors" '{"pillBg":true,"underline":true,"pillLabel":true,"key":true,"label":true}'
assert_case "resize.native" '{"pill":true,"key":true,"label":true}'
assert_case "resize.bold"   '{"pill":true,"key":true}'
assert_case "resize.font"   "Iosevka Nerd Font"
assert_case "resize.px"     "16"

scenario "fontsize-propagates: the fontSize prop reaches the pill label Text (AC1 edge)"
assert_case "fontsize-22.px"   "22"
assert_case "fontsize-22.pill" "resize"

scenario "mode-flip-no-stale: default->resize->default->screenshot leaves no stale rows (AC4)"
assert_case "mode-flip-no-stale.pill"  "screenshot"
assert_case "mode-flip-no-stale.hints" \
  '[{"key":"drag","label":"select region"},{"key":"2-tap","label":"corners"},{"key":"w","label":"whole screen"},{"key":"Esc","label":"cancel"}]'

# ============================================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
