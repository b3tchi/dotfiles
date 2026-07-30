package proc

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// GrabReport is the sidecar the daemon publishes after every grab-set
// computation -- the evidence a --health probe reads to tell "alive but
// missing chords the table asks for" (adr0017 verdict 9) from "alive and
// fully grabbed". It is a SIDECAR, deliberately distinct from the lock
// file: the lock's mtime is the heartbeat, so writing the report there
// would beat the heart on every re-grab and make a wedged daemon that
// still receives MappingNotify look alive.
type GrabReport struct {
	PID     int      `json:"pid"`
	Wanted  int      `json:"wanted"`
	Active  int      `json:"active"`
	Missing []string `json:"missing"`
}

// WriteGrabReport publishes a report for display, stamped with the
// calling process's own pid -- not a caller-supplied one -- so a reader
// can tell whether this report is about the daemon whose lock it just
// read (adr0017: evidence only about the daemon that wrote it). The write
// is atomic (temp file + rename), so a reader never observes a partially
// written report.
//
// Best-effort: matches hotkeyd.py's write_grab_report. A runtime dir that
// went read-only or vanished is not a reason to stop serving the keyboard
// (adr0014), so failures here are swallowed, not returned.
func WriteGrabReport(display string, wanted, active int, missing []string) {
	report := GrabReport{
		PID:     os.Getpid(),
		Wanted:  wanted,
		Active:  active,
		Missing: missing,
	}
	data, err := json.Marshal(report)
	if err != nil {
		return
	}
	_ = atomicWriteFile(GrabReportPath(display), data, 0o644)
}

// ReadGrabReport returns display's last published grab report, or
// (nil, false) if there is not one or it cannot be read/parsed.
//
// Callers that need adr0017's pid-mismatch protection should use
// CurrentGrabReport instead -- this function returns whatever is on disk
// without checking who wrote it.
func ReadGrabReport(display string) (*GrabReport, bool) {
	data, err := os.ReadFile(GrabReportPath(display))
	if err != nil {
		return nil, false
	}
	var report GrabReport
	if err := json.Unmarshal(data, &report); err != nil {
		return nil, false
	}
	return &report, true
}

// CurrentGrabReport returns display's grab report, but only when its pid
// stamp matches the pid recorded in display's lock file. A report whose
// pid mismatches the lock's is evidence about a DIFFERENT daemon -- a
// dead process's last report left sitting on disk under a live
// claimant's path -- and adr0017 requires it be ignored rather than
// misread as current.
func CurrentGrabReport(display string) (*GrabReport, bool) {
	lockPID, ok := LockPID(LockPath(display))
	if !ok {
		return nil, false
	}
	report, ok := ReadGrabReport(display)
	if !ok || report.PID != lockPID {
		return nil, false
	}
	return report, true
}

// atomicWriteFile writes data to a fresh, uniquely-named temp file beside
// path and renames it over path. rename(2) is atomic on the same
// filesystem, so a concurrent reader of path always sees either the
// previous complete content or the new complete content, never a partial
// write and never a truncated-then-refilled window. The temp name is
// unique per call (os.CreateTemp) rather than a fixed "path+.tmp": a
// fixed name is safe for a single writer but two racing writers to the
// same target would otherwise stomp on each other's temp file between
// write and rename. Shared by WriteGrabReport (and any future sidecar
// this package publishes) rather than each caller reimplementing the
// temp+rename dance.
func atomicWriteFile(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	// Best-effort cleanup: if anything below fails before the rename, don't
	// leave the temp file behind for a caller to trip over later.
	succeeded := false
	defer func() {
		if !succeeded {
			_ = os.Remove(tmpPath)
		}
	}()

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(perm); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return err
	}
	succeeded = true
	return nil
}
