// detail.go renders the detail pane: the full header and body of one
// selected envelope. It is a SEPARATE renderer from log.go's SUBJECT column
// and does not change it — sp030's plan anti-pattern (no parsing content to
// prettify the subject column) stands unchanged; T9's raw-first-line tests
// on that column are untouched. Only this pane formats: a body that parses
// as JSON is indented for reading, and a parse failure falls back to raw
// rather than erroring. ft014's opacity rule binds the TRANSPORT ("gates on
// none of the vocabulary it carries"); this is a consumer choosing how to
// DRAW what it already received in full, which does not touch that
// contract, and no `subject` field is invented on an envelope.
package render

import (
	"bytes"
	"encoding/json"
	"fmt"

	"agent-monitor/internal/source"
)

// detailPlaceholder is the single line shown when nothing is selected — a
// nil Message (no row under the cursor, or an empty log) — never a blank
// region and never a panic.
const detailPlaceholder = "(no message selected)"

// truncationIndicatorFmt marks a body cut off by the height budget with the
// count of lines that did not fit — a visible sign more exists, never a
// silent cut.
const truncationIndicatorFmt = "… (%d more line(s) not shown)"

// RenderDetail turns one selected envelope into terminal lines: a header
// (`from → to`, time, kind) followed by its body, bounded to `height` lines
// and `width` display cells. It is pure — no clock, no terminal, no exec —
// matching Render and RenderLog's contract (cmd/ owns composition, render/
// owns bytes: cmd/ picks the selected message, RenderDetail draws it).
func RenderDetail(msg *source.Message, width, height int) []string {
	if width < 1 {
		width = 1
	}
	if height < 1 {
		height = 1
	}

	if msg == nil {
		return clampToHeight([]string{truncateCells(detailPlaceholder, width)}, width, height)
	}

	lines := []string{detailHeaderLine(*msg, width)}
	lines = append(lines, detailBodyLines(msg.Content, width)...)
	return clampToHeight(lines, width, height)
}

// detailHeaderLine renders the `from → to`, time, kind summary. It goes
// through the same neutralize + cell-aware truncation as every other cell
// this package renders (subject.go) — an agent-controlled from/to/kind is as
// foreign a byte source as a message body, so it earns the same guarantee.
// Multi-recipient `to` lists every recipient via toCell (log.go), matching
// the log's existing rule.
func detailHeaderLine(msg source.Message, width int) string {
	raw := fmt.Sprintf("%s → %s   %s   %s", orDash(msg.From), toCell(msg.To), timeCell(msg.At), orDash(msg.Kind))
	return truncateCells(neutralize(raw), width)
}

// detailBodyLines renders an envelope's content as display lines: indented
// for reading when it parses as JSON, raw otherwise (prettyOrRaw). Every
// resulting physical line is neutralised and then cell-wrapped
// (wrapCells) — the same guarantee sp030 T9 proved for the subject column
// (neutralize, subject.go:92), applied to a pane that shows strictly more
// foreign bytes than a truncated column ever did.
func detailBodyLines(content []byte, width int) []string {
	body := prettyOrRaw(content)
	var lines []string
	for _, raw := range splitLines(body) {
		lines = append(lines, wrapCells(neutralize(raw), width)...)
	}
	return lines
}

// prettyOrRaw indents content when it parses as JSON, and falls back to the
// raw bytes (as text) when it does not. A malformed/truncated body is not an
// error here, just content that stays raw — the fallback the task's
// edge_cases and test_plan both call out explicitly.
func prettyOrRaw(content []byte) string {
	trimmed := bytes.TrimSpace(content)
	if len(trimmed) == 0 {
		return ""
	}
	var buf bytes.Buffer
	if err := json.Indent(&buf, trimmed, "", "  "); err == nil {
		return buf.String()
	}
	return string(trimmed)
}

// splitLines splits s on its own newlines (CRLF-tolerant), preserving empty
// lines, so wrapCells only ever has to reason about one physical line at a
// time. Run BEFORE neutralize — neutralize strips every C0 byte including
// \n and \r, so splitting has to happen first or a multi-line pretty-printed
// body would collapse into one line.
func splitLines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			lines = append(lines, trimTrailingCR(s[start:i]))
			start = i + 1
		}
	}
	lines = append(lines, trimTrailingCR(s[start:]))
	return lines
}

func trimTrailingCR(s string) string {
	if len(s) > 0 && s[len(s)-1] == '\r' {
		return s[:len(s)-1]
	}
	return s
}

// wrapCells hard-wraps one already-neutralised physical line into display
// lines of at most width cells each, breaking only on whole-rune boundaries
// (using the same runeWidth accounting truncateCells uses, subject.go:154)
// and never splitting a wide rune across two lines. This is what lets a
// deeply-indented or very long body respect the width budget instead of
// running off the right edge, which truncateCells alone cannot do since it
// only ever produces one line.
func wrapCells(s string, width int) []string {
	if s == "" {
		return []string{""}
	}
	if width < 1 {
		width = 1
	}
	var lines []string
	var cur []rune
	used := 0
	for _, r := range s {
		w := runeWidth(r)
		if used > 0 && used+w > width {
			lines = append(lines, string(cur))
			cur = nil
			used = 0
		}
		cur = append(cur, r)
		used += w
	}
	lines = append(lines, string(cur))
	return lines
}

// clampToHeight bounds lines to at most height entries, replacing the last
// slot with a visible truncation indicator (rather than a silent cut) when
// there was more content than the budget allows.
func clampToHeight(lines []string, width, height int) []string {
	if len(lines) <= height || height <= 0 {
		if height <= 0 {
			return nil
		}
		return lines
	}
	kept := lines[:height-1]
	remaining := len(lines) - len(kept)
	indicator := truncateCells(neutralize(fmt.Sprintf(truncationIndicatorFmt, remaining)), width)
	out := make([]string, 0, height)
	out = append(out, kept...)
	out = append(out, indicator)
	return out
}
