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
	fmt.Fprint(w, `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body class="markdown-preview">`)
	_, _ = w.Write(buf.Bytes())
	if truncated {
		fmt.Fprint(w, `<p class="preview-truncated">[preview truncated]</p>`)
	}
	fmt.Fprint(w, `</body></html>`)
}
