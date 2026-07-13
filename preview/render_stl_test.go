package main

import (
	"bytes"
	"encoding/binary"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeSTLFixture mirrors render_image_test.go / render_video_test.go's
// writeFixture helpers.
func writeSTLFixture(t *testing.T, name string, content []byte) (string, os.FileInfo) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatalf("write fixture %s: %v", name, err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat fixture %s: %v", name, err)
	}
	return path, fi
}

// asciiSTLFixture is a minimal but well-formed ASCII STL: one triangle.
const asciiSTLFixture = `solid test
facet normal 0 0 1
  outer loop
    vertex 0 0 0
    vertex 1 0 0
    vertex 0 1 0
  endloop
endfacet
endsolid test
`

// binarySTLFixture builds a minimal well-formed binary STL: an 80-byte
// header, a uint32 triangle count of 1, and one 50-byte triangle record
// (12 float32 normal+vertices + a 2-byte attribute count) -- proving the
// renderer's byte-stream path is format-agnostic (sp008 Task 9 edge case:
// binary vs ASCII STL, both load -- decoding itself happens client-side in
// the vendored viewer, so the server side only needs to stream bytes
// faithfully for either format).
func binarySTLFixture() []byte {
	buf := make([]byte, 80+4+50)
	binary.LittleEndian.PutUint32(buf[80:84], 1)
	floats := []float32{0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0}
	off := 84
	for _, f := range floats {
		binary.LittleEndian.PutUint32(buf[off:off+4], math.Float32bits(f))
		off += 4
	}
	return buf
}

// TestRenderSTLPageReferencesEmbeddedViewer proves GET /file/<path>.stl
// (full=false) returns an HTML page that references the embedded viewer
// asset (sp008 Task 9 success criteria + test_plan: "/file/<path>.stl
// returns HTML referencing the embedded viewer asset").
func TestRenderSTLPageReferencesEmbeddedViewer(t *testing.T) {
	path, fi := writeSTLFixture(t, "model.stl", []byte(asciiSTLFixture))

	rec := httptest.NewRecorder()
	renderSTL(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	ct := rec.Header().Get("Content-Type")
	if !strings.Contains(ct, "text/html") {
		t.Fatalf("content-type = %q, want text/html", ct)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "/static/stl-viewer.js") {
		t.Errorf("page does not reference embedded viewer asset /static/stl-viewer.js: %s", body)
	}
}

// TestRenderSTLFullStreamsRawBytes proves full=true streams the original STL
// bytes back unmodified -- the byte source the viewer page's own fetch
// points at via ?full (sp008 Task 9 test_plan: "/file/<path>?raw (or
// equivalent) that streams the STL bytes" -- this renderer reuses the
// existing ?full convention, see render.go dispatch comment).
func TestRenderSTLFullStreamsRawBytes(t *testing.T) {
	content := []byte(asciiSTLFixture)
	path, fi := writeSTLFixture(t, "model.stl", content)

	rec := httptest.NewRecorder()
	renderSTL(rec, path, fi, true)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("full body not byte-identical to source: got %d bytes, want %d bytes", rec.Body.Len(), len(content))
	}
}

// TestRenderSTLBinaryFullStreamsRawBytes is
// TestRenderSTLFullStreamsRawBytes's binary-format counterpart (sp008 Task 9
// edge case: binary vs ASCII STL, both load).
func TestRenderSTLBinaryFullStreamsRawBytes(t *testing.T) {
	content := binarySTLFixture()
	path, fi := writeSTLFixture(t, "model-binary.stl", content)

	rec := httptest.NewRecorder()
	renderSTL(rec, path, fi, true)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("full body not byte-identical to binary source: got %d bytes, want %d bytes", rec.Body.Len(), len(content))
	}
}

// TestRenderSTLBinaryPageReferencesEmbeddedViewer is
// TestRenderSTLPageReferencesEmbeddedViewer's binary-format counterpart
// (sp008 Task 9 edge case: binary vs ASCII STL, both load).
func TestRenderSTLBinaryPageReferencesEmbeddedViewer(t *testing.T) {
	path, fi := writeSTLFixture(t, "model-binary.stl", binarySTLFixture())

	rec := httptest.NewRecorder()
	renderSTL(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "/static/stl-viewer.js") {
		t.Errorf("binary STL page does not reference embedded viewer asset")
	}
}

// TestRenderSTLMalformedStillReturns200HTML proves a malformed/garbage .stl
// file still returns 200 HTML -- the page itself never inspects STL content
// server-side, so it always loads; the viewer bundle's client-side fetch
// +parse is what surfaces an error state (sp008 Task 9 edge case: malformed
// STL -> viewer shows error state, page still loads; test_plan:
// "Malformed-STL fixture still returns 200 HTML").
func TestRenderSTLMalformedStillReturns200HTML(t *testing.T) {
	path, fi := writeSTLFixture(t, "garbage.stl", []byte{0x00, 0x01, 0x02, 0xFF, 0xFE, 0x10, 0x20})

	rec := httptest.NewRecorder()
	renderSTL(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (malformed STL page must still load)", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "/static/stl-viewer.js") {
		t.Errorf("malformed STL page does not reference embedded viewer asset")
	}
}

// TestRenderSTLEmptyFileStillReturns200HTML proves a 0-byte .stl file still
// returns 200 HTML (sp008 Task 9 edge case: empty file).
func TestRenderSTLEmptyFileStillReturns200HTML(t *testing.T) {
	path, fi := writeSTLFixture(t, "empty.stl", []byte{})

	rec := httptest.NewRecorder()
	renderSTL(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (empty STL page must still load)", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "/static/stl-viewer.js") {
		t.Errorf("empty STL page does not reference embedded viewer asset")
	}
}

// TestRenderFileDispatchesSTL proves renderFile's type-dispatch (render.go)
// routes a .stl path to the STL renderer's default (page) tier.
func TestRenderFileDispatchesSTL(t *testing.T) {
	path, _ := writeSTLFixture(t, "model.stl", []byte(asciiSTLFixture))

	rec := httptest.NewRecorder()
	renderFile(rec, path, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	ct := rec.Header().Get("Content-Type")
	if !strings.Contains(ct, "text/html") {
		t.Errorf("content-type = %q, want text/html", ct)
	}
	if !strings.Contains(rec.Body.String(), "/static/stl-viewer.js") {
		t.Errorf("dispatched STL page does not reference embedded viewer asset")
	}
}

// TestRenderFileDispatchesSTLFullOnFlag proves renderFile's dispatch passes
// full=true through to the STL renderer, streaming raw bytes.
func TestRenderFileDispatchesSTLFullOnFlag(t *testing.T) {
	content := []byte(asciiSTLFixture)
	path, _ := writeSTLFixture(t, "model.stl", content)

	rec := httptest.NewRecorder()
	renderFile(rec, path, true)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("dispatched full body not byte-identical to source")
	}
}

// TestHandleFileSTLDefaultReturnsViewerPage exercises the REAL production
// mux end to end: GET /file/<path>.stl (no query) must return the HTML
// viewer page. This proves the feature works with ZERO server.go changes --
// server.go's existing handleFile already threads r.URL.Query().Has("full")
// through to renderFile for any extension, so STL rides the same wiring
// image/video already use (sp008 Task 9 notes: prefer reusing ?full to
// minimize server.go touch).
func TestHandleFileSTLDefaultReturnsViewerPage(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "model.stl"), []byte(asciiSTLFixture), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/model.stl", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != 200 {
		t.Fatalf("GET /file/model.stl: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	ct := rec.Header().Get("Content-Type")
	if !strings.Contains(ct, "text/html") {
		t.Fatalf("content-type = %q, want text/html", ct)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "/static/stl-viewer.js") {
		t.Errorf("live response missing embedded viewer reference: %s", body)
	}
}

// TestHandleFileSTLFullReturnsRawBytes is
// TestHandleFileSTLDefaultReturnsViewerPage's ?full counterpart: the real
// mux must stream raw STL bytes for GET /file/<path>.stl?full (sp008 Task 9
// test_plan: "/file/<path>?raw (or equivalent) that streams the STL
// bytes").
func TestHandleFileSTLFullReturnsRawBytes(t *testing.T) {
	root := t.TempDir()
	content := []byte(asciiSTLFixture)
	if err := os.WriteFile(filepath.Join(root, "model.stl"), content, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/model.stl?full", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != 200 {
		t.Fatalf("GET /file/model.stl?full: status %d, want 200", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("?full body not byte-identical to source")
	}
}

// TestHandleFileSTLPageHasNoOutboundNetworkReference is the offline-embed
// test (sp008 Task 9 test_plan): the served HTML must reference no
// http://|https:// URL -- every asset (the viewer bundle) is same-origin,
// served from /static/, embedded via go:embed rather than pulled from a CDN.
func TestHandleFileSTLPageHasNoOutboundNetworkReference(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "model.stl"), []byte(asciiSTLFixture), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/model.stl", nil)
	srv.Handler().ServeHTTP(rec, req)

	body := rec.Body.String()
	if strings.Contains(body, "http://") || strings.Contains(body, "https://") {
		t.Errorf("served STL page references an outbound URL, must be same-origin only: %s", body)
	}
}

// TestStaticFSEmbedsSTLViewerBundle proves the vendored viewer bundle is
// actually go:embed'd into the binary (embed.go's whole-directory
// //go:embed static glob) and reachable via the same fs.Sub(staticFS,
// "static") the server uses to serve /static/ -- sp008 Task 9 notes: "Verify
// the file gets embedded via a test that reads it from staticFS."
func TestStaticFSEmbedsSTLViewerBundle(t *testing.T) {
	data, err := staticFS.ReadFile("static/stl-viewer.js")
	if err != nil {
		t.Fatalf("static/stl-viewer.js not embedded in staticFS: %v", err)
	}
	if len(data) == 0 {
		t.Fatalf("embedded stl-viewer.js is empty")
	}
	if !bytes.Contains(data, []byte("THREE")) {
		t.Errorf("embedded stl-viewer.js does not look like a three.js bundle (no THREE reference)")
	}
}

// TestHandleFileServesSTLViewerBundleFromStatic proves the bundle is
// actually reachable over HTTP at /static/stl-viewer.js -- the URL the
// rendered STL page's <script src> points at.
func TestHandleFileServesSTLViewerBundleFromStatic(t *testing.T) {
	root := t.TempDir()
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/static/stl-viewer.js", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != 200 {
		t.Fatalf("GET /static/stl-viewer.js: status %d, want 200", rec.Code)
	}
	if rec.Body.Len() == 0 {
		t.Errorf("served viewer bundle is empty")
	}
}
