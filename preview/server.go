package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// Status is the GET /status payload: daemon health snapshot (ft002/ft004
// parity — ft005 api_surface).
type Status struct {
	PID       int       `json:"pid"`
	Root      string    `json:"root"`
	Port      string    `json:"port"`
	StartedAt time.Time `json:"started_at"`
}

// Server owns the preview-d lifecycle and HTTP surface. Task 1 wired the
// skeleton routes (/status, /stop); Task 2 added /file/<path>; Task 4 adds
// /preview<N> (the stateful live-shell + ws hub route family). /open and
// /watch land in later sp008 tasks.
type Server struct {
	root      string
	port      string
	startedAt time.Time

	ctx    context.Context
	cancel context.CancelFunc

	static   fs.FS
	slots    *SlotManager
	upgrader websocket.Upgrader
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

	sub, err := fs.Sub(staticFS, "static")
	if err != nil {
		return nil, fmt.Errorf("preview-d: embedded static fs: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	return &Server{
		root:      root,
		port:      port,
		startedAt: time.Now(),
		ctx:       ctx,
		cancel:    cancel,
		static:    sub,
		slots:     NewSlotManager(),
		// localhost-only tool — same no-auth stance as ft002/ft004; accept
		// any origin (akm-graph NewServer precedent).
		upgrader: websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }},
	}, nil
}

// Done exposes the server lifecycle context's cancellation channel so
// callers (main's shutdown loop, tests) can block on graceful stop.
func (s *Server) Done() <-chan struct{} { return s.ctx.Done() }

// Handler wires the HTTP mux. Task 1 seeded /status and /stop; Task 2 added
// /file/<path>; Task 4 adds /static/ (shell assets) and routes /preview<N>
// through previewRouter, since a bare "/preview1"-shaped path has no
// separator for net/http's ServeMux subtree matching. Task 6 adds /open
// (the reverse channel, proxy.go). /watch lands in a later sp008 task.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/status", s.handleStatus)
	mux.HandleFunc("/stop", s.handleStop)
	mux.HandleFunc("/file/", s.handleFile)
	mux.Handle("/static/", http.StripPrefix("/static/", noCache(http.FileServer(http.FS(s.static)))))

	// sp008 Task 6: POST /open is the reverse channel (webview -> nvim),
	// handled in proxy.go. Registered in its own block, deliberately away
	// from handleFile/previewRouter above, so this task's server.go edits
	// land in a different region than sibling tasks touching render.go /
	// handleFile — keeps a clean auto-merge.
	mux.HandleFunc("/open", s.handleOpen)

	// sp008 Task 7: GET /d2embed/<path> is the same-origin proxy target a
	// .d2 file's iframe embed points at (proxy.go's handleD2Embed) — kept in
	// its own block for the same clean-auto-merge reason as /open above.
	mux.HandleFunc("/d2embed/", s.handleD2Embed)

	// sp009 Task 1: POST /register is the per-slot nvim-address binding
	// route — an nvim instance registers its server addr against a slot
	// (allocated when omitted, or an explicit slot it already owns) so a
	// later task's /open routing can send the reverse-open request to the
	// nvim that owns the targeted slot. Own block for the same
	// clean-auto-merge reason as /open and /d2embed above.
	mux.HandleFunc("/register", s.handleRegister)

	return s.previewRouter(mux)
}

// noCache stops the browser caching the shell/app.js assets so a rebuilt
// daemon's updated static files show on a normal refresh (akm-graph
// noCache precedent).
func noCache(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
		h.ServeHTTP(w, r)
	})
}

// previewRouter intercepts any path shaped like /preview<N> before falling
// through to next for the other routes. Go 1.21's ServeMux has no
// path-variable support, and "/preview<N>" has no "/" separator for a
// subtree pattern, so the slot number is parsed here by hand. A path
// starting with "/preview" whose suffix does not parse as a non-negative
// integer is a 400 (sp008 Task 4 edge case: N non-numeric -> 400), not a
// fall-through to 404 — it is unambiguously a malformed preview-slot
// request, not some other unmatched route.
func (s *Server) previewRouter(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, ok, matched := parsePreviewSlot(r.URL.Path)
		if !matched {
			next.ServeHTTP(w, r)
			return
		}
		if !ok {
			http.Error(w, "bad preview slot", http.StatusBadRequest)
			return
		}
		s.handlePreview(n, w, r)
	})
}

// previewPrefix is the fixed lead-in for the /preview<N> route family.
const previewPrefix = "/preview"

// parsePreviewSlot reports whether path is shaped like /preview<N>
// (matched) and, if so, whether <N> parsed as a valid non-negative slot
// number (ok). matched=false means path is not a preview-route request at
// all and the caller should fall through to other routes.
func parsePreviewSlot(path string) (n int, ok bool, matched bool) {
	if !strings.HasPrefix(path, previewPrefix) {
		return 0, false, false
	}
	suffix := path[len(previewPrefix):]
	v, err := strconv.Atoi(suffix)
	if err != nil || v < 0 {
		return 0, false, true
	}
	return v, true, true
}

// handlePreview dispatches GET (shell HTML, or a websocket upgrade) and
// POST (set slot n's current path) for one /preview<N> slot (ft005
// api_surface /preview<N> + POST /preview<N>).
func (s *Server) handlePreview(n int, w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		if websocket.IsWebSocketUpgrade(r) {
			s.handlePreviewWS(n, w, r)
			return
		}
		s.handlePreviewShell(w, r)
	case http.MethodPost:
		s.handlePreviewSet(n, w, r)
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// handlePreviewShell serves the static shell page for a plain (non-ws) GET
// /preview<N>. The shell is slot-agnostic HTML/JS: it discovers which slot
// it belongs to client-side from window.location.pathname (sp008 Task 4
// success criteria: shell opens a websocket and loads the current
// /file/<path>).
func (s *Server) handlePreviewShell(w http.ResponseWriter, r *http.Request) {
	raw, err := fs.ReadFile(s.static, "shell.html")
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	_, _ = w.Write(raw)
}

// handlePreviewSet handles POST /preview<N> {"path": "..."}: it sets slot
// n's current path and broadcasts a redraw to every window currently
// connected to that slot (ft005 api_surface POST /preview<N>). A malformed
// body is a 400, never a 500 or panic (sp008-wide anti-pattern).
func (s *Server) handlePreviewSet(n int, w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	var body struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request body", http.StatusBadRequest)
		return
	}
	// Canonicalize to the root-relative form /file/<path> expects. nvim
	// sends absolute buffer paths (the wrapper forwards them verbatim);
	// stored verbatim they made every viewer iframe request
	// /file//home/... and 404 (dotfiles-hva). An absolute path outside
	// root can never be served — reject at ingestion instead of
	// broadcasting a guaranteed 404 to every window.
	p := body.Path
	if filepath.IsAbs(p) {
		absRoot, err := filepath.Abs(s.root)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		rel, err := filepath.Rel(filepath.Clean(absRoot), filepath.Clean(p))
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			http.Error(w, "path outside preview root", http.StatusBadRequest)
			return
		}
		p = rel
	}
	s.slots.SetPath(n, p)
	writeJSON(w, map[string]any{"slot": n, "path": p})
}

// handlePreviewWS upgrades GET /preview<N> to a websocket and registers the
// connection against slot n's Hub only — the slot isolation that lets
// distinct N values maintain independent client sets (sp008 Task 4 success
// criteria). A newly-connected window is primed with the slot's buffered
// current path (if any) so a POST that landed before this window connected
// is still applied immediately (sp008 Task 4 edge case).
func (s *Server) handlePreviewWS(n int, w http.ResponseWriter, r *http.Request) {
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		// Upgrade already wrote the 4xx response.
		return
	}
	c := &wsClient{conn: conn, send: make(chan []byte, wsSendBuffer)}
	hub := s.slots.Hub(n)
	hub.Register(c)

	if path := s.slots.CurrentPath(n); path != "" {
		select {
		case c.send <- redrawMessage(path):
		default:
		}
	}

	go s.writePreviewPump(c)
	s.readPreviewPump(hub, c) // blocks until the client disconnects
}

// readPreviewPump drains inbound frames (control frames + any client
// chatter) purely to detect disconnect, then unregisters the client from
// its slot's hub. Runs on the request goroutine (ported akm-graph
// readPump pattern).
func (s *Server) readPreviewPump(hub *Hub, c *wsClient) {
	defer func() {
		hub.Unregister(c)
		_ = c.conn.Close()
	}()
	for {
		if _, _, err := c.conn.ReadMessage(); err != nil {
			return
		}
	}
}

// writePreviewPump serialises all writes to a single client's socket
// (gorilla requires one concurrent writer) and sends periodic pings. It
// exits when the hub closes c.send (client dropped — bounded buffer, sp008
// Task 4 edge case: slow client dropped without blocking others) or a
// write fails (ported akm-graph writePump pattern).
func (s *Server) writePreviewPump(c *wsClient) {
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

// handleFile serves GET /file/<path>: the stateless render primitive
// (ft005 api_surface). It is the primary attack surface of preview-d — it
// serves local disk content to a webview — so the requested path is
// jailed through resolveInRoot (path.go) BEFORE any content is read.
// resolveInRoot's two error cases map to distinct, honest statuses: an
// escape attempt (ErrPathEscape) is a client error (400), a path that
// simply doesn't exist under root is a 404 — never a 500 for either (sp008
// Task 2 anti-pattern: no raw webview input reaches disk I/O unvalidated).
func (s *Server) handleFile(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	reqPath := strings.TrimPrefix(r.URL.Path, "/file/")
	resolved, err := resolveInRoot(s.root, reqPath)
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
	// sp008 Task 8 (DEVIATION flagged per task instructions): ?live selects
	// the video renderer's live tier — an HTML wrapper embedding a <video>
	// element that plays the file via its own ?full byte-stream (ft005
	// api_surface video row). This is special-cased here, before the
	// renderFile dispatch below, rather than threaded through renderFile's
	// existing single "full" bool: reusing one flag for both "return the
	// live wrapper" and "return raw bytes" would make the wrapper's own
	// <video src> re-trigger the wrapper instead of the byte stream it
	// needs to actually play. It also needs reqPath (the original request
	// path) to build that src, which renderFile never receives — only the
	// resolved filesystem path.
	if isVideoExt(resolved) && r.URL.Query().Has("live") {
		renderVideoLive(w, reqPath)
		return
	}
	// sp008 Task 7 (DEVIATION flagged per task instructions, same pattern as
	// Task 8's ?live special-case immediately above): a .d2 file or an akm
	// zettel (docs/notes/**.md) resolves to an iframe embed of ft002/ft004
	// respectively, rather than the plain code/markdown render the switch
	// below would otherwise give it. Special-cased here, before the
	// renderFile dispatch, because renderD2Embed needs reqPath (to build the
	// /d2embed/<reqPath> proxy target) and renderAkmEmbed needs s.root (to
	// spawn akm-graph-d with the matching --root) — neither is available
	// inside renderFile's signature (path.go/render.go's dispatcher only
	// ever receives the resolved filesystem path), the exact same
	// constraint that put the ?live case here instead of inside renderFile.
	if isD2Ext(resolved) {
		renderD2Embed(w, reqPath)
		return
	}
	if isAkmZettel(s.root, resolved) {
		renderAkmEmbed(w, s.root, parseSlotQuery(r))
		return
	}
	// sp008 Task 3: ?full selects the full-res tier (image row of the ft005
	// api_surface); its presence, not its value, is what matters (e.g.
	// "?full" or "?full=1" both count). Minimal, necessary one-line
	// passthrough — the query lives only on r, which render.go's dispatch
	// has no other way to see.
	renderFile(w, resolved, r.URL.Query().Has("full"))
}

// parseSlotQuery reads the optional ?slot=N query parameter off r (sp009
// Task 6: threading the /preview<N> window's slot down to renderAkmEmbed's
// iframe src). A missing or non-numeric value returns nil — slot is a
// routing hint carried through the URL, never grounds for a 400 (sp009 Task
// 6 edge case: non-numeric ?slot -> ignored, not rejected).
func parseSlotQuery(r *http.Request) *int {
	raw := r.URL.Query().Get("slot")
	if raw == "" {
		return nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return nil
	}
	return &n
}

// handleRegister handles POST /register {"nvim": "...", "slot": N?}: an
// nvim instance registers its server address against a slot so a later
// task's /open routing can find the nvim that owns the targeted slot
// (sp009 Task 1 success criteria). When slot is omitted, a free slot is
// allocated (mutex-guarded via SlotManager.AllocateSlot, so concurrent
// no-slot registers never collide) and returned as {"slot": N}; when slot
// is given explicitly, that slot's addr is (re-)bound — re-registering an
// already-bound slot updates the addr rather than allocating a new one
// (sp009 Task 1 edge case: last-wins). An empty "nvim" address is rejected
// with 400 before anything is bound (sp009 Task 1 edge case), and a
// malformed JSON body is a 400 as well (sp008-wide anti-pattern: no panic,
// no 500 for a bad client body).
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}
	defer r.Body.Close()
	var body struct {
		Nvim string `json:"nvim"`
		Slot *int   `json:"slot"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request body", http.StatusBadRequest)
		return
	}
	if body.Nvim == "" {
		http.Error(w, "nvim address required", http.StatusBadRequest)
		return
	}

	n := 0
	if body.Slot != nil {
		n = *body.Slot
	} else {
		n = s.slots.AllocateSlot()
	}
	s.slots.SetNvimAddr(n, body.Nvim)
	writeJSON(w, map[string]any{"slot": n})
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
