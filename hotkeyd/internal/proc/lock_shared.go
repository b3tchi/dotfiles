package proc

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// LockMarker is written as the lock file's second line by every daemon
// build that beats. Its ABSENCE means the daemon predates the heartbeat,
// not that the heartbeat went stale (adr0017) — byte-identical to
// hotkeyd.py's LOCK_MARKER so a --health probe reading either daemon's
// lock file gets the same verdict.
const LockMarker = "heartbeat=1"

// HeartbeatPeriod throttles Lock.Beat's mtime rewrite to at most once per
// this interval, matching hotkeyd.py's HEARTBEAT_PERIOD_S.
const HeartbeatPeriod = time.Second

// ErrAlreadyRunning means another hotkeyd already holds this display's
// lock — the lock is exclusive and non-blocking, so a second `start`
// fails fast instead of queuing behind the first. PID is the holder's pid
// as its lock file records it, or 0 where the lock does not name it (the
// flock build leaves it 0; the Windows build reads it, see
// lock_windows.go).
type ErrAlreadyRunning struct {
	Path string
	PID  int
}

func (e *ErrAlreadyRunning) Error() string {
	if e.PID > 0 {
		return fmt.Sprintf("proc: another hotkeyd (pid %d) holds %s", e.PID, e.Path)
	}
	return fmt.Sprintf("proc: another hotkeyd holds %s", e.Path)
}

// Lock is a flock-based single-instance guard that doubles as the
// daemon's heartbeat: its mtime is rewritten (throttled) from the
// run-loop top, and health probes read that mtime rather than asking "is
// the pid alive" — the flock answers the wrong question, since the
// kernel holds it just as firmly for a daemon frozen mid-loop as for one
// serving the keyboard (adr0017).
//
// Held for the process lifetime. The kernel releases the flock even on
// SIGKILL, so a hard-killed daemon does not lock its display out of a
// restart — see AcquireLock's handling of stale content left behind by
// exactly that.
type Lock struct {
	path   string
	file   *os.File
	now    func() time.Time
	beatAt time.Time // zero value: no beat recorded yet, so the first Beat always writes
}

// Beat records that the run loop is still turning, rewriting the lock
// file's mtime — throttled to HeartbeatPeriod so a hot loop doesn't put a
// syscall on the per-keystroke path to buy nothing. Call it from the top
// of the run loop so it covers both the idle path and the event path
// with one call site.
func (l *Lock) Beat() {
	now := l.now()
	if !l.beatAt.IsZero() && now.Sub(l.beatAt) < HeartbeatPeriod {
		return
	}
	l.beatAt = now
	// adr0014: a runtime dir that went read-only under us is not a
	// reason to stop serving the keyboard. The beat going stale is
	// itself the report a --health probe reads.
	_ = os.Chtimes(l.path, now, now)
}

// HasHeartbeat reports whether the lock file at path was written by a
// daemon build that beats (dotfiles-hwds.29). False for a lock written by
// a build that predates the heartbeat, whose mtime is therefore its START
// time and says nothing about liveness — and false when the file cannot
// be read at all, which lands on the same honest "cannot determine"
// rather than on a verdict (adr0017: absence of a beat is not a missed
// beat).
func HasHeartbeat(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return strings.Contains(string(data), LockMarker)
}

// LockPID returns the pid recorded in the lock file's first line, or
// (0, false) if the file is missing, empty, or its first line is not a
// valid pid.
func LockPID(path string) (int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	first, _, _ := strings.Cut(string(data), "\n")
	pid, err := strconv.Atoi(strings.TrimSpace(first))
	if err != nil {
		return 0, false
	}
	return pid, true
}
