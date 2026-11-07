#!/usr/bin/env bash
# test-setup.sh - github/setup.sh: key created once, GitHub's host key pinned,
# gh login only when logged out, the key registered only when the account
# lacks it. No network: a throwaway $HOME and a stub gh.
#
# Usage: github/test-setup.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
S="$here/setup.sh"
fails=0
ok() { echo "ok   - $1"; }
no() { echo "FAIL - $1"; fails=$((fails + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME" "$T/bin"
# stub gh: `auth status` exits with $T/auth-rc (default 1, logged out);
# `auth login` and `ssh-key add` are logged and succeed; `api user/keys`
# prints $T/account-keys.
cat >"$T/bin/gh" <<STUB
#!/bin/sh
echo "\$*" >>"$T/gh-calls"
case "\$1 \$2" in
"auth status") exit \$(cat "$T/auth-rc" 2>/dev/null || echo 1) ;;
"auth login") echo 0 >"$T/auth-rc" ;;
"api user/keys") cat "$T/account-keys" 2>/dev/null ;;
"ssh-key add") cut -d' ' -f1,2 "\$3" >>"$T/account-keys" ;;
esac
exit 0
STUB
chmod +x "$T/bin/gh"
run() { PATH="$T/bin:$PATH" sh "$S" >"$T/out" 2>&1; }
calls() { local n; n=$(grep -c "^$1" "$T/gh-calls" 2>/dev/null); echo "${n:-0}"; }

KH="$HOME/.ssh/known_hosts"
PIN="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

# --- first run: nothing set up
run
rc=$?
[ "$rc" = 0 ] && ok "first run succeeds" || no "first run succeeds (rc $rc: $(cat "$T/out"))"
[ -f "$HOME/.ssh/id_ed25519" ] && [ -f "$HOME/.ssh/id_ed25519.pub" ] && ok "key created" || no "key created"
[ "$(stat -c %a "$HOME/.ssh")" = 700 ] && ok "~/.ssh is 700" || no "~/.ssh is 700"
[ "$(stat -c %a "$HOME/.ssh/id_ed25519")" = 600 ] && ok "private key is 600" || no "private key is 600"
grep -qxF "$PIN" "$KH" 2>/dev/null && ok "GitHub host key pinned" || no "GitHub host key pinned"
[ "$(calls 'auth login')" = 1 ] && ok "logged out -> one gh login" || no "logged out -> one gh login ($(calls 'auth login'))"
grep -q -- '--git-protocol ssh' "$T/gh-calls" && grep -q -- 'admin:public_key' "$T/gh-calls" &&
    ok "login over ssh, with the scope to add keys" || no "login over ssh, with the scope to add keys"
[ "$(calls 'ssh-key add')" = 1 ] && ok "key registered on the account" || no "key registered on the account"

# --- second run: everything in place, nothing done
key1=$(cat "$HOME/.ssh/id_ed25519.pub")
rm -f "$T/gh-calls"
run
rc=$?
[ "$rc" = 0 ] && ok "second run succeeds" || no "second run succeeds (rc $rc)"
[ "$(cat "$HOME/.ssh/id_ed25519.pub")" = "$key1" ] && ok "existing key kept" || no "existing key kept"
[ "$(grep -cxF "$PIN" "$KH")" = 1 ] && ok "host key pinned once" || no "host key pinned once"
[ "$(calls 'auth login')" = 0 ] && ok "logged in -> no login" || no "logged in -> no login"
[ "$(calls 'ssh-key add')" = 0 ] && ok "key on the account -> not added again" || no "key on the account -> not added again"

# --- a known_hosts entry for github.com with another key: refuse, change nothing
printf '%s\n' "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBADBADBADBADBADBADBADBADBADBADBADBADBADBADBA" >"$KH"
run
rc=$?
[ "$rc" != 0 ] && ok "other github.com host key -> refused" || no "other github.com host key -> refused"
grep -qF "$PIN" "$KH" && no "other host key left as found" || ok "other host key left as found"

# --- failed login stops the run
rm -f "$KH" "$T/gh-calls" "$T/account-keys"
echo 1 >"$T/auth-rc"
cat >"$T/bin/gh" <<STUB
#!/bin/sh
echo "\$*" >>"$T/gh-calls"
case "\$1 \$2" in
"auth status") exit 1 ;;
"auth login") exit 1 ;;
esac
exit 0
STUB
run
rc=$?
[ "$rc" != 0 ] && ok "failed login -> fails" || no "failed login -> fails"
[ "$(calls 'ssh-key add')" = 0 ] && ok "failed login -> no key added" || no "failed login -> no key added"

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
