// agent-monitor is the interactive terminal view over agent-census's
// published roster and pi-worker's message bus. Per adr0030, this binary IS
// the interface — there is no nushell/actions/ wrapper, and it links
// straight to ~/.local/bin.
//
// sp030 T8 wired the roster pane scaffold: a slow, gated sample on a ticker,
// a forced refresh on `r`, and a plain render loop. sp030 T9 added the
// second pane — messages, sampled on their own fast, ungated ticker — and
// `--once`, a non-interactive single-frame mode that composes in a pipe (no
// raw mode, no alternate screen). sp030 T10 moved focus, filter and scroll
// into a tui.Model.
//
// sp032 T2 (this file) hands the EVENT LOOP to bubbletea. The shell type
// below is the tea.Model: bubbletea owns raw mode and its restore (including
// on panic), the alternate screen, escape decoding, SIGWINCH and mouse
// reports, so the hand-rolled byte pump, the escape state machine and the
// restore-exactly-once guard are all gone. What did NOT move is everything
// that decides what a frame SAYS: internal/render still produces every byte
// of every pane, tui.Model still owns focus, filter and scroll, and the two
// samplers in internal/source keep their own goroutines and adr0014's
// guards — a tick simply becomes a message now instead of a draw callback.
// --once never constructs a program at all (see runOnce).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"agent-monitor/internal/render"
	"agent-monitor/internal/source"
	"agent-monitor/internal/tui"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
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

	if err := interactiveExitError(runInteractive(*project)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// interactiveExitError maps a finished program's error onto an exit status.
// bubbletea reports a SIGINT as tea.ErrInterrupted, but the pre-sp032 loop
// returned on a signal and the process exited 0 — a ctrl+c or a `kill` is a
// clean way to leave a monitor, not a failure. SIGTERM already arrives as an
// ordinary quit (nil), so only the interrupt needs unwrapping.
func interactiveExitError(err error) error {
	if errors.Is(err, tea.ErrInterrupted) {
		return nil
	}
	return err
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
	// interactive filter, no scroll, top of the list". An interactive
	// session starts from the same construction and then OPENS its message
	// pane at the tail (sp032 T8, shell.View); this path never does, because
	// it builds no shell and its height==0 frame reports no viewport for the
	// opening to consume. --project is set directly, since it is not
	// something a key ever commits.
	model := tui.NewModel()
	model.Project = project
	lines, _ := buildFrame(model, censusMonitor, msgMonitor, time.Now(), terminalWidth(), 0)
	for _, line := range lines {
		fmt.Fprintln(w, line)
	}
	return nil
}

// rosterTickMsg and messagesTickMsg are what a sampler goroutine delivers
// into the loop: "this pane's data changed, redraw". They carry NOTHING —
// the monitors hold the sample and the model holds the view state, so a tick
// that carried data would be a second copy of both and a second place for
// them to disagree. Crucially, a tick moves no cursor and no scroll offset
// (TestUpdate_TickMsgRedrawsWithoutMovingAnyCursor): sp032 T1 made the
// scroll first-class precisely so a two-second sample cannot drag it.
type rosterTickMsg struct{}

type messagesTickMsg struct{}

// shell is agent-monitor's tea.Model — the event loop's whole state. It owns
// nothing that decides what a frame SAYS: render/ produces every byte, and
// tui.Model holds focus, filter, cursor and scroll exactly as it did under
// the hand-rolled loop. What lives here is only what the loop itself needs:
// the two monitors a forced refresh re-reads, the geometry the last
// tea.WindowSizeMsg reported, and the clock the frame stamps ages against.
type shell struct {
	ctx    context.Context
	model  *tui.Model
	census *source.Monitor
	msgs   *source.MessagesMonitor

	// width and height come from tea.WindowSizeMsg — term.GetSize is gone
	// from the interactive path. width starts at the same 80-column fallback
	// terminalWidth() uses, so a frame rendered before the first size message
	// is laid out rather than collapsed; height starts at 0, which renderFrame
	// already reads as "do not clamp, no detail pane" (the --once contract),
	// so the pre-size frame is a plain stack rather than a mis-clamped one.
	width, height int

	// now is the clock renderFrame stamps staleness and message ages
	// against, injectable so a test can compare a frame byte-for-byte.
	now func() time.Time

	// opened records that this session's message pane has had its sp032 T8
	// opening (openMessagesAtTailOnce). It is per-SESSION rather than
	// per-frame: the opening puts the pane at its tail once, and every frame
	// after it leaves a reader who scrolled back exactly where they are.
	opened bool
}

func newShell(ctx context.Context, model *tui.Model, census *source.Monitor, msgs *source.MessagesMonitor) *shell {
	return &shell{ctx: ctx, model: model, census: census, msgs: msgs, width: 80, now: time.Now}
}

// Init has nothing to start: both samplers are ordinary goroutines started in
// runInteractive (adr0014's guards live in source.RunLoop and
// source.RunMessagesLoop and are deliberately NOT re-expressed as tea.Cmd
// tickers — see sp032 ## solution), and the first frame's forced reads have
// already happened by the time the program runs.
func (s *shell) Init() tea.Cmd { return nil }

// Update maps one event onto tui.Model and does nothing else — the rule that
// keeps the whole key surface unit-testable without ever constructing a
// tea.Program. No key logic lives here; translateKey converts the event and
// tui.Model decides what it means.
func (s *shell) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		s.width, s.height = msg.Width, msg.Height

	case rosterTickMsg, messagesTickMsg:
		// A sampler saw new data. The monitors already hold it and View
		// reads them, so there is nothing to do but let bubbletea redraw.

	case tea.KeyMsg:
		for _, k := range translateKey(msg) {
			outcome := s.model.HandleKey(k)
			if outcome.Quit {
				return s, tea.Quit
			}
			if outcome.ForceRefresh {
				s.census.Refresh(s.ctx)
				s.msgs.Tick(s.ctx)
			}
		}

	case tea.MouseMsg:
		s.handleMouse(msg)
	}
	return s, nil
}

// handleMouse is sp032 T3's whole mouse surface: it recomputes THIS frame's
// layout (the same one View() just drew — nothing about the model or the
// geometry has changed between that draw and this event), converts the
// event's Y into a (pane, row) via the ONE hit test, and hands the result to
// a Model entry point. No arithmetic on msg.Y happens anywhere else.
//
// MouseActionMotion is dropped first and unconditionally: cell-motion
// reporting sends a stream of these during a drag, and none of them is a
// press. Every other button/action combination narrows from there.
func (s *shell) handleMouse(msg tea.MouseMsg) {
	if msg.Action == tea.MouseActionMotion {
		return
	}

	_, layout := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
	target, isData, offset := hitTest(layout, msg.Y)

	switch msg.Button {
	case tea.MouseButtonLeft:
		if msg.Action != tea.MouseActionPress {
			return
		}
		switch target {
		case hitRoster:
			s.model.ClickPane(tui.PaneRoster, isData, offset)
		case hitMessages:
			s.model.ClickPane(tui.PaneMessages, isData, offset)
		case hitDetail:
			// sp032 T4: the pane is a focus stop now. isData is always
			// false for it (hitTest says so — a message body has no
			// selectable rows), so this focuses and selects nothing.
			s.model.ClickPane(tui.PaneDetail, false, 0)
			// hitNone: a separator/off-frame press changes nothing at all.
		}
	case tea.MouseButtonWheelUp:
		switch target {
		case hitRoster:
			s.model.ScrollPane(tui.PaneRoster, -3)
		case hitMessages:
			s.model.ScrollPane(tui.PaneMessages, -3)
		case hitDetail:
			s.model.ScrollPane(tui.PaneDetail, -3)
		}
	case tea.MouseButtonWheelDown:
		switch target {
		case hitRoster:
			s.model.ScrollPane(tui.PaneRoster, 3)
		case hitMessages:
			s.model.ScrollPane(tui.PaneMessages, 3)
		case hitDetail:
			s.model.ScrollPane(tui.PaneDetail, 3)
		}
	}
}

// View is renderFrame's lines joined with "\n", and nothing else. It is NOT
// \r\n: dotfiles-r9ty's CRLF workaround existed because the hand-rolled loop
// wrote frames itself while the tty was in raw mode, with ONLCR disabled, so
// a bare \n moved down a row without returning the carriage. bubbletea owns
// the output mapping now, so the cause is gone and the workaround goes with
// it rather than being carried forward as a superstition.
func (s *shell) View() string {
	lines, _ := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
	// sp032 T8: this session's FIRST frame opens the message pane at its
	// tail (dotfiles-utob — a monitor that opens on the oldest message, and
	// since T6 opens already `+N` behind, contradicts the conditional
	// tail-follow sp032's ## solution commits to). It happens here, AFTER a
	// frame has been laid out, because laying one out is the only thing that
	// reports the pane's viewport — and the opening needs that viewport both
	// to land the scroll at the bottom and to know the pane has a window at
	// all. The frame is then composed a second time, so the very first frame
	// the operator SEES is the opened one rather than the one before it.
	//
	// Exactly one frame in a session pays for the second composition, and
	// nothing on the --once path pays for it at all: runOnce calls buildFrame
	// directly and never constructs a shell.
	if s.openMessagesAtTailOnce() {
		lines, _ = buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height)
	}
	return strings.Join(lines, "\n")
}

// openMessagesAtTailOnce performs this session's opening and reports whether
// it just did. It is a no-op once the pane has been opened, so a later frame
// or resize can never yank a reader who has scrolled back — and a no-op
// while the pane has no window (a terminal too short for a data row, or a
// frame drawn before the first tea.WindowSizeMsg), so the opening waits for
// a window rather than being spent on a pane that cannot show its result.
func (s *shell) openMessagesAtTailOnce() bool {
	if s.opened {
		return false
	}
	if !s.model.OpenMessagesAtTail() {
		return false
	}
	s.opened = true
	return true
}

// translateKey converts one bubbletea key event into the tui.Key values the
// model already understands. It returns a SLICE because bubbletea coalesces a
// burst of printable input (a paste, a fast typist) into one KeyRunes event,
// where the byte-at-a-time decoder it replaces produced one Key per rune —
// feeding them individually is what keeps a pasted filter query arriving
// whole. An unmapped key returns nothing, which is exactly what the old
// decoder did with a bare ESC and with any CSI sequence ft016 has no action
// for.
//
// ctrl+c maps to the 0x03 RUNE rather than to a quit here, deliberately:
// HandleKey is what decides that 0x03 quits, and it decides so only when a
// filter draft is NOT open — while editing, 0x03 has always been swallowed
// into the draft. Translating it to a quit in this function would silently
// change that (TestUpdate_CtrlCWhileEditingIsDraftTextNotQuit).
func translateKey(k tea.KeyMsg) []tui.Key {
	switch k.Type {
	case tea.KeyRunes, tea.KeySpace:
		// KeySpace is bubbletea's one printable key reported under its own
		// type; its rune still arrives in Runes, so both cases read the same
		// field and a space typed into a filter query is not dropped.
		keys := make([]tui.Key, 0, len(k.Runes))
		for _, r := range k.Runes {
			keys = append(keys, tui.Key{Rune: r})
		}
		return keys
	case tea.KeyCtrlC:
		return []tui.Key{{Rune: 0x03}}
	case tea.KeyUp:
		return []tui.Key{{Special: tui.KeyUp}}
	case tea.KeyDown:
		return []tui.Key{{Special: tui.KeyDown}}
	case tea.KeyLeft:
		return []tui.Key{{Special: tui.KeyLeft}}
	case tea.KeyRight:
		return []tui.Key{{Special: tui.KeyRight}}
	case tea.KeyEnter:
		return []tui.Key{{Special: tui.KeyEnter}}
	case tea.KeyBackspace:
		return []tui.Key{{Special: tui.KeyBackspace}}
	case tea.KeyTab:
		return []tui.Key{{Special: tui.KeyTab}}
	case tea.KeyEsc:
		return []tui.Key{{Special: tui.KeyEsc}}
	case tea.KeyPgUp:
		return []tui.Key{{Special: tui.KeyPgUp}}
	case tea.KeyPgDown:
		return []tui.Key{{Special: tui.KeyPgDn}}
	case tea.KeyHome:
		return []tui.Key{{Special: tui.KeyHome}}
	case tea.KeyEnd:
		return []tui.Key{{Special: tui.KeyEnd}}
	}
	return nil
}

// programOptions is the option set every agent-monitor program is built
// with, named so a test can assert it without running a program.
//
// The alternate screen is what the hand-rolled path used to write by hand.
// Cell-motion mouse reporting has no consumer yet — sp032 T3 adds the hit
// test — and is enabled here because a shell that does not ask for mouse
// reports receives none, so T3 would otherwise have nothing to consume.
//
// What is NOT here matters as much: bubbletea's panic catcher and its signal
// handler are both left ON, and they are what replaced tui's hand-rolled
// restore-exactly-once guard, deleted in this task. Opting
// out of either would put the terminal back in the state that guard existed
// to prevent (TestShell_PanicAndSignalRestoreLeftToBubbletea).
func programOptions() []tea.ProgramOption {
	return []tea.ProgramOption{tea.WithAltScreen(), tea.WithMouseCellMotion()}
}

// runInteractive drives two samplers (roster + messages) and a bubbletea
// program over a tui.Model, returning the program's error. project is
// --project's value (sp031 T3), set on the model once here and never touched
// again — no key mutates it, unlike the interactive `/` filter.
func runInteractive(project string) error {
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

	p := tea.NewProgram(newShell(ctx, model, censusMonitor, msgMonitor), programOptions()...)

	// The samplers keep their own goroutines and source.RunLoop /
	// source.RunMessagesLoop keep adr0014's three guards verbatim — they are
	// NOT rewritten as tea.Cmd tickers (sp032 ## solution). Only the callback
	// changed: what used to render on THIS goroutine now only posts a
	// message, which is also why tui's cross-goroutine restore guard could
	// be deleted rather than merely retired — nothing on these goroutines
	// touches the terminal any more.
	//
	// The `changed` gate is kept from the pre-port callback on purpose: an
	// unchanged sample redrew nothing before this task and redraws nothing
	// after it. This task is a port with no behavior change, and a tick that
	// always sent would quietly turn a two-second no-op into a two-second
	// repaint.
	go source.RunLoop(ctx, censusMonitor, pollInterval, piBoundInterval, func(changed bool) {
		if changed {
			p.Send(rosterTickMsg{})
		}
	})
	go source.RunMessagesLoop(ctx, msgMonitor, messagesInterval, func(changed bool) {
		if changed {
			p.Send(messagesTickMsg{})
		}
	})

	_, err := p.Run()
	return err
}

// buildFrame is runInteractive's and runOnce's entry point: it resolves the
// two monitors' last samples and staleness, then hands off to renderFrame,
// which does the actual composition and is what tests drive directly (a
// *source.Monitor's last sample is unexported and only settable by execing
// a real or stubbed binary — renderFrame takes samples directly so a test
// can hand-build one).
func buildFrame(model *tui.Model, censusMonitor *source.Monitor, msgMonitor *source.MessagesMonitor, now time.Time, width, height int) ([]string, frameLayout) {
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
//
// The second return value is sp032 T3's layout: where each VISIBLE pane
// landed in the lines slice this call also returns. It is derived from the
// same paneBudgets/fitPanes call that trimmed roster/log — never a second
// arithmetic on height — and it is the ONLY thing a mouse handler consults to
// turn a screen row into (pane, row); see hitTest.
func renderFrame(model *tui.Model, censusSample *source.Sample, censusStale bool, msgSample *source.MessageSample, msgStale bool, now time.Time, width, height int) ([]string, frameLayout) {
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

	// sp032 T4's zoom: the detail pane alone, at full height. It returns
	// EARLY, before the roster and the log are rendered or their viewports
	// re-reported — deliberately, on both counts. Rendering panes that are
	// not on screen would be waste; reporting them a viewport of 0 would be
	// worse, because SetRosterViewport's legacy viewport<=0 regime pins
	// scroll to the cursor, which would silently discard a wheel offset
	// (sp032 T1's whole point) for the duration of the zoom.
	if height > 0 && model.DetailVisible && model.DetailZoom {
		_, _, detailBudget, _ := paneBudgets(rosterLines, logLines, height, true, true)
		detailLines := renderDetailPane(model, selectedMessage(model, msgSample), width, detailBudget, true)
		return detailLines, frameLayout{
			detail:      detailRegion(0, len(detailLines)),
			detailShown: true,
		}
	}

	if height > 0 {
		rosterBudget, logBudget, _, _ := paneBudgets(rosterLines, logLines, height, model.DetailVisible, false)
		model.SetRosterViewport(viewportRows(min(rosterLines, rosterBudget)))
		model.SetMessagesViewport(viewportRows(min(logLines, logBudget)))
	}

	roster := render.Render(scrolledCensusSample(censusSample, rosterRows, model.RosterScroll), censusStale, now, width)
	// model.PendingMessages is sp032 T6's tail counter, and it is passed
	// here rather than folded into the header by this file because render/
	// owns every byte of a pane's content — the `+N new` segment is TEXT
	// subject to the same width budget as everything else RenderLog emits.
	// It is zero on the --once path by construction (the tail counts
	// nothing without a reported viewport, and height == 0 never reports
	// one), so that frame's bytes are unchanged.
	log := render.RenderLog(scrolledMessageSample(msgSample, msgRows, model.MessagesScroll), msgStale, now, width, model.PendingMessages)

	// fitPanes re-derives the same budgets from the rendered line counts and
	// does the actual trimming. The two derivations agree: a pane whose
	// rendered length differs from rosterLines/logLines is one that scrolled,
	// and a pane only scrolls when it is at or over its budget — so the
	// "is this pane shorter than its share?" test lands the same way either
	// way, and the surplus is redistributed identically.
	roster, log, detailBudget, detailShown := fitPanes(roster, log, height, model.DetailVisible)

	// detailLines is rendered HERE, before the layout is built, because its
	// ACTUAL length is not detailBudget: a short message occupies fewer
	// rows than its budget, with no padding to fill it, exactly like
	// roster/log's own clamp() (fitPanes above). The layout must describe
	// the frame that is actually returned, so it reads this slice's real
	// length rather than the budget that merely bounds it.
	var detailLines []string
	if detailShown {
		detailLines = renderDetailPane(model, selectedMessage(model, msgSample), width, detailBudget, false)
	}

	layout := buildLayout(censusSample != nil, len(rosterRows), len(roster), msgSample != nil, len(msgRows), len(log), len(detailLines), detailShown)

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
		// The detail pane is a focus stop since sp032 T4, so its header
		// earns the same marking. rows is 0: the pane has no selectable
		// row, so markPane marks the header and stops. (The ZOOM layout
		// does not mark anything — it is the only pane on screen, so there
		// is nothing for a focus mark to distinguish it from.)
		detailLines = markPane(detailLines, model.Focus == tui.PaneDetail, 0, 0, 0)
	}

	var lines []string
	lines = append(lines, roster...)
	lines = append(lines, "")
	lines = append(lines, log...)

	if detailShown {
		lines = append(lines, "")
		lines = append(lines, detailLines...)
	}
	return lines, layout
}

// styleOn/styleOff are the reverse-video pair that marks the focused pane's
// header and the selected row. Both are SGR attribute toggles, not colours:
// they cost zero display cells, so a marked line occupies exactly the width
// its text did, and they restore only the attribute they set (27 turns off
// reverse, unlike a blanket 0 reset) so no other styling is clobbered.
// zoomIndicator is the text the detail pane's header carries while the pane
// is zoomed to the full frame (sp032 T4 criterion 4). It is plain text, not
// an escape: the zoom is a MODE, and a mode the operator cannot name is one
// they cannot leave.
const zoomIndicator = "[zoom]"

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

// fitPanes trims the two stacked scrolling panes (and reports the detail
// pane's budget) so the whole frame fits in height rows. It is the
// THREE-PANE layout's trimmer only: the zoom layout renders neither roster
// nor log, so renderFrame returns before reaching it and passes detailZoom
// false here.
//
// Roster, messages, and — when there is room and the toggle allows it — the
// detail pane.
//
// dotfiles-9x2m / dotfiles-m0km: without this the frame is however many
// lines the data happens to produce, the frame writer prints all of them, and a
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
	rosterBudget, logBudget, detailBudget, detailShown := paneBudgets(len(roster), len(log), height, detailVisible, false)
	return clamp(roster, rosterBudget), clamp(log, logBudget), detailBudget, detailShown
}

// paneBudgets is fitPanes' arithmetic with the []string arguments replaced
// by their lengths, so renderFrame can ask for this frame's budgets BEFORE
// anything is rendered — the ordering sp031 T1's criterion needs (see
// renderFrame). A budget of -1 means "do not clamp" (the height<=0 --once
// contract); clamp treats any negative n that way.
func paneBudgets(rosterLines, logLines, height int, detailVisible, detailZoom bool) (rosterBudget, logBudget, detailBudget int, detailShown bool) {
	if height <= 0 {
		return -1, -1, 0, false
	}

	// sp032 T4's zoom is a THIRD case of the same arithmetic rather than a
	// second arithmetic somewhere else: the detail pane takes every row,
	// the other two get none, and there is no separator because there is
	// nothing to separate. detailBudget is the pane's TOTAL line budget in
	// both layouts (its header plus its viewport), so the "viewport takes
	// height-1 rows" of the criterion falls out of renderDetailPane's one
	// header line, not out of a second subtraction here.
	if detailVisible && detailZoom {
		return 0, 0, height, true
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

// paneLayout is one VISIBLE pane's on-screen geometry for THIS frame, in the
// SAME line-index space renderFrame's []string result uses — which is also
// exactly the space a tea.MouseMsg's Y addresses, since View() emits those
// lines with nothing else above them (no chrome, no cursor-home prefix).
//
// totalRows is the pane's whole rendered footprint, headerRows+dataRows for
// an ordinary pane but headerRows+1 for a pane rendering the
// "(no agents)"/"(no messages)" placeholder — that placeholder line occupies
// a real screen row (a click there must still focus the pane, per T3's edge
// cases) while dataRows stays 0 (there is nothing to select). The distinction
// is why totalRows is carried separately rather than derived as
// headerRows+dataRows every time.
type paneLayout struct {
	firstRow   int
	headerRows int
	dataRows   int
	totalRows  int
}

// frameLayout is renderFrame's second return value: where the roster,
// messages and (when shown) detail panes each landed. detail is the zero
// paneLayout when detailShown is false — hitTest checks the flag before
// consulting it, exactly like every other reader of model.DetailVisible.
//
// sp032 T3 gives the detail pane geometry here (criterion 1 asks for EVERY
// visible pane) but no focus stop and no scroll authority — hitTest reports
// hitDetail for a coordinate that lands on it, and every mouse handler in
// this task treats that report as inert. T4 is what turns it into a third
// focus stop.
type frameLayout struct {
	roster      paneLayout
	messages    paneLayout
	detail      paneLayout
	detailShown bool
}

// buildLayout derives frameLayout from paneBudgets' own outputs and the
// counts renderFrame already computed — it never re-implements the budget
// arithmetic, only reads its result. rosterRenderedLen/logRenderedLen are the
// roster/log slices' lengths AFTER fitPanes' clamp, and detailRenderedLen is
// RenderDetail's own output length — all three are the exact number of
// screen rows each pane occupies in THIS frame, which is not always its
// budget: a pane (detail above all — a short message renders far fewer lines
// than its budget, with no padding) can come in under budget, and the layout
// must describe the frame actually returned rather than the ceiling that
// merely bounds it.
func buildLayout(haveRoster bool, rosterRows, rosterRenderedLen int, haveMessages bool, msgRows, logRenderedLen int, detailRenderedLen int, detailShown bool) frameLayout {
	roster := paneRegion(0, haveRoster, rosterRows, rosterRenderedLen)

	msgFirst := rosterRenderedLen + 1 // +1: the blank separator line
	messages := paneRegion(msgFirst, haveMessages, msgRows, logRenderedLen)

	layout := frameLayout{roster: roster, messages: messages, detailShown: detailShown}
	if detailShown {
		detailFirst := msgFirst + logRenderedLen + 1 // +1: the blank separator line
		layout.detail = detailRegion(detailFirst, detailRenderedLen)
	}
	return layout
}

// detailRegion is the detail pane's geometry, shared by the three-pane
// layout and the zoom layout so the two never disagree about where the
// header ends and the scrolled body begins.
//
// The pane has no column-header row and no placeholder-vs-data distinction:
// its first line is the header ("from → to", or the "(no message selected)"
// placeholder) and everything after it is the viewport's body, when there is
// a second line at all. dataRows is therefore the viewport's on-screen row
// count — which is what makes "the viewport takes height-1 rows" (criterion
// 4) a checkable property of the layout rather than of the renderer.
func detailRegion(firstRow, renderedLen int) paneLayout {
	headerRows := min(1, renderedLen)
	return paneLayout{
		firstRow:   firstRow,
		headerRows: headerRows,
		dataRows:   renderedLen - headerRows,
		totalRows:  renderedLen,
	}
}

// renderDetailPane is sp032 T4's detail pane: the selected envelope's header
// line, then as much of its body as the budget shows, through a
// bubbles/viewport.
//
// The render it feeds the viewport is UNCLAMPED (height 0 — render/'s "do
// not clamp" convention): a body pre-trimmed to the pane budget could not be
// scrolled, because the rows past the budget would never have been produced.
// The truncation indicator sp031 showed instead is gone from this path for
// the same reason — the content below is reachable now, so marking it
// "not shown" would be a lie.
//
// The viewport does the windowing; tui.Model owns the OFFSET. That split is
// the spec's one-scroll-authority rule applied to this pane: the content is
// re-rendered on every sampler tick, so a viewport that owned its own
// YOffset across those rebuilds would be a second authority over the same
// number, and the one that lost would lose intermittently. Here the offset
// is read out of the model on every frame and never read back, so the
// viewport is a pure formatting device and there is nothing in it to
// preserve between frames.
//
// zoom appends the indicator criterion 4 asks for, in cmd/ and after
// rendering — the same place and for the same reason markPane applies
// reverse video, so render/ keeps emitting nothing but text.
func renderDetailPane(model *tui.Model, msg *source.Message, width, budget int, zoom bool) []string {
	// Which message this is, before anything reads the scroll: a changed
	// selection resets the offset to the top, an unchanged one keeps it.
	model.SetDetailSelection(detailSelectionKey(msg))

	full := render.RenderDetail(msg, width, 0)
	if len(full) == 0 {
		return nil
	}
	header, body := full[0], full[1:]

	bodyRows := budget - 1 // the header line is chrome above the scrolled region
	if bodyRows < 0 {
		bodyRows = 0
	}
	model.SetDetailViewport(bodyRows)
	model.SetDetailLen(len(body))

	if zoom {
		header = withZoomIndicator(header, width)
	}
	out := []string{header}
	if bodyRows == 0 || len(body) == 0 {
		return out
	}

	// Height is the SMALLER of the budget and the body, so a short message
	// occupies only the rows it needs: viewport.View() pads to its Height,
	// and padding here would give the pane phantom rows the frame would
	// then have to carry. The model still hears the real budget above, so
	// the two clamps agree (both give a max offset of 0 when the body fits).
	vp := viewport.New(width, min(bodyRows, len(body)))
	vp.SetContent(strings.Join(body, "\n"))
	vp.SetYOffset(model.DetailScroll)
	for _, line := range strings.Split(vp.View(), "\n") {
		// viewport.View() pads every line out to its Width with spaces.
		// Trimming that back off keeps the frame's lines the same shape
		// render/ produced them in — which is what the "no line exceeds the
		// width" reasoning and every byte-comparing frame test assume.
		out = append(out, strings.TrimRight(line, " "))
	}
	return out
}

// detailSelectionKey is cmd/'s answer to "is the detail pane showing the
// same message as last frame?" — the question tui.Model's
// SetDetailSelection asks to decide whether the scroll offset survives.
//
// The ID alone would do in production (ft014's ids are ULIDs), but the
// other fields cost nothing and make the key correct for any envelope whose
// id is absent or reused, which is a cheaper guarantee than trusting a
// producer. It is NOT a content parse: adr0031 forbids deriving display
// meaning from a body outside RenderDetail, and nothing here reads Content.
func detailSelectionKey(msg *source.Message) string {
	if msg == nil {
		return ""
	}
	return strings.Join([]string{msg.ID, msg.At, msg.From, strings.Join(msg.To, ","), msg.Kind}, "\x00")
}

// withZoomIndicator appends criterion 4's zoom marker to the detail pane's
// header, shortening the header itself by the cells the marker needs so the
// line still fits the width. render.TruncateCells is used rather than a
// local rune count because a header can carry wide runes, and the cell
// accounting is a load-bearing rule this file must not fork.
func withZoomIndicator(header string, width int) string {
	const room = len(zoomIndicator) + 1 // the marker plus its separating space
	if width <= room {
		return render.TruncateCells(zoomIndicator, width)
	}
	return render.TruncateCells(header, width-room) + " " + zoomIndicator
}

// paneRegion is buildLayout's per-pane case split: no sample yet (the
// "waiting for first sample" single line), too little budget to even fit the
// header, an empty filtered list (the placeholder line), or the ordinary
// header-plus-data-rows case. renderedLen is always the pane's ACTUAL
// on-screen line count post-clamp, so a pane trimmed below its natural size
// reports the geometry that is really on screen, not what it would have
// wanted.
func paneRegion(firstRow int, haveSample bool, filteredRows, renderedLen int) paneLayout {
	if !haveSample {
		return paneLayout{firstRow: firstRow, headerRows: renderedLen, totalRows: renderedLen}
	}
	if renderedLen < headerLines {
		// Degenerate clamp (paneBudgets' avail<2 branch): even the column
		// header did not survive. Every rendered line is "header" in the
		// sense that none of it is a selectable row.
		return paneLayout{firstRow: firstRow, headerRows: renderedLen, totalRows: renderedLen}
	}
	if filteredRows == 0 {
		// The "(no agents)"/"(no messages)" placeholder: one real screen row
		// beyond the header that is not a data row (see paneLayout doc).
		return paneLayout{firstRow: firstRow, headerRows: headerLines, totalRows: renderedLen}
	}
	return paneLayout{
		firstRow:   firstRow,
		headerRows: headerLines,
		dataRows:   renderedLen - headerLines,
		totalRows:  renderedLen,
	}
}

// hitTarget names which of the frame's regions a screen row belongs to.
// hitDetail and hitNone both carry no further meaning in T3 — see
// frameLayout's doc — but are named distinctly from each other so a future
// task (T4) can tell "the detail pane, inert for now" from "no pane at all"
// without re-deriving geometry.
type hitTarget int

const (
	hitNone hitTarget = iota
	hitRoster
	hitMessages
	hitDetail
)

// hitTest is sp032 T3's ONE place that converts a screen row into a pane and
// an offset within it — every mouse handler in this file consumes its
// result rather than doing its own arithmetic on a MouseMsg's Y. x is
// deliberately not a parameter: the frame is a single full-width vertical
// stack, so a column never selects a different pane, and a coordinate off
// the right edge of the rendered content still names the same row a
// terminal's cell grid would report it against.
//
// isData reports whether y landed on an actual selectable row (offset is
// then that row's 0-based index within the pane's CURRENTLY VISIBLE data,
// i.e. scroll + offset is the absolute row a caller should select). isData
// is false for a header/column-header row, for the empty-list placeholder
// row, and whenever target is hitNone or hitDetail — none of those is ever a
// selection.
func hitTest(layout frameLayout, y int) (target hitTarget, isData bool, offset int) {
	if hit, ok := paneHit(layout.roster, y); ok {
		return hitRoster, hit.isData, hit.offset
	}
	if hit, ok := paneHit(layout.messages, y); ok {
		return hitMessages, hit.isData, hit.offset
	}
	if layout.detailShown {
		if _, ok := paneHit(layout.detail, y); ok {
			return hitDetail, false, 0
		}
	}
	return hitNone, false, 0
}

type paneHitResult struct {
	isData bool
	offset int
}

// paneHit reports whether y falls anywhere within p's on-screen span
// (ok==false covers both "above/below this pane" and, via the caller's
// ordering in hitTest, "this row belongs to the separator between panes" —
// a separator is simply a row no pane's span reaches).
func paneHit(p paneLayout, y int) (paneHitResult, bool) {
	rel := y - p.firstRow
	if rel < 0 || rel >= p.totalRows {
		return paneHitResult{}, false
	}
	if rel < p.headerRows {
		return paneHitResult{}, true
	}
	dataOffset := rel - p.headerRows
	if dataOffset < p.dataRows {
		return paneHitResult{isData: true, offset: dataOffset}, true
	}
	// Beyond the real data rows but still inside the pane's span: the
	// placeholder line (dataRows == 0, totalRows == headerRows+1). Focus
	// only, per the edge case — never a selection of "(no agents)".
	return paneHitResult{}, true
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

func terminalWidth() int {
	if w, _, err := term.GetSize(int(os.Stdout.Fd())); err == nil && w > 0 {
		return w
	}
	return 80
}

func stampPath() string {
	return filepath.Join(os.TempDir(), fmt.Sprintf("agent-monitor-census-stamp-%d", os.Getuid()))
}
