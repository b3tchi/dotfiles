package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestIndexHandlerLinks(t *testing.T) {
	// Set up a registry with one local project containing a .d2 file.
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "mydiagram.d2"), []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	reg := Registry{"myproject": dir}
	handler := newIndexHandler(reg, false)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	body := rec.Body.String()
	if !strings.Contains(body, "/myproject/mydiagram.d2") {
		t.Errorf("expected link /myproject/mydiagram.d2 in body, got:\n%s", body)
	}
}

func TestIndexHandlerSSHAbsent(t *testing.T) {
	// ssh projects should not appear in the index at all — they are excluded
	// at registry load time so we just verify a registry with no local entries
	// produces an empty but non-crashing index page.
	reg := Registry{} // no local projects (ssh were already filtered out by loadRegistry)
	handler := newIndexHandler(reg, false)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 even with empty registry, got %d", rec.Code)
	}
}

func TestIndexHandlerMissingRegistryBanner(t *testing.T) {
	// When the registry file is missing, the handler should show a warning banner.
	reg := Registry{}
	handler := newIndexHandler(reg, true) // registryMissing = true

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 even with missing registry, got %d", rec.Code)
	}

	body := rec.Body.String()
	if !strings.Contains(body, "registry") {
		t.Errorf("expected registry warning banner in body, got:\n%s", body)
	}
}

func TestIndexHandlerCollisionFlag(t *testing.T) {
	// A collision should be visible in the index page.
	dir := t.TempDir()
	sub := filepath.Join(dir, "sub")
	if err := os.Mkdir(sub, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "dup.d2"), []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "dup.d2"), []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	reg := Registry{"colproj": dir}
	handler := newIndexHandler(reg, false)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	body := rec.Body.String()
	// The collision flag should appear somewhere on the page
	if !strings.Contains(body, "collision") && !strings.Contains(body, "duplicate") && !strings.Contains(body, "⚠") {
		t.Errorf("expected collision indicator in body, got:\n%s", body)
	}
}

func TestIndexHandlerUnicodeFilename(t *testing.T) {
	dir := t.TempDir()
	unicodeName := "日本語.d2"
	if err := os.WriteFile(filepath.Join(dir, unicodeName), []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	reg := Registry{"uniproj": dir}
	handler := newIndexHandler(reg, false)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	body := rec.Body.String()
	// The href should be URL-encoded for the non-ASCII filename
	if !strings.Contains(body, "%E6%97%A5%E6%9C%AC%E8%AA%9E") && !strings.Contains(body, "日本語") {
		t.Errorf("expected unicode filename (raw or encoded) in body, got:\n%s", body)
	}
}

// TestIndexHandlerReflectsFileCreatedAfterStartup proves the dotfiles-glo
// fix: the landing page must show a .d2 created after the handler was built,
// not a frozen startup snapshot. The proxy already re-walks on demand so the
// file ROUTES; the index page must not lie about what exists.
func TestIndexHandlerReflectsFileCreatedAfterStartup(t *testing.T) {
	defer withIndexRebuildTTL(0)() // rebuild every request, no debounce

	dir := t.TempDir() // empty at construction
	reg := Registry{"proj": dir}
	handler := newIndexHandler(reg, false)

	// Nothing yet.
	rec0 := httptest.NewRecorder()
	handler.ServeHTTP(rec0, httptest.NewRequest(http.MethodGet, "/", nil))
	if strings.Contains(rec0.Body.String(), "/proj/late.d2") {
		t.Fatalf("baseline listed a file that does not exist yet")
	}

	// Create a diagram AFTER the handler exists.
	if err := os.WriteFile(filepath.Join(dir, "late.d2"), []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if !strings.Contains(rec.Body.String(), "/proj/late.d2") {
		t.Errorf("index did not list a file created after startup; body:\n%s", rec.Body.String())
	}
}

// TestIndexHandlerDebouncesWalk proves the TTL cache: within the window a
// second request reuses the snapshot and does NOT reflect a just-created
// file. This is the guard against walking the tree on every landing-page hit.
func TestIndexHandlerDebouncesWalk(t *testing.T) {
	defer withIndexRebuildTTL(time.Hour)() // effectively "walk once"

	dir := t.TempDir()
	reg := Registry{"proj": dir}
	handler := newIndexHandler(reg, false)

	// First request warms the cache (empty tree).
	rec0 := httptest.NewRecorder()
	handler.ServeHTTP(rec0, httptest.NewRequest(http.MethodGet, "/", nil))

	if err := os.WriteFile(filepath.Join(dir, "late.d2"), []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if strings.Contains(rec.Body.String(), "/proj/late.d2") {
		t.Errorf("index re-walked inside the TTL window (should have served the cached snapshot)")
	}
}

// withIndexRebuildTTL sets the package rebuild TTL and returns a restore func.
// Sequential tests (no t.Parallel), so mutating the global is safe.
func withIndexRebuildTTL(d time.Duration) func() {
	prev := indexRebuildTTL
	indexRebuildTTL = d
	return func() { indexRebuildTTL = prev }
}
