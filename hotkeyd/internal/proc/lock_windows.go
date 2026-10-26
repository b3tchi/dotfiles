package proc

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"
)

// The Windows lock is LockFileEx on one byte far past the file's content
// rather than flock on the whole file: a Windows byte-range lock also
// blocks READS of the range it covers, and a refused second hotkeyd must
// still be able to read the holder's pid out of line 1 to name it. Like
// flock, the lock dies with the process that holds it, however it dies, so
// a killed daemon leaves only a stale file - which the next start takes
// over and says so, once.

var (
	modkernel32      = syscall.NewLazyDLL("kernel32.dll")
	procLockFileEx   = modkernel32.NewProc("LockFileEx")
	procUnlockFileEx = modkernel32.NewProc("UnlockFileEx")
)

const (
	lockfileFailImmediately = 0x1
	lockfileExclusiveLock   = 0x2
	errorLockViolation      = syscall.Errno(33)
	errorIOPending          = syscall.Errno(997)
	// lockOffsetHigh puts the locked byte at 4 GiB, far past a few-byte
	// pid file, so the content stays readable by everyone.
	lockOffsetHigh = 1
)

func lockFileEx(h syscall.Handle) error {
	ol := syscall.Overlapped{OffsetHigh: lockOffsetHigh}
	r, _, err := procLockFileEx.Call(uintptr(h), lockfileExclusiveLock|lockfileFailImmediately, 0, 1, 0, uintptr(unsafe.Pointer(&ol)))
	if r == 0 {
		return err
	}
	return nil
}

func unlockFileEx(h syscall.Handle) {
	ol := syscall.Overlapped{OffsetHigh: lockOffsetHigh}
	_, _, _ = procUnlockFileEx.Call(uintptr(h), 0, 1, 0, uintptr(unsafe.Pointer(&ol)))
}

// AcquireLock claims the single-instance lock at path, creating it if
// necessary, and returns *ErrAlreadyRunning naming the holder's pid if
// another process holds it. On success the file holds exactly the pid on
// line 1 and LockMarker on line 2, and Beat has been called once.
func AcquireLock(path string) (*Lock, error) {
	return newLock(path, time.Now)
}

func newLock(path string, now func() time.Time) (*Lock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	// Not truncated on open, for the flock build's reason: a losing second
	// start must never touch the winner's bytes.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	h := syscall.Handle(f.Fd())
	if err := lockFileEx(h); err != nil {
		f.Close()
		if err == errorLockViolation || err == errorIOPending {
			pid, _ := LockPID(path)
			return nil, &ErrAlreadyRunning{Path: path, PID: pid}
		}
		return nil, fmt.Errorf("proc: lock %s: %w", path, err)
	}

	// The lock is ours, so whatever pid the file still names is a holder
	// that is gone (killed, crashed, or exited without a reaper).
	if old, ok := LockPID(path); ok && old != os.Getpid() {
		Log(fmt.Sprintf("lock %s: taking over from pid %d, which no longer holds it", path, old))
	}

	fail := func(err error) (*Lock, error) {
		unlockFileEx(h)
		f.Close()
		return nil, err
	}
	if err := f.Truncate(0); err != nil {
		return fail(err)
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return fail(err)
	}
	if _, err := fmt.Fprintf(f, "%d\n%s\n", os.Getpid(), LockMarker); err != nil {
		return fail(err)
	}

	l := &Lock{path: path, file: f, now: now}
	l.Beat()
	return l, nil
}

// Release unlocks and closes the lock file.
func (l *Lock) Release() {
	unlockFileEx(syscall.Handle(l.file.Fd()))
	_ = l.file.Close()
}

// LockHeld reports whether some process holds the lock at path right now.
// It asks the way a second daemon would - a non-blocking LockFileEx on the
// lock byte - and lets go at once if it got it. `hotkeyd recover` asks
// before it ends the pid the file names (sp012 Task 7): a pid in a file
// nobody holds is a dead daemon's, and the pid may since be another
// program's. Any answer other than "refused, held" is false, so a doubt
// never ends a process.
func LockHeld(path string) bool {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return false
	}
	defer f.Close()
	h := syscall.Handle(f.Fd())
	if err := lockFileEx(h); err != nil {
		return err == errorLockViolation || err == errorIOPending
	}
	unlockFileEx(h)
	return false
}
