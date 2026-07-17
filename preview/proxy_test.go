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

// TestHandleOpenWithSlotRoutesToSlotNvimAddr proves the sp009 Task 2 core
// case: when the request body carries a "slot" that has a registered nvim
// address (via SlotManager.SetNvimAddr, sp009 Task 1), handleOpen targets
// THAT address rather than the global $NVIM env var — the per-slot routing
// this task adds. $NVIM is deliberately left unset here so a fallback to it
// would make the assertion on --server's value fail.
func TestHandleOpenWithSlotRoutesToSlotNvimAddr(t *testing.T) {
	logPath := newFakeNvimOnPath(t)
	t.Setenv("NVIM", "")

	root := t.TempDir()
	target := filepath.Join(root, "note.md")
	if err := os.WriteFile(target, []byte("# hi"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	srv.slots.SetNvimAddr(3, "/tmp/slot3-nvim-socket")

	reqBody, _ := json.Marshal(map[string]any{"path": "note.md", "slot": 3})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/open", bytes.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /open (slot 3): status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	wantAbs, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatalf("EvalSymlinks fixture: %v", err)
	}
	argv := readArgvLog(t, logPath)
	if !containsArg(argv, "--server") {
		t.Errorf("nvim argv %v missing --server", argv)
	}
	if !containsArg(argv, "/tmp/slot3-nvim-socket") {
		t.Errorf("nvim argv %v missing --server value from slot 3's registered addr", argv)
	}
	if !containsArg(argv, "--remote") {
		t.Errorf("nvim argv %v missing --remote", argv)
	}
	if !containsArg(argv, wantAbs) {
		t.Errorf("nvim argv %v missing abs path %q", argv, wantAbs)
	}
}

// TestHandleOpenWithUnboundSlotReturns424NoExec proves the sp009 Task 2 edge
// case: a slot with no registered nvim address (no SetNvimAddr ever landed
// for it) must fail closed with 424 Failed Dependency and never invoke the
// nvim subprocess — mirroring the existing $NVIM-unset behavior, but scoped
// per-slot rather than falling back to the global env var.
func TestHandleOpenWithUnboundSlotReturns424NoExec(t *testing.T) {
	logPath := newFakeNvimOnPath(t)
	t.Setenv("NVIM", "/tmp/fake-global-nvim-socket") // set globally, must NOT be used as a fallback

	root := t.TempDir()
	target := filepath.Join(root, "note.md")
	if err := os.WriteFile(target, []byte("# hi"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	// Slot 7 is never registered via SetNvimAddr.

	reqBody, _ := json.Marshal(map[string]any{"path": "note.md", "slot": 7})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/open", bytes.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusFailedDependency {
		t.Fatalf("POST /open (unbound slot 7): status %d, want 424 (body: %s)", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(logPath); !os.IsNotExist(err) {
		t.Errorf("fake nvim was invoked for an unbound slot (log exists at %q)", logPath)
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

// TestHandleFileAkmZettelWithSlotAppendsSlotQuery proves the sp009 Task 6
// success criteria: GET /file/<akm-zettel>?slot=N threads N through to the
// akm-graph iframe's src as ?slot=N, so a click inside the embedded akm-graph
// carries the /preview<N> window's slot back through /open.
func TestHandleFileAkmZettelWithSlotAppendsSlotQuery(t *testing.T) {
	port := freePort(t)
	t.Setenv("AKM_GRAPH_PORT", port)
	startStubDaemon(t, port)

	srv, reqPath := akmZettelServer(t, "us010")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, reqPath+"?slot=3", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s?slot=3: status %d, want 200 (body: %s)", reqPath, rec.Code, rec.Body.String())
	}
	wantSrc := "http://127.0.0.1:" + port + "/?slot=3"
	if !strings.Contains(rec.Body.String(), `<iframe src="`+wantSrc) {
		t.Errorf("body missing iframe targeting %q; body=%s", wantSrc, rec.Body.String())
	}
}

// TestHandleFileAkmZettelWithoutSlotOmitsSlotQuery proves the sp009 Task 6
// back-compat success criteria: a standalone GET /file/<akm-zettel> with no
// ?slot omits the slot param from the iframe src entirely.
func TestHandleFileAkmZettelWithoutSlotOmitsSlotQuery(t *testing.T) {
	port := freePort(t)
	t.Setenv("AKM_GRAPH_PORT", port)
	startStubDaemon(t, port)

	srv, reqPath := akmZettelServer(t, "us011")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, reqPath, nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s: status %d, want 200 (body: %s)", reqPath, rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "slot=") {
		t.Errorf("body contains a slot query param despite no ?slot on the request; body=%s", rec.Body.String())
	}
}

// TestHandleFileAkmZettelNonNumericSlotIgnored proves the sp009 Task 6 edge
// case: a non-numeric ?slot value is treated as absent (a routing hint,
// never a 400) — the iframe src omits the slot param just like no ?slot at
// all, and the request still succeeds.
func TestHandleFileAkmZettelNonNumericSlotIgnored(t *testing.T) {
	port := freePort(t)
	t.Setenv("AKM_GRAPH_PORT", port)
	startStubDaemon(t, port)

	srv, reqPath := akmZettelServer(t, "us012")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, reqPath+"?slot=abc", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s?slot=abc: status %d, want 200 (body: %s)", reqPath, rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "slot=") {
		t.Errorf("body contains a slot query param for a non-numeric ?slot; body=%s", rec.Body.String())
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

// TestHandleFileD2FileEmbedsD2RouterDirectly proves the .d2 embed points
// DIRECTLY at d2-router's own resolved URL, exactly as renderAkmEmbed does
// for akm zettels — preview-d proxies nothing.
//
// This is what makes live preview work. `d2 --watch` ships an empty
// #d2-svg-container and pushes the SVG over a websocket that watch.js opens
// at a root-relative /{project}/{file}/watch. Only a same-origin iframe can
// reach it, so the document, watch.js and that socket must all share
// d2-router's origin. Routing the document through a preview-d proxy stranded
// the assets and the socket on the wrong origin and rendered the diagram
// blank (dotfiles-ars).
func TestHandleFileD2FileEmbedsD2RouterDirectly(t *testing.T) {
	port := freePort(t)
	t.Setenv("D2_ROUTER_PORT", port)

	srv, reqPath, absPath := d2FileServer(t)
	resolved := "http://127.0.0.1:" + port + "/dotfiles/diagram.d2"
	startStubD2Router(t, port, absPath, resolved)

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
	if !strings.Contains(rec.Body.String(), `<iframe src="`+resolved+`"`) {
		t.Errorf("body missing direct cross-origin iframe at %s; body=%s", resolved, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "/d2embed/") {
		t.Errorf("body still points at the removed same-origin proxy route: %s", rec.Body.String())
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

// ── sp011 Task 3: POST /api/highlight forward (ft004's inbound surface) ──

// highlightCall is the decoded shape of one captured POST /api/highlight
// body — sp011 Task 3 test_plan: "stub akm-graph daemon capturing
// /api/highlight bodies".
type highlightCall struct {
	Path string `json:"path"`
	Slot int    `json:"slot"`
}

// highlightCapture records every POST /api/highlight body a stub daemon
// receives, guarded by a mutex since the test's assertion goroutine and the
// stub's request-handling goroutine touch it concurrently.
type highlightCapture struct {
	mu    sync.Mutex
	calls []highlightCall
}

func (c *highlightCapture) add(call highlightCall) {
	c.mu.Lock()
	c.calls = append(c.calls, call)
	c.mu.Unlock()
}

func (c *highlightCapture) len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.calls)
}

func (c *highlightCapture) last() highlightCall {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls[len(c.calls)-1]
}

// startStubHighlightDaemon binds 127.0.0.1:port and answers POST
// /api/highlight, decoding and recording every body into capture and
// replying with status (a minimal {"id":"stub","slot":N} body on a 2xx,
// an empty body otherwise) — enough to drive forwardAkmHighlight's success
// and failure paths without a real akm-graph-d binary.
func startStubHighlightDaemon(t *testing.T, port string, status int, capture *highlightCapture) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		t.Fatalf("bind stub akm-graph highlight daemon on port %s: %v", port, err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/highlight", func(w http.ResponseWriter, r *http.Request) {
		var body highlightCall
		_ = json.NewDecoder(r.Body).Decode(&body)
		capture.add(body)
		w.WriteHeader(status)
		if status >= 200 && status < 300 {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"id":"stub","slot":%d}`, body.Slot)
		}
	})
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
}

// TestForwardAkmHighlightPostsRelativizedPathAndSlot proves the core
// forward case: forwardAkmHighlight POSTs exactly the given root-relative
// path and slot to akm-graph-d's /api/highlight and reports success on 200
// (sp011 Task 3 test_plan: "akm path -> POST with relativized path +
// slot").
func TestForwardAkmHighlightPostsRelativizedPathAndSlot(t *testing.T) {
	port := freePort(t)
	t.Setenv("AKM_GRAPH_PORT", port)
	capture := &highlightCapture{}
	startStubHighlightDaemon(t, port, http.StatusOK, capture)

	if err := forwardAkmHighlight("docs/notes/us010.md", 2); err != nil {
		t.Fatalf("forwardAkmHighlight: %v", err)
	}

	if got := capture.len(); got != 1 {
		t.Fatalf("stub received %d POSTs, want 1", got)
	}
	call := capture.last()
	if call.Path != "docs/notes/us010.md" || call.Slot != 2 {
		t.Errorf("captured call = %+v, want {docs/notes/us010.md 2}", call)
	}
}

// TestForwardAkmHighlightNon2xxReturnsError proves a non-2xx response (the
// daemon rejecting or erroring on the request) is surfaced as an error, not
// swallowed — the caller (handlePreviewSet) needs this to drive its
// akm->akm fallback-broadcast decision.
func TestForwardAkmHighlightNon2xxReturnsError(t *testing.T) {
	port := freePort(t)
	t.Setenv("AKM_GRAPH_PORT", port)
	startStubHighlightDaemon(t, port, http.StatusInternalServerError, &highlightCapture{})

	if err := forwardAkmHighlight("docs/notes/us010.md", 1); err == nil {
		t.Fatal("forwardAkmHighlight: want error on 500, got nil")
	}
}

// TestForwardAkmHighlightConnectionRefusedReturnsError proves the
// daemon-down case (nothing listening on the target port) is a plain error,
// never a panic or an unbounded hang — freePort reserves and releases a
// port so nothing answers it.
func TestForwardAkmHighlightConnectionRefusedReturnsError(t *testing.T) {
	port := freePort(t) // reserved then released; nothing is listening
	t.Setenv("AKM_GRAPH_PORT", port)

	if err := forwardAkmHighlight("docs/notes/us010.md", 1); err == nil {
		t.Fatal("forwardAkmHighlight: want error on connection refused, got nil")
	}
}

// TestHandlePreviewSetForwardsHighlightOnlyForAkmPaths proves the sp011
// Task 3 success criteria end-to-end through the real /preview<N> handler:
// a non-akm path never triggers a highlight POST, and an akm path triggers
// exactly one, carrying the relativized path and the slot (test_plan: "akm
// path -> POST with relativized path + slot; non-akm -> no call").
func TestHandlePreviewSetForwardsHighlightOnlyForAkmPaths(t *testing.T) {
	root := t.TempDir()
	notesDir := filepath.Join(root, "docs", "notes")
	if err := os.MkdirAll(notesDir, 0o755); err != nil {
		t.Fatalf("mkdir docs/notes: %v", err)
	}
	if err := os.WriteFile(filepath.Join(notesDir, "a.md"), []byte("# a"), 0o644); err != nil {
		t.Fatalf("write zettel fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "code.go"), []byte("package main"), 0o644); err != nil {
		t.Fatalf("write code fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	port := freePort(t)
	t.Setenv("AKM_GRAPH_PORT", port)
	capture := &highlightCapture{}
	startStubHighlightDaemon(t, port, http.StatusOK, capture)

	// Non-akm path: no highlight call at all.
	rec := httptest.NewRecorder()
	reqBody, _ := json.Marshal(map[string]string{"path": "code.go"})
	req := httptest.NewRequest(http.MethodPost, "/preview1", bytes.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST /preview1 code.go: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if got := capture.len(); got != 0 {
		t.Fatalf("non-akm POST /preview1: stub received %d highlight calls, want 0", got)
	}

	// Akm path: exactly one highlight call, relativized path + slot.
	rec = httptest.NewRecorder()
	reqBody, _ = json.Marshal(map[string]string{"path": "docs/notes/a.md"})
	req = httptest.NewRequest(http.MethodPost, "/preview1", bytes.NewReader(reqBody))
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST /preview1 docs/notes/a.md: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if got := capture.len(); got != 1 {
		t.Fatalf("akm POST /preview1: stub received %d highlight calls, want 1", got)
	}
	call := capture.last()
	if call.Path != "docs/notes/a.md" || call.Slot != 1 {
		t.Errorf("captured call = %+v, want {docs/notes/a.md 1}", call)
	}
}




