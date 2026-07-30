package proc

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestAcquireLock_WritesPidAndHeartbeatMarker(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")

	lock, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("AcquireLock: %v", err)
	}
	t.Cleanup(lock.Release)

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	want := fmt.Sprintf("%d\n%s\n", os.Getpid(), LockMarker)
	if string(data) != want {
		t.Fatalf("lock content = %q, want %q", string(data), want)
	}
}

func TestAcquireLock_SecondClaimantFails(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")

	lock, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("first AcquireLock: %v", err)
	}
	t.Cleanup(lock.Release)

	_, err = AcquireLock(path)
	if err == nil {
		t.Fatal("second AcquireLock succeeded, want ErrAlreadyRunning")
	}
	var already *ErrAlreadyRunning
	if !asErrAlreadyRunning(err, &already) {
		t.Fatalf("AcquireLock error = %v (%T), want *ErrAlreadyRunning", err, err)
	}
}

func TestAcquireLock_ConcurrentClaimantsCollapseToOneOwner(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")

	const n = 8
	var wins int32
	var wg sync.WaitGroup
	locks := make([]*Lock, n)
	errs := make([]error, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			l, err := AcquireLock(path)
			locks[i] = l
			errs[i] = err
			if err == nil {
				atomic.AddInt32(&wins, 1)
			}
		}(i)
	}
	wg.Wait()

	if wins != 1 {
		t.Fatalf("winners = %d, want exactly 1", wins)
	}
	for i, err := range errs {
		if err == nil {
			locks[i].Release()
		}
	}
}

func TestLock_ReleaseAllowsAnotherClaimant(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")

	lock, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("AcquireLock: %v", err)
	}
	lock.Release()

	lock2, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("AcquireLock after release: %v", err)
	}
	lock2.Release()
}

func TestAcquireLock_SurvivesStaleContentFromSigkilledPredecessor(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")

	// Simulate a predecessor that was SIGKILLed: the kernel released its
	// flock (nothing holds it), but the file content is stale -- a dead
	// pid, and it may or may not carry the heartbeat marker.
	if err := os.WriteFile(path, []byte("99999\nheartbeat=1\n"), 0o644); err != nil {
		t.Fatalf("seed stale lock: %v", err)
	}
	oldTime := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, oldTime, oldTime); err != nil {
		t.Fatalf("Chtimes: %v", err)
	}

	lock, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("AcquireLock over stale content: %v", err)
	}
	t.Cleanup(lock.Release)

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	want := fmt.Sprintf("%d\n%s\n", os.Getpid(), LockMarker)
	if string(data) != want {
		t.Fatalf("lock content after reclaim = %q, want %q", string(data), want)
	}
}

func TestHasHeartbeat_TrueWhenMarkerPresent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")
	if err := os.WriteFile(path, []byte("123\nheartbeat=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !HasHeartbeat(path) {
		t.Fatal("HasHeartbeat = false, want true")
	}
}

func TestHasHeartbeat_FalseWhenMarkerAbsent(t *testing.T) {
	// A lock file predating the heartbeat: pid only, no marker line. Must
	// read as "predates the heartbeat", distinguishable from a stale beat
	// (adr0017 verdict 10).
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")
	if err := os.WriteFile(path, []byte("123\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if HasHeartbeat(path) {
		t.Fatal("HasHeartbeat = true, want false for a marker-less lock file")
	}
}

func TestHasHeartbeat_FalseWhenFileMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")
	if HasHeartbeat(path) {
		t.Fatal("HasHeartbeat = true, want false for a missing file")
	}
}

func TestLockPID_ReadsFirstLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")
	if err := os.WriteFile(path, []byte("4242\nheartbeat=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	pid, ok := LockPID(path)
	if !ok || pid != 4242 {
		t.Fatalf("LockPID = (%d, %v), want (4242, true)", pid, ok)
	}
}

func TestLockPID_FalseWhenFileMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")
	if _, ok := LockPID(path); ok {
		t.Fatal("LockPID ok = true, want false for a missing file")
	}
}

// fakeClock lets the mtime-throttle test advance time deterministically
// instead of racing the wall clock or waiting a full second per assertion.
type fakeClock struct{ t time.Time }

func (f *fakeClock) now() time.Time { return f.t }
func (f *fakeClock) advance(d time.Duration) {
	f.t = f.t.Add(d)
}

func TestLock_BeatThrottlesToAtMostOncePerSecond(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hotkeyd-0.lock")
	clock := &fakeClock{t: time.Now()}

	lock, err := newLock(path, clock.now)
	if err != nil {
		t.Fatalf("newLock: %v", err)
	}
	t.Cleanup(lock.Release)

	mtimeAfterCreate := statMtime(t, path)

	// Advance less than the heartbeat period: Beat must NOT rewrite mtime.
	clock.advance(500 * time.Millisecond)
	lock.Beat()
	if got := statMtime(t, path); !got.Equal(mtimeAfterCreate) {
		t.Fatalf("mtime moved on a sub-period Beat: %v -> %v", mtimeAfterCreate, got)
	}

	// Advance past the heartbeat period: Beat must rewrite mtime to the
	// (fake) current time.
	clock.advance(600 * time.Millisecond)
	lock.Beat()
	got := statMtime(t, path)
	if got.Equal(mtimeAfterCreate) {
		t.Fatal("mtime did not move on a past-period Beat")
	}
	if !got.Equal(clock.now()) {
		t.Fatalf("mtime = %v, want %v (the fake clock's current time)", got, clock.now())
	}
}

func statMtime(t *testing.T, path string) time.Time {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	return info.ModTime()
}

// asErrAlreadyRunning is a small errors.As wrapper kept local to the test
// so the test file doesn't need its own "errors" import ceremony spread
// across every call site.
func asErrAlreadyRunning(err error, target **ErrAlreadyRunning) bool {
	if e, ok := err.(*ErrAlreadyRunning); ok {
		*target = e
		return true
	}
	return false
}

func TestErrAlreadyRunning_MessageNamesThePath(t *testing.T) {
	err := &ErrAlreadyRunning{Path: "/run/user/1000/hotkeyd-0.lock"}
	if !strings.Contains(err.Error(), "/run/user/1000/hotkeyd-0.lock") {
		t.Fatalf("error message %q does not name the path", err.Error())
	}
}
