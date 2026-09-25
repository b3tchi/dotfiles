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
#     invocation, as a regression guard on top of the redirection itself;
#   - asserts every systemctl call across every run names ONLY
#     xrdp-sesman-kwi3.service / xrdp-kwi3.service - never the stock
#     xrdp.service / xrdp-sesman.service carrying the i3 session on 3391
#     (kwi3-7m8.13 point 3, kwi3-7m8.14).
#
# It also pins the kwi3-7m8.14 routing fix in the COMMITTED files: the kwi3
# sesman.ini sets no non-default ListenPort (xrdp 0.10.6 can only dial
# /var/run/xrdp/sesman.socket), and both units bind a private /run/xrdp-kwi3
# over /run/xrdp, create it themselves and never remove it on stop.

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
TRACE_ALL="$STATE/trace-all"
mkdir -p "$BIN" "$FAKE_HOME/.dotfiles/kwi3" "$ETCROOT"
cp -a "$XRDP_SRC_REAL" "$FAKE_HOME/.dotfiles/kwi3/xrdp"
: > "$TRACE"
: > "$TRACE_ALL"

# The real /etc/xrdp-kwi3 legitimately EXISTS on a box where `rotz install
# kwi3` has run, so the sandbox check at the end compares it before and after
# rather than demanding that it be absent.
etc_fingerprint() {
  if [ -e /etc/xrdp-kwi3 ]; then
    find /etc/xrdp-kwi3 -printf '%p %s %T@ %i\n' 2>/dev/null | sort
  else
    echo absent
  fi
}
ETC_BEFORE="$(etc_fingerprint)"

# ---------------------------------------------------------------- the stubs
# FAIL_SUDO_INSTALL=1 makes `sudo install ...` fail the way a refused password
# or a read-only /etc would (kwi3-7m8.13 point 1): recorded, nothing written,
# exit 1.
cat > "$BIN/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$TRACE"
if [ "${FAIL_SUDO_INSTALL:-0}" = 1 ] && [ "$1" = install ]; then
  echo "sudo: a password is required" >&2
  exit 1
fi
exec "$@"
EOF
# Every systemctl call from every run is ALSO appended to $TRACE_ALL, which is
# never truncated, so the stock-unit guard at the end sees all of them.
cat > "$BIN/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$TRACE"
printf 'systemctl %s\n' "$*" >> "$TRACE_ALL"
exit 0
EOF
chmod +x "$BIN/sudo" "$BIN/systemctl"

# --------------------------------------------------- extract the real text
FRAGMENT="$STATE/step4.sh"
yq -r '.linux.installs.cmd' "$DOT_YAML" \
  | sed -n '/^# 4\. This BOX'"'"'s own kwi3 xrdp listener/,$p' \
  > "$FRAGMENT"
[ -s "$FRAGMENT" ] || { echo "test-xrdp-install: extracted fragment is empty - has the marker comment moved?" >&2; exit 2; }

run_step4() {   # extra VAR=value arguments are passed into the environment
  env -i \
    HOME="$FAKE_HOME" \
    PATH="$BIN:/usr/bin:/bin" \
    TRACE="$TRACE" \
    TRACE_ALL="$TRACE_ALL" \
    KWI3_XRDP_ETC_ROOT="$ETCROOT" \
    "$@" \
    bash "$FRAGMENT"
}

# The restart step 4 must run when a file changed, and must not run when
# nothing did (kwi3-7m8.14): a running unit keeps the mount namespace - and
# the sesman.ini inode it bound - that it was started with.
RESTART_RE='^systemctl restart xrdp-sesman-kwi3\.service xrdp-kwi3\.service$'

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
grep -q '^systemctl enable xrdp-sesman-kwi3.service xrdp-kwi3.service$' "$TRACE" \
  && ok "first install: enable ran with both units, sesman first" \
  || bad "first install: enable missing or wrong argument order"
grep -qE "$RESTART_RE" "$TRACE" \
  && ok "first install: restart named both kwi3 units (restart also starts a stopped unit)" \
  || bad "first install: no restart of the two kwi3 units"

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
grep -q '^systemctl restart' "$TRACE" \
  && bad "second install: restarted with nothing changed - that drops live kwi3 sessions for nothing" \
  || ok "second install: nothing changed, nothing restarted"

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
grep -qE "$RESTART_RE" "$TRACE" \
  && ok "local-edit repair: the kwi3 units were restarted to pick the repaired sesman.ini up" \
  || bad "local-edit repair: sesman.ini changed but the kwi3 units were not restarted"

# ============================ a failed sudo install is reported, not "wrote"
# kwi3-7m8.13 point 1: the old copy_if_changed printed "wrote" and set
# XRDP_CHANGED after a sudo that had failed.
printf '\n; another local edit\n' >> "$KE/xrdp.ini"
: > "$TRACE"
run_step4 FAIL_SUDO_INSTALL=1 > "$STATE/fail.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && ok "failed install: step 4 exits non-zero ($rc)" \
  || bad "failed install: step 4 exited 0 after sudo install failed"
grep -q 'kwi3-xrdp: wrote' "$STATE/fail.out" \
  && bad "failed install: still printed 'wrote' for a file it did not write" \
  || ok "failed install: no 'wrote' line"
grep -q 'kwi3-xrdp: FAILED to install .*xrdp.ini' "$STATE/fail.out" \
  && ok "failed install: the failure is named with the file" \
  || bad "failed install: the failure was not reported by name"
grep -qE '^systemctl (daemon-reload|restart|enable)' "$TRACE" \
  && bad "failed install: went on to daemon-reload/enable/restart on a half-written install" \
  || ok "failed install: no daemon-reload, enable or restart after the failure"
: > "$TRACE"
run_step4 > /dev/null 2>&1
cmp -s "$KE/xrdp.ini" "$XRDP_SRC_REAL/xrdp.ini" \
  && ok "failed install: the next good run repairs it" \
  || bad "failed install: the next good run did not repair xrdp.ini"

# =================== the committed files carry the kwi3-7m8.14 routing fix
# xrdp 0.10.6 always dials XRDP_SOCKET_ROOT_PATH/sesman.socket: its
# xrdp_mm_get_sesman_port() keeps a sesman.ini ListenPort only when atoi()
# gives 1..64999, and scp_port_to_unix_domain_path() maps every positive
# integer to "sesman.socket". A kwi3 sesman on any OTHER socket name is
# unreachable from xrdp-kwi3, which then reattaches the i3 session instead.
SI="$XRDP_SRC_REAL/sesman.ini"
lp=$(awk '/^[ \t]*\[/ { sect = $0; next }
          sect ~ /^[ \t]*\[Globals\]/ && /^[ \t]*ListenPort[ \t]*=/ {
            sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit }' "$SI")
case "$lp" in
  ""|sesman.socket) ok "kwi3 sesman.ini sets no non-default ListenPort (got '${lp:-<none>}')" ;;
  *) bad "kwi3 sesman.ini sets ListenPort='$lp' - xrdp 0.10.6 can never reach a sesman there" ;;
esac
for u in xrdp-kwi3.service xrdp-sesman-kwi3.service; do
  UF="$XRDP_SRC_REAL/$u"
  grep -qx 'BindPaths=/run/xrdp-kwi3:/run/xrdp' "$UF" \
    && ok "$u binds the private /run/xrdp-kwi3 over /run/xrdp" \
    || bad "$u lacks BindPaths=/run/xrdp-kwi3:/run/xrdp"
  grep -qx 'RuntimeDirectory=xrdp-kwi3' "$UF" \
    && ok "$u creates /run/xrdp-kwi3 itself (RuntimeDirectory=xrdp-kwi3)" \
    || bad "$u lacks RuntimeDirectory=xrdp-kwi3 - BindPaths would fail on a fresh boot"
  grep -qx 'RuntimeDirectoryPreserve=yes' "$UF" \
    && ok "$u never removes /run/xrdp-kwi3 on stop (RuntimeDirectoryPreserve=yes)" \
    || bad "$u lacks RuntimeDirectoryPreserve=yes - stopping it would delete the other unit's sockets"
  grep -qE '^(PrivateTmp|ProtectSystem|TemporaryFileSystem)=' "$UF" \
    && bad "$u privatises /tmp - the two sesmen would stop seeing each other's /tmp/.X11-unix displays" \
    || ok "$u leaves /tmp shared (display-number collision avoidance)"
done
grep -qx 'BindPaths=/etc/xrdp-kwi3/sesman.ini:/etc/xrdp/sesman.ini' "$XRDP_SRC_REAL/xrdp-sesman-kwi3.service" \
  && ok "xrdp-sesman-kwi3 still binds its sesman.ini (chansrv reads /etc/xrdp/sesman.ini by literal path)" \
  || bad "xrdp-sesman-kwi3 lost its sesman.ini bind - KWI3_SESSION=1 would not reach the session"

# ==================================================== never touches /etc
if grep -qE '(^| )/etc/xrdp(/| |$)' "$TRACE"; then
  bad "nothing in any sudo/systemctl call ever named the real /etc/xrdp"
else
  ok "nothing in any sudo/systemctl call ever named the real /etc/xrdp"
fi
if [ "$(etc_fingerprint)" = "$ETC_BEFORE" ]; then
  ok "the real /etc/xrdp-kwi3 is exactly as it was before the test"
else
  bad "the real /etc/xrdp-kwi3 changed - this test wrote outside its sandbox"
fi

# ====================================== never names the STOCK xrdp units
# kwi3-7m8.13 point 3 / kwi3-7m8.14: across EVERY run above, every argument of
# every systemctl call is either the verb, a flag, or one of the two kwi3
# units. xrdp.service / xrdp-sesman.service carry Jan's live i3 session on
# 3391 and must never be restarted, reloaded, stopped or even enabled here.
stray=$(awk '{ for (i = 3; i <= NF; i++)
                 if ($i !~ /^-/ && $i != "xrdp-kwi3.service" && $i != "xrdp-sesman-kwi3.service")
                   print $i }' "$TRACE_ALL")
n_sc=$(grep -c '^systemctl ' "$TRACE_ALL" || true)
if [ -n "$stray" ]; then
  bad "a systemctl call named something other than the two kwi3 units: $(echo "$stray" | sort -u | tr '\n' ' ')"
elif [ "$n_sc" -lt 5 ]; then
  bad "stock-unit guard saw only $n_sc systemctl calls - TRACE_ALL is not recording"
else
  ok "all $n_sc systemctl calls named only the kwi3 units (never xrdp.service / xrdp-sesman.service)"
fi

echo
echo "test-xrdp-install: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
