package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// --- GET /preview<N> shell -----------------------------------------------

// TestPreviewShellServesHTML proves a plain GET /preview<N> (no websocket
// upgrade headers) returns the shell HTML that opens a websocket and hosts
// the hot-swap content frame (sp008 Task 4 success criteria).
func TestPreviewShellServesHTML(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/preview1", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /preview1: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Errorf("GET /preview1 content-type %q, want text/html", ct)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "app.js") {
		t.Errorf("GET /preview1 body missing app.js script reference: %s", body)
	}
	if !strings.Contains(body, `id="content"`) {
		t.Errorf("GET /preview1 body missing hot-swap content element: %s", body)
	}
}

// TestPreviewStaticAppJSServed proves /static/app.js (referenced by the
// shell) is actually served from the embedded static FS.
func TestPreviewStaticAppJSServed(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/static/app.js", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /static/app.js: status %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "WebSocket") {
		t.Errorf("GET /static/app.js body missing WebSocket client code")
	}
}

// TestPreviewNonNumericSlotReturns400 proves a non-numeric slot N returns
// 400, both for a garbage suffix and for the bare "/preview" with no slot
// at all (sp008 Task 4 edge case: N non-numeric -> 400).
func TestPreviewNonNumericSlotReturns400(t *testing.T) {
	cases := []string{"/previewabc", "/preview", "/preview-1"}
	for _, path := range cases {
		t.Run(path, func(t *testing.T) {
			srv := newTestServer(t)
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodGet, path, nil)
			srv.Handler().ServeHTTP(rec, req)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("GET %s: status %d, want 400 (body: %s)", path, rec.Code, rec.Body.String())
			}
		})
	}
}

// --- POST /preview<N> {path} ----------------------------------------------

// TestPreviewPostSetsSlotPath proves POST /preview<N> {path} sets slot N's
// current path (readable back via the buffered CurrentPath, which a
// freshly-connecting window is primed with).
func TestPreviewPostSetsSlotPath(t *testing.T) {
	srv := newTestServer(t)
	body, _ := json.Marshal(map[string]string{"path": "a.go"})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/preview1", bytes.NewReader(body))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /preview1: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if got := srv.slots.CurrentPath(1); got != "a.go" {
		t.Errorf("slot 1 CurrentPath = %q, want a.go", got)
	}
}

// TestPreviewPostBadJSONReturns400 proves a malformed POST body is rejected
// with 400 rather than a panic or 500.
func TestPreviewPostBadJSONReturns400(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/preview1", strings.NewReader("not json"))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("POST /preview1 bad json: status %d, want 400", rec.Code)
	}
}

// TestPreviewWrongMethodReturns405 proves a method other than GET/POST on
// /preview<N> is rejected (ft002/ft004/preview method-parity).
func TestPreviewWrongMethodReturns405(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodDelete, "/preview1", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("DELETE /preview1: status %d, want 405", rec.Code)
	}
}

// --- websocket integration: connect, push, hot-swap, slot isolation -------

// dialPreview opens a real websocket connection to ts's /preview<n>.
func dialPreview(t *testing.T, ts *httptest.Server, n int) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + previewPath(n)
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial /preview%d: %v", n, err)
	}
	return c
}

func previewPath(n int) string {
	return "/preview" + strconv.Itoa(n)
}

func postPreview(t *testing.T, ts *httptest.Server, n int, path string) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"path": path})
	resp, err := http.Post(ts.URL+previewPath(n), "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST /preview%d: %v", n, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("POST /preview%d: status %d", n, resp.StatusCode)
	}
}

func readRedraw(t *testing.T, c *websocket.Conn, timeout time.Duration) redrawMsg {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(timeout))
	_, raw, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("ws read: %v", err)
	}
	var msg redrawMsg
	if err := json.Unmarshal(raw, &msg); err != nil {
		t.Fatalf("decode redraw message %q: %v", raw, err)
	}
	return msg
}

// TestPreviewWSReceivesSequentialPathUpdates is the sp008 Task 4 test_plan
// ws integration test: connect /preview1, POST {path=A} -> socket receives
// A; POST {path=B} -> receives B.
func TestPreviewWSReceivesSequentialPathUpdates(t *testing.T) {
	srv := newTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	c := dialPreview(t, ts, 1)
	defer c.Close()

	postPreview(t, ts, 1, "a.go")
	if got := readRedraw(t, c, 2*time.Second); got.Path != "a.go" {
		t.Fatalf("first push path = %q, want a.go", got.Path)
	}

	postPreview(t, ts, 1, "b.go")
	if got := readRedraw(t, c, 2*time.Second); got.Path != "b.go" {
		t.Fatalf("second push path = %q, want b.go", got.Path)
	}
}

// TestPreviewWSSlotIsolation is the sp008 Task 4 test_plan slot-isolation
// case: a second client on /preview2 with its own path C must never
// receive the pushes made to /preview1.
func TestPreviewWSSlotIsolation(t *testing.T) {
	srv := newTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	c1 := dialPreview(t, ts, 1)
	defer c1.Close()
	c2 := dialPreview(t, ts, 2)
	defer c2.Close()

	postPreview(t, ts, 1, "a.go")
	if got := readRedraw(t, c1, 2*time.Second); got.Path != "a.go" {
		t.Fatalf("preview1 push path = %q, want a.go", got.Path)
	}
	postPreview(t, ts, 1, "b.go")
	if got := readRedraw(t, c1, 2*time.Second); got.Path != "b.go" {
		t.Fatalf("preview1 second push path = %q, want b.go", got.Path)
	}

	postPreview(t, ts, 2, "c.md")
	if got := readRedraw(t, c2, 2*time.Second); got.Path != "c.md" {
		t.Fatalf("preview2 push path = %q, want c.md", got.Path)
	}

	// c2 must never have received a.go or b.go: assert no further message
	// is waiting for it beyond its own c.md push.
	c2.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
	if _, raw, err := c2.ReadMessage(); err == nil {
		t.Fatalf("preview2 client unexpectedly received an extra message: %s", raw)
	}
}

// TestPreviewWSPrimesBufferedPathOnConnect proves a POST /preview<N> that
// arrives before any window N has connected is buffered and applied the
// moment a window does connect (sp008 Task 4 edge case).
func TestPreviewWSPrimesBufferedPathOnConnect(t *testing.T) {
	srv := newTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	postPreview(t, ts, 3, "buffered.go")

	c := dialPreview(t, ts, 3)
	defer c.Close()

	if got := readRedraw(t, c, 2*time.Second); got.Path != "buffered.go" {
		t.Fatalf("primed path on connect = %q, want buffered.go", got.Path)
	}
}

// TestPreviewWSTwoWindowsSameSlot proves two clients connected to the same
// slot N both receive the same broadcast (edge case: two windows same N).
func TestPreviewWSTwoWindowsSameSlot(t *testing.T) {
	srv := newTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	cA := dialPreview(t, ts, 5)
	defer cA.Close()
	cB := dialPreview(t, ts, 5)
	defer cB.Close()

	postPreview(t, ts, 5, "shared.go")

	if got := readRedraw(t, cA, 2*time.Second); got.Path != "shared.go" {
		t.Fatalf("window A path = %q, want shared.go", got.Path)
	}
	if got := readRedraw(t, cB, 2*time.Second); got.Path != "shared.go" {
		t.Fatalf("window B path = %q, want shared.go", got.Path)
	}
}
