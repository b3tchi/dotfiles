// subject.go derives the message pane's one free-text column from an
// envelope's opaque content. No `subject` field is ever read from an
// envelope — none is written (adr0028) — so this is the one place content is
// looked at, and only exactly as far as the rule requires: first line of
// content for an ordinary message; `status — summary` for a result envelope;
// the raw first line for anything else. It never parses content structurally
// beyond that to make the column prettier (the JSON-blob edge case is
// deliberately ugly-but-correct, not "fixed").
package render

import (
	"encoding/json"
	"strings"
)

// kindResult is the one envelope kind that gets a derivation other than
// "raw first line" — the bus's actual kind vocabulary (see
// claude/marketplace/plugins/pi-workers/scripts/pi-worker.nu's
// ENVELOPE_KINDS) is "inbox" / "result" / "error" / "identity"; an ordinary
// message travels as "inbox", not "message" — ft014's data_model says
// "message" but the transport writes "inbox" (pi-worker.nu:1399), a card/
// reality mismatch tracked as dotfiles-9oa4. This code follows the shipped
// transport, not the card. "inbox", "error" and "identity" all render the
// same way: the raw first line of content, untouched.
const kindResult = "result"

// DeriveSubject computes the message pane's SUBJECT cell for one envelope,
// truncated to width display cells with an explicit ellipsis, and with
// control characters (ANSI escapes included) neutralised BEFORE truncation —
// so a message payload can never reposition the cursor, clear the display,
// or have its escape sequence split mid-sequence by the cut.
func DeriveSubject(kind string, content []byte, width int) string {
	subject := rawSubject(kind, content)
	subject = neutralize(subject)
	return truncateCells(subject, width)
}

// rawSubject computes the untruncated, unneutralised subject text.
func rawSubject(kind string, content []byte) string {
	if kind == kindResult {
		var r struct {
			Status  string `json:"status"`
			Summary string `json:"summary"`
		}
		if err := json.Unmarshal(content, &r); err == nil && (r.Status != "" || r.Summary != "") {
			return r.Status + " — " + r.Summary
		}
		// Missing/malformed fields: fall back to the same raw first-line
		// treatment "anything else" gets, rather than blanking the column.
	}
	return firstLine(contentText(content))
}

// contentText renders content's raw bytes as display text. A JSON string
// unmarshals to its real (unescaped) value; anything else — an object,
// array, number, bool, or null — renders as its own compact JSON text
// verbatim. This is the JSON-blob edge case: content that is itself a blob
// renders as that blob, truncated — never parsed further to look nicer.
func contentText(content []byte) string {
	trimmed := strings.TrimSpace(string(content))
	if trimmed == "" {
		return ""
	}
	if trimmed[0] == '"' {
		var s string
		if err := json.Unmarshal([]byte(trimmed), &s); err == nil {
			return s
		}
	}
	return trimmed
}

// firstLine returns the text up to (not including) the first newline or
// carriage return, or the whole string if it has neither.
func firstLine(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return s[:i]
	}
	return s
}

// neutralize strips C0/C1 control characters — including the ESC byte that
// introduces every ANSI escape sequence — before the subject ever reaches a
// terminal. Dropping ESC alone is sufficient to make a CSI sequence inert
// (a terminal only interprets "\x1b[31m" as a colour change because of the
// leading ESC; without it, "[31m" is just three harmless printable
// characters), so this does not need a full ANSI parser to be safe.
func neutralize(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// truncateCells bounds s to width display cells, counting each rune's real
// terminal width (wide CJK/emoji runes count as 2) rather than bytes or rune
// count, and cutting only on whole-rune boundaries. A truncated result gets
// an explicit single-cell ellipsis; a result that already fits is returned
// unchanged with no ellipsis added.
func truncateCells(s string, width int) string {
	if width <= 0 {
		return ""
	}
	runes := []rune(s)
	total := 0
	for _, r := range runes {
		total += runeWidth(r)
	}
	if total <= width {
		return s
	}
	if width == 1 {
		return "…"
	}
	budget := width - 1 // reserve one cell for the ellipsis
	var out []rune
	used := 0
	for _, r := range runes {
		w := runeWidth(r)
		if used+w > budget {
			break
		}
		out = append(out, r)
		used += w
	}
	return string(out) + "…"
}

// displayWidth is truncateCells's own width accounting, exported (within the
// package) for tests to verify a result never exceeds its declared budget.
func displayWidth(s string) int {
	w := 0
	for _, r := range s {
		w += runeWidth(r)
	}
	return w
}

// runeWidth approximates a rune's terminal display width: 2 cells for the
// common wide ranges (CJK ideographs and their symbols, Hiragana/Katakana,
// Hangul syllables, fullwidth forms, and common emoji blocks), 1 otherwise.
// This is a practical subset of East Asian Width, not the full Unicode
// annex — good enough to keep a truncated line from ever overrunning its
// column, which is the only property truncateCells depends on.
func runeWidth(r rune) int {
	switch {
	case r < 0x20:
		return 0 // control character; neutralize already strips these from subjects
	case isWide(r):
		return 2
	default:
		return 1
	}
}

func isWide(r rune) bool {
	switch {
	case r >= 0x1100 && r <= 0x115F: // Hangul Jamo
		return true
	case r >= 0x2E80 && r <= 0x303E: // CJK Radicals, symbols & punctuation
		return true
	case r >= 0x3041 && r <= 0x33FF: // Hiragana..CJK compat
		return true
	case r >= 0x3400 && r <= 0x4DBF: // CJK Ext-A
		return true
	case r >= 0x4E00 && r <= 0x9FFF: // CJK Unified Ideographs
		return true
	case r >= 0xA000 && r <= 0xA4CF: // Yi
		return true
	case r >= 0xAC00 && r <= 0xD7A3: // Hangul syllables
		return true
	case r >= 0xF900 && r <= 0xFAFF: // CJK compatibility ideographs
		return true
	case r >= 0xFF00 && r <= 0xFF60: // Fullwidth forms
		return true
	case r >= 0xFFE0 && r <= 0xFFE6: // Fullwidth signs
		return true
	case r >= 0x1F300 && r <= 0x1FAFF: // emoji blocks
		return true
	case r >= 0x2600 && r <= 0x27BF: // misc symbols & dingbats (common emoji)
		return true
	default:
		return false
	}
}
