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

# ---------------------------------------------------------------------------
# WHAT THE BRIDGE MAY FORWARD (dotfiles-9i56). Everything above is about the
# startup gate and needs no X server; this section needs one, because the
# defect is in what the running poller does with a selection it should not
# touch.
#
# The bridge is TEXT-ONLY by design, but it read the X clipboard with a bare
# `xclip -o` — and xclip, which owns the selection behind every picture this
# repo publishes, answers ANY target request with its payload. So an image/png
# selection was read as text, pushed into the WINDOWS clipboard as text
# (confirmed on the deployed host: Get-Clipboard came back with the PNG
# header), and the Win->X watcher then wrote that text back onto the X
# clipboard — which is what made a $mod+v picture pick paste as "\211PNG\r\n"
# about a second after it was set.
#
# The powershell stand-in LOGS what would have gone to Windows, so "was it
# forwarded" is an observation rather than an assumption. It is the same
# process for both directions the bridge spawns: a Set-Clipboard invocation
# appends its stdin to the log, a Get-Clipboard watcher just blocks (nothing
# ever comes back from "Windows" here).
XVFB="${XVFB:-Xvfb}"
if command -v "$XVFB" >/dev/null 2>&1 && command -v xclip >/dev/null 2>&1; then
  # A display number that is genuinely free: neither a socket file, nor a lock,
  # nor an answer to a connection — an X server can be live with no socket file
  # at all (dotfiles-4ai2), and standing this suite's Xvfb on top of a real
  # session would push that session's clipboard to Windows.
  FWD_NUM=189
  while [ -e "/tmp/.X11-unix/X$FWD_NUM" ] || [ -e "/tmp/.X${FWD_NUM}-lock" ] \
        || grep -q "@/tmp/\.X11-unix/X$FWD_NUM\$" /proc/net/unix 2>/dev/null; do
    FWD_NUM=$((FWD_NUM + 1))
  done
  FWD_DPY=":$FWD_NUM"

  "$XVFB" "$FWD_DPY" -screen 0 320x240x24 >"$TMP/xvfb.log" 2>&1 &
  FWD_XVFB=$!
  for _i in $(seq 1 40); do
    env DISPLAY="$FWD_DPY" timeout 2 xclip -selection clipboard -t TARGETS -o \
      2>&1 >/dev/null | grep -q "Can't open display" || break
    sleep 0.25
  done

  PS_LOG="$TMP/ps.log"; : > "$PS_LOG"
  mkdir -p "$TMP/fwdbin"
  cat > "$TMP/fwdbin/powershell.exe" <<'STUBEOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *Set-Clipboard*) cat >> "$PS_LOG"; printf '\n--push--\n' >> "$PS_LOG"; exit 0 ;;
    *Get-Clipboard*) exec sleep 300 ;;
  esac
done
exec sleep 300
STUBEOF
  chmod +x "$TMP/fwdbin/powershell.exe"

  printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==' \
    | base64 -d > "$TMP/one.png"

  own_text() { printf '%s' "$1" | env DISPLAY="$FWD_DPY" xclip -selection clipboard -i & sleep 0.4; }
  own_img()  { env DISPLAY="$FWD_DPY" xclip -selection clipboard -t image/png -i < "$TMP/one.png" & sleep 0.4; }

  env -i HOME="$TMP/home" PATH="$TMP/fwdbin:/usr/bin:/bin" \
      PS_LOG="$PS_LOG" \
      CLIP_BRIDGE_DISPLAY="$FWD_DPY" \
      CLIP_BRIDGE_LOCK="$TMP/fwd.lock" \
      CLIP_BRIDGE_WSL_MARK="$TMP/iswsl" \
      /bin/sh "$BRIDGE" >"$TMP/fwd.out" 2>&1 &
  FWD_PID=$!
  sleep 2

  scenario "forwarding CONTROL: a text copy IS pushed to Windows"
  own_text 'BRIDGE-TEXT-marker'
  sleep 2
  assert_eq "the text reached the Windows side" "yes" \
    "$(grep -qF 'BRIDGE-TEXT-marker' "$PS_LOG" && echo yes || echo no)"

  scenario "forwarding: an image-only selection is NOT pushed to Windows"
  pushes_before="$(grep -c -- '--push--' "$PS_LOG")"
  own_img
  sleep 3
  assert_eq "no PNG bytes were handed to Set-Clipboard" "no" \
    "$(grep -qa 'PNG' "$PS_LOG" && echo yes || echo no)"
  assert_eq "and no further push happened at all" "$pushes_before" \
    "$(grep -c -- '--push--' "$PS_LOG")"

  scenario "forwarding: a text copy after the image is pushed again (the skip must not wedge the poller)"
  own_text 'BRIDGE-TEXT-after-image'
  sleep 2
  assert_eq "the later text reached the Windows side" "yes" \
    "$(grep -qF 'BRIDGE-TEXT-after-image' "$PS_LOG" && echo yes || echo no)"

  # Reap the whole tree, in the order that actually works: the win_watch
  # SUBSHELL is a child of $FWD_PID and its powershell stand-in a child of
  # that, so killing the parent first orphans the rest (observed: a bridge and
  # a `sleep 300` stub left running past the suite). Children first, parent
  # last, and grandchildren via the subshell's own pid.
  for _p in $(pgrep -P "$FWD_PID" 2>/dev/null); do
    pkill -P "$_p" 2>/dev/null
    kill "$_p" 2>/dev/null
  done
  kill "$FWD_PID" 2>/dev/null
  wait "$FWD_PID" 2>/dev/null
  kill "$FWD_XVFB" 2>/dev/null
else
  printf '\n[forwarding: skipped — Xvfb or xclip missing]\n'
fi

printf '\n%s\n' "-------------------------------------------------"
printf 'PASS %s   FAIL %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
