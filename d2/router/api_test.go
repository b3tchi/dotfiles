package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
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
	h := NewAPIHandler(cm, Registry{}, "4800", "")

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

	h := NewAPIHandler(cm, Registry{}, "4800", "")
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
	h := NewAPIHandler(cm, Registry{}, "4800", "")

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
	h := NewAPIHandler(cm, Registry{}, "4800", "")

	req := httptest.NewRequest(http.MethodPost, "/api/reload/proj/foo.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("reload not-running: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPIReload_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800", "")

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

	h := NewAPIHandler(cm, Registry{}, "4800", "")
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
	h := NewAPIHandler(cm, Registry{}, "4800", "")

	req := httptest.NewRequest(http.MethodPost, "/api/restart/proj/foo.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("restart not-running: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPIRestart_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800", "")

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
	h := NewAPIHandler(cm, Registry{}, "4800", "")

	req := httptest.NewRequest(http.MethodPost, "/api/stop/proj/foo.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("stop not-running: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPIStop_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800", "")

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

	h := NewAPIHandler(cm, Registry{}, "4800", "")
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
	h := NewAPIHandler(cm, Registry{}, "4800", "")

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

	h := NewAPIHandler(cm, Registry{}, "4800", "")
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
	h := NewAPIHandler(cm, reg, "4800", "")

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
	h := NewAPIHandler(cm, reg, "4800", "")

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
	h := NewAPIHandler(cm, reg, "4800", "")

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
	h := NewAPIHandler(cm, reg, "4800", "")

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
	h := NewAPIHandler(cm, reg, "4800", "")

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
	h := NewAPIHandler(cm, Registry{}, "4800", "")

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
	h := NewAPIHandler(cm, reg, "4800", "")

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
	h := NewAPIHandler(cm, reg, "4800", "")

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
	h := NewAPIHandler(cm, reg, "4800", "")

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
		{
			path:        "/api/svg?path=/home/user/proj/a.d2",
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
	h := NewAPIHandler(cm, Registry{}, "4800", "")

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

// spawnFakeChildWithCache is spawnFakeChild plus an explicit SvgCacheDir, for
// /api/svg tests that need to know exactly where the child's Child.SVGPath
// will land (sp022 Task 1).
func spawnFakeChildWithCache(t *testing.T, key, absPath, cacheDir string) (*ChildManager, func()) {
	t.Helper()
	cfg := config{
		RouterPort:    "4800",
		D2Bin:         helperBin(t),
		ChildPortBase: fmt.Sprintf("%d", freePort(t)),
		IdleTimeout:   "30m",
		SvgCacheDir:   cacheDir,
	}
	cm := NewChildManager(cfg, helperEnv())

	if _, err := cm.Ensure(key, absPath); err != nil {
		t.Fatalf("spawnFakeChildWithCache: Ensure: %v", err)
	}

	stop := func() {
		cm.Stop(key) //nolint:errcheck
	}
	return cm, stop
}

// ── /api/svg ─────────────────────────────────────────────────────────────

func TestAPISvg_wrongMethod(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800", "")

	req := httptest.NewRequest(http.MethodPost, "/api/svg?path=/home/user/proj/a.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("svg POST: want 405, got %d", rr.Code)
	}
	if allow := rr.Header().Get("Allow"); allow != "GET" {
		t.Errorf("svg POST: want Allow: GET, got %q", allow)
	}
}

func TestAPISvg_relativePath(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800", "")

	req := httptest.NewRequest(http.MethodGet, "/api/svg?path=relative/path.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("svg relative: want 400, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPISvg_missingPath(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800", "")

	req := httptest.NewRequest(http.MethodGet, "/api/svg", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("svg missing path: want 400, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestAPISvg_outsideRegistry(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	reg := Registry{"proj": "/home/user/proj"}
	h := NewAPIHandler(cm, reg, "4800", "")

	req := httptest.NewRequest(http.MethodGet, "/api/svg?path=/tmp/other/file.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("svg outside: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

// TestAPISvg_projectRemovedFromRegistry is the edge case "registry project
// removed while child runs → 404 on next fetch": the route re-checks the
// registry on every request rather than trusting a previously-spawned
// child, so an emptied registry 404s even though "proj" is still a valid
// prefix of the requested path.
func TestAPISvg_projectRemovedFromRegistry(t *testing.T) {
	cm := NewChildManager(config{D2Bin: "false", ChildPortBase: "4801", IdleTimeout: "30m"}, nil)
	h := NewAPIHandler(cm, Registry{}, "4800", "") // project no longer registered

	req := httptest.NewRequest(http.MethodGet, "/api/svg?path=/home/user/proj/gone.d2", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("svg project removed: want 404, got %d: %s", rr.Code, rr.Body.String())
	}
}

// TestAPISvg_success is the test_plan's core route test plus its recompile
// follow-up: registered path → 200 + image/svg+xml + expected bytes, and a
// second fetch after the on-disk svg changes (simulating a recompile
// triggered by touching the source) returns the NEW bytes — proving the
// route always re-reads current content rather than caching.
func TestAPISvg_success(t *testing.T) {
	projDir := t.TempDir()
	filePath := filepath.Join(projDir, "board.d2")
	if err := os.WriteFile(filePath, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	cacheDir := t.TempDir()
	cm, stop := spawnFakeChildWithCache(t, "proj/board.d2", filePath, cacheDir)
	defer stop()

	reg := Registry{"proj": projDir}
	h := NewAPIHandler(cm, reg, "4800", cacheDir)

	// The fake helper never invokes real d2, so simulate its first compile by
	// writing to the same deterministic path a live "d2 --watch" would have
	// written (Child.SVGPath, set by children.go's spawnLocked).
	snap := cm.Snapshot()
	ch, ok := snap["proj/board.d2"]
	if !ok {
		t.Fatal("child not found in snapshot")
	}
	want1 := []byte("<svg>one</svg>")
	if err := os.WriteFile(ch.SVGPath, want1, 0644); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/svg?path="+filePath, nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("svg success: want 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if ct := rr.Header().Get("Content-Type"); ct != "image/svg+xml" {
		t.Errorf("svg success: want Content-Type image/svg+xml, got %q", ct)
	}
	if rr.Body.String() != string(want1) {
		t.Errorf("svg success: want body %q, got %q", want1, rr.Body.String())
	}

	// Recompile: the on-disk svg changes (simulating "touch source → fake
	// child updates its svg") — the next fetch must return the new bytes.
	want2 := []byte("<svg>two</svg>")
	if err := os.WriteFile(ch.SVGPath, want2, 0644); err != nil {
		t.Fatal(err)
	}
	rr2 := httptest.NewRecorder()
	h.ServeHTTP(rr2, httptest.NewRequest(http.MethodGet, "/api/svg?path="+filePath, nil))
	if rr2.Code != http.StatusOK {
		t.Fatalf("svg recompile: want 200, got %d: %s", rr2.Code, rr2.Body.String())
	}
	if rr2.Body.String() != string(want2) {
		t.Errorf("svg recompile: want body %q, got %q", want2, rr2.Body.String())
	}
}

// TestAPISvg_pathWithSpaces is the edge case "Path with spaces →
// url-encoded query handled".
func TestAPISvg_pathWithSpaces(t *testing.T) {
	projDir := t.TempDir()
	filePath := filepath.Join(projDir, "my board.d2")
	if err := os.WriteFile(filePath, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	cacheDir := t.TempDir()
	cm, stop := spawnFakeChildWithCache(t, "proj/my board.d2", filePath, cacheDir)
	defer stop()

	reg := Registry{"proj": projDir}
	h := NewAPIHandler(cm, reg, "4800", cacheDir)

	snap := cm.Snapshot()
	ch, ok := snap["proj/my board.d2"]
	if !ok {
		t.Fatal("child not found in snapshot")
	}
	want := []byte("<svg>spaced</svg>")
	if err := os.WriteFile(ch.SVGPath, want, 0644); err != nil {
		t.Fatal(err)
	}

	target := "/api/svg?path=" + url.QueryEscape(filePath)
	req := httptest.NewRequest(http.MethodGet, target, nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("svg spaces: want 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if rr.Body.String() != string(want) {
		t.Errorf("svg spaces: want %q, got %q", want, rr.Body.String())
	}
}

// TestAPISvg_firstHitRacesInitialCompile is the edge case "child compiled
// nothing yet (first hit races the initial compile) → bounded retry/poll
// before 200": the svg file appears mid-poll (simulating the child's first
// compile landing just after Ensure returns), and the route must still
// return 200 with those bytes rather than 503ing on the initial miss.
func TestAPISvg_firstHitRacesInitialCompile(t *testing.T) {
	origInterval, origDeadline := svgPollInterval, svgPollDeadline
	svgPollInterval = 5 * time.Millisecond
	svgPollDeadline = 2 * time.Second
	defer func() { svgPollInterval, svgPollDeadline = origInterval, origDeadline }()

	projDir := t.TempDir()
	filePath := filepath.Join(projDir, "racing.d2")
	if err := os.WriteFile(filePath, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	cacheDir := t.TempDir()
	cm, stop := spawnFakeChildWithCache(t, "proj/racing.d2", filePath, cacheDir)
	defer stop()

	snap := cm.Snapshot()
	ch, ok := snap["proj/racing.d2"]
	if !ok {
		t.Fatal("child not found in snapshot")
	}

	want := []byte("<svg>raced</svg>")
	go func() {
		time.Sleep(60 * time.Millisecond)
		_ = os.WriteFile(ch.SVGPath, want, 0644)
	}()

	reg := Registry{"proj": projDir}
	h := NewAPIHandler(cm, reg, "4800", cacheDir)

	req := httptest.NewRequest(http.MethodGet, "/api/svg?path="+filePath, nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("svg race: want 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if rr.Body.String() != string(want) {
		t.Errorf("svg race: want %q, got %q", want, rr.Body.String())
	}
}

// TestAPISvg_timeoutNeverHangs is the edge case's other half: if the svg
// never lands, the route 503s after the bounded deadline rather than
// hanging. svgPollDeadline is shrunk so the test itself stays fast; the
// assertion on elapsed time is what proves "never a hang" rather than
// "eventually, on some unbounded clock".
func TestAPISvg_timeoutNeverHangs(t *testing.T) {
	origInterval, origDeadline := svgPollInterval, svgPollDeadline
	svgPollInterval = 5 * time.Millisecond
	svgPollDeadline = 50 * time.Millisecond
	defer func() { svgPollInterval, svgPollDeadline = origInterval, origDeadline }()

	projDir := t.TempDir()
	filePath := filepath.Join(projDir, "never.d2")
	if err := os.WriteFile(filePath, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	cacheDir := t.TempDir()
	cm, stop := spawnFakeChildWithCache(t, "proj/never.d2", filePath, cacheDir)
	defer stop()

	reg := Registry{"proj": projDir}
	h := NewAPIHandler(cm, reg, "4800", cacheDir)

	start := time.Now()
	req := httptest.NewRequest(http.MethodGet, "/api/svg?path="+filePath, nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	elapsed := time.Since(start)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("svg never-compiled: want 503, got %d: %s", rr.Code, rr.Body.String())
	}
	if elapsed > 2*time.Second {
		t.Errorf("svg never-compiled: took %v — looks like a hang, not a bounded timeout", elapsed)
	}
}

// TestAPISvg_lastGoodSvgWhenEnsureFails is the edge case "d2 compile error →
// the route serves the last good svg if one exists": here Ensure itself
// fails on every attempt (every spawn crashes before ready), yet a
// pre-existing svg at the deterministic output path — left behind by some
// earlier, since-crashed child — is still served rather than erroring,
// because the path is a pure function of (project, basename), independent
// of any live child.
func TestAPISvg_lastGoodSvgWhenEnsureFails(t *testing.T) {
	projDir := t.TempDir()
	filePath := filepath.Join(projDir, "flaky.d2")
	if err := os.WriteFile(filePath, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}
	cacheDir := t.TempDir()

	cfg := makeHelperConfig(t, freePort(t))
	cfg.SvgCacheDir = cacheDir
	m := newCrashBeforeReadyManager(t, cfg) // every spawn attempt fails readiness
	defer m.StopAll()

	// Pre-seed the deterministic output path with bytes from a prior good
	// compile — this file's existence does not depend on any live child.
	outPath, err := svgOutputPath(cacheDir, "proj", filePath)
	if err != nil {
		t.Fatal(err)
	}
	want := []byte("<svg>stale-but-good</svg>")
	if err := os.WriteFile(outPath, want, 0644); err != nil {
		t.Fatal(err)
	}

	reg := Registry{"proj": projDir}
	h := NewAPIHandler(m.ChildManager, reg, "4800", cacheDir)

	req := httptest.NewRequest(http.MethodGet, "/api/svg?path="+filePath, nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("svg last-good: want 200 (served from disk despite Ensure failure), got %d: %s", rr.Code, rr.Body.String())
	}
	if rr.Body.String() != string(want) {
		t.Errorf("svg last-good: want %q, got %q", want, rr.Body.String())
	}
}

// TestAPISvg_emptySourceNamesTheCause covers the empty-source path
// (dotfiles-sytg). d2 v0.7.1 writes no svg at all for a source with no
// statements, and exits 0 without a word on stdout or stderr, so /api/svg
// cannot produce bytes. That part is correct and unavoidable; what was wrong
// was the message. The bounded poll surfaced it as
//
//	svg not ready after 3s: open …/bravo.svg: no such file or directory
//
// which reads like a first-hit compile race. It cost a P1 misdiagnosis: the
// fixture in that report (fixtures/walk/bravo.d2) is 0 bytes, and the
// "race" was permanent. The response must now name the real cause.
func TestAPISvg_emptySourceNamesTheCause(t *testing.T) {
	origDeadline := svgPollDeadline
	svgPollDeadline = 100 * time.Millisecond // no svg is ever coming; don't wait 3s
	defer func() { svgPollDeadline = origDeadline }()

	projDir := t.TempDir()
	filePath := filepath.Join(projDir, "blank.d2")
	if err := os.WriteFile(filePath, nil, 0644); err != nil {
		t.Fatal(err)
	}

	cacheDir := t.TempDir()
	cm, stop := spawnFakeChildWithCache(t, "proj/blank.d2", filePath, cacheDir)
	defer stop()

	reg := Registry{"proj": projDir}
	h := NewAPIHandler(cm, reg, "4800", cacheDir)

	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/svg?path="+filePath, nil))

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("empty source: want 503, got %d: %s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if !strings.Contains(body, "no d2 statements") {
		t.Errorf("empty source: 503 must name the cause, got %s", body)
	}
	if !strings.Contains(body, filePath) {
		t.Errorf("empty source: 503 must name the source file, got %s", body)
	}
	// The old misleading framing must be gone.
	if strings.Contains(body, "not ready") || strings.Contains(body, "no such file or directory") {
		t.Errorf("empty source: 503 still reads like a race/timeout, got %s", body)
	}
}

// TestAPISvg_whitespaceAndCommentOnlySourcesNameTheCause extends the above to
// the two other sources d2 v0.7.1 silently declines to compile: whitespace
// only and comments only. Both were verified against the real binary to write
// no output and exit 0, so both must get the same honest diagnostic as a
// 0-byte file rather than the poll's "no such file" text.
func TestAPISvg_whitespaceAndCommentOnlySourcesNameTheCause(t *testing.T) {
	origDeadline := svgPollDeadline
	svgPollDeadline = 100 * time.Millisecond
	defer func() { svgPollDeadline = origDeadline }()

	cases := map[string]string{
		"whitespace-only": "   \n\n\t\n",
		"comment-only":    "# just a note\n# and another\n",
	}
	for name, content := range cases {
		t.Run(name, func(t *testing.T) {
			projDir := t.TempDir()
			filePath := filepath.Join(projDir, "quiet.d2")
			if err := os.WriteFile(filePath, []byte(content), 0644); err != nil {
				t.Fatal(err)
			}

			cacheDir := t.TempDir()
			cm, stop := spawnFakeChildWithCache(t, "proj/quiet.d2", filePath, cacheDir)
			defer stop()

			h := NewAPIHandler(cm, Registry{"proj": projDir}, "4800", cacheDir)
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/svg?path="+filePath, nil))

			if rr.Code != http.StatusServiceUnavailable {
				t.Fatalf("want 503, got %d: %s", rr.Code, rr.Body.String())
			}
			if !strings.Contains(rr.Body.String(), "no d2 statements") {
				t.Errorf("503 must name the cause, got %s", rr.Body.String())
			}
		})
	}
}

// TestAPISvg_realD2WritesNonEmptyCacheFile is the assertion whose absence let
// a bad diagnosis stand for two audits: it drives the REAL d2 binary through
// the REAL production path and asserts the cache file exists and is NON-EMPTY.
//
// Every other /api/svg test writes Child.SVGPath itself before fetching, so
// the suite proved "the route serves a file that is there" but never "the
// production path puts a file there". The audits that verified this route
// checked only the ABSENCE of a sibling .svg in the repo (dotfiles-eq8), never
// the PRESENCE of bytes at the cache path — so a route producing nothing would
// have passed both gates. This test closes that hole, and doubles as the
// standing proof that "d2 --watch honours its explicit output path", the claim
// dotfiles-sytg wrongly denied.
//
// Skipped when no real d2 is installed; the fake helper cannot stand in here,
// because a fake that writes the file on request is precisely the blind spot.
func TestAPISvg_realD2WritesNonEmptyCacheFile(t *testing.T) {
	d2bin, err := exec.LookPath("d2")
	if err != nil {
		t.Skipf("real d2 not on PATH: %v", err)
	}

	projDir := t.TempDir()
	filePath := filepath.Join(projDir, "real.d2")
	if err := os.WriteFile(filePath, []byte("alpha -> beta\n"), 0644); err != nil {
		t.Fatal(err)
	}
	cacheDir := t.TempDir()

	cfg := config{
		RouterPort:    "4800",
		D2Bin:         d2bin,
		ChildPortBase: fmt.Sprintf("%d", freePort(t)),
		IdleTimeout:   "30m",
		SvgCacheDir:   cacheDir,
	}
	cm := NewChildManager(cfg, os.Environ())
	defer cm.StopAll()

	key := "proj/real.d2"
	if _, err := cm.Ensure(key, filePath); err != nil {
		t.Fatalf("Ensure with real d2: %v", err)
	}

	outPath, err := svgOutputPath(cacheDir, "proj", filePath)
	if err != nil {
		t.Fatal(err)
	}
	// Nothing but the real d2 can create this file.
	if _, err := os.Stat(outPath); !os.IsNotExist(err) {
		t.Fatalf("precondition: %s must not exist before the fetch (stat err=%v)", outPath, err)
	}

	// A real compile takes ~80-450ms; allow generous headroom over the default.
	origDeadline := svgPollDeadline
	svgPollDeadline = 20 * time.Second
	defer func() { svgPollDeadline = origDeadline }()

	h := NewAPIHandler(cm, Registry{"proj": projDir}, "4800", cacheDir)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/svg?path="+filePath, nil))

	if rr.Code != http.StatusOK {
		t.Fatalf("real d2 fetch: want 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if ct := rr.Header().Get("Content-Type"); ct != "image/svg+xml" {
		t.Errorf("real d2 fetch: want image/svg+xml, got %q", ct)
	}
	if rr.Body.Len() == 0 {
		t.Fatal("real d2 fetch: 200 with an empty body")
	}
	if !strings.Contains(rr.Body.String(), "<svg") {
		t.Errorf("real d2 fetch: body is not svg: %.120q", rr.Body.String())
	}

	// THE assertion: the production path actually wrote bytes to the cache.
	info, statErr := os.Stat(outPath)
	if statErr != nil {
		t.Fatalf("production path wrote no svg: stat %s: %v", outPath, statErr)
	}
	if info.Size() == 0 {
		t.Fatalf("production path wrote an EMPTY svg at %s", outPath)
	}

	// dotfiles-eq8: still nothing beside the source.
	entries, err := os.ReadDir(projDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".svg") {
			t.Errorf("dotfiles-eq8 regression: stray %s written beside the source", e.Name())
		}
	}
}
