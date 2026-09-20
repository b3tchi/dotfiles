// log.go renders the message pane: one row per envelope, newest-first (sp033
// T6 — row 0 is the newest arrival, an inbox's natural reading order rather
// than a transcript's), with a derived SUBJECT column (subject.go) instead
// of a nonexistent envelope field (adr0028). It joins nothing itself — every
// value came from the source.MessageSample it was handed, exactly like
// roster.go's Render, and it does not sort: cmd/agent-monitor's
// orderedMessages is what puts rows in this order before RenderLog ever
// sees them (see RenderLog's own doc for why the reorder lives there).
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
	// msgColMark is sp033 T7's row marker: a one-cell column, present only
	// when RenderLog is given an identity address (LogSignals.Identity !=
	// ""), that carries markCell on a row addressed to that address. It is
	// never in msgDropOrder — see fitMsgColumns — because criterion 4 is
	// that the marker survives a narrow terminal: it is what makes a for-you
	// conversation findable after the header's count has been cleared.
	msgColMark
)

var msgColumnHeader = map[msgColumn]string{
	msgColTime:    "TIME",
	msgColFrom:    "FROM",
	msgColTo:      "TO",
	msgColSubject: "SUBJECT",
	msgColMark:    "",
}

// msgFixedWidth is the declared width of every column except SUBJECT, which
// takes whatever width remains after the surviving fixed columns (see
// subjectWidth below).
var msgFixedWidth = map[msgColumn]int{
	msgColTime: 8, // "15:04:05"
	msgColFrom: 12,
	msgColTo:   16,
	msgColMark: 1,
}

// markCell is the row marker itself (sp033 T7 criterion 1/4): plain ASCII,
// rendered on a row whose ToAddresses contains the resolved identity's
// address, alongside every other cell in this package which emits no
// escapes and styles nothing.
const markCell = "*"

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

// fitMsgColumns returns the fixed columns (in display order: [Mark,] Time,
// From, To) that fit alongside SUBJECT's floor at the given width, dropping
// from msgDropOrder until they do (or until none of Time/From/To are left,
// at which point the row is TIME-less and just Mark (if present) plus
// SUBJECT). hasIdentity controls whether Mark is included at all — see
// msgColMark — and it is never a drop candidate: unlike Time/From/To, a
// terminal too narrow to fit it still needs the marker itself (criterion 4).
func fitMsgColumns(width int, hasIdentity bool) []msgColumn {
	cols := []msgColumn{msgColTime, msgColFrom, msgColTo}
	if hasIdentity {
		cols = append([]msgColumn{msgColMark}, cols...)
	}
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
// of now. Rows print in the sample's own order — this renderer does not
// re-sort — and since sp033 T6 that order is newest-first: cmd/agent-monitor
// hands it a sample already reordered by orderedMessages, not
// source.ParseMessages' raw ascending id/time order. Keeping the sort out of
// this package is deliberate: main.go is what threads MessagesCursor through
// SetMessagesLen, the scrolled slice and the detail pane's selection, so it
// is the one place that can keep all three agreeing on what row 0 means; a
// second reorder here would be exactly the hidden-second-order this task's
// anti-pattern list forbids, just moved to a different file.
//
// LogSignals bundles the per-frame counts and identity RenderLog needs
// beyond the sample itself: sp032 T6's Pending (`+N new`), sp033 T7's ForYou
// (`N for you`) and the Identity address T7's row marker compares
// ToAddresses against. Go allows only one variadic parameter, and it must be
// the last one, so a second and third optional int/string cannot be added
// as their own trailing arguments — bundling them into one struct is what
// keeps RenderLog's variadic shape (see below) instead of forcing every
// caller to spell out three positional values, most of which are usually
// zero/empty.
type LogSignals struct {
	Pending  int
	ForYou   int
	Identity string

	// FilterQuery, FilterDraft and FilterEditing are dotfiles-jw73's
	// addition: the message pane's own filter state was rendered nowhere,
	// so a reduced view looked identical to a quiet bus and a `/` draft was
	// typed blind. FilterQuery is the COMMITTED query (tui.Model.Filter.
	// Query) — passed unconditionally, its emptiness is what gates the
	// segment, never a Set bool, because Filter{Set: true, Query: ""} is
	// the documented "cleared" state and must render exactly like no
	// filter at all (see tui.Filter's doc comment). FilterDraft/
	// FilterEditing mirror tui.Model.FilterDraft()/Editing the same way
	// Pending/ForYou already mirror tui.Model's counters: caller-owned
	// state, this package only turns it into text.
	FilterQuery   string
	FilterDraft   string
	FilterEditing bool
}

// pending is sp032 T6's counter, inverted for the head by sp033 T6: how many
// messages have arrived since the message pane stopped being live
// (tui.Model.PendingMessages). A positive value adds a `+N new` segment to
// the header line. sp033 T7 adds ForYou (tui.Model.ForYouCount, `N for you`)
// and Identity (the operator's resolved address, tui column marker
// comparand) the same way. Zero/empty in all three — and the four-argument
// call, which is what --once and every pre-T6/T7 caller makes — renders the
// header and every row byte-for-byte as they did before either existed
// (criterion 5).
//
// It is VARIADIC rather than fixed parameters for exactly that reason. The
// output's byte-identity when nothing is signalled is a success criterion
// with a test suite's worth of assertions already standing on it, and the
// cheapest way to keep those assertions honest is to leave the call they
// make untouched rather than to re-type them all and re-assert what they
// used to say. At most one value is meaningful; extra ones are ignored the
// way a mis-built call deserves rather than summed into a wrong count.
func RenderLog(sample *source.MessageSample, stale bool, now time.Time, width int, signals ...LogSignals) []string {
	if sample == nil {
		return []string{"messages — waiting for first sample"}
	}

	sig := firstSignalOrZero(signals)
	hasIdentity := sig.Identity != ""

	cols := fitMsgColumns(width, hasIdentity)
	subjW := subjectWidth(width, cols)
	widths := map[msgColumn]int{msgColSubject: subjW}
	for _, c := range cols {
		widths[c] = msgFixedWidth[c]
	}
	allCols := append(append([]msgColumn{}, cols...), msgColSubject)

	var lines []string
	lines = append(lines, logHeaderLine(sample, stale, now, sig, width))
	lines = append(lines, msgColumnHeaderLine(allCols, widths))

	if len(sample.Messages) == 0 {
		lines = append(lines, "(no messages)")
		return lines
	}

	for _, m := range sample.Messages {
		lines = append(lines, msgRowLine(m, allCols, widths, sig.Identity))
	}
	return lines
}

func logHeaderLine(sample *source.MessageSample, stale bool, now time.Time, sig LogSignals, width int) string {
	age := ageString(now, sample.At)
	var base string
	if stale {
		base = fmt.Sprintf("messages — STALE (last good sample %s old)", age)
	} else {
		base = fmt.Sprintf("messages — updated %s ago", age)
	}
	forYou := sig.ForYou
	if sig.Identity == "" {
		// Criterion 5: an identity-less caller can only ever mean "no
		// signal", however sig.ForYou happens to be constructed — the
		// header must not carry a count with nothing behind it to compare
		// ToAddresses against.
		forYou = 0
	}
	// dotfiles-jw73 rejection #2: the filter text is budgeted against the room
	// the COUNTS will leave behind, not against the full width. Budgeting it in
	// isolation and appending the counts afterwards is what overflowed — each
	// part fitted alone and their sum did not.
	return withCountSegments(base, filterSegment(sig, filterBudget(width, sig.Pending, forYou)), sig.Pending, forYou, width)
}

// filterSegment turns LogSignals' filter fields into the header's optional
// filter segment via filter.go's buildFilterSegment — shared with roster.go,
// since both panes are filtered by the SAME committed Filter/draft.
func filterSegment(sig LogSignals, width int) string {
	return buildFilterSegment(sig.FilterQuery, sig.FilterDraft, sig.FilterEditing, width)
}

// firstSignalOrZero reads RenderLog's variadic signals argument. No value is
// the pre-T6/T7 call and means nothing pending, nothing for-you, no
// identity.
func firstSignalOrZero(vals []LogSignals) LogSignals {
	if len(vals) == 0 {
		return LogSignals{}
	}
	return vals[0]
}

// withCountSegments appends sp032 T6's `+N new` and sp033 T7's `N for you`
// to a header line and fits the result to width. The two are independent
// (## plan anti-patterns: do not fold `N for you` into `+N new`) and either,
// both or neither can be present — criterion 3.
//
// Only a POSITIVE count is news for either segment: zero is either a live
// pane (pending) or nothing addressed to the operator since the pane froze
// (for-you), and a negative one is a value tui.Model cannot produce but
// which must not render as `+-3 new` if some future caller does. Neither
// present returns base UNCHANGED — byte-for-byte the header this renderer
// emitted before T6/T7 existed, width included, since the header was never
// width-fitted before and fitting it here would be a silent regression on a
// narrow terminal.
//
// When at least one segment IS present the line has to fit, because the
// header is one of the two free-text lines in this file (the other is "(no
// messages)") and a line past the terminal width wraps — the failure every
// column in this package is built to avoid. The COUNTS are what survive the
// squeeze: they are the entire signal that the pane is frozen on purpose (or
// that mail addressed to the operator is waiting), so the prose in front of
// them is elided first, then the separator, and only a terminal too narrow
// for the segment text itself overruns — the same trade-off subjectWidth
// documents for the one column it refuses to drop.
func withCountSegments(base string, filter string, pending, forYou int, width int) string {
	var parts []string
	if filter != "" {
		parts = append(parts, filter)
	}
	parts = append(parts, countParts(pending, forYou)...)
	if len(parts) == 0 {
		return base
	}
	segment := segmentGap + strings.Join(parts, segmentJoin)
	if width <= 0 || displayWidth(base)+displayWidth(segment) <= width {
		// width <= 0 is this package's "do not clamp" convention, the same
		// one paneBudgets and RenderDetail use.
		return base + segment
	}
	if room := width - displayWidth(segment); room > 0 {
		return truncateCells(base, room) + segment
	}
	// Last resort: the segment alone is wider than the terminal. Clamping
	// here is what makes "no header line exceeds width" an invariant of this
	// function rather than a property of whatever its callers happened to
	// pass — dotfiles-jw73 rejection #2 was exactly this branch returning an
	// assembled segment verbatim. `filterBudget` above should normally keep
	// us out of it; this is the floor under that, not a substitute for it.
	return truncateCells(strings.TrimLeft(segment, " "), width)
}

// segmentGap separates the header's base from its first segment; segmentJoin
// separates segments from each other. Named because `filterBudget` has to
// reserve exactly what the assembly above will spend.
const (
	segmentGap  = "  "
	segmentJoin = ", "
)

// countParts renders sp032 T6's `+N new` and sp033 T7's `N for you`. Split
// out of withCountSegments so that the count text has ONE definition: the
// assembly and the budget that reserves room for it cannot drift into
// disagreeing about how wide it is.
func countParts(pending, forYou int) []string {
	var parts []string
	if pending > 0 {
		parts = append(parts, fmt.Sprintf("+%d new", pending))
	}
	if forYou > 0 {
		parts = append(parts, fmt.Sprintf("%d for you", forYou))
	}
	return parts
}

// filterBudget is the width the FILTER segment may occupy, given the counts
// that will be appended after it and the gap that precedes the whole
// segment. Without this the filter is bounded against the full render width
// and the counts push the assembled header past it (dotfiles-jw73 rejection
// #2: a 70-cell draft plus both counts produced a 79-cell header against a
// 60-cell budget).
//
// Returns width unchanged when width <= 0 — this package's "do not clamp"
// convention has to survive the reservation, or a caller asking for no
// clamping would get a 1-cell filter instead.
func filterBudget(width, pending, forYou int) int {
	if width <= 0 {
		return width
	}
	reserved := displayWidth(segmentGap)
	if counts := countParts(pending, forYou); len(counts) > 0 {
		// The counts themselves plus the separator that will join them to
		// the filter segment ahead of them.
		reserved += displayWidth(segmentJoin + strings.Join(counts, segmentJoin))
	}
	budget := width - reserved
	if budget < 1 {
		budget = 1
	}
	return budget
}

func msgColumnHeaderLine(cols []msgColumn, widths map[msgColumn]int) string {
	parts := make([]string, 0, len(cols))
	for _, c := range cols {
		parts = append(parts, pad(msgColumnHeader[c], widths[c]))
	}
	return join(parts)
}

func msgRowLine(m source.Message, cols []msgColumn, widths map[msgColumn]int, identity string) string {
	parts := make([]string, 0, len(cols))
	for _, c := range cols {
		parts = append(parts, pad(msgCellFor(c, m, widths[c], identity), widths[c]))
	}
	return join(parts)
}

func msgCellFor(c msgColumn, m source.Message, width int, identity string) string {
	switch c {
	case msgColMark:
		if identity != "" && forYouRow(m, identity) {
			return markCell
		}
		return ""
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

// forYouRow is sp033 T7 criterion 1: a message is FOR the identity when its
// ToAddresses — the raw recipient addresses sp033 T1 added, never the
// rendered To labels — contains that address. This is an ADDRESS
// comparison, never a label one: a from_address in FromAddress is not in
// ToAddresses (edge case: a sent message is never marked as for-you), and an
// address from a released registration cannot appear in a CURRENT message's
// ToAddresses because adr0034 never reuses one.
func forYouRow(m source.Message, identity string) bool {
	for _, a := range m.ToAddresses {
		if a == identity {
			return true
		}
	}
	return false
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
