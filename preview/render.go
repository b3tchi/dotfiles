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
// path's type: markdown extensions render via goldmark, anything chroma
// recognises (including its plaintext lexer, which covers .txt and
// unmatched-but-textual files) renders as syntax HTML, everything else —
// unknown extensions, files with no extension chroma can't match, and
// binary content — falls back to a safe "no preview" page. It never
// panics and never emits a 500 for a problem with the FILE itself (sp008
// Task 2 success criteria); only a genuine I/O failure reading an
// existing, already root-jailed path falls through to 500.
func renderFile(w http.ResponseWriter, path string) {
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
