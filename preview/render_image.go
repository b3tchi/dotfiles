package main

import (
	"bytes"
	"image"
	_ "image/gif"  // format registration only: image.Decode/DecodeConfig recognise GIF
	_ "image/jpeg" // format registration only: image.Decode/DecodeConfig recognise JPEG
	"image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/image/draw"
)

// maxThumbDimension bounds the longest side (in pixels) of a generated
// thumbnail — sp008 Task 3 success criteria: "thumbnail generation is
// bounded (max dimension)". An image already at or below this on both axes
// is served unscaled (no upsampling).
const maxThumbDimension = 320

// maxDecodePixels bounds how many pixels renderImage will fully decode into
// memory for thumbnailing. A file whose header declares more than this is
// treated as too large to safely thumbnail and falls back rather than
// risking an OOM from decoding a huge (or maliciously crafted) image —
// sp008 Task 3 edge case: "very large image (thumbnail must not OOM —
// decode-bounded)". At 4 bytes/pixel (RGBA) this caps the decode buffer
// around 256MB.
const maxDecodePixels = 64_000_000

// isImageExt reports whether path's extension is one of the formats
// renderImage understands. Detection is extension-based (matching the rest
// of render.go's dispatch, e.g. isMarkdown); content that turns out not to
// actually be a decodable image of that format still degrades safely via
// renderImage's own decode-error handling (sp008 Task 3 edge case: non-image
// content with an image extension must not crash).
func isImageExt(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".png", ".jpg", ".jpeg", ".gif":
		return true
	default:
		return false
	}
}

// renderImage serves path's image content: a downscaled thumbnail by
// default, or the original file bytes streamed verbatim when full is true —
// the ft005 api_surface image row (thumbnail default, full-res on ?full).
// The full path never re-encodes: it is a raw byte stream of the source
// file, so it is byte-identical with zero re-encoding loss (sp008 Task 3
// success criteria). Any failure along the way (corrupt content, an
// extension that doesn't match real content, an unsupported format, or a
// declared size too large to safely decode) degrades to the same safe
// fallback used elsewhere in render.go — never a crash, never a 500 (sp008
// Task 3 edge cases: non-image with image extension, 0-byte image, very
// large image, unsupported format).
func renderImage(w http.ResponseWriter, path string, fi os.FileInfo, full bool) {
	if fi.Size() == 0 {
		renderFallback(w, path, fi)
		return
	}

	f, err := os.Open(path)
	if err != nil {
		renderFallback(w, path, fi)
		return
	}
	defer f.Close()

	if full {
		serveOriginalImage(w, f, path, fi)
		return
	}

	// Learn the format + declared dimensions from the header alone —
	// image.DecodeConfig reads only the header, never pixel data — so a
	// huge (or malicious) declared size is caught BEFORE any full decode
	// is attempted (sp008 Task 3 edge case: decode-bounded).
	cfg, _, err := image.DecodeConfig(f)
	if err != nil {
		renderFallback(w, path, fi)
		return
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || int64(cfg.Width)*int64(cfg.Height) > maxDecodePixels {
		renderFallback(w, path, fi)
		return
	}

	if _, err := f.Seek(0, io.SeekStart); err != nil {
		renderFallback(w, path, fi)
		return
	}
	src, _, err := image.Decode(f)
	if err != nil {
		renderFallback(w, path, fi)
		return
	}

	thumb := scaleToMax(src, maxThumbDimension)

	var buf bytes.Buffer
	if err := png.Encode(&buf, thumb); err != nil {
		renderFallback(w, path, fi)
		return
	}

	w.Header().Set("Content-Type", "image/png")
	_, _ = w.Write(buf.Bytes())
}

// scaleToMax returns src scaled down so its longest side is at most maxDim,
// preserving aspect ratio. An image already within maxDim on both axes is
// returned unchanged — thumbnails never upscale.
func scaleToMax(src image.Image, maxDim int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= maxDim && h <= maxDim {
		return src
	}

	var newW, newH int
	if w >= h {
		newW = maxDim
		newH = int(float64(h) * float64(maxDim) / float64(w))
	} else {
		newH = maxDim
		newW = int(float64(w) * float64(maxDim) / float64(h))
	}
	if newW < 1 {
		newW = 1
	}
	if newH < 1 {
		newH = 1
	}

	dst := image.NewRGBA(image.Rect(0, 0, newW, newH))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, b, draw.Over, nil)
	return dst
}

// serveOriginalImage streams f's bytes to w unmodified with a Content-Type
// derived from path's extension — no decode, no re-encode, so the response
// is byte-identical to the source file (sp008 Task 3 success criteria: full
// path streams original bytes without re-encoding loss).
func serveOriginalImage(w http.ResponseWriter, f *os.File, path string, fi os.FileInfo) {
	w.Header().Set("Content-Type", imageContentTypeByExt(path))
	w.Header().Set("Content-Length", strconv.FormatInt(fi.Size(), 10))
	_, _ = io.Copy(w, f)
}

// imageContentTypeByExt maps path's extension to its image MIME type.
// isImageExt has already gated dispatch to one of these extensions.
func imageContentTypeByExt(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	default:
		return "application/octet-stream"
	}
}
