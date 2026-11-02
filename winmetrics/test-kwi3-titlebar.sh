#!/usr/bin/env bash
# test-kwi3-titlebar.sh - kwi3-titlebar.sh's flow against a STUB ncm
# ($KWI3_TITLEBAR_NCM): the real metrics are never written (kwi3-9mcs).
#
#   winmetrics/test-kwi3-titlebar.sh
#
# The stub keeps its metrics in a file under a private temp dir and logs
# every `set`. The derivation itself is test-kwi3-titlebar.js's. One case
# runs the REAL ncm.ps1 `read` (read-only: SPI_GETNONCLIENTMETRICS, GDI text
# metrics, AdjustWindowRectExForDpi) and one the default config.js lookup
# with a private %APPDATA% through WSLENV; both need WSL interop.
# Exit 0 all passed, 1 a failure, 77 no node (a skip, never a pass).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/kwi3-titlebar.sh"
CMD=/mnt/c/Windows/System32/cmd.exe
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

command -v node >/dev/null && command -v wslpath >/dev/null && [ -x "$CMD" ] \
    || { echo "SKIP: needs WSL interop and node"; exit 77; }

PASS=0
FAIL=0
ok()   { echo "  PASS $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# The stub ncm: state "border caption padded font dpi" in $STUB_STATE.
cat >"$ROOT/ncm" <<'EOF'
#!/usr/bin/env bash
read -r b c p f d <"$STUB_STATE"
case "$1" in
read)
    node -e '
const [b, c, p, f, d] = process.argv.slice(1).map(Number);
const tm = { "-6": 8, "-7": 10, "-8": 11, "-9": 12, "-10": 12, "-11": 13, "-12": 15, "-13": 17, "-14": 19, "-15": 20, "-16": 21 };
console.log(JSON.stringify({ dpi: d, border: b, caption: c, padded: p, font: f, face: "Segoe UI", weight: 400,
  smCyCaption: c + 1, smCySizeFrame: b + 3, inset: (c + 1) + (b + 3) + p,
  fonts: Object.keys(tm).map(k => ({ lf: Number(k), tm: tm[k] })) }));' "$b" "$c" "$p" "$f" "$d"
    ;;
set)
    echo "set $2" >>"$STUB_LOG"
    IFS=, read -r b c p f <<<"$2"
    # Windows' caption floor (tmHeight + 2) when STUB_CLAMP: -12 -> 17.
    if [ -n "${STUB_CLAMP:-}" ] && [ "$f" = -12 ] && [ "$c" -lt 17 ]; then c=17; fi
    echo "$b $c $p $f $d" >"$STUB_STATE"
    ;;
esac
EOF
chmod +x "$ROOT/ncm"

mkdir -p "$ROOT/cfg"
cat >"$ROOT/cfg/config.js" <<'EOF'
kwi3.set({ module: [9, 18] });
if (kwi3.host === 'win32') kwi3.include("sub\\mod.js");
EOF
mkdir -p "$ROOT/cfg/sub"
echo "kwi3.set({ module: [8, 21] });" >"$ROOT/cfg/sub/mod.js"
echo "kwi3.set({ module: [8, 19] });" >"$ROOT/cfg/m19.js"

# run <case> <state> [args...]
run() {
    local c="$1" s="$2"; shift 2
    echo "$s" >"$ROOT/$c.state"
    : >"$ROOT/$c.log"
    STUB_STATE="$ROOT/$c.state" STUB_LOG="$ROOT/$c.log" KWI3_TITLEBAR_NCM="$ROOT/ncm" \
        "$SCRIPT" "$@" >"$ROOT/$c.out" 2>"$ROOT/$c.err"
    echo $? >"$ROOT/$c.rc"
}
rc()  { cat "$ROOT/$1.rc"; }
out() { cat "$ROOT/$1.out" "$ROOT/$1.err"; }
sets() { wc -l <"$ROOT/$1.log" | tr -d ' '; }

STOCK="1 22 4 -12 96"
FITTED="1 16 0 -11 96"

echo "== apply on a stock machine"
run apply "$STOCK" --config "$ROOT/cfg/config.js"
check "exit 0" '[ "$(rc apply)" = 0 ]'
check "one set, 1,16,0,-11" '[ "$(cat "$ROOT/apply.log")" = "set 1,16,0,-11" ]'
check "before printed (31 px)" 'out apply | grep -q "^before: border 1, caption 22, padded 4, caption font -12 (Segoe UI): titlebar + top frame 31 px"'
check "target printed (21 px, module height 21)" 'out apply | grep -q "^target: .*titlebar + top frame 21 px = one module row of .*module height 21"'
check "after printed (21 px)" 'out apply | grep -q "^after:  border 1, caption 16, padded 0, caption font -11 (Segoe UI): titlebar + top frame 21 px"'
check "state is now fitted" '[ "$(cat "$ROOT/apply.state")" = "$FITTED" ]'

echo "== idempotent"
run again "$FITTED" --config "$ROOT/cfg/config.js"
check "exit 0" '[ "$(rc again)" = 0 ]'
check "no change said" 'out again | grep -q "no change"'
check "nothing set" '[ "$(sets again)" = 0 ]'
check "before and target both printed" 'out again | grep -q "^before:" && out again | grep -q "^target:"'

echo "== --dry-run"
run dry "$STOCK" --config "$ROOT/cfg/config.js" --dry-run
check "exit 0" '[ "$(rc dry)" = 0 ]'
check "nothing set" '[ "$(sets dry)" = 0 ]'
check "says what it would set" 'out dry | grep -q "would set border,caption,padded,font = 1,16,0,-11; nothing written"'
check "no after line" '! out dry | grep -q "^after:"'

echo "== another module (19 -> -10)"
run m19 "$STOCK" --config "$ROOT/cfg/m19.js"
check "set 1,14,0,-10" '[ "$(rc m19)" = 0 ] && [ "$(cat "$ROOT/m19.log")" = "set 1,14,0,-10" ]'

echo "== --restore"
run restore "$FITTED" --restore
check "exit 0, set 1,22,4,-12" '[ "$(rc restore)" = 0 ] && [ "$(cat "$ROOT/restore.log")" = "set 1,22,4,-12" ]'
check "after 31 px" 'out restore | grep -q "^after:  .*titlebar + top frame 31 px"'
run restore2 "$STOCK" --restore
check "restore on stock: no change, nothing set" '[ "$(rc restore2)" = 0 ] && [ "$(sets restore2)" = 0 ] && out restore2 | grep -q "no change"'
run restoredry "$FITTED" --restore --dry-run
check "restore --dry-run sets nothing" '[ "$(rc restoredry)" = 0 ] && [ "$(sets restoredry)" = 0 ]'

echo "== Windows does not take it"
# A derivation that kept -12 with a 16 caption: the stub clamps to 17.
cat >"$ROOT/clampwrap" <<EOF
#!/usr/bin/env bash
if [ "\$1" = set ]; then exec "$ROOT/ncm" set 1,16,0,-12; fi
exec "$ROOT/ncm" "\$@"
EOF
chmod +x "$ROOT/clampwrap"
echo "$STOCK" >"$ROOT/clamp.state"; : >"$ROOT/clamp.log"
STUB_CLAMP=1 STUB_STATE="$ROOT/clamp.state" STUB_LOG="$ROOT/clamp.log" KWI3_TITLEBAR_NCM="$ROOT/clampwrap" \
    "$SCRIPT" --config "$ROOT/cfg/config.js" >"$ROOT/clamp.out" 2>"$ROOT/clamp.err"; echo $? >"$ROOT/clamp.rc"
check "exit 1, naming what Windows took" '[ "$(rc clamp)" = 1 ] && grep -q "Windows took 1,17,0,-12, not 1,16,0,-11" "$ROOT/clamp.err"'

echo "== refusals"
run dpi "1 22 4 -12 120" --config "$ROOT/cfg/config.js"
check "120 dpi: exit 2, nothing set" '[ "$(rc dpi)" = 2 ] && [ "$(sets dpi)" = 0 ] && out dpi | grep -q "96 dpi"'
run nocfg "$STOCK" --config "$ROOT/cfg/none.js"
check "missing config.js: exit 2, named" '[ "$(rc nocfg)" = 2 ] && out nocfg | grep -q "REFUSED - no kwi3 config.js at $ROOT/cfg/none.js"'
echo "kwi3.set({ font: 'X 16' });" >"$ROOT/cfg/nomod.js"
run nomod "$STOCK" --config "$ROOT/cfg/nomod.js"
check "config.js without module: exit 1, nothing set" '[ "$(rc nomod)" = 1 ] && [ "$(sets nomod)" = 0 ] && out nomod | grep -q "sets no module"'
echo "kwi3.set({ module: [8, 17] });" >"$ROOT/cfg/m17.js"
run m17 "$STOCK" --config "$ROOT/cfg/m17.js"
check "module 17: exit 1, nothing set" '[ "$(rc m17)" = 1 ] && [ "$(sets m17)" = 0 ] && out m17 | grep -q "no caption font"'
run both "$STOCK" --restore --config "$ROOT/cfg/config.js"
check "--restore with --config: exit 2" '[ "$(rc both)" = 2 ] && [ "$(sets both)" = 0 ]'
run badarg "$STOCK" --bogus
check "unknown argument: exit 2" '[ "$(rc badarg)" = 2 ]'

echo "== default config.js: private %APPDATA% through WSLENV"
win_tmp="$(env -C /mnt/c "$CMD" /d /c 'echo %TEMP%' | tr -d '\r')"
AD_W="$win_tmp\\kwi3-titlebar-$$"
AD="$(wslpath -u "$win_tmp")/kwi3-titlebar-$$"
mkdir -p "$AD/kwi3/sub"
cp "$ROOT/cfg/config.js" "$AD/kwi3/config.js"
cp "$ROOT/cfg/sub/mod.js" "$AD/kwi3/sub/mod.js"
echo "$STOCK" >"$ROOT/def.state"; : >"$ROOT/def.log"
env -u KWI3_CONFIG APPDATA="$AD_W" WSLENV="APPDATA" STUB_STATE="$ROOT/def.state" STUB_LOG="$ROOT/def.log" \
    KWI3_TITLEBAR_NCM="$ROOT/ncm" "$SCRIPT" --dry-run >"$ROOT/def.out" 2>"$ROOT/def.err"; echo $? >"$ROOT/def.rc"
check "reads the private %APPDATA%\\kwi3\\config.js" '[ "$(rc def)" = 0 ] && grep -qF "one module row of $AD_W\\kwi3\\config.js (module height 21)" "$ROOT/def.out"'
rm -rf "$AD"

echo "== the real ncm.ps1 read (read-only)"
real="$(env -C /mnt/c "$PS" -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$HERE/ncm.ps1")" read | tr -d '\r')"
echo "$real" >"$ROOT/real.json"
check "parses, its inset is caption+1 + border+3 + padded, SM_CYCAPTION is caption+1" 'node -e "
const t = require(process.argv[1]); const m = JSON.parse(require(\"fs\").readFileSync(process.argv[2], \"utf8\"));
process.exit(m.inset === t.inset(m) && m.smCyCaption === m.caption + 1 && m.smCySizeFrame === m.border + 3 ? 0 : 1);" "$HERE/kwi3-titlebar.js" "$ROOT/real.json"'
check "the current caption font fits its floor (Windows enforced it)" 'node -e "
const t = require(process.argv[1]); const m = JSON.parse(require(\"fs\").readFileSync(process.argv[2], \"utf8\"));
process.exit(t.captionFloor(m.fonts, m.font) <= m.caption ? 0 : 1);" "$HERE/kwi3-titlebar.js" "$ROOT/real.json"'
for a in "set 1,2" "set 1,16,x,-11" "bogus"; do
    env -C /mnt/c "$PS" -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$HERE/ncm.ps1")" $a >/dev/null 2>&1
    r=$?
    check "ncm.ps1 $a: usage, exit 2 (before any SPI call)" '[ "$r" = 2 ]'
done

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
