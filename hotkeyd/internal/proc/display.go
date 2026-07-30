// Package proc owns the daemon's process-lifetime runtime state: the
// single-instance lock (which doubles as its heartbeat), the grab-report
// sidecar health probes read, and detached spawning of user-bound actions.
// Everything here lives under $XDG_RUNTIME_DIR, keyed on the display.
package proc

import "strings"

// NormalizeDisplay strips the X11 screen suffix from a $DISPLAY string so
// ":10.0" and ":10" resolve to the same per-display runtime-file tag — RDP
// sessions present ":10.0", but the daemon runs one X connection per
// display, not per screen (dotfiles-3x85 normalization; hotkeyd.py's
// lock_path/grab_report_path apply the identical rule).
//
// display is expected to already be default-resolved (e.g. from $DISPLAY
// or an explicit --display flag) before being passed here — this function
// does not apply a default of its own.
//
// Shared with internal/layer's state-socket path (sp021 Task 8), which
// needs the identical tag for "hotkeyd-<tag>.sock" — this is the one
// implementation of the rule both packages import, per that task's
// success criterion ("one helper, one test").
func NormalizeDisplay(display string) string {
	d := strings.TrimLeft(display, ":")
	if i := strings.IndexByte(d, '.'); i >= 0 {
		d = d[:i]
	}
	return d
}
