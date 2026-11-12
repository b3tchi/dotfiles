pragma Singleton
import Quickshell
import QtQuick

// Scored subsequence fuzzy match + match-char highlight, extracted from
// config/Overlay.qml (fuzzyMatch / highlightMatch). Single implementation so
// the four dialogs can no longer drift. `match` is byte-identical to the
// original scoring; `highlight` is the original wrap PLUS HTML-escaping,
// required now that rows render as RichText over arbitrary clipboard bytes.
Singleton {
    id: fuzzy

    // Extracted VERBATIM from config/Overlay.qml fuzzyMatch(). Scoring, kept
    // exactly: word-boundary bonus +10 (index 0, after ' ', after '-'),
    // consecutive-match bonus +5, +1 per matched char. Empty pattern ->
    // matched, score 0, no indices. Non-subsequence -> not matched. Case is
    // folded on both sides; indices refer to the ORIGINAL text code units.
    function match(text, pattern) {
        if (!pattern) return { matched: true, score: 0, indices: [] }
        if (!text) return { matched: false, score: 0, indices: [] }

        var lower = text.toLowerCase()
        var pat = pattern.toLowerCase()
        var ti = 0, pi = 0
        var indices = []
        var score = 0
        var prevMatched = false

        while (ti < lower.length && pi < pat.length) {
            if (lower[ti] === pat[pi]) {
                indices.push(ti)
                if (prevMatched) score += 5
                if (ti === 0 || text[ti - 1] === ' ' || text[ti - 1] === '-')
                    score += 10
                score += 1
                pi++
                prevMatched = true
            } else {
                prevMatched = false
            }
            ti++
        }

        return { matched: pi === pat.length, score: score, indices: indices }
    }

    // fzf-style matcher (fzf v1 algorithm, simplified scoring). Unlike the
    // pinned greedy `match`, it tries EVERY start of the first pattern char,
    // tightens each candidate window backwards (fzf v1), and keeps the best
    // alignment — so "fox" in "firefox" lands on the contiguous "fox", and
    // "gg" in "git-graph" lands on both word starts. Same return shape as
    // `match`; empty pattern -> matched, score 0. Callers wanting fzf's
    // default --tiebreak=length break equal scores on text length.
    //   +16 per matched char
    //   + boundary bonus at the char: start 10, after non-alnum 8,
    //     camelCase 7, letter->digit 4 (doubled for the FIRST pattern char)
    //   consecutive char: + max(bonus of its run's first char, 4)
    //   gap: -3 to open, -1 per extra skipped char
    function fzf(text, pattern) {
        if (!pattern) return { matched: true, score: 0, indices: [] }
        if (!text) return { matched: false, score: 0, indices: [] }

        var lower = text.toLowerCase()
        var pat = pattern.toLowerCase()
        var n = pat.length
        var best = null

        var s = lower.indexOf(pat[0])
        while (s !== -1) {
            // forward greedy from s
            var fwd = [s]
            var ti = s + 1
            for (var pi = 1; pi < n; pi++) {
                ti = lower.indexOf(pat[pi], ti)
                if (ti === -1) break
                fwd.push(ti)
                ti++
            }
            if (fwd.length < n) break   // no later start can succeed either

            // backward tighten from the forward window's end
            var bwd = new Array(n)
            var bi = fwd[n - 1]
            for (var pj = n - 1; pj >= 0; pj--) {
                bi = lower.lastIndexOf(pat[pj], bi)
                bwd[pj] = bi
                bi--
            }

            var cands = [fwd, bwd]
            for (var c = 0; c < 2; c++) {
                var sc = _fzfScore(text, cands[c])
                if (!best || sc > best.score)
                    best = { matched: true, score: sc, indices: cands[c] }
            }
            s = lower.indexOf(pat[0], bwd[0] + 1)
        }
        return best || { matched: false, score: 0, indices: [] }
    }

    function _bonusAt(text, i) {
        if (i === 0) return 10
        var p = text[i - 1], ch = text[i]
        if (!/[A-Za-z0-9]/.test(p)) return 8
        if (/[a-z]/.test(p) && /[A-Z]/.test(ch)) return 7
        if (/[A-Za-z]/.test(p) && /[0-9]/.test(ch)) return 4
        return 0
    }

    function _fzfScore(text, idx) {
        var sc = 0
        var runBonus = 0
        for (var k = 0; k < idx.length; k++) {
            var b = _bonusAt(text, idx[k])
            sc += 16 + b
            if (k === 0) {
                sc += b
                runBonus = b
            } else {
                var gap = idx[k] - idx[k - 1] - 1
                if (gap === 0) {
                    sc += Math.max(runBonus, 4)
                } else {
                    sc -= 3 + (gap - 1)
                    runBonus = b
                }
            }
        }
        return sc
    }

    // Wrap the code units at `indices` in an accent-colored bold run for
    // RichText rendering. HARDENING over the original highlightMatch: every
    // char is HTML-escaped (&, <, >) BEFORE wrapping, so arbitrary clipboard
    // bytes render literally instead of injecting markup into the row. Empty
    // or null indices returns the escaped text unchanged (the original
    // returned it RAW — that path is now escaped too). Color is sourced from
    // DialogTheme.accent so the highlight tracks the shared theme.
    function highlight(text, indices) {
        var matchSet = {}
        if (indices)
            for (var i = 0; i < indices.length; i++) matchSet[indices[i]] = true
        var result = ""
        for (var j = 0; j < text.length; j++) {
            var c = text[j]
            if (c === '&') c = "&amp;"
            else if (c === '<') c = "&lt;"
            else if (c === '>') c = "&gt;"
            if (matchSet[j])
                result += "<font color='" + DialogTheme.accent + "'><b>" + c + "</b></font>"
            else
                result += c
        }
        return result
    }
}
