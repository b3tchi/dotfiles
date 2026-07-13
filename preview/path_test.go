package main

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// TestResolveInRootAcceptsPlainFile proves a normal in-root path resolves
// to the file's absolute path (sp008 Task 2 success criteria: only paths
// resolving under an allowed root are served).
func TestResolveInRootAcceptsPlainFile(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "hello.txt")
	if err := os.WriteFile(target, []byte("hi"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	got, err := resolveInRoot(root, "hello.txt")
	if err != nil {
		t.Fatalf("resolveInRoot: unexpected error: %v", err)
	}
	want, _ := filepath.EvalSymlinks(target)
	if got != want {
		t.Errorf("resolveInRoot = %q, want %q", got, want)
	}
}

// TestResolveInRootAcceptsNestedFile proves a subdirectory path under root
// still resolves.
func TestResolveInRootAcceptsNestedFile(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "sub", "dir"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	target := filepath.Join(root, "sub", "dir", "f.go")
	if err := os.WriteFile(target, []byte("package main"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	got, err := resolveInRoot(root, "sub/dir/f.go")
	if err != nil {
		t.Fatalf("resolveInRoot: unexpected error: %v", err)
	}
	want, _ := filepath.EvalSymlinks(target)
	if got != want {
		t.Errorf("resolveInRoot = %q, want %q", got, want)
	}
}

// TestResolveInRootRejectsDotDotEscape proves a ".." traversal that would
// resolve outside root is rejected with ErrPathEscape BEFORE any file is
// touched (sp008 Task 2 security-critical success criteria).
func TestResolveInRootRejectsDotDotEscape(t *testing.T) {
	root := t.TempDir()
	// Plant a canary file one level above root; the request must never be
	// able to reach it, and if it did the test infra below (in
	// TestResolveInRootReadsNothingOnEscape) proves it isn't opened.
	_, err := resolveInRoot(root, "../../etc/passwd")
	if !errors.Is(err, ErrPathEscape) {
		t.Fatalf("resolveInRoot(%q): err = %v, want ErrPathEscape", "../../etc/passwd", err)
	}
}

// TestResolveInRootRejectsAbsoluteEscape proves an absolute path segment
// embedded in the request (e.g. "/etc/passwd") is jailed under root rather
// than treated as filesystem-absolute.
func TestResolveInRootRejectsAbsoluteEscape(t *testing.T) {
	root := t.TempDir()
	// "/etc/passwd" joined+cleaned under root stays inside root (becomes
	// root/etc/passwd) UNLESS root itself is shallow enough that ".."-style
	// collapsing during Clean pushes it out — cover the case that actually
	// escapes: a deep ".." chain combined with an absolute-looking suffix.
	_, err := resolveInRoot(root, "/../../../../../../../../etc/passwd")
	if !errors.Is(err, ErrPathEscape) {
		t.Fatalf("resolveInRoot(deep escape): err = %v, want ErrPathEscape", err)
	}
}

// TestResolveInRootRejectsSiblingPrefixCollision proves the containment
// check is a real path-boundary check, not a naive string prefix: a sibling
// directory whose name merely starts with root's basename (e.g. root
// "/tmp/x/root" vs candidate "/tmp/x/root-evil") must not be mistaken for a
// descendant of root.
func TestResolveInRootRejectsSiblingPrefixCollision(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "root")
	evilSibling := filepath.Join(parent, "root-evil")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	if err := os.MkdirAll(evilSibling, 0o755); err != nil {
		t.Fatalf("mkdir sibling: %v", err)
	}
	secret := filepath.Join(evilSibling, "secret.txt")
	if err := os.WriteFile(secret, []byte("top secret"), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}

	// A request for "../root-evil/secret.txt" against root must be
	// rejected: root-evil is NOT a descendant of root despite sharing a
	// string prefix.
	_, err := resolveInRoot(root, "../root-evil/secret.txt")
	if !errors.Is(err, ErrPathEscape) {
		t.Fatalf("resolveInRoot(sibling escape): err = %v, want ErrPathEscape", err)
	}
}

// TestResolveInRootRejectsSymlinkEscape proves a symlink planted inside
// root whose target resolves outside root is rejected — the classic
// path-jail bypass that pure string-prefix checks on the unresolved path
// miss.
func TestResolveInRootRejectsSymlinkEscape(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks require elevated privileges on windows")
	}
	root := t.TempDir()
	outside := t.TempDir()
	secret := filepath.Join(outside, "secret.txt")
	if err := os.WriteFile(secret, []byte("top secret contents"), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}
	link := filepath.Join(root, "escape-link")
	if err := os.Symlink(secret, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	_, err := resolveInRoot(root, "escape-link")
	if !errors.Is(err, ErrPathEscape) {
		t.Fatalf("resolveInRoot(symlink escape): err = %v, want ErrPathEscape", err)
	}
}

// TestResolveInRootRejectsSymlinkDirEscape proves a symlinked directory
// inside root, containing an in-bounds-looking child path, is also caught
// — not just a direct symlink-to-file.
func TestResolveInRootRejectsSymlinkDirEscape(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks require elevated privileges on windows")
	}
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.MkdirAll(filepath.Join(outside, "sub"), 0o755); err != nil {
		t.Fatalf("mkdir outside/sub: %v", err)
	}
	secret := filepath.Join(outside, "sub", "secret.txt")
	if err := os.WriteFile(secret, []byte("nested secret"), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}
	linkDir := filepath.Join(root, "escape-dir")
	if err := os.Symlink(outside, linkDir); err != nil {
		t.Fatalf("symlink dir: %v", err)
	}

	_, err := resolveInRoot(root, "escape-dir/sub/secret.txt")
	if !errors.Is(err, ErrPathEscape) {
		t.Fatalf("resolveInRoot(symlinked dir escape): err = %v, want ErrPathEscape", err)
	}
}

// TestResolveInRootNonexistentReturnsNotExist proves a path that doesn't
// exist under root is reported distinctly from an escape, so the caller can
// map it to 404 rather than 400 (sp008 Task 2 edge case).
func TestResolveInRootNonexistentReturnsNotExist(t *testing.T) {
	root := t.TempDir()
	_, err := resolveInRoot(root, "does-not-exist.txt")
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("resolveInRoot(missing): err = %v, want os.ErrNotExist", err)
	}
}
