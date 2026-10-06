#!/usr/bin/env bash
# test-xinitrc.sh - xrdp/xinitrc's KWI3_SESSION dispatch, with no X server
# and no xrdp (kwi3-7m8.7).
#
#   xrdp/test-xinitrc.sh
#
# Same stub approach as kwi3's own i3kwin/test/session-launcher-test.sh:
# nothing under test talks to a display. xrdb, setxkbmap, i3 and
# kwi3-x11-session are all recorder stubs, and kwi3-session-env.sh is a
# second stub (SOURCED, exactly as the real script sources it) whose
# STUB_ENV_MODE picks what it exports, so the refusal paths can be driven
# without a real window manager ever computing a real socket path. Since
# kwi3 sp004 Task 18 (kwi3-234.18) the env script exports $KWI3SOCK only -
# kwi3 has no i3 IPC socket - so the healthy shape is KWI3SOCK set; the old
# I3SOCK/HOTKEYD_I3SOCK pair is what a STALE (pre-T18) install exports.
#
# What this does NOT re-test: kwi3-x11-session's own internals (the
# hotkeyd/bar startup ordering, the ready-marker wait) - that is
# i3kwin/test/session-launcher-test.sh's job, in the kwi3 repo. This file
# only covers the one thing that lives in THIS repo: which program
# xrdp/xinitrc hands off to, and under which conditions.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XINITRC="$REPO_ROOT/xrdp/xinitrc"

[ -r "$XINITRC" ] || { echo "test-xinitrc: missing $XINITRC" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has()  { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (not in $(basename "$1"))"; fi; }
hasnt() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found '$2')"; else ok "$3"; fi; }

STATE="$(mktemp -d "${TMPDIR:-/tmp}/kwi3-xinitrc-test.XXXXXX")"
trap 'rm -rf "$STATE"' EXIT

BIN="$STATE/bin"
FAKE_HOME="$STATE/home"
TRACE="$STATE/trace"
mkdir -p "$BIN" "$FAKE_HOME/.local/bin"

mkstub() { # mkstub NAME BODY
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\n%s\n' "$1" "$TRACE" "$2" \
    > "$BIN/$1"
  chmod +x "$BIN/$1"
}
mkstub xrdb      'cat >/dev/null; exit 0'
# -query answers with whatever layout xorgxrdp loaded from the RDP client's
# keyboard (STUB_XKB_LAYOUT / STUB_XKB_VARIANT); unset, it prints no layout.
mkstub setxkbmap 'if [ "$1" = -query ]; then
  printf "rules:      base\nmodel:      pc104\n"
  [ -n "${STUB_XKB_LAYOUT:-}" ] && printf "layout:     %s\n" "$STUB_XKB_LAYOUT"
  [ -n "${STUB_XKB_VARIANT:-}" ] && printf "variant:    %s\n" "$STUB_XKB_VARIANT"
fi
exit 0'
mkstub i3        'exit 0'
# sp038 T1: the snapshot writer is a recorder too; only ORDER is asserted.
cat > "$FAKE_HOME/.local/bin/wm-session-env-snapshot" <<EOF
#!/bin/sh
printf 'wm-session-env-snapshot\n' >> "$TRACE"
exit 0
EOF
chmod +x "$FAKE_HOME/.local/bin/wm-session-env-snapshot"

cat > "$FAKE_HOME/.local/bin/kwi3-x11-session" <<EOF
#!/bin/sh
printf 'kwi3-x11-session %s\n' "\$*" >> "$TRACE"
exit 0
EOF
chmod +x "$FAKE_HOME/.local/bin/kwi3-x11-session"

# Sourced, not exec'd, by the real xinitrc - so this has no shebang trap of
# its own to worry about, only what it exports. STUB_ENV_MODE:
#   agree     - KWI3SOCK set, no i3 variable (the healthy, post-T18 case)
#   legacy    - I3SOCK == HOTKEYD_I3SOCK and no KWI3SOCK: a stale pre-T18
#               kwi3-session-env.sh, naming an i3 socket kwi3 no longer serves
#   noexport  - the file exists but exports nothing (a broken install)
cat > "$FAKE_HOME/.local/bin/kwi3-session-env.sh" <<'EOF'
printf 'kwi3-session-env.sh sourced\n' >> "$TRACE"
case "${STUB_ENV_MODE:-agree}" in
  agree)    KWI3SOCK=/run/user/1000/kwi3-99.rpc.sock; export KWI3SOCK ;;
  legacy)   I3SOCK=/run/user/1000/kwi3-99.sock; HOTKEYD_I3SOCK=/run/user/1000/kwi3-99.sock
            export I3SOCK HOTKEYD_I3SOCK ;;
  noexport) : ;;
esac
EOF

# run_xinitrc [extra env assignments...] - runs the real xinitrc as its own
# process (matching how startwm.sh sources it into a shell that then execs -
# effect is identical: whatever it execs becomes the process this call
# waits on).
run_xinitrc() {
  : > "$TRACE"
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$FAKE_HOME" TRACE="$TRACE" \
      "$@" sh "$XINITRC"
  echo $?
}

# ===========================================================================
echo "-- 1. KWI3_SESSION unset: the i3 leg, unconditional"
# ===========================================================================
rc=$(run_xinitrc)
check "$rc" "0" "no KWI3_SESSION: xinitrc exits 0 (i3 stub's own exit)"
has "$TRACE" "i3 " "execs i3"
hasnt "$TRACE" "kwi3-x11-session" "never touches the kwi3 launcher"
hasnt "$TRACE" "kwi3-session-env.sh sourced" "never sources the env script"

# ===========================================================================
echo "-- 2. shared preamble runs on the i3 leg too (mod resource + keymap)"
# ===========================================================================
run_xinitrc XRDP_SESSION=1 >/dev/null
has "$TRACE" "xrdb -merge" "xrdb -merge ran (Alt-as-mod resource)"
has "$TRACE" "setxkbmap -layout us -model pc104 -option " "setxkbmap ran (keymap + locked-modifier reset)"

# ===========================================================================
echo "-- 2b. the keymap reset keeps the RDP client's layout (Dvorak stays Dvorak)"
# ===========================================================================
run_xinitrc XRDP_SESSION=1 STUB_XKB_LAYOUT='us(dvorak)' >/dev/null
has "$TRACE" "setxkbmap -layout us(dvorak) -model pc104 -option " "i3 leg keeps us(dvorak)"
hasnt "$TRACE" "setxkbmap -layout us -model" "and does not force QWERTY over it"
run_xinitrc KWI3_SESSION=1 XRDP_SESSION=1 STUB_ENV_MODE=agree STUB_XKB_LAYOUT='us(dvorak)' >/dev/null
has "$TRACE" "setxkbmap -layout us(dvorak) -model pc104 -option " "kwi3 leg keeps us(dvorak)"
run_xinitrc STUB_XKB_LAYOUT=us STUB_XKB_VARIANT=dvorak >/dev/null
has "$TRACE" "setxkbmap -layout us -variant dvorak -model pc104 -option " "layout + variant keeps its variant"

# ===========================================================================
echo "-- 3. KWI3_SESSION=1, healthy env, launcher present: the kwi3 leg"
# ===========================================================================
rc=$(run_xinitrc KWI3_SESSION=1 XRDP_SESSION=1 STUB_ENV_MODE=agree)
check "$rc" "0" "healthy kwi3 leg: exits 0 (the stub launcher's own exit)"
has "$TRACE" "kwi3-session-env.sh sourced" "sources kwi3-session-env.sh"
has "$TRACE" "kwi3-x11-session " "execs kwi3-x11-session"
hasnt "$TRACE" "i3 " "does NOT fall through to i3"
has "$TRACE" "xrdb -merge" "the shared preamble still ran first (same leg, same session)"
has "$TRACE" "setxkbmap -layout us -model pc104 -option " "and the keymap reset too"

# ===========================================================================
echo "-- 4. KWI3_SESSION=1, no \$KWI3SOCK exported: refuses, falls through"
# ===========================================================================
# A stale, pre-T18 env script (I3SOCK/HOTKEYD_I3SOCK and no KWI3SOCK) and a
# broken one that exports nothing are the same refusal: nothing in the
# session would know where kwi3's socket is.
STATE_ERR="$STATE/stderr"
for mode in legacy noexport; do
  : > "$TRACE"; : > "$STATE_ERR"
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$FAKE_HOME" TRACE="$TRACE" \
      KWI3_SESSION=1 STUB_ENV_MODE=$mode \
      sh "$XINITRC" >/dev/null 2>"$STATE_ERR"
  has "$TRACE" "kwi3-session-env.sh sourced" "$mode: still sources the env script"
  hasnt "$TRACE" "kwi3-x11-session" "$mode: refuses to exec the kwi3 launcher with no KWI3SOCK"
  has "$TRACE" "i3 " "$mode: falls through to the i3 leg instead"
  has "$STATE_ERR" "KWI3SOCK" "$mode: and says why, on stderr"
done

# ===========================================================================
echo "-- 5. KWI3_SESSION=1, launcher missing: falls through, does not crash"
# ===========================================================================
rm -f "$FAKE_HOME/.local/bin/kwi3-x11-session"
: > "$STATE_ERR"
: > "$TRACE"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$FAKE_HOME" TRACE="$TRACE" \
    KWI3_SESSION=1 STUB_ENV_MODE=agree \
    sh "$XINITRC" >/dev/null 2>"$STATE_ERR"
has "$TRACE" "i3 " "falls through to the i3 leg when the launcher binary is gone"
has "$STATE_ERR" "missing, not" "and says why, on stderr"

# ===========================================================================
echo "-- 6. the i3 leg's own bytes are untouched - the diff is pure addition"
# ===========================================================================
# Compared against the branch this task is stacked on, not against HEAD: by
# the time this runs post-commit, a diff against HEAD would show nothing at
# all and prove nothing. bd-kwi3-7m8.6.0 is the pristine file this task
# started from.
BASE_REF=bd-kwi3-7m8.6.0
if git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
  REMOVED=$(git -C "$REPO_ROOT" diff --no-color "$BASE_REF" -- xrdp/xinitrc \
              | grep -c '^-[^-]')
  check "$REMOVED" "0" "diff against $BASE_REF removes zero lines (pure addition)"
else
  echo "  SKIP diff-against-base check ($BASE_REF not found in this clone)"
fi

# ===========================================================================
echo "-- 7. sp038 T1: the session env snapshot is taken BEFORE each exec"
# ===========================================================================
# line number of the first trace line starting with $1 (empty when absent)
lineof() { grep -n "^$1" "$TRACE" | head -1 | cut -d: -f1; }
before() { # before SNAP-LINE EXEC-LINE LABEL
  if [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; then ok "$3"; else bad "$3 (snapshot line '$1', exec line '$2')"; fi
}
cat > "$FAKE_HOME/.local/bin/kwi3-x11-session" <<EOF
#!/bin/sh
printf 'kwi3-x11-session %s\n' "\$*" >> "$TRACE"
exit 0
EOF
chmod +x "$FAKE_HOME/.local/bin/kwi3-x11-session"

run_xinitrc KWI3_SESSION=1 STUB_ENV_MODE=agree >/dev/null
before "$(lineof wm-session-env-snapshot)" "$(lineof kwi3-x11-session)" "snapshot-before-exec-kwi3: snapshot recorded before kwi3-x11-session"
hasnt "$TRACE" "i3 " "snapshot-before-exec-kwi3: no i3 exec"

run_xinitrc >/dev/null
before "$(lineof wm-session-env-snapshot)" "$(lineof 'i3 ')" "snapshot-before-exec-i3: snapshot recorded before i3"

run_xinitrc KWI3_SESSION=1 STUB_ENV_MODE=noexport >/dev/null 2>&1
before "$(lineof wm-session-env-snapshot)" "$(lineof 'i3 ')" "snapshot-on-fallthrough: refusal path still snapshots, before i3"
check "$(grep -c '^wm-session-env-snapshot' "$TRACE")" "1" "snapshot-on-fallthrough: exactly once"

# a missing writer must not stop the session
rm -f "$FAKE_HOME/.local/bin/wm-session-env-snapshot"
run_xinitrc >/dev/null 2>&1
has "$TRACE" "i3 " "snapshot writer missing: i3 still exec'd"

echo
echo "test-xinitrc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
