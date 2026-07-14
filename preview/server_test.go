package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// newTestServer wires a Server against a scratch temp dir root so handler
// tests don't depend on the working directory.
func newTestServer(t *testing.T) *Server {
	t.Helper()
	root := t.TempDir()
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer(%q): %v", root, err)
	}
	return srv
}

// TestStatus proves GET /status returns 200 + a JSON health snapshot with
// the expected fields (sp008 Task 1 success criteria, ft002/ft004 parity).
func TestStatus(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/status", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /status: status %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Errorf("GET /status content-type %q, want application/json", ct)
	}
	var st Status
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatalf("unmarshal /status: %v", err)
	}
	if st.PID <= 0 {
		t.Errorf("status pid %d, want >0", st.PID)
	}
	if st.Root == "" {
		t.Errorf("status root empty")
	}
	if st.Port != "4200" {
		t.Errorf("status port %q, want 4200", st.Port)
	}
	if st.StartedAt.IsZero() {
		t.Errorf("status started_at zero")
	}
}

// TestStop proves POST /stop cancels the server context (graceful shutdown
// signal) and returns 200.
func TestStop(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/stop", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST /stop: status %d, want 200", rec.Code)
	}
	select {
	case <-srv.Done():
		// context cancelled — shutdown signalled
	default:
		t.Errorf("POST /stop did not cancel server context")
	}
}

// TestStopIdempotent proves a second POST /stop after the context is
// already cancelled still returns 200 rather than panicking or erroring
// (sp008 Task 1 edge case: double stop is idempotent).
func TestStopIdempotent(t *testing.T) {
	srv := newTestServer(t)

	rec1 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec1, httptest.NewRequest(http.MethodPost, "/stop", nil))
	if rec1.Code != http.StatusOK {
		t.Fatalf("first POST /stop: status %d, want 200", rec1.Code)
	}

	rec2 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec2, httptest.NewRequest(http.MethodPost, "/stop", nil))
	if rec2.Code != http.StatusOK {
		t.Fatalf("second POST /stop: status %d, want 200", rec2.Code)
	}

	select {
	case <-srv.Done():
	default:
		t.Errorf("context not cancelled after double stop")
	}
}

// TestMethodMatrix proves ft002/ft004 method-parity: wrong method on
// /status or /stop returns 405 with an Allow header naming the accepted
// method, and a wrong-method /stop never cancels the context.
func TestMethodMatrix(t *testing.T) {
	cases := []struct {
		path      string
		method    string
		wantAllow string
	}{
		{"/status", http.MethodPost, http.MethodGet},
		{"/stop", http.MethodGet, http.MethodPost},
	}
	for _, tc := range cases {
		t.Run(tc.method+tc.path, func(t *testing.T) {
			srv := newTestServer(t)
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(tc.method, tc.path, nil)
			srv.Handler().ServeHTTP(rec, req)

			if rec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s %s: status %d, want 405", tc.method, tc.path, rec.Code)
			}
			if allow := rec.Header().Get("Allow"); !strings.Contains(allow, tc.wantAllow) {
				t.Errorf("%s %s: Allow %q, want to contain %q", tc.method, tc.path, allow, tc.wantAllow)
			}
			if tc.path == "/stop" {
				select {
				case <-srv.Done():
					t.Errorf("GET /stop wrongly cancelled server context")
				default:
				}
			}
		})
	}
}

// TestMissingRootErrors proves NewServer fails fast on a nonexistent root,
// naming the offending path (sp008 Task 1 edge case: -root missing dir ->
// error at startup, not empty serve).
func TestMissingRootErrors(t *testing.T) {
	_, err := NewServer("/does-not-exist-xyz-preview-root", "4200")
	if err == nil {
		t.Fatal("NewServer on missing root: want error, got nil")
	}
	if !strings.Contains(err.Error(), "does-not-exist-xyz-preview-root") {
		t.Errorf("error %q does not name the missing path", err.Error())
	}
}

// TestHandleFileServesCodeInRoot proves GET /file/<path> reaches the code
// renderer end-to-end through the real mux (sp008 Task 2 success
// criteria).
func TestHandleFileServesCodeInRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "sample.go"), []byte("package main\n"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/sample.go", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /file/sample.go: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `class="chroma"`) {
		t.Errorf("GET /file/sample.go: body missing chroma wrapper: %s", rec.Body.String())
	}
}

// TestHandleFileNonexistentReturns404 proves a nonexistent in-root path
// returns 404 through the full handler chain, not a 500 (sp008 Task 2 edge
// case).
func TestHandleFileNonexistentReturns404(t *testing.T) {
	srv := newTestServer(t)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/does-not-exist.go", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("GET /file/does-not-exist.go: status %d, want 404 (body: %s)", rec.Code, rec.Body.String())
	}
}

// TestHandleFileWrongMethodRejected proves a non-GET /file/<path> request
// returns 405 (ft002 method-parity, same as /status and /stop).
func TestHandleFileWrongMethodRejected(t *testing.T) {
	srv := newTestServer(t)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/file/sample.go", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /file/sample.go: status %d, want 405", rec.Code)
	}
}

// TestHandleFileRejectsDotDotEscapeAndReadsNothing is the sp008 Task 2
// security test: a ".." traversal request must be rejected with 400 by
// path.go's containment check and must NEVER reach the secret file's
// content. The handler is called directly (bypassing http.ServeMux, which
// would otherwise 307-redirect an unclean "/file/../../etc/passwd" request
// to "/etc/passwd" before our own code ever runs — a stdlib quirk that is
// not the security boundary we're proving; resolveInRoot's explicit
// containment check is) so the test exercises our own path-jail logic
// end to end.
//
// The secret lives one level above root, is unreadable (mode 0000) as a
// tripwire — if any code path incorrectly attempted to open it, that would
// surface as a distinct (non-400) failure — and its content is asserted
// absent from the response body.
func TestHandleFileRejectsDotDotEscapeAndReadsNothing(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "root")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	secret := filepath.Join(parent, "secret.txt")
	const secretMarker = "TOP-SECRET-CONTENT-MUST-NOT-LEAK"
	if err := os.WriteFile(secret, []byte(secretMarker), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}
	if err := os.Chmod(secret, 0o000); err != nil {
		t.Fatalf("chmod secret: %v", err)
	}
	defer os.Chmod(secret, 0o644) // t.TempDir cleanup needs to remove it

	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/../secret.txt", nil)
	srv.handleFile(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("GET /file/../secret.txt: status %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), secretMarker) {
		t.Fatalf("GET /file/../secret.txt: response leaked secret content: %s", rec.Body.String())
	}
}

// TestHandleFileRejectsSymlinkEscapeAndReadsNothing proves a symlink
// planted inside root that points outside it is rejected with 400 and its
// target's content never appears in the response — the classic path-jail
// bypass that a pure string-prefix check on the unresolved request path
// would miss (sp008 Task 2 security-critical success criteria).
func TestHandleFileRejectsSymlinkEscapeAndReadsNothing(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	secret := filepath.Join(outside, "secret.txt")
	const secretMarker = "TOP-SECRET-SYMLINK-TARGET-CONTENT"
	if err := os.WriteFile(secret, []byte(secretMarker), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}
	if err := os.Chmod(secret, 0o000); err != nil {
		t.Fatalf("chmod secret: %v", err)
	}
	defer os.Chmod(secret, 0o644)

	link := filepath.Join(root, "escape-link")
	if err := os.Symlink(secret, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/escape-link", nil)
	srv.handleFile(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("GET /file/escape-link: status %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), secretMarker) {
		t.Fatalf("GET /file/escape-link: response leaked secret content: %s", rec.Body.String())
	}
}

// TestHandleFileSymlinkEscapeViaFullMux re-runs the symlink-escape case
// through the real srv.Handler() (http.ServeMux) rather than calling
// handleFile directly. Unlike a literal ".."-containing request path
// (which net/http's ServeMux redirects away from before any handler runs
// — see TestHandleFileRejectsDotDotEscapeAndReadsNothing's doc comment), a
// symlink target is invisible at the URL level: "/file/escape-link" is
// already a clean path, so the mux dispatches it straight to handleFile
// with no redirect. This proves the 400 our path-jail returns is what a
// real client actually receives for this attack, not just what direct unit
// tests observe.
func TestHandleFileSymlinkEscapeViaFullMux(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	secret := filepath.Join(outside, "secret.txt")
	const secretMarker = "TOP-SECRET-FULL-MUX-CONTENT"
	if err := os.WriteFile(secret, []byte(secretMarker), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}
	link := filepath.Join(root, "escape-link")
	if err := os.Symlink(secret, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/escape-link", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("GET /file/escape-link via full mux: status %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), secretMarker) {
		t.Fatalf("GET /file/escape-link via full mux: response leaked secret content: %s", rec.Body.String())
	}
}

// TestParseSlotQuery proves the sp009 Task 6 ?slot parsing contract: a
// missing or non-numeric value returns nil (absent — slot is a routing
// hint, never grounds for a 400), while a valid integer returns a pointer to
// it.
func TestParseSlotQuery(t *testing.T) {
	intPtr := func(n int) *int { return &n }
	cases := []struct {
		name string
		url  string
		want *int
	}{
		{"missing", "/file/x.md", nil},
		{"numeric", "/file/x.md?slot=3", intPtr(3)},
		{"non-numeric", "/file/x.md?slot=abc", nil},
		{"empty value", "/file/x.md?slot=", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tc.url, nil)
			got := parseSlotQuery(req)
			if (got == nil) != (tc.want == nil) {
				t.Fatalf("parseSlotQuery(%q) = %v, want %v", tc.url, got, tc.want)
			}
			if got != nil && *got != *tc.want {
				t.Errorf("parseSlotQuery(%q) = %d, want %d", tc.url, *got, *tc.want)
			}
		})
	}
}

// --- POST /register: per-slot nvim address binding (sp009 Task 1) ------

// registerBody is the POST /register response shape: {"slot": N}.
type registerResp struct {
	Slot int `json:"slot"`
}

// doRegister posts a /register request through the real mux and decodes the
// JSON response, failing the test on a non-200 status.
func doRegister(t *testing.T, srv *Server, body string) registerResp {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/register", strings.NewReader(body))
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST /register %s: status %d, want 200 (body: %s)", body, rec.Code, rec.Body.String())
	}
	var got registerResp
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode /register response %s: %v", rec.Body.String(), err)
	}
	return got
}

// TestHandleRegisterAllocatesSlotWhenOmitted proves POST /register
// {"nvim":...} with no slot allocates a free slot, returns it as {"slot":N},
// and binds the nvim addr to that slot (sp009 Task 1 success criteria).
func TestHandleRegisterAllocatesSlotWhenOmitted(t *testing.T) {
	srv := newTestServer(t)

	got := doRegister(t, srv, `{"nvim":"/tmp/nvim.a.sock"}`)

	if got.Slot <= 0 {
		t.Fatalf("POST /register with no slot: allocated slot %d, want > 0", got.Slot)
	}
	if addr := srv.slots.NvimAddr(got.Slot); addr != "/tmp/nvim.a.sock" {
		t.Errorf("NvimAddr(%d) = %q, want /tmp/nvim.a.sock", got.Slot, addr)
	}
}

// TestHandleRegisterExplicitSlotBindsAddr proves POST /register
// {"nvim":...,"slot":N} binds addr to the caller-chosen slot N and echoes N
// back in the response (sp009 Task 1 success criteria).
func TestHandleRegisterExplicitSlotBindsAddr(t *testing.T) {
	srv := newTestServer(t)

	got := doRegister(t, srv, `{"nvim":"/tmp/nvim.b.sock","slot":5}`)

	if got.Slot != 5 {
		t.Fatalf("POST /register with slot=5: response slot %d, want 5", got.Slot)
	}
	if addr := srv.slots.NvimAddr(5); addr != "/tmp/nvim.b.sock" {
		t.Errorf("NvimAddr(5) = %q, want /tmp/nvim.b.sock", addr)
	}
}

// TestHandleRegisterReRegisterUpdatesAddrNotNewSlot proves re-registering an
// explicit slot updates its bound address (last-wins) rather than
// allocating a new slot (sp009 Task 1 edge case).
func TestHandleRegisterReRegisterUpdatesAddrNotNewSlot(t *testing.T) {
	srv := newTestServer(t)

	first := doRegister(t, srv, `{"nvim":"/tmp/nvim.old.sock","slot":2}`)
	second := doRegister(t, srv, `{"nvim":"/tmp/nvim.new.sock","slot":2}`)

	if first.Slot != 2 || second.Slot != 2 {
		t.Fatalf("re-register slot 2: got slots %d then %d, want 2 both times", first.Slot, second.Slot)
	}
	if addr := srv.slots.NvimAddr(2); addr != "/tmp/nvim.new.sock" {
		t.Errorf("NvimAddr(2) after re-register = %q, want /tmp/nvim.new.sock", addr)
	}
}

// TestHandleRegisterEmptyNvimReturns400 proves an empty "nvim" address is
// rejected with 400 rather than silently registering a blank address
// (sp009 Task 1 edge case).
func TestHandleRegisterEmptyNvimReturns400(t *testing.T) {
	srv := newTestServer(t)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/register", strings.NewReader(`{"nvim":""}`))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("POST /register with empty nvim: status %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
}

// TestHandleRegisterMalformedBodyReturns400 proves an unparseable JSON body
// is a 400, never a 500 or panic (sp008-wide anti-pattern, applied to the
// new route).
func TestHandleRegisterMalformedBodyReturns400(t *testing.T) {
	srv := newTestServer(t)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/register", strings.NewReader(`{not json`))
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("POST /register with malformed body: status %d, want 400 (body: %s)", rec.Code, rec.Body.String())
	}
}

// TestHandleRegisterWrongMethodRejected proves a non-POST /register request
// returns 405 (ft002/ft004 method-parity, same as the other routes).
func TestHandleRegisterWrongMethodRejected(t *testing.T) {
	srv := newTestServer(t)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/register", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /register: status %d, want 405", rec.Code)
	}
}

// TestHandleRegisterConcurrentNoSlotDistinct proves concurrent no-slot
// /register requests (as real simultaneous nvim startups would produce)
// never receive the same allocated slot number — the full-stack version of
// the SlotManager.AllocateSlot concurrency guarantee, exercised through the
// real HTTP handler (sp009 Task 1 success criteria).
func TestHandleRegisterConcurrentNoSlotDistinct(t *testing.T) {
	srv := newTestServer(t)

	const n = 20
	results := make([]int, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			rec := httptest.NewRecorder()
			body := `{"nvim":"/tmp/nvim.concurrent.sock"}`
			req := httptest.NewRequest(http.MethodPost, "/register", strings.NewReader(body))
			srv.Handler().ServeHTTP(rec, req)
			var got registerResp
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Errorf("decode concurrent /register response: %v", err)
				return
			}
			results[idx] = got.Slot
		}(i)
	}
	wg.Wait()

	seen := make(map[int]bool, n)
	for _, got := range results {
		if seen[got] {
			t.Fatalf("concurrent POST /register handed out duplicate slot %d: %v", got, results)
		}
		seen[got] = true
	}
}
