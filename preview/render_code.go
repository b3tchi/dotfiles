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
	style := styles.Get("github")
	if style == nil {
		style = styles.Fallback
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!DOCTYPE html><html><head><meta charset="utf-8"><style>`)
	_ = formatter.WriteCSS(w, style)
	fmt.Fprint(w, `</style></head><body class="code-preview">`)
	// formatter.Format only errors on a write failure to w (e.g. a broken
	// connection); there is nothing safe to fall back to at that point
	// since headers/partial body are already flushed, so the error is
	// intentionally not treated as a render failure.
	_ = formatter.Format(w, style, iterator)
	if truncated {
		fmt.Fprint(w, `<p class="preview-truncated">[preview truncated]</p>`)
	}
	fmt.Fprint(w, `</body></html>`)
}
