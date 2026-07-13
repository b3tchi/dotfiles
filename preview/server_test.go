package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// newTestServer wires a Server against a scratch temp dir root so handler
// tests don't depend on the working directory.
func newTestServer(t *testing.T) *Server {
	t.Helper()
	root := t.TempDir()
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer(%q): %v", root, err)
	}
	return srv
}

// TestStatus proves GET /status returns 200 + a JSON health snapshot with
// the expected fields (sp008 Task 1 success criteria, ft002/ft004 parity).
func TestStatus(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/status", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /status: status %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Errorf("GET /status content-type %q, want application/json", ct)
	}
	var st Status
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatalf("unmarshal /status: %v", err)
	}
	if st.PID <= 0 {
		t.Errorf("status pid %d, want >0", st.PID)
	}
	if st.Root == "" {
		t.Errorf("status root empty")
	}
	if st.Port != "4200" {
		t.Errorf("status port %q, want 4200", st.Port)
	}
	if st.StartedAt.IsZero() {
		t.Errorf("status started_at zero")
	}
}

// TestStop proves POST /stop cancels the server context (graceful shutdown
// signal) and returns 200.
func TestStop(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/stop", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /stop: status %d, want 200", rec.Code)
	}
	select {
	case <-srv.Done():
		// context cancelled — shutdown signalled
	default:
		t.Errorf("POST /stop did not cancel server context")
	}
}

// TestStopIdempotent proves a second POST /stop after the context is
// already cancelled still returns 200 rather than panicking or erroring
// (sp008 Task 1 edge case: double stop is idempotent).
func TestStopIdempotent(t *testing.T) {
	srv := newTestServer(t)

	rec1 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec1, httptest.NewRequest(http.MethodPost, "/stop", nil))
	if rec1.Code != http.StatusOK {
		t.Fatalf("first POST /stop: status %d, want 200", rec1.Code)
	}

	rec2 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec2, httptest.NewRequest(http.MethodPost, "/stop", nil))
	if rec2.Code != http.StatusOK {
		t.Fatalf("second POST /stop: status %d, want 200", rec2.Code)
	}

	select {
	case <-srv.Done():
	default:
		t.Errorf("context not cancelled after double stop")
	}
}

// TestMethodMatrix proves ft002/ft004 method-parity: wrong method on
// /status or /stop returns 405 with an Allow header naming the accepted
// method, and a wrong-method /stop never cancels the context.
func TestMethodMatrix(t *testing.T) {
	cases := []struct {
		path      string
		method    string
		wantAllow string
	}{
		{"/status", http.MethodPost, http.MethodGet},
		{"/stop", http.MethodGet, http.MethodPost},
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
			if tc.path == "/stop" {
				select {
				case <-srv.Done():
					t.Errorf("GET /stop wrongly cancelled server context")
				default:
				}
			}
		})
	}
}

// TestMissingRootErrors proves NewServer fails fast on a nonexistent root,
// naming the offending path (sp008 Task 1 edge case: -root missing dir ->
// error at startup, not empty serve).
func TestMissingRootErrors(t *testing.T) {
	_, err := NewServer("/does-not-exist-xyz-preview-root", "4200")
	if err == nil {
		t.Fatal("NewServer on missing root: want error, got nil")
	}
	if !strings.Contains(err.Error(), "does-not-exist-xyz-preview-root") {
		t.Errorf("error %q does not name the missing path", err.Error())
	}
}
