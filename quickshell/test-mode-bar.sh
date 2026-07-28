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
# The pin matches the ft009 {text,key} registry: resize 6 rows, screenshot 4
# rows, system 8 rows, unknown -> [{text:<raw>,key:""}]. `key` is the trigger
# and the highlighted part of the word; ModeBar renders it inline when it is a
# substring of `text`, else falls back to `key␣text`.
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
  # PHASE 2 bar host is setsid'd into its own process group so the blocking
  # i3-msg subscribe reader (and the ws-subscribe sleep) die with it.
  [ -n "${BAR_PID:-}" ]  && kill -- -"$BAR_PID" 2>/dev/null
  [ -n "${BAR_PID:-}" ]  && kill "$BAR_PID"  2>/dev/null
  [ -n "${FORK_PID:-}" ] && kill -- -"$FORK_PID" 2>/dev/null
  [ -n "${FORK_PID:-}" ] && kill "$FORK_PID" 2>/dev/null
  [ -n "${PUB_PID:-}" ]  && kill "$PUB_PID"  2>/dev/null
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

    // ---- nav / nav-move (dotfiles-5u6m): the move-modifier pair. The rows
    //      must DIFFER (move-← vs ←, moving vs ctrl-to-move) — a registry that
    //      aliases nav-move back to nav renders no signal at all, which is the
    //      whole point of the synthetic mode. ----
    emit("hints-nav",        j(ModeBarTheme.hints["nav"]))
    emit("hints-nav-move",   j(ModeBarTheme.hints["nav-move"]))
    emit("hints-nav-resize", j(ModeBarTheme.hints["nav-resize"]))
    emit("nav-resolves",   JSON.stringify([
      ModeBarTheme.resolve("nav"), ModeBarTheme.resolve("nav-move"),
      ModeBarTheme.resolve("nav-resize")
    ]))

    // ---- resolve: the full \$mode_system string routes to system via
    //      indexOf("(l)ock"), NOT equality (an equality mutant fails here) ----
    emit("system-long-name-resolves", j(ModeBarTheme.hintsFor(sys)))

    // ---- unknown mode -> fallback row [{key:"", label:<raw>}] ----
    emit("unknown-mode-fallback", j(ModeBarTheme.hintsFor("somefuture")))

    // ---- displayName ternary (resize/screenshot/nav pair else system) ----
    emit("display-names", JSON.stringify([
      ModeBarTheme.displayName("resize"),
      ModeBarTheme.displayName("screenshot"),
      ModeBarTheme.displayName(sys),
      ModeBarTheme.displayName("somefuture"),
      ModeBarTheme.displayName("")
    ]))
    emit("nav-display-names", JSON.stringify([
      ModeBarTheme.displayName("nav"),
      ModeBarTheme.displayName("nav-move"),
      ModeBarTheme.displayName("nav-resize")
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

scenario "ModeBarTheme.hints — new {text,key} registry shape (AC3/AC4)"
assert_case "hints-resize-verbatim" \
  '[{"text":"←","key":"h"},{"text":"↓","key":"j"},{"text":"↑","key":"k"},{"text":"→","key":"l"},{"text":"arrows","key":"←↓↑→"},{"text":"quit","key":"q"}]'
assert_case "hints-screenshot-verbatim" \
  '[{"text":"region","key":"drag/tap"},{"text":"window","key":"w"},{"text":"desktop","key":"d"},{"text":"quit","key":"q"}]'
assert_case "hints-system-verbatim" \
  '[{"text":"lock","key":"l"},{"text":"exit","key":"e"},{"text":"switch-user","key":"u"},{"text":"suspend","key":"s"},{"text":"hibernate","key":"h"},{"text":"reboot","key":"r"},{"text":"poweroff","key":"p"},{"text":"quit","key":"q"}]'

scenario "resolve — full \$mode_system string routes to system via indexOf (AC4)"
# An equality-match mutant returns the fallback row for the long name instead.
assert_case "system-long-name-resolves" \
  '[{"text":"lock","key":"l"},{"text":"exit","key":"e"},{"text":"switch-user","key":"u"},{"text":"suspend","key":"s"},{"text":"hibernate","key":"h"},{"text":"reboot","key":"r"},{"text":"poweroff","key":"p"},{"text":"quit","key":"q"}]'

scenario "hintsFor — unknown + empty modes fall back verbatim (AC4)"
assert_case "unknown-mode-fallback" '[{"text":"somefuture","key":""}]'
assert_case "empty-mode-fallback"   '[{"text":"","key":""}]'

scenario "displayName — resize/screenshot else system (AC4)"
assert_case "display-names" '["resize","screenshot","system","system","system"]'

scenario "nav pair (dotfiles-5u6m) — registry + resolve + pill labels differ by held Shift"
assert_case "hints-nav" \
  '[{"text":"←","key":"h"},{"text":"↓","key":"j"},{"text":"↑","key":"k"},{"text":"→","key":"l"},{"text":"ctrl-to-move","key":"^"},{"text":"quit","key":"q"}]'
assert_case "hints-nav-move" \
  '[{"text":"move-←","key":"h"},{"text":"move-↓","key":"j"},{"text":"move-↑","key":"k"},{"text":"move-→","key":"l"},{"text":"moving","key":"^"},{"text":"quit","key":"q"}]'
assert_case "hints-nav-resize" \
  '[{"text":"narrower","key":"h"},{"text":"taller","key":"j"},{"text":"shorter","key":"k"},{"text":"wider","key":"l"},{"text":"resizing","key":"⎇"},{"text":"quit","key":"q"}]'
# both must resolve to their OWN key — a nav-move falling through to "" would
# render the raw mode name and lose the strip entirely.
assert_case "nav-resolves" '["nav","nav-move","nav-resize"]'
# the pill is the held-Shift tell: the two labels MUST NOT be equal.
assert_case "nav-display-names" '["nav","nav MOVE","nav RESIZE"]'

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

    // Each hint renders 5 content spans: hpre + hk + hpost (inline layout) and
    // hspace + hl (fallback layout). Dumping all five per row pins the ft009
    // render intent — the key is the HIGHLIGHTED slice of the word when it is a
    // substring (inline), else the classic `key␣text` fallback.
    var data = []
    for (var i = 0; i < rows.length; i++) {
      var pre  = findChild(rows[i], "hpre")
      var k    = findChild(rows[i], "hk")
      var post = findChild(rows[i], "hpost")
      var sp   = findChild(rows[i], "hspace")
      var l    = findChild(rows[i], "hl")
      data.push({
        pre:   pre  ? pre.text  : null,
        key:   k    ? k.text    : null,
        post:  post ? post.text : null,
        space: sp   ? sp.text   : null,
        tail:  l    ? l.text    : null
      })
    }

    emit(name + ".visible", mb.visible ? "1" : "0")
    emit(name + ".pill",    pl ? pl.text : "?")
    emit(name + ".delta",   pill && pl ? (pill.width - pl.implicitWidth) : -1)
    emit(name + ".underlineH", ul ? ul.height : -1)
    emit(name + ".gapW",    gap ? gap.width : -1)
    emit(name + ".hints",   j(data))

    var hpre  = rows.length ? findChild(rows[0], "hpre")  : null
    var hk    = rows.length ? findChild(rows[0], "hk")    : null
    var hpost = rows.length ? findChild(rows[0], "hpost") : null
    var hl    = rows.length ? findChild(rows[0], "hl")    : null
    // pre/post carry fg (like the tail label); key carries highlight. A
    // hardcoded literal drifting from the theme flips one of these to false.
    emit(name + ".colors", j({
      pillBg:    sameColour(pill.color, ModeBarTheme.pillBg),
      underline: sameColour(ul.color,   ModeBarTheme.highlight),
      pillLabel: sameColour(pl.color,   ModeBarTheme.fg),
      pre:       hpre  ? sameColour(hpre.color,  ModeBarTheme.fg)        : true,
      key:       hk    ? sameColour(hk.color,    ModeBarTheme.highlight) : true,
      post:      hpost ? sameColour(hpost.color, ModeBarTheme.fg)        : true,
      label:     hl    ? sameColour(hl.color,    ModeBarTheme.fg)        : true
    }))
    emit(name + ".native", j({
      pill:  pl.renderType === Text.NativeRendering,
      pre:   hpre  ? hpre.renderType  === Text.NativeRendering : true,
      key:   hk    ? hk.renderType    === Text.NativeRendering : true,
      post:  hpost ? hpost.renderType === Text.NativeRendering : true,
      label: hl    ? hl.renderType    === Text.NativeRendering : true
    }))
    emit(name + ".bold",  j({ pill: pl.font.bold, key: hk ? hk.font.bold : true }))
    emit(name + ".font",  pl.font.family)
    emit(name + ".px",    pl.font.pixelSize)

    // Font invariant (parity guard): the coloured Texts carry ModeBarTheme.font
    // (Iosevka); the pure-whitespace Texts (separator + spacer) keep the DEFAULT
    // font, matching Bar.qml:599/601. A space's advance differs by font, so
    // re-adding ModeBarTheme.font to the whitespace Texts widens the strip
    // ~+61.5px in resize — flipping sep/space below to false and FAILING here,
    // catching the drift in the suite (not just review). Machine-independent:
    // it compares font *identity*, not pixel widths.
    var hl2 = hl  // (already the first row's label)
    var hsep  = rows.length ? findChild(rows[0], "hsep")  : null
    var hspc  = rows.length ? findChild(rows[0], "hspace") : null
    emit(name + ".fonts", j({
      pill:  pl.font.family === ModeBarTheme.font,
      pre:   hpre  ? hpre.font.family  === ModeBarTheme.font : true,
      key:   hk    ? hk.font.family    === ModeBarTheme.font : true,
      post:  hpost ? hpost.font.family === ModeBarTheme.font : true,
      label: hl2   ? hl2.font.family   === ModeBarTheme.font : true,
      sep:   hsep  ? hsep.font.family  !== ModeBarTheme.font : true,
      space: hspc  ? hspc.font.family  !== ModeBarTheme.font : true
    }))
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
flip1 "nav"        "nav"
flip1 "nav-move"   "nav-move"

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
# arrows/directions are fallback (key not a substring of text): pre/post empty,
# space=" ", tail=<glyph>. "quit"/"q" is inline: pre="", hk="q", post="uit".
assert_case "resize.hints" \
  '[{"pre":"","key":"h","post":"","space":" ","tail":"←"},{"pre":"","key":"j","post":"","space":" ","tail":"↓"},{"pre":"","key":"k","post":"","space":" ","tail":"↑"},{"pre":"","key":"l","post":"","space":" ","tail":"→"},{"pre":"","key":"←↓↑→","post":"","space":" ","tail":"arrows"},{"pre":"","key":"q","post":"uit","space":"","tail":""}]'

scenario "screenshot-hints: pill 'screenshot' + 4 verbatim hint rows (AC4)"
assert_case "screenshot.visible" "1"
assert_case "screenshot.pill"    "screenshot"
# "window"/"w" and "desktop"/"d" are both inline (key at index 0): hk="w"
# post="indow", hk="d" post="esktop". "drag/tap"/"region" is fallback (key
# not a substring of text).
assert_case "screenshot.hints" \
  '[{"pre":"","key":"drag/tap","post":"","space":" ","tail":"region"},{"pre":"","key":"w","post":"indow","space":"","tail":""},{"pre":"","key":"d","post":"esktop","space":"","tail":""},{"pre":"","key":"q","post":"uit","space":"","tail":""}]'

scenario "system-long-name: the full \$mode_system string -> pill reads 'system' (AC4)"
assert_case "system-long-name.visible" "1"
assert_case "system-long-name.pill"    "system"
# inline highlighting: lock->hk="l" post="ock"; switch-user->pre="switch-"
# hk="u" post="ser". poweroff/"p" is inline (p at index 0).
assert_case "system-long-name.hints" \
  '[{"pre":"","key":"l","post":"ock","space":"","tail":""},{"pre":"","key":"e","post":"xit","space":"","tail":""},{"pre":"switch-","key":"u","post":"ser","space":"","tail":""},{"pre":"","key":"s","post":"uspend","space":"","tail":""},{"pre":"","key":"h","post":"ibernate","space":"","tail":""},{"pre":"","key":"r","post":"eboot","space":"","tail":""},{"pre":"","key":"p","post":"oweroff","space":"","tail":""},{"pre":"","key":"q","post":"uit","space":"","tail":""}]'

scenario "nav-pair-render: 'nav' vs 'nav-move' render a DIFFERENT pill + strip (dotfiles-5u6m)"
assert_case "nav.visible"      "1"
assert_case "nav.pill"         "nav"
assert_case "nav-move.visible" "1"
assert_case "nav-move.pill"    "nav MOVE"
# every direction row is fallback here (the key never occurs in an arrow glyph
# or in "move-←"), so pre/post stay empty and the word lands in `tail`;
# "quit"/"q" is inline as everywhere else.
assert_case "nav.hints" \
  '[{"pre":"","key":"h","post":"","space":" ","tail":"←"},{"pre":"","key":"j","post":"","space":" ","tail":"↓"},{"pre":"","key":"k","post":"","space":" ","tail":"↑"},{"pre":"","key":"l","post":"","space":" ","tail":"→"},{"pre":"","key":"^","post":"","space":" ","tail":"ctrl-to-move"},{"pre":"","key":"q","post":"uit","space":"","tail":""}]'
assert_case "nav-move.hints" \
  '[{"pre":"","key":"h","post":"","space":" ","tail":"move-←"},{"pre":"","key":"j","post":"","space":" ","tail":"move-↓"},{"pre":"","key":"k","post":"","space":" ","tail":"move-↑"},{"pre":"","key":"l","post":"","space":" ","tail":"move-→"},{"pre":"","key":"^","post":"","space":" ","tail":"moving"},{"pre":"","key":"q","post":"uit","space":"","tail":""}]'

scenario "unknown-fallback: unknown mode -> pill 'system' + one raw-name hint row (AC4)"
assert_case "unknown-fallback.visible" "1"
assert_case "unknown-fallback.pill"    "system"
# empty key -> fallback path with an empty hk span; the raw name renders as the
# tail (space+tail layout, key span empty).
assert_case "unknown-fallback.hints"   '[{"pre":"","key":"","post":"","space":" ","tail":"somefuture"}]'

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
assert_case "resize.colors" '{"pillBg":true,"underline":true,"pillLabel":true,"pre":true,"key":true,"post":true,"label":true}'
assert_case "resize.native" '{"pill":true,"pre":true,"key":true,"post":true,"label":true}'
assert_case "resize.bold"   '{"pill":true,"key":true}'
assert_case "resize.font"   "Iosevka Nerd Font"
assert_case "resize.px"     "16"

scenario "font-invariant: coloured Texts use ModeBarTheme.font; whitespace Texts keep the default font (AC1 parity vs Bar.qml:599/601)"
# Re-adding ModeBarTheme.font to the separator/spacer flips sep/space to false
# and fails here — pinning the whitespace-font drift the reviewer measured.
assert_case "resize.fonts" '{"pill":true,"pre":true,"key":true,"post":true,"label":true,"sep":true,"space":true}'

scenario "fontsize-propagates: the fontSize prop reaches the pill label Text (AC1 edge)"
assert_case "fontsize-22.px"   "22"
assert_case "fontsize-22.pill" "resize"

scenario "mode-flip-no-stale: default->resize->default->screenshot leaves no stale rows (AC4)"
assert_case "mode-flip-no-stale.pill"  "screenshot"
assert_case "mode-flip-no-stale.hints" \
  '[{"pre":"","key":"drag/tap","post":"","space":" ","tail":"region"},{"pre":"","key":"w","post":"indow","space":"","tail":""},{"pre":"","key":"d","post":"esktop","space":"","tail":""},{"pre":"","key":"q","post":"uit","space":"","tail":""}]'

# ============================================================================
# PHASE 2 — Bar.qml migrated onto ModeBar (sp018 Task 3 / dotfiles-80px.3):
#           the REAL config/Bar.qml component, hosted in a minimal ShellRoot and
#           driven by a SANDBOXED-PATH i3-msg stub whose `-t subscribe ["mode"]`
#           streams events from a harness FIFO — exactly the mode IPC the shipped
#           bar consumes. Behaviour is inspected via an IpcHandler dump that
#           walks the bar's render tree by objectName (ModeBar's pill) and by
#           the seeded workspace-tab text, reading effective visibility.
#           Precedent: test-clip-history.sh PHASE 1.5 / test-overlay.sh
#           (sandboxed argv-recording stubs, real component in a ShellRoot).
#
#           A2 (AC3) grep contract is asserted HERE against the shipped Bar.qml,
#           so re-introducing modeHints()/the dead Mode-indicator block, or the
#           modeText/modeNameText ids, or a second ModeBar, fails the RUN — not
#           just review.
# ============================================================================

BAR_QML="$SCRIPT_DIR/config/Bar.qml"
[ -r "$BAR_QML" ] || { echo "FATAL: Bar.qml missing" >&2; exit 1; }

# direct (non-CASE) shell assert for the grep contract + a few booleans.
a2() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }

# ---- AC3 grep contract (negative control, asserted in-suite) ----------------
scenario "grep-contract: Bar.qml drops modeHints/(l)ock, the modeText/modeNameText ids, keeps exactly one ModeBar (AC3)"
a2 "no modeHints() call or (l)ock sniff remains in Bar.qml" \
  "0" "$(grep -cE 'modeHints|\(l\)ock' "$BAR_QML" | tr -d ' ')"
a2 "the dead-block id 'modeText' is gone" \
  "0" "$(grep -cE 'id:[[:space:]]*modeText\b' "$BAR_QML" | tr -d ' ')"
a2 "the overlay-Row id 'modeNameText' is gone" \
  "0" "$(grep -cE 'id:[[:space:]]*modeNameText\b' "$BAR_QML" | tr -d ' ')"
a2 "exactly one ModeBar instance is wired in" \
  "1" "$(grep -cE '^[[:space:]]*ModeBar[[:space:]]*\{' "$BAR_QML" | tr -d ' ')"

# ---- end-to-end: real Bar + stubbed i3-msg mode subscription (FIFO) ----------
CFG2="$TMP/cfg2"                 # PHASE 2 host config (real Bar in a ShellRoot)
PBIN2="$TMP/pbin2"               # sandboxed PATH: coreutils + the i3-msg stub
RUN2="$TMP/run2"                 # isolated runtime dir (own ipc socket)
FIFO="$TMP/mode.fifo"            # the ["mode"] subscription stream
ARGV2="$TMP/i3-argv.log"         # every non-subscribe/non-get_workspaces argv
mkdir -p "$CFG2" "$PBIN2" "$RUN2"
chmod 700 "$RUN2"
ln -s "$COMMON_DIR" "$CFG2/Common"
ln -s "$SCRIPT_DIR/config/Bar.qml" "$CFG2/Bar.qml"
mkfifo "$FIFO"

SLEEP_BIN="$(command -v sleep)"
# Every coreutil the Bar's Processes shell out to (stats/net/vol/bat probes
# harmlessly no-op under the sandbox) plus sh for the get_workspaces wrapper.
# python3 is in here because the Bar's layer feed is a python reader
# (hotkeyd/state-tail.py — quickshell cannot open a unix socket itself and this
# host has no socat). Without it the feed Process would fail to spawn and every
# layer assertion would read "default" for the wrong reason.
for t in sh cat sleep tr awk df grep sed cut head python3; do
  src="$(command -v "$t")" && ln -sf "$src" "$PBIN2/$t"
done

# One focused workspace tab named "wsprobe" — a text unique in the tree, so the
# dump can locate the workspace Repeater's tab and read its effective visibility
# (leftSide hides in a mode; the tab must go with it).
WS2_JSON='[{"name":"wsprobe","num":1,"focused":true,"visible":true,"urgent":false,"id":1}]'
cat > "$PBIN2/i3-msg" <<STUBEOF
#!/bin/sh
case "\$1" in
  -t)
    case "\$2" in
      get_workspaces) printf '%s' '$WS2_JSON'; exit 0 ;;
      subscribe)
        case "\$4" in
          *mode*)
            # Stream mode events from the FIFO, line by line, forever (the
            # harness holds a persistent RDWR writer so read never sees EOF).
            while IFS= read -r line; do printf '%s\n' "\$line"; done < "$FIFO"
            exit 0 ;;
          *) exec "$SLEEP_BIN" 300 ;;
        esac ;;
      *) exit 0 ;;
    esac ;;
esac
printf '%s\n' "\$*" >> "$ARGV2"
exit 0
STUBEOF
chmod +x "$PBIN2/i3-msg"
ln -sf "$PBIN2/i3-msg" "$PBIN2/swaymsg"   # sway path answers under either name
: > "$ARGV2"

# --- minimal ShellRoot hosting the REAL Bar, plus an inspection IpcHandler ----
cat > "$CFG2/shell.qml" <<'HOST2EOF'
import Quickshell
import Quickshell.Io
import QtQuick
import "./Common"

ShellRoot {
  id: host
  function emit(n, p) { console.log("CASE " + n + " " + p) }

  // Walk from a PanelWindow's contentItem (declared children land there).
  function rootOf(w) { return (w && w.contentItem) ? w.contentItem : w }
  function findByName(item, name) {
    if (!item) return null
    var kids = item.children
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i]
      if (c.objectName === name) return c
      var f = findByName(c, name)
      if (f) return f
    }
    return null
  }
  function findByText(item, t) {
    if (!item) return null
    var kids = item.children
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i]
      if (c.text !== undefined && c.text === t) return c
      var f = findByText(c, t)
      if (f) return f
    }
    return null
  }
  // Effective visibility: an item renders iff it and every ancestor are visible.
  function effVis(it) { var n = it; while (n) { if (n.visible === false) return false; n = n.parent } return true }

  function dump(name) {
    var r    = rootOf(bar)
    var pill = findByName(r, "pillLabel")   // ModeBar's name-pill label
    var ws   = findByText(r, "wsprobe")     // the workspace tab text
    emit(name + ".mode",  bar.currentMode)
    emit(name + ".strip", (pill && effVis(pill)) ? "1" : "0")
    emit(name + ".pill",  pill ? pill.text : "?")
    emit(name + ".ws",    (ws && effVis(ws)) ? "1" : "0")
  }

  IpcHandler {
    target: "barprobe"
    function dumpc(name: string): void { host.dump(name) }
    function bye(): void { Quickshell.exit(0) }
  }

  Bar {
    id: bar
    screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }
}
HOST2EOF

QS_BIN="$(command -v "$QUICKSHELL")"
# QS_LAYER_FEED / HOTKEYD_DIR point at THIS worktree. Bar.qml's default is
# $HOME/.dotfiles/hotkeyd/state-tail.py, which is whatever branch happens to be
# checked out there — on a fresh clone it does not exist at all, and every layer
# assertion below would read "default" because the reader failed to spawn, not
# because the bar was wrong.
HOTKEYD_DIR="$(cd -- "$SCRIPT_DIR/../hotkeyd" && pwd)"
STATE_TAIL="$HOTKEYD_DIR/state-tail.py"
[ -r "$STATE_TAIL" ] || { echo "FATAL: $STATE_TAIL missing" >&2; exit 1; }

# setsid: own process group so cleanup reaps the blocking FIFO reader. PATH is
# the sandbox ONLY (so wmMsg resolves to the stub); SWAYSOCK unset => i3 path.
setsid env -u SWAYSOCK DISPLAY="$DPY" PATH="$PBIN2" \
    XDG_CONFIG_HOME="$CFG2" XDG_RUNTIME_DIR="$RUN2" XDG_CACHE_HOME="$CCH" \
    QS_LAYER_FEED="$STATE_TAIL" \
    "$QS_BIN" -p "$CFG2" >"$TMP/qs2.out" 2>&1 &
BAR_PID=$!

ipc2() { env XDG_CONFIG_HOME="$CFG2" XDG_RUNTIME_DIR="$RUN2" XDG_CACHE_HOME="$CCH" \
             "$QUICKSHELL" ipc --pid "$BAR_PID" "$@" 2>/dev/null; }

for i in $(seq 1 60); do
  n="$(ipc2 show 2>/dev/null | grep -c 'barprobe')"
  [ "${n:-0}" -gt 0 ] && { BAR_UP=1; break; }
  sleep 0.5
done

if [ -z "${BAR_UP:-}" ]; then
  fail "PHASE 2 bar host exposed the 'barprobe' IPC target" \
       "a barprobe target" "none (host did not boot — see below)"
  tail -30 "$TMP/qs2.out" >&2
else
  # Persistent RDWR writer: opening the FIFO O_RDWR never blocks and holds a
  # writer open so the stub's `read` loop streams events without ever EOF-ing.
  exec 3<>"$FIFO"
  mode_emit() { printf '%s\n' "$1" >&3; }
  # emit a mode event, let the scene settle (Text metrics + Repeater rebuild),
  # then snapshot the tree.
  barflip() { mode_emit "$1"; sleep 0.6; ipc2 call barprobe dumpc "$2" >/dev/null 2>&1; sleep 0.25; }

  sleep 0.8   # let get_workspaces land + the workspace Repeater build the tab
  ipc2 call barprobe dumpc "boot" >/dev/null 2>&1; sleep 0.3

  barflip '{"change":"resize"}'  "resize-on"
  barflip '{"change":"default"}' "default-off"
  barflip "{\"change\":\"$SYS\"}" "system-on"
  # garbage: current mode is the long system string; a malformed event must be
  # swallowed by the existing try/catch, leaving currentMode UNCHANGED.
  barflip 'this is not json @@@' "garbage-ignored"
  mode_emit '{"change":"default"}'; sleep 0.3   # reset

  # --- nav mode + the Shift indicator (dotfiles-5u6m) ------------------------
  # Binding events ride the SAME ["mode","binding"] subscription as the mode
  # events above, so they are driven through the same FIFO — no second stream,
  # exactly as the real bar sees them. Payloads are the shape i3 emits (verified
  # against a live i3 in i3/test-nav-mode.sh).
  bind_emit() { # <mods-json> <symbol> <command>
    mode_emit "{\"change\":\"run\",\"binding\":{\"command\":\"$3\",\"mods\":$1,\"symbol\":\"$2\",\"input_type\":\"keyboard\"}}"
  }
  bindflip() { # <mods-json> <symbol> <command> <dump-name>
    bind_emit "$1" "$2" "$3"; sleep 0.5
    ipc2 call barprobe dumpc "$4" >/dev/null 2>&1; sleep 0.25
  }


  # --- hotkeyd layer feed fixture -------------------------------------------
  # The bar no longer infers the layer from binding events; it reads hotkeyd's
  # state socket (sp020 T7). This fixture publishes on that socket using the
  # REAL StatePublisher from hotkeyd/layers.py, so the harness cannot drift from
  # what the daemon actually writes — replay-on-connect included, which is what
  # lets the bar be started before or after the publisher.
  PUB_FIFO="$TMP/pub.fifo"
  mkfifo "$PUB_FIFO"
  # $1 command FIFO, $2 (optional) state to publish BEFORE anyone can connect —
  # that is what makes the replay-on-connect path reachable on a restart.
  #
  # `poll()` runs on a 50ms tick rather than only after a published line: the
  # publisher must ACCEPT a connecting bar promptly, otherwise the harness is
  # racing the bar's 1s reconnect timer and the first layer assertion flakes.
  # `CLIENTS <n>` is printed on every change so the harness can WAIT for the bar
  # to be attached instead of sleeping and hoping.
  #
  # `RAW:<text>` writes text to the connected clients verbatim, bypassing
  # json.dumps. Without it a "malformed line" scenario only proves the FIXTURE
  # rejects garbage — the bytes never reach the bar, and a bar that blanked its
  # state on a parse error would still pass.
  cat > "$TMP/statepub.py" <<'PUBEOF'
import json, os, select, sys
sys.path.insert(0, os.environ["HOTKEYD_DIR"])
import layers as L

pub = L.StatePublisher(L.socket_path(os.environ.get("DISPLAY")))
if len(sys.argv) > 2 and sys.argv[2]:
    pub.publish(json.loads(sys.argv[2]))

fd = os.open(sys.argv[1], os.O_RDWR)     # O_RDWR: never blocks, never sees EOF
buf = b""
seen = -1
while True:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        buf += os.read(fd, 4096)
    while b"\n" in buf:
        raw, buf = buf.split(b"\n", 1)
        line = raw.decode(errors="replace").strip()
        if line == "QUIT":
            pub.close()
            sys.exit(0)
        if line.startswith("RAW:"):
            wire = (line[4:] + "\n").encode()
            for c in list(pub._clients):
                try:
                    c.send(wire)
                except OSError:
                    pass
            continue
        if line:
            try:
                pub.publish(json.loads(line))
            except Exception as e:
                print("statepub: %s" % e, file=sys.stderr, flush=True)
    pub.poll()
    if pub.client_count != seen:
        seen = pub.client_count
        print("CLIENTS %d" % seen, flush=True)
PUBEOF

  start_pub() { # <logfile> [initial-state-json]
    DISPLAY="$DPY" XDG_RUNTIME_DIR="$RUN2" HOTKEYD_DIR="$HOTKEYD_DIR" \
      python3 "$TMP/statepub.py" "$PUB_FIFO" "${2:-}" >"$1" 2>&1 &
    PUB_PID=$!
  }
  # Wait until the publisher reports an attached client. Deterministic where a
  # fixed sleep was racing the bar's 1s layerFeedRetry (observed: 1 spurious
  # nav-on failure in 7 runs).
  wait_client() { # <logfile>
    local i
    for i in $(seq 1 60); do
      grep -q '^CLIENTS 1$' "$1" && return 0
      sleep 0.25
    done
    return 1
  }

  start_pub "$TMP/statepub.log"
  exec 9>"$PUB_FIFO"          # hold the write end so the reader never sees EOF
  wait_client "$TMP/statepub.log" \
    || fail "the bar attached to the layer socket" "CLIENTS 1" "$(tr '\n' ' ' < "$TMP/statepub.log")"

  # Publish one state line and give the bar time to render it.
  pub() { printf '%s\n' "$1" >&9; sleep 0.45; }
  # Publish, then snapshot the bar under a name.
  pubdump() { pub "$1"; ipc2 call barprobe dumpc "$2" >/dev/null 2>&1; sleep 0.2; }

  # Entering the layer: the daemon says so, no i3 mode involved.
  pubdump '{"layer":"nav","mod":null}' "nav-on"
  # A held modifier BEFORE any hjkl — the whole point of the indicator. i3 needed
  # six marker binds to fake this; the daemon just says which modifier is down.
  pubdump '{"layer":"nav","mod":"move"}' "nav-mod-move"
  pubdump '{"layer":"nav","mod":null}' "nav-mod-cleared"
  pubdump '{"layer":"nav","mod":"resize"}' "nav-mod-resize"
  # Switching straight between modifier layers must be immediate — no bar-side
  # debounce survives, because the daemon publishes on CHANGE only and already
  # absorbs a stray release (its 120ms guard, tested in hotkeyd/test_layers.py).
  pubdump '{"layer":"nav","mod":"move"}' "nav-mod-switch"
  # An unknown mod value must degrade to plain nav, not to a blank pill.
  pubdump '{"layer":"nav","mod":"wat"}' "nav-mod-unknown"
  # Leaving the layer.
  pubdump '{"layer":"default","mod":null}' "nav-off"
  # A malformed line must be ignored rather than blanking the bar. The garbage
  # goes on the wire RAW — routing it through pub.publish() would have it
  # rejected by json.loads inside the FIXTURE, so the bar would never see it and
  # a bar that reset its state on a parse error would still pass.
  pubdump '{"layer":"nav","mod":"move"}' "nav-before-garbage"
  pub 'RAW:not json at all @@@'
  ipc2 call barprobe dumpc "nav-after-garbage" >/dev/null 2>&1; sleep 0.2
  # ...and a well-formed line right after it must still land: the reader must
  # have skipped one line, not desynced its stream.
  pubdump '{"layer":"nav","mod":"resize"}' "nav-after-garbage-recovers"
  pub '{"layer":"default","mod":null}'


  # Leaving the layer while a modifier is still held, then re-entering: the bar
  # must open plain rather than inheriting MOVE. The daemon guarantees this (it
  # publishes default with mod=null on exit), and the bar must not add its own
  # memory on top.
  pubdump '{"layer":"nav","mod":"move"}' "nav-held-before-exit"
  pubdump '{"layer":"default","mod":null}' "nav-off-after-mod"
  pubdump '{"layer":"nav","mod":null}' "nav-reentry"

  # --- mid-stream disconnect + replay-on-connect -----------------------------
  # The daemon dying while the bar runs is the edge case that decides whether a
  # STALE layer stays painted. Enter a layer, SIGKILL the publisher (no
  # goodbye line — the socket just closes), and the bar must fall back to
  # default on its own. Then bring a publisher back that is ALREADY in a layer
  # and never publishes again: the only way the pill can repaint is the
  # replay-the-current-state-on-connect half of the contract.
  pubdump '{"layer":"nav","mod":"move"}' "disconnect-before"
  exec 9>&-
  kill -9 "$PUB_PID" 2>/dev/null; wait "$PUB_PID" 2>/dev/null
  sleep 2.5                      # > the bar's 1s retry: it reconnects, fails, resets
  ipc2 call barprobe dumpc "disconnect-after" >/dev/null 2>&1; sleep 0.2

  start_pub "$TMP/statepub2.log" '{"layer":"nav","mod":"resize"}'
  exec 9>"$PUB_FIFO"
  wait_client "$TMP/statepub2.log" \
    || fail "the bar re-attached after the daemon came back" "CLIENTS 1" \
            "$(tr '\n' ' ' < "$TMP/statepub2.log")"
  sleep 0.6
  ipc2 call barprobe dumpc "reconnect-replay" >/dev/null 2>&1; sleep 0.2

  pub '{"layer":"default","mod":null}'
  exec 9>&-
  printf 'QUIT\n' > "$PUB_FIFO" 2>/dev/null || true
  kill "$PUB_PID" 2>/dev/null

  grep -a 'CASE ' "$TMP/qs2.out" | sed 's/^.*CASE /CASE /' >> "$CASES"
  ipc2 call barprobe bye >/dev/null 2>&1

  scenario "boot: no mode event yet -> default, strip hidden, workspaces shown"
  assert_case "boot.mode"  "default"
  assert_case "boot.strip" "0"
  assert_case "boot.ws"    "1"

  scenario "mode-strip-appears-on-resize: {change:resize} maps the strip, pill reads 'resize' (AC1/AC4)"
  assert_case "resize-on.mode"  "resize"
  assert_case "resize-on.strip" "1"
  assert_case "resize-on.pill"  "resize"

  scenario "workspaces-hidden-in-mode: leftSide (its wsprobe tab) hides while the strip shows (visibility complement)"
  assert_case "resize-on.ws" "0"

  scenario "strip-clears-on-default: {change:default} clears the strip, workspaces return (AC4)"
  assert_case "default-off.mode"  "default"
  assert_case "default-off.strip" "0"
  assert_case "default-off.ws"    "1"

  scenario "system-long-name-pill: the full \$mode_system string -> strip shows, pill reads 'system' (AC4)"
  assert_case "system-on.strip" "1"
  assert_case "system-on.pill"  "system"
  assert_case "system-on.ws"    "0"

  scenario "garbage-event-ignored: a malformed mode event leaves currentMode unchanged (try/catch preserved)"
  # Still the system string from the prior event — NOT reset to default, NOT the
  # garbage payload; the strip and pill are unchanged too.
  assert_case "garbage-ignored.mode"  "$SYS"
  assert_case "garbage-ignored.strip" "1"
  assert_case "garbage-ignored.pill"  "system"

  scenario "nav-layer: the daemon's feed shows the strip, pill reads 'nav' before any modifier"
  assert_case "nav-on.mode"  "nav"
  assert_case "nav-on.strip" "1"
  assert_case "nav-on.pill"  "nav"
  assert_case "nav-on.ws"    "0"

  scenario "a held modifier lights MOVE before any hjkl, with no mode change"
  # i3 needed six bindcode `nop` marker binds to fake this, because it cannot
  # report a held modifier. The daemon states it and the bar renders the
  # statement — no string matching, no corroboration from bind mods, no timer.
  assert_case "nav-mod-move.pill"  "nav MOVE"
  assert_case "nav-mod-move.mode"  "nav"
  assert_case "nav-mod-move.strip" "1"

  scenario "releasing the modifier falls back to plain nav"
  assert_case "nav-mod-cleared.pill" "nav"
  assert_case "nav-mod-cleared.mode" "nav"

  scenario "the resize layer, and an immediate switch between modifier layers"
  assert_case "nav-mod-resize.pill" "nav RESIZE"
  # There is no bar-side debounce left at all: the daemon publishes on CHANGE
  # and already absorbs a stray release, so a switch must appear at once.
  assert_case "nav-mod-switch.pill" "nav MOVE"

  scenario "an unknown mod value degrades to plain nav rather than a blank pill"
  # MUTANT PIN: map the mod straight into the pill text and this reads "nav wat".
  assert_case "nav-mod-unknown.pill" "nav"
  assert_case "nav-mod-unknown.mode" "nav"

  scenario "leaving the layer hides the strip and gives the workspace tabs back"
  assert_case "nav-off.strip" "0"
  assert_case "nav-off.ws"    "1"

  scenario "a malformed feed line (raw, on the wire) is ignored rather than blanking the bar"
  # MUTANT PIN: make the reader's catch reset daemonLayer/daemonMod to default
  # and nav-after-garbage.pill reads "nav" (or the strip vanishes) instead.
  assert_case "nav-before-garbage.pill" "nav MOVE"
  assert_case "nav-after-garbage.pill"  "nav MOVE"
  assert_case "nav-after-garbage.mode"  "nav"
  # and the stream is not desynced by the skipped line
  assert_case "nav-after-garbage-recovers.pill" "nav RESIZE"

  scenario "re-entry never inherits the modifier held when the layer was left"
  assert_case "nav-held-before-exit.pill" "nav MOVE"
  assert_case "nav-off-after-mod.strip"   "0"
  assert_case "nav-reentry.pill"          "nav"

  scenario "the daemon dying mid-stream drops the layer instead of painting it stale"
  # MUTANT PIN: delete the daemonLayer/daemonMod resets in Bar.qml's
  # layerFeed.onExited and the bar keeps showing "nav MOVE" for a daemon that no
  # longer exists — the "no stale layer painted" edge case, unpinned until now.
  assert_case "disconnect-before.pill"  "nav MOVE"
  assert_case "disconnect-after.mode"   "default"
  assert_case "disconnect-after.strip"  "0"
  assert_case "disconnect-after.ws"     "1"

  scenario "a bar that reconnects to a daemon ALREADY in a layer paints it at once (replay-on-connect)"
  # The restarted publisher published its state before the bar could attach and
  # never publishes again, so this pill can only come from the replay.
  assert_case "reconnect-replay.mode"  "nav"
  assert_case "reconnect-replay.pill"  "nav RESIZE"
  assert_case "reconnect-replay.strip" "1"
fi

# ============================================================================
# PHASE 3 — the reader itself (hotkeyd/state-tail.py), the piece the bar spawns.
#           Driven directly against a real StatePublisher, with no quickshell in
#           the way, so the parts of the ft011 contract that are RACY through a
#           1s-retry bar become deterministic here: replay-on-connect is the
#           FIRST line the reader ever prints, a garbage line is passed through
#           without ending the stream, each DISPLAY resolves its own socket, and
#           an absent socket / absent parent directory exits non-zero instead of
#           retrying internally ([[adr0014]] — the retry belongs to the host).
# ============================================================================

RUN3="$TMP/run3"; mkdir -p "$RUN3"; chmod 700 "$RUN3"

cat > "$TMP/tailprobe.py" <<'TAILEOF'
import json, os, select, subprocess, sys, time

RUN, TAIL = sys.argv[1], sys.argv[2]
os.environ["XDG_RUNTIME_DIR"] = RUN
sys.path.insert(0, os.environ["HOTKEYD_DIR"])
import layers as L                                     # noqa: E402


def emit(name, payload):
    print("CASE %s %s" % (name, payload), flush=True)


def start_tail(display, runtime=RUN):
    env = dict(os.environ, XDG_RUNTIME_DIR=runtime, DISPLAY=display)
    return subprocess.Popen(
        [sys.executable, TAIL], env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def line_from(proc, pubs=(), timeout=8.0):
    """One line from the reader, pumping the publishers' accept loop meanwhile."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for p in pubs:
            p.poll()
        r, _, _ = select.select([proc.stdout], [], [], 0.05)
        if r:
            line = proc.stdout.readline()
            if not line:
                return "<EOF>"
            return line.strip()
    return "<TIMEOUT>"


def send_raw(pub, text):
    for c in list(pub._clients):
        c.send((text + "\n").encode())


# --- replay-on-connect: the publisher is ALREADY in a layer, and never
#     publishes again. Anything the reader prints can only be the replay.
a = L.StatePublisher(L.socket_path(":191"))
a.publish({"layer": "nav", "mod": "move"})
ta = start_tail(":191")
emit("tail-replay-first-line", line_from(ta, [a]))

# --- a garbage line reaches the reader and does NOT end the stream: the next
#     well-formed line still arrives. (The reader forwards bytes verbatim — it
#     is the BAR that must tolerate the garbage, asserted in PHASE 2.)
send_raw(a, "not json at all @@@")
emit("tail-raw-passthrough", line_from(ta, [a]))
a.publish({"layer": "nav", "mod": "resize"})
emit("tail-survives-garbage", line_from(ta, [a]))

# --- two displays, two sockets: each reader sees ONLY its own display's state.
b = L.StatePublisher(L.socket_path(":192"))
b.publish({"layer": "nav", "mod": "move"})
tb = start_tail(":192")
first_b = line_from(tb, [a, b])
emit("tail-two-displays", json.dumps({
    "sock191": L.socket_path(":191").name,
    "sock192": L.socket_path(":192").name,
    "b_first": first_b,
}))
# and a publish on :191 must not leak into :192's reader
a.publish({"layer": "default", "mod": None})
emit("tail-no-crosstalk", line_from(tb, [a, b], timeout=1.5))

for p in (ta, tb):
    p.kill()

# --- the daemon goes away mid-stream: the reader EXITS (it does not retry).
tc = start_tail(":191")
line_from(tc, [a])                    # drain the replay so we know it is attached
a.close()
try:
    emit("tail-exits-on-daemon-death", tc.wait(timeout=5))
except subprocess.TimeoutExpired:
    tc.kill()
    emit("tail-exits-on-daemon-death", "HUNG")

# --- socket absent, and socket's PARENT DIRECTORY absent: non-zero, promptly.
t0 = time.time()
td = start_tail(":193")
try:
    rc_absent = td.wait(timeout=5)
except subprocess.TimeoutExpired:
    td.kill(); rc_absent = "HUNG"
gone = os.path.join(RUN, "does-not-exist")
te = start_tail(":194", runtime=gone)
try:
    rc_nodir = te.wait(timeout=5)
except subprocess.TimeoutExpired:
    te.kill(); rc_nodir = "HUNG"
emit("tail-absent-socket", json.dumps({
    "rc_no_socket": rc_absent,
    "rc_no_parent_dir": rc_nodir,
    "prompt": (time.time() - t0) < 5,
}))

b.close()
emit("PHASE3-DONE", "1")
TAILEOF

env HOTKEYD_DIR="$HOTKEYD_DIR" python3 "$TMP/tailprobe.py" "$RUN3" "$STATE_TAIL" \
  >"$TMP/tail3.out" 2>"$TMP/tail3.err"
grep -a '^CASE ' "$TMP/tail3.out" >> "$CASES"

if ! grep -q '^CASE PHASE3-DONE 1$' "$CASES"; then
  fail "PHASE 3 reader probe ran to completion" "PHASE3-DONE" \
       "$(tail -5 "$TMP/tail3.err" | tr '\n' ' ')"
else
  scenario "replay-on-connect: a reader attaching to a daemon already in a layer gets that layer as its FIRST line (ft011)"
  # This is the deterministic half of "a bar started while the daemon is already
  # in a layer paints it at once" — nothing is published after the reader starts.
  assert_case "tail-replay-first-line" '{"layer":"nav","mod":"move"}'

  scenario "a malformed line is forwarded and does not end the stream"
  assert_case "tail-raw-passthrough"  "not json at all @@@"
  assert_case "tail-survives-garbage" '{"layer":"nav","mod":"resize"}'

  scenario "two displays: each reader resolves and reads its OWN socket, no crosstalk"
  assert_case "tail-two-displays" \
    '{"sock191": "hotkeyd-191.sock", "sock192": "hotkeyd-192.sock", "b_first": "{\"layer\":\"nav\",\"mod\":\"move\"}"}'
  # :191 moved to default while :192 stayed in nav — nothing arrives on :192.
  assert_case "tail-no-crosstalk" "<TIMEOUT>"

  scenario "adr0014: the reader exits when the daemon dies, rather than retrying inside itself"
  assert_case "tail-exits-on-daemon-death" "0"

  scenario "adr0014: an absent socket — and an absent parent directory — exit non-zero, promptly"
  # A reader that retried internally would hang here, and the bar's bounded
  # respawn (PHASE 4) would have nothing to bound.
  assert_case "tail-absent-socket" '{"rc_no_socket": 1, "rc_no_parent_dir": 1, "prompt": true}'
fi

# ============================================================================
# PHASE 4 — the fork guard ([[adr0014]], the d069180 shape). A bar whose layer
#           socket can never be opened must cost ONE reader per retry interval,
#           not a spin. Boot a real Bar with its socket's PARENT DIRECTORY
#           removed, count how many times it spawns the reader over 5s, and
#           require the count to be bounded — while the host is still alive, so
#           a crashed bar cannot pass this by spawning nothing.
# ============================================================================

CFG4="$TMP/cfg4"; PBIN4="$TMP/pbin4"; RUN4="$TMP/run4"
SPAWNS="$TMP/feed-spawns.log"
mkdir -p "$CFG4" "$PBIN4" "$RUN4"
chmod 700 "$RUN4"
ln -s "$COMMON_DIR" "$CFG4/Common"
ln -s "$SCRIPT_DIR/config/Bar.qml" "$CFG4/Bar.qml"
python3 - "$PBIN2/i3-msg" "$PBIN4/i3-msg" <<'CPEOF'
import shutil, sys
shutil.copyfile(sys.argv[1], sys.argv[2])
CPEOF
chmod +x "$PBIN4/i3-msg"
ln -sf "$PBIN4/i3-msg" "$PBIN4/swaymsg"
for t in sh cat sleep tr awk df grep sed cut head; do
  src="$(command -v "$t")" && ln -sf "$src" "$PBIN4/$t"
done

# The counting shim: every reader spawn appends one line, then runs the real
# thing. This is the bar's ONLY use of python3 under $PBIN4, so the line count
# IS the respawn count.
: > "$SPAWNS"
REAL_PY="$(command -v python3)"
cat > "$PBIN4/python3" <<SHIMEOF
#!/bin/sh
echo spawn >> "$SPAWNS"
exec "$REAL_PY" "\$@"
SHIMEOF
chmod +x "$PBIN4/python3"

cat > "$CFG4/shell.qml" <<'HOST4EOF'
import Quickshell
import QtQuick
import "./Common"

ShellRoot {
  Bar { screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null }
}
HOST4EOF

setsid env -u SWAYSOCK DISPLAY="$DPY" PATH="$PBIN4" \
    XDG_CONFIG_HOME="$CFG4" XDG_RUNTIME_DIR="$RUN4" XDG_CACHE_HOME="$CCH" \
    QS_LAYER_FEED="$STATE_TAIL" \
    "$QS_BIN" -p "$CFG4" >"$TMP/qs4.out" 2>&1 &
FORK_PID=$!

# Let it boot and start spawning readers against a socket that does not exist.
sleep 3
rm -rf "$RUN4"            # the socket's PARENT DIRECTORY is now gone
: > "$SPAWNS"             # count only the window with the directory removed
sleep 5
SPAWN_N="$(wc -l < "$SPAWNS" | tr -d ' ')"
ALIVE="$(kill -0 "$FORK_PID" 2>/dev/null && echo yes || echo no)"
kill -- -"$FORK_PID" 2>/dev/null; kill "$FORK_PID" 2>/dev/null

scenario "fork guard: a permanently-missing layer socket costs a bounded number of readers over 5s (adr0014 / d069180)"
# The retry Timer is 1000ms, so ~5 spawns are expected in a 5s window. The bound
# is deliberately loose (any timer in the same order of magnitude passes) and
# still catches the shape it exists for: respawning from onExited WITHOUT the
# timer produces spawns as fast as python3 can start and exit — hundreds.
a2 "the bar host survived losing the socket directory" "yes" "$ALIVE"
a2 "reader respawns over 5s are bounded (<= 20, observed $SPAWN_N)" \
   "yes" "$([ "${SPAWN_N:-0}" -le 20 ] && echo yes || echo no)"
# ...and it did keep retrying: a bar that gave up entirely would also be "bounded".
a2 "the bar kept retrying rather than giving up (>= 2, observed $SPAWN_N)" \
   "yes" "$([ "${SPAWN_N:-0}" -ge 2 ] && echo yes || echo no)"

# ============================================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
