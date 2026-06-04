package main

import (
	"encoding/json"
	"net/http"
	"path/filepath"
	"sort"
	"strings"
)

// APIHandler serves all /api/* endpoints.
// It requires read access to the Registry (for resolve) and the ChildManager
// (for status/reload/restart/stop), plus the router port to build resolve URLs.
type APIHandler struct {
	cm         *ChildManager
	reg        Registry // local-only registry: name → abs path (ssh excluded)
	routerPort string   // used to build URLs in /api/resolve
}

// NewAPIHandler creates an APIHandler.
func NewAPIHandler(cm *ChildManager, reg Registry, routerPort string) *APIHandler {
	return &APIHandler{cm: cm, reg: reg, routerPort: routerPort}
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
	if absPath == "" {
		writeJSONErr(w, http.StatusBadRequest, "missing required query parameter: path")
		return
	}
	if !filepath.IsAbs(absPath) {
		writeJSONErr(w, http.StatusBadRequest, "path must be absolute")
		return
	}

	// Canonicalize BEFORE prefix-matching. Without this, a ..-escaping path
	// (e.g. /home/user/proj/../../../etc/passwd.d2) would raw-prefix-match its
	// origin project and 200 with the wrong project — but filepath.Clean
	// resolves it to /etc/passwd.d2, which is outside every project → 404
	// (ft002:38). The IsAbs check stays above so a relative path still 400s
	// (Clean would otherwise mask "../x" as a rooted-looking path); an
	// in-project ".." that cleans back inside still matches and 200s.
	absPath = filepath.Clean(absPath)

	// Longest-prefix match: find the project whose path is the longest
	// prefix of absPath.
	bestProject := ""
	bestPath := ""
	for projectName, projectPath := range h.reg {
		// Ensure the project path ends with "/" for prefix matching
		// to avoid /foo matching /foobar.
		prefix := projectPath
		if !strings.HasSuffix(prefix, "/") {
			prefix += "/"
		}
		if !strings.HasPrefix(absPath, prefix) {
			continue
		}
		if len(projectPath) > len(bestPath) {
			bestProject = projectName
			bestPath = projectPath
		}
	}

	if bestProject == "" {
		writeJSONErr(w, http.StatusNotFound, "path is outside all registered local projects")
		return
	}

	// Derive the file basename (flat routing matches what registry.go uses).
	basename := filepath.Base(absPath)
	file := basename

	// Build the routed URL: http://127.0.0.1:<port>/<project>/<file>
	url := "http://127.0.0.1:" + h.routerPort + "/" + bestProject + "/" + file

	writeJSON(w, http.StatusOK, resolveResponse{
		Project: bestProject,
		File:    file,
		URL:     url,
	})
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
