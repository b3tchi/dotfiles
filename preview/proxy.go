package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"time"
)

// openTimeout bounds the nvim --remote subprocess so a dead/unreachable
// nvim server can't stall the request goroutine indefinitely (sp008 Task 6
// edge case: "nvim server dead -> error, not a hang"; sp008 plan
// anti-pattern: never block a request goroutine unbounded).
const openTimeout = 3 * time.Second

// handleOpen serves POST /open {"path": "..."} — the reverse channel (ft005
// api_surface /open, sp008 Task 6): the webview asks the daemon to open a
// file back in the running nvim instance via
// "nvim --server $NVIM --remote <path>".
//
// Validation runs strictly before any subprocess exec, in this order:
//  1. decode the JSON body (malformed -> 400, never reaches the next step)
//  2. resolveInRoot (path.go, sp008 Task 2) — the path must exist AND
//     resolve inside the allowed root; an escape is 400, a missing path is
//  404. This is the sp008 Task 6 anti-pattern gate: no raw webview input
//     reaches a subprocess unvalidated.
//  3. $NVIM must be set — with no running nvim server there is nothing to
//     drive, and a missing target must be a distinct, visible error (424
//     Failed Dependency), not a silent no-op (sp008 Task 6 success
//     criteria).
//
// Only once all three hold does exec.CommandContext run, and it runs with
// an explicit arg vector ("nvim", "--server", <addr>, "--remote", <path>)
// under a bounded context — never a shell string, never unbounded (sp008
// Task 6 edge cases: path with spaces/special chars passed safely; nvim
// server dead -> error not hang).
func (s *Server) handleOpen(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}
	defer r.Body.Close()

	var body struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request body", http.StatusBadRequest)
		return
	}

	resolved, err := resolveInRoot(s.root, body.Path)
	if err != nil {
		switch {
		case errors.Is(err, ErrPathEscape):
			http.Error(w, "bad path", http.StatusBadRequest)
		case errors.Is(err, os.ErrNotExist):
			http.Error(w, "not found", http.StatusNotFound)
		default:
			http.Error(w, "internal error", http.StatusInternalServerError)
		}
		return
	}

	nvimServer := os.Getenv("NVIM")
	if nvimServer == "" {
		http.Error(w, "no running nvim server ($NVIM unset)", http.StatusFailedDependency)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), openTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "nvim", "--server", nvimServer, "--remote", resolved)
	if err := cmd.Run(); err != nil {
		http.Error(w, "failed to open in nvim: "+err.Error(), http.StatusFailedDependency)
		return
	}

	writeJSON(w, map[string]any{"opened": resolved})
}
