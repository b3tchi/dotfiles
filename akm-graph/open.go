package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"
)

// previewOpenTimeout bounds the outbound POST to preview-d's /open endpoint
// so an unreachable or hung preview-d can't stall the akm-graph request
// goroutine indefinitely (sp009 Task 5 edge case: "preview-d unreachable ->
// timeout error, not a hang"). Mirrors preview/proxy.go's daemonHealthTimeout
// idiom. A package-level var (not a const) so tests can shorten it instead of
// paying the full production budget (same test seam as proxy.go's
// daemonSpawnWait/daemonSpawnPoll).
var previewOpenTimeout = 3 * time.Second

// previewPort resolves preview-d's port from $PREVIEW_PORT, defaulting to
// 4200 — matching preview/main.go's resolvePort default (sp008 Task 1 edge
// case: $PREVIEW_PORT unset -> 4200).
func previewPort() string {
	if p := os.Getenv("PREVIEW_PORT"); p != "" {
		return p
	}
	return "4200"
}

// handleOpen serves POST /api/open {"id": "...", "slot": N?} — the
// reverse-open keystone (sp009 Task 5): the akm-graph viewer asks the daemon
// to resolve a clicked node id back to its source file and forward that open
// request to preview-d, which routes it to the specific nvim owning that
// slot (sp009 Task 2) or, absent a slot, preview-d's global $NVIM fallback
// (sp008 Task 6, back-compat for a standalone akm-graph with no ?slot).
//
// Resolution runs strictly in this order:
//  1. decode the JSON body (malformed -> 400, never reaches graph lookup)
//  2. look up id in the current graph snapshot; a missing id OR a ghost node
//     (empty Path — T4's contract: ghost nodes have no backing Note) -> 404,
//     no preview-d call is ever attempted (sp009 Task 5 edge case:
//     unknown/ghost id -> no-op, no downstream call)
//  3. POST {path, slot?} to preview-d's /open, via a scoped
//     http.Client{Timeout} so an unreachable/hung preview-d surfaces as a
//     bounded error rather than hanging the request goroutine (sp009 Task 5
//     edge case: preview-d down -> timeout error, not a hang)
func (s *Server) handleOpen(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}
	defer r.Body.Close()

	var body struct {
		ID   string `json:"id"`
		Slot *int   `json:"slot"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request body", http.StatusBadRequest)
		return
	}

	path := ""
	found := false
	for _, n := range s.Snapshot().Nodes {
		if n.ID == body.ID {
			found = n.Path != "" // ghost nodes carry an empty Path (T4 contract)
			path = n.Path
			break
		}
	}
	if !found {
		http.Error(w, "unknown node", http.StatusNotFound)
		return
	}

	if err := postPreviewOpen(r.Context(), path, body.Slot); err != nil {
		http.Error(w, "preview-d open failed: "+err.Error(), http.StatusFailedDependency)
		return
	}

	writeJSON(w, map[string]any{"opened": path})
}

// postPreviewOpen POSTs {"path": path, "slot": slot?} as JSON to preview-d's
// /open endpoint at 127.0.0.1:$PREVIEW_PORT (default 4200), bounded by
// previewOpenTimeout end to end (request build + response). slot is omitted
// from the JSON body entirely when nil — a raw shell string is never built;
// the body is always JSON-encoded so a path with spaces/Unicode round-trips
// safely (sp009 Task 5 edge case).
func postPreviewOpen(ctx context.Context, path string, slot *int) error {
	reqBody := struct {
		Path string `json:"path"`
		Slot *int   `json:"slot,omitempty"`
	}{Path: path, Slot: slot}

	b, err := json.Marshal(reqBody)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(ctx, previewOpenTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"http://127.0.0.1:"+previewPort()+"/open", bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	client := http.Client{Timeout: previewOpenTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("preview-d /open: status %d", resp.StatusCode)
	}
	return nil
}
