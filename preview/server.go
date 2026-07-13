package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"
)

// Status is the GET /status payload: daemon health snapshot (ft002/ft004
// parity — ft005 api_surface).
type Status struct {
	PID       int       `json:"pid"`
	Root      string    `json:"root"`
	Port      string    `json:"port"`
	StartedAt time.Time `json:"started_at"`
}

// Server owns the preview-d lifecycle and HTTP surface. Task 1 wires only
// the skeleton routes (/status, /stop); the render + session routes
// (/file/<path>, /preview<N>, /open, /watch) land in later sp008 tasks.
type Server struct {
	root      string
	port      string
	startedAt time.Time

	ctx    context.Context
	cancel context.CancelFunc
}

// NewServer validates root and returns a ready Server. It fails fast,
// naming the path, if root is missing or not a directory — a mistyped
// -root surfaces at startup rather than an empty serve (sp008 Task 1 edge
// case).
func NewServer(root, port string) (*Server, error) {
	fi, err := os.Stat(root)
	if err != nil || !fi.IsDir() {
		return nil, fmt.Errorf("preview-d: root %q not found or not a directory: %w", root, err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	return &Server{
		root:      root,
		port:      port,
		startedAt: time.Now(),
		ctx:       ctx,
		cancel:    cancel,
	}, nil
}

// Done exposes the server lifecycle context's cancellation channel so
// callers (main's shutdown loop, tests) can block on graceful stop.
func (s *Server) Done() <-chan struct{} { return s.ctx.Done() }

// Handler wires the HTTP mux. Task 1 seeds /status and /stop; /file/<path>,
// /preview<N>, /open, /watch land in later sp008 tasks.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/status", s.handleStatus)
	mux.HandleFunc("/stop", s.handleStop)
	return mux
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	st := Status{
		PID:       os.Getpid(),
		Root:      s.root,
		Port:      s.port,
		StartedAt: s.startedAt,
	}
	writeJSON(w, st)
}

// handleStop cancels the server context and returns 200. It is idempotent:
// context.CancelFunc is safe to call more than once, so a second POST
// /stop after the context is already cancelled still returns 200 rather
// than erroring (sp008 Task 1 edge case: double stop).
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

// requireMethod enforces want; on mismatch it writes 405 + Allow and
// returns false so the caller returns without touching the body (ft002
// method-parity).
func requireMethod(w http.ResponseWriter, r *http.Request, want string) bool {
	if r.Method == want {
		return true
	}
	w.Header().Set("Allow", want)
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	return false
}

// writeJSON marshals v as application/json. On marshal failure it emits a
// 500 rather than panicking (sp008 plan anti-pattern: no panic in
// handlers).
func writeJSON(w http.ResponseWriter, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(b)
}
