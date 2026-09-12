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
)

func main() {
	project := flag.String("project", "", "restrict the roster to one project")
	once := flag.Bool("once", false, "render one frame to stdout and exit 0: no raw mode, no alternate screen, so it composes in a pipe")
	flag.Parse()
	_ = project // scaffold: project filtering lands with a later task

	if *once {
		if err := runOnce(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	runInteractive()
}

// runOnce renders exactly one frame — a forced roster refresh plus one
// ungated message poll — and writes it to w as plain text: no ANSI colour,
// no cursor-home/clear escape, no alternate-screen or raw-mode sequence.
// That is what "composes in a pipe" means: the byte stream w receives must
// contain nothing a terminal would interpret as a control sequence.
func runOnce(w io.Writer) error {
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
	// it renders — a fresh, untouched Model is exactly "no filter, no
	// scroll", the same state an interactive session starts in too.
	for _, line := range buildFrame(tui.NewModel(), censusMonitor, msgMonitor, time.Now(), terminalWidth()) {
		fmt.Fprintln(w, line)
	}
	return nil
}

// runInteractive drives two samplers (roster + messages), a tui.Model for
// key-driven state, and draws their combined, filtered, scrolled frame.
func runInteractive() {
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
		lines := buildFrame(model, censusMonitor, msgMonitor, time.Now(), terminalWidth())
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

// buildFrame stacks the roster pane over the message pane, separated by one
// blank line, into a single list of terminal lines. Neither pane's Render
// function talks to the other; this is the only place that joins them, and
// it joins rendered TEXT, not data — the two samples never touch. model's
// committed filter and each pane's scroll offset are applied here, to a
// COPY of the last good sample — Monitor.Last() itself is never mutated, so
// a later change to the filter or scroll can still see every row the
// sampler ever captured.
func buildFrame(model *tui.Model, censusMonitor *source.Monitor, msgMonitor *source.MessagesMonitor, now time.Time, width int) []string {
	var lines []string
	lines = append(lines, render.Render(filteredCensusSample(model, censusMonitor.Last()), censusMonitor.Stale(), now, width)...)
	lines = append(lines, "")
	lines = append(lines, render.RenderLog(filteredMessageSample(model, msgMonitor.Last()), msgMonitor.Stale(), now, width)...)
	return lines
}

// filteredCensusSample applies model's committed filter and the roster
// pane's own scroll offset (dropping that many rows from the top — a
// scrolled-past row is simply not in the slice render.Render receives) to
// sample, without mutating it. It calls SetRosterLen so the NEXT keystroke's
// scroll bound reflects the CURRENT (post-filter) row count — a filter that
// just shrank the roster must not leave scroll pointing past its new end.
func filteredCensusSample(model *tui.Model, sample *source.Sample) *source.Sample {
	if sample == nil {
		return nil
	}
	rows := model.FilterRoster(sample.Rows)
	model.SetRosterLen(len(rows))
	return &source.Sample{Rows: rows[model.RosterScroll:], At: sample.At}
}

// filteredMessageSample is filteredCensusSample's twin for the message pane.
func filteredMessageSample(model *tui.Model, sample *source.MessageSample) *source.MessageSample {
	if sample == nil {
		return nil
	}
	msgs := model.FilterMessages(sample.Messages)
	model.SetMessagesLen(len(msgs))
	return &source.MessageSample{Messages: msgs[model.MessagesScroll:], At: sample.At}
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
	// Home cursor and clear below, rather than a full clear-and-redraw --
	// cheaper and avoids a visible flash on every tick.
	fmt.Print("\x1b[H\x1b[J")
	for _, l := range lines {
		fmt.Println(l)
	}
}
