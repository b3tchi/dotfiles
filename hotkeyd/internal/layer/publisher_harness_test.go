package layer

import (
	"path/filepath"
	"testing"
)

// TestWriteRawLineReachesClientsVerbatim is the property the quickshell bar
// harness depends on: bytes that are NOT a valid state line must be deliverable
// to a subscriber. Without it, a "the bar survives a malformed line" scenario
// can only ever demonstrate that the fixture refused to send one.
func TestWriteRawLineReachesClientsVerbatim(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-1.sock")
	pub, err := NewStatePublisher(path, State{Layer: "nav", Mod: "move"})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer pub.Close()

	r := dial(t, path)
	defer r.Close()
	waitForClientCount(t, pub, 1)
	if got, want := readLine(t, r), "{\"layer\":\"nav\",\"mod\":\"move\"}\n"; got != want {
		t.Fatalf("replay line = %q, want %q", got, want)
	}

	if n := pub.WriteRawLine("not json at all @@@"); n != 1 {
		t.Fatalf("WriteRawLine wrote to %d clients, want 1", n)
	}
	if got, want := readLine(t, r), "not json at all @@@\n"; got != want {
		t.Errorf("raw line = %q, want %q -- it must arrive byte for byte, since "+
			"the point is to put something unparseable on the wire", got, want)
	}
}

// TestWriteRawLineDoesNotBecomeTheReplayedState is the asymmetry with Publish,
// and it is load-bearing rather than incidental: a reader that reconnects after
// garbage must be replayed the last REAL state. If raw bytes updated `current`,
// a reconnecting bar would be handed the noise as its opening line and the
// suite's reconnect-replay assertion would be testing the wrong thing.
func TestWriteRawLineDoesNotBecomeTheReplayedState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-2.sock")
	pub, err := NewStatePublisher(path, State{Layer: "default"})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer pub.Close()

	first := dial(t, path)
	waitForClientCount(t, pub, 1)
	readLine(t, first) // drain the replay
	pub.Publish(State{Layer: "nav", Mod: "resize"})
	readLine(t, first)
	pub.WriteRawLine("garbage")
	readLine(t, first)
	// Closed, not reaped: the publisher drops a dead client on its next write
	// attempt, not when the peer hangs up, so ClientCount deliberately still
	// reads 1 here. The assertion below does not depend on the reap either way.
	_ = first.Close()

	// A fresh subscriber must open on the last well-formed state, not "garbage".
	second := dial(t, path)
	defer second.Close()
	if got, want := readLine(t, second), "{\"layer\":\"nav\",\"mod\":\"resize\"}\n"; got != want {
		t.Errorf("replay after a raw write = %q, want %q", got, want)
	}
}

// TestWriteRawLineOnAClosedPublisherIsANoOp: Close() is reachable concurrently
// with a harness still writing, and a post-Close write must not panic on the
// nil listener or resurrect a dropped client.
func TestWriteRawLineOnAClosedPublisherIsANoOp(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-3.sock")
	pub, err := NewStatePublisher(path, State{Layer: "default"})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	if err := pub.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if n := pub.WriteRawLine("anything"); n != 0 {
		t.Errorf("WriteRawLine on a closed publisher wrote to %d clients, want 0", n)
	}
}
