package render

// filter.go is dotfiles-jw73's shared filter-segment text: tui.Model has ONE
// committed Filter and ONE draft (internal/tui/keys.go), applied to BOTH the
// roster (FilterRoster) and the message list (FilterMessages) — so both
// panes' headers need the identical "editing filter: <draft>" / "filter:
// <query>" text, cell-truncated the same way. log.go's LogSignals and
// roster.go's RosterSignals stay separate types (each carries fields the
// other pane has no use for — Pending/ForYou/Identity vs nothing extra at
// all), but the text they render from their three shared fields is built
// here once rather than twice.

// filterCursor is the filter draft's trailing cursor marker — the same
// glyph cmd/agent-monitor's composerBodyLines appends to an in-progress
// reply, kept here as its own literal since this package renders no code
// shared with cmd/.
const filterCursor = "▏"

// buildFilterSegment turns a pane's filter state into its header's optional
// filter segment. Editing wins over a committed query even when both are
// set: the composer's region never shows anything but the current draft
// either, and mirroring that (rather than inventing a second shape that
// shows both) is dotfiles-jw73 requirement 5. Neither a non-empty
// draft/query nor editing returns "" — the byte-identical case requirement
// 4 pins — deliberately never keyed on a Set-style bool, since a committed
// empty query (Filter{Set: true, Query: ""}) is the documented "cleared"
// state and must render exactly like no filter was ever committed.
//
// The draft/query is cell-truncated (rejection #1) to fit alongside its own
// fixed prefix and cursor within `width` BEFORE the result reaches either
// caller's own width-fit squeeze (log.go's withCountSegments, roster.go's
// withRosterFilterSegment): both callers' overflow branch returns an
// overlong segment verbatim, so a filter/draft typed longer than the screen
// would otherwise blow the header past width even after everything else is
// elided. truncateHeadCells (not truncateCells) keeps the TAIL — the text
// nearest wherever the operator is typing, or the end of a committed query
// — the same "keep what's most recent" rule composerBodyLines already
// applies to a multi-line reply draft.
func buildFilterSegment(query, draft string, editing bool, width int) string {
	if editing {
		const prefix, suffix = "editing filter: ", filterCursor
		budget := segmentTextBudget(width, prefix, suffix)
		return prefix + truncateHeadCells(draft, budget) + suffix
	}
	if query != "" {
		const prefix = "filter: "
		budget := segmentTextBudget(width, prefix, "")
		return prefix + truncateHeadCells(query, budget)
	}
	return ""
}

// segmentTextBudget is how many cells buildFilterSegment's variable text
// (the draft/query itself) gets so prefix+text+suffix together never exceed
// width — floored at 1 so a pathologically narrow terminal still gets an
// ellipsis rather than a negative/zero truncateHeadCells budget (which
// would silently return "").
func segmentTextBudget(width int, prefix, suffix string) int {
	budget := width - displayWidth(prefix) - displayWidth(suffix)
	if budget < 1 {
		budget = 1
	}
	return budget
}
