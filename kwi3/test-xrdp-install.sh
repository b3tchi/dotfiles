#!/usr/bin/env bash
# test-xrdp-install.sh - kwi3/dot.yaml's step 4 (the kwi3 xrdp listener
# install, kwi3-7m8.7), with no root and nothing under /etc touched.
#
#   kwi3/test-xrdp-install.sh
#
# ---------------------------------------------------------------------------
# WHY THIS EXTRACTS THE REAL SCRIPT RATHER THAN RESTATING IT
# ---------------------------------------------------------------------------
# The text under test is read straight out of kwi3/dot.yaml with `yq`, from
# the "# 4. This BOX's own kwi3 xrdp listener" marker to the end of the cmd
# block - the exact same characters `rotz install kwi3` would run. A test
# that hand-copied the logic into a second script would drift the moment
# either one changed and prove nothing about the other.
#
# ---------------------------------------------------------------------------
# WHAT IS STUBBED, AND WHY
# ---------------------------------------------------------------------------
#   sudo        a pass-through: `exec "$@"` after recording the call. There
#               is no root in this sandbox and none is needed - every path
#               under test is redirected (below) into a throwaway directory
#               this script owns.
#   systemctl   a pure recorder, exit 0. This is the one command that must
#               NEVER be allowed to reach the real systemd - `daemon-reload`
#               and `enable --now` against the live user/system manager
#               would be exactly the live-system change kwi3-7m8.7's hard
#               safety rules forbid an agent from making.
#   install     NOT stubbed. GNU install run against a path under $ETCROOT
#               (a mktemp -d) is an ordinary, harmless file copy; stubbing
#               it too would remove the one command whose actual effect
#               (a file landing on disk, or not) is what criterion 5's
#               idempotence claim is about. `cmp`, `mkdir`, `dirname` are
#               real for the same reason.
#   akm-root    absent. PATH below excludes ~/.local/bin, so the block's
#               `command -v akm-root` check fails exactly as it would on a
#               box that has never installed the akm tooling, and DOTROOT
#               falls back to $HOME/.dotfiles - which this test points at a
#               fake home containing the real kwi3/xrdp/* files (copied,
#               not symlinked, so the destination-vs-source `cmp` in
#               copy_if_changed is a real content comparison).
#
# ---------------------------------------------------------------------------
# SAFETY
# ---------------------------------------------------------------------------
#   - never runs as root and never asks to; PATH is scoped to this script's
#     stub dir plus a minimal system PATH for cmp/install/mkdir/dirname/cat;
#   - $KWI3_XRDP_ETC_ROOT is the only place any file is written, and it is
#     mktemp -d'd fresh and removed on exit;
#   - asserts nothing under the real /etc was ever named in a sudo/install
#     invocation, as a regression guard on top of the redirection itself.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOT_YAML="$REPO_ROOT/kwi3/dot.yaml"
XRDP_SRC_REAL="$REPO_ROOT/kwi3/xrdp"

command -v yq >/dev/null 2>&1 || { echo "test-xrdp-install: needs yq" >&2; exit 2; }
[ -r "$DOT_YAML" ] || { echo "test-xrdp-install: missing $DOT_YAML" >&2; exit 2; }
for f in xrdp.ini sesman.ini xrdp-kwi3.service xrdp-sesman-kwi3.service; do
  [ -r "$XRDP_SRC_REAL/$f" ] || { echo "test-xrdp-install: missing $XRDP_SRC_REAL/$f" >&2; exit 2; }
done

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

STATE="$(mktemp -d "${TMPDIR:-/tmp}/kwi3-xrdp-install-test.XXXXXX")"
trap 'rm -rf "$STATE"' EXIT

BIN="$STATE/bin"
FAKE_HOME="$STATE/home"
ETCROOT="$STATE/etc"
TRACE="$STATE/trace"
mkdir -p "$BIN" "$FAKE_HOME/.dotfiles/kwi3" "$ETCROOT"
cp -a "$XRDP_SRC_REAL" "$FAKE_HOME/.dotfiles/kwi3/xrdp"
: > "$TRACE"

# ---------------------------------------------------------------- the stubs
cat > "$BIN/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$TRACE"
exec "$@"
EOF
cat > "$BIN/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$TRACE"
exit 0
EOF
chmod +x "$BIN/sudo" "$BIN/systemctl"

# --------------------------------------------------- extract the real text
FRAGMENT="$STATE/step4.sh"
yq -r '.linux.installs.cmd' "$DOT_YAML" \
  | sed -n '/^# 4\. This BOX'"'"'s own kwi3 xrdp listener/,$p' \
  > "$FRAGMENT"
[ -s "$FRAGMENT" ] || { echo "test-xrdp-install: extracted fragment is empty - has the marker comment moved?" >&2; exit 2; }

run_step4() {
  env -i \
    HOME="$FAKE_HOME" \
    PATH="$BIN:/usr/bin:/bin" \
    TRACE="$TRACE" \
    KWI3_XRDP_ETC_ROOT="$ETCROOT" \
    bash "$FRAGMENT"
}

# ============================================================ first install
: > "$TRACE"
run_step4
rc=$?
check "$rc" "0" "first install: step 4 exits 0"

KE="$ETCROOT/xrdp-kwi3"
UD="$ETCROOT/systemd/system"
for f in "$KE/xrdp.ini" "$KE/sesman.ini" "$UD/xrdp-kwi3.service" "$UD/xrdp-sesman-kwi3.service"; do
  [ -f "$f" ] && ok "first install: wrote $f" || bad "first install: missing $f"
done
if [ -f "$KE/xrdp.ini" ]; then
  if cmp -s "$KE/xrdp.ini" "$XRDP_SRC_REAL/xrdp.ini"; then
    ok "first install: installed xrdp.ini matches the committed source byte-for-byte"
  else
    bad "first install: installed xrdp.ini differs from the committed source"
  fi
fi

n_install=$(grep -c '^sudo install ' "$TRACE" || true)
check "$n_install" "4" "first install: exactly 4 sudo install calls (one per file)"
grep -q '^systemctl daemon-reload' "$TRACE" \
  && ok "first install: daemon-reload ran (unit files changed)" \
  || bad "first install: daemon-reload did not run"
grep -q '^systemctl enable --now xrdp-sesman-kwi3.service xrdp-kwi3.service' "$TRACE" \
  && ok "first install: enable --now ran with both units, sesman first" \
  || bad "first install: enable --now missing or wrong argument order"

# ================================================== second install: no-op
: > "$TRACE"
run_step4
rc=$?
check "$rc" "0" "second install: step 4 exits 0"

n_install2=$(grep -c '^sudo install ' "$TRACE" || true)
check "$n_install2" "0" "second install: zero sudo install calls - nothing changed, nothing written"
grep -q '^systemctl daemon-reload' "$TRACE" \
  && bad "second install: daemon-reload ran again with nothing changed" \
  || ok "second install: daemon-reload correctly skipped"
grep -q '^systemctl enable --now xrdp-sesman-kwi3.service xrdp-kwi3.service' "$TRACE" \
  && ok "second install: enable --now still ran (idempotent no-op on an already-active unit)" \
  || bad "second install: enable --now missing on the second run"

for f in "$KE/xrdp.ini" "$KE/sesman.ini" "$UD/xrdp-kwi3.service" "$UD/xrdp-sesman-kwi3.service"; do
  h1=$(cmp -s "$f" "$FAKE_HOME/.dotfiles/kwi3/xrdp/$(basename "$f")" && echo same || echo diff)
  check "$h1" "same" "second install: $f content still matches the source"
done

# ======================================= edge case: local edit is repaired
printf '\n; local edit that should be overwritten\n' >> "$KE/sesman.ini"
: > "$TRACE"
run_step4
rc=$?
check "$rc" "0" "local-edit repair: step 4 exits 0"
n_install3=$(grep -c '^sudo install ' "$TRACE" || true)
check "$n_install3" "1" "local-edit repair: exactly 1 sudo install call (only sesman.ini differed)"
grep -q "sudo install .*$KE/sesman.ini" "$TRACE" \
  && ok "local-edit repair: the one install named sesman.ini" \
  || bad "local-edit repair: the install call did not name sesman.ini"
if cmp -s "$KE/sesman.ini" "$XRDP_SRC_REAL/sesman.ini"; then
  ok "local-edit repair: sesman.ini restored to the committed content"
else
  bad "local-edit repair: sesman.ini was not restored"
fi
n_install_xrdpini=$(grep -c "sudo install .*$KE/xrdp.ini" "$TRACE" || true)
check "$n_install_xrdpini" "0" "local-edit repair: xrdp.ini (unedited) was NOT rewritten"

# ==================================================== never touches /etc
if grep -qE '(^| )/etc/xrdp(/| |$)' "$TRACE"; then
  bad "nothing in any sudo/systemctl call ever named the real /etc/xrdp"
else
  ok "nothing in any sudo/systemctl call ever named the real /etc/xrdp"
fi
if [ -e /etc/xrdp-kwi3 ]; then
  bad "the real /etc/xrdp-kwi3 exists - this test wrote outside its sandbox"
else
  ok "the real /etc/xrdp-kwi3 was never created"
fi

echo
echo "test-xrdp-install: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
