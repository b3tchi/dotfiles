package proc

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestWriteGrabReport_ThenReadGrabReport_RoundTrips(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	WriteGrabReport(":0", 5, 3, []string{"$mod+j", "$mod+k"})

	got, ok := ReadGrabReport(":0")
	if !ok {
		t.Fatal("ReadGrabReport ok = false, want true")
	}
	if got.PID != os.Getpid() || got.Wanted != 5 || got.Active != 3 ||
		len(got.Missing) != 2 || got.Missing[0] != "$mod+j" || got.Missing[1] != "$mod+k" {
		t.Fatalf("report = %+v, want pid=%d wanted=5 active=3 missing=[$mod+j $mod+k]", got, os.Getpid())
	}
}

func TestWriteGrabReport_StampsCallersPidRegardlessOfPriorWriter(t *testing.T) {
	// dotfiles-hwds.42: a report is evidence only about the daemon that
	// wrote it. Seed a report claiming a different pid, then write a
	// fresh one and confirm the CALLER's real pid wins, not whatever the
	// caller passes in report fields.
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	stale, _ := json.Marshal(GrabReport{PID: 999999, Wanted: 0, Active: 0})
	if err := os.WriteFile(GrabReportPath(":0"), stale, 0o644); err != nil {
		t.Fatal(err)
	}

	WriteGrabReport(":0", 1, 1, nil)

	got, ok := ReadGrabReport(":0")
	if !ok || got.PID != os.Getpid() {
		t.Fatalf("report pid = %+v, want stamped with real pid %d", got, os.Getpid())
	}
}

func TestReadGrabReport_FalseWhenMissing(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	if _, ok := ReadGrabReport(":0"); ok {
		t.Fatal("ReadGrabReport ok = true, want false for a display with no report")
	}
}

func TestWriteGrabReport_NoRuntimeDirDoesNotPanic(t *testing.T) {
	// Edge case: $XDG_RUNTIME_DIR vanished under the daemon. Best-effort
	// per adr0014 -- the write is swallowed, not fatal.
	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(t.TempDir(), "does-not-exist"))
	WriteGrabReport(":0", 1, 1, nil) // must not panic
	if _, ok := ReadGrabReport(":0"); ok {
		t.Fatal("ReadGrabReport ok = true, want false when the runtime dir never existed")
	}
}

func TestCurrentGrabReport_IgnoresReportWhosePidMismatchesLock(t *testing.T) {
	// adr0017: a grab report is evidence only about the daemon that wrote
	// it. A report left by a dead process, sitting under a live
	// claimant's path, must not be read as current.
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	lock, err := AcquireLock(LockPath(":0"))
	if err != nil {
		t.Fatalf("AcquireLock: %v", err)
	}
	t.Cleanup(lock.Release)

	stale, _ := json.Marshal(GrabReport{PID: os.Getpid() + 1, Wanted: 9, Active: 9})
	if err := os.WriteFile(GrabReportPath(":0"), stale, 0o644); err != nil {
		t.Fatal(err)
	}

	if _, ok := CurrentGrabReport(":0"); ok {
		t.Fatal("CurrentGrabReport ok = true, want false for a pid-mismatched report")
	}
}

func TestCurrentGrabReport_ReturnsReportWhosePidMatchesLock(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	lock, err := AcquireLock(LockPath(":0"))
	if err != nil {
		t.Fatalf("AcquireLock: %v", err)
	}
	t.Cleanup(lock.Release)

	WriteGrabReport(":0", 5, 5, nil)

	got, ok := CurrentGrabReport(":0")
	if !ok || got.PID != os.Getpid() {
		t.Fatalf("CurrentGrabReport = (%+v, %v), want a matching-pid report", got, ok)
	}
}

// TestAtomicWriteFile_NeverExposesPartialContent proves the write is
// write-temp-then-rename, not a direct truncating write: concurrent
// writers hammer the same path with distinct full-size payloads while a
// reader loops, and every observed read must be byte-exact to exactly one
// writer's complete payload -- never empty, never a mix of two payloads.
// A naive `os.WriteFile(path, data, perm)` (open O_TRUNC, write, no
// rename) fails this near-certainly: O_TRUNC exposes a zero-length window
// before the write lands.
func TestAtomicWriteFile_NeverExposesPartialContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "target")

	const writers = 6
	const itersPerWriter = 60
	const payloadSize = 64 * 1024 // large enough to not land in one page

	payloads := make([][]byte, writers)
	for w := 0; w < writers; w++ {
		payloads[w] = bytes.Repeat([]byte{byte('A' + w)}, payloadSize)
	}

	// Seed the file so the reader never has to special-case ENOENT.
	if err := atomicWriteFile(path, payloads[0], 0o644); err != nil {
		t.Fatalf("seed atomicWriteFile: %v", err)
	}

	stop := make(chan struct{})
	var readErr error
	var mu sync.Mutex
	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			data, err := os.ReadFile(path)
			if err != nil {
				continue // a rename mid-flight can transiently ENOENT on some fs; not what we're checking
			}
			if len(data) != payloadSize {
				mu.Lock()
				readErr = fmt.Errorf("torn read: length %d, want %d (content prefix %q)", len(data), payloadSize, data[:min(len(data), 8)])
				mu.Unlock()
				return
			}
			first := data[0]
			for _, b := range data {
				if b != first {
					mu.Lock()
					readErr = fmt.Errorf("torn read: mixed content, first byte %q found different byte %q", first, b)
					mu.Unlock()
					return
				}
			}
		}
	}()

	var writersWG sync.WaitGroup
	writersWG.Add(writers)
	for w := 0; w < writers; w++ {
		go func(w int) {
			defer writersWG.Done()
			for i := 0; i < itersPerWriter; i++ {
				if err := atomicWriteFile(path, payloads[w], 0o644); err != nil {
					mu.Lock()
					if readErr == nil {
						readErr = fmt.Errorf("atomicWriteFile: %w", err)
					}
					mu.Unlock()
					return
				}
			}
		}(w)
	}
	writersWG.Wait()
	close(stop)
	wg.Wait()

	mu.Lock()
	defer mu.Unlock()
	if readErr != nil {
		t.Fatal(readErr)
	}
}

func TestAtomicWriteFile_LeavesNoStrayTempFileOnSuccess(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "target")
	if err := atomicWriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatalf("atomicWriteFile: %v", err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "target" {
		names := make([]string, len(entries))
		for i, e := range entries {
			names[i] = e.Name()
		}
		t.Fatalf("dir entries = %v, want exactly [target]", names)
	}
}
