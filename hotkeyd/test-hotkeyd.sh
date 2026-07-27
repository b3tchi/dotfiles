#!/usr/bin/env bash
# Runtime suite for hotkeyd (sp020). Task 2 (dotfiles-yvxs) covers the bind
# table + loader + --check; Tasks 3-4 extend this file with layer-engine,
# socket and grab cases.
#
# Bash rather than nushell per adr0002 condition 1 — this must run on a fresh
# box and in CI before any dotfiles link step has happened.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# --- stage 1: loader unit suite -------------------------------------------
echo "stage 1: bind table loader (pytest)"
if ! command -v python3 >/dev/null; then
    bad "python3 missing"
else
    out="$(cd "$HERE" && python3 -m pytest test_binds.py -q 2>&1)"
    if [ $? -eq 0 ]; then
        ok "loader suite ($(printf '%s' "$out" | tail -1))"
    else
        bad "loader suite"
        printf '%s\n' "$out" | tail -20
    fi
fi

# --- stage 2: --check contract on the shipped table ------------------------
echo "stage 2: --check on the shipped table"
if out="$(python3 "$HERE/hotkeyd.py" --check 2>&1)"; then
    ok "exits 0: $out"
else
    bad "shipped table does not validate: $out"
fi

# --- stage 3: --check rejects a seeded duplicate, naming the chord ---------
echo "stage 3: --check rejects a seeded fault"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/faulty.py" <<EOF
import sys; sys.path.insert(0, "$HERE")
from binds import Bind, Layer, enter_layer
BINDS = [Bind('Mod4+z', 'kill'), Bind('Mod4+z', 'nop dup'),
         Bind('Mod4+y', ''), Bind('Mod4+o', enter_layer('ghost'))]
LAYERS = {}
EOF
out="$(python3 "$HERE/hotkeyd.py" --check --binds "$TMP/faulty.py" 2>&1)"
rc=$?
if [ $rc -ne 0 ]; then
    ok "exits non-zero ($rc)"
else
    bad "faulty table validated clean — the validator is not load-bearing"
fi
for token in 'Mod4+z' 'Mod4+y' 'ghost'; do
    if printf '%s' "$out" | grep -q -- "$token"; then
        ok "names $token"
    else
        bad "does not name $token (a bare non-zero exit is not actionable)"
    fi
done

# --- stage 4: validation needs no X ---------------------------------------
echo "stage 4: --check works with no DISPLAY"
if out="$(env -u DISPLAY python3 "$HERE/hotkeyd.py" --check 2>&1)"; then
    ok "headless: $out"
else
    bad "needs an X display: $out"
fi

# --- stage 5: the grab loop is honest about not existing yet --------------
echo "stage 5: running without --check reports unimplemented"
out="$(python3 "$HERE/hotkeyd.py" 2>&1)"
rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qi 'not implemented'; then
    ok "exits 2 and says so"
else
    bad "expected exit 2 + 'not implemented', got rc=$rc: $out"
fi

echo
printf 'hotkeyd: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
