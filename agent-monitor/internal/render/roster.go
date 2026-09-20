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
// project, then runtime. uid/name never drops: it is the one column that
// identifies a row.
type column int

const (
	colUIDName column = iota
	colRuntime
	colProject
	colRole
	colState
	colActivity
	colAge
)

// columnOrder is the fixed left-to-right, drop-from-the-right priority.
//
// colProject sits third, right after colRuntime, so it survives longer than
// colRole, colState, colActivity and colAge when the terminal narrows: on a
// machine running several projects at once, which workspace a row belongs
// to is more identifying than its role or how long ago it moved -- it is
// the detail an operator reaches for to tell rows apart before any of
// those. It still ranks below colUIDName (the one column that never drops)
// and colRuntime (a row's own identity, then its runtime kind -- pi vs
// claude -- are more fundamental than which project it belongs to).
var columnOrder = []column{colUIDName, colRuntime, colProject, colRole, colState, colActivity, colAge}

var columnHeader = map[column]string{
	colUIDName:  "UID/NAME",
	colRuntime:  "RUNTIME",
	colProject:  "PROJECT",
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
	colProject:  8,
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
	case colProject:
		// r.Project came straight from the census row for both runtimes
		// (ft012) -- nothing here re-derives it from a cwd, a window name
		// or a path. Empty renders blank via orDash, the same "no value"
		// convention every other column already uses; it must never guess
		// the literal word "unknown", which adr0017 owns as an
		// observational verdict at a different layer (the aggregate
		// count-row grouping, not this per-agent cell).
		return orDash(r.Project)
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
// Truncation is cell-aware (truncateCells, subject.go) rather than rune-
// counted: a project name or any other cell value carrying CJK/emoji runes
// must be bounded by its actual terminal width, not by how many runes it
// takes to encode that width, or a wide-character cell could overrun its
// column and the line's declared width with it.
//
// pad is the ONLY function that writes a grid cell — every row/header in
// the roster grid, the flat log grid and the thread grid goes through here
// (dotfiles-br55). It neutralises s FIRST, before displayWidth/truncateCells
// measure it, so no C0/DEL/C1 byte (an ESC included) can reach the terminal
// from ANY column, not just SUBJECT (which DeriveSubject already
// neutralises before calling here — neutralize is idempotent, so that is a
// no-op second pass). Neutralising first also fixes the width-accounting
// half of the same defect: runeWidth reports 0 for r < 0x20, so measuring
// before neutralising would let an escape reach the terminal while
// consuming no width budget. Neutralise → measure → truncate, in that
// order, always.
func pad(s string, width int) string {
	s = neutralize(s)
	w := displayWidth(s)
	if w > width {
		return truncateCells(s, width)
	}
	return s + spaces(width-w)
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

// ageString formats how long ago `at` was, relative to `now`.
//
// Two ages exist in this frame and they answer different questions. The
// header's is the SAMPLE's: how fresh the whole picture is. The AGE column's
// is the AGENT's: how long this one has been running, which is the question
// "is that blocked one worth interrupting" actually needs (dotfiles-a1tq).
//
// The column used to show the sample age in every row, because the census
// carried no per-row timestamp — honest, uniform, and unable to distinguish a
// worker blocked for eight seconds from one blocked for forty minutes. The
// census stamps each row now (`started`, ISO for both runtimes), so
// `rowAge` prefers it and falls back to this for a row that has none.
//
// The sample age remains a truthful bound for a pi row as well as a claude
// one, DESPITE the --if-changed gate having been blind to pi state
// (dotfiles-eee4, since fixed): source.Sample's doc comment and
// source.RunLoop's bound clock are what make that true — every sample this
// renderer ever sees was produced by an agent-census invocation that
// re-probed pi unconditionally, at most RunLoop's bound-clock interval ago
// (cmd/agent-monitor/main.go's piBoundInterval).
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

// rowAge is how long THIS agent has been running, or `fallback` (the sample's
// capture age) when the census could not say.
//
// An unparseable stamp is treated exactly like an absent one. The census
// writes these, but a row also arrives from a plugin or a build this one has
// never met, and a renderer that trusted the string would print a negative
// duration or 1970 — a wrong answer where "as fresh as this sample" is a
// right, if less precise, one.
func rowAge(r source.Row, now time.Time, fallback string) string {
	if r.Started == "" {
		return fallback
	}
	at, err := time.Parse(time.RFC3339, r.Started)
	if err != nil {
		return fallback
	}
	return ageString(now, at)
}

// RosterSignals bundles the per-frame filter state Render's header needs to
// echo (dotfiles-jw73 rejection #1): tui.Model has ONE committed
// Filter/draft, and FilterRoster (internal/tui/keys.go) applies it to
// roster rows exactly like FilterMessages applies it to the message list —
// so the roster's reduced view is exactly as silent as the message pane's
// was before this task's first pass, and needs the identical indicator.
// Deliberately its own small type rather than reusing render/log.go's
// LogSignals: LogSignals also carries Pending/ForYou/Identity, which mean
// nothing to a roster row, and a caller passing them here by mistake would
// silently do nothing rather than fail to compile.
//
// It is VARIADIC for the same reason LogSignals is: the byte-identical
// output of every pre-existing 4-argument Render call is a success
// criterion, and leaving that call shape untouched is what keeps it honest
// rather than re-asserting it by hand.
type RosterSignals struct {
	FilterQuery   string
	FilterDraft   string
	FilterEditing bool
}

func firstRosterSignalOrZero(vals []RosterSignals) RosterSignals {
	if len(vals) == 0 {
		return RosterSignals{}
	}
	return vals[0]
}

// Render turns one sample into terminal lines, at the given width, as of
// `now` (passed in rather than read from time.Now so rendering is
// deterministic and testable). stale marks a sample whose last refresh
// attempt failed — the header says so, the rows still show the last good
// frame, and nothing is blanked.
func Render(sample *source.Sample, stale bool, now time.Time, width int, signals ...RosterSignals) []string {
	if sample == nil {
		return []string{"agents — waiting for first sample"}
	}

	sig := firstRosterSignalOrZero(signals)
	cols := fitColumns(width)
	widths := effectiveWidths(cols, width)
	age := ageString(now, sample.At)

	var lines []string
	lines = append(lines, truncateToWidth(withRosterFilterSegment(headerLine(sample, stale, age), sig, width), width))
	lines = append(lines, columnHeaderLine(cols, widths))

	if len(sample.Rows) == 0 {
		lines = append(lines, truncateToWidth("(no agents)", width))
		return lines
	}

	for _, row := range sample.Rows {
		lines = append(lines, rowLine(cols, row, rowAge(row, now, age), widths))
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

// withRosterFilterSegment appends the roster's own filter segment to its
// header line, squeezing exactly the way log.go's withCountSegments does
// for the message pane: rosterFilterSegment already bounds the segment
// itself to at most `width` cells, so when base+segment together overrun,
// the BASE is what gets elided (or dropped entirely) — never the segment,
// which is where the operator's own typing lives.
func withRosterFilterSegment(base string, sig RosterSignals, width int) string {
	segment := rosterFilterSegment(sig, width)
	if segment == "" {
		return base
	}
	joiner := "  "
	full := base + joiner + segment
	if width <= 0 || displayWidth(full) <= width {
		return full
	}
	if room := width - displayWidth(joiner) - displayWidth(segment); room > 0 {
		return truncateCells(base, room) + joiner + segment
	}
	return segment
}

// rosterFilterSegment is RosterSignals' entry into filter.go's shared
// buildFilterSegment — see LogSignals' filterSegment (log.go) for why the
// two panes each keep their own small signal type but share the text.
func rosterFilterSegment(sig RosterSignals, width int) string {
	return buildFilterSegment(sig.FilterQuery, sig.FilterDraft, sig.FilterEditing, width)
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
