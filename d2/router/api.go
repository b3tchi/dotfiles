package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// APIHandler serves all /api/* endpoints.
// It requires read access to the Registry (for resolve) and the ChildManager
// (for status/reload/restart/stop), plus the router port to build resolve URLs.
type APIHandler struct {
	cm          *ChildManager
	reg         Registry // local-only registry: name → abs path (ssh excluded)
	routerPort  string   // used to build URLs in /api/resolve
	svgCacheDir string   // mirrors cfg.SvgCacheDir; used to recompute a child's
	// deterministic svg path for the last-good fallback when Ensure itself
	// fails (sp022 Task 1 edge case).
}

// NewAPIHandler creates an APIHandler.
func NewAPIHandler(cm *ChildManager, reg Registry, routerPort, svgCacheDir string) *APIHandler {
	return &APIHandler{cm: cm, reg: reg, routerPort: routerPort, svgCacheDir: svgCacheDir}
}

// ServeHTTP dispatches /api/* sub-paths.
// Unknown paths → 404 JSON; wrong method → 405 with Allow header.
func (h *APIHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Strip /api prefix; path.Clean is not needed — we do exact matches.
	sub := strings.TrimPrefix(r.URL.Path, "/api")
	// sub is either "", "/status", "/reload/...", "/restart/...", "/stop/...", "/stop-all", "/resolve"

	switch {
	case sub == "/status" || sub == "/status/":
		h.handleStatus(w, r)

	case sub == "/stop-all" || sub == "/stop-all/":
		h.handleStopAll(w, r)

	case sub == "/resolve" || sub == "/resolve/":
		h.handleResolve(w, r)

	case sub == "/svg" || sub == "/svg/":
		h.handleSvg(w, r)

	case strings.HasPrefix(sub, "/reload/"):
		key := strings.TrimPrefix(sub, "/reload/")
		h.handleReload(w, r, key)

	case strings.HasPrefix(sub, "/restart/"):
		key := strings.TrimPrefix(sub, "/restart/")
		h.handleRestart(w, r, key)

	case strings.HasPrefix(sub, "/stop/"):
		key := strings.TrimPrefix(sub, "/stop/")
		h.handleStop(w, r, key)

	default:
		writeJSONErr(w, http.StatusNotFound, "unknown API endpoint")
	}
}

// ── /api/status ───────────────────────────────────────────────────────────────

// statusEntry is the JSON shape for one child in /api/status output.
// Fields match ft002 api_surface exactly.
type statusEntry struct {
	Project     string  `json:"project"`
	File        string  `json:"file"`
	Port        int     `json:"port"`
	PID         int     `json:"pid"`
	Clients     int32   `json:"clients"`
	LastCompile string  `json:"lastCompile"`
	LastError   *string `json:"lastError"`
}

// handleStatus handles GET /api/status.
// Returns a JSON array of all running children sorted by key.
func (h *APIHandler) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		writeJSONErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	snap := h.cm.Snapshot()

	// Deterministic output order.
	keys := make([]string, 0, len(snap))
	for k := range snap {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	entries := make([]statusEntry, 0, len(snap))
	for _, k := range keys {
		ch := snap[k]
		project, file := splitProjectFile(k)
		var errStr *string
		if ch.LastError != nil {
			s := ch.LastError.Error()
			errStr = &s
		}
		entries = append(entries, statusEntry{
			Project:     project,
			File:        file,
			Port:        ch.Port,
			PID:         ch.PID,
			Clients:     ch.Clients,
			LastCompile: ch.LastActive.UTC().Format("2006-01-02T15:04:05Z07:00"),
			LastError:   errStr,
		})
	}

	writeJSON(w, http.StatusOK, entries)
}

// ── /api/reload|restart|stop ─────────────────────────────────────────────────

func (h *APIHandler) handleReload(w http.ResponseWriter, r *http.Request, key string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeJSONErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if key == "" {
		writeJSONErr(w, http.StatusBadRequest, "missing project/file in path")
		return
	}
	if err := h.cm.Reload(key); err != nil {
		// Reload returns "not running" error when child absent — map to 404.
		if strings.Contains(err.Error(), "not running") {
			writeJSONErr(w, http.StatusNotFound, err.Error())
		} else {
			writeJSONErr(w, http.StatusInternalServerError, err.Error())
		}
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "reloaded", "key": key})
}

func (h *APIHandler) handleRestart(w http.ResponseWriter, r *http.Request, key string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeJSONErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if key == "" {
		writeJSONErr(w, http.StatusBadRequest, "missing project/file in path")
		return
	}
	if err := h.cm.Restart(key); err != nil {
		if strings.Contains(err.Error(), "not running") {
			writeJSONErr(w, http.StatusNotFound, err.Error())
		} else {
			writeJSONErr(w, http.StatusInternalServerError, err.Error())
		}
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "restarted", "key": key})
}

func (h *APIHandler) handleStop(w http.ResponseWriter, r *http.Request, key string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeJSONErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if key == "" {
		writeJSONErr(w, http.StatusBadRequest, "missing project/file in path")
		return
	}
	if err := h.cm.Stop(key); err != nil {
		if strings.Contains(err.Error(), "not running") {
			writeJSONErr(w, http.StatusNotFound, err.Error())
		} else {
			writeJSONErr(w, http.StatusInternalServerError, err.Error())
		}
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped", "key": key})
}

// ── /api/stop-all ────────────────────────────────────────────────────────────

func (h *APIHandler) handleStopAll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeJSONErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	h.cm.StopAll()
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopped-all"})
}

// ── /api/resolve ─────────────────────────────────────────────────────────────

// resolveResponse is the JSON response for a successful /api/resolve call.
type resolveResponse struct {
	Project string `json:"project"`
	File    string `json:"file"`
	URL     string `json:"url"`
}

// handleResolve handles GET /api/resolve?path=<abs>.
// Maps an absolute file path to its routed URL via longest-prefix match
// against the registry. Returns:
//   - 400 if path is relative (does not start with "/")
//   - 404 if path is outside all local projects
//   - 200 + {project, file, url} on match
func (h *APIHandler) handleResolve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		writeJSONErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	absPath := r.URL.Query().Get("path")
	project, canonPath, err := resolveAgainstRegistry(h.reg, absPath)
	if err != nil {
		writeRegistryErr(w, err)
		return
	}

	// Derive the file basename (flat routing matches what registry.go uses).
	file := filepath.Base(canonPath)

	// Build the routed URL: http://127.0.0.1:<port>/<project>/<file>
	url := "http://127.0.0.1:" + h.routerPort + "/" + project + "/" + file

	writeJSON(w, http.StatusOK, resolveResponse{
		Project: project,
		File:    file,
		URL:     url,
	})
}

// errPathMissing / errPathRelative / errOutsideRegistry are the sentinel
// errors resolveAgainstRegistry returns, so both /api/resolve and /api/svg
// map them to the same status codes (ft002 api_surface parity, sp022 Task 1).
var (
	errPathMissing     = errors.New("missing required query parameter: path")
	errPathRelative    = errors.New("path must be absolute")
	errOutsideRegistry = errors.New("path is outside all registered local projects")
)

// resolveAgainstRegistry canonicalizes absPath and finds its longest-prefix
// registry match. Shared by /api/resolve and /api/svg so both keep identical
// 400 (missing/relative) / 404 (outside registry) semantics.
func resolveAgainstRegistry(reg Registry, absPath string) (project, canonPath string, err error) {
	if absPath == "" {
		return "", "", errPathMissing
	}
	if !filepath.IsAbs(absPath) {
		return "", "", errPathRelative
	}

	// Canonicalize BEFORE prefix-matching. Without this, a ..-escaping path
	// (e.g. /home/user/proj/../../../etc/passwd.d2) would raw-prefix-match its
	// origin project and 200 with the wrong project — but filepath.Clean
	// resolves it to /etc/passwd.d2, which is outside every project → 404
	// (ft002:38). The IsAbs check stays above so a relative path still 400s
	// (Clean would otherwise mask "../x" as a rooted-looking path); an
	// in-project ".." that cleans back inside still matches and 200s.
	canonPath = filepath.Clean(absPath)

	// Longest-prefix match: find the project whose path is the longest
	// prefix of canonPath.
	bestProject := ""
	bestPath := ""
	for projectName, projectPath := range reg {
		// Ensure the project path ends with "/" for prefix matching
		// to avoid /foo matching /foobar.
		prefix := projectPath
		if !strings.HasSuffix(prefix, "/") {
			prefix += "/"
		}
		if !strings.HasPrefix(canonPath, prefix) {
			continue
		}
		if len(projectPath) > len(bestPath) {
			bestProject = projectName
			bestPath = projectPath
		}
	}

	if bestProject == "" {
		return "", "", errOutsideRegistry
	}
	return bestProject, canonPath, nil
}

// writeRegistryErr maps a resolveAgainstRegistry error to its HTTP status.
func writeRegistryErr(w http.ResponseWriter, err error) {
	if errors.Is(err, errOutsideRegistry) {
		writeJSONErr(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSONErr(w, http.StatusBadRequest, err.Error())
}

// ── /api/svg ─────────────────────────────────────────────────────────────

// svgPollInterval / svgPollDeadline bound the wait for a lazily-spawned
// child's first compile to land (edge case: "first hit races the initial
// compile" — bounded retry before 200, 503 after the deadline, never a
// hang). Vars so tests can shrink them (mirrors rewalkDebounce in proxy.go).
var (
	svgPollInterval = 20 * time.Millisecond
	svgPollDeadline = 3 * time.Second
)

// handleSvg handles GET /api/svg?path=<abs>.
//
// Mirrors /api/resolve's canonicalization + registry match (400 on missing
// or relative path, 404 outside the registry), then lazy-spawns the child
// (Ensure) and serves the compiled svg bytes from its explicit output path
// (children.go spawnLocked / svgOutputPath — dotfiles-eq8's fix). The output
// path is deterministic from (project, basename), so it is recomputed
// independent of any live child: a crash+respawn or a compile error still
// resolve to the same file, which is how the "serve the last good svg"
// edge case falls out for free rather than needing separate tracking.
func (h *APIHandler) handleSvg(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		writeJSONErr(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	absPath := r.URL.Query().Get("path")
	project, canonPath, err := resolveAgainstRegistry(h.reg, absPath)
	if err != nil {
		writeRegistryErr(w, err)
		return
	}

	basename := filepath.Base(canonPath)
	key := project + "/" + basename

	// Independent of Ensure's outcome: the deterministic path a prior good
	// compile (if any) would have landed at.
	expectedSVGPath, pathErr := svgOutputPath(h.svgCacheDir, project, canonPath)

	child, ensureErr := h.cm.Ensure(key, canonPath)
	if ensureErr != nil {
		// Spawn/respawn failed. A last-good svg from before the failure may
		// still be on disk (deterministic path) — serve it if so, per the
		// "d2 compile error → serve the last good svg if one exists" edge
		// case; otherwise report why the child is unavailable.
		if pathErr == nil {
			if data, readErr := os.ReadFile(expectedSVGPath); readErr == nil && len(data) > 0 {
				writeSVG(w, data)
				return
			}
		}
		writeJSONErr(w, http.StatusServiceUnavailable, fmt.Sprintf("child unavailable: %v", ensureErr))
		return
	}

	data, svgErr := waitForSVG(child.SVGPath, svgPollInterval, svgPollDeadline)
	if svgErr != nil {
		msg := svgErr.Error()
		if snap, ok := h.cm.Snapshot()[key]; ok && snap.LastError != nil {
			msg = snap.LastError.Error()
		}
		writeJSONErr(w, http.StatusServiceUnavailable, msg)
		return
	}

	writeSVG(w, data)
}

// writeSVG writes data with a 200 and Content-Type: image/svg+xml.
func writeSVG(w http.ResponseWriter, data []byte) {
	w.Header().Set("Content-Type", "image/svg+xml")
	w.WriteHeader(http.StatusOK)
	w.Write(data) //nolint:errcheck
}

// waitForSVG polls path until it exists with non-zero content, or deadline
// elapses. A pre-existing file with bytes (e.g. from a prior successful
// compile) returns immediately on the first check — this is what makes the
// "serve the last good svg" edge case fall out of a plain re-read rather
// than needing separate freshness tracking.
func waitForSVG(path string, interval, deadline time.Duration) ([]byte, error) {
	end := time.Now().Add(deadline)
	var lastErr error
	for {
		data, err := os.ReadFile(path)
		if err == nil && len(data) > 0 {
			return data, nil
		}
		if err != nil {
			lastErr = err
		} else {
			lastErr = fmt.Errorf("svg at %s is empty", path)
		}
		if time.Now().After(end) {
			return nil, fmt.Errorf("svg not ready after %s: %w", deadline, lastErr)
		}
		time.Sleep(interval)
	}
}

// ── helpers ───────────────────────────────────────────────────────────────────

// splitProjectFile splits a key of the form "project/file" into its two parts.
// Returns ("", key) if the key has no "/".
func splitProjectFile(key string) (project, file string) {
	idx := strings.IndexByte(key, '/')
	if idx < 0 {
		return "", key
	}
	return key[:idx], key[idx+1:]
}

// writeJSON writes v as JSON with the given HTTP status code.
func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}
