#!/usr/bin/env node
// kwi3-cell.js - print the Lua table that gives WezTerm on Windows kwi3's
// font and a character cell of exactly kwi3's module (kwi3-wv1u). Used by
// install-kwi3-cell.sh; wezterm.lua loads the file it writes.
//
//   node kwi3-cell.js --config <config.js> --font-dir <dir>... [--source <text>]
//
// ONE SOURCE: config.js is RUN exactly as for the Windows Terminal fragment
// - winterm/kwi3-fragment.js's evaluate() and fontAndModule(), kwi3.host
// "win32", kwi3.include() followed - so both terminals and the Windows host
// read one file.
//
// THE MAPPING (WezTerm 20240203-110809-5046fc22):
//   kwi3 `font: '<family> <px>'` - px. WezTerm's font_size is in POINTS,
//     pixel size = font_size * dpi / 72 (wezterm-font ftwrap.rs
//     set_font_size), so font_size = px * 72 / 96 (12 for 16 px) at 96 dpi.
//   WezTerm has no absolute cell size: cell_width and line_height MULTIPLY
//     the font's natural cell, and the result is ceil()ed
//     (wezterm-gui utilsprites.rs RenderMetrics::new:
//     (natural * multiplier).ceil()). The natural cell is
//       width  = the widest advance among chars 32..127 (ftwrap.rs
//                cell_metrics()), scaled to px;
//       height = FreeType's face height (hhea ascender - descender +
//                lineGap; OS/2 typo, else win metrics, when hhea has
//                neither), scaled to px.
//     So the font FILE is read (sfnt.js), found by family in --font-dir.
//     The multipliers aim at (module - 0.5) px, the middle of the one
//     interval ceil() maps to the module: FreeType's own fixed-point scale
//     makes the natural height 20.0003 px, not 20, for Iosevka at 16 px -
//     a multiplier aimed at exactly 21 would ceil() to 22.
//
// Exit: 0 printed; 1 config.js threw, its font/module cannot be mapped, or
// the font is in none of the directories; 2 a usage error.
'use strict';

const fs = require('fs');
const path = require('path');
const { evaluate, fontAndModule } = require('../winterm/kwi3-fragment.js');
const sfnt = require('./sfnt.js');

function die(code, msg) {
    process.stderr.write('kwi3-cell: ' + msg + '\n');
    process.exit(code);
}

function parseArgs(argv) {
    const o = { config: null, dirs: [], source: null };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        const next = () => {
            if (i + 1 >= argv.length) die(2, a + ' needs a value');
            return argv[++i];
        };
        if (a === '--config') o.config = next();
        else if (a === '--font-dir') o.dirs.push(next());
        else if (a === '--source') o.source = next();
        else die(2, 'unknown argument: ' + a);
    }
    if (!o.config || o.dirs.length === 0) {
        die(2, 'usage: kwi3-cell.js --config <config.js> --font-dir <dir>... [--source <text>]');
    }
    return o;
}

// The file WezTerm's wezterm.font("<family>") picks: that family, Regular.
function findFont(family, dirs) {
    const want = family.toLowerCase();
    const hits = [];
    for (const d of dirs) {
        let ents;
        try {
            ents = fs.readdirSync(d);
        } catch (e) {
            continue;
        }
        for (const e of ents.sort()) {
            if (!/\.(ttf|otf|ttc)$/i.test(e)) continue;
            const p = path.join(d, e);
            let ns;
            try {
                ns = sfnt.namesOf(p);
            } catch (err) {
                continue;
            }
            ns.forEach((n, i) => {
                if (n.family.toLowerCase() === want || n.family1.toLowerCase() === want) {
                    hits.push({ path: p, index: i, regular: /^(regular|book|normal)$/i.test(n.subfamily) });
                }
            });
        }
    }
    hits.sort((a, b) => Number(b.regular) - Number(a.regular));
    if (!hits.length) return null;
    const h = hits[0];
    return { path: h.path, face: sfnt.parse(fs.readFileSync(h.path))[h.index] };
}

function faceHeight(f) {
    if (f.hheaAscender || f.hheaDescender) return f.hheaAscender - f.hheaDescender + f.hheaLineGap;
    if (f.os2 && (f.os2.typoAscender || f.os2.typoDescender)) {
        return f.os2.typoAscender - f.os2.typoDescender + f.os2.typoLineGap;
    }
    if (f.os2) return f.os2.winAscent + f.os2.winDescent;
    return 0;
}

function fmt(x) {
    return String(Number(x.toPrecision(12)));
}

function luaString(s) {
    return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"';
}

function main() {
    const o = parseArgs(process.argv.slice(2));
    let fm;
    try {
        fm = fontAndModule(evaluate(o.config), o.config);
    } catch (e) {
        die(1, o.config + ': ' + (e && e.message ? e.message : e));
    }
    const { fontRaw, family, px, mw, mh } = fm;
    const font = findFont(family, o.dirs);
    if (!font) die(1, 'no font of family "' + family + '" in ' + o.dirs.join(', '));
    const f = font.face;
    const natW = f.asciiAdvance * px / f.upem;
    const natH = faceHeight(f) * px / f.upem;
    if (!(natW > 0) || !(natH > 0)) die(1, font.path + ': no usable advance or height');
    const cellWidth = fmt((mw - 0.5) / natW);
    const lineHeight = fmt((mh - 0.5) / natH);
    if (Math.ceil(Number(cellWidth) * natW) !== mw || Math.ceil(Number(lineHeight) * natH) !== mh) {
        die(1, 'multipliers ' + cellWidth + ' x ' + lineHeight + ' do not ceil to ' + mw + 'x' + mh);
    }
    const lua = [
        '-- Generated by dotfiles wezterm/install-kwi3-cell.sh from ' + (o.source || o.config),
        '-- (font "' + fontRaw + '", module ' + mw + 'x' + mh + '; natural cell ' + fmt(natW) + 'x' +
            fmt(natH) + ' px of ' + path.basename(font.path) + '):',
        '-- a cell of exactly ' + mw + 'x' + mh + ' px at 96 dpi. Do not edit; re-run the script.',
        'return {',
        '\tfont_family = ' + luaString(family) + ',',
        '\tfont_size = ' + fmt(px * 72 / 96) + ',',
        '\tcell_width = ' + cellWidth + ',',
        '\tline_height = ' + lineHeight + ',',
        '\tmodule = { ' + mw + ', ' + mh + ' },',
        '}',
    ];
    process.stdout.write(lua.join('\n') + '\n');
}

main();
