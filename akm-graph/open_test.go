package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// previewStub records every POST /open body it receives and can be dialed via
// $PREVIEW_PORT so handleOpen's outbound call lands on it instead of a real
// preview-d (sp009 Task 5 test_plan: "httptest stub preview-d capturing the
// body").
type previewStub struct {
	srv   *httptest.Server
	calls []map[string]any
}

func newPreviewStub(t *testing.T) *previewStub {
	t.Helper()
	stub := &previewStub{}
	stub.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		stub.calls = append(stub.calls, body)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"opened":true}`))
	}))
	port := stub.srv.URL[strings.LastIndex(stub.srv.URL, ":")+1:]
	t.Setenv("PREVIEW_PORT", port)
	t.Cleanup(stub.srv.Close)
	return stub
}

// TestHandleOpenResolvesIDAndForwardsToPreview proves POST /api/open
// {id, slot} resolves the fixture node's Path from the built graph and POSTs
// {path, slot} to the stub preview-d.
func TestHandleOpenResolvesIDAndForwardsToPreview(t *testing.T) {
	stub := newPreviewStub(t)
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

	reqBody := `{"id":"us001","slot":2}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/open", strings.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /api/open: status %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if len(stub.calls) != 1 {
		t.Fatalf("preview-d stub calls = %d, want 1", len(stub.calls))
	}
	got := stub.calls[0]
	if got["path"] != wantPath {
		t.Errorf("stub received path %v, want %q", got["path"], wantPath)
	}
	if got["slot"] != float64(2) {
		t.Errorf("stub received slot %v, want 2", got["slot"])
	}
}

// TestHandleOpenNoSlotOmitsSlotDownstream proves that when the request body
// carries no slot, the downstream POST to preview-d omits the slot field
// entirely (sp009 Task 5: standalone akm -> preview-d global $NVIM,
// best-effort — must not send slot:null or slot:0).
func TestHandleOpenNoSlotOmitsSlotDownstream(t *testing.T) {
	stub := newPreviewStub(t)
	srv := newTestServer(t)

	reqBody := `{"id":"us001"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/open", strings.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /api/open: status %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if len(stub.calls) != 1 {
		t.Fatalf("preview-d stub calls = %d, want 1", len(stub.calls))
	}
	if _, present := stub.calls[0]["slot"]; present {
		t.Errorf("stub body has slot field %v, want omitted entirely", stub.calls[0]["slot"])
	}
}

// TestHandleOpenGhostIDNoDownstreamCall proves an unknown/ghost id never
// reaches preview-d (sp009 Task 5 edge case: unknown/ghost id -> 404/no-op,
// no downstream call).
func TestHandleOpenGhostIDNoDownstreamCall(t *testing.T) {
	stub := newPreviewStub(t)
	srv := newTestServer(t)

	reqBody := `{"id":"this-id-does-not-exist-xyz"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/open", strings.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("POST /api/open ghost id: status %d, want 404", rec.Code)
	}
	if len(stub.calls) != 0 {
		t.Fatalf("preview-d stub calls = %d, want 0 (ghost id must not reach preview-d)", len(stub.calls))
	}
}

// TestHandleOpenPreviewUnreachableTimesOut proves that when preview-d accepts
// the connection but never responds, handleOpen returns an error (not a hang)
// within the bounded timeout — sp009 Task 5 edge case: "preview-d down ->
// error, not a hang." previewOpenTimeout is shortened for the test so this
// doesn't pay the full production budget (mirrors preview/proxy.go's
// daemonSpawnWait test seam). A raw net.Listener (not httptest.Server) is used
// so the never-responding connection can be abandoned without Close() blocking
// on it — the accept loop unwinds when the listener closes.
func TestHandleOpenPreviewUnreachableTimesOut(t *testing.T) {
	orig := previewOpenTimeout
	previewOpenTimeout = 100 * time.Millisecond
	t.Cleanup(func() { previewOpenTimeout = orig })

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	var (
		mu    sync.Mutex
		held  []net.Conn // keep accepted conns alive so no finalizer closes them early
	)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return // listener closed in cleanup
			}
			mu.Lock()
			held = append(held, conn) // accept, then never read/write — force a client-side timeout
			mu.Unlock()
		}
	}()
	_, port, err := net.SplitHostPort(ln.Addr().String())
	if err != nil {
		t.Fatalf("split host port: %v", err)
	}
	t.Setenv("PREVIEW_PORT", port)

	srv := newTestServer(t)
	reqBody := `{"id":"us001"}`

	done := make(chan int, 1)
	go func() {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/open", strings.NewReader(reqBody))
		srv.Handler().ServeHTTP(rec, req)
		done <- rec.Code
	}()

	select {
	case code := <-done:
		if code < 400 {
			t.Fatalf("POST /api/open against hung preview-d: status %d, want an error status", code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("POST /api/open hung past its bounded timeout — request goroutine blocked indefinitely")
	}
}

// TestHandleOpenMethodNotAllowed proves GET /api/open is rejected 405 with
// Allow: POST (ft002/server.go method-parity idiom).
func TestHandleOpenMethodNotAllowed(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/open", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /api/open: status %d, want 405", rec.Code)
	}
	if allow := rec.Header().Get("Allow"); allow != http.MethodPost {
		t.Errorf("GET /api/open Allow header %q, want %q", allow, http.MethodPost)
	}
}
