// log.go renders the message pane: one row per envelope, oldest-first /
// newest-last (a scrolling log's natural reading order), with a derived
// SUBJECT column (subject.go) instead of a nonexistent envelope field
// (adr0028). It joins nothing itself — every value came from the
// source.MessageSample it was handed, exactly like roster.go's Render.
package render

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"agent-monitor/internal/source"
)

// msgColumn is the message pane's own column enum — deliberately a separate
// type from roster.go's column, so the two panes' widths and drop rules
// never accidentally share state.
type msgColumn int

const (
	msgColTime msgColumn = iota
	msgColFrom
	msgColTo
	msgColSubject
)

var msgColumnHeader = map[msgColumn]string{
	msgColTime:    "TIME",
	msgColFrom:    "FROM",
	msgColTo:      "TO",
	msgColSubject: "SUBJECT",
}

// msgFixedWidth is the declared width of every column except SUBJECT, which
// takes whatever width remains after the surviving fixed columns (see
// subjectWidth below).
var msgFixedWidth = map[msgColumn]int{
	msgColTime: 8, // "15:04:05"
	msgColFrom: 12,
	msgColTo:   16,
}

// minSubjectWidth is the floor SUBJECT is never shrunk below, even on a
// pathologically narrow terminal — matching roster.go's "uid/name never
// drops" rule: this pane has one indispensable column too, it just happens
// to sit on the right instead of the left.
const minSubjectWidth = 8

// msgDropOrder is the drop priority among the FIXED columns (Time/From/To)
// when the terminal is too narrow to fit all three plus SUBJECT's floor: TO
// drops first, then FROM, then TIME. SUBJECT never drops — see
// minSubjectWidth.
var msgDropOrder = []msgColumn{msgColTo, msgColFrom, msgColTime}

// fitMsgColumns returns the fixed columns (in display order: Time, From, To)
// that fit alongside SUBJECT's floor at the given width, dropping from
// msgDropOrder until they do (or until none are left, at which point the
// row is TIME-less and just SUBJECT).
func fitMsgColumns(width int) []msgColumn {
	cols := []msgColumn{msgColTime, msgColFrom, msgColTo}
	for len(cols) > 0 && fixedLineWidth(cols)+1+minSubjectWidth > width {
		dropped := false
		for _, d := range msgDropOrder {
			if idx := indexOfMsgCol(cols, d); idx >= 0 {
				cols = append(cols[:idx], cols[idx+1:]...)
				dropped = true
				break
			}
		}
		if !dropped {
			break
		}
	}
	return cols
}

func fixedLineWidth(cols []msgColumn) int {
	w := 0
	for i, c := range cols {
		if i > 0 {
			w++ // single-space separator
		}
		w += msgFixedWidth[c]
	}
	return w
}

func indexOfMsgCol(cols []msgColumn, target msgColumn) int {
	for i, c := range cols {
		if c == target {
			return i
		}
	}
	return -1
}

// subjectWidth returns how many display cells SUBJECT gets given the
// surviving fixed columns: everything left after them and their separators,
// floored at minSubjectWidth (which can make the total line wider than
// `width` on an extremely narrow terminal — the same trade-off roster.go's
// effectiveWidths makes for its one indispensable column).
func subjectWidth(width int, cols []msgColumn) int {
	used := fixedLineWidth(cols)
	if len(cols) > 0 {
		used++ // separator before SUBJECT
	}
	w := width - used
	if w < minSubjectWidth {
		w = minSubjectWidth
	}
	return w
}

// RenderLog turns a MessageSample into terminal lines at the given width, as
// of now. Rows print in the sample's own order (ParseMessages already
// returns ascending id/time order), so the most recent message is the last
// line — this renderer does not re-sort.
func RenderLog(sample *source.MessageSample, stale bool, now time.Time, width int) []string {
	if sample == nil {
		return []string{"messages — waiting for first sample"}
	}

	cols := fitMsgColumns(width)
	subjW := subjectWidth(width, cols)
	widths := map[msgColumn]int{msgColSubject: subjW}
	for _, c := range cols {
		widths[c] = msgFixedWidth[c]
	}
	allCols := append(append([]msgColumn{}, cols...), msgColSubject)

	var lines []string
	lines = append(lines, logHeaderLine(sample, stale, now))
	lines = append(lines, msgColumnHeaderLine(allCols, widths))

	if len(sample.Messages) == 0 {
		lines = append(lines, "(no messages)")
		return lines
	}

	for _, m := range sample.Messages {
		lines = append(lines, msgRowLine(m, allCols, widths))
	}
	return lines
}

func logHeaderLine(sample *source.MessageSample, stale bool, now time.Time) string {
	age := ageString(now, sample.At)
	if stale {
		return fmt.Sprintf("messages — STALE (last good sample %s old)", age)
	}
	return fmt.Sprintf("messages — updated %s ago", age)
}

func msgColumnHeaderLine(cols []msgColumn, widths map[msgColumn]int) string {
	parts := make([]string, 0, len(cols))
	for _, c := range cols {
		parts = append(parts, pad(msgColumnHeader[c], widths[c]))
	}
	return join(parts)
}

func msgRowLine(m source.Message, cols []msgColumn, widths map[msgColumn]int) string {
	parts := make([]string, 0, len(cols))
	for _, c := range cols {
		parts = append(parts, pad(msgCellFor(c, m, widths[c]), widths[c]))
	}
	return join(parts)
}

func msgCellFor(c msgColumn, m source.Message, width int) string {
	switch c {
	case msgColTime:
		return timeCell(m.At)
	case msgColFrom:
		return orDash(shortAddress(m.From))
	case msgColTo:
		return toCellShort(m.To)
	case msgColSubject:
		return DeriveSubject(m.Kind, m.Content, width)
	default:
		return ""
	}
}

// timeCell formats an envelope's ISO-8601 `at` timestamp as a short
// wall-clock string. A timestamp that fails to parse renders as-is
// (truncated/padded like any other cell) rather than raising — one
// malformed field must not blank the row.
func timeCell(at string) string {
	t, err := time.Parse(time.RFC3339Nano, at)
	if err != nil {
		return at
	}
	return t.Format("15:04:05")
}

// toCell joins a multi-recipient `to` list so every recipient is visible —
// never silently just the first — leaving column-width truncation (via pad)
// to shorten the joined text the same way it shortens any other cell.
func toCell(to []string) string {
	if len(to) == 0 {
		return emptyCell
	}
	return strings.Join(to, ",")
}

// addressPattern is the shape pi-worker mints an address in (dotfiles-1d1f):
// `a` plus 26 Crockford base32 characters. Kept here rather than imported
// because this package renders whatever `pi-worker messages --json` hands it
// and never parses the bus itself — this is a display heuristic about one
// string, not a second implementation of the address type.
var addressPattern = regexp.MustCompile(`^a[0-9A-HJKMNP-TV-Z]{26}$`)

// How much of an unresolved address's tail the log shows. The tail is the
// RANDOM half of the id; the leading characters are a millisecond timestamp,
// so two addresses minted in the same second share their first eleven
// characters. Head-truncating an address the way `pad` truncates any other
// cell would therefore render two different senders identically — which is
// worse than unreadable, because it looks like one sender.
const addressTailChars = 6

// shortAddress renders an address as an elided tail, and anything else
// unchanged.
//
// `pi-worker messages` already resolves an address to its label, so a cell
// reaching this holding an address is one the registry could not resolve —
// the [[adr0017]] fallback, where the raw address is the only honest answer.
// This does not replace it with a guess; it elides it, marked, to the part
// that distinguishes one from another. The full address is in the detail pane
// (detail.go), which is the view an operator copies from.
func shortAddress(s string) string {
	if !addressPattern.MatchString(s) {
		return s
	}
	return "…" + s[len(s)-addressTailChars:]
}

// toCellShort is toCell with each recipient elided by shortAddress — the log
// pane's form. detail.go keeps toCell, and so keeps the full addresses.
func toCellShort(to []string) string {
	if len(to) == 0 {
		return emptyCell
	}
	short := make([]string, 0, len(to))
	for _, a := range to {
		short = append(short, shortAddress(a))
	}
	return strings.Join(short, ",")
}
