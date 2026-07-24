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
