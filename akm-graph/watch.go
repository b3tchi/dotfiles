package main

import (
	"context"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/gorilla/websocket"
)

// wsClient is a single /watch subscriber. send is buffered; a client whose
// buffer fills (stuck socket) is dropped by the Hub so one slow reader can
// never stall the broadcast loop.
type wsClient struct {
	conn *websocket.Conn
	send chan []byte
}

// Hub fans a graph payload out to all connected /watch clients. It is guarded
// by a mutex rather than a run-loop goroutine so Broadcast/Register/Unregister
// are simple synchronous calls and drop-on-full needs no extra coordination.
type Hub struct {
	mu      sync.Mutex
	clients map[*wsClient]bool
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{clients: make(map[*wsClient]bool)}
}

// Register adds a client.
func (h *Hub) Register(c *wsClient) {
	h.mu.Lock()
	h.clients[c] = true
	h.mu.Unlock()
}

// Unregister removes a client and closes its send channel exactly once. Safe to
// call twice (broadcast-drop then read-pump disconnect).
func (h *Hub) Unregister(c *wsClient) {
	h.mu.Lock()
	if h.clients[c] {
		delete(h.clients, c)
		close(c.send)
	}
	h.mu.Unlock()
}

// Count returns the number of connected clients.
func (h *Hub) Count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// Broadcast pushes msg to every client with a non-blocking send. Any client
// whose buffer is full is dropped (removed + send closed) so it cannot stall
// delivery to the others.
func (h *Hub) Broadcast(msg []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		select {
		case c.send <- msg:
		default:
			// Full buffer -> slow/stuck client. Drop it.
			delete(h.clients, c)
			close(c.send)
		}
	}
}

// Watcher fsnotify-watches every directory under root (fsnotify is
// non-recursive, so subdirs are added explicitly and newly-created dirs are
// added as they appear). Bursts of events are debounced into a single
// onChange call.
type Watcher struct {
	w        *fsnotify.Watcher
	root     string
	debounce time.Duration
	onChange func()
}

// NewWatcher creates the fsnotify watcher and adds every existing directory
// under root.
func NewWatcher(root string, debounce time.Duration, onChange func()) (*Watcher, error) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	wt := &Watcher{w: w, root: root, debounce: debounce, onChange: onChange}
	if err := wt.addTree(root); err != nil {
		w.Close()
		return nil, err
	}
	return wt, nil
}

// addTree walks dir and adds every directory to the watch set. Missing dirs are
// skipped rather than fatal (a dir may vanish between walk and add).
func (wt *Watcher) addTree(dir string) error {
	return filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // tolerate transient errors during walk
		}
		if d.IsDir() {
			_ = wt.w.Add(p)
		}
		return nil
	})
}

// Run consumes fsnotify events until ctx is cancelled, debouncing bursts into
// one onChange. Newly-created directories are added to the watch set so files
// created inside them are seen. A deleted watched root is logged but does not
// stop the loop (the server keeps serving the last graph).
func (wt *Watcher) Run(ctx context.Context) {
	var timer *time.Timer
	var timerC <-chan time.Time

	arm := func() {
		if timer == nil {
			timer = time.NewTimer(wt.debounce)
		} else {
			timer.Reset(wt.debounce)
		}
		timerC = timer.C
	}

	for {
		select {
		case <-ctx.Done():
			return

		case ev, ok := <-wt.w.Events:
			if !ok {
				return
			}
			// A newly-created directory must be watched explicitly.
			if ev.Op&fsnotify.Create != 0 {
				if fi, err := os.Stat(ev.Name); err == nil && fi.IsDir() {
					_ = wt.addTree(ev.Name)
				}
			}
			if ev.Name == wt.root && ev.Op&fsnotify.Remove != 0 {
				log.Printf("akm-graph: watched root %s removed; serving last graph", wt.root)
			}
			arm()

		case <-timerC:
			timerC = nil
			wt.onChange()

		case err, ok := <-wt.w.Errors:
			if !ok {
				return
			}
			log.Printf("akm-graph: watch error: %v", err)
		}
	}
}

// Close stops the underlying fsnotify watcher.
func (wt *Watcher) Close() error {
	return wt.w.Close()
}
