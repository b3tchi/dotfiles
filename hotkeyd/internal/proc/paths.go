package proc

import (
	"fmt"
	"os"
	"path/filepath"
)

// RuntimeDir resolves $XDG_RUNTIME_DIR, falling back to /run/user/<uid> —
// the same fallback systemd and hotkeyd.py's _runtime_dir both use.
func RuntimeDir() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return d
	}
	return fmt.Sprintf("/run/user/%d", os.Getuid())
}

// LockPath returns the per-display single-instance lock path for display,
// e.g. "$XDG_RUNTIME_DIR/hotkeyd-10.lock" — byte-identical in shape to
// hotkeyd.py's lock_path so a --health probe reads the same file the Go
// daemon writes.
func LockPath(display string) string {
	return filepath.Join(RuntimeDir(), fmt.Sprintf("hotkeyd-%s.lock", NormalizeDisplay(display)))
}

// GrabReportPath returns the per-display grab-report sidecar path for
// display, e.g. "$XDG_RUNTIME_DIR/hotkeyd-10.grabs".
func GrabReportPath(display string) string {
	return filepath.Join(RuntimeDir(), fmt.Sprintf("hotkeyd-%s.grabs", NormalizeDisplay(display)))
}
