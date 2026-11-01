//go:build !phone

package main

import "hotkeyd/internal/bind"

// hostOverrides is empty on a machine with no host_<name>.go of its own: the
// shared table in config.go is used exactly as written.
func hostOverrides() map[string][]bind.Action { return nil }

// kwinMod is $mod on a kwin session (an X display reads its own from i3's
// config instead).
const kwinMod = bind.DefaultMod
