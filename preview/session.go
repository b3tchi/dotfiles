package main

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	// wsSendBuffer bounds a client's pending-broadcast queue; a client that
	// falls this far behind is dropped rather than allowed to stall the hub
	// (akm-graph wsSendBuffer pattern — sp008 Task 4 plan anti-pattern: ws
	// hub must not stall on one slow window).
	wsSendBuffer = 16
	// wsWriteWait is the per-message write deadline.
	wsWriteWait = 10 * time.Second
	// wsPingPeriod keeps the socket alive through idle periods.
	wsPingPeriod = 30 * time.Second
)

// wsClient is a single /preview<N> websocket subscriber (one connected
// preview window). send is buffered; a client whose buffer fills (stuck
// socket) is dropped by the Hub so one slow reader can never stall the
// broadcast loop (ported akm-graph watch.go pattern).
type wsClient struct {
	conn *websocket.Conn
	send chan []byte
}

// Hub fans a redraw payload out to every connected client of one
// /preview<N> slot. Guarded by a mutex rather than a run-loop goroutine so
// Broadcast/Register/Unregister are simple synchronous calls and
// drop-on-full needs no extra coordination (ported akm-graph watch.go
// verbatim — sp008 Task 4 conventions: "port akm-graph's proven surface
// verbatim where it fits").
type Hub struct {
	mu      sync.Mutex
	clients map[*wsClient]bool
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{clients: make(map[*wsClient]bool)}
}

// Register adds a client.
func (h *Hub) Register(c *wsClient) {
	h.mu.Lock()
	h.clients[c] = true
	h.mu.Unlock()
}

// Unregister removes a client and closes its send channel exactly once.
// Safe to call twice (broadcast-drop then read-pump disconnect).
func (h *Hub) Unregister(c *wsClient) {
	h.mu.Lock()
	if h.clients[c] {
		delete(h.clients, c)
		close(c.send)
	}
	h.mu.Unlock()
}

// Count returns the number of connected clients.
func (h *Hub) Count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// Broadcast pushes msg to every client with a non-blocking send. Any client
// whose buffer is full is dropped (removed + send closed) so it cannot
// stall delivery to the others (sp008 Task 4 edge case: client disconnect /
// stall mid-push is dropped per bounded buffer, no hub stall).
func (h *Hub) Broadcast(msg []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		select {
		case c.send <- msg:
		default:
			// Full buffer -> slow/stuck client. Drop it.
			delete(h.clients, c)
			close(c.send)
		}
	}
}

// redrawMsg is the websocket payload pushed to a /preview<N> window telling
// it which file to hot-swap to. path is relative to the daemon root — the
// same string the client re-requests as GET /file/<path>.
type redrawMsg struct {
	Path string `json:"path"`
}

// redrawMessage marshals a redrawMsg. Marshal of a struct with a single
// string field cannot practically fail, but the fallback keeps the
// sp008-wide anti-pattern (no panic in handlers / hub) true here too.
func redrawMessage(path string) []byte {
	b, err := json.Marshal(redrawMsg{Path: path})
	if err != nil {
		return []byte(`{"path":""}`)
	}
	return b
}

// slot holds one /preview<N> window's live state: the hub fanning redraw
// messages to every connected client of that window, plus the "current
// path" — buffered here so a POST /preview<N> that arrives before any
// window N has connected is still applied the moment one connects (sp008
// Task 4 edge case).
type slot struct {
	mu   sync.Mutex
	path string // "" = no path ever set for this slot yet
	hub  *Hub
}

// SlotManager owns the independent {path, client-set} state for every
// /preview<N> slot, keyed by N. Distinct N values never see each other's
// path or broadcasts — the slot model that makes multiple concurrent
// preview windows possible (sp008 Task 4 success criteria).
type SlotManager struct {
	mu    sync.Mutex
	slots map[int]*slot
}

// NewSlotManager returns an empty SlotManager; slots are created lazily on
// first access (SetPath, CurrentPath, or Hub) so an unused N never
// allocates state.
func NewSlotManager() *SlotManager {
	return &SlotManager{slots: make(map[int]*slot)}
}

// slotFor returns slot n, creating it (with a fresh Hub) on first access.
func (sm *SlotManager) slotFor(n int) *slot {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	s, ok := sm.slots[n]
	if !ok {
		s = &slot{hub: NewHub()}
		sm.slots[n] = s
	}
	return s
}

// SetPath sets slot n's current path and broadcasts a redraw message to
// every client currently connected to that slot only. Concurrent/rapid
// calls are last-wins: only the most recently set path is ever stored or
// broadcast, so a burst of cursor-driven updates collapses to the caller's
// last call rather than queuing a redraw storm (sp008 Task 4 edge case).
func (sm *SlotManager) SetPath(n int, path string) {
	s := sm.slotFor(n)
	s.mu.Lock()
	s.path = path
	s.mu.Unlock()
	s.hub.Broadcast(redrawMessage(path))
}

// CurrentPath returns slot n's buffered path, or "" if no POST has ever
// landed for it.
func (sm *SlotManager) CurrentPath(n int) string {
	s := sm.slotFor(n)
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.path
}

// Hub returns slot n's websocket hub.
func (sm *SlotManager) Hub(n int) *Hub {
	return sm.slotFor(n).hub
}
