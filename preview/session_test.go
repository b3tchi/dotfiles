package main

import (
	"encoding/json"
	"sync"
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

	sm.SwapPath(1, "a.go")
	sm.SwapPath(2, "c.md")

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

	// The production store+broadcast pair (handlePreviewSet: SwapPath then a
	// per-slot Hub broadcast). Exercises the same primitives rather than the
	// removed SetPath convenience.
	sm.SwapPath(2, "c.md")
	sm.Hub(2).Broadcast(redrawMessage("c.md"))

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
		t.Fatal("slot 2 client received nothing after SwapPath + broadcast")
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

// --- SlotManager: per-slot nvim address (sp009 Task 1) -----------------

// TestSlotManagerNvimAddrSetAndGet proves SetNvimAddr binds an address to a
// slot and NvimAddr returns it back (sp009 Task 1 success criteria: the
// per-slot half of "open in the nvim that owns slot N").
func TestSlotManagerNvimAddrSetAndGet(t *testing.T) {
	sm := NewSlotManager()
	sm.SetNvimAddr(1, "/tmp/nvim.1.sock")

	if got := sm.NvimAddr(1); got != "/tmp/nvim.1.sock" {
		t.Errorf("NvimAddr(1) = %q, want /tmp/nvim.1.sock", got)
	}
}

// TestSlotManagerNvimAddrUnknownSlotEmpty proves NvimAddr on a slot that
// never had SetNvimAddr called returns "" (sp009 Task 1 edge case).
func TestSlotManagerNvimAddrUnknownSlotEmpty(t *testing.T) {
	sm := NewSlotManager()
	if got := sm.NvimAddr(42); got != "" {
		t.Errorf("NvimAddr(42) on fresh slot = %q, want empty", got)
	}
}

// TestSlotManagerNvimAddrReRegisterUpdates proves a second SetNvimAddr call
// on the same slot overwrites the address (last-wins, not additive) — the
// re-register-updates-not-new-slot edge case (sp009 Task 1).
func TestSlotManagerNvimAddrReRegisterUpdates(t *testing.T) {
	sm := NewSlotManager()
	sm.SetNvimAddr(3, "/tmp/nvim.a.sock")
	sm.SetNvimAddr(3, "/tmp/nvim.b.sock")

	if got := sm.NvimAddr(3); got != "/tmp/nvim.b.sock" {
		t.Errorf("NvimAddr(3) after re-register = %q, want /tmp/nvim.b.sock", got)
	}
}

// --- SlotManager: free-slot allocation (sp009 Task 1) -------------------

// TestSlotManagerAllocateSlotReturnsUnusedSlot proves AllocateSlot returns a
// slot number not already occupied by an existing slot.
func TestSlotManagerAllocateSlotReturnsUnusedSlot(t *testing.T) {
	sm := NewSlotManager()
	sm.SetNvimAddr(1, "/tmp/nvim.1.sock")

	n := sm.AllocateSlot()
	if n == 1 {
		t.Errorf("AllocateSlot() = %d, want a slot distinct from the occupied slot 1", n)
	}
}

// TestSlotManagerAllocateSlotConcurrentDistinct proves concurrent
// AllocateSlot calls (as would happen from simultaneous no-slot /register
// requests) never hand out the same slot number twice — the mutex-guarded
// allocation success criterion (sp009 Task 1: "concurrent registers with no
// slot receive distinct slot numbers").
func TestSlotManagerAllocateSlotConcurrentDistinct(t *testing.T) {
	sm := NewSlotManager()

	const n = 20
	results := make([]int, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx] = sm.AllocateSlot()
		}(i)
	}
	wg.Wait()

	seen := make(map[int]bool, n)
	for _, got := range results {
		if seen[got] {
			t.Fatalf("AllocateSlot handed out duplicate slot %d across %d concurrent calls: %v", got, n, results)
		}
		seen[got] = true
	}
}

// --- helpers -----------------------------------------------------------

func newTestClient(buf int) *wsClient {
	return &wsClient{send: make(chan []byte, buf)}
}

// TestSlotWorkspaceRoundTrip proves a slot carries the WM workspace its
// nvim was on when it registered, alongside the nvim address it already
// holds (dotfiles-816). preview-d only stores and serves the string — the
// wrapper captures it and does the WM move, since placement is an interface
// concern and the daemon is an engine (adr0003).
func TestSlotWorkspaceRoundTrip(t *testing.T) {
	sm := NewSlotManager()

	if got := sm.Workspace(1); got != "" {
		t.Errorf("Workspace(1) on a fresh slot = %q, want \"\" (no workspace recorded)", got)
	}

	sm.SetWorkspace(1, "dotfiles")
	if got := sm.Workspace(1); got != "dotfiles" {
		t.Errorf("Workspace(1) = %q, want \"dotfiles\"", got)
	}

	// Slots must not leak into each other — the whole point of the slot model.
	if got := sm.Workspace(2); got != "" {
		t.Errorf("Workspace(2) = %q, want \"\" — slot 1's workspace leaked", got)
	}

	// Re-registering from a different workspace must overwrite, not append:
	// nvim moving workspaces and re-running :PreviewStart is the fix path for
	// the known staleness caveat.
	sm.SetWorkspace(1, "promotool")
	if got := sm.Workspace(1); got != "promotool" {
		t.Errorf("Workspace(1) after re-register = %q, want \"promotool\"", got)
	}
}
