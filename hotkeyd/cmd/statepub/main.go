// Command statepub is a TEST FIXTURE, never shipped to a session: it publishes
// hotkeyd layer state on a display's unix socket so quickshell's bar can be
// driven through every layer transition without a keyboard, an X server, or a
// real daemon (dotfiles-ylmp.16, sp021 Task 16).
//
// It replaces quickshell/test-mode-bar.sh's statepub.py, which imported
// hotkeyd/layers.py and drove the REAL StatePublisher. That property is the
// reason this exists as a Go program rather than a hand-rolled socket server
// in the suite: it uses internal/layer's actual StatePublisher, so the bytes
// the bar reads here are produced by the same code the daemon runs, and the
// harness cannot drift from production by construction. A fixture that
// reimplemented the wire format would keep passing after the daemon changed it.
//
// # Protocol
//
//	statepub <command-fifo> [initial-state-json]
//
// Commands are read one per line from <command-fifo>:
//
//	{"layer":"nav","mod":"move"}   publish this state (any JSON object)
//	RAW:<text>                     write <text> to clients verbatim, no
//	                               encoding — the malformed-line scenario
//	QUIT                           close the socket and exit 0
//
// `CLIENTS <n>` is printed to stdout whenever the subscriber count changes, so
// the suite can WAIT for the bar to attach instead of sleeping and hoping — a
// fixed sleep raced the bar's 1s reconnect timer and flaked.
//
// [initial-state-json] is published BEFORE the socket accepts anyone, which is
// what makes replay-on-connect reachable: a bar started afterwards must be told
// the current layer immediately rather than sitting blank until the next
// change. That gap was bd dotfiles-4uiu, and it is the thing Task 8's
// accept-time replay fixed — so the fixture has to be able to set it up.
//
// The display comes from $DISPLAY, matching what the daemon does, so the suite
// controls the socket path the same way it controls the daemon's.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"hotkeyd/internal/layer"
)

// wireIn mirrors the daemon's published line: `mod` is absent or null when no
// modifier is held, which is why it is a pointer and not a string.
type wireIn struct {
	Layer string  `json:"layer"`
	Mod   *string `json:"mod"`
}

func parseState(s string) (layer.State, error) {
	var w wireIn
	if err := json.Unmarshal([]byte(s), &w); err != nil {
		return layer.State{}, err
	}
	st := layer.State{Layer: w.Layer}
	if w.Mod != nil {
		st.Mod = *w.Mod
	}
	return st, nil
}

func main() {
	os.Exit(run())
}

func run() int {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: statepub <command-fifo> [initial-state-json]")
		return 2
	}
	fifoPath := os.Args[1]

	initial := layer.State{}
	if len(os.Args) > 2 && os.Args[2] != "" {
		st, err := parseState(os.Args[2])
		if err != nil {
			fmt.Fprintf(os.Stderr, "statepub: bad initial state %q: %v\n", os.Args[2], err)
			return 2
		}
		initial = st
	}

	sockPath := layer.SocketPath(os.Getenv("DISPLAY"))
	pub, err := layer.NewStatePublisher(sockPath, initial)
	if err != nil {
		fmt.Fprintf(os.Stderr, "statepub: cannot publish on %s: %v\n", sockPath, err)
		return 1
	}

	// Report the subscriber count on a tick rather than only after a command:
	// clients attach on the publisher's own accept goroutine, so a count that
	// only refreshed when the suite wrote a line would never announce the very
	// first connection — which is the one the suite waits for.
	done := make(chan struct{})
	go func() {
		seen := -1
		t := time.NewTicker(25 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				if n := pub.ClientCount(); n != seen {
					seen = n
					fmt.Printf("CLIENTS %d\n", n)
					_ = os.Stdout.Sync()
				}
			}
		}
	}()

	// O_RDWR, not O_RDONLY: holding a writer ourselves means the reader never
	// sees EOF when the suite's own write end closes between commands, so this
	// blocks waiting for the next line instead of exiting early.
	f, err := os.OpenFile(fifoPath, os.O_RDWR, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "statepub: cannot open command fifo %s: %v\n", fifoPath, err)
		close(done)
		_ = pub.Close()
		return 1
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case line == "":
			continue
		case line == "QUIT":
			close(done)
			_ = pub.Close()
			return 0
		case strings.HasPrefix(line, "RAW:"):
			pub.WriteRawLine(strings.TrimPrefix(line, "RAW:"))
		default:
			st, err := parseState(line)
			if err != nil {
				// Report and keep serving. The suite deliberately feeds this
				// process only well-formed states — garbage goes to the BAR via
				// RAW: — so a parse error here is the harness's own bug and must
				// be visible rather than silently dropped.
				fmt.Fprintf(os.Stderr, "statepub: %v\n", err)
				continue
			}
			pub.Publish(st)
		}
	}

	close(done)
	_ = pub.Close()
	return 0
}
