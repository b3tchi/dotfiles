// agent-monitor is the interactive terminal view over agent-census's
// published roster and pi-worker's message bus. Per adr0030, this binary IS
// the interface — there is no nushell/actions/ wrapper, and it links
// straight to ~/.local/bin.
//
// sp030 T8 wired the roster pane scaffold: a slow, gated sample on a ticker,
// a forced refresh on `r`, and a plain render loop. sp030 T9 (this file)
// adds the second pane — messages, sampled on their own fast, ungated
// ticker — and `--once`, a non-interactive single-frame mode that composes
// in a pipe (no raw mode, no alternate screen). Real key-table extraction
// and full loop-guard packaging are T10's job.
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

	for _, line := range buildFrame(censusMonitor, msgMonitor, time.Now(), terminalWidth()) {
		fmt.Fprintln(w, line)
	}
	return nil
}

// runInteractive is the T8 scaffold's original loop, now driving two
// samplers (roster + messages) and drawing their combined frame.
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

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// First frame: forced, ungated reads on both panes so startup never
	// shows "waiting for first sample" when a perfectly good read is one
	// exec away.
	censusMonitor.Refresh(ctx)
	msgMonitor.Tick(ctx)

	restoreTerminal := enterInteractiveMode()
	defer restoreTerminal()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	keys := make(chan byte)
	go readKeys(keys)

	draw := func() {
		lines := buildFrame(censusMonitor, msgMonitor, time.Now(), terminalWidth())
		writeFrame(lines)
	}
	draw()

	go source.RunLoop(ctx, censusMonitor, pollInterval, piBoundInterval, func(changed bool) {
		if changed {
			draw()
		}
	})
	go source.RunMessagesLoop(ctx, msgMonitor, messagesInterval, func(changed bool) {
		if changed {
			draw()
		}
	})

	for {
		select {
		case <-sigCh:
			return
		case <-ctx.Done():
			return
		case b, ok := <-keys:
			if !ok {
				return
			}
			switch b {
			case 'q', 'Q', 0x03: // 0x03 = Ctrl-C, in case raw mode swallowed SIGINT
				return
			case 'r', 'R':
				censusMonitor.Refresh(ctx)
				msgMonitor.Tick(ctx)
				draw()
			}
		}
	}
}

// buildFrame stacks the roster pane over the message pane, separated by one
// blank line, into a single list of terminal lines. Neither pane's Render
// function talks to the other; this is the only place that joins them, and
// it joins rendered TEXT, not data — the two samples never touch.
func buildFrame(censusMonitor *source.Monitor, msgMonitor *source.MessagesMonitor, now time.Time, width int) []string {
	var lines []string
	lines = append(lines, render.Render(censusMonitor.Last(), censusMonitor.Stale(), now, width)...)
	lines = append(lines, "")
	lines = append(lines, render.RenderLog(msgMonitor.Last(), msgMonitor.Stale(), now, width)...)
	return lines
}

// readKeys feeds raw stdin bytes to ch, closing it on EOF/error (stdin
// closed, e.g. under a non-interactive harness). Full key-table handling
// (tab/filter/scroll) is internal/tui's job in a later task; this scaffold
// only needs to tell `q` and `r` apart from everything else.
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
