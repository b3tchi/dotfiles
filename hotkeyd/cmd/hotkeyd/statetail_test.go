package main

// statetail_test.go covers the `state-tail` subcommand (sp021 Task 13, bd
// dotfiles-ylmp.12): connect, print lines verbatim, exit the moment the
// socket is missing or closes -- adr0014's no-internal-retry, and a
// drop-in for state-tail.py's argv contract.

import (
	"bytes"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"hotkeyd/internal/layer"
)

// TestStateTail_SocketMissing_ExitsOneImmediately is the design's core
// no-retry requirement made concrete: a socket that was never there must
// fail FAST, once, with no internal loop -- adr0014 says the HOST owns the
// respawn timer.
func TestStateTail_SocketMissing_ExitsOneImmediately(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	var stdout, stderr bytes.Buffer
	start := time.Now()
	code := stateTail(":123", &stdout, &stderr)
	elapsed := time.Since(start)

	if code != 1 {
		t.Fatalf("stateTail with no socket = %d, want 1", code)
	}
	if stdout.Len() != 0 {
		t.Errorf("stdout should be empty on connect failure, got %q", stdout.String())
	}
	if stderr.Len() == 0 {
		t.Error("stderr should name the failed connection, got nothing")
	}
	if elapsed > 2*time.Second {
		t.Errorf("stateTail took %s to fail on a missing socket -- looks like an internal retry loop, which adr0014 forbids", elapsed)
	}
}

// TestStateTail_PrintsLinesVerbatim_ThenExitsZeroOnClose drives a real
// unix-socket server standing in for the daemon's state publisher: writes
// two JSON lines, then closes -- state-tail must print both, then exit 0
// (not 1) when the peer goes away cleanly, matching state-tail.py's "not
// chunk: return 0" contract.
func TestStateTail_PrintsLinesVerbatim_ThenExitsZeroOnClose(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	display := ":55"

	path := layer.SocketPath(display)
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %s", err)
	}
	defer ln.Close()

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.Write([]byte(`{"layer":"default","mod":null}` + "\n"))
		conn.Write([]byte(`{"layer":"nav","mod":null}` + "\n"))
		// close: the daemon went away
	}()

	var stdout, stderr bytes.Buffer
	code := stateTail(display, &stdout, &stderr)
	wg.Wait()

	if code != 0 {
		t.Fatalf("stateTail on a clean peer close = %d, want 0; stderr: %s", code, stderr.String())
	}
	got := stdout.String()
	if !strings.Contains(got, `"layer":"default"`) || !strings.Contains(got, `"layer":"nav"`) {
		t.Fatalf("stdout missing one or both lines verbatim: %q", got)
	}
	// Verbatim means unmodified JSON, one line each -- not re-encoded or
	// reordered.
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d line(s), want 2: %q", len(lines), got)
	}
	if lines[0] != `{"layer":"default","mod":null}` {
		t.Errorf("line 1 = %q, not verbatim", lines[0])
	}
	if lines[1] != `{"layer":"nav","mod":null}` {
		t.Errorf("line 2 = %q, not verbatim", lines[1])
	}
}

// TestStateTail_ResolvesDisplayLikePythonsArgvContract pins state-tail's
// argv contract as a drop-in for state-tail.py: an explicit display beats
// $DISPLAY. Exercised through runStateTailCmd, which is what actually reads
// argv/os.Environ, using a real listener to make the resolution
// observable (a wrong path would fail to connect).
func TestStateTail_ResolvesDisplayLikePythonsArgvContract(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("DISPLAY", ":1") // must NOT be used -- argv[0] wins

	path := layer.SocketPath(":42")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %s", err)
	}
	defer ln.Close()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		conn.Close() // immediate EOF is fine -- proves we reached the RIGHT socket
	}()

	if code := runStateTailCmd([]string{":42"}); code != 0 {
		t.Fatalf("runStateTailCmd([:42]) = %d, want 0 (argv display should have been used, not $DISPLAY=:1)", code)
	}
}
