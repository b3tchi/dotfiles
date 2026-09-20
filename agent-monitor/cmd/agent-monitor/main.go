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

	// composerCapRows and composerCapDivisor are detailCapRows/detailCapDivisor's
	// twin for the composer region (sp033 T10): the same shape, deliberately
	// equal, so the ONLY thing that decides who loses a row under a squeeze
	// is the priority paneBudgets applies (detail first, composer second),
	// never one pane simply having a stingier cap than the other.
	composerCapRows    = 8
	composerCapDivisor = 3

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
	as := flag.String("as", "", "resolve identity as this bus label via pi-worker whoami --label, for an operator whose label isn't their OS username; no separate registry lookup")
	flag.Parse()

	if *once {
		if err := runOnce(os.Stdout, *project, *as); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	if err := interactiveExitError(runInteractive(*project, *as)); err != nil {
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
//
// as is --as's value (sp033 T4 criterion 5: --once resolves identity too, so
// a piped frame marks the same rows an interactive session would). It is
// VARIADIC, not a third required parameter, for the same reason RenderLog's
// pending count is (internal/render/log.go): every pre-T4 call in this
// package's tests passes exactly two arguments, and that byte-identical call
// shape is itself part of criterion 3's regression coverage — rewriting
// every one of them to pass "" would touch dozens of unrelated tests to say
// nothing new.
func runOnce(w io.Writer, project string, as ...string) error {
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
	// pane at its live end (sp032 T8, shell.View; the head since sp033 T6);
	// this path never does, because it builds no shell and its height==0
	// frame reports no viewport for the opening to consume. --project is set
	// directly, since it is not something a key ever commits.
	model := tui.NewModel()
	model.Project = project
	identity := resolveIdentityForModel(ctx, model, firstOrEmpty(as))
	lines, _ := buildFrame(model, censusMonitor, msgMonitor, time.Now(), terminalWidth(), 0, nil, identity)
	for _, line := range lines {
		fmt.Fprintln(w, line)
	}
	return nil
}

// firstOrEmpty reads runOnce's variadic --as value: no argument is every
// pre-T4 call and means no override, exactly like RenderLog's firstOrZero.
func firstOrEmpty(vals []string) string {
	if len(vals) == 0 {
		return ""
	}
	return vals[0]
}

// resolveIdentity execs `pi-worker whoami --json` once and reports, on
// stderr, the one case criterion 3's "panes render exactly as today" cannot
// itself say out loud: an operator who passed --as but whose whoami answer
// came back unregistered gets no identity (edge case 4) — the escape hatch
// renames a resolved identity, it does not manufacture one, so this is
// exactly a `--as` given with nothing to override. The note is informational
// only: it never changes the exit code, and it never touches a pane, so
// criterion 3's byte-identical frame holds regardless of whether it prints.
func resolveIdentity(ctx context.Context, as string) source.Identity {
	identity := source.ResolveIdentity(ctx, source.RealExec, as)
	if as != "" && !identity.Registered {
		fmt.Fprintf(os.Stderr, "agent-monitor: --as %q: no identity resolved (not registered)\n", as)
	}
	return identity
}

// resolveIdentityForModel is runOnce's and runInteractive's shared identity
// wiring: resolve, then set model.HasIdentity from the result — the seam
// between sp033 T4 (identity resolution) and sp033 T8 (OpenComposer's
// !HasIdentity refusal, keys.go:913), factored so a test can call the exact
// statement production depends on instead of reimplementing it.
func resolveIdentityForModel(ctx context.Context, model *tui.Model, as string) source.Identity {
	identity := resolveIdentity(ctx, as)
	model.HasIdentity = identity.Registered
	return identity
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

	// sender is sp033 T9's one write path: `pi-worker send`, execed by
	// sendCmd's tea.Cmd — never called from Update directly (that would
	// block the render loop) and never called from a sampler's Tick (that
	// would put a writer inside adr0014's guarded reader loops).
	sender *source.Sender

	// sendNotice is the composer's transient status line: "sent to X" on a
	// successful send (criterion 3) or the CLI's stderr on a failed one
	// (criterion 4). It is plain text with nowhere of its own to render
	// yet — T10 gives the composer its own region and reads this — so this
	// task's own tests assert it directly rather than through a frame.
	sendNotice string

	// identity is who ResolveIdentity said the operator is, resolved ONCE at
	// startup (runInteractive) and never re-derived on a tick — see
	// source.Identity's doc for why a user who registers mid-session stays
	// unresolved until the monitor restarts.
	identity source.Identity

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
	// opening (openMessagesAtHeadOnce). It is per-SESSION rather than
	// per-frame: the opening puts the pane at its live end once (the head,
	// since sp033 T6), and every frame after it leaves a reader who scrolled
	// back exactly where they are.
	opened bool

	// expansion is dotfiles-1t00 Task 6's expansion SET — which thread keys
	// (render.Thread.Key) are currently expanded — following the shell.opened
	// precedent above: per-session state a keystroke changes that tui.Model
	// cannot hold, because Model is a comparable struct (fixtures assert
	// `*m != want`) and a map field would break that at compile time
	// (## plan's anti-pattern list, restated on Threaded's own doc).
	// HandleKey reports only the INTENT on Outcome.Thread — it holds no row
	// list to say WHICH key is meant — so applyThreadOutcome is what resolves
	// the message pane's current cursor row to a key and mutates this map.
	//
	// It is consulted, never trusted (## edge_cases): a key for a thread that
	// has since vanished from the bus is simply never asked about again — see
	// expandedFn — so a stale entry costs a little memory and nothing else.
	expansion map[string]bool
}

// identity is VARIADIC for the same reason runOnce's --as and RenderLog's
// pending count are: every pre-T4 call in this package's tests passes
// exactly four arguments, and none of them means to say anything about
// identity — the zero source.Identity{} (Registered false) is exactly what
// they get, and exactly what leaves the header byte-identical (criterion 3).
func newShell(ctx context.Context, model *tui.Model, census *source.Monitor, msgs *source.MessagesMonitor, identity ...source.Identity) *shell {
	return &shell{ctx: ctx, model: model, census: census, msgs: msgs, sender: source.NewSender(), identity: firstIdentityOrZero(identity), width: 80, now: time.Now}
}

// firstIdentityOrZero reads newShell's/buildFrame's/renderFrame's variadic
// identity argument: no value means no override, exactly like firstOrZero
// (RenderLog's pending count) and firstOrEmpty (runOnce's --as).
func firstIdentityOrZero(vals []source.Identity) source.Identity {
	if len(vals) == 0 {
		return source.Identity{}
	}
	return vals[0]
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
			if s.tryOpenComposer(k) {
				continue
			}
			// dotfiles-1t00.6 edge case: "Toggling mode preserves the
			// SELECTED envelope where it still exists, rather than resetting
			// the cursor to row 0." `t` mutates model.Threaded directly
			// inside HandleKey (it is unconditional, not gated on Focus, and
			// carries no Outcome signal of its own — see keys.go), so the
			// only way to notice it happened is to check the condition
			// ourselves and capture the pre-toggle selection before calling
			// HandleKey at all.
			isModeToggle := !s.model.Editing && !s.model.Composing && (k.Rune == 't' || k.Rune == 'T')
			var selectedBeforeToggle string
			if isModeToggle {
				selectedBeforeToggle = s.selectedMessageID()
			}

			outcome := s.model.HandleKey(k)
			if outcome.Quit {
				return s, tea.Quit
			}
			if outcome.ForceRefresh {
				s.census.Refresh(s.ctx)
				s.msgs.Tick(s.ctx)
			}
			if outcome.Send != nil {
				return s, s.sendCmd(outcome.Send)
			}
			if outcome.Thread != tui.ThreadNone {
				s.applyThreadOutcome(outcome.Thread)
			}
			if isModeToggle {
				s.restoreSelectionByID(selectedBeforeToggle)
			}
		}

	case tea.MouseMsg:
		s.handleMouse(msg)

	case sendResultMsg:
		s.handleSendResult(msg)
	}
	return s, nil
}

// tryOpenComposer is `a`'s dispatch (sp033 T10, the wiring T8 deliberately
// left out): Model.OpenComposer needs the SELECTED message's from_address,
// and Model holds no message list to read that from — only main.go, which
// already threads s.msgs through selectedMessage for the detail pane, does.
// It reports whether it consumed k, so Update's loop skips HandleKey for
// exactly this one key and only when it means "open the composer" — while
// Editing or Composing, 'a' is text, and falling through to HandleKey is what
// makes it belong to whichever draft is open, unchanged.
//
// A successful open also drops the detail zoom: the composer renders BELOW
// the detail pane (criterion 1), which the zoom's full-screen layout has no
// room for, and nothing in the composing key surface (handleComposingKey
// swallows Enter as a newline, not a zoom) can re-enter zoom while Composing
// is true — so this is the only place that invariant needs enforcing.
func (s *shell) tryOpenComposer(k tui.Key) bool {
	if k.Rune != 'a' {
		return false
	}
	if s.model.Editing || s.model.Composing {
		return false
	}
	toAddress := ""
	if msg := selectedMessage(s.model, s.currentMessageRows()); msg != nil {
		toAddress = msg.FromAddress
	}
	opened, reason := s.model.OpenComposer(toAddress)
	if !opened {
		s.sendNotice = reason
		return true
	}
	s.model.DetailZoom = false
	return true
}

// expandedFn is the "is this key expanded" predicate render.ThreadRows takes
// (Task 2), backed by s.expansion. Reading a nil map is safe in Go (it
// answers false, never panics), which is exactly the "consulted, never
// trusted" rule the stale-key edge case asks for: a key nothing has expanded
// yet, or a key whose thread has since vanished from the bus, both simply
// read false rather than needing to be purged first.
func (s *shell) expandedFn() func(string) bool {
	return func(key string) bool { return s.expansion[key] }
}

// isThreaded is the SINGLE authority for "does the message pane render
// threaded right now" (dotfiles-1t00.6 gap 2, rev-dotfiles-1t00-6 rejection
// #1): height<=0 always means flat — "a pipe has no cursor and nothing to
// expand" (## plan) — regardless of model.Threaded's own value, no matter who
// is asking. Before this fix, renderFrame and currentThreadsAndRows each
// restated `height > 0 && model.Threaded` as their own literal expression;
// they agreed only by coincidence. shell.height documents itself as starting
// at 0 (see shell's own doc, and a real terminal can legitimately report a 0
// height too), so there is a real window — before the first
// tea.WindowSizeMsg, or on a 0-height report — where the two calls would
// silently diverge: renderFrame renders (and SetMessagesLen clamps the
// cursor into) one row list while Update resolves the SAME cursor against a
// different one. Every reader of "is this render threaded" — production or
// test — calls this, never re-derives the condition inline.
func isThreaded(model *tui.Model, height int) bool {
	return height > 0 && model.Threaded
}

// threaded is shell's own copy of isThreaded, over its CURRENT width/height
// and model — what currentThreadsAndRows (and so applyThreadOutcome,
// selectedMessageID, restoreSelectionByID: everything that resolves "what
// row is the cursor on right now" between keystrokes) consults, so it can
// never disagree with the SAME frame's renderFrame call (buildFrame's own
// s.height, s.model) about which row list is in play.
func (s *shell) threaded() bool {
	return isThreaded(s.model, s.height)
}

// currentThreadsAndRows recomputes the message pane's CURRENT threads and row
// list off the shell's last sample, s.threaded() and s.expansion — the same
// inputs filterMessageRows renders from, but read-only: it calls neither
// SetMessagesLen nor SetMessageCount nor AddForYouArrivals, because it exists
// for Update to resolve "what row is the cursor on right now" between
// keystrokes, not to advance any of those counters a second time for the same
// sample. threads is nil in flat mode (there is nothing to look a key's
// membership up in); rows is nil when there is no sample yet, matching
// filterMessageRows' own nil-sample case.
func (s *shell) currentThreadsAndRows() ([]render.Thread, []render.LogRow) {
	sample := s.msgs.Last()
	if sample == nil {
		return nil, nil
	}
	msgs := orderedMessages(s.model, sample)
	if !s.threaded() {
		rows, _ := buildMessageRows(msgs, false, nil)
		return nil, rows
	}
	threads := render.Threads(msgs)
	return threads, render.ThreadRows(threads, s.expandedFn())
}

// currentMessageRows is currentThreadsAndRows without the threads slice, for
// the callers (applyThreadOutcome) that only need the row list.
func (s *shell) currentMessageRows() []render.LogRow {
	_, rows := s.currentThreadsAndRows()
	return rows
}

// selectedMessageID is the message pane's current selection, by envelope
// identity (source.Message.ID) rather than by row index — exactly what
// restoreSelectionByID needs to find the SAME envelope again after the row
// list's shape changes out from under it (a mode toggle, criterion/edge
// case: "Toggling mode preserves the SELECTED envelope where it still
// exists"). Empty when nothing is selected (an empty log, or a cursor
// somehow past the end).
func (s *shell) selectedMessageID() string {
	rows := s.currentMessageRows()
	if s.model.MessagesCursor < 0 || s.model.MessagesCursor >= len(rows) {
		return ""
	}
	return rows[s.model.MessagesCursor].Message.ID
}

// restoreSelectionByID re-selects the envelope named by id after `t` has
// already flipped model.Threaded — id is empty when nothing was selected
// before the toggle, in which case this is a no-op and the cursor stays
// wherever HandleKey/SetMessagesLen's next clamp leaves it. It tries the
// envelope's own row first (every flat row and a thread row whose newest
// member IS the envelope both match directly), and falls back to the row of
// the THREAD that owns it — the case a toggle from flat to threaded folds an
// older thread member invisibly behind its (collapsed) summary row, per
// indexByIdentity's own doc.
func (s *shell) restoreSelectionByID(id string) {
	if id == "" {
		return
	}
	threads, rows := s.currentThreadsAndRows()
	if i := indexByIdentity(rows, id, ownerThreadKey(threads, id)); i >= 0 {
		s.model.MessagesCursor = i
	}
}

// applyThreadOutcome is dotfiles-1t00 Task 6's other half of the signal
// HandleKey returns for l/h/KeyLeft/KeyRight/space (Outcome.Thread): HandleKey
// names only the INTENT (expand/collapse/toggle) because it holds no
// expansion set and no row list to say WHICH thread key is meant (Model must
// stay comparable — see Threaded's own doc, and see keys.go:1115-1127). This
// is the caller that owns both: s.expansion, and the row list this frame's
// last render computed, which is what resolves "the message pane's current
// selection" (Outcome.Thread's own doc) to a THREAD KEY.
//
// The resolution reads off the CURRENT cursor ROW, not off some separate
// notion of "the selected thread": on a KindMessage (child) row, the key
// resolved is that child's OWN thread key (LogRow.Key is the same value on a
// thread row and every one of its children — Task 2's doc), which is what
// lets h/KeyLeft collapse the expansion the cursor is standing INSIDE rather
// than being a no-op or reaching some other thread entirely (CARRIED FORWARD
// FROM TASK 5's AUDIT, dotfiles-1t00.5).
//
// After the mutation, the cursor is re-resolved by envelope identity — the
// same rule restoreSelectionByID uses for a mode toggle — falling back to the
// thread's OWN row when the envelope itself just left the rendered list
// (collapsing hides every child): "Collapsing a thread the cursor is standing
// inside leaves the cursor on the thread row rather than off the end."
// Expanding never needs the fallback (a collapsed thread has no child row to
// stand on, so the cursor is always on the thread's own row when it is
// expanded, and that row's identity is unchanged by gaining children), but
// resolving generally, the same way either direction, means this function
// carries no separate case for which way the toggle went.
func (s *shell) applyThreadOutcome(intent tui.ThreadIntent) {
	rows := s.currentMessageRows()
	if s.model.MessagesCursor < 0 || s.model.MessagesCursor >= len(rows) {
		return
	}
	current := rows[s.model.MessagesCursor]
	key, selectedID := current.Key, current.Message.ID

	if s.expansion == nil {
		s.expansion = make(map[string]bool)
	}
	switch intent {
	case tui.ThreadExpand:
		s.expansion[key] = true
	case tui.ThreadCollapse:
		delete(s.expansion, key)
	case tui.ThreadToggle:
		s.expansion[key] = !s.expansion[key]
	default:
		return
	}

	if i := indexByIdentity(s.currentMessageRows(), selectedID, key); i >= 0 {
		s.model.MessagesCursor = i
	}
}

// indexByIdentity finds selectedID (a source.Message.ID) among rows and
// returns its index. When no row carries that exact envelope any more — a
// collapse hid it inside its thread's children, or a mode toggle folded it
// behind a summary row it is not itself — it falls back to the row of kind
// thread whose Key is fallbackKey, so a caller always lands on SOME row that
// still represents the envelope's conversation rather than an arbitrary
// clamp. Returns -1 when neither is found (the envelope and its thread are
// both gone — the bus pruned it), which every caller treats as "leave the
// cursor alone; the next SetMessagesLen clamps it into range regardless".
func indexByIdentity(rows []render.LogRow, selectedID, fallbackKey string) int {
	for i, row := range rows {
		if row.Message.ID == selectedID {
			return i
		}
	}
	if fallbackKey == "" {
		return -1
	}
	for i, row := range rows {
		if row.Kind == render.KindThread && row.Key == fallbackKey {
			return i
		}
	}
	return -1
}

// ownerThreadKey answers "which thread's Key contains the message with this
// ID", for indexByIdentity's fallback when the exact envelope is not its own
// row (a mode toggle folded an older thread member behind its collapsed
// summary row). Empty in flat mode (threads is nil) or when nothing matches.
func ownerThreadKey(threads []render.Thread, id string) string {
	for _, th := range threads {
		for _, m := range th.Messages {
			if m.ID == id {
				return th.Key
			}
		}
	}
	return ""
}

// sendResultMsg is what a dispatched send reports back into Update — never
// performed inline (criterion 2). It carries the ORIGINAL request rather
// than making Update re-derive it from Model: commitCompose already cleared
// Composing/ComposeTo/the draft by the time this arrives, so req is the
// only place left holding what was actually sent.
type sendResultMsg struct {
	req *tui.SendRequest
	err error
}

// sendCmd dispatches source.Sender.Send as a tea.Cmd (criterion 2): it runs
// on bubbletea's own command goroutine, never on Update's, so a slow or
// hung pi-worker cannot freeze the render loop. from is the operator's own
// resolved ADDRESS (sp033 T4's identity) — never the label — matching
// Sender.Send's own contract and adr0034's "addresses identify, labels
// display" rule.
func (s *shell) sendCmd(req *tui.SendRequest) tea.Cmd {
	from := s.identity.Address
	sender := s.sender
	ctx := s.ctx
	return func() tea.Msg {
		err := sender.Send(ctx, from, req.To, req.Body)
		return sendResultMsg{req: req, err: err}
	}
}

// handleSendResult applies one dispatched send's outcome. A success sets a
// transient confirmation naming the recipient's rendered LABEL (criterion
// 3) — the reply itself is never inserted locally; it arrives through the
// ordinary message tick like every other envelope, so there stays exactly
// one source of truth for what is on the bus. A failure shows the CLI's
// stderr and replays the draft's body back through the model's own key
// surface to reopen the composer exactly as it was (criterion 4): nothing
// the operator typed is lost. Replaying via HandleKey rather than a new
// Model setter keeps this restore inside the existing "every rune belongs
// to the draft" contract instead of adding a second way to mutate it.
func (s *shell) handleSendResult(msg sendResultMsg) {
	label := s.recipientLabel(msg.req.To)
	if msg.err != nil {
		s.sendNotice = fmt.Sprintf("send to %s failed: %s", label, msg.err)
		if opened, _ := s.model.OpenComposer(msg.req.To); opened {
			for _, r := range msg.req.Body {
				s.model.HandleKey(tui.Key{Rune: r})
			}
		}
		return
	}
	s.sendNotice = fmt.Sprintf("sent to %s", label)
}

// recipientLabel resolves an address to the rendered label a currently
// known envelope carries for it, off the shell's own last sample. See
// recipientLabelFromSample, which does the actual lookup: it takes a sample
// directly (rather than a monitor) so renderFrame — a package-level function
// with no shell to call, but the msgSample it was already handed — can
// resolve the SAME label for the composer's header, sp033 T10, without a
// second lookup rule.
func (s *shell) recipientLabel(address string) string {
	return recipientLabelFromSample(s.msgs.Last(), address)
}

// recipientLabelFromSample is recipientLabel's lookup: the same From/To
// rendering pi-worker.nu already computed (ft014 T1's
// from_address/to_addresses widening), never a second Go-side registry
// lookup (the ## plan's absolute rule: "the registry is read in nu, never in
// Go"). Falls back to the address itself when no known envelope carries it —
// a recipient released between open and send (## edge_cases), or a reply
// composer whose selected message has since scrolled out of the sample, has
// no label left to show, and the address is an honest thing to show instead
// of guessing or crashing.
func recipientLabelFromSample(sample *source.MessageSample, address string) string {
	if sample == nil {
		return address
	}
	for _, m := range sample.Messages {
		if m.FromAddress == address {
			return m.From
		}
		for i, a := range m.ToAddresses {
			if a == address && i < len(m.To) {
				return m.To[i]
			}
		}
	}
	return address
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

	_, layout := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height, s.expandedFn(), s.identity)
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
	lines, layout := buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height, s.expandedFn(), s.identity)
	// sp032 T8: this session's FIRST frame opens the message pane at its
	// live end (dotfiles-utob — a monitor that opened on the wrong end, and
	// since T6 opens already `+N` behind, contradicts the conditional
	// live-follow sp032's ## solution commits to; sp033 T6 moved that end
	// from the tail to the head). It happens here, AFTER a frame has been
	// laid out, because laying one out is the only thing that reports the
	// pane's viewport — and the opening needs that viewport both to land the
	// scroll at row 0 and to know the pane has a window at all. The frame is
	// then composed a second time, so the very first frame the operator SEES
	// is the opened one rather than the one before it.
	//
	// Exactly one frame in a session pays for the second composition, and
	// nothing on the --once path pays for it at all: runOnce calls buildFrame
	// directly and never constructs a shell.
	if s.openMessagesAtHeadOnce() {
		lines, layout = buildFrame(s.model, s.census, s.msgs, s.now(), s.width, s.height, s.expandedFn(), s.identity)
	}
	lines = applySendNotice(lines, layout, s.sendNotice, s.width)
	return strings.Join(lines, "\n")
}

// applySendNotice overlays sendNotice onto the composer's own header row,
// using the SAME layout renderFrame already computed — never a second pass
// over model state. It lives in View(), not renderFrame, because sendNotice
// is shell state (sp033 T9's send result), and renderFrame is a
// package-level function with no shell to read it from; every renderFrame
// call this package's tests make (none of them touching sendNotice) is
// therefore unaffected.
//
// It is a no-op whenever the composer is not shown — which is exactly the
// successful-send case (commitCompose already closed it before the tea.Cmd
// even ran, T9's TestSend_DispatchedAsCmdShowsConfirmation), so that
// confirmation has no region left to render into; the reply appearing in the
// ordinary message list on the next tick (T9 criterion 3) IS that
// confirmation. A FAILED send reopens the composer (handleSendResult) with
// the SAME recipient and draft restored, which is exactly when this overlay
// has a header row to attach "send to X failed: …" to.
func applySendNotice(lines []string, layout frameLayout, notice string, width int) []string {
	if notice == "" || !layout.composerShown || layout.composer.headerRows == 0 {
		return lines
	}
	idx := layout.composer.firstRow
	if idx < 0 || idx >= len(lines) {
		return lines
	}
	out := make([]string, len(lines))
	copy(out, lines)
	out[idx] = render.TruncateCells(out[idx]+"  "+notice, width)
	return out
}

// openMessagesAtHeadOnce performs this session's opening and reports whether
// it just did. It is a no-op once the pane has been opened, so a later frame
// or resize can never yank a reader who has scrolled back — and a no-op
// while the pane has no window (a terminal too short for a data row, or a
// frame drawn before the first tea.WindowSizeMsg), so the opening waits for
// a window rather than being spent on a pane that cannot show its result.
func (s *shell) openMessagesAtHeadOnce() bool {
	if s.opened {
		return false
	}
	if !s.model.OpenMessagesAtHead() {
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
	case tea.KeyCtrlS:
		// sp033 T8's commitCompose checks for the raw 0x13 (DC3) rune rather
		// than a Special key, and every existing test drives it that way
		// (tui.Key{Rune: 0x13}) — this is the one place that mapping from a
		// real keypress was still missing, since T8/T9 only ever exercised it
		// by constructing the Key directly.
		return []tui.Key{{Rune: 0x13}}
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
// again — no key mutates it, unlike the interactive `/` filter. as is
// --as's value (sp033 T4), resolved into an identity once, here, before the
// program starts — never re-resolved on a tick, per source.Identity's doc.
func runInteractive(project string, as string) error {
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
	identity := resolveIdentityForModel(ctx, model, as)

	p := tea.NewProgram(newShell(ctx, model, censusMonitor, msgMonitor, identity), programOptions()...)

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
func buildFrame(model *tui.Model, censusMonitor *source.Monitor, msgMonitor *source.MessagesMonitor, now time.Time, width, height int, expanded func(string) bool, identity ...source.Identity) ([]string, frameLayout) {
	return renderFrame(model, censusMonitor.Last(), censusMonitor.Stale(), msgMonitor.Last(), msgMonitor.Stale(), now, width, height, expanded, identity...)
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
func renderFrame(model *tui.Model, censusSample *source.Sample, censusStale bool, msgSample *source.MessageSample, msgStale bool, now time.Time, width, height int, expanded func(string) bool, identity ...source.Identity) ([]string, frameLayout) {
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
	resolvedIdentity := firstIdentityOrZero(identity)
	rosterRows := filterRosterRows(model, censusSample)
	// dotfiles-1t00.6: --once (height<=0) always renders FLAT regardless of
	// model.Threaded — "a pipe has no cursor and nothing to expand" (## plan)
	// — via isThreaded, the single authority shell.threaded() also consults
	// (gap 2, rev-dotfiles-1t00-6 rejection #1): two independent
	// `height > 0 && model.Threaded` expressions agreed only by coincidence.
	threaded := isThreaded(model, height)
	msgRows, msgThreads := filterMessageRows(model, msgSample, resolvedIdentity, threaded, expanded)
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
		_, _, detailBudget, _, _, _ := paneBudgets(rosterLines, logLines, height, true, true, model.Composing)
		detailLines := renderDetailPane(model, selectedMessage(model, msgRows), width, detailBudget, true)
		return detailLines, frameLayout{
			detail:      detailRegion(0, len(detailLines)),
			detailShown: true,
		}
	}

	if height > 0 {
		rosterBudget, logBudget, _, _, _, _ := paneBudgets(rosterLines, logLines, height, model.DetailVisible, false, model.Composing)
		model.SetRosterViewport(viewportRows(min(rosterLines, rosterBudget)))
		model.SetMessagesViewport(viewportRows(min(logLines, logBudget)))
	}

	// FilterRoster applies the SAME committed Filter/draft FilterMessages
	// does (dotfiles-jw73 rejection #1) — a reduced roster was exactly as
	// silent as a reduced message list, so the roster's header gets the
	// identical signals the message header gets below.
	roster := render.Render(scrolledCensusSample(censusSample, rosterRows, model.RosterScroll), censusStale, now, width, render.RosterSignals{
		FilterQuery:   model.Filter.Query,
		FilterDraft:   model.FilterDraft(),
		FilterEditing: model.Editing,
	})
	// model.PendingMessages is sp032 T6's counter (inverted to the head by
	// sp033 T6), and it is passed here rather than folded into the header by
	// this file because render/ owns every byte of a pane's content — the
	// `+N new` segment is TEXT subject to the same width budget as
	// everything else RenderLog emits. It is zero on the --once path by
	// construction (nothing counts without a reported viewport, and
	// height == 0 never reports one), so that frame's bytes are unchanged.
	// model.PendingMessages/ForYouCount are sp032 T6's and sp033 T7's
	// counters, and both are passed here rather than folded into the header
	// by this file because render/ owns every byte of a pane's content — the
	// `+N new`/`N for you` segments are TEXT subject to the same width
	// budget as everything else RenderLog emits. resolvedIdentity.Address is
	// what T7's row marker compares ToAddresses against; both counters are
	// zero and the address is empty on the --once path by construction
	// (nothing counts without a reported viewport, and height == 0 never
	// reports one; --once also never resolves an unregistered identity), so
	// that frame's bytes are unchanged.
	// model.Filter.Query/FilterDraft()/Editing are dotfiles-jw73's addition,
	// passed the same way as Pending/ForYou above: render/ owns every byte
	// of the header, this file only threads the model's own state through.
	// FilterQuery is passed UNCONDITIONALLY (never gated on Filter.Set) —
	// a committed empty query is the documented "cleared" state and must
	// render with no segment, which is exactly what an empty string already
	// does on the render/ side without this file special-casing Set. Both
	// are zero-value on the --once path by construction (nothing ever sets
	// Editing or commits a query without a keystroke), so that frame's
	// bytes are unchanged.
	logSignals := render.LogSignals{
		Pending:       model.PendingMessages,
		ForYou:        model.ForYouCount,
		Identity:      resolvedIdentity.Address,
		FilterQuery:   model.Filter.Query,
		FilterDraft:   model.FilterDraft(),
		FilterEditing: model.Editing,
	}
	// dotfiles-1t00.6: threaded and flat share this ONE row list (msgRows) —
	// the split below is only about which GRID renders it. Flat goes through
	// the untouched pre-spec call (a *source.MessageSample built from the
	// SAME rows, in the SAME order, which is what keeps --once and every
	// flat frame byte-identical: TestRenderLog_FlatOutputUnchanged's contract
	// travels through unchanged bytes, not through a coincidence). Threaded
	// goes through Task 6's RenderThreadLog, over the SAME scrolled slice of
	// msgRows and the threads map filterMessageRows/buildMessageRows already
	// built — render/ does no re-ordering of its own either way.
	var log []string
	scrolledRows := scrolledLogRows(msgRows, model.MessagesScroll)
	if threaded {
		log = render.RenderThreadLog(scrolledRows, msgThreads, msgSample != nil, sampleAtOrZero(msgSample), msgStale, now, width, logSignals)
	} else {
		log = render.RenderLog(scrolledFlatMessageSample(msgSample, scrolledRows), msgStale, now, width, logSignals)
	}
	// sp033 T4 criterion 4: the resolved identity is named once in the
	// message pane header, so the operator can see which party the monitor
	// thinks they are. This is a post-processing step on RenderLog's output,
	// exactly like markPane/withZoomIndicator below — render/ stays free of
	// anything but the sample it was handed, and a zero source.Identity{}
	// (every pre-T4 caller, and every unregistered/refused/missing-binary
	// case) leaves the header untouched, which is what keeps criterion 3's
	// byte-identical frame true without this file special-casing "no
	// identity" as a second code path.
	log = withIdentityHeader(log, resolvedIdentity, width)

	// fitPanes re-derives the same budgets from the rendered line counts and
	// does the actual trimming. The two derivations agree: a pane whose
	// rendered length differs from rosterLines/logLines is one that scrolled,
	// and a pane only scrolls when it is at or over its budget — so the
	// "is this pane shorter than its share?" test lands the same way either
	// way, and the surplus is redistributed identically.
	roster, log, detailBudget, detailShown, composerBudget, composerShown := fitPanes(roster, log, height, model.DetailVisible, model.Composing)

	// detailLines is rendered HERE, before the layout is built, because its
	// ACTUAL length is not detailBudget: a short message occupies fewer
	// rows than its budget, with no padding to fill it, exactly like
	// roster/log's own clamp() (fitPanes above). The layout must describe
	// the frame that is actually returned, so it reads this slice's real
	// length rather than the budget that merely bounds it.
	var detailLines []string
	if detailShown {
		detailLines = renderDetailPane(model, selectedMessage(model, msgRows), width, detailBudget, false)
	}

	// composerLines is detailLines' twin (sp033 T10 criterion 1): rendered
	// from its own ACTUAL length, never composerBudget, for the same reason.
	// composerShown is false whenever model.Composing is false (paneBudgets'
	// height<=0 branch and its composerVisible gate both force it), so this
	// costs nothing on every frame the composer is closed — criterion 2.
	var composerLines []string
	if composerShown {
		composerLines = renderComposerPane(model, msgSample, width, composerBudget)
	}

	layout := buildLayout(censusSample != nil, len(rosterRows), len(roster), msgSample != nil, len(msgRows), len(log), len(detailLines), detailShown, len(composerLines), composerShown)

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
		// dotfiles-o7ab rejection #1: OpenComposer never changes model.Focus
		// (whichever pane the operator was on when they pressed 'a' keeps
		// it), so marking roster/log/detail off model.Focus alone double-
		// marked the frame whenever the composer was open — the focused
		// list pane's row AND the composer's header. While composing, the
		// composer is the only focusable thing (every key belongs to the
		// draft), so it must be the ONLY thing marked; gate the other three
		// panes on !model.Composing rather than on their own focus state.
		if !model.Composing {
			roster = markPane(roster, model.Focus == tui.PaneRoster, model.RosterCursor, model.RosterScroll, len(rosterRows))
			log = markPane(log, model.Focus == tui.PaneMessages, model.MessagesCursor, model.MessagesScroll, len(msgRows))
			// The detail pane is a focus stop since sp032 T4, so its header
			// earns the same marking. rows is 0: the pane has no selectable
			// row, so markPane marks the header and stops. (The ZOOM layout
			// does not mark anything — it is the only pane on screen, so there
			// is nothing for a focus mark to distinguish it from.)
			detailLines = markPane(detailLines, model.Focus == tui.PaneDetail, 0, 0, 0)
		}
		// The composer has no cursor and no other stop to distinguish it
		// from (nothing else is focusable while Composing — every key
		// belongs to the draft), so it is marked focused unconditionally
		// whenever it is shown at all, exactly like the zoom layout marks
		// nothing because there is nothing to distinguish there either.
		composerLines = markPane(composerLines, true, 0, 0, 0)
	}

	var lines []string
	lines = append(lines, roster...)
	lines = append(lines, "")
	lines = append(lines, log...)

	if detailShown {
		lines = append(lines, "")
		lines = append(lines, detailLines...)
	}
	if composerShown {
		lines = append(lines, "")
		lines = append(lines, composerLines...)
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

// markPane applies one pane's interactive affordances in reverse video, and
// dotfiles-o7ab's rule is exactly ONE reversed line per frame: a pane with
// rows to select carries the mark on its SELECTED ROW when focused and
// nowhere at all when not; a pane with no rows (rows <= 0 — the detail view,
// the reply composer, or a list pane that is currently empty and so has
// nothing to select) carries it on its HEADER when focused, since a header
// is the only line such a pane has to carry it.
//
// cursor is an index into the pane's FULL filtered row list and scroll is
// the first row currently visible, so cursor-scroll is the selected row's
// offset within the lines this pane actually rendered.
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

	if rows <= 0 {
		if focused {
			out[0] = styleOn + out[0] + styleOff
		}
		return out
	}
	if !focused {
		return out
	}
	// headerLines is the pane header plus the column header; data rows start
	// after them. A pane still waiting for its first sample renders a single
	// line and never reaches here (rows <= 0 above).
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
// the full FILTERED row list — not the slice already scrolled into the
// renderer's view — so the detail pane tracks selection regardless of what
// happens to be scrolled on screen. rows is filterMessageRows' own return
// value, so MessagesCursor indexes the same row here as it does on screen,
// whether flat or threaded (dotfiles-1t00.6). nil means nothing is selected:
// an empty log, or (as a guard, not expected given SetMessagesLen's same-pass
// clamp) a cursor past the end; either way RenderDetail's own nil case is the
// placeholder.
//
// A KindThread row's own Message field is already its thread's NEWEST member
// (render.LogRow's own contract, Task 2), so this needs no special case for
// "which envelope does a thread row mean" — it is the same field a flat
// KindMessage row carries, which is exactly what keeps the detail pane, `a`'s
// reply recipient (tryOpenComposer) and this function agreeing on ONE
// envelope regardless of row kind (Task 6 criterion 3).
func selectedMessage(model *tui.Model, rows []render.LogRow) *source.Message {
	if model.MessagesCursor < 0 || model.MessagesCursor >= len(rows) {
		return nil
	}
	return &rows[model.MessagesCursor].Message
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
// detail and the composer always hidden — no clamping at all, exactly as
// before this task.
//
// The detail pane and the composer (sp033 T10) are each capped independently
// at roughly a third of height or their own *CapRows, whichever is smaller,
// and each hides itself (falling back to the original two-way split) when
// its own visibility flag is false or when showing it ALONE would leave less
// than minPaneRows*2 lines for roster+messages combined — the "squeezed into
// uselessness" floor the edge_cases call out. When BOTH want to show, a
// second check (fitsBothPanes) re-derives that same floor against their
// COMBINED cost — three separators and two budgets, not one of each — and
// drops detail first, the composer only if the list would still be squeezed
// even without detail too. That ordering is criterion 1's edge case, "the
// composer wins rows over the DETAIL pane, never over the message list it is
// replying within": composer/detail are given EQUAL caps on purpose, so the
// only thing that decides who loses a row is this priority, never one pane
// simply having a stingier budget than the other.
//
// Below whatever survives, roster and messages redistribute surplus exactly
// as they did before detail (and now the composer) existed: each gets half
// the remaining rows, minus the blank separator(s); whatever a short pane
// does not use goes to the other, so a machine with three agents and a busy
// bus still fills the screen with messages rather than padding. Trimming
// takes from the BOTTOM, which keeps each pane's header line — a pane whose
// header scrolled away is unreadable, and the header is what carries the
// staleness indicator.
func fitPanes(roster, log []string, height int, detailVisible, composerVisible bool) (rosterOut, logOut []string, detailBudget int, detailShown bool, composerBudget int, composerShown bool) {
	rosterBudget, logBudget, detailBudget, detailShown, composerBudget, composerShown := paneBudgets(len(roster), len(log), height, detailVisible, false, composerVisible)
	return clamp(roster, rosterBudget), clamp(log, logBudget), detailBudget, detailShown, composerBudget, composerShown
}

// paneBudgets is fitPanes' arithmetic with the []string arguments replaced
// by their lengths, so renderFrame can ask for this frame's budgets BEFORE
// anything is rendered — the ordering sp031 T1's criterion needs (see
// renderFrame). A budget of -1 means "do not clamp" (the height<=0 --once
// contract); clamp treats any negative n that way.
//
// This is the SINGLE arithmetic sp033 T10's own SRE note names: the composer
// gets no second calculation of its own anywhere else in this file, exactly
// like the detail pane before it.
func paneBudgets(rosterLines, logLines, height int, detailVisible, detailZoom, composerVisible bool) (rosterBudget, logBudget, detailBudget int, detailShown bool, composerBudget int, composerShown bool) {
	if height <= 0 {
		return -1, -1, 0, false, 0, false
	}

	// sp032 T4's zoom is a case of the same arithmetic rather than a second
	// arithmetic somewhere else: the detail pane takes every row, the other
	// two (and the composer) get none, and there is no separator because
	// there is nothing to separate. detailBudget is the pane's TOTAL line
	// budget in both layouts (its header plus its viewport), so the
	// "viewport takes height-1 rows" of the criterion falls out of
	// renderDetailPane's one header line, not out of a second subtraction
	// here. The composer cannot legally be open while zoomed (tryOpenComposer
	// clears the zoom on a successful open, and nothing reachable while
	// Composing re-enters it), so this branch simply never shows it.
	if detailVisible && detailZoom {
		return 0, 0, height, true, 0, false
	}

	detailBudget, detailShown = detailCap(height)
	if !detailVisible {
		detailBudget, detailShown = 0, false
	}

	composerBudget, composerShown = composerCap(height)
	if !composerVisible {
		composerBudget, composerShown = 0, false
	}

	// Priority under a squeeze: detail loses first, the composer only if the
	// list would still be squeezed without detail too. With composerCap and
	// detailCap sharing the exact same shape, dropping detail alone already
	// resolves every case fitsBothPanes can construct against these two
	// constants — the second check exists so retuning either constant later
	// can never silently break the priority order.
	if detailShown && !fitsBothPanes(height, detailBudget, composerBudget) {
		detailBudget, detailShown = 0, false
	}
	if composerShown && !fitsBothPanes(height, detailBudget, composerBudget) {
		composerBudget, composerShown = 0, false
	}

	seps := 1 // the blank line between roster and messages
	if detailShown {
		seps++ // plus the blank line between messages and detail
	}
	if composerShown {
		seps++ // plus the blank line before the composer
	}

	avail := height - seps - detailBudget - composerBudget
	if avail < 2 {
		// Degenerate terminal: one row each is the most that is still two
		// panes. Below that there is nothing useful to show.
		return 1, 1, detailBudget, detailShown, composerBudget, composerShown
	}

	rosterBudget = avail / 2
	logBudget = avail - rosterBudget
	if rosterLines < rosterBudget {
		logBudget += rosterBudget - rosterLines
	} else if logLines < logBudget {
		rosterBudget += logBudget - logLines
	}
	return rosterBudget, logBudget, detailBudget, detailShown, composerBudget, composerShown
}

// fitsBothPanes reports whether showing detail and the composer TOGETHER, at
// the given budgets, still leaves roster+messages at least minPaneRows*2
// combined lines — detailCap/composerCap each check this in isolation
// (assuming the OTHER is absent), which is exactly wrong the one frame both
// want to show at once; this is the combined check paneBudgets applies
// before trusting either self-assessment.
func fitsBothPanes(height, detailBudget, composerBudget int) bool {
	seps := 1
	if detailBudget > 0 {
		seps++
	}
	if composerBudget > 0 {
		seps++
	}
	return height-seps-detailBudget-composerBudget >= minPaneRows*2
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
// composer is the zero paneLayout when composerShown is false — hitTest has
// no case for it yet (sp033 T10 gives the composer a region and focus, not a
// mouse target), so nothing consults it while it is empty.
type frameLayout struct {
	roster        paneLayout
	messages      paneLayout
	detail        paneLayout
	detailShown   bool
	composer      paneLayout
	composerShown bool
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
// composerRenderedLen/composerShown are detailRenderedLen/detailShown's
// twin (sp033 T10): the composer's region, when shown, sits BELOW wherever
// the frame's stack currently ends — after detail if detail is shown, after
// the log otherwise — never at a fixed offset of its own.
func buildLayout(haveRoster bool, rosterRows, rosterRenderedLen int, haveMessages bool, msgRows, logRenderedLen int, detailRenderedLen int, detailShown bool, composerRenderedLen int, composerShown bool) frameLayout {
	roster := paneRegion(0, haveRoster, rosterRows, rosterRenderedLen)

	msgFirst := rosterRenderedLen + 1 // +1: the blank separator line
	messages := paneRegion(msgFirst, haveMessages, msgRows, logRenderedLen)

	layout := frameLayout{roster: roster, messages: messages, detailShown: detailShown, composerShown: composerShown}

	next := msgFirst + logRenderedLen
	if detailShown {
		next++ // the blank separator line before detail
		layout.detail = detailRegion(next, detailRenderedLen)
		next += detailRenderedLen
	}
	if composerShown {
		next++ // the blank separator line before the composer
		layout.composer = detailRegion(next, composerRenderedLen)
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

// renderComposerPane is sp033 T10's composer region: the recipient's
// rendered label (never a second registry lookup — recipientLabelFromSample)
// plus the send/cancel hint on one header line, then the draft's own text.
// It is sized from budget exactly like renderDetailPane, which is what keeps
// paneBudgets the one arithmetic that decides how many rows either pane gets
// (this file never computes a composer height a second way).
//
// budget < 1 renders nothing — the caller (renderFrame) only calls this when
// fitPanes/paneBudgets reported composerShown true, so this guard is a
// defensive floor rather than a path anything exercises today.
func renderComposerPane(model *tui.Model, sample *source.MessageSample, width, budget int) []string {
	if budget < 1 {
		return nil
	}
	label := recipientLabelFromSample(sample, model.ComposeTo)
	header := render.TruncateCells(fmt.Sprintf("reply to %s  (ctrl+s send · esc cancel)", label), width)

	bodyRows := budget - 1 // the header line is chrome above the draft
	if bodyRows < 0 {
		bodyRows = 0
	}
	out := []string{header}
	if bodyRows == 0 {
		return out
	}
	return append(out, composerBodyLines(model.ComposeDraft(), width, bodyRows)...)
}

// composerBodyLines renders the draft's TAIL — its last bodyRows lines, with
// a trailing cursor marker on the very last one (so an empty draft still
// shows where typing lands). The tail, not the head, because
// handleComposingKey's only cursor position is the END of the text: nothing
// in the composing key surface moves within the draft, only appends to or
// backspaces from its end, so the rows worth keeping on screen while a
// multi-line reply outgrows its budget (## edge_cases) are always the ones
// closest to where the next keystroke lands.
func composerBodyLines(draft string, width, bodyRows int) []string {
	lines := strings.Split(draft, "\n")
	lines[len(lines)-1] += "▏"
	if len(lines) > bodyRows {
		lines = lines[len(lines)-bodyRows:]
	}
	out := make([]string, len(lines))
	for i, l := range lines {
		out[i] = render.TruncateCells(l, width)
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
// withIdentityHeader appends "— you are <label>" to the message pane's
// header line when identity.Registered, and leaves lines untouched
// otherwise — the zero source.Identity{} is exactly criterion 3's "no
// identity" case, and this function is the one place that turns Registered
// into text so nothing else has to special-case it. TruncateCells is the
// same cell-accounting withZoomIndicator uses, so a narrow terminal trims the
// suffix rather than letting the line exceed width.
func withIdentityHeader(lines []string, identity source.Identity, width int) []string {
	if len(lines) == 0 || !identity.Registered {
		return lines
	}
	out := make([]string, len(lines))
	copy(out, lines)
	out[0] = render.TruncateCells(out[0]+fmt.Sprintf(" — you are %s", identity.Label), width)
	return out
}

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

// composerCap is detailCap's twin for the composer region (sp033 T10): same
// shape, same constants, checked in isolation exactly like detailCap is —
// paneBudgets' fitsBothPanes is what re-checks the case both this and
// detailCap said yes to at once.
func composerCap(height int) (budget int, shown bool) {
	budget = height / composerCapDivisor
	if budget > composerCapRows {
		budget = composerCapRows
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

// filterMessageRows is filterRosterRows' twin for the message pane. sp033
// T6 additionally reorders: it puts the sample into the pane's own display
// order — newest-first, row 0 the newest envelope — rather than
// source.ParseMessages' ascending wire order (see orderedMessages for why the
// reorder lives here rather than in render/log.go or in tui.Model). Task 6
// adds the second step: it hands SetMessagesLen (and, through its return
// value, RenderLog/RenderThreadLog, the scroll slice and selectedMessage) the
// pane's own rendered ROW list — one row per message when flat, one row per
// thread (plus, per expanded thread, one row per member) when threaded — so
// every consumer of MessagesCursor agrees on what index 0 means regardless of
// mode ("## plan"'s single-reorder-point rule extended to the row list
// itself: render.Threads/render.ThreadRows do no re-sorting of their own,
// thread.go's own doc, so there is exactly one order here either way).
//
// dotfiles-1t00.4: SetMessagesLen gets the ROW count (len(rows)) and
// SetMessageCount gets the MESSAGE count (len(msgs)) — wiring these backwards
// reintroduces exactly the defect Task 4 exists to prevent, since expanding a
// thread changes rows, never messages. before is read off model.MessagesCount
// (the message-count twin), not model.MessagesLen (the row count), for the
// same reason. threads is nil in flat mode (buildMessageRows' own doc) — this
// file's own caller only reaches for it when it is about to render threaded.
func filterMessageRows(model *tui.Model, sample *source.MessageSample, identity source.Identity, threaded bool, expanded func(string) bool) ([]render.LogRow, map[string]render.Thread) {
	if sample == nil {
		return nil, nil
	}
	msgs := orderedMessages(model, sample)
	before := model.MessagesCount
	model.SetMessageCount(len(msgs))
	model.AddForYouArrivals(countNewForYou(msgs, before, identity))

	rows, threads := buildMessageRows(msgs, threaded, expanded)
	model.SetMessagesLen(len(rows))
	return rows, threads
}

// buildMessageRows is filterMessageRows' and currentThreadsAndRows' shared
// row-list construction (dotfiles-1t00 Task 6): threaded wraps msgs through
// render.Threads/render.ThreadRows (Task 1/Task 2), producing one row per
// thread and — only for an expanded key — its child rows; flat wraps each
// message as its own KindMessage row, in the SAME order msgs already carries.
// Either way the caller gets ONE list to walk for row count, the scroll
// slice and "the message at index i" (SetMessagesLen, selectedMessage) — ##
// plan's "do not derive a second order" applied to the row list itself, not
// just to msgs.
//
// Every row's Message is a real envelope regardless of kind: a KindThread
// row's Message is its thread's NEWEST member (render.ThreadRows' own
// contract), which is what lets selectedMessage agree with the detail pane
// and `a`'s reply recipient no matter which kind of row is selected.
//
// threads is nil in flat mode: there is no grouping to look a key's
// membership up in, and a caller that only wants rows (the flat render path,
// or currentThreadsAndRows' own flat branch) has no use for it either way.
func buildMessageRows(msgs []source.Message, threaded bool, expanded func(string) bool) ([]render.LogRow, map[string]render.Thread) {
	if !threaded {
		rows := make([]render.LogRow, len(msgs))
		for i, m := range msgs {
			rows[i] = render.LogRow{Kind: render.KindMessage, Message: m, Count: 1}
		}
		return rows, nil
	}
	threads := render.Threads(msgs)
	byKey := make(map[string]render.Thread, len(threads))
	for _, th := range threads {
		byKey[th.Key] = th
	}
	return render.ThreadRows(threads, expanded), byKey
}

// countNewForYou is sp033 T7's arrival count for Model.AddForYouArrivals,
// SetMessageCount's `grown := n - m.MessagesCount` restated at this file's
// boundary (Model itself holds no source.Message to compare against). msgs
// is already in the pane's display order — newest-first, sp033 T6 — so the
// rows genuinely NEW this tick are its first `len(msgs)-before` entries; of
// those, this counts the ones whose ToAddresses contains the identity's
// address (criterion 1: an address comparison, never a label one, matching
// render.forYouRow's rule exactly). An unregistered identity never counts —
// there is no address to compare against — and a shrink (before > len(msgs))
// yields zero new rows, the same floor SetMessageCount enforces for
// PendingMessages. before is the MESSAGE count (dotfiles-1t00.4), not the
// rendered row count — the two diverge once a thread can be expanded.
func countNewForYou(msgs []source.Message, before int, identity source.Identity) int {
	if !identity.Registered {
		return 0
	}
	grown := len(msgs) - before
	if grown <= 0 {
		return 0
	}
	n := 0
	for _, m := range msgs[:grown] {
		for _, a := range m.ToAddresses {
			if a == identity.Address {
				n++
				break
			}
		}
	}
	return n
}

// orderedMessages applies the committed filter and puts the result into the
// message pane's own display order (sp033 T6: newest-first). It is the
// SINGLE place that reorders, called by both filterMessageRows (what
// SetMessagesLen bounds and RenderLog renders) and selectedMessage (what the
// detail pane shows) — a second, independent reorder in either caller would
// let MessagesCursor mean two different things depending which path read it,
// exactly the hidden-second-order anti-pattern `## plan` forbids for T6.
//
// source.ParseMessages already returns ascending id/time order (oldest
// first) and this spec does not touch that — reversing a freshly filtered
// copy on every call is cheaper to reason about than tracking an
// incremental "prepend to the front" invariant against a sample that is
// re-fetched whole on every tick.
func orderedMessages(model *tui.Model, sample *source.MessageSample) []source.Message {
	msgs := model.FilterMessages(sample.Messages)
	reversed := make([]source.Message, len(msgs))
	for i, m := range msgs {
		reversed[len(msgs)-1-i] = m
	}
	return reversed
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

// scrolledLogRows is scrolledCensusSample's twin for the message pane's ROW
// list (dotfiles-1t00.6): dropping the first `scroll` rows is the same
// operation regardless of mode, since flat and threaded now share the one
// []render.LogRow shape — there is no longer a separate
// scrolledMessageSample for []source.Message, because a rendered row and a
// message stopped being the same thing the moment a thread can collapse.
func scrolledLogRows(rows []render.LogRow, scroll int) []render.LogRow {
	if scroll < 0 || scroll > len(rows) {
		return rows
	}
	return rows[scroll:]
}

// scrolledFlatMessageSample rebuilds a *source.MessageSample from the flat
// row list's own messages, in the SAME order, so RenderLog's pre-spec call
// shape (a *source.MessageSample, not a []render.LogRow) is unchanged and
// every flat frame — including --once — stays byte-identical
// (TestRenderLog_FlatOutputUnchanged, TestShell_OnceIsFlatAndByteIdentical).
// It is only ever called with FLAT rows (buildMessageRows' KindMessage-per-
// message wrapping), so extracting .Message back out recovers exactly
// orderedMessages' own slice.
func scrolledFlatMessageSample(sample *source.MessageSample, rows []render.LogRow) *source.MessageSample {
	if sample == nil {
		return nil
	}
	msgs := make([]source.Message, len(rows))
	for i, row := range rows {
		msgs[i] = row.Message
	}
	return &source.MessageSample{Messages: msgs, At: sample.At}
}

// sampleAtOrZero reads a *source.MessageSample's own At for RenderThreadLog,
// which carries no sample pointer of its own to read it off (its data is
// []render.LogRow, not []source.Message) — the zero time.Time{} for a nil
// sample is never actually read, since RenderThreadLog's haveSample argument
// (msgSample != nil) short-circuits before it would matter.
func sampleAtOrZero(sample *source.MessageSample) time.Time {
	if sample == nil {
		return time.Time{}
	}
	return sample.At
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
