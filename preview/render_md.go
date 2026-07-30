package main

import (
	"bytes"
	"fmt"
	"net/http"

	"github.com/yuin/goldmark"
)

// renderMarkdown renders src as HTML via goldmark — the ft005 api_surface
// /file/<path> markdown row. A goldmark conversion failure falls back to
// an HTML-escaped <pre> rather than a 500 (sp008 Task 2 anti-pattern: no
// panics in handlers, safe fallback).
func renderMarkdown(w http.ResponseWriter, src []byte, truncated bool) {
	var buf bytes.Buffer
	if err := goldmark.Convert(src, &buf); err != nil {
		renderPlainFallback(w, src, truncated)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!DOCTYPE html><html><head><meta charset="utf-8">`+
		textPreviewStyle()+`</head><body class="markdown-preview">`)
	_, _ = w.Write(buf.Bytes())
	if truncated {
		fmt.Fprint(w, `<p class="preview-truncated">[preview truncated]</p>`)
	}
	fmt.Fprint(w, textPreviewScript()+`</body></html>`)
}

// renderMarkdownNative serves the GET /file/<path>?native payload for a
// classified "md" file (sp022 Task 3 success criteria): the file's RAW
// bytes as text/plain, not goldmark's rendered HTML. The QML client (T4)
// paints markdown itself via Qt's own Text.MarkdownText delegate, so the
// native tier's job is handing over source text, not pre-rendered markup —
// the opposite of renderMarkdown above, which exists for the browser
// fallback / non-native path and is left untouched.
//
// truncated appends the same literal "[preview truncated]" marker
// renderPlainFallback uses elsewhere in this package, straight onto the raw
// bytes (no HTML wrapper exists here to hold a styled <p> the way the
// non-native renderer's marker does).
func renderMarkdownNative(w http.ResponseWriter, src []byte, truncated bool) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write(src)
	if truncated {
		fmt.Fprint(w, "\n[preview truncated]")
	}
}
