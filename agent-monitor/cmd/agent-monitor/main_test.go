package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeStub drops an executable shell script named `name` into dir, so a
// test can point PATH at dir and have source.Available()/MessagesAvailable()
// find a stand-in binary without ever touching the real agent-census or
// pi-worker.
func writeStub(t *testing.T, dir, name, script string) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatalf("write stub %s: %v", name, err)
	}
}

// TestRunOnce_NoRawModeNoAltScreen_ExitsCleanly is the test_plan's --once
// case: on a stub PATH it must write a frame to stdout and exit 0 (return a
// nil error here, since runOnce is the pre-os.Exit seam main() calls),
// emitting no terminal-mode escape sequence at all — no alternate-screen
// enter/exit, no raw-mode setup, no cursor-home/clear — so the output
// composes cleanly in a pipe.
func TestRunOnce_NoRawModeNoAltScreen_ExitsCleanly(t *testing.T) {
	dir := t.TempDir()
	writeStub(t, dir, "agent-census", "#!/bin/sh\necho '[]'\n")
	writeStub(t, dir, "pi-worker", "#!/bin/sh\necho '[]'\n")

	oldPath := os.Getenv("PATH")
	if err := os.Setenv("PATH", dir+string(os.PathListSeparator)+oldPath); err != nil {
		t.Fatalf("setenv PATH: %v", err)
	}
	defer os.Setenv("PATH", oldPath)

	var buf bytes.Buffer
	if err := runOnce(&buf); err != nil {
		t.Fatalf("runOnce: %v", err)
	}

	out := buf.String()
	if out == "" {
		t.Fatalf("expected a rendered frame, got empty output")
	}
	if strings.ContainsRune(out, 0x1b) {
		t.Fatalf("output contains an ESC byte; --once must emit no terminal-mode escape sequence: %q", out)
	}
	for _, forbidden := range []string{altScreenEnter, altScreenExit} {
		if strings.Contains(out, forbidden) {
			t.Fatalf("output contains an alternate-screen sequence %q", forbidden)
		}
	}
	if !strings.Contains(out, "agents") {
		t.Fatalf("expected the roster pane header in output, got %q", out)
	}
	if !strings.Contains(out, "messages") {
		t.Fatalf("expected the message pane header in output, got %q", out)
	}
}

func TestRunOnce_MissingBinary_ReturnsError(t *testing.T) {
	dir := t.TempDir() // empty: neither stub exists
	oldPath := os.Getenv("PATH")
	if err := os.Setenv("PATH", dir); err != nil {
		t.Fatalf("setenv PATH: %v", err)
	}
	defer os.Setenv("PATH", oldPath)

	var buf bytes.Buffer
	if err := runOnce(&buf); err == nil {
		t.Fatalf("expected an error when agent-census/pi-worker are not on PATH")
	}
}

// dotfiles-r9ty: the interactive frame must use CRLF line endings.
//
// The bug this pins was invisible to every other test in this module. The
// render packages are tested on the []string they return, and --once is
// asserted on bytes — both correct, and both blind to how those lines reach a
// terminal that is in RAW mode, where ONLCR is off and a bare \n drops a row
// without returning the carriage. The result was a frame that staircased off
// the right edge. Only running the real TUI showed it.
func TestFrameBytes_UsesCRLF(t *testing.T) {
	got := frameBytes([]string{"alpha", "beta"})

	if want := "\x1b[H\x1b[J"; !strings.HasPrefix(got, want) {
		t.Fatalf("frame does not start with home+clear: %q", got)
	}
	if want := "\x1b[H\x1b[Jalpha\r\nbeta\r\n"; got != want {
		t.Errorf("frame = %q, want %q", got, want)
	}

	// The property that actually matters, stated independently of the exact
	// frame above: no LF may appear without a CR immediately before it, or
	// the row below starts at the wrong column.
	for i, r := range got {
		if r == '\n' && (i == 0 || got[i-1] != '\r') {
			t.Errorf("bare LF at byte %d in %q — raw mode will not return the carriage", i, got)
		}
	}
}

func TestFrameBytes_EmptyFrameStillClears(t *testing.T) {
	// A frame with no lines must still home and clear, otherwise a transition
	// to an empty roster leaves the previous frame on screen.
	if got, want := frameBytes(nil), "\x1b[H\x1b[J"; got != want {
		t.Errorf("frameBytes(nil) = %q, want %q", got, want)
	}
}

// dotfiles-9x2m: the frame must fit the terminal, or the terminal scrolls and
// carries the roster off the top where in-pane scrolling cannot reach it.
func TestFitPanes_TotalNeverExceedsHeight(t *testing.T) {
	long := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = "row"
		}
		return out
	}

	for _, h := range []int{3, 10, 24, 40} {
		roster, log := fitPanes(long(100), long(100), h)
		if total := len(roster) + 1 + len(log); total > h {
			t.Errorf("height %d: frame is %d lines (roster %d + blank + log %d), want <= %d",
				h, total, len(roster), len(log), h)
		}
		if len(roster) == 0 || len(log) == 0 {
			t.Errorf("height %d: a pane was trimmed out of existence (roster %d, log %d)",
				h, len(roster), len(log))
		}
	}
}

func TestFitPanes_ShortPaneYieldsItsSurplus(t *testing.T) {
	// Three agents and a busy bus: the roster should not hold half the screen
	// empty while messages are being trimmed.
	roster, log := fitPanes([]string{"hdr", "a", "b"}, make([]string, 100), 25)
	if len(roster) != 3 {
		t.Errorf("short pane was trimmed: got %d lines, want 3", len(roster))
	}
	if want := 25 - 1 - 3; len(log) != want {
		t.Errorf("log got %d lines, want %d (all of the roster's surplus)", len(log), want)
	}
}

func TestFitPanes_TrimsFromBottomKeepingHeaders(t *testing.T) {
	roster := []string{"ROSTER HEADER", "r1", "r2", "r3", "r4", "r5"}
	log := []string{"LOG HEADER", "m1", "m2", "m3", "m4", "m5"}
	gotRoster, gotLog := fitPanes(roster, log, 7)

	if gotRoster[0] != "ROSTER HEADER" {
		t.Errorf("roster lost its header: %q", gotRoster)
	}
	if gotLog[0] != "LOG HEADER" {
		t.Errorf("log lost its header: %q", gotLog)
	}
}
