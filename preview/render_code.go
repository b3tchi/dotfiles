package main

import (
	"fmt"
	"net/http"

	"github.com/alecthomas/chroma/v2"
	chromahtml "github.com/alecthomas/chroma/v2/formatters/html"
	"github.com/alecthomas/chroma/v2/lexers"
	"github.com/alecthomas/chroma/v2/styles"
)

// renderCode renders src as syntax-highlighted HTML via chroma, the lexer
// selected by path's filename/extension — the ft005 api_surface
// /file/<path> code row. Falls back to an HTML-escaped <pre> if
// tokenising fails for some reason — never a 500 for a source file chroma
// can't parse (sp008 Task 2 anti-pattern: no panics in handlers).
func renderCode(w http.ResponseWriter, path string, src []byte, truncated bool) {
	lexer := lexers.Match(path)
	if lexer == nil {
		lexer = lexers.Fallback
	}
	lexer = chroma.Coalesce(lexer)

	iterator, err := lexer.Tokenise(nil, string(src))
	if err != nil {
		renderPlainFallback(w, src, truncated)
		return
	}

	formatter := chromahtml.New(chromahtml.WithClasses(true), chromahtml.TabWidth(2))
	// Dark to match the webview shell — the light "github" style rendered
	// near-black tokens that were unreadable once the page background went
	// dark (render_theme.go).
	style := styles.Get("github-dark")
	if style == nil {
		style = styles.Fallback
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!DOCTYPE html><html><head><meta charset="utf-8"><style>`)
	_ = formatter.WriteCSS(w, style)
	// Shared palette last so its `.chroma` background override beats chroma's
	// own; chroma's token selectors (.chroma .k, …) are untouched.
	fmt.Fprint(w, textPreviewCSS)
	fmt.Fprint(w, `</style></head><body class="code-preview">`)
	// formatter.Format only errors on a write failure to w (e.g. a broken
	// connection); there is nothing safe to fall back to at that point
	// since headers/partial body are already flushed, so the error is
	// intentionally not treated as a render failure.
	_ = formatter.Format(w, style, iterator)
	if truncated {
		fmt.Fprint(w, `<p class="preview-truncated">[preview truncated]</p>`)
	}
	fmt.Fprint(w, textPreviewScript()+`</body></html>`)
}
