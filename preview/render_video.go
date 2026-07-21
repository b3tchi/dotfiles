package main

import (
	"bytes"
	"context"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ffmpegTimeout bounds how long a single poster-frame extraction is allowed
// to run. ffmpeg's "-frames:v 1" flag already makes extraction cheap
// regardless of source length (it stops after the first decodable frame),
// but a pathological/corrupt input must still not block a request goroutine
// unbounded (sp008 plan anti-pattern: external renderers MUST carry a
// timeout; Task 8 edge case: very long video -> bounded time).
const ffmpegTimeout = 5 * time.Second

// isVideoExt reports whether path's extension is one of the formats
// renderVideo understands. Detection is extension-based, matching
// isImageExt/isMarkdown's dispatch style in render.go; content that turns
// out not to actually be decodable video still degrades safely via
// renderVideo's own ffmpeg-error handling (sp008 Task 8 edge case: 0-byte/
// corrupt video -> icon, not a crash).
func isVideoExt(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".mp4", ".webm", ".mov", ".mkv", ".avi":
		return true
	default:
		return false
	}
}

// videoContentTypeByExt maps path's extension to its video MIME type.
// isVideoExt has already gated dispatch to one of these extensions.
func videoContentTypeByExt(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".mp4":
		return "video/mp4"
	case ".webm":
		return "video/webm"
	case ".mov":
		return "video/quicktime"
	case ".mkv":
		return "video/x-matroska"
	case ".avi":
		return "video/x-msvideo"
	default:
		return "application/octet-stream"
	}
}

// renderVideo serves path's video content: an ffmpeg-extracted poster frame
// by default, or the original file bytes streamed verbatim when full is
// true (the byte source the live wrapper's <video> element points at via
// ?full — ft005 api_surface video row: "poster frame by default and a
// <video> element on ?live"). Any failure along the way (ffmpeg missing,
// 0-byte/corrupt content, an extension that doesn't match real content, a
// format ffmpeg can't decode a first frame from) degrades to the same safe
// fallback used elsewhere in render.go — never a crash, never a 500 (sp008
// Task 8 edge cases).
func renderVideo(w http.ResponseWriter, path string, fi os.FileInfo, full bool) {
	if fi.Size() == 0 {
		renderFallback(w, path, fi)
		return
	}

	if full {
		serveOriginalVideo(w, path, fi)
		return
	}

	data, err := posterFor(path, fi)
	if err != nil {
		renderFallback(w, path, fi)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	_, _ = w.Write(data)
}

// serveOriginalVideo streams path's bytes to w unmodified with a
// Content-Type derived from its extension — no decode, no re-encode, so the
// response is byte-identical to the source file (parity with
// serveOriginalImage's full-res tier).
func serveOriginalVideo(w http.ResponseWriter, path string, fi os.FileInfo) {
	f, err := os.Open(path)
	if err != nil {
		renderFallback(w, path, fi)
		return
	}
	defer f.Close()

	w.Header().Set("Content-Type", videoContentTypeByExt(path))
	w.Header().Set("Content-Length", strconv.FormatInt(fi.Size(), 10))
	_, _ = io.Copy(w, f)
}

// renderVideoLive serves the HTML shell for GET /file/<path>?live: a page
// embedding a <video> element whose src points back at the same path's
// ?full byte-stream (ft005 api_surface: "<video> element on ?live"). reqPath
// is the already root-jail-validated request path (server.go's handleFile
// resolves and validates it via resolveInRoot before this is ever called),
// so no further filesystem access is needed here — this handler only
// formats a link back to the existing /file/<path>?full route, which is
// what actually streams the playable bytes. Kept as a distinct code path
// from renderVideo's full flag specifically to avoid a self-referential
// loop: reusing one flag for both "return the live wrapper" and "return raw
// bytes" would make the wrapper's own <video src> re-trigger the wrapper
// instead of the byte stream.
func renderVideoLive(w http.ResponseWriter, reqPath string) {
	src := (&url.URL{Path: "/file/" + reqPath, RawQuery: "full"}).String()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html><html><head><meta charset="utf-8"></head>`+
		`<body class="preview-video-live"><video controls autoplay src="%s"></video></body></html>`,
		html.EscapeString(src))
}

// posterEntry caches one video file's extracted poster frame. Its mutex
// serializes concurrent generation attempts for the SAME file so N
// simultaneous requests for one video invoke ffmpeg once, not N times
// (sp008 Task 8 edge case: concurrent poster requests -> cache/bound); the
// cached bytes are reused as long as the file's mtime/size are unchanged.
type posterEntry struct {
	mu         sync.Mutex
	haveGen    bool // a generation attempt has completed at least once
	ok         bool // that attempt succeeded
	data       []byte
	modTime    time.Time
	size       int64
	lastAccess time.Time // for LRU eviction; guarded by posterCacheMu
}

var (
	posterCacheMu sync.Mutex
	posterCache   = map[string]*posterEntry{}
)

// posterCacheMaxEntries bounds the poster cache so a long-lived daemon that
// previews many distinct videos over its lifetime does not grow posterCache
// without limit (dotfiles-e6o). Eviction is LRU by lastAccess. A var so tests
// can shrink it. 128 poster JPEGs is a few MB — ample for a personal tree,
// still a hard ceiling for a large video collection.
var posterCacheMaxEntries = 128

// evictPosterCacheLocked removes least-recently-accessed entries until the
// cache is within posterCacheMaxEntries. Caller must hold posterCacheMu.
// O(n) per evicted entry, which is fine at this cap and frequency (only runs
// when a new path grows the map past the ceiling). Evicting an entry whose
// per-file mu is held mid-generation is safe: that goroutine keeps its own
// reference and completes; only future lookups miss and regenerate.
func evictPosterCacheLocked() {
	for len(posterCache) > posterCacheMaxEntries {
		var oldestKey string
		var oldest time.Time
		first := true
		for k, e := range posterCache {
			if first || e.lastAccess.Before(oldest) {
				oldestKey, oldest, first = k, e.lastAccess, false
			}
		}
		delete(posterCache, oldestKey)
	}
}

// posterFor returns path's cached poster bytes, (re)generating via ffmpeg
// only when no valid cache entry exists for the file's current mtime/size.
func posterFor(path string, fi os.FileInfo) ([]byte, error) {
	posterCacheMu.Lock()
	e, ok := posterCache[path]
	if !ok {
		e = &posterEntry{}
		posterCache[path] = e
	}
	e.lastAccess = time.Now()
	if !ok {
		// The map just grew — bound it. Runs after lastAccess is set so the
		// entry we just created (newest) is never the one evicted.
		evictPosterCacheLocked()
	}
	posterCacheMu.Unlock()

	e.mu.Lock()
	defer e.mu.Unlock()

	if e.haveGen && e.modTime.Equal(fi.ModTime()) && e.size == fi.Size() {
		if e.ok {
			return e.data, nil
		}
		return nil, fmt.Errorf("preview: cached poster generation failed for %s", path)
	}

	data, err := extractPosterFrame(path)
	e.haveGen = true
	e.modTime = fi.ModTime()
	e.size = fi.Size()
	if err != nil {
		e.ok = false
		e.data = nil
		return nil, err
	}
	e.ok = true
	e.data = data
	return data, nil
}

// extractPosterFrame invokes ffmpeg via an explicit arg vector (never a
// shell string) to extract path's first decodable frame as a JPEG, bounded
// by ffmpegTimeout (sp008 plan anti-pattern: external renderers MUST carry
// a timeout + never block a request goroutine unbounded). ffmpeg's absence
// is detected up front via exec.LookPath so the caller degrades to the icon
// fallback instead of a 500 (sp008 Task 8 success criteria).
func extractPosterFrame(path string) ([]byte, error) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		return nil, fmt.Errorf("preview: ffmpeg not found: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), ffmpegTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ffmpeg",
		"-v", "error",
		"-i", path,
		"-frames:v", "1",
		"-f", "image2",
		"-c:v", "mjpeg",
		"-",
	)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("preview: ffmpeg poster extraction failed for %s: %w: %s", path, err, stderr.String())
	}
	if stdout.Len() == 0 {
		return nil, fmt.Errorf("preview: ffmpeg produced no poster frame for %s", path)
	}
	return stdout.Bytes(), nil
}
