package main

import (
	"io"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTextPreviewsAreDark asserts every HTML-rendered *text* preview
// (markdown, syntax-highlighted code, and both plain fallbacks) carries the
// shared dark palette. Before this, renderMarkdown emitted no CSS at all and
// renderCode used chroma's light "github" style, so a preview flashed a white
// page inside an otherwise dark webview shell (static/shell.html is #111).
func TestTextPreviewsAreDark(t *testing.T) {
	cases := []struct {
		name     string
		filename string
		content  []byte
	}{
		{"markdown", "sample.md", []byte("# Hello\n\nWorld\n")},
		{"code", "sample.go", []byte("package main\n\nfunc main() {}\n")},
		{"plaintext", "sample.txt", []byte("just some plain text\n")},
		{"unknown", "sample.xyz123unknown", []byte{0x00, 0x01, 0xFF}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := renderToString(t, tc.filename, tc.content)

			if !strings.Contains(body, previewBG) {
				t.Errorf("rendered %s carries no dark background (want %q)\n%s",
					tc.filename, previewBG, truncateForLog(body))
			}
			if strings.Contains(body, "background: #fff") ||
				strings.Contains(body, "background:#fff") ||
				strings.Contains(body, "background: white") {
				t.Errorf("rendered %s still sets a white background\n%s",
					tc.filename, truncateForLog(body))
			}
		})
	}
}

// TestTextPreviewsZoom asserts text previews ship the keyboard zoom script.
// The image wrapper (static/app.js imageDoc) has had a fit<->1:1 toggle since
// sp008 Task 3, but text previews had no zoom at all — font-size scaling is
// the text analogue.
func TestTextPreviewsZoom(t *testing.T) {
	cases := []struct {
		name     string
		filename string
		content  []byte
	}{
		{"markdown", "sample.md", []byte("# Hello\n")},
		{"code", "sample.go", []byte("package main\n")},
		{"plaintext", "sample.txt", []byte("plain\n")},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := renderToString(t, tc.filename, tc.content)

			if !strings.Contains(body, "keydown") {
				t.Errorf("rendered %s has no keydown handler — zoom missing\n%s",
					tc.filename, truncateForLog(body))
			}
			// The zoom steps must be driven off documentElement font-size,
			// which is what makes both prose and <pre> scale together.
			if !strings.Contains(body, "documentElement.style.fontSize") {
				t.Errorf("rendered %s does not scale root font-size\n%s",
					tc.filename, truncateForLog(body))
			}
			// The image doc focuses itself on load so its keydown listener
			// receives keys inside the iframe; text previews need the same or
			// zoom silently does nothing.
			if !strings.Contains(body, "window.focus()") {
				t.Errorf("rendered %s never focuses itself — iframe keydown would not fire\n%s",
					tc.filename, truncateForLog(body))
			}
		})
	}
}

// TestCodePreviewUsesDarkChromaStyle pins the chroma style to a dark one.
// Asserted separately from the palette test because a light chroma style
// would still pass the body-background check while leaving every token colour
// tuned for a white page (near-black text on near-black background).
func TestCodePreviewUsesDarkChromaStyle(t *testing.T) {
	body := renderToString(t, "sample.go", []byte("package main\n\nfunc main() {}\n"))

	if !strings.Contains(body, `class="chroma"`) {
		t.Fatalf("expected chroma output, got:\n%s", truncateForLog(body))
	}
	// github-dark's comment/keyword colours; the light "github" style emits
	// #999988 / #000000 for these instead.
	if !strings.Contains(body, "#f85149") && !strings.Contains(body, "#ff7b72") {
		t.Errorf("code preview does not look like a dark chroma style\n%s",
			truncateForLog(body))
	}
}

// TestShellIframeIsNotWhite guards the webview shell itself: the #content
// iframe had `background: #fff`, which painted a white rectangle over the
// dark shell for the instant before (and the whole time, for a transparent
// document) the framed page rendered.
func TestShellIframeIsNotWhite(t *testing.T) {
	f, err := staticFS.Open("static/shell.html")
	if err != nil {
		t.Fatalf("open embedded shell.html: %v", err)
	}
	defer f.Close()

	raw, err := io.ReadAll(f)
	if err != nil {
		t.Fatalf("read embedded shell.html: %v", err)
	}
	shell := string(raw)

	if strings.Contains(shell, "background: #fff") || strings.Contains(shell, "background:#fff") {
		t.Errorf("shell.html still paints an element white:\n%s", shell)
	}
	if !strings.Contains(shell, previewBG) {
		t.Errorf("shell.html does not use the shared dark background %q:\n%s", previewBG, shell)
	}
}

// renderToString runs renderFile over a temp file and returns the body.
func renderToString(t *testing.T, filename string, content []byte) string {
	t.Helper()

	dir := t.TempDir()
	path := filepath.Join(dir, filename)
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	rec := httptest.NewRecorder()
	renderFile(rec, path, false)

	if rec.Code != 200 {
		t.Fatalf("renderFile(%s) status = %d, want 200", filename, rec.Code)
	}
	return rec.Body.String()
}

// truncateForLog caps a rendered document so a failure message stays readable.
func truncateForLog(s string) string {
	const max = 600
	if len(s) <= max {
		return s
	}
	return s[:max] + "\n… [truncated]"
}
