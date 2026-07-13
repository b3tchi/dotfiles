package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// fixturePNG returns width x height PNG bytes of a solid color — big enough
// (larger than maxThumbDimension in both dimensions) that a bounded
// thumbnail is provably smaller than the source (sp008 Task 3 test_plan).
func fixturePNG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x % 256), G: uint8(y % 256), B: 128, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode fixture png: %v", err)
	}
	return buf.Bytes()
}

// fixtureJPEG mirrors fixturePNG for the JPEG format.
func fixtureJPEG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x % 256), G: uint8(y % 256), B: 128, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatalf("encode fixture jpeg: %v", err)
	}
	return buf.Bytes()
}

// writeFixture writes content to name under a fresh temp dir and returns the
// full path plus its os.FileInfo (renderImage's signature, mirroring
// renderFile's existing fi-from-os.Stat pattern).
func writeFixture(t *testing.T, name string, content []byte) (string, os.FileInfo) {
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

// TestRenderImageThumbnailSmallerThanSource proves the default (full=false)
// response is a downscaled thumbnail whose pixel dimensions are smaller than
// the source (sp008 Task 3 success criteria + test_plan: thumbnail response
// smaller-dimensioned than source).
func TestRenderImageThumbnailSmallerThanSource(t *testing.T) {
	cases := []struct {
		name    string
		ext     string
		fixture func(t *testing.T) []byte
	}{
		{"png", "big.png", func(t *testing.T) []byte { return fixturePNG(t, 800, 600) }},
		{"jpeg", "big.jpg", func(t *testing.T) []byte { return fixtureJPEG(t, 800, 600) }},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			content := tc.fixture(t)
			path, fi := writeFixture(t, tc.ext, content)

			rec := httptest.NewRecorder()
			renderImage(rec, path, fi, false)

			if rec.Code != 200 {
				t.Fatalf("status = %d, want 200 (body len %d)", rec.Code, rec.Body.Len())
			}
			thumbCfg, _, err := image.DecodeConfig(bytes.NewReader(rec.Body.Bytes()))
			if err != nil {
				t.Fatalf("decode thumbnail config: %v", err)
			}
			if thumbCfg.Width >= 800 || thumbCfg.Height >= 600 {
				t.Errorf("thumbnail dims %dx%d not smaller than source 800x600", thumbCfg.Width, thumbCfg.Height)
			}
			if thumbCfg.Width > maxThumbDimension || thumbCfg.Height > maxThumbDimension {
				t.Errorf("thumbnail dims %dx%d exceed maxThumbDimension %d", thumbCfg.Width, thumbCfg.Height, maxThumbDimension)
			}
		})
	}
}

// TestRenderImageFullByteIdentical proves full=true streams the original
// bytes back with zero re-encoding loss (sp008 Task 3 success criteria +
// test_plan: ?full byte-identical to source file).
func TestRenderImageFullByteIdentical(t *testing.T) {
	content := fixturePNG(t, 800, 600)
	path, fi := writeFixture(t, "big.png", content)

	rec := httptest.NewRecorder()
	renderImage(rec, path, fi, true)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("full-res body not byte-identical to source: got %d bytes, want %d bytes", rec.Body.Len(), len(content))
	}
}

// TestRenderImageCorruptFallback proves a file with an image extension but
// non-image content degrades to the safe fallback (status + body marker),
// never a crash (sp008 Task 3 edge case: non-image with image extension ->
// type icon, not a crash; test_plan: corrupt-image fixture returns the
// fallback, asserted by status + body marker).
func TestRenderImageCorruptFallback(t *testing.T) {
	path, fi := writeFixture(t, "corrupt.png", []byte("this is not a real PNG, just text pretending to be one"))

	rec := httptest.NewRecorder()
	renderImage(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (fallback still succeeds, never a 500)", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("no preview")) {
		t.Errorf("corrupt image body missing fallback marker: %s", rec.Body.String())
	}
}

// TestRenderImageZeroByteFallback proves a 0-byte image file degrades to the
// safe fallback rather than crashing (sp008 Task 3 edge case: 0-byte image).
func TestRenderImageZeroByteFallback(t *testing.T) {
	path, fi := writeFixture(t, "empty.png", []byte{})

	rec := httptest.NewRecorder()
	renderImage(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("no preview")) {
		t.Errorf("0-byte image body missing fallback marker: %s", rec.Body.String())
	}
}

// hugeDimPNGHeader builds the minimal bytes image.DecodeConfig needs to
// learn a PNG's declared width/height: the 8-byte signature plus a
// syntactically valid IHDR chunk (length + type + 13-byte data). Go's
// image/png DecodeConfig returns as soon as it has parsed IHDR's data — it
// never reads the trailing CRC or any IDAT pixel data for a configOnly
// parse — so this proves the decode-bound check can learn "this image
// claims to be huge" from ~30 bytes without allocating any pixel buffer,
// however large width/height claim to be (sp008 Task 3 edge case: very
// large image must not OOM — decode-bounded).
func hugeDimPNGHeader(t *testing.T, width, height uint32) []byte {
	t.Helper()
	var buf bytes.Buffer
	buf.Write([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})

	data := make([]byte, 13)
	binary.BigEndian.PutUint32(data[0:4], width)
	binary.BigEndian.PutUint32(data[4:8], height)
	data[8] = 8  // bit depth
	data[9] = 6  // color type: truecolor + alpha
	data[10] = 0 // compression method
	data[11] = 0 // filter method
	data[12] = 0 // interlace method

	var lenB [4]byte
	binary.BigEndian.PutUint32(lenB[:], uint32(len(data)))
	buf.Write(lenB[:])
	buf.WriteString("IHDR")
	buf.Write(data)
	// Deliberately no CRC / IDAT / IEND: DecodeConfig never reads past
	// IHDR's data for a non-paletted image, and renderImage must never
	// attempt a full image.Decode on a file this large in the first place.
	return buf.Bytes()
}

// TestRenderImageHugeDimensionsDecodeBounded proves an image declaring
// pixel dimensions far beyond maxDecodePixels is rejected via the cheap
// DecodeConfig header check and falls back safely, without ever attempting
// a full pixel decode (sp008 Task 3 edge case: very large image — thumbnail
// generation must not OOM, decode-bounded).
func TestRenderImageHugeDimensionsDecodeBounded(t *testing.T) {
	// 100,000 x 100,000 = 10 billion pixels — decoding this for real would
	// exhaust memory. If renderImage is properly decode-bounded it rejects
	// this from the ~30-byte header alone.
	content := hugeDimPNGHeader(t, 100000, 100000)
	path, fi := writeFixture(t, "huge.png", content)

	rec := httptest.NewRecorder()
	renderImage(rec, path, fi, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (fallback, never a crash/500)", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("no preview")) {
		t.Errorf("huge-dimension image body missing fallback marker: %s", rec.Body.String())
	}
}

// TestRenderFileDispatchesImageThumbnailByDefault proves renderFile's
// type-dispatch (render.go) routes an image path to the image renderer and
// defaults to the thumbnail tier when full=false — the same entry point
// server.go's handleFile calls for every /file/<path> request (sp008 Task 3
// success criteria: GET /file/<path> on an image returns a downscaled
// thumbnail by default).
func TestRenderFileDispatchesImageThumbnailByDefault(t *testing.T) {
	content := fixturePNG(t, 800, 600)
	path, _ := writeFixture(t, "photo.png", content)

	rec := httptest.NewRecorder()
	renderFile(rec, path, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/png" {
		t.Errorf("content-type = %q, want image/png", ct)
	}
	thumbCfg, _, err := image.DecodeConfig(bytes.NewReader(rec.Body.Bytes()))
	if err != nil {
		t.Fatalf("decode dispatched thumbnail: %v", err)
	}
	if thumbCfg.Width >= 800 || thumbCfg.Height >= 600 {
		t.Errorf("dispatched thumbnail dims %dx%d not smaller than source 800x600", thumbCfg.Width, thumbCfg.Height)
	}
}

// TestRenderFileDispatchesImageFullOnFlag proves renderFile's dispatch
// passes full=true through to the image renderer, returning byte-identical
// original bytes rather than a thumbnail (sp008 Task 3 success criteria:
// full-res on ?full — this test proves the plumbing from renderFile's
// dispatch layer down to renderImage; server.go's handleFile is what
// translates the actual ?full query parameter into this bool).
func TestRenderFileDispatchesImageFullOnFlag(t *testing.T) {
	content := fixturePNG(t, 800, 600)
	path, _ := writeFixture(t, "photo.png", content)

	rec := httptest.NewRecorder()
	renderFile(rec, path, true)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("dispatched full-res body not byte-identical to source: got %d bytes, want %d bytes", rec.Body.Len(), len(content))
	}
}

// TestHandleFileFullQueryServesOriginal exercises the real production
// wiring end to end through the server's mux: GET /file/<path>?full must
// reach handleFile (server.go) -> renderFile (render.go) -> renderImage
// (render_image.go) and return the byte-identical source, proving the
// ?full query parameter is actually threaded through, not just the
// renderFile(..., true) plumbing in isolation above.
func TestHandleFileFullQueryServesOriginal(t *testing.T) {
	root := t.TempDir()
	content := fixturePNG(t, 800, 600)
	if err := os.WriteFile(filepath.Join(root, "photo.png"), content, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/photo.png?full", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != 200 {
		t.Fatalf("GET /file/photo.png?full: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("GET /file/photo.png?full: body not byte-identical to source: got %d bytes, want %d bytes", rec.Body.Len(), len(content))
	}
}

// TestHandleFileDefaultServesThumbnail is TestHandleFileFullQueryServesOriginal's
// counterpart without ?full: the same end-to-end mux path must default to
// the (smaller) thumbnail tier.
func TestHandleFileDefaultServesThumbnail(t *testing.T) {
	root := t.TempDir()
	content := fixturePNG(t, 800, 600)
	if err := os.WriteFile(filepath.Join(root, "photo.png"), content, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	srv, err := NewServer(root, "4200")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/file/photo.png", nil)
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != 200 {
		t.Fatalf("GET /file/photo.png: status %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if bytes.Equal(rec.Body.Bytes(), content) {
		t.Errorf("GET /file/photo.png without ?full unexpectedly returned byte-identical original (want thumbnail)")
	}
	thumbCfg, _, err := image.DecodeConfig(bytes.NewReader(rec.Body.Bytes()))
	if err != nil {
		t.Fatalf("decode default-response thumbnail: %v", err)
	}
	if thumbCfg.Width >= 800 || thumbCfg.Height >= 600 {
		t.Errorf("default response dims %dx%d not smaller than source 800x600", thumbCfg.Width, thumbCfg.Height)
	}
}
