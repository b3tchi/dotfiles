// agent-monitor is the interactive terminal view over agent-census's
// published roster and pi-worker's message bus. Per adr0030, this binary IS
// the interface — there is no nushell/actions/ wrapper, and it links
// straight to ~/.local/bin.
//
// sp030 T8 wired the roster pane scaffold: a slow, gated sample on a ticker,
// a forced refresh on `r`, and a plain render loop. sp030 T9 added the
// second pane — messages, sampled on their own fast, ungated ticker — and
// `--once`, a non-interactive single-frame mode that composes in a pipe (no
// raw mode, no alternate screen). sp030 T10 (this file) extracts the
// PROVISIONAL inline key handling those left behind into internal/tui:
// focus, filter and scroll now live in a tui.Model driven by a tui.Decoder,
// and terminal restore is wired through a tui.Restorer so it fires exactly
// once regardless of which of several goroutines gets there first — see
// enterInteractiveMode's and runInteractive's comments for why that matters
// specifically for a panic in a background sampler's render callback.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"agent-monitor/internal/render"
	"agent-monitor/internal/source"
	"agent-monitor/internal/tui"

	"golang.org/x/term"
)

const (
	// pollInterval is the roster's gated poll cadence: cheap (agent-census's
	// --fast/--if-changed path), so a few seconds is fine. `r` bypasses it
	// entirely for an on-demand full read.
	pollInterval = 3 * time.Second

	// piBoundInterval is the forced, ungated roster refresh's cadence. It
	// exists because agent-census's --if-changed gate fingerprints claude
	// account files only (dotfiles-eee4) — a pi worker changing state never
	// opens the gate, so relying on pollInterval alone would leave pi rows
	// stale indefinitely on a machine where claude happens to stay quiet.
	// This clock pays the full per-account probe cost (~600ms, ft012) on
	// purpose, far less often than pollInterval, to put a finite ceiling on
	// pi staleness instead.
	piBoundInterval = 20 * time.Second

	// messagesInterval is the message pane's own ticker. Unlike the roster,
	// `pi-worker messages --json` has no --if-changed gate to respect — it
	// is a local file read, cheap enough to re-read in full every tick — so
	// there is only one clock here, not two (sp030 T9 design note).
	messagesInterval = 2 * time.Second

	// detailCapRows and detailCapDivisor bound the detail pane's share of the
	// frame (sp031 T5): at most height/detailCapDivisor lines, or
	// detailCapRows, whichever is smaller — the cap TestFitPanes_
	// DetailCapNeverExceedsThirdOrEight pins so an 80-row terminal never
	// gives the pane half the screen.
	detailCapRows    = 8
	detailCapDivisor = 3

	// headerLines is how many lines Render/RenderLog always spend on a
	// pane's own header (the status line plus the column header row),
	// regardless of how many data rows follow. It converts a pane's total
	// rendered line budget into the data-row viewport
	// SetRosterViewport/SetMessagesViewport expect.
	headerLines = 2

	// minPaneRows is the floor, in total RENDERED lines (header included) per
	// pane, below which roster or messages is considered squeezed into
	// uselessness. detailCap checks roster+messages' combined line budget
	// against minPaneRows*2 and hides the detail pane rather than push
	// either of them under it.
	minPaneRows = 2
)

func main() {
	project := flag.String("project", "", "restrict the roster to one project")
	once := flag.Bool("once", false, "render one frame to stdout and exit 0: no raw mode, no alternate screen, so it composes in a pipe")
	flag.Parse()

	if *once {
		if err := runOnce(os.Stdout, *project); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	runInteractive(*project)
}

// runOnce renders exactly one frame — a forced roster refresh plus one
// ungated message poll — and writes it to w as plain text: no ANSI colour,
// no cursor-home/clear escape, no alternate-screen or raw-mode sequence.
// That is what "composes in a pipe" means: the byte stream w receives must
// contain nothing a terminal would interpret as a control sequence.
//
// project is --project's value, forwarded verbatim from main() (sp031 T3):
// --once has no key input, so nothing ever commits an interactive filter,
// but --project is a startup argument, not a keystroke, and applies here
// exactly as it does in runInteractive.
func runOnce(w io.Writer, project string) error {
	if err := source.Available(); err != nil {
		return err
	}
	if err := source.MessagesAvailable(); err != nil {
		return err
	}

	ctx := context.Background()

	censusMonitor := source.NewMonitor(source.NewSampler(stampPath()))
	censusMonitor.Refresh(ctx)

	msgMonitor := source.NewMessagesMonitor(source.NewMessagesSampler())
	msgMonitor.Tick(ctx)

	// --once has no key input, so nothing ever filters or scrolls a frame
	// it renders via a keystroke — a fresh, untouched Model is exactly "no
	// interactive filter, no scroll", the same state an interactive session
	// starts in too. --project is set directly, since it is not something a
	// key ever commits.
	model := tui.NewModel()
	model.Project = project
	for _, line := range buildFrame(model, censusMonitor, msgMonitor, time.Now(), terminalWidth(), 0) {
		fmt.Fprintln(w, line)
	}
	return nil
}

// runInteractive drives two samplers (roster + messages), a tui.Model for
// key-driven state, and draws their combined, filtered, scrolled frame.
// project is --project's value (sp031 T3), set on the model once here and
// never touched again — no key mutates it, unlike the interactive `/`
// filter.
func runInteractive(project string) {
	// adr0014 guard 1, fail fast on unrecoverable setup: checked once, here,
	// before any loop starts. A missing dependency is not something a retry
	// fixes, so agent-monitor says so once and exits — never an empty UI
	// that looks like "no agents".
	if err := source.Available(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := source.MessagesAvailable(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	censusMonitor := source.NewMonitor(source.NewSampler(stampPath()))
	msgMonitor := source.NewMessagesMonitor(source.NewMessagesSampler())
	model := tui.NewModel()
	model.Project = project

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// First frame: forced, ungated reads on both panes so startup never
	// shows "waiting for first sample" when a perfectly good read is one
	// exec away.
	censusMonitor.Refresh(ctx)
	msgMonitor.Tick(ctx)

	restoreTerminal := enterInteractiveMode()

	// restorer makes "restore the terminal exactly once" true regardless of
	// WHICH exit path gets there first: this defer covers a normal quit
	// (`q`), a signal, or a panic on THIS (the main) goroutine. It does not
	// by itself cover a panic in a render path running on a background
	// sampler goroutine — draw, invoked from source.RunLoop's and
	// source.RunMessagesLoop's onTick below, runs on ITS OWN goroutine, and
	// Go never runs one goroutine's deferred calls to save another's panic.
	// Those two goroutines get their own restorer.Guard below instead, and
	// sync.Once (inside tui.Restorer) is what makes exactly one of these
	// several defers actually do the restoring, whichever fires first. See
	// tui.Restorer's doc comment for the full reasoning.
	restorer := tui.NewRestorer(restoreTerminal)
	defer restorer.Restore()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	keys := make(chan byte)
	go readKeys(keys)

	draw := func() {
		lines := buildFrame(model, censusMonitor, msgMonitor, time.Now(), terminalWidth(), terminalHeight())
		writeFrame(lines)
	}
	draw()

	go restorer.Guard(func() {
		source.RunLoop(ctx, censusMonitor, pollInterval, piBoundInterval, func(changed bool) {
			if changed {
				draw()
			}
		})
	})
	go restorer.Guard(func() {
		source.RunMessagesLoop(ctx, msgMonitor, messagesInterval, func(changed bool) {
			if changed {
				draw()
			}
		})
	})

	dec := &tui.Decoder{}
	for {
		select {
		case <-sigCh: // SIGINT/SIGTERM take the same restore path as `q`: return
			return
		case <-ctx.Done():
			return
		case b, ok := <-keys:
			if !ok {
				return
			}
			key, ready := dec.Feed(b)
			if !ready {
				continue // mid-escape-sequence; wait for the rest
			}
			outcome := model.HandleKey(key)
			if outcome.Quit {
				return
			}
			if outcome.ForceRefresh {
				censusMonitor.Refresh(ctx)
				msgMonitor.Tick(ctx)
			}
			draw()
		}
	}
}

// buildFrame is runInteractive's and runOnce's entry point: it resolves the
// two monitors' last samples and staleness, then hands off to renderFrame,
// which does the actual composition and is what tests drive directly (a
// *source.Monitor's last sample is unexported and only settable by execing
// a real or stubbed binary — renderFrame takes samples directly so a test
// can hand-build one).
func buildFrame(model *tui.Model, censusMonitor *source.Monitor, msgMonitor *source.MessagesMonitor, now time.Time, width, height int) []string {
	return renderFrame(model, censusMonitor.Last(), censusMonitor.Stale(), msgMonitor.Last(), msgMonitor.Stale(), now, width, height)
}

// renderFrame stacks the roster pane, the message pane and (when it fits)
// the detail pane, separated by blank lines, into a single list of terminal
// lines. Neither render function talks to another; this is the only place
// that joins them, and it joins rendered TEXT, not data. model's committed
// filter, each pane's cursor-derived scroll, and the detail toggle are all
// applied here, to a COPY of the last good sample — the sample itself is
// never mutated, so a later change to the filter or scroll can still see
// every row the sampler ever captured.
//
// height is the terminal's row count, or 0 for "do not clamp, no detail, no
// toggle" — which is what --once passes (runOnce/buildFrame's height==0
// path): a pipe has no cursor and no height, so a consumer asked for the
// whole frame exactly as it rendered before this task.
func renderFrame(model *tui.Model, censusSample *source.Sample, censusStale bool, msgSample *source.MessageSample, msgStale bool, now time.Time, width, height int) []string {
	// Order matters, and is the whole point of this arrangement (sp031 T1's
	// binding criterion: a resized terminal cannot leave the cursor
	// off-screen). Filter FIRST — that fixes each pane's row count and, via
	// SetRosterLen/SetMessagesLen, clamps the cursor AND the scroll (sp032
	// T1: the scroll is clamped into range, never re-derived from the
	// cursor, so a wheel offset survives a sampler tick). Derive THIS frame's
	// pane budgets from those counts and THIS frame's height, and report the
	// resulting viewports to the model. Only THEN slice by scroll and
	// render: the scroll the slice uses is now the one this height implies,
	// so a shrunk terminal re-fits within the draw that observed it rather
	// than one draw later. Deriving the budgets before rendering is what
	// breaks the apparent circularity (slicing needs pane sizes, pane sizes
	// looked like they needed rendered output): paneBudgets needs only LINE
	// COUNTS, and a pane's line count is a pure function of its row count.
	rosterRows := filterRosterRows(model, censusSample)
	msgRows := filterMessageRows(model, msgSample)
	rosterLines := paneLines(censusSample != nil, len(rosterRows))
	logLines := paneLines(msgSample != nil, len(msgRows))

	if height > 0 {
		rosterBudget, logBudget, _, _ := paneBudgets(rosterLines, logLines, height, model.DetailVisible)
		model.SetRosterViewport(viewportRows(min(rosterLines, rosterBudget)))
		model.SetMessagesViewport(viewportRows(min(logLines, logBudget)))
	}

	roster := render.Render(scrolledCensusSample(censusSample, rosterRows, model.RosterScroll), censusStale, now, width)
	log := render.RenderLog(scrolledMessageSample(msgSample, msgRows, model.MessagesScroll), msgStale, now, width)

	// fitPanes re-derives the same budgets from the rendered line counts and
	// does the actual trimming. The two derivations agree: a pane whose
	// rendered length differs from rosterLines/logLines is one that scrolled,
	// and a pane only scrolls when it is at or over its budget — so the
	// "is this pane shorter than its share?" test lands the same way either
	// way, and the surplus is redistributed identically.
	roster, log, detailBudget, detailShown := fitPanes(roster, log, height, model.DetailVisible)

	// Make the cursor and the focus VISIBLE (dotfiles-uyih). sp031 shipped a
	// cursor that moves, a scroll that follows it and a detail pane that
	// tracks it — and nothing that drew any of it, so `tab` looked like a
	// dead key. Marking happens HERE, after rendering and trimming, for two
	// reasons: render/ stays free of escape bytes, so its own "no line
	// exceeds the width" tests keep measuring real text; and reverse video
	// costs zero display cells, so marking cannot break that invariant in
	// the first place.
	//
	// height > 0 is the interactive gate. --once renders through this same
	// function and must emit no ESC byte at all (sp030 T9, asserted in
	// TestRunOnce): a pipe has no cursor to show.
	if height > 0 {
		roster = markPane(roster, model.Focus == tui.PaneRoster, model.RosterCursor, model.RosterScroll, len(rosterRows))
		log = markPane(log, model.Focus == tui.PaneMessages, model.MessagesCursor, model.MessagesScroll, len(msgRows))
	}

	var lines []string
	lines = append(lines, roster...)
	lines = append(lines, "")
	lines = append(lines, log...)

	if detailShown {
		lines = append(lines, "")
		lines = append(lines, render.RenderDetail(selectedMessage(model, msgSample), width, detailBudget)...)
	}
	return lines
}

// styleOn/styleOff are the reverse-video pair that marks the focused pane's
// header and the selected row. Both are SGR attribute toggles, not colours:
// they cost zero display cells, so a marked line occupies exactly the width
// its text did, and they restore only the attribute they set (27 turns off
// reverse, unlike a blanket 0 reset) so no other styling is clobbered.
const (
	styleOn  = "\x1b[7m"
	styleOff = "\x1b[27m"
)

// markPane applies one pane's interactive affordances: its header line in
// reverse video when the pane holds focus, and its selected data row in
// reverse video.
//
// cursor is an index into the pane's FULL filtered row list and scroll is
// the first row currently visible, so cursor-scroll is the selected row's
// offset within the lines this pane actually rendered. rows is that full
// list's length: zero means there is nothing to select, and the
// "(no agents)"/"(no messages)" placeholder occupying the first data line
// must NOT be marked as though it were a row.
//
// Since sp032 T1 the cursor may legally sit OUTSIDE the scrolled window (the
// operator scrolled away from their selection), above it or below it. The
// bounds test below already covers both: an offset before the first data
// line or past the last rendered line simply marks nothing, which is the
// correct frame for a selection that is not on screen.
func markPane(lines []string, focused bool, cursor, scroll, rows int) []string {
	if len(lines) == 0 {
		return lines
	}
	out := make([]string, len(lines))
	copy(out, lines)

	if focused {
		out[0] = styleOn + out[0] + styleOff
	}
	if rows <= 0 {
		return out
	}
	// headerLines is the pane header plus the column header; data rows start
	// after them. A pane still waiting for its first sample renders a single
	// line and never reaches here.
	if i := headerLines + (cursor - scroll); i > headerLines-1 && i < len(out) {
		out[i] = styleOn + out[i] + styleOff
	}
	return out
}

// viewportRows converts a pane's total rendered line count (its fixed
// headerLines plus data rows, or the "(no agents)"/"(no messages)"
// placeholder) into the data-row viewport tui.Model's SetRosterViewport /
// SetMessagesViewport expect. Never negative, even for a pane clamped down
// to just its header.
func viewportRows(paneLines int) int {
	n := paneLines - headerLines
	if n < 0 {
		return 0
	}
	return n
}

// selectedMessage returns the message under the message pane's cursor, from
// the full FILTERED list — not the slice already scrolled into RenderLog's
// view — so the detail pane tracks selection regardless of what happens to
// be scrolled on screen. nil means nothing is selected: an empty log, or (as
// a guard, not expected given SetMessagesLen's same-pass clamp) a cursor
// past the end; either way RenderDetail's own nil case is the placeholder.
func selectedMessage(model *tui.Model, sample *source.MessageSample) *source.Message {
	if sample == nil {
		return nil
	}
	msgs := model.FilterMessages(sample.Messages)
	if model.MessagesCursor < 0 || model.MessagesCursor >= len(msgs) {
		return nil
	}
	return &msgs[model.MessagesCursor]
}

// fitPanes trims three stacked panes so the whole frame fits in height rows:
// roster, messages, and — when there is room and the toggle allows it — the
// detail pane.
//
// dotfiles-9x2m / dotfiles-m0km: without this the frame is however many
// lines the data happens to produce, writeFrame prints all of them, and a
// frame taller than the terminal makes the TERMINAL scroll — carrying the
// roster off the top where no amount of in-pane scrolling can bring it
// back. The pane scroll offsets were being applied correctly and were
// simply invisible. A third region makes that failure mode cheaper to
// reintroduce, so the invariant is re-asserted here rather than assumed.
//
// height<=0 (the --once contract) returns roster and log untouched and
// detail always hidden — no clamping at all, exactly as before this task.
//
// The detail pane is capped independently at roughly a third of height or
// detailCapRows, whichever is smaller, and hides itself (falling back to
// the original two-way split) when detailVisible is false or when giving it
// that budget would leave less than minPaneRows*2 lines for roster+messages
// combined — the "squeezed into uselessness" floor the edge_cases call out.
// Below that, roster and messages redistribute surplus exactly as they did
// before detail existed: each gets half the remaining rows, minus the blank
// separator(s); whatever a short pane does not use goes to the other, so a
// machine with three agents and a busy bus still fills the screen with
// messages rather than padding. Trimming takes from the BOTTOM, which keeps
// each pane's header line — a pane whose header scrolled away is
// unreadable, and the header is what carries the staleness indicator.
func fitPanes(roster, log []string, height int, detailVisible bool) (rosterOut, logOut []string, detailBudget int, detailShown bool) {
	rosterBudget, logBudget, detailBudget, detailShown := paneBudgets(len(roster), len(log), height, detailVisible)
	return clamp(roster, rosterBudget), clamp(log, logBudget), detailBudget, detailShown
}

// paneBudgets is fitPanes' arithmetic with the []string arguments replaced
// by their lengths, so renderFrame can ask for this frame's budgets BEFORE
// anything is rendered — the ordering sp031 T1's criterion needs (see
// renderFrame). A budget of -1 means "do not clamp" (the height<=0 --once
// contract); clamp treats any negative n that way.
func paneBudgets(rosterLines, logLines, height int, detailVisible bool) (rosterBudget, logBudget, detailBudget int, detailShown bool) {
	if height <= 0 {
		return -1, -1, 0, false
	}

	detailBudget, detailShown = detailCap(height)
	if !detailVisible {
		detailBudget, detailShown = 0, false
	}

	seps := 1 // the blank line between roster and messages
	if detailShown {
		seps = 2 // plus the blank line between messages and detail
	}

	avail := height - seps - detailBudget
	if avail < 2 {
		// Degenerate terminal: one row each is the most that is still two
		// panes. Below that there is nothing useful to show.
		return 1, 1, detailBudget, detailShown
	}

	rosterBudget = avail / 2
	logBudget = avail - rosterBudget
	if rosterLines < rosterBudget {
		logBudget += rosterBudget - rosterLines
	} else if logLines < logBudget {
		rosterBudget += logBudget - logLines
	}
	return rosterBudget, logBudget, detailBudget, detailShown
}

// paneLines predicts how many lines render.Render/render.RenderLog will
// produce for a pane holding rows data rows, without rendering it: one line
// for the "waiting for first sample" state, headerLines+1 for the empty
// placeholder, headerLines+rows otherwise. It is the inverse of viewportRows
// and the reason the budgets can be computed before the render.
func paneLines(haveSample bool, rows int) int {
	if !haveSample {
		return 1
	}
	if rows == 0 {
		return headerLines + 1 // the "(no agents)"/"(no messages)" placeholder
	}
	return headerLines + rows
}

// detailCap decides the detail pane's line budget (header included) for a
// given terminal height: at most height/detailCapDivisor, or detailCapRows,
// whichever is smaller. It hides the pane (0, false) when that budget would
// leave roster+messages less than minPaneRows*2 combined lines — the point
// past which a third region stops being a convenience and starts being the
// reason the other two are unreadable.
func detailCap(height int) (budget int, shown bool) {
	budget = height / detailCapDivisor
	if budget > detailCapRows {
		budget = detailCapRows
	}
	if budget < 1 {
		return 0, false
	}
	if height-budget-2 < minPaneRows*2 {
		return 0, false
	}
	return budget, true
}

func clamp(lines []string, n int) []string {
	if n < 0 || len(lines) <= n {
		return lines
	}
	return lines[:n]
}

// filterRosterRows applies model's committed filter to sample's rows without
// mutating sample, and calls SetRosterLen so scroll is bounded by the
// CURRENT (post-filter) row count — a filter that just shrank the roster
// must not leave scroll pointing past its new end. It deliberately does NOT
// apply scroll: scrolling is scrolledCensusSample's job, and happens only
// after this frame's viewport has been set (see renderFrame).
func filterRosterRows(model *tui.Model, sample *source.Sample) []source.Row {
	if sample == nil {
		return nil
	}
	rows := model.FilterRoster(sample.Rows)
	model.SetRosterLen(len(rows))
	return rows
}

// filterMessageRows is filterRosterRows' twin for the message pane.
func filterMessageRows(model *tui.Model, sample *source.MessageSample) []source.Message {
	if sample == nil {
		return nil
	}
	msgs := model.FilterMessages(sample.Messages)
	model.SetMessagesLen(len(msgs))
	return msgs
}

// scrolledCensusSample applies the roster pane's scroll offset (dropping
// that many rows from the top — a scrolled-past row is simply not in the
// slice render.Render receives) to already-filtered rows, returning a fresh
// sample so the original is never mutated.
func scrolledCensusSample(sample *source.Sample, rows []source.Row, scroll int) *source.Sample {
	if sample == nil {
		return nil
	}
	return &source.Sample{Rows: rows[scroll:], At: sample.At}
}

// scrolledMessageSample is scrolledCensusSample's twin for the message pane.
func scrolledMessageSample(sample *source.MessageSample, msgs []source.Message, scroll int) *source.MessageSample {
	if sample == nil {
		return nil
	}
	return &source.MessageSample{Messages: msgs[scroll:], At: sample.At}
}

// readKeys feeds raw stdin bytes to ch, closing it on EOF/error (stdin
// closed, e.g. under a non-interactive harness). Byte-at-a-time is
// deliberate: tui.Decoder is what assembles multi-byte sequences (arrow
// keys) back into whole Key events, so this loop stays a dumb byte pump.
func readKeys(ch chan<- byte) {
	defer close(ch)
	buf := make([]byte, 1)
	for {
		n, err := os.Stdin.Read(buf)
		if n > 0 {
			ch <- buf[0]
		}
		if err != nil {
			return
		}
	}
}

const (
	altScreenEnter = "\x1b[?1049h"
	altScreenExit  = "\x1b[?1049l"
)

// enterInteractiveMode swaps to the alternate screen and puts the terminal
// into raw mode when stdin is a real terminal, returning a restore function
// that undoes both. Off a real terminal (piped input, a test harness) it is
// a no-op both ways, so the scaffold never corrupts a caller's pipe. --once
// never calls this at all (see runOnce) — it is not merely a no-op there,
// it is simply not in that code path.
func enterInteractiveMode() (restore func()) {
	fd := int(os.Stdin.Fd())
	if !term.IsTerminal(fd) {
		return func() {}
	}
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		return func() {}
	}
	fmt.Print(altScreenEnter)
	return func() {
		fmt.Print(altScreenExit)
		_ = term.Restore(fd, oldState)
	}
}

// terminalHeight reports the row count, or 0 when stdout is not a terminal —
// 0 meaning "do not clamp", the same contract buildFrame's height takes.
func terminalHeight() int {
	if _, h, err := term.GetSize(int(os.Stdout.Fd())); err == nil && h > 0 {
		return h
	}
	return 0
}

func terminalWidth() int {
	if w, _, err := term.GetSize(int(os.Stdout.Fd())); err == nil && w > 0 {
		return w
	}
	return 80
}

func stampPath() string {
	return filepath.Join(os.TempDir(), fmt.Sprintf("agent-monitor-census-stamp-%d", os.Getuid()))
}

func writeFrame(lines []string) {
	io.WriteString(os.Stdout, frameBytes(lines))
}

// frameBytes is the exact text writeFrame puts on the terminal, split out so a
// test can assert on it without a pty.
//
// CRLF, not LF (dotfiles-r9ty). The interactive path runs in RAW mode, which
// disables the ONLCR output mapping that normally turns a bare \n into \r\n.
// Without that mapping \n moves down one row and KEEPS THE COLUMN, so every
// line starts where the previous one ended and the frame staircases off the
// right edge, wrapping rows into each other. `--once` never enters raw mode,
// so the tty still maps LF for it — which is why one-shot output looked
// perfect, every unit test passed, and only running the real TUI showed it.
func frameBytes(lines []string) string {
	// Home cursor and clear below, rather than a full clear-and-redraw --
	// cheaper and avoids a visible flash on every tick.
	var b strings.Builder
	b.WriteString("\x1b[H\x1b[J")
	for _, l := range lines {
		b.WriteString(l)
		b.WriteString("\r\n")
	}
	return b.String()
}
