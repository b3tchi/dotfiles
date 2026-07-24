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
# PHASE 1 (Combo control) is added by dotfiles-evnv.2; this file is created by
# Task 1 with PHASE 0 only.
#
# usage: quickshell/test-combo.sh
# env:   XVFB= QUICKSHELL=          (default: from PATH)
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
