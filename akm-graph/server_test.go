package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

// newTestServer wires a Server against the crafted fixture tree so handler
// tests exercise the same graph the golden-file test asserts on.
func newTestServer(t *testing.T) *Server {
	t.Helper()
	root := filepath.Join("fixtures")
	srv, err := NewServer(root)
	if err != nil {
		t.Fatalf("NewServer(%q): %v", root, err)
	}
	return srv
}

// TestServeIndex proves GET / serves the embedded viewer regardless of cwd —
// the go:embed content, not a filesystem read of static/.
func TestServeIndex(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /: status %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Errorf("GET / content-type %q, want text/html", ct)
	}
	if !strings.Contains(rec.Body.String(), "<title>") {
		t.Errorf("GET / body missing <title>")
	}
}

// TestServeStaticAsset proves the embedded app.js is reachable so the viewer
// page's <script src> resolves.
func TestServeStaticAsset(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/app.js", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /app.js: status %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Errorf("GET /app.js content-type %q, want javascript", ct)
	}
}

// TestEmbedViewerAssetsOnly proves the daemon binary embeds only the viewer
// assets (index.html, app.js, cosmos-bundle.js) and not the smoke-test files
// (smoke.sh, smoke-tooltip.html, graph.json), which are served on-disk by
// smoke.sh's own http server (regression for dotfiles-blm).
func TestEmbedViewerAssetsOnly(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()

	served := []string{"/", "/app.js", "/cosmos-bundle.js", "/force-graph-bundle.js"}
	for _, p := range served {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("GET %s: status %d, want 200 (viewer asset must be embedded)", p, rec.Code)
		}
	}

	notEmbedded := []string{"/smoke.sh", "/smoke-tooltip.html", "/graph.json"}
	for _, p := range notEmbedded {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		if rec.Code != http.StatusNotFound {
			t.Errorf("GET %s: status %d, want 404 (test file must NOT be embedded)", p, rec.Code)
		}
	}
}

// TestBackendMetaDefault proves GET / serves the force-graph default in the
// <meta name="akm-backend"> tag when $AKM_GRAPH_BACKEND is unset.
func TestBackendMetaDefault(t *testing.T) {
	t.Setenv("AKM_GRAPH_BACKEND", "")
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if !strings.Contains(rec.Body.String(), `name="akm-backend" content="force-graph"`) {
		t.Errorf("GET / default backend meta missing force-graph; body:\n%s", rec.Body.String())
	}
}

// TestBackendMetaEnv proves $AKM_GRAPH_BACKEND=cosmos rewrites the served meta
// tag so a fresh page load selects the WebGL backend without a query param.
func TestBackendMetaEnv(t *testing.T) {
	t.Setenv("AKM_GRAPH_BACKEND", "cosmos")
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	body := rec.Body.String()
	if !strings.Contains(body, `name="akm-backend" content="cosmos"`) {
		t.Errorf("GET / with AKM_GRAPH_BACKEND=cosmos: meta not rewritten to cosmos; body:\n%s", body)
	}
	if strings.Contains(body, `content="force-graph"`) {
		t.Errorf("GET / still advertises force-graph after cosmos override")
	}
}

// TestAPIGraph proves GET /api/graph returns the ft004-shape JSON built from
// the fixture root — same graph as the golden file (spot-checked by node count).
func TestAPIGraph(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/graph", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/graph: status %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Errorf("content-type %q, want application/json", ct)
	}
	var g Graph
	if err := json.Unmarshal(rec.Body.Bytes(), &g); err != nil {
		t.Fatalf("unmarshal /api/graph: %v", err)
	}
	// The fixture golden has 8 nodes (see graph_test golden); assert non-empty
	// and that a known fixture node is present.
	if len(g.Nodes) == 0 {
		t.Fatalf("graph has no nodes")
	}
	found := false
	for _, n := range g.Nodes {
		if n.ID == "us001" {
			found = true
		}
	}
	if !found {
		t.Errorf("graph missing fixture node us001; nodes=%d", len(g.Nodes))
	}
}

// TestAPIStatus proves GET /api/status reports pid, root, counts, last-rebuild.
func TestAPIStatus(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/status: status %d, want 200", rec.Code)
	}
	var st Status
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatalf("unmarshal status: %v", err)
	}
	if st.PID <= 0 {
		t.Errorf("status pid %d, want >0", st.PID)
	}
	if st.Root == "" {
		t.Errorf("status root empty")
	}
	if st.Nodes == 0 {
		t.Errorf("status node count 0, want fixture count")
	}
	if st.LastRebuild.IsZero() {
		t.Errorf("status last-rebuild zero")
	}
}

// TestAPIStop proves POST /api/stop cancels the server context (graceful
// shutdown signal) and returns 200.
func TestAPIStop(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/stop", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /api/stop: status %d, want 200", rec.Code)
	}
	select {
	case <-srv.Done():
		// context cancelled — shutdown signalled
	default:
		t.Errorf("POST /api/stop did not cancel server context")
	}
}

// TestMethodMatrix proves ft002 method-parity: wrong method on /api/* returns
// 405 with an Allow header naming the accepted method(s).
func TestMethodMatrix(t *testing.T) {
	cases := []struct {
		path      string
		method    string
		wantAllow string
	}{
		{"/api/graph", http.MethodPost, http.MethodGet},
		{"/api/status", http.MethodPost, http.MethodGet},
		{"/api/stop", http.MethodGet, http.MethodPost}, // GET /api/stop -> 405, daemon stays up
	}
	for _, tc := range cases {
		t.Run(tc.method+tc.path, func(t *testing.T) {
			srv := newTestServer(t)
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(tc.method, tc.path, nil)
			srv.Handler().ServeHTTP(rec, req)

			if rec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s %s: status %d, want 405", tc.method, tc.path, rec.Code)
			}
			if allow := rec.Header().Get("Allow"); !strings.Contains(allow, tc.wantAllow) {
				t.Errorf("%s %s: Allow %q, want to contain %q", tc.method, tc.path, allow, tc.wantAllow)
			}
			// GET /api/stop must NOT cancel the context.
			if tc.path == "/api/stop" {
				select {
				case <-srv.Done():
					t.Errorf("GET /api/stop wrongly cancelled server context")
				default:
				}
			}
		})
	}
}

// TestMissingRootErrors proves NewServer fails fast on a nonexistent root,
// naming the offending path.
func TestMissingRootErrors(t *testing.T) {
	_, err := NewServer(filepath.Join("fixtures", "does-not-exist-xyz"))
	if err == nil {
		t.Fatal("NewServer on missing root: want error, got nil")
	}
	if !strings.Contains(err.Error(), "does-not-exist-xyz") {
		t.Errorf("error %q does not name the missing path", err.Error())
	}
}

// TestConcurrentGraphReads exercises the atomic-snapshot guarantee: concurrent
// /api/graph reads interleaved with a rebuild never observe a half-built graph
// (decode always succeeds, node count is stable).
func TestConcurrentGraphReads(t *testing.T) {
	srv := newTestServer(t)
	want := len(srv.Snapshot().Nodes)

	done := make(chan struct{})
	go func() {
		for i := 0; i < 50; i++ {
			_ = srv.Rebuild(context.Background())
		}
		close(done)
	}()

	for i := 0; i < 200; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/api/graph", nil)
		srv.Handler().ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("concurrent GET /api/graph: status %d", rec.Code)
		}
		var g Graph
		if err := json.Unmarshal(rec.Body.Bytes(), &g); err != nil {
			t.Fatalf("concurrent decode: %v", err)
		}
		if len(g.Nodes) != want {
			t.Fatalf("torn snapshot: got %d nodes, want %d", len(g.Nodes), want)
		}
	}
	<-done
}
