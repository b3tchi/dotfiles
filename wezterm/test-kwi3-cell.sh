#!/usr/bin/env bash
# test-kwi3-cell.sh - install-kwi3-cell.sh against a PRIVATE %USERPROFILE%,
# %LOCALAPPDATA% and %APPDATA%, with fonts this test writes itself
# (kwi3-wv1u).
#
#   wezterm/test-kwi3-cell.sh
#
# Every run makes its own directory under the Windows %TEMP% and hands it to
# the script as USERPROFILE/LOCALAPPDATA/APPDATA through WSLENV, the way the
# script reads them; the real profile is never written (each case checks the
# script named the private directory). The fonts are minimal TrueType files
# built here (only the tables the metrics come from), so no installed font
# decides a case. Needs WSL interop and node.
# Exit 0 all passed, 1 a failure, 77 no interop/node (a skip, never a pass).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/install-kwi3-cell.sh"
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
ROOT_W="$win_tmp\\kwi3-wezcell-$$"
ROOT="$(wslpath -u "$win_tmp")/kwi3-wezcell-$$"
mkdir -p "$ROOT"
trap 'rm -rf "$ROOT"' EXIT

# mkfont <file> <family> <subfamily> <upem> <hheaAsc> <hheaDesc> <hheaGap>
#        <typoAsc> <typoDesc> <typoGap> <advance>
# A TrueType file with head, hhea, maxp, hmtx, cmap (format 4: U+0020..U+007E
# -> glyph 1), name (ids 1, 2 in the Windows platform) and OS/2.
mkfont() {
    node - "$@" <<'JS'
const [file, family, sub, upem, ha, hd, hg, ta, td, tg, adv] = process.argv.slice(2);
const n = s => Number(s);
const u16 = v => { const b = Buffer.alloc(2); b.writeUInt16BE(v & 0xffff); return b; };
const i16 = v => { const b = Buffer.alloc(2); b.writeInt16BE(v); return b; };
const u32 = v => { const b = Buffer.alloc(4); b.writeUInt32BE(v >>> 0); return b; };
const cat = a => Buffer.concat(a);
const head = cat([u32(0x00010000), u32(0), u32(0), u32(0x5F0F3CF5), u16(0), u16(n(upem)),
    Buffer.alloc(16), i16(0), i16(0), i16(0), i16(0), u16(0), u16(8), i16(2), i16(0), i16(0)]);
const hhea = cat([u32(0x00010000), i16(n(ha)), i16(n(hd)), i16(n(hg)), u16(n(adv)),
    i16(0), i16(0), i16(0), i16(1), i16(0), i16(0), Buffer.alloc(8), i16(0), u16(2)]);
const maxp = cat([u32(0x00005000), u16(2)]);
const hmtx = cat([u16(n(adv)), i16(0), u16(n(adv)), i16(0)]);
// cmap format 4, two segments: 0x20..0x7E -> 1 (delta), and the 0xFFFF end.
const seg = cat([u16(4), u16(0), u16(0), u16(4), u16(4), u16(1), u16(0),
    u16(0x7E), u16(0xFFFF), u16(0), u16(0x20), u16(0xFFFF),
    i16(1 - 0x20), i16(1), u16(0), u16(0)]);
seg.writeUInt16BE(seg.length, 2);
const cmap = cat([u16(0), u16(1), u16(3), u16(1), u32(12), seg]);
const enc = s => { const b = Buffer.from(s, 'utf16le'); b.swap16(); return b; };
const s1 = enc(family), s2 = enc(sub);
const name = cat([u16(0), u16(2), u16(6 + 24),
    u16(3), u16(1), u16(0x409), u16(1), u16(s1.length), u16(0),
    u16(3), u16(1), u16(0x409), u16(2), u16(s2.length), u16(s1.length), s1, s2]);
const os2 = Buffer.alloc(78);
os2.writeUInt16BE(4, 0); os2.writeUInt16BE(sub === 'Bold' ? 700 : 400, 4);
os2.writeUInt16BE(sub === 'Bold' ? 0x20 : 0x40, 62);
os2.writeInt16BE(n(ta), 68); os2.writeInt16BE(n(td), 70); os2.writeInt16BE(n(tg), 72);
os2.writeUInt16BE(Math.max(n(ta), 0), 74); os2.writeUInt16BE(Math.max(-n(td), 0), 76);
const tabs = [['OS/2', os2], ['cmap', cmap], ['head', head], ['hhea', hhea], ['hmtx', hmtx],
    ['maxp', maxp], ['name', name]];
let off = 12 + 16 * tabs.length;
const dir = [], body = [];
for (const [tag, data] of tabs) {
    const pad = Buffer.alloc((4 - data.length % 4) % 4);
    dir.push(Buffer.from(tag, 'latin1'), u32(0), u32(off), u32(data.length));
    body.push(data, pad);
    off += data.length + pad.length;
}
require('fs').writeFileSync(file, cat([u32(0x00010000), u16(tabs.length), u16(0), u16(0), u16(0), ...dir, ...body]));
JS
}

# run <case> [args...]: the script with this case's private UP/LAD/AD.
run() {
    local c="$1"; shift
    mkdir -p "$ROOT/$c/up" "$ROOT/$c/lad" "$ROOT/$c/ad"
    env USERPROFILE="$ROOT_W\\$c\\up" LOCALAPPDATA="$ROOT_W\\$c\\lad" APPDATA="$ROOT_W\\$c\\ad" \
        WSLENV="USERPROFILE:LOCALAPPDATA:APPDATA${EXTRA_WSLENV:+:$EXTRA_WSLENV}" \
        "$SCRIPT" "$@" >"$ROOT/$c.out" 2>"$ROOT/$c.err"
    echo $? >"$ROOT/$c.rc"
}
rc()   { cat "$ROOT/$1.rc"; }
cell() { echo "$ROOT/$1/up/.config/wezterm/kwi3-cell.lua"; }
# field <file> <key>: the value of `\t<key> = <value>,` in the Lua table.
field() { sed -n "s/^\t$2 = \(.*\),\$/\1/p" "$1"; }

# A config.js shaped like the dotfiles one: Linux values at the top, the
# Windows font in the win32 branch, a rule, and a relative include whose
# module wins (set later).
mkconfig() {
    mkdir -p "$ROOT/$1/ad/kwi3/sub"
    cat >"$ROOT/$1/ad/kwi3/config.js" <<EOF2
kwi3.set({ font: 'Iosevka 16', module: [9, 18] });
if (kwi3.host === 'win32') {
    kwi3.set({ font: '${2:-Kwi3 Test Mono} 16', workspaceLayout: 'tabbed' });
    kwi3.onWindowAdded({ title: /^kwi3-run\$/ }, w => { w.float(); });
}
kwi3.include("sub\\\\mod.js");
EOF2
    echo "kwi3.set({ module: [8, 21] });" >"$ROOT/$1/ad/kwi3/sub/mod.js"
}

FONTS="$ROOT/fonts"
mkdir -p "$FONTS"
# IosevkaTerm Nerd Font's own numbers (upem 1000, hhea 965/-285/0, advance
# 500): natural cell 8 x 20 px at 16 px. A Bold of the family with another
# advance sorts first by name; the Regular must win.
mkfont "$FONTS/a-bold.ttf" "Kwi3 Test Mono" Bold 1000 965 -285 0 965 -285 0 600
mkfont "$FONTS/b-regular.ttf" "Kwi3 Test Mono" Regular 1000 965 -285 0 965 -285 0 500
# Other numbers: upem 2048, height 1900+500 = 2400, advance 1229.
mkfont "$FONTS/other.ttf" "Kwi3 Other" Regular 2048 1900 -500 0 1900 -500 0 1229
# hhea ascender and descender both 0: FreeType takes OS/2's typo metrics.
mkfont "$FONTS/typo.ttf" "Kwi3 Typo" Regular 1000 0 0 0 800 -200 100 500
FONTS_W="$ROOT_W\\fonts"

echo "== A: the host's config.js, its include, the font file"
mkconfig a
run a --font-dir "$FONTS_W"
F="$(cell a)"
check "A1 exit 0" '[ "$(rc a)" = 0 ]'
check "A2 written in the PRIVATE USERPROFILE" '[ -f "$F" ] && grep -qF "kwi3-wezcell-$$" "$ROOT/a.out"'
check "A3 family from the win32 branch" '[ "$(field "$F" font_family)" = "\"Kwi3 Test Mono\"" ]'
check "A4 font_size 12 pt (16 px at 96 dpi)" '[ "$(field "$F" font_size)" = 12 ]'
# By hand: natural 500*16/1000 = 8 x 1250*16/1000 = 20 px; the multipliers
# aim at the module minus half a pixel: 7.5/8 and 20.5/20.
check "A5 cell_width 0.9375, line_height 1.025 (8x21 from 8x20, the Regular's advance)" \
    '[ "$(field "$F" cell_width)" = 0.9375 ] && [ "$(field "$F" line_height)" = 1.025 ]'
check "A6 module 8x21 from the include" '[ "$(field "$F" module)" = "{ 8, 21 }" ]'
check "A7 no BOM, a Lua table" '[ "$(head -c2 "$F")" = "--" ] && grep -q "^return {" "$F" && [ "$(tail -1 "$F")" = "}" ]'

echo "== B: a second run is a no-op"
m1="$(stat -c %Y.%i "$F")"
sleep 1
run a --font-dir "$FONTS_W"
check "B1 exit 0, says unchanged" '[ "$(rc a)" = 0 ] && grep -q unchanged "$ROOT/a.out"'
check "B2 file untouched" '[ "$(stat -c %Y.%i "$F")" = "$m1" ]'

echo "== C: --dry-run writes nothing"
mkconfig c
run c --font-dir "$FONTS_W" --dry-run
check "C1 exit 0 and the table on stdout" '[ "$(rc c)" = 0 ] && grep -q "^return {" "$ROOT/c.out"'
check "C2 nothing written" '[ ! -e "$ROOT/c/up/.config" ]'

echo "== D: no config.js is refused"
run d --font-dir "$FONTS_W"
check "D1 exit 2 naming the path" '[ "$(rc d)" = 2 ] && grep -qF "kwi3\\config.js" "$ROOT/d.err"'
check "D2 nothing written" '[ ! -e "$ROOT/d/up/.config" ]'

echo "== E: a font in none of the directories"
mkconfig e "No Such Mono"
run e --font-dir "$FONTS_W"
check "E1 exit 1 naming the family" '[ "$(rc e)" = 1 ] && grep -q "No Such Mono" "$ROOT/e.err"'
check "E2 nothing written" '[ ! -e "$ROOT/e/up/.config" ]'

echo "== F: other metrics, another font size and module"
mkdir -p "$ROOT/f/ad/kwi3"
echo "kwi3.set({font: 'Kwi3 Other 14', module: [9, 18]});" >"$ROOT/f/ad/kwi3/config.js"
run f --font-dir "$FONTS_W"
F="$(cell f)"
# By hand: natural 1229*14/2048 = 8.4013671875 x 2400*14/2048 = 16.40625 px;
# 8.5/8.4013671875 = 1.0117400906... and 17.5/16.40625 = 1.06666...; 14 px = 10.5 pt.
check "F1 10.5 pt, 1.01174..., 1.06666..." \
    '[ "$(rc f)" = 0 ] && [ "$(field "$F" font_size)" = 10.5 ] &&
     [ "$(field "$F" cell_width)" = 1.01174009067 ] && [ "$(field "$F" line_height)" = 1.06666666667 ]'

echo "== G: hhea with no ascender/descender takes OS/2's typo metrics"
mkdir -p "$ROOT/g/ad/kwi3"
echo "kwi3.set({font: 'Kwi3 Typo 16', module: [8, 21]});" >"$ROOT/g/ad/kwi3/config.js"
run g --font-dir "$FONTS_W"
# By hand: (800+200+100)*16/1000 = 17.6 px; 20.5/17.6 = 1.16477...
check "G1 line_height from typo metrics" '[ "$(rc g)" = 0 ] && [ "$(field "$(cell g)" line_height)" = 1.16477272727 ]'

echo "== H: no --font-dir: %LOCALAPPDATA%\\Microsoft\\Windows\\Fonts is searched"
mkconfig h
mkdir -p "$ROOT/h/lad/Microsoft/Windows/Fonts"
cp "$FONTS/b-regular.ttf" "$ROOT/h/lad/Microsoft/Windows/Fonts/"
run h --dry-run
check "H1 found in the private user font directory" '[ "$(rc h)" = 0 ] && grep -q "b-regular.ttf" "$ROOT/h.out"'

echo "== I: --config and %KWI3_CONFIG% win over %APPDATA%"
mkconfig i
mkdir -p "$ROOT/i/alt"
echo "kwi3.set({font: 'Kwi3 Other 14', module: [9, 18]});" >"$ROOT/i/alt/config.js"
run i --font-dir "$FONTS_W" --config "$ROOT/i/alt/config.js" --dry-run
check "I1 --config (a Linux path)" '[ "$(rc i)" = 0 ] && grep -q "Kwi3 Other" "$ROOT/i.out"'
KWI3_CONFIG="$ROOT_W\\i\\alt\\config.js" EXTRA_WSLENV=KWI3_CONFIG run i --font-dir "$FONTS_W" --dry-run
check "I2 %KWI3_CONFIG% (a Windows path)" '[ "$(rc i)" = 0 ] && grep -q "Kwi3 Other" "$ROOT/i.out"'

echo "== J: a font/module change rewrites the file"
mkconfig j
run j --font-dir "$FONTS_W"
echo "kwi3.set({ module: [9, 21] });" >"$ROOT/j/ad/kwi3/sub/mod.js"
run j --font-dir "$FONTS_W"
check "J1 rewritten with the new module" '[ "$(rc j)" = 0 ] && grep -q wrote "$ROOT/j.out" && [ "$(field "$(cell j)" module)" = "{ 9, 21 }" ]'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
