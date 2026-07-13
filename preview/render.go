package main

import (
	"fmt"
	"html"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/alecthomas/chroma/v2/lexers"
)

// maxRenderSize bounds how many bytes of a file's content the code/md
// renderers will read and render. A huge file must not make a single
// /file/<path> request buffer the whole thing into memory (sp008 Task 2
// edge case: huge file, cap render size).
const maxRenderSize = 5 * 1024 * 1024 // 5 MiB

// renderFile stats path and dispatches to the renderer selected by the
// path's type: markdown extensions render via goldmark, image extensions
// render via renderImage (thumbnail by default, full-res when full is true
// — the ft005 api_surface image row), video extensions render via
// renderVideo (poster frame by default, raw bytes when full is true — the
// ft005 api_surface video row's byte-stream half; the ?live HTML wrapper is
// handled separately by server.go's handleFile), anything chroma recognises
// (including its plaintext lexer, which covers .txt and unmatched-but-
// textual files) renders as syntax HTML, everything else — unknown
// extensions, files with no extension chroma can't match, and binary
// content — falls back to a safe "no preview" page. It never panics and
// never emits a 500 for a problem with the FILE itself (sp008 Task 2/3/8
// success criteria); only a genuine I/O failure reading an existing,
// already root-jailed path falls through to 500.
func renderFile(w http.ResponseWriter, path string, full bool) {
	fi, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if fi.IsDir() {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	// Images are binary content that must never pass through the capped
	// text read below (readCapped's 5 MiB cap exists for text/code/markdown
	// rendering; an image's full=true response must stream every byte of
	// the source unmodified — sp008 Task 3 success criteria: no
	// re-encoding loss).
	if isImageExt(path) {
		renderImage(w, path, fi, full)
		return
	}

	// Video is binary content that must never pass through the capped text
	// read below, same rationale as the image branch above (sp008 Task 8:
	// poster frame by default, raw bytes on full — the ft005 api_surface
	// video row's byte-stream half; the ?live HTML wrapper is special-cased
	// in server.go's handleFile since it needs the original request path,
	// not just the resolved filesystem path renderFile receives).
	if isVideoExt(path) {
		renderVideo(w, path, fi, full)
		return
	}

	// STL is binary content, same rationale as image/video above -- must
	// never pass through the capped text read below. Unlike image/video it
	// has no thumbnail tier: the default (full=false) response IS the live
	// orbit-viewer page (sp008 Task 9 success criteria: "loads live
	// directly, no thumbnail"); full=true streams the raw bytes that page's
	// own client-side fetch pulls via ?full.
	if isSTLExt(path) {
		renderSTL(w, path, fi, full)
		return
	}

	src, truncated, err := readCapped(path, fi.Size())
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	switch {
	case isMarkdown(path):
		renderMarkdown(w, src, truncated)
	case lexers.Match(path) != nil:
		renderCode(w, path, src, truncated)
	default:
		renderFallback(w, path, fi)
	}
}

// isMarkdown reports whether path's extension is a markdown extension —
// checked before the chroma lexer dispatch so markdown always renders via
// goldmark rather than chroma's own markdown lexer.
func isMarkdown(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".md", ".markdown":
		return true
	default:
		return false
	}
}

// isD2Ext reports whether path's extension is d2 (case-insensitive), the
// same detection style as isImageExt/isVideoExt/isSTLExt. sp008 Task 7:
// server.go's handleFile special-cases this before the renderFile dispatch
// so a .d2 file resolves to a cross-origin-proxied embed of [[ft002]]
// (d2-router) instead of the plain code render chroma would otherwise give
// it (chroma has no d2 lexer, so without this it would fall through to the
// plaintext lexer).
func isD2Ext(path string) bool {
	return strings.ToLower(filepath.Ext(path)) == ".d2"
}

// isAkmZettel reports whether resolved — an absolute, already root-jailed
// filesystem path (path.go's resolveInRoot output) — is a markdown zettel
// under root's AKM notes tree (docs/notes/**.md, any depth including
// archive/). This mirrors the subtree akm-graph/parser.go's WalkNotes walks
// to build the [[ft004]] graph. sp008 Task 7: server.go's handleFile
// special-cases these paths before the renderFile dispatch so they resolve
// to a cross-origin iframe of akm-graph instead of the plain goldmark
// markdown render the isMarkdown branch would otherwise give them.
//
// root is compared via filepath.Abs (NOT symlink-resolved) to match
// path.go's resolveInRoot, which performs its own containment check against
// the same non-symlink-resolved root. A known, non-blocking gap: the single
// hub file docs/notes/akm.md is a symlink whose EvalSymlinks target
// (claude/akm/akm.md) escapes this prefix check, so that one file still
// renders as plain markdown rather than the akm-graph embed — akm-graph's
// own WalkNotes special-cases exactly this file for the same underlying
// reason (see its hubFiles comment).
func isAkmZettel(root, resolved string) bool {
	if strings.ToLower(filepath.Ext(resolved)) != ".md" {
		return false
	}
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	notesDir := filepath.Join(filepath.Clean(absRoot), "docs", "notes") + string(filepath.Separator)
	return strings.HasPrefix(resolved, notesDir)
}

// readCapped reads up to maxRenderSize bytes of path's content, reporting
// whether the file was longer than that (sp008 Task 2 edge case: huge
// file must not be read/rendered in full).
func readCapped(path string, size int64) (data []byte, truncated bool, err error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false, err
	}
	defer f.Close()

	limit := size
	if limit > maxRenderSize {
		limit = maxRenderSize
	}
	buf := make([]byte, limit)
	n, err := io.ReadFull(f, buf)
	if err != nil && err != io.ErrUnexpectedEOF && err != io.EOF {
		return nil, false, err
	}
	return buf[:n], size > maxRenderSize, nil
}

// renderFallback serves a safe "no preview" HTML page for a type chroma
// doesn't recognise and that isn't markdown — covers unknown extensions,
// extensionless files, and binary content. It always returns 200, never a
// 500 (sp008 Task 2 success criteria: unknown/binary type falls back
// safely, never a 500).
func renderFallback(w http.ResponseWriter, path string, fi os.FileInfo) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html><html><head><meta charset="utf-8"></head>`+
		`<body class="preview-fallback"><p>no preview available for %s (%d bytes)</p></body></html>`,
		html.EscapeString(filepath.Base(path)), fi.Size())
}

// renderPlainFallback serves src as an HTML-escaped <pre> block. Used when
// a renderer that claims to understand the content (goldmark, chroma
// tokenising) errors out anyway, so a render failure still degrades to a
// safe response instead of a 500.
func renderPlainFallback(w http.ResponseWriter, src []byte, truncated bool) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body class="preview-fallback"><pre>`)
	fmt.Fprint(w, html.EscapeString(string(src)))
	if truncated {
		fmt.Fprint(w, "\n[preview truncated]")
	}
	fmt.Fprint(w, `</pre></body></html>`)
}
