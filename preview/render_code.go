package main

import (
	"fmt"
	"html"
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

// renderCodeNative serves the GET /file/<path>?native payload for a
// classified "code" file (sp022 Task 3 success criteria): a chroma
// fragment using INLINE styles (WithClasses(false)) with no
// <html>/<head>/<style> wrapper at all — Qt rich text (QML
// Text.RichText/MarkdownText) cannot resolve CSS classes the way a browser
// can, so every token needs a literal style="color:..." attribute instead
// of chroma's class-based CSS + a <style> block. Unlike renderCode's
// class-based full-document render (left untouched — it still serves the
// no-?native / browser-fallback response), there is nothing here to wrap:
// formatter.Format's own output (its default <pre>...) IS the whole
// fragment.
//
// A tokenise failure degrades to an HTML-escaped plain-text fragment with
// no <pre> — readable text, never markup, never a 500 (sp022 Task 3 edge
// case: "chroma tokenise error → HTML-escaped plain <pre>-less text
// fragment, never 500").
func renderCodeNative(w http.ResponseWriter, path string, src []byte, truncated bool) {
	lexer := lexers.Match(path)
	if lexer == nil {
		lexer = lexers.Fallback
	}
	lexer = chroma.Coalesce(lexer)

	iterator, err := lexer.Tokenise(nil, string(src))
	if err != nil {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, html.EscapeString(string(src)))
		if truncated {
			fmt.Fprint(w, "\n[preview truncated]")
		}
		return
	}

	formatter := chromahtml.New(chromahtml.WithClasses(false), chromahtml.TabWidth(2))
	style := styles.Get("github-dark")
	if style == nil {
		style = styles.Fallback
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// formatter.Format only errors on a write failure to w, same rationale
	// as renderCode above — nothing safe to fall back to once headers are
	// already flushed, so it is intentionally not treated as a render
	// failure.
	_ = formatter.Format(w, style, iterator)
	if truncated {
		fmt.Fprint(w, "\n[preview truncated]")
	}
}
