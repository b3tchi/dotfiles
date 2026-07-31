package main

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRenderFileByType is the sp008 Task 2 table test: {go, md, txt,
// unknown} fixtures each assert a content-type + a signature substring of
// the rendered output (ft005 api_surface /file/<path> renderer-by-type
// contract).
func TestRenderFileByType(t *testing.T) {
	cases := []struct {
		name        string
		filename    string
		content     []byte
		wantStatus  int
		wantCT      string
		wantBodyHas string
	}{
		{
			name:        "go",
			filename:    "sample.go",
			content:     []byte("package main\n\nfunc main() {}\n"),
			wantStatus:  200,
			wantCT:      "text/html",
			wantBodyHas: `class="chroma"`,
		},
		{
			name:        "markdown",
			filename:    "sample.md",
			content:     []byte("# Hello\n\nWorld\n"),
			wantStatus:  200,
			wantCT:      "text/html",
			wantBodyHas: "<h1>Hello</h1>",
		},
		{
			name:        "txt",
			filename:    "sample.txt",
			content:     []byte("just some plain text\n"),
			wantStatus:  200,
			wantCT:      "text/html",
			wantBodyHas: `class="chroma"`,
		},
		{
			name:        "unknown",
			filename:    "sample.xyz123unknown",
			content:     []byte{0x00, 0x01, 0x02, 0xFF, 0xFE},
			wantStatus:  200,
			wantCT:      "text/html",
			wantBodyHas: "no preview",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, tc.filename)
			if err := os.WriteFile(path, tc.content, 0o644); err != nil {
				t.Fatalf("write fixture: %v", err)
			}

			rec := httptest.NewRecorder()
			renderFile(rec, path, false)

			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d (body: %s)", rec.Code, tc.wantStatus, rec.Body.String())
			}
			if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, tc.wantCT) {
				t.Errorf("content-type = %q, want to contain %q", ct, tc.wantCT)
			}
			if body := rec.Body.String(); !strings.Contains(body, tc.wantBodyHas) {
				t.Errorf("body does not contain %q; body=%s", tc.wantBodyHas, body)
			}
		})
	}
}

// TestRenderFileEmpty proves an empty file renders without error (sp008
// Task 2 edge case: empty file).
func TestRenderFileEmpty(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "empty.go")
	if err := os.WriteFile(path, []byte{}, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	rec := httptest.NewRecorder()
	renderFile(rec, path, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `class="chroma"`) {
		t.Errorf("empty file body missing chroma wrapper: %s", rec.Body.String())
	}
}

// TestRenderFileNoExtension proves a file with no extension and no chroma
// filename match falls back safely rather than crashing (sp008 Task 2 edge
// case: file with no extension).
func TestRenderFileNoExtension(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "noext")
	if err := os.WriteFile(path, []byte("mystery content"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	rec := httptest.NewRecorder()
	renderFile(rec, path, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "no preview") {
		t.Errorf("no-extension file body missing fallback marker: %s", rec.Body.String())
	}
}

// TestRenderFileHugeCapped proves a file larger than maxRenderSize is
// rendered with a bounded read, not the whole file (sp008 Task 2 edge
// case: huge file, cap render size).
func TestRenderFileHugeCapped(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "huge.go")

	// One byte over the cap so the file is provably "huge" without
	// actually allocating tens of megabytes in the test.
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create fixture: %v", err)
	}
	line := strings.Repeat("a", 1024) + "\n"
	written := 0
	for written < maxRenderSize+len(line) {
		if _, err := f.WriteString(line); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
		written += len(line)
	}
	f.Close()

	rec := httptest.NewRecorder()
	renderFile(rec, path, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "preview-truncated") {
		t.Errorf("huge file response missing truncation marker; body len=%d", rec.Body.Len())
	}
	// The rendered body must stay in the same order of magnitude as the
	// cap, not balloon to the full file size (which is > maxRenderSize).
	if rec.Body.Len() > maxRenderSize*2 {
		t.Errorf("huge file response body len=%d, want bounded near maxRenderSize=%d", rec.Body.Len(), maxRenderSize)
	}
}

// TestRenderFileUnicodeCRLF proves unicode content and CRLF line endings
// survive rendering intact (sp008 Task 2 edge case).
func TestRenderFileUnicodeCRLF(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "unicode.txt")
	content := "héllo wörld π\r\nsecond line\r\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	rec := httptest.NewRecorder()
	renderFile(rec, path, false)

	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "wörld") || !strings.Contains(rec.Body.String(), "π") {
		t.Errorf("unicode content not preserved in body: %s", rec.Body.String())
	}
}

// TestRenderFileNonexistent proves a nonexistent path renders 404, not a
// 500 (sp008 Task 2 edge case: nonexistent path -> 404 not 500).
func TestRenderFileNonexistent(t *testing.T) {
	dir := t.TempDir()
	rec := httptest.NewRecorder()
	renderFile(rec, filepath.Join(dir, "does-not-exist.go"), false)

	if rec.Code != 404 {
		t.Fatalf("status = %d, want 404 (body: %s)", rec.Code, rec.Body.String())
	}
}

// TestIsD2Ext proves the .d2 extension is detected case-insensitively, the
// same style as isImageExt/isVideoExt/isSTLExt (sp008 Task 7: .d2 files
// dispatch to the d2-router embed rather than the plain code/text render).
func TestIsD2Ext(t *testing.T) {
	cases := []struct {
		path string
		want bool
	}{
		{"diagram.d2", true},
		{"diagram.D2", true},
		{"/abs/path/network.d2", true},
		{"notes.md", false},
		{"noext", false},
		{"diagram.d2x", false},
	}
	for _, tc := range cases {
		if got := isD2Ext(tc.path); got != tc.want {
			t.Errorf("isD2Ext(%q) = %v, want %v", tc.path, got, tc.want)
		}
	}
}

// TestIsAkmZettel proves an akm zettel path is detected as any markdown
// file under root's docs/notes/** subtree — the same subtree ft004's
// WalkNotes (akm-graph/parser.go) walks to build the graph (sp008 Task 7:
// these paths dispatch to the akm-graph embed rather than the plain
// goldmark markdown render).
func TestIsAkmZettel(t *testing.T) {
	root := "/repo"
	cases := []struct {
		name     string
		resolved string
		want     bool
	}{
		{"zettel", "/repo/docs/notes/us006.md", true},
		{"nested archive zettel", "/repo/docs/notes/archive/spec/sp001.md", true},
		{"non-md under notes", "/repo/docs/notes/diagram.d2", false},
		{"md outside notes", "/repo/README.md", false},
		{"md at docs root", "/repo/docs/board.md", false},
		{"sibling dir name collision", "/repo/docs/notes-other/x.md", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isAkmZettel(root, tc.resolved); got != tc.want {
				t.Errorf("isAkmZettel(%q, %q) = %v, want %v", root, tc.resolved, got, tc.want)
			}
		})
	}
}

// --- classifyPath: sp022 Task 2 type classifier -------------------------

// TestClassifyPathByType is the sp022 Task 2 test_plan table test: one
// fixture per emitted type (image | svg | md | code | video | html | akm |
// stl | none), proving classifyPath returns exactly the 9-value vocabulary
// the QML client (T4) will switch its render tier on — no extras, no
// renames (sp022 Task 2 downstream-contract note).
func TestClassifyPathByType(t *testing.T) {
	root := t.TempDir()
	mkfile := func(rel string) string {
		abs := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatalf("mkdir for fixture %q: %v", rel, err)
		}
		if err := os.WriteFile(abs, []byte("fixture"), 0o644); err != nil {
			t.Fatalf("write fixture %q: %v", rel, err)
		}
		return abs
	}

	cases := []struct {
		name string
		rel  string
		want string
	}{
		{"image", "photo.png", "image"},
		{"svg (d2 source)", "diagram.d2", "svg"},
		{"md", "note.md", "md"},
		{"code", "main.go", "code"},
		{"video", "clip.mp4", "video"},
		{"html", "page.html", "html"},
		{"akm zettel", "docs/notes/us006.md", "akm"},
		{"stl", "model.stl", "stl"},
		{"none (unknown extension)", "mystery.xyz123unknown", "none"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resolved := mkfile(tc.rel)
			if got := classifyPath(root, resolved); got != tc.want {
				t.Errorf("classifyPath(%q) = %q, want %q", tc.rel, got, tc.want)
			}
		})
	}
}

// TestClassifyPathPrecedence proves the two documented precedence rules
// (sp022 Task 2 success criteria: "classification precedence matches
// today's handleFile dispatch order — akm/d2 special-cases before
// markdown/chroma"):
//   - a .d2 file classifies as "svg", never falling through to chroma's
//     lexer-match branch ("code") even though .d2 has no chroma lexer today
//     — pins the switch ORDER, not just today's absence of an overlap.
//   - a markdown file under docs/notes/** is a genuine double match (both
//     isAkmZettel AND isMarkdown are true for it, and chroma's own
//     "markdown" lexer also matches .md by filename) — akm must win over
//     both.
func TestClassifyPathPrecedence(t *testing.T) {
	root := t.TempDir()
	mkfile := func(rel string) string {
		abs := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatalf("mkdir for fixture %q: %v", rel, err)
		}
		if err := os.WriteFile(abs, []byte("fixture"), 0o644); err != nil {
			t.Fatalf("write fixture %q: %v", rel, err)
		}
		return abs
	}

	t.Run("d2 beats chroma", func(t *testing.T) {
		resolved := mkfile("network.d2")
		if got := classifyPath(root, resolved); got != "svg" {
			t.Errorf("classifyPath(.d2) = %q, want svg (d2 special-case must precede the chroma lexer-match branch)", got)
		}
	})

	t.Run("akm beats md", func(t *testing.T) {
		resolved := mkfile("docs/notes/a.md")
		if got := classifyPath(root, resolved); got != "akm" {
			t.Errorf("classifyPath(docs/notes/a.md) = %q, want akm (akm special-case must precede the plain-markdown branch)", got)
		}
	})
}

// TestClassifyPathEdgeCases pins the sp022 Task 2 edge_cases not already
// covered by the type/precedence tables above.
func TestClassifyPathEdgeCases(t *testing.T) {
	root := t.TempDir()
	mkfile := func(rel string) string {
		abs := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatalf("mkdir for fixture %q: %v", rel, err)
		}
		if err := os.WriteFile(abs, []byte("fixture"), 0o644); err != nil {
			t.Fatalf("write fixture %q: %v", rel, err)
		}
		return abs
	}

	t.Run(".markdown extension classifies as md", func(t *testing.T) {
		resolved := mkfile("note.markdown")
		if got := classifyPath(root, resolved); got != "md" {
			t.Errorf("classifyPath(.markdown) = %q, want md", got)
		}
	})

	t.Run("extensionless chroma match classifies as code", func(t *testing.T) {
		resolved := mkfile("Makefile")
		if got := classifyPath(root, resolved); got != "code" {
			t.Errorf("classifyPath(Makefile) = %q, want code", got)
		}
	})

	t.Run("uppercase extension classifies same as lowercase", func(t *testing.T) {
		resolved := mkfile("PHOTO.PNG")
		if got := classifyPath(root, resolved); got != "image" {
			t.Errorf("classifyPath(PHOTO.PNG) = %q, want image (case-insensitive)", got)
		}
	})

	t.Run("docs/notes nested at any depth classifies as akm", func(t *testing.T) {
		resolved := mkfile("docs/notes/archive/spec/sp001.md")
		if got := classifyPath(root, resolved); got != "akm" {
			t.Errorf("classifyPath(nested akm) = %q, want akm", got)
		}
	})
}

// --- sp022 Task 3: native (?native) payload renderers -------------------

// TestRenderMarkdownNativeRawBytes proves the ?native markdown payload is
// the file's raw bytes as text/plain, not goldmark HTML (sp022 Task 3
// success criteria: "md -> raw bytes text/plain; charset=utf-8" — the QML
// client paints markdown itself via Text.MarkdownText).
func TestRenderMarkdownNativeRawBytes(t *testing.T) {
	src := []byte("# Hello\n\nWorld\n")
	rec := httptest.NewRecorder()
	renderMarkdownNative(rec, src, false)

	if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
		t.Errorf("content-type = %q, want text/plain; charset=utf-8", ct)
	}
	if rec.Body.String() != string(src) {
		t.Errorf("body = %q, want exact raw bytes %q", rec.Body.String(), src)
	}
}

// TestRenderMarkdownNativeTruncatedMarker proves a capped read still carries
// the literal "[preview truncated]" marker appended after the raw bytes
// (sp022 Task 3 success criteria).
func TestRenderMarkdownNativeTruncatedMarker(t *testing.T) {
	src := []byte("partial content")
	rec := httptest.NewRecorder()
	renderMarkdownNative(rec, src, true)

	if !strings.HasPrefix(rec.Body.String(), string(src)) {
		t.Errorf("body does not start with the raw content: %s", rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "[preview truncated]") {
		t.Errorf("body missing truncation marker: %s", rec.Body.String())
	}
}

// TestRenderCodeNativeInlineStyles proves the ?native code payload uses
// chroma's INLINE-styles mode (WithClasses(false)) with no <html> wrapper —
// suitable for Qt rich text (sp022 Task 3 test_plan: "response contains
// `style=\"color:` and no `<html`").
func TestRenderCodeNativeInlineStyles(t *testing.T) {
	src := []byte("package main\n\nfunc main() {}\n")
	rec := httptest.NewRecorder()
	renderCodeNative(rec, "sample.go", src, false)

	body := rec.Body.String()
	if !strings.Contains(body, `style="color:`) {
		t.Errorf("body missing an inline style attribute: %s", body)
	}
	if strings.Contains(body, "<html") {
		t.Errorf("body contains an <html> wrapper, want a bare fragment: %s", body)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Errorf("content-type = %q, want text/html", ct)
	}
}

// TestRenderCodeNativeTruncatedMarker mirrors
// TestRenderMarkdownNativeTruncatedMarker for the code renderer.
func TestRenderCodeNativeTruncatedMarker(t *testing.T) {
	src := []byte("package main\n")
	rec := httptest.NewRecorder()
	renderCodeNative(rec, "sample.go", src, true)

	if !strings.Contains(rec.Body.String(), "[preview truncated]") {
		t.Errorf("body missing truncation marker: %s", rec.Body.String())
	}
}
