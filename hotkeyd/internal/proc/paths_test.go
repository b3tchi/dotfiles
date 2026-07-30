package proc

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestRuntimeDir_UsesXDGWhenSet(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/example-runtime")
	if got := RuntimeDir(); got != "/tmp/example-runtime" {
		t.Fatalf("RuntimeDir() = %q, want /tmp/example-runtime", got)
	}
}

func TestRuntimeDir_FallsBackToRunUserUID(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "")
	want := fmt.Sprintf("/run/user/%d", os.Getuid())
	if got := RuntimeDir(); got != want {
		t.Fatalf("RuntimeDir() = %q, want %q", got, want)
	}
}

func TestLockPath_NormalizesDisplayAndJoinsRuntimeDir(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/example-runtime")
	got := LockPath(":10.0")
	want := filepath.Join("/tmp/example-runtime", "hotkeyd-10.lock")
	if got != want {
		t.Fatalf("LockPath(:10.0) = %q, want %q", got, want)
	}
}

func TestGrabReportPath_NormalizesDisplayAndJoinsRuntimeDir(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/example-runtime")
	got := GrabReportPath(":10.0")
	want := filepath.Join("/tmp/example-runtime", "hotkeyd-10.grabs")
	if got != want {
		t.Fatalf("GrabReportPath(:10.0) = %q, want %q", got, want)
	}
}
