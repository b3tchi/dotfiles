// sfnt.js - the few numbers of a TrueType/OpenType font file that decide
// WezTerm's natural character cell (kwi3-wv1u). No dependencies; used by
// kwi3-cell.js. Reads: name (family/subfamily), head (unitsPerEm), hhea
// (ascender/descender/lineGap), OS/2 (typo metrics, fsSelection, weight),
// cmap (format 4 or 12) and hmtx (advance widths). A .ttc yields each font.
'use strict';

function tables(buf, off) {
    const n = buf.readUInt16BE(off + 4);
    const t = {};
    for (let i = 0; i < n; i++) {
        const r = off + 12 + i * 16;
        t[buf.toString('latin1', r, r + 4)] = { off: buf.readUInt32BE(r + 8), len: buf.readUInt32BE(r + 12) };
    }
    return t;
}

function names(buf, t) {
    const out = {};
    if (!t.name) return out;
    const b = t.name.off;
    const count = buf.readUInt16BE(b + 2);
    const strs = b + buf.readUInt16BE(b + 4);
    for (let i = 0; i < count; i++) {
        const r = b + 6 + i * 12;
        const plat = buf.readUInt16BE(r), enc = buf.readUInt16BE(r + 2);
        const lang = buf.readUInt16BE(r + 4), id = buf.readUInt16BE(r + 6);
        const len = buf.readUInt16BE(r + 8), o = strs + buf.readUInt16BE(r + 10);
        if (![1, 2, 16, 17].includes(id)) continue;
        let s;
        if (plat === 3 || plat === 0) {
            if (plat === 3 && enc !== 1 && enc !== 10) continue;
            const u = Buffer.from(buf.subarray(o, o + len));
            u.swap16();
            s = u.toString('utf16le');
            // English (US) first, any language otherwise.
            if (out[id] !== undefined && !(plat === 3 && lang === 0x409)) continue;
        } else if (plat === 1 && enc === 0) {
            if (out[id] !== undefined) continue;
            s = buf.toString('latin1', o, o + len);
        } else continue;
        out[id] = s;
    }
    return out;
}

function cmapLookup(buf, t) {
    if (!t.cmap) return () => 0;
    const b = t.cmap.off;
    const n = buf.readUInt16BE(b + 2);
    let best = null;
    for (let i = 0; i < n; i++) {
        const r = b + 4 + i * 8;
        const plat = buf.readUInt16BE(r), enc = buf.readUInt16BE(r + 2);
        const o = b + buf.readUInt32BE(r + 4);
        const fmt = buf.readUInt16BE(o);
        if ((plat === 3 && (enc === 1 || enc === 10)) || plat === 0) {
            if (fmt === 12 || (fmt === 4 && (!best || best.fmt !== 12))) best = { o, fmt };
        }
    }
    if (!best) return () => 0;
    const o = best.o;
    if (best.fmt === 12) {
        const groups = buf.readUInt32BE(o + 12);
        return c => {
            for (let i = 0; i < groups; i++) {
                const g = o + 16 + i * 12;
                const s = buf.readUInt32BE(g), e = buf.readUInt32BE(g + 4);
                if (c >= s && c <= e) return buf.readUInt32BE(g + 8) + (c - s);
            }
            return 0;
        };
    }
    const segX2 = buf.readUInt16BE(o + 6);
    const ends = o + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2;
    return c => {
        for (let i = 0; i < segX2; i += 2) {
            if (c > buf.readUInt16BE(ends + i)) continue;
            const s = buf.readUInt16BE(starts + i);
            if (c < s) return 0;
            const d = buf.readInt16BE(deltas + i), ro = buf.readUInt16BE(ranges + i);
            if (ro === 0) return (c + d) & 0xffff;
            const gi = buf.readUInt16BE(ranges + i + ro + 2 * (c - s));
            return gi === 0 ? 0 : (gi + d) & 0xffff;
        }
        return 0;
    };
}

function face(buf, off) {
    const t = tables(buf, off);
    if (!t.head || !t.hhea) return null;
    const nm = names(buf, t);
    const f = {
        family: nm[16] || nm[1] || '',
        family1: nm[1] || '',
        subfamily: nm[17] || nm[2] || '',
        upem: buf.readUInt16BE(t.head.off + 18),
        hheaAscender: buf.readInt16BE(t.hhea.off + 4),
        hheaDescender: buf.readInt16BE(t.hhea.off + 6),
        hheaLineGap: buf.readInt16BE(t.hhea.off + 8),
        os2: null,
    };
    if (t['OS/2']) {
        const o = t['OS/2'].off;
        f.os2 = {
            weight: buf.readUInt16BE(o + 4),
            fsSelection: buf.readUInt16BE(o + 62),
            typoAscender: buf.readInt16BE(o + 68),
            typoDescender: buf.readInt16BE(o + 70),
            typoLineGap: buf.readInt16BE(o + 72),
            winAscent: buf.readUInt16BE(o + 74),
            winDescent: buf.readUInt16BE(o + 76),
        };
    }
    // The widest advance among the printable ASCII glyphs the font has:
    // what WezTerm takes as the natural cell width (wezterm-font ftwrap.rs
    // cell_metrics(): chars 32..127).
    const lookup = cmapLookup(buf, t);
    const nh = buf.readUInt16BE(t.hhea.off + 34);
    let adv = 0;
    if (t.hmtx && nh > 0) {
        for (let c = 32; c < 128; c++) {
            const g = lookup(c);
            if (!g) continue;
            const a = buf.readUInt16BE(t.hmtx.off + 4 * Math.min(g, nh - 1));
            if (a > adv) adv = a;
        }
    }
    f.asciiAdvance = adv;
    return f;
}

// parse(buf) -> [face...]: one per font in the file (several in a .ttc).
function parse(buf) {
    if (buf.length < 12) return [];
    const tag = buf.toString('latin1', 0, 4);
    if (tag === 'ttcf') {
        const n = buf.readUInt32BE(8);
        const out = [];
        for (let i = 0; i < n; i++) {
            const f = face(buf, buf.readUInt32BE(12 + 4 * i));
            if (f) out.push(f);
        }
        return out;
    }
    const v = buf.readUInt32BE(0);
    if (v !== 0x00010000 && tag !== 'OTTO' && tag !== 'true') return [];
    const f = face(buf, 0);
    return f ? [f] : [];
}

// names(path) -> [{family, family1, subfamily}...] for each font in the
// file, reading only its table directory and name table: a font directory
// holds hundreds of files, and only a match is read whole.
function namesOf(path) {
    const fs = require('fs');
    const fd = fs.openSync(path, 'r');
    try {
        const read = (off, len) => {
            const b = Buffer.alloc(len);
            const n = fs.readSync(fd, b, 0, len, off);
            if (n !== len) throw new Error('short read');
            return b;
        };
        const head = read(0, 12);
        let offs = [0];
        if (head.toString('latin1', 0, 4) === 'ttcf') {
            const n = head.readUInt32BE(8);
            const o = read(12, 4 * n);
            offs = [];
            for (let i = 0; i < n; i++) offs.push(o.readUInt32BE(4 * i));
        } else {
            const v = head.readUInt32BE(0);
            const tag = head.toString('latin1', 0, 4);
            if (v !== 0x00010000 && tag !== 'OTTO' && tag !== 'true') return [];
        }
        const out = [];
        for (const off of offs) {
            const n = read(off + 4, 2).readUInt16BE(0);
            const dir = read(off, 12 + 16 * n);
            const t = tables(dir, 0);
            if (!t.name) continue;
            const nb = read(t.name.off, t.name.len);
            const nm = names(nb, { name: { off: 0, len: t.name.len } });
            out.push({ family: nm[16] || nm[1] || '', family1: nm[1] || '', subfamily: nm[17] || nm[2] || '' });
        }
        return out;
    } finally {
        fs.closeSync(fd);
    }
}

module.exports = { parse, namesOf };
