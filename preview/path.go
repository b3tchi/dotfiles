package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// ErrPathEscape is returned when a requested path resolves outside the
// allowed root — via "..", an absolute-path segment, or a symlink that
// points outside root. Handlers must map this to 400 (sp008 Task 2:
// path.go is the primary attack surface for /file/<path>; it must reject
// BEFORE any content read).
var ErrPathEscape = errors.New("preview: path escapes allowed root")

// resolveInRoot resolves the URL path segment reqPath (already
// percent-decoded by net/http) against root and returns the absolute,
// symlink-resolved path — but only when that path is actually contained in
// root.
//
// The containment check runs TWICE, deliberately:
//
//  1. On the syntactic join (pure string/path computation, zero I/O) —
//     this alone rejects ".." and absolute-path escapes before the
//     filesystem is touched at all.
//  2. On the symlink-resolved result (filepath.EvalSymlinks walks the path
//     resolving links; it does not read file content) — this catches a
//     symlink planted inside root whose target escapes it, which the
//     syntactic check cannot see.
//
// Both checks use underRoot's proper prefix comparison (trailing
// separator), not a naive strings.HasPrefix, so a sibling directory whose
// name merely starts with root's name (e.g. "/root-evil" vs "/root") is
// never mistaken for a descendant.
func resolveInRoot(root, reqPath string) (string, error) {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	absRoot = filepath.Clean(absRoot)

	// filepath.Join + the Clean it performs internally collapses ".."
	// segments syntactically. On its own this is NOT sufficient: Clean
	// only stops ".." from crossing the filesystem's "/" root, not
	// absRoot — so e.g. Join("/home/x/root", "../../etc/passwd") cleans to
	// the very real absolute path "/etc/passwd". The containment check
	// below is what actually rejects escapes; this line alone proves
	// nothing.
	joined := filepath.Join(absRoot, reqPath)

	if !underRoot(absRoot, joined) {
		return "", ErrPathEscape
	}

	// The syntactic path is contained. Resolve symlinks to catch a link
	// planted inside root whose target escapes it. EvalSymlinks requires
	// the path to exist; a missing path/component surfaces as
	// os.ErrNotExist so callers can map it to 404 instead of 400.
	resolved, err := filepath.EvalSymlinks(joined)
	if err != nil {
		if os.IsNotExist(err) {
			return "", os.ErrNotExist
		}
		return "", err
	}
	if !underRoot(absRoot, resolved) {
		return "", ErrPathEscape
	}
	return resolved, nil
}

// underRoot reports whether candidate is root itself or a descendant of
// it, via an explicit trailing-separator comparison — guards against a
// sibling path whose name merely starts with root's string (e.g.
// "/root-evil" incorrectly matching a naive prefix check against "/root").
func underRoot(root, candidate string) bool {
	if candidate == root {
		return true
	}
	return strings.HasPrefix(candidate, root+string(filepath.Separator))
}
