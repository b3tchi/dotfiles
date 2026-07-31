package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// --- GET /preview<N> ------------------------------------------------------

// TestPreviewGetReturnsJSONNotShellHTML proves a plain GET /preview<N> (no
// websocket upgrade headers) returns {slot, path, type} JSON, not the old
// browser-shell markup the retired wry host used to load — the shell moved
// into QML (sp022 Task 3 success criteria: "GET /preview<N> non-ws returns
// JSON ... instead of [the old static shell]"; sp022 Task 8 deleted that
// static shell's files entirely once nothing served them anymore). This
// test supersedes the pre-sp022 TestPreviewShellServesHTML, which asserted
// exactly the contract this task replaces; server_test.go's
// TestHandlePreviewGetReturnsJSONShape/TestHandlePreviewGetJSONForUnsetSlot
// cover the JSON shape itself in more depth — this one just pins that the
// route reached through the full mux at this exact path is no longer the
// static shell.
func TestPreviewGetReturnsJSONNotShellHTML(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/preview1", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /preview1: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Errorf("GET /preview1 content-type %q, want application/json", ct)
	}
	body := rec.Body.String()
	if strings.Contains(body, `id="content"`) {
		t.Errorf("GET /preview1 body still looks like the old shell HTML: %s", body)
	}
	var got struct {
		Slot int    `json:"slot"`
		Path string `json:"path"`
		Type string `json:"type"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("GET /preview1 body is not the {slot,path,type} JSON shape: %v (body: %s)", err, body)
	}
	if got.Slot != 1 {
		t.Errorf("GET /preview1 slot = %d, want 1", got.Slot)
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
	writeInRoot(t, srv, "a.go")
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
	writeInRoot(t, srv, "a.go", "b.go")
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
	writeInRoot(t, srv, "a.go", "b.go", "c.md")
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
	writeInRoot(t, srv, "buffered.go")
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	postPreview(t, ts, 3, "buffered.go")

	c := dialPreview(t, ts, 3)
	defer c.Close()

	if got := readRedraw(t, c, 2*time.Second); got.Path != "buffered.go" {
		t.Fatalf("primed path on connect = %q, want buffered.go", got.Path)
	}
}

// TestPreviewWSBroadcastCarriesClassifiedType is the sp022 Task 2 test_plan
// ws test: connect, POST an image path, assert the frame is
// {"path":...,"type":"image"}; POST an md path next, assert the type swaps
// to "md" in the very same connection — the QML client (T4) reads this
// field to pick a delegate without re-fetching or sniffing HTML itself.
func TestPreviewWSBroadcastCarriesClassifiedType(t *testing.T) {
	srv := newTestServer(t)
	writeInRoot(t, srv, "photo.png", "note.md")
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	c := dialPreview(t, ts, 1)
	defer c.Close()

	postPreview(t, ts, 1, "photo.png")
	got := readRedraw(t, c, 2*time.Second)
	if got.Path != "photo.png" || got.Type != "image" {
		t.Fatalf("first push = {path:%q type:%q}, want {photo.png image}", got.Path, got.Type)
	}

	postPreview(t, ts, 1, "note.md")
	got = readRedraw(t, c, 2*time.Second)
	if got.Path != "note.md" || got.Type != "md" {
		t.Fatalf("second push = {path:%q type:%q}, want {note.md md}", got.Path, got.Type)
	}
}

// TestPreviewWSPrimingFrameCarriesClassifiedType proves the priming frame
// (a POST that lands before any window has connected, buffered per sp008
// Task 4) also carries the classified type once a window does connect —
// not just the sequential-broadcast path exercised above (sp022 Task 2
// test_plan: "priming test: POST before connect -> priming frame carries
// type").
func TestPreviewWSPrimingFrameCarriesClassifiedType(t *testing.T) {
	srv := newTestServer(t)
	writeInRoot(t, srv, "clip.mp4")
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	postPreview(t, ts, 4, "clip.mp4")

	c := dialPreview(t, ts, 4)
	defer c.Close()

	got := readRedraw(t, c, 2*time.Second)
	if got.Path != "clip.mp4" || got.Type != "video" {
		t.Fatalf("primed frame = {path:%q type:%q}, want {clip.mp4 video}", got.Path, got.Type)
	}
}

// TestPreviewWSPrimingDegradesToNoneWhenFileDeleted proves the sp022 Task 2
// edge case classifyStoredPath exists for: "path deleted between store and
// classify -> classify against the stored root-relative path degrades to
// none, broadcast still goes out (client shows fallback)". A path is
// POSTed and stored while the fixture still exists (POST validates
// existence at ingestion — dotfiles-joz), the underlying file is then
// removed from disk, and only THEN does a window connect — so priming
// (handlePreviewWS) calls classifyStoredPath against a stored path whose
// resolveInRoot now fails. The frame must still arrive (not be swallowed)
// with "type":"none", never an error or a dropped send.
func TestPreviewWSPrimingDegradesToNoneWhenFileDeleted(t *testing.T) {
	srv := newTestServer(t)
	writeInRoot(t, srv, "vanishing.go")
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	postPreview(t, ts, 6, "vanishing.go")

	if err := os.Remove(filepath.Join(srv.root, "vanishing.go")); err != nil {
		t.Fatalf("remove fixture between store and classify: %v", err)
	}

	c := dialPreview(t, ts, 6)
	defer c.Close()

	got := readRedraw(t, c, 2*time.Second)
	if got.Path != "vanishing.go" {
		t.Fatalf("primed frame path = %q, want vanishing.go (path is still delivered so the client can show its fallback)", got.Path)
	}
	if got.Type != "none" {
		t.Errorf("primed frame type = %q, want none (deleted-file degrade)", got.Type)
	}
}

// TestPreviewWSTwoWindowsSameSlot proves two clients connected to the same
// slot N both receive the same broadcast (edge case: two windows same N).
func TestPreviewWSTwoWindowsSameSlot(t *testing.T) {
	srv := newTestServer(t)
	writeInRoot(t, srv, "shared.go")
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
