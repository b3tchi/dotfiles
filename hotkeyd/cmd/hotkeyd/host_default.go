//go:build !phone

package main

import "hotkeyd/internal/bind"

// hostOverrides is empty on a machine with no host_<name>.go of its own: the
// shared table in config.go is used exactly as written.
func hostOverrides() map[string][]bind.Action { return nil }
