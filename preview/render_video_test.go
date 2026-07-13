package main

import (
	"bytes"
	"image"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// fixtureMP4 generates a tiny real mp4 via ffmpeg's lavfi testsrc so the
// video renderer tests exercise real ffmpeg decode/extract behaviour (sp008
// Task 8 test_plan: "small fixture mp4 + ffmpeg present"). Skips (not fails)
// when ffmpeg is unavailable, since fixture generation itself needs ffmpeg
// on the real PATH — the ffmpeg-absent code path is tested separately by
// stubbing PATH only around the call under test, after this fixture exists.
func fixtureMP4(t *testing.T) []byte {
	t.Helper()
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed; skipping video fixture generation")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "fixture.mp4")
	cmd := exec.Command("ffmpeg", "-y", "-f", "lavfi",
		"-i", "testsrc=duration=1:size=64x48:rate=5",
		"-pix_fmt", "yuv420p", path)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("generate fixture mp4: %v: %s", err, stderr.String())
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture mp4: %v", err)
	}
	return data
}

// writeVideoFixture mirrors render_image_test.go's writeFixture helper.
func writeVideoFixture(t *testing.T, name string, content []byte) (string, os.FileInfo) {
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

// TestRenderVideoPosterIsImage proves the default (live=false) response is
// an ffmpeg-extracted poster frame decodable as an image (sp008 Task 8
// success criteria + test_plan: "default response is an image (poster)").
func TestRenderVideoPosterIsImage(t *testing.T) {
	content := fixtureMP4(t)
	path, fi := writeVideoFixture(t, "clip.mp4", content)

	rec := httptest.NewRecorder()
	renderVideo(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (body len %d)", rec.Code, rec.Body.Len())
	}
	ct := rec.Header().Get("Content-Type")
	if !strings.HasPrefix(ct, "image/") {
		t.Fatalf("content-type = %q, want image/*", ct)
	}
	if _, _, err := image.DecodeConfig(bytes.NewReader(rec.Body.Bytes())); err != nil {
		t.Errorf("poster body did not decode as an image: %v", err)
	}
}

// TestRenderVideoFullStreamsRawBytes proves full=true streams the original
// video bytes back unmodified (parity with renderImage's full-res tier;
// this is also the byte source the live wrapper's <video> element points
// at via ?full).
func TestRenderVideoFullStreamsRawBytes(t *testing.T) {
	content := fixtureMP4(t)
	path, fi := writeVideoFixture(t, "clip.mp4", content)

	rec := httptest.NewRecorder()
	renderVideo(rec, path, fi, true)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "video/mp4" {
		t.Errorf("content-type = %q, want video/mp4", ct)
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("full body not byte-identical to source: got %d bytes, want %d bytes", rec.Body.Len(), len(content))
	}
}

// TestRenderVideoCorruptFallback proves a file with a video extension but
// non-video content degrades to the safe icon fallback rather than a crash
// (sp008 Task 8 edge case: 0-byte/corrupt video -> poster fails -> icon).
func TestRenderVideoCorruptFallback(t *testing.T) {
	path, fi := writeVideoFixture(t, "corrupt.mp4", []byte("not a real video, just text"))

	rec := httptest.NewRecorder()
	renderVideo(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (fallback still succeeds, never a 500)", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("no preview")) {
		t.Errorf("corrupt video body missing fallback marker: %s", rec.Body.String())
	}
}

// TestRenderVideoZeroByteFallback proves a 0-byte video file degrades to the
// safe fallback rather than invoking ffmpeg at all (sp008 Task 8 edge case:
// 0-byte video).
func TestRenderVideoZeroByteFallback(t *testing.T) {
	path, fi := writeVideoFixture(t, "empty.mp4", []byte{})

	rec := httptest.NewRecorder()
	renderVideo(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("no preview")) {
		t.Errorf("0-byte video body missing fallback marker: %s", rec.Body.String())
	}
}

// TestRenderVideoFfmpegAbsentFallback proves that when ffmpeg is not on
// PATH, the poster tier degrades to the icon fallback with 200, never a 500
// (sp008 Task 8 success criteria + test_plan: "ffmpeg-absent path (PATH
// stubbed empty) returns icon fallback with 200, asserted by body marker").
// The fixture is generated BEFORE PATH is stubbed, since fixture generation
// itself needs the real ffmpeg.
func TestRenderVideoFfmpegAbsentFallback(t *testing.T) {
	content := fixtureMP4(t)
	path, fi := writeVideoFixture(t, "clip.mp4", content)

	t.Setenv("PATH", "")

	rec := httptest.NewRecorder()
	renderVideo(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (ffmpeg absent must degrade, never 500)", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("no preview")) {
		t.Errorf("ffmpeg-absent body missing fallback marker: %s", rec.Body.String())
	}
}

// TestRenderVideoConcurrentPosterRequestsSafe proves concurrent poster
// requests for the same file are race-free and all return the same,
// correct poster bytes (sp008 Task 8 edge case: concurrent poster requests
// -> cache/bound). Run with -race to prove the shared poster cache is
// properly synchronized.
func TestRenderVideoConcurrentPosterRequestsSafe(t *testing.T) {
	content := fixtureMP4(t)
	path, fi := writeVideoFixture(t, "clip.mp4", content)

	const n = 8
	recs := make([]*httptest.ResponseRecorder, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		i := i
		recs[i] = httptest.NewRecorder()
		wg.Add(1)
		go func() {
			defer wg.Done()
			renderVideo(recs[i], path, fi, false)
		}()
	}
	wg.Wait()

	for i, rec := range recs {
		if rec.Code != 200 {
			t.Fatalf("goroutine %d: status = %d, want 200", i, rec.Code)
		}
	}
	first := recs[0].Body.Bytes()
	for i, rec := range recs {
		if !bytes.Equal(rec.Body.Bytes(), first) {
			t.Errorf("goroutine %d: poster bytes diverge from goroutine 0's result", i)
		}
	}
}

// TestRenderFileDispatchesVideoPosterByDefault proves renderFile's
// type-dispatch (render.go) routes a video path to the video renderer and
// defaults to the poster tier when full=false.
func TestRenderFileDispatchesVideoPosterByDefault(t *testing.T) {
	content := fixtureMP4(t)
	path, _ := writeVideoFixture(t, "clip.mp4", content)

	rec := httptest.NewRecorder()
	renderFile(rec, path, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "image/") {
		t.Errorf("content-type = %q, want image/*", ct)
	}
}

// TestRenderFileDispatchesVideoFullOnFlag proves renderFile's dispatch
// passes full=true through to the video renderer, streaming raw bytes.
func TestRenderFileDispatchesVideoFullOnFlag(t *testing.T) {
	content := fixtureMP4(t)
	path, _ := writeVideoFixture(t, "clip.mp4", content)

	rec := httptest.NewRecorder()
	renderFile(rec, path, true)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("dispatched full body not byte-identical to source")
	}
}

// TestHandleFileLiveQueryReturnsVideoElement exercises the real production
// wiring end to end through the server's mux: GET /file/<path>?live must
// return an HTML page containing a <video> element whose src references
// back to /file/<path> with ?full (ft005 api_surface video row + sp008 Task
// 8 test_plan: "?live returns HTML with a <video src=/file/...>").
func TestHandleFileLiveQueryReturnsVideoElement(t *testing.T) {
	root := t.TempDir()
	content := fixtureMP4(t)
	if err := os.WriteFile(filepath.Join(root, "clip.mp4"), content, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/clip.mp4?live", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != 200 {
		t.Fatalf("GET /file/clip.mp4?live: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	ct := rec.Header().Get("Content-Type")
	if !strings.Contains(ct, "text/html") {
		t.Fatalf("content-type = %q, want text/html", ct)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "<video") {
		t.Errorf("live response missing <video element: %s", body)
	}
	if !strings.Contains(body, "/file/clip.mp4?full") {
		t.Errorf("live response's <video> src does not reference /file/clip.mp4?full: %s", body)
	}
}

// TestHandleFileDefaultServesPosterForVideo is
// TestHandleFileLiveQueryReturnsVideoElement's counterpart without ?live:
// the same end-to-end mux path must default to the poster (image) tier.
func TestHandleFileDefaultServesPosterForVideo(t *testing.T) {
	root := t.TempDir()
	content := fixtureMP4(t)
	if err := os.WriteFile(filepath.Join(root, "clip.mp4"), content, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/clip.mp4", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != 200 {
		t.Fatalf("GET /file/clip.mp4: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "image/") {
		t.Errorf("content-type = %q, want image/* (poster default)", ct)
	}
}

// TestHandleFileFfmpegAbsentReturnsIconFallback exercises the full
// production mux with PATH stubbed empty, proving the daemon never 500s
// when ffmpeg is missing — it degrades to the icon fallback with 200
// (sp008 Task 8 test_plan).
func TestHandleFileFfmpegAbsentReturnsIconFallback(t *testing.T) {
	root := t.TempDir()
	content := fixtureMP4(t)
	if err := os.WriteFile(filepath.Join(root, "clip.mp4"), content, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	t.Setenv("PATH", "")

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/clip.mp4", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != 200 {
		t.Fatalf("GET /file/clip.mp4 (ffmpeg absent): status %d, want 200", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("no preview")) {
		t.Errorf("ffmpeg-absent response missing fallback marker: %s", rec.Body.String())
	}
}
