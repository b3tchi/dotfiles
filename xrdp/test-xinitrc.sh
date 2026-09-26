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
# STUB_ENV_MODE picks what it exports, so the "I3SOCK/HOTKEYD_I3SOCK
# disagree" refusal path (kwi3-soc.7's trap) can be driven without a real
# window manager ever computing a real socket path.
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

cat > "$FAKE_HOME/.local/bin/kwi3-x11-session" <<EOF
#!/bin/sh
printf 'kwi3-x11-session %s\n' "\$*" >> "$TRACE"
exit 0
EOF
chmod +x "$FAKE_HOME/.local/bin/kwi3-x11-session"

# Sourced, not exec'd, by the real xinitrc - so this has no shebang trap of
# its own to worry about, only what it exports. STUB_ENV_MODE:
#   agree     - I3SOCK == HOTKEYD_I3SOCK (the healthy case)
#   disagree  - the two differ (kwi3-soc.7's trap)
#   noexport  - the file exists but exports neither (a broken install)
cat > "$FAKE_HOME/.local/bin/kwi3-session-env.sh" <<'EOF'
printf 'kwi3-session-env.sh sourced\n' >> "$TRACE"
case "${STUB_ENV_MODE:-agree}" in
  agree)    I3SOCK=/run/user/1000/kwi3-99.sock; HOTKEYD_I3SOCK=/run/user/1000/kwi3-99.sock ;;
  disagree) I3SOCK=/run/user/1000/kwi3-99.sock; HOTKEYD_I3SOCK=/run/user/1000/other.sock ;;
  noexport) : ;;
esac
export I3SOCK HOTKEYD_I3SOCK
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
echo "-- 4. KWI3_SESSION=1, I3SOCK/HOTKEYD_I3SOCK disagree: refuses, falls through"
# ===========================================================================
STATE_ERR="$STATE/stderr"
: > "$TRACE"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$FAKE_HOME" TRACE="$TRACE" \
    KWI3_SESSION=1 STUB_ENV_MODE=disagree \
    sh "$XINITRC" >/dev/null 2>"$STATE_ERR"
has "$TRACE" "kwi3-session-env.sh sourced" "still sources the env script"
hasnt "$TRACE" "kwi3-x11-session" "refuses to exec the kwi3 launcher when the sockets disagree"
has "$TRACE" "i3 " "falls through to the i3 leg instead"
has "$STATE_ERR" "disagree" "and says why, on stderr"

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

echo
echo "test-xinitrc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
