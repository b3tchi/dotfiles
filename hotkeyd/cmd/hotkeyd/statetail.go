// statetail.go implements the `state-tail` subcommand (sp021 Task 13, bd
// dotfiles-ylmp.12): a drop-in Go replacement for state-tail.py's argv
// contract (`state-tail.py [display]`, default $DISPLAY) that connects to
// this display's layer-state socket (internal/layer's StatePublisher,
// SocketPath) and prints every line verbatim to stdout.
//
// # No internal retry (adr0014)
//
// A connect failure or a closed connection is a SINGLE terminal event: this
// file dials exactly once and reads until EOF or an error, then returns --
// there is no reconnect loop anywhere in this file. adr0014's decision is
// that a self-respawning reader cannot re-establish its own vanished
// precondition from the inside; it must die and let the layer above (here,
// whatever process spawns `hotkeyd state-tail` -- a QML Process with a
// restart timer, matching state-tail.py's existing callers) decide when to
// try again. Exit 0 on a clean peer close (the daemon went away normally --
// "let the host respawn", mirroring state-tail.py's own comment) and exit 1
// on a connect failure or a read error, so the host can tell "nothing to
// connect to" from "was talking, then wasn't" if it ever wants to.
package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"os"
	"strings"

	"hotkeyd/internal/layer"
)

// runStateTailCmd is `state-tail`'s production entry point. argv is
// everything after the "state-tail" subcommand word (Dispatch already
// stripped it). Matches state-tail.py's own argv contract: an explicit
// positional display argument, else $DISPLAY, else ":0" (resolveDisplay).
func runStateTailCmd(argv []string) int {
	display := ""
	if len(argv) > 0 {
		display = argv[0]
	}
	return stateTail(display, os.Stdout, os.Stderr)
}

// stateTail connects to display's state socket and prints every line
// verbatim to out, returning the process exit code. Factored out from
// runStateTailCmd so it is testable against a real net.Listen("unix", ...)
// fixture with injected writers, no subprocess needed.
func stateTail(display string, out, errOut io.Writer) int {
	disp := resolveDisplay(display)
	path := layer.SocketPath(disp)

	conn, err := net.Dial("unix", path)
	if err != nil {
		fmt.Fprintf(errOut, "state-tail: cannot connect to %s: %s\n", path, err)
		return 1
	}
	defer conn.Close()

	scanner := bufio.NewScanner(conn)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fmt.Fprintln(out, line)
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintf(errOut, "state-tail: %s: %s\n", path, err)
		return 1
	}
	// Scanner stopped with no error: the peer closed cleanly (EOF). The
	// daemon went away -- exit 0 and let the host's own respawn timer
	// decide whether/when to reconnect (adr0014; state-tail.py's own
	// comment: "daemon went away: exit, let the host respawn").
	return 0
}
