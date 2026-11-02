#!/usr/bin/env node
// kwi3-titlebar.js - Windows non-client metrics that make a captioned
// window's titlebar + top frame exactly one kwi3 module row (kwi3-9mcs).
// Used by kwi3-titlebar.sh; the derivation is pure and runs anywhere node does.
//
//   node kwi3-titlebar.js plan --metrics <ncm.json> (--config <config.js> [--source <text>] | --restore)
//   node kwi3-titlebar.js describe --metrics <ncm.json>
//
// <ncm.json> is `ncm.ps1 read`'s line. `plan` prints `before:`, `target:`,
// `values: <border>,<caption>,<padded>,<font>` and `change: yes|no`;
// `describe` prints one line for the metrics as they are.
//
// ONE SOURCE: the module height is read by RUNNING kwi3's config.js with
// kwi3.host "win32", by winterm/kwi3-fragment.js's evaluate() - the same run
// that gives Windows Terminal its cell - never restated here.
//
// THE GEOMETRY (96 dpi, Windows 11 22631; M = MEASURED on Jan's machine,
// D = derived from those):
//   inset = client top - DWM extended-frame top of a WS_CAPTION window
//         = SM_CYCAPTION + SM_CYSIZEFRAME + SM_CXPADDEDBORDER          (M)
//   SM_CYCAPTION   = iCaptionHeight + 1                               (M)
//   SM_CYSIZEFRAME = iBorderWidth + 3 (4 at iBorderWidth 1)  (M at 1 only)
//   iBorderWidth >= 1: Windows will not take 0                       (M)
//   31 at the defaults 1/22/4, 21 at 1/16/0                           (M)
//   AdjustWindowRectExForDpi(WS_OVERLAPPEDWINDOW, 96).top is -inset:
//     -21 read on the fitted machine; ncm.ps1 prints it as "inset"    (M)
// So with border 1 and padded 0, caption = moduleH - 5 (16 for 21).    (D)
//
// THE CAPTION FLOOR: Windows raises iCaptionHeight to the caption font's
// GDI tmHeight + 2. M: with lfCaptionFont -12 (Segoe UI, tmHeight 15) a
// caption of 16 became 17; with -11 (tmHeight 13) 16 was kept. The "+ 2"
// is fixed by the -12 point alone; -11 only agrees with it (any floor up to
// 16 would). It is also Wine's rule (win32u normalize_nonclientmetrics:
// iCaptionHeight = max(iCaptionHeight, 2 + tm.tmHeight)) - D, not M, for
// every other font. tmHeight itself is MEASURED per machine: ncm.ps1 asks
// GDI for the caption face and weight at -6..-16, so another face, or a
// font change, is handled without a table here.
// The font: the biggest lfHeight from Windows' own -12 down to -8 (8 px,
// no smaller is readable) whose floor fits the caption. Never above -12.
//
// Exit: 0 printed; 1 cannot be derived (no module, nothing fits); 2 usage.
'use strict';

const fs = require('fs');
const path = require('path');

const DEFAULTS = Object.freeze({ border: 1, caption: 22, padded: 4, font: -12 });
const SIZEFRAME_OVER_BORDER = 3;
const CAPTION_OVER_FONT = 2;
const SMALLEST_FONT = -8;
const DPI = 96;

function inset(v) {
    return (v.caption + 1) + (v.border + SIZEFRAME_OVER_BORDER) + v.padded;
}

function captionFloor(fonts, lf) {
    const f = fonts.find(x => x.lf === lf);
    if (!f || !Number.isInteger(f.tm)) throw new Error('no tmHeight measured for caption font ' + lf);
    return f.tm + CAPTION_OVER_FONT;
}

function derive(moduleH, fonts) {
    if (!Number.isInteger(moduleH) || moduleH <= 0) throw new Error('module height ' + moduleH + ' is not a positive integer');
    const border = 1, padded = 0;
    const caption = moduleH - 1 - (border + SIZEFRAME_OVER_BORDER) - padded;
    if (caption < 1) throw new Error('module height ' + moduleH + ' is too small for any caption');
    for (let lf = DEFAULTS.font; lf <= SMALLEST_FONT; lf++) {
        if (captionFloor(fonts, lf) <= caption) return { border, caption, padded, font: lf };
    }
    throw new Error('no caption font of ' + -SMALLEST_FONT + ' px or more fits a ' + caption +
        ' px caption (module height ' + moduleH + ')');
}

function values(v) { return [v.border, v.caption, v.padded, v.font].join(','); }

function describe(m) {
    return 'border ' + m.border + ', caption ' + m.caption + ', padded ' + m.padded +
        ', caption font ' + m.font + (m.face ? ' (' + m.face + ')' : '') +
        ': titlebar + top frame ' + (m.inset !== undefined ? m.inset : inset(m)) + ' px';
}

function plan(m, o) {
    if (m.dpi !== DPI) {
        throw new Error('system dpi is ' + m.dpi + '; these metrics are worked out and measured at ' + DPI + ' dpi only');
    }
    const target = o.restore ? Object.assign({}, DEFAULTS) : derive(o.moduleH, m.fonts);
    return { target, change: values(target) !== values(m) };
}

function moduleFromConfig(file) {
    const { evaluate } = require(path.join(__dirname, '..', 'winterm', 'kwi3-fragment.js'));
    const s = evaluate(file);
    const mod = s.module;
    if (!Array.isArray(mod) || mod.length !== 2 || !mod.every(n => Number.isInteger(n) && n > 0)) {
        throw new Error(file + ' sets no module [w, h] for kwi3.host "win32"');
    }
    return mod[1];
}

function main() {
    const argv = process.argv.slice(2);
    const verb = argv.shift();
    const o = {};
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        const next = () => { if (i + 1 >= argv.length) usage(a + ' needs a value'); return argv[++i]; };
        if (a === '--metrics') o.metrics = next();
        else if (a === '--config') o.config = next();
        else if (a === '--source') o.source = next();
        else if (a === '--restore') o.restore = true;
        else usage('unknown argument: ' + a);
    }
    if (!o.metrics || !['plan', 'describe'].includes(verb)) usage();
    let m;
    try { m = JSON.parse(fs.readFileSync(o.metrics, 'utf8')); }
    catch (e) { die(1, 'cannot read metrics ' + o.metrics + ': ' + e.message); }
    if (verb === 'describe') { console.log(describe(m)); return; }
    if (!o.restore === !o.config) usage('plan needs --config or --restore');
    try {
        const p = o.restore ? plan(m, { restore: true })
            : plan(m, { moduleH: moduleFromConfig(o.config) });
        const mh = o.restore ? null : inset(p.target);
        console.log('before: ' + describe(m));
        console.log('target: ' + describe(p.target) + (o.restore
            ? ' (Windows\' defaults)'
            : ' = one module row of ' + (o.source || o.config) + ' (module height ' + mh + ')'));
        console.log('values: ' + values(p.target));
        console.log('change: ' + (p.change ? 'yes' : 'no'));
    } catch (e) {
        die(1, e && e.message ? e.message : String(e));
    }
}

function die(code, msg) { process.stderr.write('kwi3-titlebar: ' + msg + '\n'); process.exit(code); }
function usage(msg) {
    die(2, (msg ? msg + '\n' : '') +
        'usage: kwi3-titlebar.js plan --metrics <ncm.json> (--config <config.js> [--source <text>] | --restore)\n' +
        '       kwi3-titlebar.js describe --metrics <ncm.json>');
}

module.exports = { DEFAULTS, inset, captionFloor, derive, describe, plan, values, moduleFromConfig };
if (require.main === module) main();
