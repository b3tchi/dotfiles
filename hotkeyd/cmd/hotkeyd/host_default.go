//go:build !phone && !win32

package main

import "hotkeyd/internal/bind"

// hostOverrides is empty on a machine with no host_<name>.go of its own: the
// shared table in config.go is used exactly as written.
func hostOverrides() map[string][]bind.Action { return nil }

// overlayCmd is the quickshell overlay: the launcher, the project picker and
// the switcher.
func overlayCmd() string { return qsOverlayScript }
