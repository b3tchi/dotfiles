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

func TestControlPath_NormalizesDisplayAndJoinsRuntimeDir(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/example-runtime")
	got := ControlPath(":10.0")
	want := filepath.Join("/tmp/example-runtime", "hotkeyd-10-ctl.sock")
	if got != want {
		t.Fatalf("ControlPath(:10.0) = %q, want %q", got, want)
	}
}

// TestControlPath_ScreenSuffixResolvesToSameSocket is the sp023 Task 3
// success criterion in one assertion: the control socket shares
// NormalizeDisplay with LockPath/GrabReportPath (and internal/layer's
// SocketPath), so an RDP session presenting ":10.0" addresses the very
// same daemon a ":10" client does. A ControlPath that formatted the raw
// display string would pass the test above and still fail here.
func TestControlPath_ScreenSuffixResolvesToSameSocket(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/example-runtime")
	if ControlPath(":10.0") != ControlPath(":10") {
		t.Fatalf("ControlPath(:10.0) = %q but ControlPath(:10) = %q — the screen suffix must not fork the socket",
			ControlPath(":10.0"), ControlPath(":10"))
	}
}

// TestControlPath_DistinctFromStateSocket pins sp023 plan decision 2: the
// control verb travels over a NEW socket, so adr0012's "mutation never
// flows back through this socket" stays literally true of the state feed.
// An implementation that reused the state path would collapse the two.
func TestControlPath_DistinctFromStateSocket(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/example-runtime")
	statePath := filepath.Join("/tmp/example-runtime", "hotkeyd-10.sock")
	if ControlPath(":10") == statePath {
		t.Fatalf("ControlPath collides with the state socket at %q — adr0012 requires a separate socket", statePath)
	}
}
