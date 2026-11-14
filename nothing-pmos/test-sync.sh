#!/usr/bin/env bash
# test-sync.sh - nothing-pmos/sync.sh: the phone's clone of the nothing-pmos
# repo is fetched from $NOTHING_PMOS_REPO and fast-forwarded, still accepts a
# push from the dev box, and is never reset or switched. A local bare repo
# stands in for GitHub; install.sh is a stub that logs each run.
#
# Usage: nothing-pmos/test-sync.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
S="$here/sync.sh"
fails=0
ok() { echo "ok   - $1"; }
no() { echo "FAIL - $1"; fails=$((fails + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig"
mkdir -p "$HOME"
git config --global user.email test@example.invalid
git config --global user.name test
SRC="$HOME/.local/src/nothing-pmos"
REMOTE="$T/remote.git"
git init -q --bare -b main "$REMOTE"
git clone -q "$REMOTE" "$T/work" 2>/dev/null
cat >"$T/work/install.sh" <<STUB
#!/bin/sh
echo "\$(git -C "\$(dirname "\$0")" rev-parse --short HEAD)" >>"$T/installs"
STUB
git -C "$T/work" add install.sh
git -C "$T/work" commit -q -m one
git -C "$T/work" push -q origin HEAD:main
commit() { echo "$1" >"$T/work/f"; git -C "$T/work" add f; git -C "$T/work" commit -q -m "$1"; git -C "$T/work" push -q origin HEAD:main; }
run() { NOTHING_PMOS_REPO="${1:-$REMOTE}" sh "$S" >"$T/out" 2>&1; }
installs() { [ -e "$T/installs" ] && wc -l <"$T/installs" || echo 0; }
head_of() { git -C "$1" rev-parse --short HEAD 2>/dev/null; }

# --- fresh phone, GitHub unreachable: nothing to install
run "$T/no-such.git"
rc=$?
[ "$rc" != 0 ] && ok "fresh, unreachable -> fails" || no "fresh, unreachable -> fails"
[ "$(installs)" = 0 ] && ok "fresh, unreachable -> install.sh not run" || no "fresh, unreachable -> install.sh not run"
[ "$(git -C "$SRC" config receive.denyCurrentBranch)" = updateInstead ] &&
    ok "fresh clone accepts a push from the dev box" || no "fresh clone accepts a push from the dev box"

# --- fresh phone, GitHub reachable: cloned and installed
rm -rf "$SRC"
run
rc=$?
[ "$rc" = 0 ] && ok "fresh -> succeeds" || no "fresh -> succeeds (rc $rc: $(cat "$T/out"))"
[ "$(head_of "$SRC")" = "$(head_of "$T/work")" ] && ok "fresh -> at GitHub's main" || no "fresh -> at GitHub's main"
[ "$(installs)" = 1 ] && ok "fresh -> install.sh run" || no "fresh -> install.sh run ($(installs))"
[ -z "$(git -C "$SRC" status --porcelain)" ] && ok "fresh -> clean tree" || no "fresh -> clean tree"

# --- GitHub moved on: fast-forward
commit two
run
[ "$(head_of "$SRC")" = "$(head_of "$T/work")" ] && ok "new commit -> fast-forwarded" || no "new commit -> fast-forwarded"
[ "$(tail -1 "$T/installs")" = "$(head_of "$T/work")" ] && ok "install.sh runs the new commit" || no "install.sh runs the new commit"

# --- GitHub unreachable later: install what the clone has
before=$(head_of "$SRC")
run "$T/no-such.git"
rc=$?
[ "$rc" = 0 ] && ok "unreachable -> succeeds with the clone" || no "unreachable -> succeeds with the clone (rc $rc)"
[ "$(head_of "$SRC")" = "$before" ] && ok "unreachable -> clone unchanged" || no "unreachable -> clone unchanged"

# --- the clone has a commit GitHub lacks (pushed from the dev box): kept
echo local >"$SRC/g"; git -C "$SRC" add g; git -C "$SRC" commit -q -m local
commit three
ahead=$(head_of "$SRC")
run
rc=$?
[ "$rc" = 0 ] && ok "diverged -> still installs" || no "diverged -> still installs (rc $rc)"
[ "$(head_of "$SRC")" = "$ahead" ] && ok "diverged -> never reset" || no "diverged -> never reset"
grep -q WARNING "$T/out" && ok "diverged -> warns" || no "diverged -> warns"
git -C "$SRC" reset -q --hard "$(head_of "$T/work")"

# --- local changes: refused, nothing touched
n=$(installs)
echo dirty >>"$SRC/install.sh"
run
rc=$?
[ "$rc" != 0 ] && ok "local changes -> refused" || no "local changes -> refused"
[ "$(installs)" = "$n" ] && ok "local changes -> install.sh not run" || no "local changes -> install.sh not run"
git -C "$SRC" checkout -q -- install.sh

# --- another branch: refused, not switched
git -C "$SRC" checkout -q -b other
run
rc=$?
[ "$rc" != 0 ] && ok "other branch -> refused" || no "other branch -> refused"
[ "$(git -C "$SRC" symbolic-ref --short HEAD)" = other ] && ok "other branch -> not switched" || no "other branch -> not switched"
git -C "$SRC" checkout -q main

# --- a push from the dev box still lands in the clone
commit four
git -C "$T/work" push -q "$SRC" HEAD:main 2>/dev/null
[ "$(head_of "$SRC")" = "$(head_of "$T/work")" ] && ok "push from the dev box lands" || no "push from the dev box lands"

# --- a Xiaomi Pad 6 runs pipa/install.sh, never the phone's install.sh
mkdir -p "$T/work/pipa"
cat >"$T/work/pipa/install.sh" <<STUB
#!/bin/sh
echo pipa >>"$T/pipa-installs"
STUB
git -C "$T/work" add pipa/install.sh
git -C "$T/work" commit -q -m pipa
git -C "$T/work" push -q origin HEAD:main
printf 'xiaomi,pipa\0qcom,sm8250\0' >"$T/compatible"
n=$(installs)
NOTHING_PMOS_DT="$T/compatible" run
rc=$?
[ "$rc" = 0 ] && ok "pipa -> succeeds" || no "pipa -> succeeds (rc $rc: $(cat "$T/out"))"
[ "$(cat "$T/pipa-installs" 2>/dev/null)" = pipa ] && ok "pipa -> pipa/install.sh run" || no "pipa -> pipa/install.sh run"
[ "$(installs)" = "$n" ] && ok "pipa -> phone install.sh not run" || no "pipa -> phone install.sh not run"

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
