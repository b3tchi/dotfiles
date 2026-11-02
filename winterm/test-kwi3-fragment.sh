#!/usr/bin/env bash
# test-kwi3-fragment.sh - install-kwi3-fragment.sh against a PRIVATE
# %LOCALAPPDATA% and %APPDATA% (kwi3-hoex.47).
#
#   winterm/test-kwi3-fragment.sh
#
# Every run makes its own directory under the Windows %TEMP% and hands it to
# the script as LOCALAPPDATA/APPDATA through WSLENV, the way the script reads
# them; the real profile is never read or written (each case checks the
# script named the private directory). Needs WSL interop and node.
# Exit 0 all passed, 1 a failure, 77 no interop/node (a skip, never a pass).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/install-kwi3-fragment.sh"
CMD=/mnt/c/Windows/System32/cmd.exe

command -v node >/dev/null && command -v wslpath >/dev/null && [ -x "$CMD" ] \
    || { echo "SKIP: needs WSL interop and node"; exit 77; }

PASS=0
FAIL=0
ok()   { echo "  PASS $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

win_tmp="$(env -C /mnt/c "$CMD" /d /c 'echo %TEMP%' | tr -d '\r')"
[ -n "$win_tmp" ] || { echo "cannot read %TEMP%"; exit 1; }
ROOT_W="$win_tmp\\kwi3-wtfrag-$$"
ROOT="$(wslpath -u "$win_tmp")/kwi3-wtfrag-$$"
mkdir -p "$ROOT"
trap 'rm -rf "$ROOT"' EXIT

# run <case> [args...]: the script with this case's private LAD/AD.
run() {
    local c="$1"; shift
    mkdir -p "$ROOT/$c/lad" "$ROOT/$c/ad"
    env LOCALAPPDATA="$ROOT_W\\$c\\lad" APPDATA="$ROOT_W\\$c\\ad" \
        WSLENV="LOCALAPPDATA:APPDATA${EXTRA_WSLENV:+:$EXTRA_WSLENV}" \
        "$SCRIPT" "$@" >"$ROOT/$c.out" 2>"$ROOT/$c.err"
    echo $? >"$ROOT/$c.rc"
}
rc()   { cat "$ROOT/$1.rc"; }
frag() { echo "$ROOT/$1/lad/Microsoft/Windows Terminal/Fragments/kwi3/kwi3-cell.json"; }
# jq-less JSON query: q <file> <js expression over `f`>
q() { node -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(eval(process.argv[2]))' "$1" "$2"; }

wt_settings() {  # a stock-shaped WT settings.json with a WSL profile
    local d="$ROOT/$1/lad/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState"
    mkdir -p "$d"
    cat >"$d/settings.json" <<'EOF'
{
    // a comment, as WT writes none but users do
    "defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
    "profiles": {
        "defaults": {},
        "list": [
            { "guid": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}", "name": "Windows PowerShell" },
            { "guid": "{3911d0f7-aa99-560f-9262-83b38d9253e6}", "name": "arch", "source": "Microsoft.WSL" }
        ]
    }
}
EOF
    echo "$d/settings.json"
}

# A config.js shaped like the dotfiles one: Linux values at the top, the
# Windows font in the win32 branch, a rule, and a relative include whose
# module wins (set later).
mkconfig() {
    mkdir -p "$ROOT/$1/ad/kwi3/sub"
    cat >"$ROOT/$1/ad/kwi3/config.js" <<'EOF'
kwi3.set({ font: 'Iosevka 16', module: [9, 18] });
if (kwi3.host === 'win32') {
    kwi3.set({ font: 'IosevkaTerm Nerd Font 16', workspaceLayout: 'tabbed' });
    kwi3.onWindowAdded({ title: /^kwi3-run$/ }, w => { w.float(); });
}
kwi3.include("sub\\mod.js");
EOF
    echo "kwi3.set({ module: [8, 21] });" >"$ROOT/$1/ad/kwi3/sub/mod.js"
}

echo "== A: the host's config.js, its include, the WT profiles"
mkconfig a
S="$(wt_settings a)"
sum_before="$(md5sum <"$S")"
run a
F="$(frag a)"
check "A1 exit 0" '[ "$(rc a)" = 0 ]'
check "A2 fragment written in the PRIVATE LOCALAPPDATA" '[ -f "$F" ] && grep -qF "kwi3-wtfrag-$$" "$ROOT/a.out"'
check "A3 face from the win32 branch" '[ "$(q "$F" "[...new Set(f.profiles.map(p=>p.font.face))].join()")" = "IosevkaTerm Nerd Font" ]'
check "A4 size 12 pt (16 px at 96 dpi)" '[ "$(q "$F" "[...new Set(f.profiles.map(p=>p.font.size))].join()")" = 12 ]'
check "A5 cell 0.5 x 1.3125 em = 8 x 21 px (module from the include)" \
    '[ "$(q "$F" "[...new Set(f.profiles.map(p=>p.font.cellWidth+\"x\"+p.font.cellHeight))].join()")" = 0.5x1.3125 ]'
check "A6 padding 0, scrollbar hidden on every profile" \
    '[ "$(q "$F" "f.profiles.every(p=>p.padding===\"0\"&&p.scrollbarState===\"hidden\")")" = true ]'
check "A7 profiles: the 3 stock + the WSL one from settings.json, once each" \
    '[ "$(q "$F" "f.profiles.map(p=>p.updates).join()")" = "{61c54bbd-c2c6-5271-96e7-009a87ff44bf},{0caa0dad-35be-5f56-a8ff-afceeeaa6101},{b453ae62-4e3d-5e58-b989-0a998ec441b8},{3911d0f7-aa99-560f-9262-83b38d9253e6}" ]'
check "A8 settings.json not written" '[ "$(md5sum <"$S")" = "$sum_before" ]'
check "A9 no BOM (WT reads UTF-8)" '[ "$(head -c1 "$F" | od -An -tx1 | tr -d " ")" = 7b ]'

echo "== B: a second run is a no-op"
m1="$(stat -c %Y.%i "$F")"
sleep 1
run a
check "B1 exit 0, says unchanged" '[ "$(rc a)" = 0 ] && grep -q unchanged "$ROOT/a.out"'
check "B2 file untouched" '[ "$(stat -c %Y.%i "$F")" = "$m1" ]'

echo "== C: --dry-run writes nothing"
mkconfig c
run c --dry-run
check "C1 exit 0 and the fragment on stdout" '[ "$(rc c)" = 0 ] && grep -q "\"updates\"" "$ROOT/c.out"'
check "C2 nothing written" '[ ! -e "$ROOT/c/lad/Microsoft" ]'

echo "== D: no config.js is refused"
run d
check "D1 exit 2 naming the path" '[ "$(rc d)" = 2 ] && grep -qF "kwi3\\config.js" "$ROOT/d.err"'
check "D2 nothing written" '[ ! -e "$ROOT/d/lad/Microsoft" ]'

echo "== E: a config.js that throws"
mkdir -p "$ROOT/e/ad/kwi3"
echo "kwi3.set({font: 'X 16', module: [8, 16]}); throw new Error('boom');" >"$ROOT/e/ad/kwi3/config.js"
run e
check "E1 exit 1 with the error" '[ "$(rc e)" = 1 ] && grep -q boom "$ROOT/e.err"'
check "E2 nothing written" '[ ! -e "$(frag e)" ]'

echo "== F: no win32 branch - the shared values, another module"
mkdir -p "$ROOT/f/ad/kwi3"
echo "kwi3.set({font: 'Iosevka 16', module: [9, 18]});" >"$ROOT/f/ad/kwi3/config.js"
run f
check "F1 Iosevka, 0.5625 x 1.125" \
    '[ "$(rc f)" = 0 ] && [ "$(q "$(frag f)" "f.profiles[0].font.face+\" \"+f.profiles[0].font.cellWidth+\"x\"+f.profiles[0].font.cellHeight")" = "Iosevka 0.5625x1.125" ]'

echo "== G: no font is refused"
mkdir -p "$ROOT/g/ad/kwi3"
echo "kwi3.set({module: [8, 21]});" >"$ROOT/g/ad/kwi3/config.js"
run g
check "G1 exit 1, nothing written" '[ "$(rc g)" = 1 ] && [ ! -e "$(frag g)" ]'

echo "== H: --config and %KWI3_CONFIG% win over %APPDATA%"
mkconfig h
mkdir -p "$ROOT/h/alt"
echo "kwi3.set({font: 'Alt Mono 20', module: [10, 25]});" >"$ROOT/h/alt/config.js"
run h --config "$ROOT/h/alt/config.js" --dry-run
check "H1 --config (a Linux path)" '[ "$(rc h)" = 0 ] && grep -q "Alt Mono" "$ROOT/h.out" && grep -q "\"size\": 15" "$ROOT/h.out"'
KWI3_CONFIG="$ROOT_W\\h\\alt\\config.js" EXTRA_WSLENV=KWI3_CONFIG run h --dry-run
check "H2 %KWI3_CONFIG% (a Windows path)" '[ "$(rc h)" = 0 ] && grep -q "Alt Mono" "$ROOT/h.out"'

echo "== I: a profile edit changes the fragment on the next run"
mkconfig i
S="$(wt_settings i)"
run i
sed 's/"name": "arch"/"name": "arch" }, { "guid": "{11111111-2222-3333-4444-555555555555}", "name": "new"/' "$S" >"$ROOT/i.json" && cat "$ROOT/i.json" >"$S"
run i
check "I1 rewritten with the new profile" \
    '[ "$(rc i)" = 0 ] && grep -q wrote "$ROOT/i.out" && grep -q 11111111-2222 "$(frag i)"'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
