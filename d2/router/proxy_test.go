package main

import (
	"bufio"
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// ── fixtures ──────────────────────────────────────────────────────────────────

// readFixture reads a file from the fixtures/ directory relative to this test file.
func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	path := filepath.Join(filepath.Dir(thisFile), "fixtures", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("readFixture %q: %v", name, err)
	}
	return data
}

// ── fake WebSocket helpers ────────────────────────────────────────────────────

// computeWSAccept returns the Sec-WebSocket-Accept for a given key (RFC 6455).
func computeWSAccept(key string) string {
	const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	h := sha1.New()
	h.Write([]byte(key + guid))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// buildWSTextFrame builds a minimal unmasked text frame.
func buildWSTextFrame(payload []byte) []byte {
	var buf bytes.Buffer
	buf.WriteByte(0x81) // FIN=1, opcode=1 (text)
	n := len(payload)
	if n < 126 {
		buf.WriteByte(byte(n))
	} else {
		buf.WriteByte(126)
		buf.WriteByte(byte(n >> 8))
		buf.WriteByte(byte(n))
	}
	buf.Write(payload)
	return buf.Bytes()
}

// wsReader is satisfied by both *bufio.Reader and *bufio.ReadWriter.
type wsReader interface {
	io.Reader
	ReadByte() (byte, error)
}

// readWSTextFrame reads one unmasked WebSocket frame; returns its payload.
func readWSTextFrame(r wsReader) ([]byte, error) {
	_, err := r.ReadByte() // b0: FIN+opcode — not checked here
	if err != nil {
		return nil, fmt.Errorf("frame b0: %w", err)
	}
	b1, err := r.ReadByte()
	if err != nil {
		return nil, fmt.Errorf("frame b1: %w", err)
	}
	length := int(b1 & 0x7f)
	if length == 126 {
		hi, _ := r.ReadByte()
		lo, _ := r.ReadByte()
		length = int(hi)<<8 | int(lo)
	}
	payload := make([]byte, length)
	_, err = io.ReadFull(r, payload)
	return payload, err
}

// echoWSFrames echoes WebSocket frames back until the connection closes or times out.
func echoWSFrames(conn net.Conn, r wsReader) {
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	for {
		payload, err := readWSTextFrame(r)
		if err != nil {
			return
		}
		if _, err := conn.Write(buildWSTextFrame(payload)); err != nil {
			return
		}
	}
}

// ── fake d2 backend ───────────────────────────────────────────────────────────

// newFakeBackend creates an httptest server simulating a d2 --watch child.
// "/" → watchHTML; "/static/watch.js" → watchJS; "/watch" → ws echo;
// any other path → SVG body.
func newFakeBackend(t *testing.T, watchHTML, watchJS []byte) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			w.Header().Set("Content-Type", "image/svg+xml")
			fmt.Fprint(w, "<svg>large asset</svg>")
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(watchHTML)
	})

	mux.HandleFunc("/static/watch.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/javascript")
		w.Write(watchJS)
	})

	mux.HandleFunc("/watch", func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			http.Error(w, "expected ws upgrade", http.StatusBadRequest)
			return
		}
		conn, buf, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		fmt.Fprintf(conn,
			"HTTP/1.1 101 Switching Protocols\r\n"+
				"Upgrade: websocket\r\n"+
				"Connection: Upgrade\r\n"+
				"Sec-WebSocket-Accept: %s\r\n\r\n",
			computeWSAccept(r.Header.Get("Sec-WebSocket-Key")))
		echoWSFrames(conn, buf)
	})

	return httptest.NewServer(mux)
}

// ── proxy test infrastructure ─────────────────────────────────────────────────

// injectFakeChild adds a pre-built Child directly into cm without spawning.
func injectFakeChild(cm *ChildManager, key, absPath string, port int) {
	e := &childEntry{
		child: &Child{
			Key:        key,
			AbsPath:    absPath,
			Port:       port,
			PID:        99999,
			LastActive: time.Now(),
		},
		done: make(chan struct{}),
	}
	cm.mu.Lock()
	cm.entries[key] = e
	cm.mu.Unlock()
}

// backendPort parses the listener port from an httptest.Server.
func backendPort(srv *httptest.Server) int {
	_, portStr, _ := net.SplitHostPort(srv.Listener.Addr().String())
	var port int
	fmt.Sscanf(portStr, "%d", &port)
	return port
}

// makeProxy builds a ProxyHandler + ChildManager for a single project/file route
// backed by the given fake backend server.
func makeProxy(t *testing.T, backend *httptest.Server, project, file string) (http.Handler, *ChildManager, string) {
	t.Helper()
	key := project + "/" + file
	idx := &IndexData{
		Entries: []RouteEntry{
			{Route: "/" + key, AbsPath: "/fake/" + key + ".d2"},
		},
	}
	cfg := config{D2Bin: os.Args[0], ChildPortBase: "0", IdleTimeout: "30m"}
	cm := NewChildManager(cfg, os.Environ())
	injectFakeChild(cm, key, "/fake/"+key+".d2", backendPort(backend))
	return NewProxyHandler(idx, nil, cm), cm, key
}

// ── HTML rewrite tests ────────────────────────────────────────────────────────

func TestProxyHTMLRewrite(t *testing.T) {
	watchHTML := readFixture(t, "watch.html")
	watchJS := readFixture(t, "watch.js")

	backend := newFakeBackend(t, watchHTML, watchJS)
	defer backend.Close()

	h, _, _ := makeProxy(t, backend, "myproject", "test.d2")
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/myproject/test.d2")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)

	// Every "/static/ occurrence in the fixture should become "/myproject/test.d2/static/.
	if bytes.Contains(body, []byte(`"/static/`)) {
		t.Errorf("unrewritten \"/static/ still present:\n%s", body)
	}
	if !bytes.Contains(body, []byte(`"/myproject/test.d2/static/`)) {
		t.Errorf("want \"/myproject/test.d2/static/ in body:\n%s", body)
	}
}

// TestProxyHTMLRewriteMiss: backend serves HTML without /static/ → passthrough + warning.
func TestProxyHTMLRewriteMiss(t *testing.T) {
	mutatedHTML := []byte(`<!DOCTYPE html><html><head></head><body>no static ref here</body></html>`)

	backend := newFakeBackend(t, mutatedHTML, readFixture(t, "watch.js"))
	defer backend.Close()

	var logBuf strings.Builder
	log.SetOutput(&logBuf)
	defer log.SetOutput(os.Stderr)

	h, _, _ := makeProxy(t, backend, "myproject", "test.d2")
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/myproject/test.d2")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if !bytes.Equal(bytes.TrimSpace(body), bytes.TrimSpace(mutatedHTML)) {
		t.Errorf("miss: want unmodified body\ngot: %s", body)
	}
	if !strings.Contains(logBuf.String(), "rewrite") {
		t.Errorf("miss: want rewrite warning; got logs: %s", logBuf.String())
	}
}

// ── watch.js rewrite tests ────────────────────────────────────────────────────

func TestProxyWatchJSRewrite(t *testing.T) {
	watchHTML := readFixture(t, "watch.html")
	watchJS := readFixture(t, "watch.js")

	backend := newFakeBackend(t, watchHTML, watchJS)
	defer backend.Close()

	h, _, _ := makeProxy(t, backend, "myproject", "test.d2")
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/myproject/test.d2/static/watch.js")
	if err != nil {
		t.Fatalf("GET watch.js: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)

	// Old literal must be gone.
	if bytes.Contains(body, []byte("ws://${window.location.host}/watch")) {
		t.Errorf("old ws pattern still present in watch.js")
	}
	// New path must be present as a template literal.
	if !bytes.Contains(body, []byte("`/myproject/test.d2/watch`")) {
		t.Errorf("want `/myproject/test.d2/watch` in watch.js body:\n%s", body)
	}
}

// TestProxyWatchJSRewriteMiss: backend serves watch.js without the expected ws:// pattern.
func TestProxyWatchJSRewriteMiss(t *testing.T) {
	mutatedJS := []byte(`"use strict"; console.log("no ws pattern here");`)

	backend := newFakeBackend(t, readFixture(t, "watch.html"), mutatedJS)
	defer backend.Close()

	var logBuf strings.Builder
	log.SetOutput(&logBuf)
	defer log.SetOutput(os.Stderr)

	h, _, _ := makeProxy(t, backend, "myproject", "test.d2")
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/myproject/test.d2/static/watch.js")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if !bytes.Equal(body, mutatedJS) {
		t.Errorf("miss: want unmodified mutated JS\ngot: %s", body)
	}
	if !strings.Contains(logBuf.String(), "rewrite") {
		t.Errorf("miss: want rewrite warning; logs: %s", logBuf.String())
	}
}

// TestProxyOtherStaticStreamed: non-watch.js assets stream through unmodified.
func TestProxyOtherStaticStreamed(t *testing.T) {
	backend := newFakeBackend(t, readFixture(t, "watch.html"), readFixture(t, "watch.js"))
	defer backend.Close()

	h, _, _ := makeProxy(t, backend, "myproject", "test.d2")
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/myproject/test.d2/diagram.svg")
	if err != nil {
		t.Fatalf("GET svg: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !bytes.Contains(body, []byte("<svg>")) {
		t.Errorf("expected svg content, got: %s", body)
	}
}

// ── 404 / traversal tests ─────────────────────────────────────────────────────

func TestProxy404UnknownRoute(t *testing.T) {
	backend := newFakeBackend(t, readFixture(t, "watch.html"), readFixture(t, "watch.js"))
	defer backend.Close()

	h, _, _ := makeProxy(t, backend, "myproject", "test.d2")
	ts := httptest.NewServer(h)
	defer ts.Close()

	for _, path := range []string{
		"/unknownproject/test.d2",
		"/myproject/notexist.d2",
	} {
		resp, err := http.Get(ts.URL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("GET %s: want 404, got %d", path, resp.StatusCode)
		}
	}
}

func TestProxyTraversalBlocked(t *testing.T) {
	backend := newFakeBackend(t, readFixture(t, "watch.html"), readFixture(t, "watch.js"))
	defer backend.Close()

	h, _, _ := makeProxy(t, backend, "myproject", "test.d2")
	ts := httptest.NewServer(h)
	defer ts.Close()

	for _, rawPath := range []string{
		"/myproject/../etc/passwd",
		"/myproject/%2e%2e/secret",
	} {
		resp, err := http.Get(ts.URL + rawPath)
		if err != nil {
			// HTTP client may reject the URL itself — that's fine.
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			t.Errorf("traversal %q: want 400/404, got %d", rawPath, resp.StatusCode)
		}
	}
}

// TestProxyTraversalRawForms drives the real ProxyHandler with httptest.NewRequest
// (NOT http.Get, which normalises the path client-side before sending). This
// exercises the dangerous /{matched-route}/../../ suffix form and its encoded
// variants that reach a real server unmodified. The child records every suffix it
// receives: any request that escapes the guard MUST be rejected (400/404) AND the
// child suffix must never contain "..".
func TestProxyTraversalRawForms(t *testing.T) {
	// Backend that records the URL path it was asked to serve.
	var gotSuffix atomic.Value
	gotSuffix.Store("")
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Record both the (pre-decoded) Path and the RawPath so we can prove no
		// ".." segment slipped through in either form.
		seen := r.URL.Path
		if r.URL.RawPath != "" {
			seen = r.URL.RawPath
		}
		gotSuffix.Store(seen)
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "child served %s", seen)
	}))
	defer backend.Close()

	idx := &IndexData{
		Entries: []RouteEntry{{Route: "/myproject/test.d2", AbsPath: "/fake/test.d2"}},
	}
	cfg := config{D2Bin: os.Args[0], ChildPortBase: "0", IdleTimeout: "30m"}
	cm := NewChildManager(cfg, os.Environ())
	injectFakeChild(cm, "myproject/test.d2", "/fake/test.d2", backendPort(backend))
	h := NewProxyHandler(idx, nil, cm)

	cases := []struct {
		name    string
		path    string // decoded path (sets r.URL.Path)
		rawPath string // optional encoded path (sets r.URL.RawPath); "" → none
	}{
		{
			name: "matched-route suffix traversal",
			path: "/myproject/test.d2/../../etc/passwd",
		},
		{
			name: "matched-route deep traversal",
			path: "/myproject/test.d2/../../../../../../etc/passwd",
		},
		{
			name:    "encoded slash traversal",
			path:    "/myproject/test.d2/../../etc/passwd",
			rawPath: "/myproject/test.d2/..%2f..%2fetc%2fpasswd",
		},
		{
			name:    "double-encoded dotdot",
			path:    "/myproject/test.d2/../secret",
			rawPath: "/myproject/test.d2/%2e%2e/secret",
		},
		{
			name: "leading traversal",
			path: "/../etc/passwd",
		},
		{
			name:    "encoded dotdot no slash route",
			path:    "/myproject/../etc/passwd",
			rawPath: "/myproject/%2e%2e/etc/passwd",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotSuffix.Store("") // reset child recorder
			req := httptest.NewRequest(http.MethodGet, "http://router"+tc.path, nil)
			if tc.rawPath != "" {
				req.URL.RawPath = tc.rawPath
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)

			if rec.Code != http.StatusBadRequest && rec.Code != http.StatusNotFound {
				t.Errorf("path=%q raw=%q: want 400/404, got %d (body %q)",
					tc.path, tc.rawPath, rec.Code, rec.Body.String())
			}
			if seen, _ := gotSuffix.Load().(string); strings.Contains(seen, "..") {
				t.Errorf("path=%q raw=%q: child received traversal suffix %q (filesystem-hit risk)",
					tc.path, tc.rawPath, seen)
			}
		})
	}
}

// TestHasTraversal unit-tests the guard predicate directly: hostile dot-dot and
// non-canonical shapes are rejected; canonical paths and legitimate trailing
// slashes are allowed.
func TestHasTraversal(t *testing.T) {
	hostile := []string{
		"/myproject/test.d2/../../etc/passwd",
		"/myproject/test.d2/..",
		"/../etc/passwd",
		"/..",
		"/a/./b",  // "." segment → non-canonical
		"/a//b",   // doubled slash → non-canonical
		"/a/../b", // resolvable but still a traversal attempt
	}
	for _, p := range hostile {
		if !hasTraversal(p) {
			t.Errorf("hasTraversal(%q) = false, want true (hostile)", p)
		}
	}

	allowed := []string{
		"/myproject/test.d2",
		"/myproject/test.d2/",          // legit trailing slash
		"/myproject/test.d2/static/",   // legit trailing slash on sub-path
		"/myproject/test.d2/static/watch.js",
		"/",
		"/myproject/..file.d2", // ".." inside a segment, not a segment itself
	}
	for _, p := range allowed {
		if hasTraversal(p) {
			t.Errorf("hasTraversal(%q) = true, want false (legitimate)", p)
		}
	}
}

// ── Accept-Encoding forced to identity ───────────────────────────────────────

func TestProxyAcceptEncodingIdentity(t *testing.T) {
	var receivedEncoding atomic.Value
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedEncoding.Store(r.Header.Get("Accept-Encoding"))
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		// Minimal HTML with /static/ so the rewrite hits.
		w.Write([]byte(`<!DOCTYPE html><html><head><script src="/static/watch.js"></script></head><body></body></html>`))
	}))
	defer backend.Close()

	idx := &IndexData{
		Entries: []RouteEntry{{Route: "/proj/f.d2", AbsPath: "/fake/f.d2"}},
	}
	cfg := config{D2Bin: os.Args[0], ChildPortBase: "0", IdleTimeout: "30m"}
	cm := NewChildManager(cfg, os.Environ())
	injectFakeChild(cm, "proj/f.d2", "/fake/f.d2", backendPort(backend))
	h := NewProxyHandler(idx, nil, cm)
	ts := httptest.NewServer(h)
	defer ts.Close()

	req, _ := http.NewRequest("GET", ts.URL+"/proj/f.d2", nil)
	req.Header.Set("Accept-Encoding", "gzip, deflate")
	resp, err := http.DefaultTransport.RoundTrip(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	resp.Body.Close()

	enc, _ := receivedEncoding.Load().(string)
	if enc != "identity" {
		t.Errorf("Accept-Encoding to child: want \"identity\", got %q", enc)
	}
}

// ── URL-encoded filenames ─────────────────────────────────────────────────────

func TestProxyURLDecodedRouteMatch(t *testing.T) {
	backend := newFakeBackend(t, readFixture(t, "watch.html"), readFixture(t, "watch.js"))
	defer backend.Close()

	// Register a route with a space-encoded name.
	idx := &IndexData{
		Entries: []RouteEntry{
			{Route: "/myproj/test%20file.d2", AbsPath: "/fake/test file.d2"},
		},
	}
	cfg := config{D2Bin: os.Args[0], ChildPortBase: "0", IdleTimeout: "30m"}
	cm := NewChildManager(cfg, os.Environ())
	injectFakeChild(cm, "myproj/test%20file.d2", "/fake/test file.d2", backendPort(backend))
	h := NewProxyHandler(idx, nil, cm)
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/myproj/test%20file.d2")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("encoded path: want 200, got %d", resp.StatusCode)
	}
}

// ── dead child → 502 ─────────────────────────────────────────────────────────

func TestProxyDeadChild502(t *testing.T) {
	// Backend that hijacks and closes immediately (simulates crash mid-request).
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, _, _ := w.(http.Hijacker).Hijack()
		conn.Close()
	}))
	defer backend.Close()

	idx := &IndexData{
		Entries: []RouteEntry{{Route: "/proj/file.d2", AbsPath: "/fake/file.d2"}},
	}
	cfg := config{D2Bin: os.Args[0], ChildPortBase: "0", IdleTimeout: "30m"}
	cm := NewChildManager(cfg, os.Environ())
	injectFakeChild(cm, "proj/file.d2", "/fake/file.d2", backendPort(backend))
	h := NewProxyHandler(idx, nil, cm)
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/proj/file.d2")
	if err != nil {
		t.Logf("expected error on dead backend: %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Errorf("dead child: want 502, got %d", resp.StatusCode)
	}
}

// ── WebSocket client-count tests ──────────────────────────────────────────────

func TestProxyWebSocketClientCount(t *testing.T) {
	backend := newFakeBackend(t, readFixture(t, "watch.html"), readFixture(t, "watch.js"))
	defer backend.Close()

	h, cm, key := makeProxy(t, backend, "myproject", "test.d2")
	ts := httptest.NewServer(h)
	defer ts.Close()

	addr := strings.TrimPrefix(ts.URL, "http://")
	conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	wsKey := "dGhlIHNhbXBsZSBub25jZQ=="
	fmt.Fprintf(conn,
		"GET /myproject/test.d2/watch HTTP/1.1\r\nHost: %s\r\n"+
			"Upgrade: websocket\r\nConnection: Upgrade\r\n"+
			"Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		addr, wsKey)

	reader := bufio.NewReader(conn)
	resp, err := http.ReadResponse(reader, nil)
	if err != nil {
		t.Fatalf("read 101: %v", err)
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("want 101, got %d", resp.StatusCode)
	}

	// Allow proxy goroutines to call AddClient.
	time.Sleep(80 * time.Millisecond)

	snap := cm.Snapshot()
	ch, ok := snap[key]
	if !ok {
		t.Fatalf("key %q not in snapshot after ws connect", key)
	}
	if ch.Clients != 1 {
		t.Errorf("after ws connect: want clients=1, got %d", ch.Clients)
	}
	if time.Since(ch.LastActive) > 5*time.Second {
		t.Errorf("LastActive stale: %v", ch.LastActive)
	}

	// Close connection; RemoveClient should decrement.
	conn.Close()
	time.Sleep(150 * time.Millisecond)

	snap2 := cm.Snapshot()
	if ch2, ok2 := snap2[key]; ok2 {
		if ch2.Clients != 0 {
			t.Errorf("after ws close: want clients=0, got %d", ch2.Clients)
		}
	}
	// If key was removed from snapshot (reaper not expected here), that's also fine.
}

// TestProxyWebSocketEcho: data flows through the upgrade proxy end-to-end.
func TestProxyWebSocketEcho(t *testing.T) {
	backend := newFakeBackend(t, readFixture(t, "watch.html"), readFixture(t, "watch.js"))
	defer backend.Close()

	h, _, _ := makeProxy(t, backend, "myproject", "test.d2")
	ts := httptest.NewServer(h)
	defer ts.Close()

	addr := strings.TrimPrefix(ts.URL, "http://")
	conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	wsKey := "dGhlIHNhbXBsZSBub25jZQ=="
	fmt.Fprintf(conn,
		"GET /myproject/test.d2/watch HTTP/1.1\r\nHost: %s\r\n"+
			"Upgrade: websocket\r\nConnection: Upgrade\r\n"+
			"Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		addr, wsKey)

	reader := bufio.NewReader(conn)
	resp, err := http.ReadResponse(reader, nil)
	if err != nil {
		t.Fatalf("read 101: %v", err)
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("want 101, got %d", resp.StatusCode)
	}

	// Send a text frame.
	payload := []byte("ping")
	conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	conn.Write(buildWSTextFrame(payload))

	// Read echoed frame. The echo MUST round-trip through the upgrade proxy:
	// a read error or a payload mismatch is a hard failure, not an optional log.
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	echoed, err := readWSTextFrame(reader)
	if err != nil {
		t.Fatalf("ws echo read: %v — echoed frame must round-trip through the proxy", err)
	}
	if !bytes.Equal(echoed, payload) {
		t.Errorf("ws echo payload mismatch: want %q got %q", payload, echoed)
	}
}

// TestProxyReindexesFileCreatedAfterStartup proves the dotfiles-t1o
// create-side fix: a .d2 file that did not exist when the handler's route
// set was built is picked up by a lazy re-walk on the routing miss, so it
// routes (200) instead of a permanent 404. Before the fix the route set was
// frozen at construction and a post-startup file was invisible forever.
func TestProxyReindexesFileCreatedAfterStartup(t *testing.T) {
	// The baseline 404 below triggers one re-walk; disable the debounce so
	// the post-create request re-walks again instead of being throttled.
	// (Throttling is covered by TestProxyRewalkDebounced.)
	defer withRewalkDebounce(0)()

	root := t.TempDir()                 // empty — no .d2 at "startup"
	reg := Registry{"proj": root}
	idx := buildIndex(reg)              // zero entries

	backend := newFakeBackend(t, readFixture(t, "watch.html"), readFixture(t, "watch.js"))
	defer backend.Close()

	cfg := config{D2Bin: os.Args[0], ChildPortBase: "0", IdleTimeout: "30m"}
	cm := NewChildManager(cfg, os.Environ())
	h := NewProxyHandler(idx, reg, cm)
	ts := httptest.NewServer(h)
	defer ts.Close()

	// Baseline: with nothing on disk, the route is genuinely absent → 404.
	resp0, err := http.Get(ts.URL + "/proj/new.d2")
	if err != nil {
		t.Fatalf("GET baseline: %v", err)
	}
	resp0.Body.Close()
	if resp0.StatusCode != http.StatusNotFound {
		t.Fatalf("baseline GET /proj/new.d2: want 404 (nothing created yet), got %d", resp0.StatusCode)
	}

	// Create the file AFTER the handler's route set was built, then wire a
	// fake child so the post-reindex lazy-spawn resolves to the backend.
	newFile := filepath.Join(root, "new.d2")
	if err := os.WriteFile(newFile, []byte("a -> b\n"), 0o644); err != nil {
		t.Fatalf("write new.d2: %v", err)
	}
	injectFakeChild(cm, "proj/new.d2", newFile, backendPort(backend))

	resp, err := http.Get(ts.URL + "/proj/new.d2")
	if err != nil {
		t.Fatalf("GET after create: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /proj/new.d2 after create: want 200 (lazy re-walk), got %d", resp.StatusCode)
	}
}

// TestProxyReindexGenuinelyMissingStays404 proves the re-walk does not turn
// every miss into a hit: a request for a file that is not on disk still 404s
// after the re-walk runs (the walk finds nothing to add).
func TestProxyReindexGenuinelyMissingStays404(t *testing.T) {
	root := t.TempDir()
	reg := Registry{"proj": root}
	idx := buildIndex(reg)

	cfg := config{D2Bin: os.Args[0], ChildPortBase: "0", IdleTimeout: "30m"}
	cm := NewChildManager(cfg, os.Environ())
	h := NewProxyHandler(idx, reg, cm)
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/proj/ghost.d2")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("GET /proj/ghost.d2 (never existed): want 404, got %d", resp.StatusCode)
	}
}

// withRewalkDebounce sets the package debounce window and returns a restore
// func for defer. Tests run sequentially (no t.Parallel here), so mutating
// the global is safe.
func withRewalkDebounce(d time.Duration) func() {
	prev := rewalkDebounce
	rewalkDebounce = d
	return func() { rewalkDebounce = prev }
}

// TestProxyRewalkDebounced proves the debounce throttles re-walks: a second
// miss for a project inside the window does NOT re-walk, so a file created
// between two rapid requests stays 404 until the window passes. This is the
// DoS guard — repeated 404s for an absent file must not spin the walker.
func TestProxyRewalkDebounced(t *testing.T) {
	defer withRewalkDebounce(time.Hour)() // effectively "never re-walk twice"

	root := t.TempDir()
	reg := Registry{"proj": root}
	h := NewProxyHandler(buildIndex(reg), reg, &ChildManager{}) // never spawns; all requests miss

	// First miss consumes the single allowed walk for this window.
	resp0, err := http.Get(mustServe(t, h) + "/proj/late.d2")
	if err != nil {
		t.Fatalf("GET first: %v", err)
	}
	resp0.Body.Close()

	// Create the file, then request again within the (1h) window.
	if err := os.WriteFile(filepath.Join(root, "late.d2"), []byte("a -> b\n"), 0o644); err != nil {
		t.Fatalf("write late.d2: %v", err)
	}
	resp, err := http.Get(mustServe(t, h) + "/proj/late.d2")
	if err != nil {
		t.Fatalf("GET second: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("second GET inside debounce window: want 404 (throttled), got %d", resp.StatusCode)
	}
}

// mustServe starts an httptest.Server for h and returns its URL, cleaning up
// via t.Cleanup. A tiny helper so debounce tests can issue two requests to
// the same handler without repeating server boilerplate.
func mustServe(t *testing.T, h http.Handler) string {
	t.Helper()
	ts := httptest.NewServer(h)
	t.Cleanup(ts.Close)
	return ts.URL
}
