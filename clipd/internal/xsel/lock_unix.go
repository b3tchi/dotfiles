//go:build unix

package xsel

import (
	"errors"
	"os"
	"syscall"
)

// Lock takes a non-blocking exclusive flock on path (created 0600). ok is
// false when another agent already holds it — the normal case when i3
// `exec_always` re-runs the autostart (clip-sync.sh's rule: losing the race
// is not an error). The lock lives until release or process exit.
func Lock(path string) (release func(), ok bool, err error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return func() { f.Close() }, true, nil
}
