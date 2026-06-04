package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIndexHandlerLinks(t *testing.T) {
	// Set up a registry with one local project containing a .d2 file.
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "mydiagram.d2"), []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	reg := Registry{"myproject": dir}
	idx := buildIndex(reg)
	handler := newIndexHandler(idx, false)

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
	idx := buildIndex(reg)
	handler := newIndexHandler(idx, false)

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
	idx := buildIndex(reg)
	handler := newIndexHandler(idx, true) // registryMissing = true

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
	idx := buildIndex(reg)
	handler := newIndexHandler(idx, false)

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
	idx := buildIndex(reg)
	handler := newIndexHandler(idx, false)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	body := rec.Body.String()
	// The href should be URL-encoded for the non-ASCII filename
	if !strings.Contains(body, "%E6%97%A5%E6%9C%AC%E8%AA%9E") && !strings.Contains(body, "日本語") {
		t.Errorf("expected unicode filename (raw or encoded) in body, got:\n%s", body)
	}
}
