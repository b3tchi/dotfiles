#!/usr/bin/env bash
# test-bar-symlink-safe.sh - kwi3/dot.yaml's step 3 (link the binary and
# session scripts; kwi3-8wb.2), with no network, no build and no real rotz.
#
#   kwi3/test-bar-symlink-safe.sh
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# kwi3-8wb.2, live: this dot used to `cp -a "$SRC/i3kwin/bar/." \
# "$HOME/.config/quickshell/kwi3/"`. On a box where ~/.config/quickshell is a
# symlink into this repo's own top-level quickshell config (it has its own
# shell.qml at quickshell/config/shell.qml), that copy followed the symlink
# and landed inside ~/.dotfiles itself as an untracked
# quickshell/config/kwi3/ - and it did not even fix the original bug: once a
# top-level shell.qml exists in a search path, quickshell 0.3.x's own `-c`
# resolution stops considering subdirectories entirely, so `qs -c kwi3`
# still failed. The fix removed the copy outright (the bar now runs from the
# clone directly, via kwi3-x11-session's own KWI3_BAR_PATH default - see
# that script and i3kwin/README.md in the kwi3 repo). This test is the
# regression guard: step 3, run for real against a symlinked
# ~/.config/quickshell, must write NOTHING under the symlink's target.
#
# ---------------------------------------------------------------------------
# WHY THIS EXTRACTS THE REAL SCRIPT RATHER THAN RESTATING IT
# ---------------------------------------------------------------------------
# Same technique as test-xrdp-install.sh: the text under test is read
# straight out of kwi3/dot.yaml with `yq`, between the "# 3. Link the
# binary" and "# 4. This BOX's own kwi3 xrdp listener" markers - the exact
# characters `rotz install kwi3` would run for this step. Steps 1 (clone)
# and 2 (build) are not under test here: they need network and a compiler,
# and step 3 only reads the variables ($SRC, $FINAL_BIN) they would have set,
# never their side effects, so this test sets those two itself.
#
# ---------------------------------------------------------------------------
# WHAT IS STUBBED, AND WHY
# ---------------------------------------------------------------------------
#   rotz   a pure recorder, exit 0. The real binary would try to read this
#          account's actual dotfiles link graph, which a throwaway $HOME has
#          none of; stubbing it is also what keeps this test from linking
#          anything into a real home even by accident.
#
# `ln`, `mkdir` are NOT stubbed: they are the ordinary, harmless filesystem
# operations step 3 actually performs, confined entirely to $FAKE_HOME
# (a mktemp -d), which is exactly what this test needs to be honest about.
#
# ---------------------------------------------------------------------------
# SAFETY
# ---------------------------------------------------------------------------
#   - never runs rotz for real, never touches the real $HOME or
#     ~/.dotfiles - every path is inside $STATE (a mktemp -d), removed on
#     exit;
#   - the symlink target it writes into for the test is ALSO inside $STATE,
#     never the real ~/.dotfiles/quickshell/config;
#   - asserts the extracted fragment's TEXT contains no "quickshell" at all,
#     as a second, independent guard on top of the filesystem check - a
#     fragment that stopped touching the symlink by accident (e.g. by
#     copying somewhere else inside ~/.config) would still fail this one.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOT_YAML="$REPO_ROOT/kwi3/dot.yaml"

command -v yq >/dev/null 2>&1 || { echo "test-bar-symlink-safe: needs yq" >&2; exit 2; }
[ -r "$DOT_YAML" ] || { echo "test-bar-symlink-safe: missing $DOT_YAML" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has()  { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (not in $(basename "$1"))"; fi; }
hasnt() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found '$2')"; else ok "$3"; fi; }

STATE="$(mktemp -d "${TMPDIR:-/tmp}/kwi3-bar-symlink-test.XXXXXX")"
trap 'rm -rf "$STATE"' EXIT

BIN="$STATE/bin"
FAKE_HOME="$STATE/home"
TRACE="$STATE/trace"
mkdir -p "$BIN" "$FAKE_HOME"
: > "$TRACE"

cat > "$BIN/rotz" <<'EOF'
#!/bin/sh
printf 'rotz %s\n' "$*" >> "$TRACE"
exit 0
EOF
chmod +x "$BIN/rotz"

# --------------------------------------------------- extract the real text
FRAGMENT="$STATE/step3.sh"
yq -r '.linux.installs.cmd' "$DOT_YAML" \
  | sed -n '/^# 3\. Link the binary/,/^# 4\. This BOX'"'"'s own kwi3 xrdp listener/p' \
  | sed '$d' \
  > "$FRAGMENT"
[ -s "$FRAGMENT" ] || { echo "test-bar-symlink-safe: extracted fragment is empty - have the marker comments moved?" >&2; exit 2; }

# ===========================================================================
echo "-- the extracted step-3 text itself"
# ===========================================================================
# A comment may still warn future editors not to write through the symlink
# (and does); what must be gone is any EXECUTABLE line naming it.
CODE_MENTIONS="$(grep -v '^[[:space:]]*#' "$FRAGMENT" | grep -c 'quickshell' || true)"
check "$CODE_MENTIONS" "0" \
      "no executable line in step 3 names quickshell - the bar copy is gone, not moved"
has "$FRAGMENT" 'ln -sf "$FINAL_BIN"' "it still links the binary"
has "$FRAGMENT" "rotz link kwi3 --force" "and still links this dot's own config via rotz"

# ===========================================================================
echo "-- run it for real, against a symlinked ~/.config/quickshell"
# ===========================================================================
# The trap: ~/.config/quickshell -> a directory that has its OWN top-level
# shell.qml (Jan's real quickshell config, on this box). Fingerprint that
# target directory before running step 3, run it, and fingerprint it again -
# any new file, any changed file, is the bug back.
QS_TARGET="$STATE/real-quickshell-config"
mkdir -p "$QS_TARGET"
echo "// Jan's own top-level quickshell config" > "$QS_TARGET/shell.qml"
mkdir -p "$FAKE_HOME/.config"
ln -s "$QS_TARGET" "$FAKE_HOME/.config/quickshell"

fingerprint() { find "$QS_TARGET" -printf '%P %s %T@\n' 2>/dev/null | sort; }
FP_BEFORE="$(fingerprint)"

SRC="$STATE/fake-clone"
mkdir -p "$SRC/i3kwin/bar" "$SRC/i3kwin/adapters/x11/build" "$SRC/i3kwin/session"
echo "// fake bar source" > "$SRC/i3kwin/bar/shell.qml"
echo '#!/bin/sh' > "$SRC/i3kwin/adapters/x11/build/i3kwin-x11"
chmod +x "$SRC/i3kwin/adapters/x11/build/i3kwin-x11"
: > "$SRC/i3kwin/session/kwi3-x11-session"
: > "$SRC/i3kwin/session/kwi3-session-env.sh"
FINAL_BIN="$SRC/i3kwin/adapters/x11/build/i3kwin-x11"

env -i \
    HOME="$FAKE_HOME" \
    PATH="$BIN:/usr/bin:/bin" \
    TRACE="$TRACE" \
    SRC="$SRC" \
    FINAL_BIN="$FINAL_BIN" \
    bash "$FRAGMENT" >"$STATE/run.out" 2>&1
rc=$?
check "$rc" "0" "step 3 exits 0 against a symlinked ~/.config/quickshell"

FP_AFTER="$(fingerprint)"
check "$FP_AFTER" "$FP_BEFORE" \
      "the symlink TARGET is byte-for-byte unchanged - nothing was written through it"

if [ -e "$FAKE_HOME/.config/quickshell/kwi3" ]; then
  bad "no quickshell/kwi3 subdirectory was created through the symlink either"
else
  ok "no quickshell/kwi3 subdirectory was created through the symlink either"
fi

# the rest of step 3 still did its real job
if [ -L "$FAKE_HOME/.local/bin/i3kwin-x11" ] \
   && [ "$(readlink "$FAKE_HOME/.local/bin/i3kwin-x11")" = "$FINAL_BIN" ]; then
  ok "the binary is still linked (not copied) to the built path"
else
  bad "the binary link is missing or wrong"
fi
if [ -L "$FAKE_HOME/.local/bin/kwi3-x11-session" ]; then
  ok "kwi3-x11-session is still linked from the clone"
else
  bad "kwi3-x11-session link is missing"
fi
has "$TRACE" "rotz link kwi3 --force" "and rotz link kwi3 --force still ran"

echo
echo "test-bar-symlink-safe: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
