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
	"strconv"
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
	lines = append(lines, logHeaderLine(sample.At, stale, now, sig, width))
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

// logHeaderLine takes the sample's own `at` timestamp rather than the sample
// itself (sp034 Task 6 refactor, no behaviour change): RenderThreadLog needs
// the identical header line but carries no *source.MessageSample of its own
// (its data is []LogRow, not []source.Message), so the one piece RenderLog's
// header actually reads off the sample — its At — is what this function takes
// directly, and both callers hand it the same value.
func logHeaderLine(at time.Time, stale bool, now time.Time, sig LogSignals, width int) string {
	age := ageString(now, at)
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

// --- sp034 Task 3: thread and child rows on one column grid ----------------
//
// threadColumn is the ONE grid shared by a thread's own summary row (Task
// 2's KindThread LogRow) and its child rows (KindMessage): "[mark] glyph
// TIME PARTICIPANTS N SUBJECT". A thread row and a child row are laid out by
// exactly this same column set, at the same widths, so SUBJECT starts at
// the same cell on both (## plan: "Row grid is ONE grid" — two grids would
// drift the moment a column drops on a narrow terminal). Only the CONTENT
// each cell renders differs by row Kind; see threadCellFor.
//
// This is a separate enum/machinery from msgColumn's flat grid on purpose:
// the flat renderer (RenderLog above) must stay byte-identical, so nothing
// here is wired into fitMsgColumns, msgCellFor or RenderLog's loop.
type threadColumn int

const (
	// threadColMark mirrors msgColMark: sp033 T7's row marker, present only
	// when a caller supplies a non-empty identity, and never a drop
	// candidate for the same reason msgColMark never is (criterion 4: a
	// for-you conversation must stay findable after every other column has
	// dropped).
	threadColMark threadColumn = iota
	// threadColGlyph is Task 3's own column: "+" collapsed, "-" expanded
	// (dotfiles-qm4h Task 3 — plain ASCII, like the ">"/"v" pair it
	// replaces), on a thread row; blank on a child row. Never a drop
	// candidate — the named edge case is that a list whose expansion state
	// is invisible cannot be navigated, so the glyph survives exactly as
	// far as the mark does.
	threadColGlyph
	// threadColTime mirrors msgColTime: both row kinds carry TIME.
	threadColTime
	// threadColParticipants carries the newest message's direction --
	// "a > b" collapsed, sender-only "a" expanded (dotfiles-qm4h Task 3) --
	// on a thread row, and a two-cell-indented FROM on a child row (## plan:
	// the participants column is spent differently per kind, not a
	// different column). It is this grid's droppable column, exactly the
	// role msgColTo plays in the flat grid's drop order.
	threadColParticipants
	// threadColCount carries the thread's member count on a thread row and
	// is blank on a child row. Clamped, never a drop candidate: a count
	// column that disappeared would look like the thread lost its count
	// rather than the terminal ran out of room.
	threadColCount
	// threadColSubject mirrors msgColSubject: the never-dropped floor,
	// derived through the existing DeriveSubject on both row kinds.
	threadColSubject
)

// threadFixedWidth is threadColumn's counterpart to msgFixedWidth: the
// declared width of every column except SUBJECT. threadCountWidth is sized
// to "999+" (edge case: a count of 999+ does not widen the grid; the column
// clamps rather than grows).
var threadFixedWidth = map[threadColumn]int{
	threadColMark:         1,
	threadColGlyph:        1,
	threadColTime:         8, // "15:04:05"
	threadColParticipants: 20,
	threadColCount:        4, // "999+"
}

// threadDropOrder is this grid's drop priority when the terminal is too
// narrow for both fixed columns plus SUBJECT's floor: PARTICIPANTS drops
// first (mirroring msgColTo dropping first in the flat grid), then TIME.
// Mark, glyph, count and SUBJECT are never drop candidates.
var threadDropOrder = []threadColumn{threadColParticipants, threadColTime}

// fitThreadColumns is fitMsgColumns' counterpart for the thread grid: the
// fixed columns (in display order: [Mark,] Glyph, Time, Participants,
// Count) that fit alongside SUBJECT's floor at the given width, dropping
// from threadDropOrder until they do.
func fitThreadColumns(width int, hasIdentity bool) []threadColumn {
	cols := []threadColumn{threadColGlyph, threadColTime, threadColParticipants, threadColCount}
	if hasIdentity {
		cols = append([]threadColumn{threadColMark}, cols...)
	}
	for len(cols) > 0 && threadFixedLineWidth(cols)+1+minSubjectWidth > width {
		dropped := false
		for _, d := range threadDropOrder {
			if idx := indexOfThreadCol(cols, d); idx >= 0 {
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

func threadFixedLineWidth(cols []threadColumn) int {
	w := 0
	for i, c := range cols {
		if i > 0 {
			w++ // single-space separator
		}
		w += threadFixedWidth[c]
	}
	return w
}

func indexOfThreadCol(cols []threadColumn, target threadColumn) int {
	for i, c := range cols {
		if c == target {
			return i
		}
	}
	return -1
}

// threadSubjectWidth is subjectWidth's counterpart for the thread grid.
func threadSubjectWidth(width int, cols []threadColumn) int {
	used := threadFixedLineWidth(cols)
	if len(cols) > 0 {
		used++ // separator before SUBJECT
	}
	w := width - used
	if w < minSubjectWidth {
		w = minSubjectWidth
	}
	return w
}

// threadParticipantIndent is how far a child row's FROM is indented inside
// the shared participants column (criterion 2: "FROM indented by two cells
// inside the participants column").
const threadParticipantIndent = "  "

// threadCountClamp is the count this grid's N column stops growing text for
// (edge case: a count of 999+ does not widen the grid).
const threadCountClamp = 999

// threadColumnLayout is the thread grid's column-fitting preamble, shared by
// every row RenderThreadRow renders AND by RenderThreadLog's own column
// header (sp034 Task 6): the same (allCols, widths) computation for both, so
// the header and the data rows can never drift apart the way two independent
// computations could on a resize. Task 3 shipped a speculative
// ThreadColumnHeaderLine and deleted it, unused, before this preamble had a
// second caller to share it with; Task 6 gives it that second caller and
// extracts the preamble at the same time rather than duplicating it.
func threadColumnLayout(width int, hasIdentity bool) (allCols []threadColumn, widths map[threadColumn]int) {
	cols := fitThreadColumns(width, hasIdentity)
	subjW := threadSubjectWidth(width, cols)
	widths = map[threadColumn]int{threadColSubject: subjW}
	for _, c := range cols {
		widths[c] = threadFixedWidth[c]
	}
	allCols = append(append([]threadColumn{}, cols...), threadColSubject)
	return allCols, widths
}

// RenderThreadRow renders one row of the pane's threaded row list — a
// thread's own summary row or one of its child rows (sp034 Task 2's
// LogRow) — on threadColumn's ONE grid. thread is the Thread that owns row
// (looked up by row.Key), supplying PARTICIPANTS and the full member list a
// thread row's for-you mark is computed over — data LogRow itself does not
// carry, since a KindThread row's own Message field is only its NEWEST
// member (Task 2's doc). RenderThreadRow establishes no order and re-sorts
// nothing; it renders exactly the one row it is given.
func RenderThreadRow(row LogRow, thread Thread, width int, identity string) string {
	allCols, widths := threadColumnLayout(width, identity != "")

	parts := make([]string, 0, len(allCols))
	for _, c := range allCols {
		parts = append(parts, pad(threadCellFor(c, row, thread, widths[c], identity), widths[c]))
	}
	return join(parts)
}

// threadColumnHeader names threadColumn's header text — msgColumnHeader's
// counterpart. Mark and glyph carry no label of their own (a one-cell mark/
// glyph column has no room for a header word, exactly like msgColMark), and
// COUNT's header is the single letter N so it never itself forces the count
// column wider than threadFixedWidth's own "999+" allowance.
var threadColumnHeader = map[threadColumn]string{
	threadColMark:         "",
	threadColGlyph:        "",
	threadColTime:         "TIME",
	threadColParticipants: "PARTICIPANTS",
	threadColCount:        "N",
	threadColSubject:      "SUBJECT",
}

// threadColumnHeaderLine is msgColumnHeaderLine's counterpart for the thread
// grid (sp034 Task 6): the header row RenderThreadLog prints above the
// pane's data rows, built from the SAME (cols, widths) threadColumnLayout
// gives every data row, so SUBJECT starts at the same cell on the header as
// it does on every row beneath it.
func threadColumnHeaderLine(cols []threadColumn, widths map[threadColumn]int) string {
	parts := make([]string, 0, len(cols))
	for _, c := range cols {
		parts = append(parts, pad(threadColumnHeader[c], widths[c]))
	}
	return join(parts)
}

// RenderThreadLog is RenderLog's counterpart for the pane's THREADED row list
// (sp034 Task 6): the identical header line (logHeaderLine — Pending/ForYou/
// Identity/Filter behave exactly as they do in flat mode) but a column header
// and data rows built from threadColumn's grid (Task 3) instead of
// msgColumn's. rows is the pane's already-flattened row list — render.
// ThreadRows' own output (Task 2), sliced to whatever the caller's scroll
// offset shows — so this function establishes no order of its own, matching
// ## plan's "do not derive a second order": it only lays out the rows it is
// given. threads is keyed by Thread.Key (render.Threads' own output), so
// RenderThreadRow's per-row PARTICIPANTS/member lookup needs no second
// derivation here.
//
// haveSample distinguishes RenderLog's "no sample yet" case (the identical
// "messages — waiting for first sample" line) from "a sample with zero rows"
// ("(no messages)") — this function's row list carries no sample pointer of
// its own to be nil, unlike RenderLog's *source.MessageSample, so the caller
// states the distinction directly.
func RenderThreadLog(rows []LogRow, threads map[string]Thread, haveSample bool, sampleAt time.Time, stale bool, now time.Time, width int, signals ...LogSignals) []string {
	if !haveSample {
		return []string{"messages — waiting for first sample"}
	}

	sig := firstSignalOrZero(signals)
	allCols, widths := threadColumnLayout(width, sig.Identity != "")

	var lines []string
	lines = append(lines, logHeaderLine(sampleAt, stale, now, sig, width))
	lines = append(lines, threadColumnHeaderLine(allCols, widths))

	if len(rows) == 0 {
		lines = append(lines, "(no messages)")
		return lines
	}

	for _, row := range rows {
		lines = append(lines, RenderThreadRow(row, threads[row.Key], width, sig.Identity))
	}
	return lines
}

func threadCellFor(c threadColumn, row LogRow, thread Thread, width int, identity string) string {
	switch c {
	case threadColMark:
		return threadMarkCell(row, thread, identity)
	case threadColGlyph:
		return threadGlyphCell(row)
	case threadColTime:
		return timeCell(row.Message.At)
	case threadColParticipants:
		return threadParticipantsCell(row, thread)
	case threadColCount:
		return threadCountCell(row)
	case threadColSubject:
		return DeriveSubject(row.Message.Kind, row.Message.Content, width)
	default:
		return ""
	}
}

// threadMarkCell is criterion 3: a thread row carries the mark when ANY
// member of its thread is addressed to identity (thread.Messages, not just
// row.Message — the thread row's own Message is only the newest member, so
// a for-you message buried earlier in the thread would be invisible to a
// mark computed from row.Message alone). A child row carries the mark only
// when its own single message is — the existing ADDRESS comparison,
// forYouRow, unchanged from sp033 T7.
func threadMarkCell(row LogRow, thread Thread, identity string) string {
	if identity == "" {
		return ""
	}
	if row.Kind == KindMessage {
		if forYouRow(row.Message, identity) {
			return markCell
		}
		return ""
	}
	for _, m := range thread.Messages {
		if forYouRow(m, identity) {
			return markCell
		}
	}
	return ""
}

// threadGlyphCell is dotfiles-qm4h Task 3's glyph pair: "+" collapsed, "-"
// expanded (plain ASCII, replacing sp034 Task 3's ">"/"v"), on a thread row;
// blank on a child row (criterion 2). sp035 Task 2 adds a third blank case:
// a thread row whose Expandable is false (Thread.Count == 1, derived once by
// ThreadRows — see LogRow.Expandable's own doc) has nothing to fold out, so
// it carries no glyph either. The cell still occupies its column (pad, in
// the caller, keeps the width), so the grid does not shift — only the glyph
// CONTENT is blank, exactly like a child row's.
func threadGlyphCell(row LogRow) string {
	if row.Kind != KindThread {
		return ""
	}
	if !row.Expandable {
		return ""
	}
	if row.Expanded {
		return "-"
	}
	return "+"
}

// threadPartyLabel resolves one participant's display label the SAME way
// thread.Participants already does (sp034 Task 1's participantLabels): the
// thread's own Key (sorted addresses) and Participants (labels, same order)
// are a positional pair, so looking addr up there reuses that resolution --
// including its own shortAddress fallback for an address no message in the
// thread ever supplied a trustworthy label for -- rather than re-deriving
// it. addr == "" (an envelope with no address field at all, sp034 Task 1's
// edge case) has nothing to look up, so raw -- the message's own From/To
// text -- is what is left to show.
func threadPartyLabel(addr, raw string, thread Thread) string {
	if addr != "" {
		for i, a := range strings.Split(thread.Key, threadKeySep) {
			if a == addr && i < len(thread.Participants) {
				return thread.Participants[i]
			}
		}
		return orDash(shortAddress(addr))
	}
	return orDash(raw)
}

// threadDirectionRecipients resolves every recipient of m through
// threadPartyLabel, comma-joined -- the collapsed cell's "to" side. A
// length mismatch between To and ToAddresses (the same malformed-envelope
// case detail.go's own mismatch handling guards) falls back to the raw To
// labels rather than pairing a label with the wrong address.
func threadDirectionRecipients(m source.Message, thread Thread) string {
	if len(m.To) != len(m.ToAddresses) {
		labels := make([]string, len(m.To))
		for i, to := range m.To {
			labels[i] = orDash(to)
		}
		return strings.Join(labels, ",")
	}
	labels := make([]string, len(m.ToAddresses))
	for i, addr := range m.ToAddresses {
		labels[i] = threadPartyLabel(addr, m.To[i], thread)
	}
	return strings.Join(labels, ",")
}

// threadParticipantsCell is dotfiles-qm4h Task 3's direction cell (a thread
// row) and sp034 Task 3's unchanged child-row form (criterion 2: its own
// message's FROM, indented, and — deliberately — no recipient anywhere: the
// recipient is implicit in the thread's own participant pair and TO is
// never rendered on a child row).
//
// A thread row renders row.Message — the thread's NEWEST member (Task 2's
// doc) — not thread.Participants' address-sorted pair: COLLAPSED, "<from> >
// <to>", so the row reports who spoke LAST rather than a fixed, grouping-
// only ordering; EXPANDED, only the newest SENDER, since the children below
// already carry each message's own sender and repeating the recipient above
// rows that already say it spends width on a constant (## solution). This
// is display order WITHIN the cell only — thread.Key, thread.Participants
// and the thread's own grouping are never touched here (## plan's
// anti-pattern: do not reorder the thread KEY).
func threadParticipantsCell(row LogRow, thread Thread) string {
	if row.Kind == KindMessage {
		return threadParticipantIndent + orDash(shortAddress(row.Message.From))
	}
	newest := row.Message
	from := threadPartyLabel(newest.FromAddress, newest.From, thread)
	if row.Expanded {
		return from
	}
	return from + " > " + threadDirectionRecipients(newest, thread)
}

// threadCountCell is criterion 1's N cell (a thread row's member count,
// clamped per threadCountClamp) and criterion 2's blank (a child row never
// repeats the count).
func threadCountCell(row LogRow) string {
	if row.Kind != KindThread {
		return ""
	}
	if row.Count > threadCountClamp {
		return strconv.Itoa(threadCountClamp) + "+"
	}
	return strconv.Itoa(row.Count)
}
