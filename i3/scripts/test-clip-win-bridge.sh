#!/usr/bin/env bash
# test-clip-win-bridge.sh — how the Windows<->X clipboard bridge decides
# whether it can run at all (dotfiles-7hf8).  No X server, no WSL, no
# powershell: every scenario is about the STARTUP GATE, which runs before the
# first X call.
#
# WHY THIS EXISTS.  The bridge guarded itself with
#
#     PS=powershell.exe
#     command -v "$PS" >/dev/null 2>&1 || exit 0   # not WSL / interop off
#
# and `exit 0` is the whole bug.  On this host powershell.exe is a symlink in
# ~/.local/bin/win/, a directory that the login `profile` puts on PATH but i3
# does NOT: i3's PATH is /home/jan/.local/bin:/sbin:/bin:/usr/bin:...  So the
# autostart in config.d/wsl.conf resolved nothing, took the silent success
# branch, and the Windows clipboard bridge never ran from i3 at all.  It only
# ever ran when a human or an agent started it from an interactive shell,
# which is why "clipboard from Windows is broken AGAIN" recurred after every
# reboot and every i3 restart, and why it always came back after someone
# poked at it by hand.
#
# The gate now separates the two cases the old one conflated:
#   * not WSL at all            -> exit 0, silent.  Nothing to bridge; the
#                                  native i3 session autostarts this too.
#   * WSL but no interop found  -> exit 69 (EX_UNAVAILABLE) and SAY SO.  The
#                                  bridge is expected to work here, so a
#                                  silent no-op is a lie.
# and it looks in the places this repo actually installs interop, not only on
# whatever PATH it inherited.
#
# usage: i3/scripts/test-clip-win-bridge.sh
# env:   KEEP_TMP=1
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$REPO_DIR/clip-win-bridge.sh"

TMP="/tmp/clip-win-bridge-test.$$"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
scenario() { printf '\n[%s]\n' "$1"; }

cleanup() {
  # Only processes this suite started, found by the lock file it alone uses.
  local p
  for p in $(pgrep -f "CLIP_BRIDGE_LOCK=$TMP" 2>/dev/null); do kill "$p" 2>/dev/null; done
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/home/.local/bin/win" "$TMP/emptybin" "$TMP/pathbin" "$TMP/notwsl" "$TMP/iswsl"

# A powershell stand-in that never touches Windows: it just blocks, which is
# what the real one does between clipboard polls.
mkstub() { printf '#!/bin/sh\nexec sleep 300\n' > "$1"; chmod +x "$1"; }

# Run the bridge with a fully controlled environment.  DISPLAY points at a
# display that does not exist, so a scenario that gets PAST the gate does no
# damage to the live session; its own flock lives under $TMP so it can never
# collide with the production bridge.  `timeout 3` bounds the ones that are
# SUPPOSED to keep running — 124 means "ran", which is the assertion.
# $1 is prepended to the system dirs rather than replacing them: the script
# needs sh/xclip/flock to exist at all.  /usr/bin and /bin hold no
# powershell.exe, so "not on PATH" scenarios stay honest.
run_gate() { # <path> <home> <wsl-marker-dir>
  timeout 3 env -i \
    HOME="$2" PATH="$1:/usr/bin:/bin" \
    CLIP_BRIDGE_DISPLAY=:99 \
    CLIP_BRIDGE_LOCK="$TMP/lock" \
    CLIP_BRIDGE_WSL_MARK="$3" \
    /bin/sh "$BRIDGE" >"$TMP/out" 2>&1
  printf '%s' $?
}

[ -r "$BRIDGE" ] || { echo "FATAL: $BRIDGE not readable" >&2; exit 1; }

# ---------------------------------------------------------------------------

scenario "gate: powershell.exe on PATH — runs (the case that always worked)"
mkstub "$TMP/pathbin/powershell.exe"
rc="$(run_gate "$TMP/pathbin" "$TMP/home" "$TMP/iswsl")"
assert_eq "still running when the deadline hit (124 = did not exit)" "124" "$rc"

scenario "gate: NOT on PATH but installed at ~/.local/bin/win — runs anyway (dotfiles-7hf8)"
# This is i3's exact situation: a PATH without ~/.local/bin/win, and the
# interop symlink sitting there unused. The old gate exited 0 here.
mkstub "$TMP/home/.local/bin/win/powershell.exe"
rc="$(run_gate "$TMP/emptybin" "$TMP/home" "$TMP/iswsl")"
assert_eq "resolves the repo's own interop location" "124" "$rc"

scenario "gate: on WSL with no interop anywhere — refuses LOUDLY, never silently"
rm -f "$TMP/home/.local/bin/win/powershell.exe"
rc="$(run_gate "$TMP/emptybin" "$TMP/home" "$TMP/iswsl")"
assert_eq "exit 69 (EX_UNAVAILABLE), not 0" "69" "$rc"
assert_eq "and says what is missing" "yes" \
  "$(grep -qi 'powershell\|interop' "$TMP/out" && echo yes || echo no)"

scenario "gate: not WSL at all — exits 0 in silence (native i3 autostarts this too)"
rc="$(run_gate "$TMP/emptybin" "$TMP/home" "$TMP/notwsl-does-not-exist")"
assert_eq "exit 0" "0" "$rc"
assert_eq "and prints nothing" "" "$(cat "$TMP/out")"

printf '\n%s\n' "-------------------------------------------------"
printf 'PASS %s   FAIL %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
