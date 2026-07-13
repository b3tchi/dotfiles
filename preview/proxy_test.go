package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
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
