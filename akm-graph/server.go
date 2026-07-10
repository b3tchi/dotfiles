package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"sync"
	"time"
)

// staticFS embeds the viewer assets so GET / and static paths serve from the
// binary regardless of the working directory (us006 AC5, ft004 offline-safe).
//
//go:embed static
var staticFS embed.FS

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

	static fs.FS
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
		root:   repoRoot,
		ctx:    ctx,
		cancel: cancel,
		static: sub,
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

// Handler wires the HTTP mux. Each /api/* handler enforces its method and emits
// a 405 + Allow header on mismatch (ft002 parity).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/graph", s.handleGraph)
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/stop", s.handleStop)
	mux.Handle("/", http.FileServer(http.FS(s.static)))
	return mux
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
