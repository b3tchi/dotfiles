package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// ── fake ChildManager helpers ─────────────────────────────────────────────────

// makeFakeCM returns a ChildManager with a pre-populated in-memory entry map
// (no real processes spawned). Used to avoid the TestHelperProcess overhead.
func makeFakeCM(children map[string]Child) *ChildManager {
	cfg := config{
		RouterPort:    "4800",
		RegistryPath:  "",
		D2Bin:         "false", // won't be invoked
		ChildPortBase: "4801",
		IdleTimeout:   "30m",
	}
	cm := NewChildManager(cfg, nil)
	for key, ch := range children {
		ch := ch // copy
		ch.Key = key
		e := &childEntry{
			child: &ch,
			done:  make(chan struct{}),
		}
		// closed done — child is "not running" but map entry exists for test
		cm.entries[key] = e
	}
	return cm
}

// injectEntry plants a live childEntry without spawning a real process.
// The done channel is open (as if the process is still alive).
func injectEntry(cm *ChildManager, key string, ch Child) {
	ch.Key = key
	e := &childEntry{
		child: &ch,
		done:  make(chan struct{}), // open — "running"
		stop:  func() {},
	}
	cm.mu.Lock()
	cm.entries[key] = e
	cm.mu.Unlock()
}

// ── /api/status ───────────────────────────────────────────────────────────────

func TestAPIStatus_empty(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: want 200, got %d", rr.Code)
	}
	ct := rr.Header().Get("Content-Type")
	if !strings.HasPrefix(ct, "application/json") {
		t.Errorf("status: want Content-Type application/json, got %q", ct)
	}

	var got []statusEntry
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("status: unmarshal: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("status: want empty array, got %v", got)
	}
}

func TestAPIStatus_golden(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)

	fixedTime := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	injectEntry(cm, "proj/a.d2", Child{
		Port:       5001,
		PID:        1234,
		Clients:    2,
		LastActive: fixedTime,
		LastError:  nil,
	})
	injectEntry(cm, "proj/b.d2", Child{
		Port:       5002,
		PID:        5678,
		Clients:    0,
		LastActive: fixedTime,
		LastError:  errors.New("exit status 1"),
	})

	h := NewAPIHandler(cm, Registry{}, "4800")
	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: want 200, got %d: %s", rr.Code, rr.Body.String())
	}

	var got []statusEntry
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("status: unmarshal: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("status: want 2 entries, got %d", len(got))
	}

	// Sorted by key: proj/a.d2 before proj/b.d2
	a := got[0]
	if a.Project != "proj" || a.File != "a.d2" {
		t.Errorf("entry0: want proj/a.d2, got %s/%s", a.Project, a.File)
	}
	if a.Port != 5001 || a.PID != 1234 || a.Clients != 2 {
		t.Errorf("entry0: fields wrong: %+v", a)
	}
	if a.LastError != nil {
		t.Errorf("entry0: want nil lastError, got %q", *a.LastError)
	}
	if a.LastCompile == "" {
		t.Errorf("entry0: lastCompile empty")
	}

	b := got[1]
	if b.Project != "proj" || b.File != "b.d2" {
		t.Errorf("entry1: want proj/b.d2, got %s/%s", b.Project, b.File)
	}
	if b.LastError == nil || *b.LastError != "exit status 1" {
		t.Errorf("entry1: want lastError 'exit status 1', got %v", b.LastError)
	}
}

func TestAPIStatus_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/status", nil)
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusMethodNotAllowed {
			t.Errorf("status %s: want 405, got %d", method, rr.Code)
		}
		if allow := rr.Header().Get("Allow"); allow != "GET" {
			t.Errorf("status %s: want Allow: GET, got %q", method, allow)
		}
	}
}

// ── /api/reload ────────────────────────────────────────────────────────────

func TestAPIReload_notRunning(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	req := httptest.NewRequest(http.MethodPost, "/api/reload/proj/foo.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("reload not-running: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPIReload_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	req := httptest.NewRequest(http.MethodGet, "/api/reload/proj/foo.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("reload GET: want 405, got %d", rr.Code)
	}
	if allow := rr.Header().Get("Allow"); allow != "POST" {
		t.Errorf("reload GET: want Allow: POST, got %q", allow)
	}
}

// TestAPIReload_success uses a real child (TestHelperProcess) to verify
// the Reload path triggers chtimes without error.
func TestAPIReload_success(t *testing.T) {
	tmpDir := t.TempDir()
	// Create a watched file so Chtimes has a real target.
	watchedFile := tmpDir + "/test.d2"
	if err := os.WriteFile(watchedFile, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	cm, stop := spawnFakeChild(t, "proj/test.d2", watchedFile)
	defer stop()

	h := NewAPIHandler(cm, Registry{}, "4800")
	req := httptest.NewRequest(http.MethodPost, "/api/reload/proj/test.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("reload success: want 200, got %d: %s", rr.Code, rr.Body.String())
	}
}

// ── /api/restart ───────────────────────────────────────────────────────────

func TestAPIRestart_notRunning(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	req := httptest.NewRequest(http.MethodPost, "/api/restart/proj/foo.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("restart not-running: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPIRestart_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	for _, method := range []string{http.MethodGet, http.MethodPut} {
		req := httptest.NewRequest(method, "/api/restart/proj/foo.d2", nil)
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusMethodNotAllowed {
			t.Errorf("restart %s: want 405, got %d", method, rr.Code)
		}
		if allow := rr.Header().Get("Allow"); allow != "POST" {
			t.Errorf("restart %s: want Allow: POST, got %q", method, allow)
		}
	}
}

// ── /api/stop ─────────────────────────────────────────────────────────────

func TestAPIStop_notRunning(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	req := httptest.NewRequest(http.MethodPost, "/api/stop/proj/foo.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("stop not-running: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPIStop_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	req := httptest.NewRequest(http.MethodGet, "/api/stop/proj/foo.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("stop GET: want 405, got %d", rr.Code)
	}
	if allow := rr.Header().Get("Allow"); allow != "POST" {
		t.Errorf("stop GET: want Allow: POST, got %q", allow)
	}
}

// TestAPIStop_success verifies POST /api/stop/<key> removes a running child.
func TestAPIStop_success(t *testing.T) {
	tmpDir := t.TempDir()
	watchedFile := tmpDir + "/test.d2"
	if err := os.WriteFile(watchedFile, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	cm, _ := spawnFakeChild(t, "proj/test.d2", watchedFile)
	// don't defer stop — the API call IS the stop

	h := NewAPIHandler(cm, Registry{}, "4800")
	req := httptest.NewRequest(http.MethodPost, "/api/stop/proj/test.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("stop success: want 200, got %d: %s", rr.Code, rr.Body.String())
	}

	// Verify child was removed from the map.
	snap := cm.Snapshot()
	if _, ok := snap["proj/test.d2"]; ok {
		t.Errorf("stop success: child still in map after stop")
	}
}

// ── /api/stop-all ────────────────────────────────────────────────────────────

func TestAPIStopAll_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(method, "/api/stop-all", nil)
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusMethodNotAllowed {
			t.Errorf("stop-all %s: want 405, got %d", method, rr.Code)
		}
		if allow := rr.Header().Get("Allow"); allow != "POST" {
			t.Errorf("stop-all %s: want Allow: POST, got %q", method, allow)
		}
	}
}

func TestAPIStopAll_success(t *testing.T) {
	tmpDir := t.TempDir()
	f1 := tmpDir + "/a.d2"
	f2 := tmpDir + "/b.d2"
	os.WriteFile(f1, []byte("a"), 0644) //nolint:errcheck
	os.WriteFile(f2, []byte("b"), 0644) //nolint:errcheck

	cm, _ := spawnFakeChild(t, "proj/a.d2", f1)
	// Inject second entry manually — avoids port conflict in test.
	injectEntry(cm, "proj/b.d2", Child{
		Port: 9999, PID: 99999,
		LastActive: time.Now(),
	})

	h := NewAPIHandler(cm, Registry{}, "4800")
	req := httptest.NewRequest(http.MethodPost, "/api/stop-all", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("stop-all: want 200, got %d: %s", rr.Code, rr.Body.String())
	}

	snap := cm.Snapshot()
	if len(snap) != 0 {
		t.Errorf("stop-all: want empty map, got %v", snap)
	}
}

// ── /api/resolve ─────────────────────────────────────────────────────────────

func TestAPIResolve_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800")

	req := httptest.NewRequest(http.MethodPost, "/api/resolve?path=/home/user/proj/a.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("resolve POST: want 405, got %d", rr.Code)
	}
	if allow := rr.Header().Get("Allow"); allow != "GET" {
		t.Errorf("resolve POST: want Allow: GET, got %q", allow)
	}
}

func TestAPIResolve_relativePath(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800")

	req := httptest.NewRequest(http.MethodGet, "/api/resolve?path=relative/path.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("resolve relative: want 400, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPIResolve_missingPath(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800")

	req := httptest.NewRequest(http.MethodGet, "/api/resolve", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("resolve missing path: want 400, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPIResolve_outsideProjects(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800")

	req := httptest.NewRequest(http.MethodGet, "/api/resolve?path=/tmp/other/file.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("resolve outside: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPIResolve_tableTests(t *testing.T) {
	// Registry with nested projects to test longest-prefix logic.
	reg := Registry{
		"dotfiles":      "/home/user/dotfiles",
		"dotfiles-docs": "/home/user/dotfiles/docs",
		"other":         "/home/user/other",
	}
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, reg, "4800")

	tests := []struct {
		name        string
		path        string
		wantStatus  int
		wantProject string
		wantFile    string
	}{
		{
			name:        "simple match",
			path:        "/home/user/dotfiles/network.d2",
			wantStatus:  200,
			wantProject: "dotfiles",
			wantFile:    "network.d2",
		},
		{
			name:        "nested longer prefix wins",
			path:        "/home/user/dotfiles/docs/arch.d2",
			wantStatus:  200,
			wantProject: "dotfiles-docs",
			wantFile:    "arch.d2",
		},
		{
			name:       "outside all projects",
			path:       "/tmp/rando/file.d2",
			wantStatus: 404,
		},
		{
			name:        "non-canonical .. that cleans back inside project → 200",
			path:        "/home/user/dotfiles/../dotfiles/x.d2",
			wantStatus:  200,
			wantProject: "dotfiles",
			wantFile:    "x.d2",
		},
		{
			name:       "traversal .. that escapes all projects → 404",
			path:       "/home/user/dotfiles/../../etc/passwd.d2",
			wantStatus: 404,
		},
		{
			name:       "deep traversal escaping to /etc → 404",
			path:       "/home/user/proj/../../../etc/passwd.d2",
			wantStatus: 404,
		},
		{
			name:       "relative path",
			path:       "relative/file.d2",
			wantStatus: 400,
		},
		{
			name:       "relative .. path stays 400 (not 404)",
			path:       "../../etc/passwd.d2",
			wantStatus: 400,
		},
		{
			name:       "empty path param",
			path:       "",
			wantStatus: 400,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			target := "/api/resolve"
			if tc.path != "" {
				target = fmt.Sprintf("/api/resolve?path=%s", tc.path)
			}
			req := httptest.NewRequest(http.MethodGet, target, nil)
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, req)

			if rr.Code != tc.wantStatus {
				t.Errorf("want %d, got %d: %s", tc.wantStatus, rr.Code, rr.Body.String())
			}

			if tc.wantStatus == 200 {
				var resp resolveResponse
				if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
					t.Fatalf("unmarshal: %v", err)
				}
				if resp.Project != tc.wantProject {
					t.Errorf("project: want %q, got %q", tc.wantProject, resp.Project)
				}
				if resp.File != tc.wantFile {
					t.Errorf("file: want %q, got %q", tc.wantFile, resp.File)
				}
				expectedURL := "http://127.0.0.1:4800/" + tc.wantProject + "/" + tc.wantFile
				if resp.URL != expectedURL {
					t.Errorf("url: want %q, got %q", expectedURL, resp.URL)
				}
			}
		})
	}
}

// TestAPIResolve_sshExcluded verifies that SSH-only registry entries are never
// matched (they are excluded at loadRegistry time and absent from the Registry).
// The test sets up an empty registry (as if all entries were SSH-only) and verifies
// that a path resolves to 404.
func TestAPIResolve_sshExcluded(t *testing.T) {
	// Empty registry — SSH projects were excluded at load time.
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	req := httptest.NewRequest(http.MethodGet, "/api/resolve?path=/remote/server/project/file.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("ssh excluded: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

// TestAPIResolve_traversalEscapesProject is the reviewer's verbatim repro: with
// registry {proj: /home/user/proj}, a ..-escaping path that path.Clean resolves
// OUTSIDE the project must 404, not 200 with a wrong-project match (ft002:38).
func TestAPIResolve_traversalEscapesProject(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800")

	// path.Clean("/home/user/proj/../../../etc/passwd.d2") == "/etc/passwd.d2",
	// which is outside proj → must be 404.
	req := httptest.NewRequest(http.MethodGet,
		"/api/resolve?path=/home/user/proj/../../../etc/passwd.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("traversal escaping proj: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

// TestAPIResolve_traversalCleansInside verifies the in-project ..-form: a path
// with ".." segments that path.Clean resolves back INSIDE the project still 200s.
func TestAPIResolve_traversalCleansInside(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800")

	// path.Clean("/home/user/proj/sub/../a.d2") == "/home/user/proj/a.d2" → 200.
	req := httptest.NewRequest(http.MethodGet,
		"/api/resolve?path=/home/user/proj/sub/../a.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("in-project ..: want 200, got %d: %s", rr.Code, rr.Body.String())
	}
	var resp resolveResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.Project != "proj" || resp.File != "a.d2" {
		t.Errorf("in-project ..: want proj/a.d2, got %s/%s", resp.Project, resp.File)
	}
}

// ── 405 matrix ───────────────────────────────────────────────────────────────

func TestAPI_405matrix(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800")

	tests := []struct {
		path        string
		allowMethod string
		badMethods  []string
	}{
		{
			path:        "/api/status",
			allowMethod: "GET",
			badMethods:  []string{"POST", "PUT", "DELETE", "PATCH"},
		},
		{
			path:        "/api/reload/proj/a.d2",
			allowMethod: "POST",
			badMethods:  []string{"GET", "PUT", "DELETE"},
		},
		{
			path:        "/api/restart/proj/a.d2",
			allowMethod: "POST",
			badMethods:  []string{"GET", "PUT", "DELETE"},
		},
		{
			path:        "/api/stop/proj/a.d2",
			allowMethod: "POST",
			badMethods:  []string{"GET", "PUT", "DELETE"},
		},
		{
			path:        "/api/stop-all",
			allowMethod: "POST",
			badMethods:  []string{"GET", "PUT", "DELETE"},
		},
		{
			path:        "/api/resolve?path=/home/user/proj/a.d2",
			allowMethod: "GET",
			badMethods:  []string{"POST", "PUT", "DELETE"},
		},
	}

	for _, tc := range tests {
		for _, method := range tc.badMethods {
			t.Run(tc.path+"/"+method, func(t *testing.T) {
				req := httptest.NewRequest(method, tc.path, nil)
				rr := httptest.NewRecorder()
				h.ServeHTTP(rr, req)

				if rr.Code != http.StatusMethodNotAllowed {
					t.Errorf("%s %s: want 405, got %d", method, tc.path, rr.Code)
				}
				if allow := rr.Header().Get("Allow"); allow != tc.allowMethod {
					t.Errorf("%s %s: want Allow: %s, got %q", method, tc.path, tc.allowMethod, allow)
				}
			})
		}
	}
}

// ── unknown path ─────────────────────────────────────────────────────────────

func TestAPI_unknownPath(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800")

	req := httptest.NewRequest(http.MethodGet, "/api/nonexistent", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("unknown path: want 404, got %d", rr.Code)
	}
}

// ── helpers ───────────────────────────────────────────────────────────────────

// spawnFakeChild spawns a real child using the TestHelperProcess fake d2 binary.
// Returns the ChildManager and a stop function.
func spawnFakeChild(t *testing.T, key, absPath string) (*ChildManager, func()) {
	t.Helper()
	cfg := config{
		RouterPort:    "4800",
		D2Bin:         helperBin(t),
		ChildPortBase: fmt.Sprintf("%d", freePort(t)),
		IdleTimeout:   "30m",
	}
	cm := NewChildManager(cfg, helperEnv())

	ch, err := cm.Ensure(key, absPath)
	if err != nil {
		t.Fatalf("spawnFakeChild: Ensure: %v", err)
	}
	_ = ch

	stop := func() {
		cm.Stop(key) //nolint:errcheck
	}
	return cm, stop
}
