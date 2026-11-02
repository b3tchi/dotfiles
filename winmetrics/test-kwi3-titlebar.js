#!/usr/bin/env node
// test-kwi3-titlebar.js - kwi3-titlebar.js's derivation, pure: no Windows,
// no metrics read or written (kwi3-9mcs). `node winmetrics/test-kwi3-titlebar.js`
// Exit 0 all passed, 1 a failure.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const t = require('./kwi3-titlebar.js');

let pass = 0, fail = 0;
function check(name, cond, detail) {
    if (cond) { pass++; console.log('  PASS ' + name); }
    else { fail++; console.log('  FAIL ' + name + (detail ? ' - ' + detail : '')); }
}
function throws(fn, re) {
    try { fn(); } catch (e) { return re.test(e.message) ? true : e.message; }
    return false;
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// GDI's tmHeight for Segoe UI 400 at lfHeight -6..-16, MEASURED on Jan's
// machine (96 dpi, Windows 11 22631) by `ncm.ps1 read`.
const SEGOE = [[-6, 8], [-7, 10], [-8, 11], [-9, 12], [-10, 12], [-11, 13],
    [-12, 15], [-13, 17], [-14, 19], [-15, 20], [-16, 21]].map(([lf, tm]) => ({ lf, tm }));

// Windows' caption floor, from the two measured points: -12 asked for 16
// and got 17 (= 15 + 2); -11 took 16 (13 + 2 = 15 <= 16).
check('floor -12 is 17 (measured clamp)', t.captionFloor(SEGOE, -12) === 17);
check('floor -11 is 15 (16 measured accepted)', t.captionFloor(SEGOE, -11) <= 16);
check('floor of an unmeasured size refuses',
    throws(() => t.captionFloor(SEGOE, -30), /no tmHeight/) === true);

// The inset Windows draws above the client: SM_CYCAPTION (caption + 1) +
// SM_CYSIZEFRAME (border + 3) + padded. 31 at the defaults, 21 fitted -
// both MEASURED (client top - DWM frame top).
check('inset of the defaults is 31', t.inset(t.DEFAULTS) === 31);
check('inset of Jan\'s fitted values is 21',
    t.inset({ border: 1, caption: 16, padded: 0, font: -11 }) === 21);

// derive(moduleH, fonts): border 1, padded 0, caption = moduleH - 5, and
// the biggest caption font not above Windows' own -12 whose floor fits.
const d21 = t.derive(21, SEGOE);
check('module 21 -> Jan\'s hand-fitted 1/16/0/-11',
    eq(d21, { border: 1, caption: 16, padded: 0, font: -11 }), JSON.stringify(d21));
check('module 21 -> inset 21', t.inset(d21) === 21);
for (const h of [18, 19, 20, 21, 22, 24, 31, 40]) {
    const d = t.derive(h, SEGOE);
    check('module ' + h + ' -> inset ' + h + ', floor fits',
        t.inset(d) === h && t.captionFloor(SEGOE, d.font) <= d.caption, JSON.stringify(d));
}
check('module 22 keeps the -12 default font (17 = floor)', t.derive(22, SEGOE).font === -12);
check('module 20 -> -11', t.derive(20, SEGOE).font === -11);
check('module 19 -> -10 (12 + 2 = 14)', t.derive(19, SEGOE).font === -10);
check('module 18 -> -8, the smallest font allowed', t.derive(18, SEGOE).font === -8);
check('module 31 never grows the font past -12', t.derive(31, SEGOE).font === -12);
check('module 17 refused: no font of 8 px or more fits a 12 px caption',
    throws(() => t.derive(17, SEGOE), /no caption font/) === true);
check('module 4 refused', throws(() => t.derive(4, SEGOE), /no caption font|too small/) === true);
check('a non-integer module refused', throws(() => t.derive(21.5, SEGOE), /module height/) === true);
// A face 2 px taller everywhere (-11 floor 17): the font shrinks one more.
const TALL = SEGOE.map(f => ({ lf: f.lf, tm: f.tm + 2 }));
check('a taller face (-11 floor 17) shrinks to -10 for module 21', t.derive(21, TALL).font === -10,
    JSON.stringify(t.derive(21, TALL)));

// plan(): what kwi3-titlebar.sh prints and does.
const jan = { dpi: 96, border: 1, caption: 16, padded: 0, font: -11, face: 'Segoe UI',
    weight: 400, smCyCaption: 17, smCySizeFrame: 4, inset: 21, fonts: SEGOE };
let p = t.plan(jan, { moduleH: 21 });
check('Jan\'s machine, module 21: no change', p.change === false && eq(p.target, d21));
const stock = Object.assign({}, jan, { caption: 22, padded: 4, font: -12, smCyCaption: 23, inset: 31 });
p = t.plan(stock, { moduleH: 21 });
check('stock machine, module 21: change to 1/16/0/-11', p.change === true && eq(p.target, d21));
p = t.plan(jan, { restore: true });
check('restore from fitted: change to 1/22/4/-12', p.change === true && eq(p.target, t.DEFAULTS));
p = t.plan(stock, { restore: true });
check('restore on stock: no change', p.change === false);
check('a border above 1 is put back to 1',
    t.plan(Object.assign({}, jan, { border: 2 }), { moduleH: 21 }).change === true);
check('not 96 dpi refused', throws(() => t.plan(Object.assign({}, jan, { dpi: 120 }), { moduleH: 21 }),
    /96 dpi/) === true);
check('restore at 120 dpi refused too',
    throws(() => t.plan(Object.assign({}, jan, { dpi: 120 }), { restore: true }), /96 dpi/) === true);
check('describe() says the inset', /titlebar \+ top frame 21 px/.test(t.describe(jan)));

// moduleFromConfig(): config.js RUN as kwi3-fragment.js runs it (win32 host,
// includes followed, later set() winning).
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kwi3-titlebar-'));
try {
    fs.mkdirSync(path.join(dir, 'sub'));
    fs.writeFileSync(path.join(dir, 'config.js'),
        "kwi3.set({ module: [9, 18] });\n" +
        "if (kwi3.host === 'win32') kwi3.include('sub\\\\mod.js');\n");
    fs.writeFileSync(path.join(dir, 'sub', 'mod.js'), 'kwi3.set({ module: [8, 21] });\n');
    check('module from a config.js with a win32 include', t.moduleFromConfig(path.join(dir, 'config.js')) === 21);
    fs.writeFileSync(path.join(dir, 'nomod.js'), "kwi3.set({ font: 'Iosevka 16' });\n");
    check('a config.js with no module refused',
        throws(() => t.moduleFromConfig(path.join(dir, 'nomod.js')), /no module/) === true);
    fs.writeFileSync(path.join(dir, 'throws.js'), "throw new Error('boom');\n");
    check('a throwing config.js refused',
        throws(() => t.moduleFromConfig(path.join(dir, 'throws.js')), /boom/) === true);
    // The CLI, end to end on a metrics file.
    const m = path.join(dir, 'm.json');
    fs.writeFileSync(m, JSON.stringify(stock));
    const out = execFileSync(process.execPath, [path.join(__dirname, 'kwi3-titlebar.js'),
        'plan', '--metrics', m, '--config', path.join(dir, 'config.js')], { encoding: 'utf8' });
    check('CLI plan prints values and change', /^values: 1,16,0,-11$/m.test(out) && /^change: yes$/m.test(out), out);
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}

// The dotfiles' own kwi3 config.js: 8x21 on win32 -> Jan's values.
const real = path.join(__dirname, '..', 'kwi3', 'config.js');
check('dotfiles kwi3/config.js -> module 21 -> 1/16/0/-11',
    eq(t.derive(t.moduleFromConfig(real), SEGOE), d21));

console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
