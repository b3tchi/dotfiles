#!/usr/bin/env bash
# test-xsession-install.sh - kwi3-lightdm/dot.yaml (kwi3 as a lightdm session
# on this box's own display; the session files themselves are kwi3's,
# tested in that repo - kwi3-30f), with no root and nothing
# under /usr touched.
#
#   kwi3/test-xsession-install.sh
#
# Lives here beside test-xrdp-install.sh; kwi3-lightdm/ holds only the
# dot.yaml meta-native-kwi3 references.
#
# Same approach as test-xrdp-install.sh: the text under test is read straight
# out of kwi3-lightdm/dot.yaml with `yq` - the exact characters
# `rotz install kwi3-lightdm` runs - never restated.
#
# Stubbed: `sudo` (records, then runs the rest; FAIL_SUDO_INSTALL=1 fails
# `sudo install` like a refused password) and `busctl` (a pure recorder - it
# must never reach the real AccountsService, which would change Jan's actual
# default session). `install`, `cmp`, `sed` are real against a mktemp -d root
# ($KWI3_XSESSION_ROOT) and a fake $HOME.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOT_YAML="$SCRIPT_DIR/../kwi3-lightdm/dot.yaml"

command -v yq >/dev/null 2>&1 || { echo "test-xsession-install: needs yq" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

STATE="$(mktemp -d "${TMPDIR:-/tmp}/kwi3-xsession-test.XXXXXX")"
trap 'rm -rf "$STATE"' EXIT
BIN="$STATE/bin"; TRACE="$STATE/trace"; FRAGMENT="$STATE/fragment.sh"
FAKE_SRC="$STATE/src"
mkdir -p "$BIN" "$FAKE_SRC/i3kwin/session"
printf '[Desktop Entry]\nName=kwi3\nExec=kwi3-xsession\nTryExec=kwi3-xsession\nType=XSession\n' \
  > "$FAKE_SRC/i3kwin/session/kwi3.desktop"
printf '#!/bin/sh\nexec "$HOME/.local/bin/kwi3-x11-session"\n' \
  > "$FAKE_SRC/i3kwin/session/kwi3-xsession"

cat > "$BIN/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$TRACE"
if [ "${FAIL_SUDO_INSTALL:-0}" = 1 ] && [ "$1" = install ]; then
  echo "sudo: a password is required" >&2; exit 1
fi
exec "$@"
EOF
cat > "$BIN/busctl" <<'EOF'
#!/bin/sh
printf 'busctl %s\n' "$*" >> "$TRACE"
exit 0
EOF
chmod +x "$BIN/sudo" "$BIN/busctl"

yq -r '.linux.installs.cmd' "$DOT_YAML" > "$FRAGMENT"
[ -s "$FRAGMENT" ] || { echo "test-xsession-install: empty cmd in $DOT_YAML" >&2; exit 2; }

# run ROOT HOME [env...] - the fragment, as rotz would run it.
run() {
  _root=$1 _home=$2; shift 2
  : > "$TRACE"
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$_home" TRACE="$TRACE" \
      KWI3_SRC="$FAKE_SRC" KWI3_XSESSION_ROOT="$_root" "$@" \
      bash "$FRAGMENT" > "$STATE/out" 2>&1
  echo $?
}
newroot() { mkdir -p "$STATE/$1/usr/share/xsessions"; echo "$STATE/$1"; }
newhome() { mkdir -p "$STATE/$1"; echo "$STATE/$1"; }
nbus() { grep -c '^busctl ' "$TRACE"; }
nsudo() { grep -c '^sudo ' "$TRACE"; }

echo "-- 1. first install"
R=$(newroot r1); H=$(newhome h1)
printf '[Desktop]\nLanguage=en_US.utf8\nSession=xfce\n' > "$H/.dmrc"
check "$(run "$R" "$H")" 0 "fragment exits 0"
cmp -s "$FAKE_SRC/i3kwin/session/kwi3.desktop" "$R/usr/share/xsessions/kwi3.desktop" \
  && ok "kwi3.desktop installed" || bad "kwi3.desktop installed"
check "$(stat -c %a "$R/usr/local/bin/kwi3-xsession" 2>/dev/null)" 755 "wrapper installed executable"
check "$(stat -c %a "$R/usr/share/xsessions/kwi3.desktop" 2>/dev/null)" 644 "desktop file mode 644"
grep -q "SetXSession s kwi3" "$TRACE" && ok "AccountsService default set to kwi3" \
  || bad "AccountsService default set to kwi3"
grep -q "/org/freedesktop/Accounts/User$(id -u) " "$TRACE" && ok "for this user only" \
  || bad "for this user only"
check "$(grep -c '^Session=kwi3$' "$H/.dmrc")" 1 "~/.dmrc Session= rewritten to kwi3"
check "$(grep -c '^Session=xfce' "$H/.dmrc")" 0 "old Session= gone"
check "$(grep -c '^Language=' "$H/.dmrc")" 1 "rest of ~/.dmrc kept"

echo "-- 2. re-run: idempotent, greeter choice sticks"
sed -i 's/^Session=.*/Session=i3/' "$H/.dmrc"   # Jan picked i3 in the greeter
check "$(run "$R" "$H")" 0 "fragment exits 0"
check "$(nsudo)" 0 "nothing changed: no sudo at all"
check "$(nbus)" 0 "default session NOT reset"
check "$(grep -c '^Session=i3$' "$H/.dmrc")" 1 "~/.dmrc keeps the greeter's pick"

echo "-- 3. a changed wrapper is updated, default still untouched"
echo '# changed' >> "$FAKE_SRC/i3kwin/session/kwi3-xsession"
run "$R" "$H" >/dev/null
cmp -s "$FAKE_SRC/i3kwin/session/kwi3-xsession" "$R/usr/local/bin/kwi3-xsession" \
  && ok "wrapper refreshed" || bad "wrapper refreshed"
check "$(nbus)" 0 "and the default session is still not touched"

echo "-- 4. kwi3 release without the files (predates kwi3-30f)"
R=$(newroot r4); H=$(newhome h4)
mv "$FAKE_SRC/i3kwin/session/kwi3.desktop" "$STATE/stash.desktop"
check "$(run "$R" "$H")" 0 "fragment exits 0"
grep -q "has no i3kwin/session/kwi3.desktop" "$STATE/out" && ok "skip is named" || bad "skip is named"
check "$(nsudo)$(nbus)" 00 "no sudo, no busctl"
[ -e "$H/.dmrc" ] && bad "~/.dmrc untouched" || ok "~/.dmrc untouched"
mv "$STATE/stash.desktop" "$FAKE_SRC/i3kwin/session/kwi3.desktop"

echo "-- 5. no display manager (no xsessions dir)"
mkdir -p "$STATE/r5"; H=$(newhome h5)
check "$(run "$STATE/r5" "$H")" 0 "fragment exits 0"
grep -q "no .*/usr/share/xsessions" "$STATE/out" && ok "skip is named" || bad "skip is named"
check "$(nsudo)$(nbus)" 00 "no sudo, no busctl"

echo "-- 6. sudo refused"
R=$(newroot r6); H=$(newhome h6)
check "$(run "$R" "$H" FAIL_SUDO_INSTALL=1)" 1 "exit 1, so rotz reports it"
[ -e "$R/usr/share/xsessions/kwi3.desktop" ] && bad "no desktop file listed" || ok "no desktop file listed"
check "$(nbus)" 0 "no default session set"
grep -q "local session NOT installed" "$STATE/out" && ok "failure is named" || bad "failure is named"
[ -e "$H/.dmrc" ] && bad "~/.dmrc untouched" || ok "~/.dmrc untouched"

echo "-- 7. ~/.dmrc shapes"
R=$(newroot r7); H=$(newhome h7)
run "$R" "$H" >/dev/null
check "$(cat "$H/.dmrc" 2>/dev/null | tr '\n' '|')" "[Desktop]|Session=kwi3|" "absent ~/.dmrc is created"
R=$(newroot r8); H=$(newhome h8)
printf '[Desktop]\nLanguage=en_US.utf8\n' > "$H/.dmrc"
run "$R" "$H" >/dev/null
check "$(grep -c '^\[Desktop\]' "$H/.dmrc")$(grep -c '^Session=kwi3$' "$H/.dmrc")" 11 \
  "[Desktop] without Session= gains one line, no second section"

echo "-- 8. no kwi3 checkout"
R=$(newroot r9); H=$(newhome h9)
check "$(run "$R" "$H" KWI3_SRC="$STATE/nosrc")" 1 "exit 1"
grep -q "no kwi3 checkout at $STATE/nosrc" "$STATE/out" && ok "named" || bad "named"
check "$(nsudo)$(nbus)" 00 "no sudo, no busctl"

echo
echo "test-xsession-install: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
