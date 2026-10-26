//go:build !windows

package main

import (
	"os"
	"syscall"
	"testing"
)

// selfSignal sends sig to this test process.
func selfSignal(t *testing.T, sig syscall.Signal) error {
	t.Helper()
	return syscall.Kill(os.Getpid(), sig)
}
