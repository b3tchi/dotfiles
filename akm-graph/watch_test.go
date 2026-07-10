package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// --- Hub broadcast / slow-client drop ---------------------------------------

// TestHubBroadcastDropsBlockedClient proves a stuck client (send buffer full,
// never drained) is dropped on broadcast while the others still receive.
func TestHubBroadcastDropsBlockedClient(t *testing.T) {
	h := NewHub()

	good1 := newTestClient(4)
	good2 := newTestClient(4)
	stuck := newTestClient(0) // unbuffered + never drained -> always blocks
	h.Register(good1)
	h.Register(good2)
	h.Register(stuck)
	if h.Count() != 3 {
		t.Fatalf("Count after register: %d, want 3", h.Count())
	}

	h.Broadcast([]byte("hello"))

	if got := <-good1.send; string(got) != "hello" {
		t.Errorf("good1 got %q, want hello", got)
	}
	if got := <-good2.send; string(got) != "hello" {
		t.Errorf("good2 got %q, want hello", got)
	}
	if h.Count() != 2 {
		t.Errorf("stuck client not dropped: Count %d, want 2", h.Count())
	}
}

// TestHubUnregisterIdempotent proves a double unregister (broadcast-drop then
// read-pump disconnect) does not panic on a double close.
func TestHubUnregisterIdempotent(t *testing.T) {
	h := NewHub()
	c := newTestClient(1)
	h.Register(c)
	h.Unregister(c)
	h.Unregister(c) // must be a no-op, not a panic
	if h.Count() != 0 {
		t.Errorf("Count after unregister: %d, want 0", h.Count())
	}
}

// --- Watcher debounce + fs events -------------------------------------------

// TestWatcherDebouncesBurst proves ~20 writes inside the debounce window
// collapse to exactly one onChange call.
func TestWatcherDebouncesBurst(t *testing.T) {
	root := t.TempDir()
	mustMkNotes(t, root)

	var calls int32
	fired := make(chan struct{}, 8)
	wt, err := NewWatcher(root, 120*time.Millisecond, func() {
		atomic.AddInt32(&calls, 1)
		fired <- struct{}{}
	})
	if err != nil {
		t.Fatalf("NewWatcher: %v", err)
	}
	defer wt.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go wt.Run(ctx)

	notesDir := filepath.Join(root, "docs", "notes")
	for i := 0; i < 20; i++ {
		p := filepath.Join(notesDir, "burst"+string(rune('a'+i))+".md")
		if err := os.WriteFile(p, []byte("# x"), 0644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	waitFor(t, fired, time.Second)
	// Allow any late duplicate to arrive, then assert coalescing.
	time.Sleep(250 * time.Millisecond)
	if n := atomic.LoadInt32(&calls); n != 1 {
		t.Errorf("debounce: onChange fired %d times for one burst, want 1", n)
	}
}

// TestWatcherPicksUpNewSubdir proves a subdir created after startup is watched
// and files inside it trigger a rebuild (fsnotify is non-recursive).
func TestWatcherPicksUpNewSubdir(t *testing.T) {
	root := t.TempDir()
	mustMkNotes(t, root)

	fired := make(chan struct{}, 8)
	wt, err := NewWatcher(root, 80*time.Millisecond, func() { fired <- struct{}{} })
	if err != nil {
		t.Fatalf("NewWatcher: %v", err)
	}
	defer wt.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go wt.Run(ctx)

	sub := filepath.Join(root, "docs", "notes", "newsub")
	if err := os.Mkdir(sub, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	waitFor(t, fired, time.Second) // dir-create itself triggers a rebuild
	drain(fired)

	if err := os.WriteFile(filepath.Join(sub, "us099.md"), []byte("# y"), 0644); err != nil {
		t.Fatalf("write in new subdir: %v", err)
	}
	waitFor(t, fired, time.Second) // file in the newly-watched subdir triggers
}

// TestWatcherRenameAndDelete proves editor atomic-rename saves and deletes both
// trigger a rebuild (RENAME/CREATE, not only WRITE).
func TestWatcherRenameAndDelete(t *testing.T) {
	root := t.TempDir()
	mustMkNotes(t, root)
	notesDir := filepath.Join(root, "docs", "notes")
	orig := filepath.Join(notesDir, "us001.md")
	if err := os.WriteFile(orig, []byte("# a"), 0644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	fired := make(chan struct{}, 8)
	wt, err := NewWatcher(root, 80*time.Millisecond, func() { fired <- struct{}{} })
	if err != nil {
		t.Fatalf("NewWatcher: %v", err)
	}
	defer wt.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go wt.Run(ctx)

	// Atomic-rename save: write temp then rename over target.
	tmp := filepath.Join(notesDir, ".us001.md.tmp")
	if err := os.WriteFile(tmp, []byte("# b"), 0644); err != nil {
		t.Fatalf("tmp write: %v", err)
	}
	if err := os.Rename(tmp, orig); err != nil {
		t.Fatalf("rename: %v", err)
	}
	waitFor(t, fired, time.Second)
	drain(fired)

	if err := os.Remove(orig); err != nil {
		t.Fatalf("remove: %v", err)
	}
	waitFor(t, fired, time.Second)
}

// --- WS endpoint integration ------------------------------------------------

// TestWSPushesGraphOnChange proves a connected /watch client receives the
// initial graph then a fresh graph <1s after a file touch.
func TestWSPushesGraphOnChange(t *testing.T) {
	root := t.TempDir()
	mustMkNotes(t, root)
	notesDir := filepath.Join(root, "docs", "notes")
	os.WriteFile(filepath.Join(notesDir, "us001.md"), []byte("# a"), 0644)

	srv, err := NewServer(root)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := srv.StartWatcher(ctx, 80*time.Millisecond); err != nil {
		t.Fatalf("StartWatcher: %v", err)
	}

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/watch"

	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer c.Close()

	// Initial push.
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, msg, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read initial: %v", err)
	}
	var g0 Graph
	if err := json.Unmarshal(msg, &g0); err != nil {
		t.Fatalf("decode initial: %v", err)
	}

	// Touch a new note -> expect a fresh push with more nodes.
	os.WriteFile(filepath.Join(notesDir, "us100.md"), []byte("# new [[us001]]"), 0644)

	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, msg2, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read pushed: %v", err)
	}
	var g1 Graph
	if err := json.Unmarshal(msg2, &g1); err != nil {
		t.Fatalf("decode pushed: %v", err)
	}
	if len(g1.Nodes) <= len(g0.Nodes) {
		t.Errorf("pushed graph did not grow: before=%d after=%d", len(g0.Nodes), len(g1.Nodes))
	}
}

// TestWSUpgradeRejectsPlainGet proves a non-WebSocket request to /watch is
// rejected fast (4xx) rather than hanging.
func TestWSUpgradeRejectsPlainGet(t *testing.T) {
	srv := newTestServer(t) // from server_test.go, fixture root
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/watch")
	if err != nil {
		t.Fatalf("GET /watch: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 400 || resp.StatusCode >= 500 {
		t.Errorf("plain GET /watch: status %d, want 4xx (no hang)", resp.StatusCode)
	}
}

// --- helpers ----------------------------------------------------------------

func newTestClient(buf int) *wsClient {
	return &wsClient{send: make(chan []byte, buf)}
}

func mustMkNotes(t *testing.T, root string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, "docs", "notes"), 0755); err != nil {
		t.Fatalf("mkdir notes: %v", err)
	}
	// hub file so BuildGraphFromRoot has content
	if err := os.WriteFile(filepath.Join(root, "docs", "board.md"), []byte("# board"), 0644); err != nil {
		t.Fatalf("board: %v", err)
	}
}

func waitFor(t *testing.T, ch <-chan struct{}, d time.Duration) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(d):
		t.Fatalf("timed out waiting %s for onChange", d)
	}
}

func drain(ch chan struct{}) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}
