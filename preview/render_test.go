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
