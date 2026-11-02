#!/usr/bin/env node
// kwi3-fragment.js - print the Windows Terminal JSON fragment that gives WT
// profiles kwi3's font and a character cell of exactly kwi3's module
// (kwi3-hoex.47). Used by install-kwi3-fragment.sh; runs anywhere node does.
//
//   node kwi3-fragment.js --config <config.js> [--guid {...}]... [--source <text>]
//
// ONE SOURCE: the font and the module are not written here. They are read by
// RUNNING the kwi3 config.js the Windows host runs, with `kwi3.host` reading
// "win32" (so its `if (kwi3.host === 'win32')` branch applies) and a stub
// `kwi3` that only records kwi3.set(). kwi3.include("<path>") is followed
// (relative to the including file; a `\\wsl.localhost\<distro>\...` or
// `\\wsl$\<distro>\...` path is read as the Linux path it names; a drive path
// `C:\...` as /mnt/c/...), as the host follows it. Settings merge per key,
// later kwi3.set() calls winning, as in core/config-api.js.
//
// THE MAPPING (Windows Terminal 1.24 source, release-1.24 branch):
//   kwi3 `font: '<family> <px>'` - px, core/defaults.js parseFont().
//   WT font.size is in POINTS: AtlasEngine::_resolveFontMetrics takes
//     fontSizeInPx = size / 72 * dpi, so size = px * 72 / 96 (12 for 16 px):
//     at 96 dpi the renderer gets the same 16 px em Qt draws kwi3's titlebar
//     with. (Every value here is exact at 96 dpi, Jan's monitor.)
//   WT font.cellWidth / font.cellHeight are CSSLengthPercentage strings
//     (src/renderer/base/CSSLengthPercentage.cpp): a bare number is a
//     multiple of the font size in px, "px"/"pt" are absolute (scaled by
//     dpi), "%" and "ch" also exist. The cell is round(value * fontSizeInPx).
//     We write the bare multiples module_w/px and module_h/px ("0.5" and
//     "1.3125" for 8x21 at 16 px): exactly 8 x 21 px at that size, and a
//     zoom (ctrl+=) grows the cell with the glyphs instead of cramming
//     bigger glyphs into an 8 x 21 box, which "8px"/"21px" would do. The
//     multiples are checked to round back to the module exactly.
//   padding "0" - WT's default is 8 px a side, which no grid of 8 x 21 holds.
//   scrollbarState "hidden" - a visible scrollbar takes width from the
//     terminal's columns.
//
// The fragment updates existing profiles by GUID ("updates"). WT applies an
// update only to a profile that exists (CascadiaSettingsSerialization.cpp
// _parseFragment: userSettings.profilesByGuid.find(updates)), so a GUID with
// no profile behind it is ignored. The GUIDs are the three stock/dynamic ones
// below (defaults.json's two, and Azure's - uuid5 of WT's namespace
// {2bde4a90-...} and "Azure Cloud Shell") plus every --guid given (install-kwi3-fragment.sh passes each GUID
// in the user's settings.json profiles.list).
//
// Exit: 0 printed; 1 config.js threw or its font/module cannot be mapped;
// 2 a usage error.
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const KNOWN_PROFILES = [
    '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}', // Windows PowerShell
    '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}', // Command Prompt
    '{b453ae62-4e3d-5e58-b989-0a998ec441b8}', // Azure Cloud Shell
];

function die(code, msg) {
    process.stderr.write('kwi3-fragment: ' + msg + '\n');
    process.exit(code);
}

function parseArgs(argv) {
    const o = { config: null, guids: [], source: null };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        const next = () => {
            if (i + 1 >= argv.length) die(2, a + ' needs a value');
            return argv[++i];
        };
        if (a === '--config') o.config = next();
        else if (a === '--guid') o.guids.push(next());
        else if (a === '--source') o.source = next();
        else die(2, 'unknown argument: ' + a);
    }
    if (!o.config) die(2, 'usage: kwi3-fragment.js --config <config.js> [--guid {...}]... [--source <text>]');
    return o;
}

// An include path as the Windows host would read it, mapped to a path this
// (Linux) process can open.
function resolveInclude(p, includer) {
    let m = /^\\\\(?:wsl\.localhost|wsl\$)\\[^\\]+(\\.*)$/i.exec(p);
    if (m) return m[1].replace(/\\/g, '/');
    m = /^([A-Za-z]):[\\/](.*)$/.exec(p);
    if (m) return '/mnt/' + m[1].toLowerCase() + '/' + m[2].replace(/\\/g, '/');
    const q = p.replace(/\\/g, '/');
    if (q.startsWith('/')) return q;
    return path.resolve(path.dirname(includer), q);
}

function evaluate(configPath) {
    const settings = {};
    const seen = new Set();
    const kwi3 = {
        set(s) {
            if (s && typeof s === 'object') Object.assign(settings, s);
        },
        onWindowAdded() {},
        grid: { snap: p => p, center: () => ({ x: 0, y: 0 }) },
        include(p) {
            if (typeof p !== 'string') throw new Error('kwi3.include: path is not a string');
            run(resolveInclude(p, current[current.length - 1]));
        },
    };
    Object.defineProperty(kwi3, 'host', { value: 'win32', enumerable: true });
    const ctx = vm.createContext({ kwi3, console });
    const current = [];
    function run(file) {
        const real = fs.realpathSync(file);
        if (seen.has(real)) return; // each file once, as the host does
        seen.add(real);
        const src = fs.readFileSync(real, 'utf8');
        current.push(real);
        try {
            vm.runInContext('(function () {\n' + src + '\n})();', ctx, { filename: real });
        } finally {
            current.pop();
        }
    }
    run(configPath);
    return settings;
}

function fmt(x) {
    // Shortest decimal that round-trips: 0.5, 1.3125, 0.5625 ...
    return String(Number(x.toPrecision(12)));
}

function main() {
    const o = parseArgs(process.argv.slice(2));
    let settings;
    try {
        settings = evaluate(o.config);
    } catch (e) {
        die(1, o.config + ': ' + (e && e.message ? e.message : e));
    }
    const fontRaw = settings.font;
    if (typeof fontRaw !== 'string') die(1, o.config + ' sets no font for kwi3.host "win32"');
    const parts = fontRaw.trim().split(/\s+/);
    const px = Number(parts[parts.length - 1]);
    if (parts.length < 2 || !/^[1-9][0-9]*$/.test(parts[parts.length - 1])) {
        die(1, 'font "' + fontRaw + '" is not "<family> <px>"');
    }
    const family = parts.slice(0, -1).join(' ');
    const mod = settings.module;
    if (!Array.isArray(mod) || mod.length !== 2 || !mod.every(n => Number.isInteger(n) && n > 0)) {
        die(1, o.config + ' sets no module [w, h] for kwi3.host "win32"');
    }
    const [mw, mh] = mod;
    const cellWidth = fmt(mw / px);
    const cellHeight = fmt(mh / px);
    // The renderer's own rounding (AtlasEngine: roundf(value * fontSizeInPx)).
    if (Math.round(Number(cellWidth) * px) !== mw || Math.round(Number(cellHeight) * px) !== mh) {
        die(1, 'cell ' + cellWidth + ' x ' + cellHeight + ' of ' + px + ' px does not round to ' + mw + 'x' + mh);
    }
    const size = px * 72 / 96;

    const guids = [];
    for (const g of KNOWN_PROFILES.concat(o.guids)) {
        if (!/^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$/.test(g)) {
            die(2, 'not a profile GUID: ' + g);
        }
        if (!guids.some(x => x.toLowerCase() === g.toLowerCase())) guids.push(g);
    }

    const frag = {
        '_kwi3': 'Generated by dotfiles winterm/install-kwi3-fragment.sh from ' +
            (o.source || o.config) + ' (font "' + fontRaw + '", module ' + mw + 'x' + mh +
            '): a cell of exactly ' + mw + 'x' + mh + ' px at 96 dpi. Do not edit; re-run the script.',
        profiles: guids.map(g => ({
            updates: g,
            font: { face: family, size: size, cellWidth: cellWidth, cellHeight: cellHeight },
            padding: '0',
            scrollbarState: 'hidden',
        })),
    };
    process.stdout.write(JSON.stringify(frag, null, 4) + '\n');
}

// winmetrics/kwi3-titlebar.js runs config.js the same way (kwi3-9mcs).
module.exports = { evaluate, resolveInclude };
if (require.main === module) main();
