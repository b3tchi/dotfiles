// Package render turns a source.Sample into terminal lines. It joins
// nothing and reads nothing itself — every value it prints came from the
// sample it was handed.
package render

import (
	"fmt"
	"time"

	"agent-monitor/internal/source"
)

// column is one roster column, in a fixed left-to-right display order. When
// the terminal is too narrow for every column, columns drop from the RIGHT
// of this list — age first, then activity, then state, then role, then
// runtime. uid/name never drops: it is the one column that identifies a row.
type column int

const (
	colUIDName column = iota
	colRuntime
	colRole
	colState
	colActivity
	colAge
)

// columnOrder is the fixed left-to-right, drop-from-the-right priority.
var columnOrder = []column{colUIDName, colRuntime, colRole, colState, colActivity, colAge}

var columnHeader = map[column]string{
	colUIDName:  "UID/NAME",
	colRuntime:  "RUNTIME",
	colRole:     "ROLE",
	colState:    "STATE",
	colActivity: "ACTIVITY",
	colAge:      "AGE",
}

// columnWidth is each column's fixed display width, including its header.
// Widths are picked once so golden-render tests are deterministic: a given
// (sample, width) pair always produces the same lines.
var columnWidth = map[column]int{
	colUIDName:  14,
	colRuntime:  7,
	colRole:     7,
	colState:    13,
	colActivity: 9,
	colAge:      5,
}

const emptyCell = "—"

// fitColumns picks which columns fit in width, dropping from the right
// (least important first) until the fixed-width line — every column at its
// declared width, joined by single spaces — is no wider than width. At
// least the uid/name column is always kept, even if that alone overflows a
// pathologically narrow terminal: a line is never wrapped mid-row.
func fitColumns(width int) []column {
	cols := append([]column{}, columnOrder...)
	for len(cols) > 1 && lineWidth(cols) > width {
		cols = cols[:len(cols)-1]
	}
	return cols
}

func lineWidth(cols []column) int {
	w := 0
	for i, c := range cols {
		if i > 0 {
			w++ // single-space separator
		}
		w += columnWidth[c]
	}
	return w
}

// effectiveWidths returns the per-column render width for cols at the given
// terminal width. Normally that is just each column's declared columnWidth.
// The one exception: a pathologically narrow terminal where even the sole
// surviving column (uid/name, never dropped) is wider than the terminal —
// fitColumns still returns it alone rather than emptying the row entirely,
// so its rendered width is clamped down to `width` here. This is what keeps
// "never wrap mid-row" and "never longer than width" both true at once.
func effectiveWidths(cols []column, width int) map[column]int {
	widths := make(map[column]int, len(cols))
	for _, c := range cols {
		widths[c] = columnWidth[c]
	}
	if len(cols) == 1 {
		c := cols[0]
		if widths[c] > width {
			if width < 1 {
				width = 1
			}
			widths[c] = width
		}
	}
	return widths
}

// bucketPriority mirrors source.SortRows's ordering so the roster renders in
// the order the sample was already sorted; render does not re-sort.

// cellFor extracts one column's raw text for one row, before padding or
// truncation. Unmapped/unknown values (a state this build has never colour-
// coded, an empty activity) render verbatim — never a guess, never blank
// where the source gave nothing better than "—".
func cellFor(c column, r source.Row, age string) string {
	switch c {
	case colUIDName:
		return orDash(source.DisplayName(r))
	case colRuntime:
		return orDash(r.Runtime)
	case colRole:
		return orDash(r.Role)
	case colState:
		return orDash(r.State)
	case colActivity:
		return orDash(r.Status)
	case colAge:
		return age
	default:
		return ""
	}
}

func orDash(s string) string {
	if s == "" {
		return emptyCell
	}
	return s
}

// pad truncates or right-pads s to exactly width display cells, using an
// ellipsis on truncation so a line is never longer than its column budget.
func pad(s string, width int) string {
	r := []rune(s)
	if len(r) > width {
		if width <= 1 {
			return string(r[:width])
		}
		return string(r[:width-1]) + "…"
	}
	return s + spaces(width-len(r))
}

func spaces(n int) string {
	if n <= 0 {
		return ""
	}
	b := make([]byte, n)
	for i := range b {
		b[i] = ' '
	}
	return string(b)
}

// ageString formats how long ago `at` was, relative to `now`. It is the
// only honest "age" this renderer has: agent-census's payload carries no
// per-row timestamp (nothing upstream promises one — see census.go's Sample
// doc), so every row in one frame shares its sample's own capture age
// rather than a fabricated per-agent value. This age is a truthful bound
// for pi rows as well as claude's, DESPITE the --if-changed gate being
// blind to pi state (dotfiles-eee4): source.Sample's doc comment and
// source.RunLoop's bound clock are what make that true — every sample this
// renderer ever sees was produced by an agent-census invocation that
// re-probed pi unconditionally, at most RunLoop's bound-clock interval ago
// (cmd/agent-monitor/main.go's piBoundInterval). A single sample-level age
// is therefore not an approximation for pi; it is exact, the same way it is
// for claude.
func ageString(now, at time.Time) string {
	d := now.Sub(at)
	if d < 0 {
		d = 0
	}
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	default:
		return fmt.Sprintf("%dh", int(d.Hours()))
	}
}

// Render turns one sample into terminal lines, at the given width, as of
// `now` (passed in rather than read from time.Now so rendering is
// deterministic and testable). stale marks a sample whose last refresh
// attempt failed — the header says so, the rows still show the last good
// frame, and nothing is blanked.
func Render(sample *source.Sample, stale bool, now time.Time, width int) []string {
	if sample == nil {
		return []string{"agents — waiting for first sample"}
	}

	cols := fitColumns(width)
	widths := effectiveWidths(cols, width)
	age := ageString(now, sample.At)

	var lines []string
	lines = append(lines, truncateToWidth(headerLine(sample, stale, age), width))
	lines = append(lines, columnHeaderLine(cols, widths))

	if len(sample.Rows) == 0 {
		lines = append(lines, truncateToWidth("(no agents)", width))
		return lines
	}

	for _, row := range sample.Rows {
		lines = append(lines, rowLine(cols, row, age, widths))
	}
	return lines
}

// truncateToWidth bounds a free-text line (the header, the zero-agent
// message) to width display cells. Rows and the column header are already
// bounded by construction via effectiveWidths; this covers the two lines
// that are not column-shaped, so no line -- fixed-width or free text -- can
// ever exceed the terminal width, however narrow.
func truncateToWidth(s string, width int) string {
	r := []rune(s)
	if len(r) <= width {
		return s
	}
	if width <= 1 {
		if width <= 0 {
			return ""
		}
		return string(r[:width])
	}
	return string(r[:width-1]) + "…"
}

func headerLine(sample *source.Sample, stale bool, age string) string {
	if stale {
		return fmt.Sprintf("agents — STALE (last good sample %s old)", age)
	}
	return fmt.Sprintf("agents — updated %s ago", age)
}

func columnHeaderLine(cols []column, widths map[column]int) string {
	parts := make([]string, 0, len(cols))
	for _, c := range cols {
		parts = append(parts, pad(columnHeader[c], widths[c]))
	}
	return join(parts)
}

func rowLine(cols []column, row source.Row, age string, widths map[column]int) string {
	parts := make([]string, 0, len(cols))
	for _, c := range cols {
		parts = append(parts, pad(cellFor(c, row, age), widths[c]))
	}
	return join(parts)
}

// bucketStyle maps a known bucket to its ANSI SGR colour prefix. A bucket
// outside this map (a state this build has no colour for) resolves to "",
// the terminal's default style — rendered verbatim, never guessed, never an
// error. StyleReset closes whatever StyleFor opened; callers must not apply
// it when StyleFor returned "".
var bucketStyle = map[string]string{
	"blocked": "\x1b[31m", // red: needs attention
	"working": "\x1b[33m", // yellow: in progress
	"idle":    "",         // default style
	"done":    "\x1b[32m", // green: finished
}

// StyleReset closes a colour opened by StyleFor.
const StyleReset = "\x1b[0m"

// StyleFor returns the colour prefix for a bucket, or "" for any bucket this
// build has no colour for. Callers (main.go's real terminal output; not the
// golden-tested Render above, which stays plain so its width/line-count
// assertions are not entangled with escape-sequence byte counts) wrap a
// line's leading bytes with this and StyleReset, or wrap with nothing when
// StyleFor returns "".
func StyleFor(bucket string) string {
	return bucketStyle[bucket]
}

func join(parts []string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += " "
		}
		out += p
	}
	return out
}
