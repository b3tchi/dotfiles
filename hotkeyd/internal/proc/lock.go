//go:build !windows

package proc

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// AcquireLock claims the single-instance lock at path, creating it if
// necessary, and returns *ErrAlreadyRunning if another process already
// holds it. On success the file is left containing exactly the pid on
// line 1 and LockMarker on line 2, and Beat has been called once.
func AcquireLock(path string) (*Lock, error) {
	return newLock(path, time.Now)
}

// newLock is AcquireLock's shared plumbing; tests use it directly to
// inject a fake clock for the heartbeat-throttle test.
func newLock(path string, now func() time.Time) (*Lock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}

	// Open WITHOUT truncating. hotkeyd.py opens its lock file in "w"
	// mode, which truncates on open regardless of who ends up winning
	// the flock -- a losing second `start` would silently zero the
	// WINNER's lock content (pid + heartbeat marker) before its own
	// flock attempt fails, corrupting a live daemon's file. Truncating
	// only after we have confirmed we hold the lock avoids that: two
	// concurrent claimants still collapse to exactly one owner, but the
	// loser never touches the winner's bytes.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}

	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if err == syscall.EWOULDBLOCK {
			return nil, &ErrAlreadyRunning{Path: path}
		}
		return nil, err
	}

	if err := f.Truncate(0); err != nil {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
		return nil, err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
		return nil, err
	}
	// pid first, then the marker: nothing parses this file for the pid
	// (that is `pgrep`'s job) but a human reading it during an outage
	// wants the pid on line 1, and HasHeartbeat only asks whether the
	// marker is present anywhere in it.
	if _, err := fmt.Fprintf(f, "%d\n%s\n", os.Getpid(), LockMarker); err != nil {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
		return nil, err
	}

	l := &Lock{path: path, file: f, now: now}
	l.Beat()
	return l, nil
}

// Release unlocks and closes the lock file. Safe to call once at
// shutdown; matches hotkeyd.py's SingleInstance.release.
func (l *Lock) Release() {
	_ = syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	_ = l.file.Close()
}
