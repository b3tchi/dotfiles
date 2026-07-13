package main

import (
	"encoding/json"
	"testing"
)

// --- Hub broadcast / slow-client drop (ported akm-graph watch_test.go
// pattern — sp008 Task 4 plan: "ws hub uses a bounded send buffer and drops
// slow clients") ------------------------------------------------------------

// TestHubBroadcastDropsBlockedClient proves a stuck client (send buffer
// full, never drained) is dropped on broadcast while the others still
// receive — a slow client must not stall the hub (sp008 Task 4 test_plan).
func TestHubBroadcastDropsBlockedClient(t *testing.T) {
	h := NewHub()

	good1 := newTestClient(4)
	good2 := newTestClient(4)
	stuck := newTestClient(0) // unbuffered + never drained -> always blocks
	h.Register(good1)
	h.Register(good2)
	h.Register(stuck)
	if h.Count() != 3 {
		t.Fatalf("Count after register: %d, want 3", h.Count())
	}

	h.Broadcast([]byte("hello"))

	if got := <-good1.send; string(got) != "hello" {
		t.Errorf("good1 got %q, want hello", got)
	}
	if got := <-good2.send; string(got) != "hello" {
		t.Errorf("good2 got %q, want hello", got)
	}
	if h.Count() != 2 {
		t.Errorf("stuck client not dropped: Count %d, want 2", h.Count())
	}
}

// TestHubUnregisterIdempotent proves a double unregister (broadcast-drop
// then read-pump disconnect) does not panic on a double close.
func TestHubUnregisterIdempotent(t *testing.T) {
	h := NewHub()
	c := newTestClient(1)
	h.Register(c)
	h.Unregister(c)
	h.Unregister(c) // must be a no-op, not a panic
	if h.Count() != 0 {
		t.Errorf("Count after unregister: %d, want 0", h.Count())
	}
}

// --- SlotManager: independent per-N path + client sets -----------------

// TestSlotManagerIndependentPaths proves distinct N values maintain
// independent current-path state (sp008 Task 4 success criteria: the slot
// model / multi-window precondition).
func TestSlotManagerIndependentPaths(t *testing.T) {
	sm := NewSlotManager()

	sm.SetPath(1, "a.go")
	sm.SetPath(2, "c.md")

	if got := sm.CurrentPath(1); got != "a.go" {
		t.Errorf("slot 1 path = %q, want a.go", got)
	}
	if got := sm.CurrentPath(2); got != "c.md" {
		t.Errorf("slot 2 path = %q, want c.md", got)
	}
}

// TestSlotManagerIndependentHubs proves each slot has its own Hub — a
// client registered against slot 1's hub is untouched by a broadcast on
// slot 2's hub (slot isolation at the client-set level, not just path).
func TestSlotManagerIndependentHubs(t *testing.T) {
	sm := NewSlotManager()

	c1 := newTestClient(4)
	c2 := newTestClient(4)
	sm.Hub(1).Register(c1)
	sm.Hub(2).Register(c2)

	sm.SetPath(2, "c.md")

	select {
	case msg := <-c2.send:
		var got redrawMsg
		if err := json.Unmarshal(msg, &got); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if got.Path != "c.md" {
			t.Errorf("slot 2 client got path %q, want c.md", got.Path)
		}
	default:
		t.Fatal("slot 2 client received nothing after SetPath(2, ...)")
	}

	select {
	case msg := <-c1.send:
		t.Fatalf("slot 1 client wrongly received a broadcast meant for slot 2: %s", msg)
	default:
		// expected: slot 1 untouched
	}
}

// TestSlotManagerNewSlotHasEmptyPath proves an unset slot's CurrentPath is
// "" — no window has connected yet and no POST has landed.
func TestSlotManagerNewSlotHasEmptyPath(t *testing.T) {
	sm := NewSlotManager()
	if got := sm.CurrentPath(99); got != "" {
		t.Errorf("fresh slot 99 path = %q, want empty", got)
	}
}

// --- helpers -----------------------------------------------------------

func newTestClient(buf int) *wsClient {
	return &wsClient{send: make(chan []byte, buf)}
}
