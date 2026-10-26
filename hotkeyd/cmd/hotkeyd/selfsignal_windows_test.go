package main

import (
	"syscall"
	"testing"
)

// selfSignal: Windows has no way to send a process a POSIX signal, so a
// test that needs one is skipped there.
func selfSignal(t *testing.T, sig syscall.Signal) error {
	t.Helper()
	t.Skipf("no self-signal (%v) on Windows", sig)
	return nil
}
