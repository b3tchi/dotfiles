package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// newFakeNvimOnPath installs a stub "nvim" executable at the front of PATH
// that records its argv (NUL-separated, one write per invocation) to a log
// file instead of driving a real editor. This is the sp008 Task 6 test_plan
// mechanism ("handler test with a fake nvim on PATH capturing argv") — it
// lets tests assert exactly what handleOpen would have executed without a
// real nvim server. PATH and FAKE_NVIM_LOG are both t.Setenv'd, so both
// reset automatically at test end.
func newFakeNvimOnPath(t *testing.T) (logPath string) {
	t.Helper()
	dir := t.TempDir()
	logPath = filepath.Join(dir, "nvim-argv.log")
	script := "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\" >> \"$FAKE_NVIM_LOG\"; done\nexit 0\n"
	scriptPath := filepath.Join(dir, "nvim")
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake nvim script: %v", err)
	}
	t.Setenv("FAKE_NVIM_LOG", logPath)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return logPath
}

// readArgvLog parses newFakeNvimOnPath's NUL-separated log into individual
// argv entries across all invocations. A missing file (never invoked) is
// reported as nil, not an error — callers assert "never called" against
// that nil.
func readArgvLog(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatalf("read fake nvim argv log: %v", err)
	}
	raw := bytes.Split(data, []byte{0})
	var out []string
	for _, r := range raw {
		if len(r) == 0 {
			continue
		}
		out = append(out, string(r))
	}
	return out
}

func containsArg(argv []string, want string) bool {
	for _, a := range argv {
		if a == want {
			return true
		}
	}
	return false
}

// TestHandleOpenValidPathInvokesNvimRemote proves the sp008 Task 6 success
// criteria core case: a valid in-root path is opened via
// "nvim --server $NVIM --remote <abs path>" as an arg vector (never a shell
// string — the argv log would concatenate into one token if it were).
func TestHandleOpenValidPathInvokesNvimRemote(t *testing.T) {
	logPath := newFakeNvimOnPath(t)
	t.Setenv("NVIM", "/tmp/fake-nvim-socket")

	root := t.TempDir()
	target := filepath.Join(root, "note.md")
	if err := os.WriteFile(target, []byte("# hi"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	reqBody, _ := json.Marshal(map[string]string{"path": "note.md"})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/open", bytes.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /open: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	wantAbs, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatalf("EvalSymlinks fixture: %v", err)
	}
	argv := readArgvLog(t, logPath)
	if !containsArg(argv, "--remote") {
		t.Errorf("nvim argv %v missing --remote", argv)
	}
	if !containsArg(argv, wantAbs) {
		t.Errorf("nvim argv %v missing abs path %q", argv, wantAbs)
	}
	if !containsArg(argv, "/tmp/fake-nvim-socket") {
		t.Errorf("nvim argv %v missing --server value from $NVIM", argv)
	}
}

// TestHandleOpenOutOfRootRejectedWithoutExec proves the sp008 Task 6
// anti-pattern gate: a path that escapes the allowed root is rejected with
// 400 and the subprocess is NEVER invoked — validation happens strictly
// before exec.
func TestHandleOpenOutOfRootRejectedWithoutExec(t *testing.T) {
	logPath := newFakeNvimOnPath(t)
	t.Setenv("NVIM", "/tmp/fake-nvim-socket")

	root := t.TempDir()
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	reqBody, _ := json.Marshal(map[string]string{"path": "../../etc/passwd"})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/open", bytes.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("POST /open (out-of-root): status %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(logPath); !os.IsNotExist(err) {
		t.Errorf("fake nvim was invoked for an out-of-root path (log exists at %q)", logPath)
	}
}

// TestHandleOpenMissingNvimEnvReturnsError proves the sp008 Task 6 edge
// case: $NVIM unset means there is no running editor server to target, so
// the handler must return a distinct, clear error (424 Failed Dependency)
// rather than a silent no-op or a 500 — and must never invoke the
// subprocess.
func TestHandleOpenMissingNvimEnvReturnsError(t *testing.T) {
	logPath := newFakeNvimOnPath(t)
	t.Setenv("NVIM", "")

	root := t.TempDir()
	target := filepath.Join(root, "note.md")
	if err := os.WriteFile(target, []byte("hi"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	reqBody, _ := json.Marshal(map[string]string{"path": "note.md"})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/open", bytes.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusFailedDependency {
		t.Fatalf("POST /open ($NVIM unset): status %d, want 424 (body: %s)", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(logPath); !os.IsNotExist(err) {
		t.Errorf("fake nvim was invoked despite missing $NVIM (log exists at %q)", logPath)
	}
}

// TestHandleOpenNonexistentPathReturns404 proves the "validates the path
// exists" half of the success criteria: an in-root path that does not
// exist is a 404 (resolveInRoot's os.ErrNotExist case), not a 500 and not
// an exec attempt.
func TestHandleOpenNonexistentPathReturns404(t *testing.T) {
	logPath := newFakeNvimOnPath(t)
	t.Setenv("NVIM", "/tmp/fake-nvim-socket")
	srv := newTestServer(t)

	reqBody, _ := json.Marshal(map[string]string{"path": "does-not-exist.md"})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/open", bytes.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("POST /open (nonexistent): status %d, want 404 (body: %s)", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(logPath); !os.IsNotExist(err) {
		t.Errorf("fake nvim was invoked for a nonexistent path (log exists at %q)", logPath)
	}
}

// freePort reserves an OS-assigned free TCP port on 127.0.0.1, releases it
// immediately, and returns its number as a string. There is an inherent
// small race between release and a later bind (another process could grab
// it first) — acceptable for these tests, the same tradeoff the Go stdlib's
// own "httptest with a fixed port" idiom makes.
func freePort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve free port: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	if err := ln.Close(); err != nil {
		t.Fatalf("release free port: %v", err)
	}
	return fmt.Sprintf("%d", port)
}

// startStubDaemon binds a minimal HTTP server to 127.0.0.1:port that
// answers GET /api/status with 200 — enough for daemonHealthy to consider
// it running (ft002/ft004 api_surface parity: both real daemons expose
// /api/status). Returns a cleanup func; also registered via t.Cleanup.
func startStubDaemon(t *testing.T, port string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		t.Fatalf("bind stub daemon on port %s: %v", port, err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
}

// TestEnsureDaemonRunningAlreadyHealthySkipsSpawn proves the fast path: a
// daemon that already answers /api/status is left alone — spawn is never
// invoked.
func TestEnsureDaemonRunningAlreadyHealthySkipsSpawn(t *testing.T) {
	port := freePort(t)
	startStubDaemon(t, port)

	var mu sync.Mutex
	var spawnCalls int32
	spawn := func() error {
		atomic.AddInt32(&spawnCalls, 1)
		return nil
	}

	if err := ensureDaemonRunning(&mu, port, spawn); err != nil {
		t.Fatalf("ensureDaemonRunning: %v", err)
	}
	if got := atomic.LoadInt32(&spawnCalls); got != 0 {
		t.Errorf("spawn called %d times, want 0 (daemon was already healthy)", got)
	}
}

// TestEnsureDaemonRunningSpawnsWhenDown proves the sp008 Task 7 core lazy-
// spawn case: nothing answers the target port, so ensureDaemonRunning
// invokes spawn (spy) and then waits for the daemon to become healthy
// before returning.
func TestEnsureDaemonRunningSpawnsWhenDown(t *testing.T) {
	port := freePort(t)

	var mu sync.Mutex
	var spawnCalls int32
	spawn := func() error {
		atomic.AddInt32(&spawnCalls, 1)
		startStubDaemon(t, port) // simulate the subprocess coming alive
		return nil
	}

	if err := ensureDaemonRunning(&mu, port, spawn); err != nil {
		t.Fatalf("ensureDaemonRunning: %v", err)
	}
	if got := atomic.LoadInt32(&spawnCalls); got != 1 {
		t.Errorf("spawn called %d times, want exactly 1", got)
	}
	if !daemonHealthy(port) {
		t.Errorf("daemon on port %s not healthy after ensureDaemonRunning returned", port)
	}
}

// TestEnsureDaemonRunningConcurrentCallersSpawnOnce proves the sp008 Task 7
// edge case: two (or more) requests needing the same daemon at once must
// produce a SINGLE spawn, not two — the double-checked-locking race guard.
func TestEnsureDaemonRunningConcurrentCallersSpawnOnce(t *testing.T) {
	port := freePort(t)

	var mu sync.Mutex
	var spawnCalls int32
	spawn := func() error {
		atomic.AddInt32(&spawnCalls, 1)
		startStubDaemon(t, port)
		return nil
	}

	const n = 8
	var wg sync.WaitGroup
	errs := make([]error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs[i] = ensureDaemonRunning(&mu, port, spawn)
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("caller %d: ensureDaemonRunning: %v", i, err)
		}
	}
	if got := atomic.LoadInt32(&spawnCalls); got != 1 {
		t.Errorf("spawn called %d times across %d concurrent callers, want exactly 1", got, n)
	}
}

// TestEnsureDaemonRunningSpawnErrorReturnsWithoutWaiting proves a spawn
// failure (e.g. binary absent) is surfaced immediately as an error, not
// masked or retried into the full health-wait timeout.
func TestEnsureDaemonRunningSpawnErrorReturnsWithoutWaiting(t *testing.T) {
	port := freePort(t)
	var mu sync.Mutex
	wantErr := &daemonError{msg: "stub-binary-not-found"}
	spawn := func() error { return wantErr }

	start := time.Now()
	err := ensureDaemonRunning(&mu, port, spawn)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("ensureDaemonRunning: want error when spawn fails, got nil")
	}
	if !strings.Contains(err.Error(), "stub-binary-not-found") {
		t.Errorf("error = %q, want to contain spawn's error", err.Error())
	}
	if elapsed > time.Second {
		t.Errorf("ensureDaemonRunning took %v after a spawn error, want near-immediate return (no health-wait)", elapsed)
	}
}

// TestEnsureDaemonRunningTimesOutWhenNeverHealthy proves a spawn that
// "succeeds" but never actually brings the daemon up is bounded, not an
// infinite wait (sp008 Task 7 edge case: daemon slow to become healthy ->
// wait with timeout). daemonSpawnWait/daemonSpawnPoll are shortened for this
// test so it doesn't cost the production 10s budget.
func TestEnsureDaemonRunningTimesOutWhenNeverHealthy(t *testing.T) {
	origWait, origPoll := daemonSpawnWait, daemonSpawnPoll
	daemonSpawnWait, daemonSpawnPoll = 300*time.Millisecond, 20*time.Millisecond
	t.Cleanup(func() { daemonSpawnWait, daemonSpawnPoll = origWait, origPoll })

	port := freePort(t)
	var mu sync.Mutex
	spawn := func() error { return nil } // "succeeds" but never binds the port

	start := time.Now()
	err := ensureDaemonRunning(&mu, port, spawn)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("ensureDaemonRunning: want timeout error, got nil")
	}
	if elapsed < daemonSpawnWait {
		t.Errorf("ensureDaemonRunning returned after %v, want to have waited at least %v", elapsed, daemonSpawnWait)
	}
	if elapsed > 2*daemonSpawnWait {
		t.Errorf("ensureDaemonRunning took %v, want bounded near %v", elapsed, daemonSpawnWait)
	}
}

// TestProxyAndStripFrameHeadersRemovesXFrameOptions proves the poc006
// residual: if an upstream page (d2-router's proxied d2 --watch page in
// production) emits a frame-blocking header, preview-d's own proxy strips
// it from what it serves back — the sp008 Task 7 success criteria "if ft002
// emits a frame-blocking header ... the proxy strips it" and its test_plan
// ("stub sends X-Frame-Options: DENY; proxied response has it removed").
// Tested directly against an httptest upstream stub, independent of any
// daemon spawn/health machinery.
func TestProxyAndStripFrameHeadersRemovesXFrameOptions(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "frame-ancestors 'none'")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("<html>upstream d2 page</html>"))
	}))
	defer upstream.Close()

	rec := httptest.NewRecorder()
	proxyAndStripFrameHeaders(rec, upstream.URL)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("X-Frame-Options"); got != "" {
		t.Errorf("X-Frame-Options = %q, want stripped (empty)", got)
	}
	if got := rec.Header().Get("Content-Security-Policy"); got != "" {
		t.Errorf("Content-Security-Policy = %q, want stripped (empty)", got)
	}
	if !strings.Contains(rec.Body.String(), "upstream d2 page") {
		t.Errorf("body not proxied through: %s", rec.Body.String())
	}
}

// TestProxyAndStripFrameHeadersPassesThroughOtherHeaders proves the strip is
// scoped to frame-blocking headers only — an unrelated header (and the
// upstream's status code) survives the proxy untouched.
func TestProxyAndStripFrameHeadersPassesThroughOtherHeaders(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Custom-Marker", "keep-me")
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte("not found upstream"))
	}))
	defer upstream.Close()

	rec := httptest.NewRecorder()
	proxyAndStripFrameHeaders(rec, upstream.URL)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 (upstream's own status passed through)", rec.Code)
	}
	if got := rec.Header().Get("X-Custom-Marker"); got != "keep-me" {
		t.Errorf("X-Custom-Marker = %q, want passed through unchanged", got)
	}
}

// TestProxyAndStripFrameHeadersUpstreamUnreachable proves an unreachable
// upstream degrades to a safe "backend unavailable" 200 response, never a
// panic or a raw 502 that would render as a broken iframe (sp008 Task 7
// edge case: target daemon unavailable -> a graceful preview).
func TestProxyAndStripFrameHeadersUpstreamUnreachable(t *testing.T) {
	rec := httptest.NewRecorder()
	proxyAndStripFrameHeaders(rec, "http://127.0.0.1:1/unreachable")

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (graceful fallback)", rec.Code)
	}
	if !strings.Contains(strings.ToLower(rec.Body.String()), "unavailable") {
		t.Errorf("body missing 'unavailable' marker: %s", rec.Body.String())
	}
}

// TestHandleOpenWrongMethodRejected proves method-parity with the other
// routes (/status, /stop, /file/<path>): a non-POST /open is 405.
func TestHandleOpenWrongMethodRejected(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/open", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /open: status %d, want 405", rec.Code)
	}
}

// TestHandleOpenBadBodyReturns400 proves malformed JSON never reaches
// resolveInRoot or exec — the sp008-wide anti-pattern "no panic in
// handlers" plus this task's "no raw input to subprocess".
func TestHandleOpenBadBodyReturns400(t *testing.T) {
	logPath := newFakeNvimOnPath(t)
	t.Setenv("NVIM", "/tmp/fake-nvim-socket")
	srv := newTestServer(t)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/open", bytes.NewReader([]byte("{not json")))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("POST /open (bad body): status %d, want 400", rec.Code)
	}
	if _, err := os.Stat(logPath); !os.IsNotExist(err) {
		t.Errorf("fake nvim was invoked for a malformed body (log exists at %q)", logPath)
	}
}

// ── sp008 Task 7: akm/d2 iframe embed + lazy-spawn — full handler tests ────

// withAkmGraphSpawn overrides the package-level akmGraphSpawn test seam for
// the duration of the test and restores the original on cleanup.
func withAkmGraphSpawn(t *testing.T, fn func(root string) error) {
	t.Helper()
	orig := akmGraphSpawn
	akmGraphSpawn = fn
	t.Cleanup(func() { akmGraphSpawn = orig })
}

// withD2RouterSpawn is withAkmGraphSpawn's counterpart for d2RouterSpawn.
func withD2RouterSpawn(t *testing.T, fn func() error) {
	t.Helper()
	orig := d2RouterSpawn
	d2RouterSpawn = fn
	t.Cleanup(func() { d2RouterSpawn = orig })
}

// akmZettelServer builds a Server whose root has a docs/notes/<name>.md
// zettel fixture, returning the server and the /file/ request path for it.
func akmZettelServer(t *testing.T, name string) (*Server, string) {
	t.Helper()
	root := t.TempDir()
	notesDir := filepath.Join(root, "docs", "notes")
	if err := os.MkdirAll(notesDir, 0o755); err != nil {
		t.Fatalf("mkdir docs/notes: %v", err)
	}
	if err := os.WriteFile(filepath.Join(notesDir, name+".md"), []byte("---\naliases: [x]\n---\n# hi\n"), 0o644); err != nil {
		t.Fatalf("write zettel fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return srv, "/file/docs/notes/" + name + ".md"
}

// TestHandleFileAkmZettelEmbedsCrossOriginIframe proves the sp008 Task 7
// success criteria core case: GET /file/<akm-zettel> resolves to a page
// embedding a cross-origin <iframe> whose src targets the healthy
// akm-graph's own port directly (poc006: no proxying needed, akm-graph
// emits zero frame-blocking headers) — the test_plan's "/file/<akm-id>
// response embeds an iframe whose src targets that port".
func TestHandleFileAkmZettelEmbedsCrossOriginIframe(t *testing.T) {
	port := freePort(t)
	t.Setenv("AKM_GRAPH_PORT", port)
	startStubDaemon(t, port) // already healthy -- no spawn should occur

	withAkmGraphSpawn(t, func(root string) error {
		t.Fatal("akm-graph spawn invoked despite daemon already healthy")
		return nil
	})

	srv, reqPath := akmZettelServer(t, "us001")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, reqPath, nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s: status %d, want 200 (body: %s)", reqPath, rec.Code, rec.Body.String())
	}
	wantSrc := "http://127.0.0.1:" + port + "/"
	if !strings.Contains(rec.Body.String(), `<iframe src="`+wantSrc) {
		t.Errorf("body missing iframe targeting %q; body=%s", wantSrc, rec.Body.String())
	}
}

// TestHandleFileAkmZettelLazySpawnsSingleDaemonUnderConcurrency proves the
// sp008 Task 7 lazy-spawn + spawn-race success criteria end-to-end: the
// daemon isn't running, N concurrent /file/<akm-zettel> requests all need
// it, the handler spawns it exactly once (spy), and every request still
// gets a working embed once the daemon becomes healthy.
func TestHandleFileAkmZettelLazySpawnsSingleDaemonUnderConcurrency(t *testing.T) {
	port := freePort(t)
	t.Setenv("AKM_GRAPH_PORT", port)

	var spawnCalls int32
	withAkmGraphSpawn(t, func(root string) error {
		atomic.AddInt32(&spawnCalls, 1)
		startStubDaemon(t, port)
		return nil
	})

	srv, reqPath := akmZettelServer(t, "us002")

	const n = 5
	var wg sync.WaitGroup
	codes := make([]int, n)
	bodies := make([]string, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodGet, reqPath, nil)
			srv.Handler().ServeHTTP(rec, req)
			codes[i] = rec.Code
			bodies[i] = rec.Body.String()
		}(i)
	}
	wg.Wait()

	wantSrc := "http://127.0.0.1:" + port + "/"
	for i := 0; i < n; i++ {
		if codes[i] != http.StatusOK {
			t.Errorf("request %d: status %d, want 200 (body: %s)", i, codes[i], bodies[i])
		}
		if !strings.Contains(bodies[i], `<iframe src="`+wantSrc) {
			t.Errorf("request %d: body missing iframe targeting %q; body=%s", i, wantSrc, bodies[i])
		}
	}
	if got := atomic.LoadInt32(&spawnCalls); got != 1 {
		t.Errorf("akm-graph spawn called %d times across %d concurrent requests, want exactly 1", got, n)
	}
}

// TestHandleFileAkmZettelBackendUnavailableWhenSpawnFails proves the sp008
// Task 7 edge case: the target daemon binary is absent (spawn fails) ->
// preview-d surfaces a "backend unavailable" preview (200 HTML), not a
// broken iframe pointing at a dead origin.
func TestHandleFileAkmZettelBackendUnavailableWhenSpawnFails(t *testing.T) {
	port := freePort(t)
	t.Setenv("AKM_GRAPH_PORT", port)
	withAkmGraphSpawn(t, func(root string) error {
		return &daemonError{msg: "akm-graph-d: not found on PATH"}
	})

	srv, reqPath := akmZettelServer(t, "us003")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, reqPath, nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (graceful fallback, body: %s)", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "<iframe") {
		t.Errorf("body contains an iframe despite backend being unavailable: %s", rec.Body.String())
	}
	if !strings.Contains(strings.ToLower(rec.Body.String()), "unavailable") {
		t.Errorf("body missing 'unavailable' marker: %s", rec.Body.String())
	}
}

// d2FileServer builds a Server whose root has a top-level fixture.d2 file,
// returning the server, the /file/ request path, and the file's absolute
// (symlink-resolved) path as d2-router's /api/resolve would receive it.
func d2FileServer(t *testing.T) (srv *Server, reqPath, absPath string) {
	t.Helper()
	root := t.TempDir()
	target := filepath.Join(root, "diagram.d2")
	if err := os.WriteFile(target, []byte("a -> b\n"), 0o644); err != nil {
		t.Fatalf("write d2 fixture: %v", err)
	}
	abs, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatalf("EvalSymlinks fixture: %v", err)
	}
	s, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return s, "/file/diagram.d2", abs
}

// startStubD2Router binds a stub d2-router to port answering /api/status
// (health) and /api/resolve?path=<abs> (ft002 api_surface) with the given
// resolved URL, so tests can drive the full lazy-spawn + resolve +
// iframe-target chain without a real d2-router-d binary.
func startStubD2Router(t *testing.T, port, wantAbsPath, resolvedURL string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		t.Fatalf("bind stub d2-router on port %s: %v", port, err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/api/resolve", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("path"); got != wantAbsPath {
			http.Error(w, "unexpected path", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"project":"dotfiles","file":"diagram.d2","url":%q}`, resolvedURL)
	})
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
}

// TestHandleFileD2FileEmbedsViaD2EmbedRoute proves the sp008 Task 7 success
// criteria for .d2 files: the /file/<path> response embeds an iframe whose
// src is preview-d's OWN /d2embed/ route (not a raw cross-origin link to
// d2-router) — poc006's header-strip residual requires preview-d to proxy
// this page itself, so it can't be a bare cross-origin iframe like the akm
// case.
func TestHandleFileD2FileEmbedsViaD2EmbedRoute(t *testing.T) {
	port := freePort(t)
	t.Setenv("D2_ROUTER_PORT", port)

	srv, reqPath, absPath := d2FileServer(t)
	startStubD2Router(t, port, absPath, "http://127.0.0.1:"+port+"/dotfiles/diagram.d2")

	withD2RouterSpawn(t, func() error {
		t.Fatal("d2-router spawn invoked despite daemon already healthy")
		return nil
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, reqPath, nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s: status %d, want 200 (body: %s)", reqPath, rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `<iframe src="/d2embed/diagram.d2"`) {
		t.Errorf("body missing same-origin d2embed iframe; body=%s", rec.Body.String())
	}
}

// TestHandleD2EmbedProxiesResolvedURLAndStripsFrameHeaders proves the
// /d2embed/ route itself: it lazy-spawns/health-checks d2-router, resolves
// the abs path via ft002's GET /api/resolve, then proxies that resolved
// page's response — stripping any frame-blocking header the upstream sent
// (sp008 Task 7 test_plan header-strip case, end-to-end through the real
// route this time rather than proxyAndStripFrameHeaders in isolation).
func TestHandleD2EmbedProxiesResolvedURLAndStripsFrameHeaders(t *testing.T) {
	// The actual d2 page content lives on a THIRD server (the thing
	// d2-router's resolved URL points at) so the stub d2-router's own
	// /api/resolve handler and the final proxied page are independently
	// verifiable.
	d2Page := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("<html>d2 diagram</html>"))
	}))
	defer d2Page.Close()

	port := freePort(t)
	t.Setenv("D2_ROUTER_PORT", port)

	srv, _, absPath := d2FileServer(t)
	startStubD2Router(t, port, absPath, d2Page.URL)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/d2embed/diagram.d2", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /d2embed/diagram.d2: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("X-Frame-Options"); got != "" {
		t.Errorf("X-Frame-Options = %q, want stripped", got)
	}
	if !strings.Contains(rec.Body.String(), "d2 diagram") {
		t.Errorf("body not proxied from resolved d2 page: %s", rec.Body.String())
	}
}

// TestHandleD2EmbedOutOfRootRejected proves /d2embed/ re-validates its path
// through the same root-jail as /file/<path> — it never trusts the iframe
// src as pre-validated (sp008 Task 2 anti-pattern: no raw webview input
// reaches network I/O unvalidated). The handler is called directly,
// bypassing http.ServeMux (which would otherwise 301-redirect an unclean
// "/d2embed/../../etc/passwd" request before our own code runs — a stdlib
// path-cleaning quirk, not the security boundary being proven here; see
// TestHandleFileRejectsDotDotEscapeAndReadsNothing in server_test.go for
// the same rationale on /file/<path>).
func TestHandleD2EmbedOutOfRootRejected(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/d2embed/../../etc/passwd", nil)
	srv.handleD2Embed(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("GET /d2embed/ (out-of-root): status %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
}

// TestHandleFileD2BackendUnavailableWhenSpawnFails proves the same "backend
// unavailable, not a broken iframe" edge case as the akm test, but for the
// d2 side: spawn fails -> /file/<path>.d2 returns a graceful 200 preview
// with no iframe at all.
func TestHandleFileD2BackendUnavailableWhenSpawnFails(t *testing.T) {
	port := freePort(t)
	t.Setenv("D2_ROUTER_PORT", port)
	withD2RouterSpawn(t, func() error {
		return &daemonError{msg: "d2-router-d: not found on PATH"}
	})

	srv, reqPath, _ := d2FileServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, reqPath, nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (graceful fallback, body: %s)", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "<iframe") {
		t.Errorf("body contains an iframe despite backend being unavailable: %s", rec.Body.String())
	}
	if !strings.Contains(strings.ToLower(rec.Body.String()), "unavailable") {
		t.Errorf("body missing 'unavailable' marker: %s", rec.Body.String())
	}
}
