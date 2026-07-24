#!/usr/bin/env bash
# test-combo.sh — headless suite for the shared i3-dialog combobox control
# (sp017 / ft008). Sibling of test-clip-history.sh; same discipline —
# Xvfb display, isolated XDG_* dirs, named scenarios, a self-test that MUST
# fail. UI is observed indirectly (adr0002): logic is asserted through
# sh-visible effects (here, CASE lines the QML prints on stdout/stderr).
#
# PHASE 0 (this file, sp017 Task 1 / dotfiles-evnv.1): the Common/Fuzzy.qml
# scoring + highlight and the Common/DialogTheme.qml constants, extracted
# VERBATIM from config/Overlay.qml. A throwaway harness config is written to
# $TMP, imports the repo's Common/ dir (symlinked by absolute path), evaluates
# a pinned scenario table, prints `CASE <name> <payload>` lines, and exits;
# quickshell runs it under Xvfb and this script asserts each expected line.
#
# The pin is byte-identical: Fuzzy.match must reproduce Overlay.qml's
# fuzzyMatch score-for-score (word-boundary +10, consecutive +5, +1/char,
# empty pattern -> matched score 0, non-subsequence -> not matched), and
# Fuzzy.highlight must HTML-escape &/</> BEFORE wrapping matched chars, so a
# clipboard preview cannot inject markup into the RichText row. The
# `subsequence-not-substring` scenario is the negative control: pattern "skg"
# matches "ssh-keygen" as a subsequence, which a substring mutant fails.
#
# PHASE 1 (this file, sp017 Task 2 / dotfiles-evnv.2): the Combo control
# (Common/Combo.qml). A persistent quickshell host wraps a Combo in a Window
# with canned rows ({row:"00000N.clip", name:...}), an IpcHandler that switches
# the Combo into each named scenario, and confirm/confirmAlt/cancel handlers
# that append to argv logs via a `Process` `sh -c` echo. xdotool drives real
# keys against the mapped window. Named scenarios: not-a-position (the adr0010
# id-stability control — Enter on a NON-first filtered row must publish that
# row's FULL opaque id, so a mutant publishing the index / first row / a
# parseInt-truncated id FAILS), esc-no-write, empty-enter-noop,
# clamp-on-refilter, alt-confirm-gate, height-formula (window geometry per
# permutation), plus rapid-reopen. Coverage is behavioral — no scenario asserts
# mere property existence.
#
# usage: quickshell/test-combo.sh
# env:   XVFB= XDOTOOL= QUICKSHELL=   (default: from PATH; PHASE 0 needs no
#                                     XDOTOOL, PHASE 1 does)
#        TEST_DISPLAY=:95
#        SELFTEST=1                 flip one expectation wrong -> suite FAILS,
#                                   proving the harness can actually fail.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/config/Common"

XVFB="${XVFB:-Xvfb}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
DPY="${TEST_DISPLAY:-:95}"
SELFTEST="${SELFTEST:-0}"

TMP="/tmp/qs-combo-test.$$"
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
# CASE names are space-free; payloads may contain spaces (JSON has none, but
# highlight output carries `<font color=...` with a space).
case_of() { # <name>
  sed -n "s/^CASE $1 //p" "$CASES" | head -1
}

assert_case() { # <name> <expected>
  local got; got="$(case_of "$1")"
  if [ "$2" = "$got" ]; then pass "$1"; else fail "$1" "$2" "$got"; fi
}

assert_eq() { # <scenario> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
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
[ -r "$COMMON_DIR/Fuzzy.qml" ]       || { echo "FATAL: Fuzzy.qml missing" >&2; exit 1; }
[ -r "$COMMON_DIR/DialogTheme.qml" ] || { echo "FATAL: DialogTheme.qml missing" >&2; exit 1; }

mkdir -p "$TMP" "$CFG" "$RUN" "$CCH"
chmod 700 "$RUN"

# --- throwaway harness config in $TMP importing the repo's Common/ ----------
# Common is symlinked by ABSOLUTE path so the harness imports the exact dir
# under test (this worktree's), and `import "./Common"` matches the ft008
# consumer usage documented in the feature card.
ln -s "$COMMON_DIR" "$CFG/Common"

cat > "$CFG/shell.qml" <<'QMLEOF'
import Quickshell
import QtQuick
import "./Common"

ShellRoot {
  function emit(name, payload) { console.log("CASE " + name + " " + payload) }
  function j(v) { return JSON.stringify(v) }

  Component.onCompleted: {
    // ---- Fuzzy.match: pinned scoring table (byte-identical to Overlay) ----
    // word-boundary +10 after '-': l at index 4 of "git-log"
    emit("score-word-boundary", j(Fuzzy.match("git-log", "l")))
    // consecutive +5 x2 over "abc"
    emit("score-consecutive", j(Fuzzy.match("abc", "abc")))
    // subsequence, not substring — negative control against a substring mutant
    emit("subsequence-not-substring", j(Fuzzy.match("ssh-keygen", "skg")))
    // empty pattern -> matched, score 0, no indices (both empty and non-empty text)
    emit("empty-pattern-matches-all", j(Fuzzy.match("anything", "")))
    emit("empty-pattern-empty-text", j(Fuzzy.match("", "")))
    // empty text + non-empty pattern -> not matched
    emit("empty-text-not-matched", j(Fuzzy.match("", "x")))
    // pattern longer than text -> not matched (partial score, matched:false)
    emit("pattern-longer-not-matched", j(Fuzzy.match("ab", "abc")))
    // case folding both directions; indices refer to original text
    emit("case-fold-upper-text", j(Fuzzy.match("ABC", "abc")))
    emit("case-fold-upper-pattern", j(Fuzzy.match("abc", "ABC")))

    // ---- Fuzzy.highlight: HTML-escape BEFORE wrapping ----
    // no indices -> escaped literal round-trip (the injection round-trip pin)
    emit("escape-richtext", j(Fuzzy.highlight("<b>x</b>", [])))
    // a matched char surrounded by markup: markup escaped, match char wrapped
    emit("escape-richtext-wrap", j(Fuzzy.highlight("<b>x</b>", [3])))
    // null indices -> escaped text, unchanged otherwise
    emit("escape-null-indices", j(Fuzzy.highlight("a&b", null)))
    emit("escape-empty-indices", j(Fuzzy.highlight("a&b", [])))

    // ---- Unicode: surrogate-pair indices land on the same code units ----
    // "a🎉b": 🎉 is 2 UTF-16 code units (1,2); 'a'=0, 'b'=3
    emit("unicode-indices", j(Fuzzy.match("a🎉b", "ab")))
    // highlight must wrap 0 and 3 without splitting the surrogate at 1,2
    emit("unicode-highlight", j(Fuzzy.highlight("a🎉b", [0, 3])))

    // ---- DialogTheme: AC1 parity constants dumped one per line ----
    emit("theme-width",          "" + DialogTheme.width)
    emit("theme-inputHeight",    "" + DialogTheme.inputHeight)
    emit("theme-inputBg",        DialogTheme.inputBg)
    emit("theme-rowHeight",      "" + DialogTheme.rowHeight)
    emit("theme-maxRows",        "" + DialogTheme.maxRows)
    emit("theme-bodyBg",         DialogTheme.bodyBg)
    emit("theme-fg",             DialogTheme.fg)
    emit("theme-font",           DialogTheme.font)
    emit("theme-accent",         DialogTheme.accent)
    emit("theme-muted",          DialogTheme.muted)
    emit("theme-urgent",         DialogTheme.urgent)
    emit("theme-pad",            "" + DialogTheme.pad)
    emit("theme-textLeftMargin", "" + DialogTheme.textLeftMargin)
    emit("theme-fontSize",       "" + DialogTheme.fontSize)

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

# SWAYSOCK unset so DialogTheme.fontSize is deterministically the i3 value (16).
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
# PHASE 0 — Fuzzy.match scoring, Fuzzy.highlight escaping, DialogTheme AC1
# ============================================================================

scenario "Fuzzy.match — pinned scoring table (byte-identical to Overlay.qml)"
assert_case "score-word-boundary"        '{"matched":true,"score":11,"indices":[4]}'
assert_case "score-consecutive"          '{"matched":true,"score":23,"indices":[0,1,2]}'
assert_case "subsequence-not-substring"  '{"matched":true,"score":23,"indices":[0,4,7]}'
assert_case "empty-pattern-matches-all"  '{"matched":true,"score":0,"indices":[]}'
assert_case "empty-pattern-empty-text"   '{"matched":true,"score":0,"indices":[]}'

scenario "Fuzzy.match — edge cases"
assert_case "empty-text-not-matched"     '{"matched":false,"score":0,"indices":[]}'
assert_case "pattern-longer-not-matched" '{"matched":false,"score":17,"indices":[0,1]}'
assert_case "case-fold-upper-text"       '{"matched":true,"score":23,"indices":[0,1,2]}'
assert_case "case-fold-upper-pattern"    '{"matched":true,"score":23,"indices":[0,1,2]}'

scenario "Fuzzy.highlight — HTML-escape before wrapping (RichText injection guard)"
assert_case "escape-richtext"      '"&lt;b&gt;x&lt;/b&gt;"'
assert_case "escape-richtext-wrap" '"&lt;b&gt;<font color='"'"'#16a085'"'"'><b>x</b></font>&lt;/b&gt;"'
assert_case "escape-null-indices"  '"a&amp;b"'
assert_case "escape-empty-indices" '"a&amp;b"'

scenario "Fuzzy — unicode surrogate indices (no split surrogate in output)"
assert_case "unicode-indices"   '{"matched":true,"score":12,"indices":[0,3]}'
assert_case "unicode-highlight" '"<font color='"'"'#16a085'"'"'><b>a</b></font>🎉<font color='"'"'#16a085'"'"'><b>b</b></font>"'

scenario "DialogTheme — AC1 parity constants (sp017 / us015 AC1)"
EXP_WIDTH=480
[ "$SELFTEST" = "1" ] && EXP_WIDTH=999   # self-test: deliberately wrong -> FAIL
assert_case "theme-width"          "$EXP_WIDTH"
assert_case "theme-inputHeight"    "32"
assert_case "theme-inputBg"        "#152024"
assert_case "theme-rowHeight"      "32"
assert_case "theme-maxRows"        "8"
assert_case "theme-bodyBg"         "#222D31"
assert_case "theme-fg"             "#FDF6E3"
assert_case "theme-font"           "Iosevka Nerd Font"
assert_case "theme-accent"         "#16a085"
assert_case "theme-muted"          "#707880"
assert_case "theme-urgent"         "#CB4B16"
assert_case "theme-pad"            "8"
assert_case "theme-textLeftMargin" "12"
assert_case "theme-fontSize"       "16"

# ============================================================================
# PHASE 1 — the Combo control (Common/Combo.qml): keyboard contract, adr0010
#           id-stability, altConfirm gate, empty-noop, refilter clamp, and the
#           implicitHeight formula across the four consumer permutations.
# ============================================================================

XDOTOOL="${XDOTOOL:-xdotool}"
command -v "$XDOTOOL" >/dev/null 2>&1 \
  || { echo "FATAL: $XDOTOOL not found (XDOTOOL= to override; PHASE 1 needs it)" >&2; exit 1; }
[ -r "$COMMON_DIR/Combo.qml" ] || { echo "FATAL: Combo.qml missing" >&2; exit 1; }

CFG1="$TMP/cfg1"                 # PHASE 1 host config (separate from PHASE 0)
LOG1="$TMP/combo.log"            # confirm/confirmAlt argv log (the "argv log")
CLOG="$TMP/cancel.log"           # cancel marker — kept OUT of the argv log, so
                                 # esc-no-write can assert the argv log EMPTY
                                 # while still proving cancel actually fired.
mkdir -p "$CFG1"
ln -s "$COMMON_DIR" "$CFG1/Common"
: > "$LOG1"; : > "$CLOG"

# --- the persistent host: a Window wrapping Combo, driven by IPC ------------
# scenario(name) reconfigures the Combo for a named case and shows the window;
# hide() unmaps it. confirm/confirmAlt write "<verb> <row.row>" to $COMBO_LOG
# (row.row is the caller's OWN opaque id field — Combo hands back the row
# OBJECT, this host picks the field, per adr0010); cancel writes to a separate
# $COMBO_CANCEL_LOG. Row ids are opaque strings ("00000N.clip"); the confirmed
# id being that exact string is the whole point of not-a-position.
cat > "$CFG1/shell.qml" <<'HOSTEOF'
import Quickshell
import Quickshell.Io
import QtQuick
import "./Common"

ShellRoot {
  id: host
  property string logPath: Quickshell.env("COMBO_LOG")
  property string cancelPath: Quickshell.env("COMBO_CANCEL_LOG")
  property bool winVisible: false

  // scenario-controlled knobs the Combo binds to
  property var comboModel: []
  property bool comboInput: true
  property int comboMax: DialogTheme.maxRows
  property int comboMin: 0
  property bool comboAlt: false
  property string comboFilterMode: "fuzzy"

  // Fixture A — every name is "<prefix>-item" where the prefix contains NONE of
  // the pattern letters i/t/e/m, so a "item" filter matches all four with an
  // IDENTICAL score (greedy matching only ever hits the shared "-item" suffix).
  // The score tie breaks on name.localeCompare, giving a DETERMINISTIC filtered
  // order that does NOT depend on fuzzy-score subtleties:
  //   aqua(000020), buzz(000030), cozy(000050), onyx(000010)
  // Model insertion order (below) is onyx, cozy, aqua, buzz, so filtering
  // genuinely REORDERS. The THIRD filtered row is cozy = 000050.clip — distinct
  // from the numeric index (2), the first filtered row (000020), the first
  // (000010) and last (000030) MODEL rows, and parseInt("000050.clip")===50.
  function rowsReorder() {
    return [
      {row:"000010.clip", name:"onyx-item"},
      {row:"000050.clip", name:"cozy-item"},
      {row:"000020.clip", name:"aqua-item"},
      {row:"000030.clip", name:"buzz-item"}
    ]
  }
  // Fixture B — a "ap" filter narrows to exactly {apple, apricot}; used to test
  // the refilter clamp (index parked past the end snaps to the last real row).
  function rowsFruit() {
    return [
      {row:"000010.clip", name:"apple"},
      {row:"000020.clip", name:"apricot"},
      {row:"000030.clip", name:"banana"},
      {row:"000040.clip", name:"cherry"}
    ]
  }
  function rowsN(n) {
    var a = []
    for (var i = 1; i <= n; i++) a.push({row:("row"+i), name:("r"+i)})
    return a
  }

  Process { id: lp }
  function logLine(s) {
    lp.command = ["sh","-c",'printf "%s\n" "$1" >> "$2"',"sh", s, host.logPath]
    lp.running = true
  }
  Process { id: cp }
  function cancelLine(s) {
    cp.command = ["sh","-c",'printf "%s\n" "$1" >> "$2"',"sh", s, host.cancelPath]
    cp.running = true
  }

  IpcHandler {
    target: "combo"
    function scenario(name: string): void {
      host.winVisible = false
      // reset to the minimal-instantiation defaults each time
      host.comboInput = true
      host.comboMax = DialogTheme.maxRows
      host.comboMin = 0
      host.comboAlt = false
      host.comboFilterMode = "fuzzy"

      if (name === "not-a-position" || name === "esc-no-write"
          || name === "reopen") {
        host.comboModel = host.rowsReorder()
      } else if (name === "filter-nothing") {
        host.comboModel = host.rowsReorder()
      } else if (name === "empty-enter-noop") {
        host.comboModel = []
      } else if (name === "clamp-on-refilter") {
        host.comboModel = host.rowsFruit()
      } else if (name === "alt-gate-on") {
        host.comboModel = host.rowsFruit(); host.comboAlt = true
      } else if (name === "alt-gate-off") {
        host.comboModel = host.rowsFruit(); host.comboAlt = false
      } else if (name === "height-launcher") {         // input + cap 8, n=10
        host.comboModel = host.rowsN(10)
        host.comboInput = true; host.comboMax = 8; host.comboMin = 0
      } else if (name === "height-switcher") {         // no input, floor 1, unbounded, n=4
        host.comboModel = host.rowsN(4)
        host.comboInput = false; host.comboMax = -1; host.comboMin = 1
      } else if (name === "height-clip") {             // input + floor 1, EMPTY list
        host.comboModel = []
        host.comboInput = true; host.comboMax = 8; host.comboMin = 1
      } else if (name === "height-unbounded") {        // input + unbounded, n=10
        host.comboModel = host.rowsN(10)
        host.comboInput = true; host.comboMax = -1; host.comboMin = 0
      } else {
        host.comboModel = []
      }
      host.winVisible = true
      Qt.callLater(function(){ combo.forceFocus() })
    }
    function hide(): void { host.winVisible = false }
  }

  Window {
    id: win
    visible: host.winVisible
    width: combo.implicitWidth
    height: combo.implicitHeight
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    color: DialogTheme.bodyBg
    title: "qs-combo"

    Combo {
      id: combo
      anchors.fill: parent
      model: host.comboModel
      filterMode: host.comboFilterMode
      inputVisible: host.comboInput
      maxVisibleRows: host.comboMax
      minVisibleRows: host.comboMin
      altConfirmEnabled: host.comboAlt
      placeholder: "type"
      emptyText: "no matches"
      delegate: Component {
        Rectangle {
          anchors.fill: parent
          color: isSelected ? DialogTheme.inputBg : "transparent"
          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: DialogTheme.textLeftMargin
            text: Fuzzy.highlight(row.name, matchIndices)
            textFormat: Text.RichText
            color: DialogTheme.fg
            font.family: DialogTheme.font
            font.pixelSize: DialogTheme.fontSize
            renderType: Text.NativeRendering
          }
        }
      }
      onConfirm: (row) => host.logLine("confirm " + row.row)
      onConfirmAlt: (row) => host.logLine("alt " + row.row)
      onCancel: () => host.cancelLine("cancel")
    }
  }
}
HOSTEOF

# --- launch the persistent host on the PHASE-0 Xvfb (:95 still up) -----------
env -u SWAYSOCK DISPLAY="$DPY" \
    XDG_CONFIG_HOME="$CFG1" XDG_RUNTIME_DIR="$RUN" XDG_CACHE_HOME="$CCH" \
    COMBO_LOG="$LOG1" COMBO_CANCEL_LOG="$CLOG" \
    "$QUICKSHELL" -p "$CFG1" >"$TMP/qs1.out" 2>&1 &
QS_PID=$!

ipc() { env XDG_CONFIG_HOME="$CFG1" XDG_RUNTIME_DIR="$RUN" XDG_CACHE_HOME="$CCH" \
            "$QUICKSHELL" ipc --pid "$QS_PID" "$@" 2>/dev/null; }

for i in $(seq 1 40); do
  n="$(ipc show | grep -c 'combo')"
  [ "${n:-0}" -gt 0 ] && { COMBO_UP=1; break; }
  sleep 0.5
done
[ -n "${COMBO_UP:-}" ] || {
  echo "FATAL: combo host did not expose the 'combo' IPC target" >&2
  tail -30 "$TMP/qs1.out" >&2; exit 1; }

scen()     { ipc call combo scenario "$1"; }
hidewin()  { ipc call combo hide >/dev/null 2>&1; }
clearlog() { : > "$LOG1"; }
clearclog(){ : > "$CLOG"; }
logtxt()   { tr '\n' ';' < "$LOG1" | sed 's/;*$//'; }
clogltxt() { tr '\n' ';' < "$CLOG" | sed 's/;*$//'; }

win_on() {
  local i id
  for i in $(seq 1 40); do
    id="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-combo$' 2>/dev/null | head -1)"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    sleep 0.25
  done
  return 1
}
gone_on() {
  local i id
  for i in $(seq 1 40); do
    id="$(env DISPLAY="$DPY" "$XDOTOOL" search --onlyvisible --name '^qs-combo$' 2>/dev/null | head -1)"
    [ -z "$id" ] && return 0
    sleep 0.25
  done
  return 1
}
focuswin() { env DISPLAY="$DPY" "$XDOTOOL" windowfocus "$1" 2>/dev/null; sleep 0.3; }
key()      { env DISPLAY="$DPY" "$XDOTOOL" key --clearmodifiers "$@" 2>/dev/null; sleep 0.2; }
keyraw()   { env DISPLAY="$DPY" "$XDOTOOL" key "$@" 2>/dev/null; sleep 0.2; }
typ()      { env DISPLAY="$DPY" "$XDOTOOL" type --clearmodifiers "$1" 2>/dev/null; sleep 0.3; }

# open a named scenario, wait for the window, take X focus; sets $WID
open_scen() {
  hidewin; gone_on
  scen "$1"
  WID="$(win_on)" || { fail "$1 (window map)" "a qs-combo window" "none"; return 1; }
  focuswin "$WID"
  return 0
}

geom_hw() { # <wid> -> "HEIGHT WIDTH"
  local H="" W=""
  eval "$(env DISPLAY="$DPY" "$XDOTOOL" getwindowgeometry --shell "$1" 2>/dev/null)"
  printf '%s %s' "${HEIGHT:-?}" "${WIDTH:-?}"
}

# ---- not-a-position: the adr0010 id-stability control -----------------------
# Filtered order under "item": aqua(000020), buzz(000030), cozy(000050),
# onyx(000010). Down x2 from the top lands on the THIRD filtered row. Enter must
# publish its FULL id 000050.clip — a mutant publishing the index ("2"), the
# first filtered row ("000020.clip"), a model position, or a parseInt-truncated
# id ("50") all fail this exact-string assertion.
scenario "not-a-position: Enter on a NON-first filtered row publishes that row's FULL opaque id"
clearlog; clearclog
if open_scen not-a-position; then
  typ "item"
  key Down; key Down
  key Return
  sleep 0.3
  assert_eq "confirm carries the third FILTERED row's full id -- not index 2, not first-row 000020.clip, not parseInt 50" \
    "confirm 000050.clip" "$(logtxt)"
  assert_eq "confirm fired exactly once (one line in the argv log)" \
    "1" "$(grep -c . "$LOG1" | tr -d ' ')"
fi

# ---- Ctrl+N / Ctrl+P move (clamped) the same as Down/Up ---------------------
scenario "ctrl-n-p-move: Ctrl+N/Ctrl+P step selection, clamped, and confirm the reached row"
clearlog; clearclog
if open_scen not-a-position; then
  typ "item"
  keyraw ctrl+n; keyraw ctrl+n      # 0 -> 2 (cozy/000050)
  keyraw ctrl+p                      # -> 1 (buzz/000030)
  key Return
  sleep 0.3
  assert_eq "Ctrl+N x2 then Ctrl+P lands on the second filtered row 000030.clip" \
    "confirm 000030.clip" "$(logtxt)"
fi

# ---- down-clamps-at-bottom --------------------------------------------------
scenario "down-clamps: Down past the last row stays on the last row (no wrap)"
clearlog; clearclog
if open_scen not-a-position; then
  typ "item"
  key Down; key Down; key Down; key Down; key Down; key Down   # 6x on a 4-row list
  key Return
  sleep 0.3
  assert_eq "Down clamps at the bottom -> onyx 000010.clip, never wraps to the top" \
    "confirm 000010.clip" "$(logtxt)"
fi

# ---- esc-no-write -----------------------------------------------------------
scenario "esc-no-write: Esc fires cancel and publishes NOTHING to the argv log"
clearlog; clearclog
if open_scen esc-no-write; then
  key Down                     # move selection so a stray confirm would be visible
  key Escape
  sleep 0.3
  assert_eq "the argv (confirm) log is empty after Esc" "" "$(logtxt)"
  assert_eq "cancel actually fired (separate marker), proving Esc was delivered" \
    "cancel" "$(clogltxt)"
fi

# ---- empty-enter-noop -------------------------------------------------------
scenario "empty-enter-noop: Enter over an empty filtered list fires no signal, spawns nothing"
clearlog; clearclog
if open_scen empty-enter-noop; then
  key Return
  sleep 0.3
  assert_eq "empty model + Enter -> argv log empty (no confirm, no process)" "" "$(logtxt)"
fi
# same, but via a filter that matches nothing over a NON-empty model
scenario "empty-enter-noop: a filter matching nothing + Enter is also a no-op"
clearlog; clearclog
if open_scen filter-nothing; then
  typ "qqqqq"                  # matches none of the -item rows
  key Return
  sleep 0.3
  assert_eq "filtered-to-nothing + Enter -> argv log still empty" "" "$(logtxt)"
fi

# ---- clamp-on-refilter ------------------------------------------------------
# Move selection to the last of 4 rows, then type a filter that shrinks the list
# to 2 rows. The index must CLAMP to the new last row (apricot/000020), and the
# next Enter must confirm that REAL row -- not an out-of-range no-op.
scenario "clamp-on-refilter: a shrinking refilter clamps index to the last row; Enter confirms a real row"
clearlog; clearclog
if open_scen clamp-on-refilter; then
  key Down; key Down; key Down     # index -> 3 (cherry), the last of 4
  typ "ap"                          # narrows to {apple, apricot}; 3 clamps to 1
  key Return
  sleep 0.3
  assert_eq "index clamped from 3 to the last surviving row -> apricot 000020.clip" \
    "confirm 000020.clip" "$(logtxt)"
fi

# ---- alt-confirm-gate -------------------------------------------------------
# Top row of the fruit fixture is apple/000010 (index 0, no navigation).
scenario "alt-confirm-gate: altConfirmEnabled true -> Shift+Enter fires confirmAlt, NOT confirm"
clearlog; clearclog
if open_scen alt-gate-on; then
  keyraw shift+Return
  sleep 0.3
  assert_eq "Shift+Enter routes to confirmAlt with the selected row id" \
    "alt 000010.clip" "$(logtxt)"
fi
scenario "alt-confirm-gate: altConfirmEnabled false -> Shift+Enter behaves as plain Enter (confirm)"
clearlog; clearclog
if open_scen alt-gate-off; then
  keyraw shift+Return
  sleep 0.3
  assert_eq "with the gate off, Shift+Enter is a plain confirm" \
    "confirm 000010.clip" "$(logtxt)"
fi

# ---- rapid-reopen: no stale filter or index ---------------------------------
# Dirty the control (filter down to one row, which also moves the effective
# selection), close, reopen, and Enter WITHOUT typing. A clean reopen confirms
# the top of the FULL model (aqua/000020). A stale filter ("onyx") would instead
# confirm onyx/000010; a stale index would confirm a non-top row.
scenario "rapid-reopen: a close+reopen clears stale filter text and index"
clearlog; clearclog
if open_scen reopen; then
  typ "onyx"                   # filters to just onyx/000010
  hidewin; gone_on
  clearlog
  scen reopen
  WID="$(win_on)" && focuswin "$WID"
  key Return                   # no typing this time
  sleep 0.3
  assert_eq "reopen shows the FULL model at the top (aqua 000020.clip), not the stale onyx or a stale index" \
    "confirm 000020.clip" "$(logtxt)"
fi

# ---- height-formula: implicitHeight across the four consumer permutations ---
# implicitHeight = (inputVisible?32:0) + max(min(n,cap),floor)*32 + 8, all from
# DialogTheme (input 32, row 32, pad 8). Read back as the mapped window height.
scenario "height-formula: implicitHeight matches the plan formula for the four consumer permutations"
if open_scen height-launcher; then     # input + cap 8, n=10 -> 32 + 8*32 + 8 = 296
  assert_eq "launcher (input, cap 8, n=10): capped at 8 rows -> 296x480" \
    "296 480" "$(geom_hw "$WID")"
fi
if open_scen height-switcher; then     # no input, floor 1, unbounded, n=4 -> 0 + 4*32 + 8 = 136
  assert_eq "switcher plain (no input, unbounded, floor 1, n=4): 136x480" \
    "136 480" "$(geom_hw "$WID")"
fi
if open_scen height-clip; then         # input + floor 1, EMPTY -> 32 + 1*32 + 8 = 72
  assert_eq "clip floor-1 (input, floor 1, empty list): floor keeps one row -> 72x480" \
    "72 480" "$(geom_hw "$WID")"
fi
if open_scen height-unbounded; then    # input + unbounded, n=10 -> 32 + 10*32 + 8 = 360
  assert_eq "unbounded (input, maxVisibleRows -1, n=10): no cap -> 360x480" \
    "360 480" "$(geom_hw "$WID")"
fi

hidewin; gone_on

# ============================================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
