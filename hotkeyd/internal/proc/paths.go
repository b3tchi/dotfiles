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

// ControlPath returns the per-display CONTROL socket path for display, e.g.
// "$XDG_RUNTIME_DIR/hotkeyd-10-ctl.sock" — the one request/one reply socket
// the `set-layer` verb dials (sp023 Task 3, plan decision 2).
//
// Deliberately a SEPARATE socket from internal/layer's SocketPath
// ("hotkeyd-10.sock"): [[adr0012]] frames the state feed as read-only, with
// mutation never flowing back through it, and this port keeps that claim
// LITERALLY true — the external-trigger exception is a new socket, not a
// loosened old one. The state publisher still never calls Read on a client
// connection.
//
// Shares NormalizeDisplay with LockPath / GrabReportPath (and, via
// proc.NormalizeDisplay, with layer.SocketPath) — the "one helper, one test"
// rule — so ":10.0" and ":10" address the identical daemon.
func ControlPath(display string) string {
	return filepath.Join(RuntimeDir(), fmt.Sprintf("hotkeyd-%s-ctl.sock", NormalizeDisplay(display)))
}
