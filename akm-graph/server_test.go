package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
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

// --- POST /api/highlight (sp011 Task 1) -------------------------------------

// TestHandleHighlightResolvesPathToID proves a known fixture path resolves to
// its node id against the current graph and echoes {id, slot} (sp011 Task 1
// success criterion 1 / us010 AC: viewer receives the new current zettel).
func TestHandleHighlightResolvesPathToID(t *testing.T) {
	srv := newTestServer(t)

	var wantPath string
	for _, n := range srv.Snapshot().Nodes {
		if n.ID == "us001" {
			wantPath = n.Path
		}
	}
	if wantPath == "" {
		t.Fatalf("fixture node us001 has no Path — grounding assumption broken")
	}

	reqBody := `{"path":"` + wantPath + `","slot":1}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/highlight", strings.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /api/highlight: status %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var got struct {
		ID   string `json:"id"`
		Slot int    `json:"slot"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if got.ID != "us001" {
		t.Errorf("resolved id = %q, want us001", got.ID)
	}
	if got.Slot != 1 {
		t.Errorf("echoed slot = %d, want 1", got.Slot)
	}
}

// TestHandleHighlightUnknownPathSilentClear proves an unknown/ghost/non-graph
// path stores an empty highlight and returns 200 — never an error (sp011 Task
// 1 success criterion 2: silent no-op, previous highlight cleared).
func TestHandleHighlightUnknownPathSilentClear(t *testing.T) {
	srv := newTestServer(t)

	reqBody := `{"path":"docs/notes/does-not-exist-xyz.md","slot":3}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/highlight", strings.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /api/highlight unknown path: status %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var got struct {
		ID   string `json:"id"`
		Slot int    `json:"slot"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if got.ID != "" {
		t.Errorf("resolved id = %q, want empty (unknown path)", got.ID)
	}
	if got.Slot != 3 {
		t.Errorf("echoed slot = %d, want 3", got.Slot)
	}
}

// TestHandleHighlightSlotOmittedDefaultsToZero proves an omitted slot in the
// request body defaults to slot 0 (standalone), per sp011 Task 1 edge case.
func TestHandleHighlightSlotOmittedDefaultsToZero(t *testing.T) {
	srv := newTestServer(t)

	var wantPath string
	for _, n := range srv.Snapshot().Nodes {
		if n.ID == "us001" {
			wantPath = n.Path
		}
	}

	reqBody := `{"path":"` + wantPath + `"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/highlight", strings.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /api/highlight no slot: status %d, want 200", rec.Code)
	}
	var got struct {
		ID   string `json:"id"`
		Slot int    `json:"slot"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if got.Slot != 0 {
		t.Errorf("default slot = %d, want 0", got.Slot)
	}
}

// TestHandleHighlightMalformedBodyBadRequest proves malformed JSON is
// rejected 400, never a panic (sp011 Task 1 success criterion).
func TestHandleHighlightMalformedBodyBadRequest(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/highlight", strings.NewReader("{not json"))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("POST /api/highlight malformed body: status %d, want 400", rec.Code)
	}
}

// TestHandleHighlightMissingPathBadRequest proves a body with no "path" field
// is rejected 400 rather than silently treated as an unknown-path clear
// (sp011 Task 1 success criterion: missing path -> 400).
func TestHandleHighlightMissingPathBadRequest(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/highlight", strings.NewReader(`{"slot":1}`))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("POST /api/highlight missing path: status %d, want 400", rec.Code)
	}
}

// TestHandleHighlightMethodNotAllowed proves GET /api/highlight is rejected
// 405 with Allow: POST (ft002/server.go method-parity idiom).
func TestHandleHighlightMethodNotAllowed(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/highlight", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /api/highlight: status %d, want 405", rec.Code)
	}
	if allow := rec.Header().Get("Allow"); allow != http.MethodPost {
		t.Errorf("GET /api/highlight Allow header %q, want %q", allow, http.MethodPost)
	}
}

// TestHandleHighlightBroadcastsShapeValidMessage proves an accepted highlight
// fans out exactly one {"type":"highlight",...} message over the existing
// hub — shape-discriminated from raw graph JSON, never a typed envelope
// wrapping the graph itself (sp011 anti-pattern: no envelope on /watch graph
// payloads).
func TestHandleHighlightBroadcastsShapeValidMessage(t *testing.T) {
	srv := newTestServer(t)
	c := newTestClient(4)
	srv.hub.Register(c)
	defer srv.hub.Unregister(c)

	var wantPath string
	for _, n := range srv.Snapshot().Nodes {
		if n.ID == "us001" {
			wantPath = n.Path
		}
	}

	reqBody := `{"path":"` + wantPath + `","slot":2}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/highlight", strings.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST /api/highlight: status %d, want 200", rec.Code)
	}

	select {
	case msg := <-c.send:
		var envelope struct {
			Type string `json:"type"`
			ID   string `json:"id"`
			Slot int    `json:"slot"`
		}
		if err := json.Unmarshal(msg, &envelope); err != nil {
			t.Fatalf("unmarshal hub message: %v; raw=%s", err, msg)
		}
		if envelope.Type != "highlight" {
			t.Errorf("hub message type = %q, want highlight", envelope.Type)
		}
		if envelope.ID != "us001" {
			t.Errorf("hub message id = %q, want us001", envelope.ID)
		}
		if envelope.Slot != 2 {
			t.Errorf("hub message slot = %d, want 2", envelope.Slot)
		}
		// A raw graph payload has no "type" key; confirm this message is NOT
		// shape-compatible with Graph (no nodes/links keys expected here).
		if strings.Contains(string(msg), `"nodes"`) {
			t.Errorf("highlight broadcast wrongly carries a nodes/links envelope: %s", msg)
		}
	default:
		t.Fatal("hub did not fan out a highlight message to the registered client")
	}
}

// --- /watch?slot=N priming (sp011 Task 1) -----------------------------------

// TestWatchSlotPrimedWithStoredHighlightAfterGraph proves connecting to
// /watch?slot=N after a highlight was already stored for that slot receives
// the graph priming message FIRST, then the stored highlight (sp011 Task 1
// success criterion: first zettel preview highlights once ready).
func TestWatchSlotPrimedWithStoredHighlightAfterGraph(t *testing.T) {
	srv := newTestServer(t)

	var wantPath string
	for _, n := range srv.Snapshot().Nodes {
		if n.ID == "us001" {
			wantPath = n.Path
		}
	}

	// Store a highlight for slot 1 before any client connects.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/highlight", strings.NewReader(`{"path":"`+wantPath+`","slot":1}`))
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("seed POST /api/highlight: status %d", rec.Code)
	}

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/watch?slot=1"

	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer c.Close()

	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, msg1, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read first message: %v", err)
	}
	var g Graph
	if err := json.Unmarshal(msg1, &g); err != nil || len(g.Nodes) == 0 {
		t.Fatalf("first message was not the graph priming frame: %s", msg1)
	}

	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, msg2, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read second message (highlight priming): %v", err)
	}
	var envelope struct {
		Type string `json:"type"`
		ID   string `json:"id"`
		Slot int    `json:"slot"`
	}
	if err := json.Unmarshal(msg2, &envelope); err != nil {
		t.Fatalf("unmarshal second message: %v; raw=%s", err, msg2)
	}
	if envelope.Type != "highlight" || envelope.ID != "us001" || envelope.Slot != 1 {
		t.Errorf("highlight priming message = %+v, want type=highlight id=us001 slot=1", envelope)
	}
}

// TestWatchNoSlotNoHighlightPriming proves /watch without ?slot= receives only
// the graph priming frame — no highlight message follows, even if highlights
// are stored for other slots (sp011 Task 1 edge case: standalone viewer, no
// highlight priming).
func TestWatchNoSlotNoHighlightPriming(t *testing.T) {
	srv := newTestServer(t)

	var wantPath string
	for _, n := range srv.Snapshot().Nodes {
		if n.ID == "us001" {
			wantPath = n.Path
		}
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/highlight", strings.NewReader(`{"path":"`+wantPath+`","slot":0}`))
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("seed POST /api/highlight: status %d", rec.Code)
	}

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/watch"

	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer c.Close()

	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, msg1, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read first message: %v", err)
	}
	var g Graph
	if err := json.Unmarshal(msg1, &g); err != nil || len(g.Nodes) == 0 {
		t.Fatalf("first message was not the graph priming frame: %s", msg1)
	}

	// No second message should arrive within a short window.
	c.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	_, _, err = c.ReadMessage()
	if err == nil {
		t.Fatal("unexpected second message on /watch without ?slot=")
	}
}

// TestHighlightConcurrentSlotsRace proves concurrent POSTs to distinct slots
// are safe under the mutex (go test -race, sp011 Task 1 success criterion).
func TestHighlightConcurrentSlotsRace(t *testing.T) {
	srv := newTestServer(t)

	var wantPath string
	for _, n := range srv.Snapshot().Nodes {
		if n.ID == "us001" {
			wantPath = n.Path
		}
	}

	var wg sync.WaitGroup
	for slot := 0; slot < 8; slot++ {
		for i := 0; i < 20; i++ {
			wg.Add(1)
			go func(slot int) {
				defer wg.Done()
				rec := httptest.NewRecorder()
				req := httptest.NewRequest(http.MethodPost, "/api/highlight",
					strings.NewReader(`{"path":"`+wantPath+`","slot":`+itoa(slot)+`}`))
				srv.Handler().ServeHTTP(rec, req)
				if rec.Code != http.StatusOK {
					t.Errorf("concurrent POST /api/highlight slot %d: status %d", slot, rec.Code)
				}
			}(slot)
		}
	}
	wg.Wait()
}

// itoa avoids importing strconv solely for this small test helper.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}
