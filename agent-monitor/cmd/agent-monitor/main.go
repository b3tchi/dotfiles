// agent-monitor is the interactive terminal view over agent-census's
// published roster. Per adr0030, this binary IS the interface — there is no
// nushell/actions/ wrapper, and it links straight to ~/.local/bin.
//
// This scaffold (sp030 T8) wires the roster pane only: a slow, gated sample
// on a ticker, a forced refresh on `r`, and a plain render loop. The message
// pane, `--once`, real key-table extraction and full loop-guard packaging
// are later tasks (T9, T10) — see agent-monitor/internal/source/census.go
// and internal/render/roster.go for where the real logic and its tests
// live; this file is deliberately thin.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"agent-monitor/internal/render"
	"agent-monitor/internal/source"

	"golang.org/x/term"
)

// pollInterval is the roster's slow tick. ~600ms is the measured cost of one
// underlying probe per account (ft012); this cadence keeps a poll from
// overlapping the previous one under normal conditions while still feeling
// live. `r` bypasses it entirely for an on-demand full read.
const pollInterval = 3 * time.Second

func main() {
	project := flag.String("project", "", "restrict the roster to one project")
	flag.Parse()
	_ = project // scaffold: project filtering lands with the message pane (T9)

	// adr0014 guard 1, fail fast on unrecoverable setup: checked once, here,
	// before any loop starts. A missing dependency is not something a retry
	// fixes, so agent-monitor says so once and exits — never an empty UI
	// that looks like "no agents".
	if err := source.Available(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	stampPath := filepath.Join(os.TempDir(), fmt.Sprintf("agent-monitor-census-stamp-%d", os.Getuid()))
	monitor := source.NewMonitor(source.NewSampler(stampPath))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// First frame: a forced, ungated read so startup never shows "waiting
	// for first sample" when a perfectly good census is one exec away.
	monitor.Refresh(ctx)

	restoreTerminal := enterInteractiveMode()
	defer restoreTerminal()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	keys := make(chan byte)
	go readKeys(keys)

	draw := func() {
		lines := render.Render(monitor.Last(), monitor.Stale(), time.Now(), terminalWidth())
		writeFrame(lines)
	}
	draw()

	go source.RunLoop(ctx, monitor, pollInterval, func(changed bool) {
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
				monitor.Refresh(ctx)
				draw()
			}
		}
	}
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
// a no-op both ways, so the scaffold never corrupts a caller's pipe.
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

func writeFrame(lines []string) {
	// Home cursor and clear below, rather than a full clear-and-redraw --
	// cheaper and avoids a visible flash on every tick.
	fmt.Print("\x1b[H\x1b[J")
	for _, l := range lines {
		fmt.Println(l)
	}
}
