package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	// wsSendBuffer bounds a client's pending-broadcast queue; a client that
	// falls this far behind is dropped rather than allowed to stall the hub.
	wsSendBuffer = 16
	// wsWriteWait is the per-message write deadline.
	wsWriteWait = 10 * time.Second
	// wsPingPeriod keeps the socket alive through idle periods.
	wsPingPeriod = 30 * time.Second
)

// staticFS embeds the viewer assets so GET / and static paths serve from the
// binary regardless of the working directory (us006 AC5, ft004 offline-safe).
// Both render-engine bundles are embedded — the client loads only the one the
// active backend needs (?backend= / AKM_GRAPH_BACKEND). The smoke-test files
// (smoke.sh, smoke-tooltip.html, graph.json) stay on disk, served by smoke.sh's
// own http server, and must not bloat the daemon binary (dotfiles-blm).
//
//go:embed static/index.html static/app.js static/cosmos-bundle.js static/force-graph-bundle.js
var staticFS embed.FS

// defaultBackend is served in index.html's <meta name="akm-backend"> when
// $AKM_GRAPH_BACKEND is unset. force-graph (2D canvas) is default: for a
// ~100s-node graph it keeps the GPU cold at idle where cosmos.gl (WebGL) does not.
const defaultBackend = "force-graph"

// resolveBackend validates $AKM_GRAPH_BACKEND, falling back to defaultBackend.
func resolveBackend() string {
	switch os.Getenv("AKM_GRAPH_BACKEND") {
	case "cosmos":
		return "cosmos"
	case "force-graph":
		return "force-graph"
	default:
		return defaultBackend
	}
}

// Status is the GET /api/status payload: daemon health snapshot.
type Status struct {
	PID         int       `json:"pid"`
	Root        string    `json:"root"`
	Nodes       int       `json:"nodes"`
	Links       int       `json:"links"`
	LastRebuild time.Time `json:"last_rebuild"`
}

// Server owns the current graph snapshot and the HTTP surface. The graph is
// swapped atomically under a mutex so concurrent /api/graph reads never observe
// a half-built graph (sp006 plan — atomic graph swap, no panic in handlers).
type Server struct {
	root string

	mu          sync.RWMutex
	graph       Graph
	lastRebuild time.Time

	ctx    context.Context
	cancel context.CancelFunc

	static   fs.FS
	backend  string
	hub      *Hub
	upgrader websocket.Upgrader
	watcher  *Watcher

	// highlightMu guards highlights independently of mu (the graph lock) —
	// highlight state and graph state are updated on unrelated triggers (a
	// POST vs a filesystem rebuild) and gating one behind the other's lock
	// would be an artificial coupling (sp011 Task 1: per-slot state under
	// its own mutex).
	highlightMu sync.Mutex
	// highlights maps slot -> resolved node id ("" means no/cleared
	// highlight). Absent slot keys read back as "" (Go zero value), which is
	// indistinguishable from an explicitly-cleared slot — both are a no-op
	// for the viewer, so no separate "ok" tracking is needed.
	highlights map[int]string
}

// NewServer builds the initial graph from repoRoot and returns a ready Server.
// It fails fast (naming the path) if the root is missing, so a mistyped --root
// surfaces at startup rather than as an empty graph.
func NewServer(repoRoot string) (*Server, error) {
	if fi, err := os.Stat(repoRoot); err != nil || !fi.IsDir() {
		return nil, fmt.Errorf("akm-graph: notes root %q not found or not a directory: %w", repoRoot, err)
	}

	sub, err := fs.Sub(staticFS, "static")
	if err != nil {
		return nil, fmt.Errorf("akm-graph: embedded static fs: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{
		root:       repoRoot,
		ctx:        ctx,
		cancel:     cancel,
		static:     sub,
		backend:    resolveBackend(),
		hub:        NewHub(),
		highlights: make(map[int]string),
		// localhost-only tool — same no-auth stance as ft002; accept any origin.
		upgrader: websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }},
	}
	if err := s.Rebuild(ctx); err != nil {
		cancel()
		return nil, err
	}
	return s, nil
}

// Rebuild re-parses the notes tree and atomically swaps in the new graph.
func (s *Server) Rebuild(ctx context.Context) error {
	g, err := BuildGraphFromRoot(s.root)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.graph = g
	s.lastRebuild = time.Now()
	s.mu.Unlock()
	return nil
}

// Snapshot returns the current graph under a read lock (consistent copy of the
// slice headers; nodes/links are never mutated in place after a swap).
func (s *Server) Snapshot() Graph {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.graph
}

// Done exposes the server context's cancellation channel so callers (main's
// shutdown loop, tests) can block on graceful-stop.
func (s *Server) Done() <-chan struct{} { return s.ctx.Done() }

// WatchContext returns the server lifecycle context so the file watcher stops
// when the daemon shuts down (POST /api/stop / signal).
func (s *Server) WatchContext() context.Context { return s.ctx }

// Handler wires the HTTP mux. Each /api/* handler enforces its method and emits
// a 405 + Allow header on mismatch (ft002 parity).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/graph", s.handleGraph)
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/stop", s.handleStop)
	mux.HandleFunc("/api/open", s.handleOpen)
	mux.HandleFunc("/api/highlight", s.handleHighlight)
	mux.HandleFunc("/watch", s.handleWatch)
	fileServer := noCache(http.FileServer(http.FS(s.static)))
	mux.Handle("/", noCache(s.indexHandler(fileServer)))
	return mux
}

// indexHandler serves index.html with its <meta name="akm-backend"> content
// rewritten to the resolved daemon default ($AKM_GRAPH_BACKEND), so a fresh page
// load picks the right engine without a query param. All other paths fall through
// to the embedded file server. The ?backend= query param still overrides client-side.
func (s *Server) indexHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" && r.URL.Path != "/index.html" {
			next.ServeHTTP(w, r)
			return
		}
		raw, err := fs.ReadFile(s.static, "index.html")
		if err != nil {
			next.ServeHTTP(w, r) // fall back to the file server on any read error
			return
		}
		html := strings.Replace(
			string(raw),
			`<meta name="akm-backend" content="`+defaultBackend+`" />`,
			`<meta name="akm-backend" content="`+s.backend+`" />`,
			1,
		)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(html))
	})
}

// noCache stops the browser caching the viewer assets so a rebuilt daemon's
// updated index.html / app.js show on a normal refresh (no hard-reload needed).
func noCache(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
		h.ServeHTTP(w, r)
	})
}

func (s *Server) handleGraph(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	g := s.Snapshot()
	writeJSON(w, g)
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	s.mu.RLock()
	st := Status{
		PID:         os.Getpid(),
		Root:        s.root,
		Nodes:       len(s.graph.Nodes),
		Links:       len(s.graph.Links),
		LastRebuild: s.lastRebuild,
	}
	s.mu.RUnlock()
	writeJSON(w, st)
}

func (s *Server) handleStop(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"stopping":true}`))
	// Flush the response before cancelling so the client sees 200.
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	s.cancel()
}

// highlightMsg is the /watch envelope for a current-node highlight (sp011
// Task 1). It is discriminated from a raw Graph payload BY SHAPE — a
// "type":"highlight" key that a {nodes,links} graph frame never carries — so
// existing graph consumers parse unchanged (sp011 anti-pattern: no typed
// wrapper on the graph broadcast).
type highlightMsg struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Slot int    `json:"slot"`
}

// handleHighlight serves POST /api/highlight {"path": "...", "slot": N?} —
// the forward twin of handleOpen's id->path resolution (sp011 Task 1,
// mirroring the adr0007 discipline: the id is resolved server-side from the
// trusted in-process graph, never trusted from the caller). Localhost-only
// trust boundary — same no-auth stance as every other /api/* handler here.
//
// Resolution order:
//  1. decode the JSON body; malformed -> 400, never reaches graph lookup
//  2. reject a missing/empty path -> 400 (distinct from an unknown path,
//     which is a valid "clear" signal, not a caller error)
//  3. look up path against the current graph snapshot's node paths (a plain
//     string match — no filesystem access, so no traversal surface even for
//     a path containing ".." or an absolute escape); unknown/ghost/non-graph
//     path resolves to "" rather than an error (silent clear contract)
//  4. store the resolved id for the slot (last-write-wins under
//     highlightMu) and broadcast {type:"highlight", id, slot} over the
//     existing hub — always, even for an empty id, so viewers clear stale
//     emphasis
func (s *Server) handleHighlight(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}
	defer r.Body.Close()

	var body struct {
		Path string `json:"path"`
		Slot *int   `json:"slot"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request body", http.StatusBadRequest)
		return
	}
	if body.Path == "" {
		http.Error(w, "missing path", http.StatusBadRequest)
		return
	}

	slot := 0
	if body.Slot != nil {
		slot = *body.Slot
	}

	id := ""
	for _, n := range s.Snapshot().Nodes {
		if n.Path != "" && n.Path == body.Path {
			id = n.ID
			break
		}
	}

	s.setHighlight(slot, id)
	s.broadcastHighlight(id, slot)

	writeJSON(w, map[string]any{"id": id, "slot": slot})
}

// setHighlight stores id (possibly empty) as slot's current highlight.
// Concurrent POSTs to the same slot are last-write-wins under highlightMu
// (sp011 Task 1 edge case).
func (s *Server) setHighlight(slot int, id string) {
	s.highlightMu.Lock()
	s.highlights[slot] = id
	s.highlightMu.Unlock()
}

// getHighlight returns the stored id for slot ("" if never set or explicitly
// cleared — both read the same, which is correct: neither should render
// emphasis).
func (s *Server) getHighlight(slot int) string {
	s.highlightMu.Lock()
	defer s.highlightMu.Unlock()
	return s.highlights[slot]
}

// broadcastHighlight fans a highlight envelope out to every /watch client,
// regardless of which slot they're primed for — the viewer ignores messages
// for a slot that isn't its own (ft004 Task 2 scope). Marshal failure (should
// be unreachable for this fixed shape) is swallowed rather than panicking,
// matching broadcastGraph's no-panic contract.
func (s *Server) broadcastHighlight(id string, slot int) {
	b, err := json.Marshal(highlightMsg{Type: "highlight", ID: id, Slot: slot})
	if err != nil {
		return
	}
	s.hub.Broadcast(b)
}

// handleWatch upgrades to WebSocket, pushes the current graph immediately,
// then — for a connection carrying ?slot=N — primes the stored highlight for
// that slot right after the graph frame (sp011 Task 1: first zettel preview
// highlights once ready, priming order graph-then-highlight so consumers can
// rely on it). A connection with no ?slot= (standalone viewer) gets no
// highlight priming at all — same behavior as before this feature. Then
// streams every subsequent rebuild/highlight broadcast. A non-WebSocket
// request is rejected by the upgrader with a 400 (it never hangs). Only GET
// can carry an Upgrade header, so ServeMux + the upgrader together enforce
// method+protocol.
func (s *Server) handleWatch(w http.ResponseWriter, r *http.Request) {
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		// Upgrade already wrote the 4xx response.
		return
	}
	c := &wsClient{conn: conn, send: make(chan []byte, wsSendBuffer)}
	s.hub.Register(c)

	// Prime the new client with the current graph so it renders without waiting
	// for the next file change.
	if b, err := json.Marshal(s.Snapshot()); err == nil {
		select {
		case c.send <- b:
		default:
		}
	}

	// Slot-aware highlight priming: only when the query string names an
	// explicit slot (an embed's ?slot=N). A malformed slot value is treated
	// the same as absent — no priming, no error (this is a best-effort
	// convenience, not a contract the caller can violate its way into a 4xx).
	if slotStr := r.URL.Query().Get("slot"); slotStr != "" {
		if slot, err := strconv.Atoi(slotStr); err == nil {
			id := s.getHighlight(slot)
			if b, err := json.Marshal(highlightMsg{Type: "highlight", ID: id, Slot: slot}); err == nil {
				select {
				case c.send <- b:
				default:
				}
			}
		}
	}

	go s.writePump(c)
	s.readPump(c) // blocks until the client disconnects
}

// readPump drains inbound frames (control frames + any client chatter) purely to
// detect disconnect, then unregisters the client. Runs on the request goroutine.
func (s *Server) readPump(c *wsClient) {
	defer func() {
		s.hub.Unregister(c)
		_ = c.conn.Close()
	}()
	for {
		if _, _, err := c.conn.ReadMessage(); err != nil {
			return
		}
	}
}

// writePump serialises all writes to a single client's socket (gorilla requires
// one concurrent writer) and sends periodic pings. It exits when the hub closes
// c.send (client dropped) or a write fails.
func (s *Server) writePump(c *wsClient) {
	ticker := time.NewTicker(wsPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case msg, ok := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
			if !ok {
				_ = c.conn.WriteMessage(websocket.CloseMessage, nil)
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// broadcastGraph marshals the current snapshot and fans it out to all clients.
func (s *Server) broadcastGraph() {
	b, err := json.Marshal(s.Snapshot())
	if err != nil {
		return
	}
	s.hub.Broadcast(b)
}

// StartWatcher wires an fsnotify Watcher whose debounced onChange rebuilds the
// graph and broadcasts it. A rebuild error (e.g. root deleted) is logged and
// the last good graph keeps being served — no broadcast, no crash.
func (s *Server) StartWatcher(ctx context.Context, debounce time.Duration) error {
	wt, err := NewWatcher(s.root, debounce, func() {
		if err := s.Rebuild(ctx); err != nil {
			log.Printf("akm-graph: rebuild skipped: %v", err)
			return
		}
		s.broadcastGraph()
	})
	if err != nil {
		return err
	}
	s.watcher = wt
	go wt.Run(ctx)
	go func() {
		<-ctx.Done()
		_ = wt.Close()
	}()
	return nil
}

// requireMethod enforces want; on mismatch it writes 405 + Allow and returns
// false so the caller returns without touching the body.
func requireMethod(w http.ResponseWriter, r *http.Request, want string) bool {
	if r.Method == want {
		return true
	}
	w.Header().Set("Allow", want)
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	return false
}

// writeJSON marshals v as application/json. On marshal failure it emits a 500
// rather than panicking (sp006 plan — no panic in handlers).
func writeJSON(w http.ResponseWriter, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(b)
}
