package main

// kwi3-hoex.30: `hotkeyd stop`, every branch with fakes (stop.go is pure
// over stopDeps). The real thing on Windows is stop_windows_test.go.

import (
	"errors"
	"runtime"
	"strings"
	"testing"
	"time"
)

type stopRig struct {
	lockPID int
	named   bool
	held    bool
	proc    *fakeProc
	openErr error
	opened  []int
	stops   int
	stopErr error
	logger  *fakeLogger
	out     strings.Builder
	self    string
	// heldAfterOpenFail: what lockHeld answers once openProc has failed.
	heldAfterOpenFail bool
}

func newStopRig() *stopRig {
	return &stopRig{proc: &fakeProc{exitsOnStop: true}, logger: &fakeLogger{}}
}

func (r *stopRig) running(pid int) { r.lockPID, r.named, r.held = pid, true, true }

func (r *stopRig) deps() stopDeps {
	return stopDeps{
		display: "kwi3t-s",
		lockPID: func(string) (int, bool) { return r.lockPID, r.named },
		lockHeld: func(string) bool {
			if r.openErr != nil && len(r.opened) > 0 {
				return r.heldAfterOpenFail
			}
			return r.held
		},
		openProc: func(pid int) (recoverProc, error) {
			r.opened = append(r.opened, pid)
			if r.openErr != nil {
				return nil, r.openErr
			}
			return r.proc, nil
		},
		stop: func(string, time.Duration) error {
			r.stops++
			if r.stopErr != nil {
				return r.stopErr
			}
			r.proc.stopped = true
			return nil
		},
		selfImage: r.self,
		log:       r.logger.log,
		out:       &r.out,
	}
}

func (r *stopRig) untouched(t *testing.T) {
	t.Helper()
	if r.stops != 0 || r.proc.terminated {
		t.Fatalf("stops %d, terminated %v: want nothing sent and nothing ended", r.stops, r.proc.terminated)
	}
}

func TestStop_NotRunning_ExitsZeroSayingSo(t *testing.T) {
	r := newStopRig()
	if code := stopRun(r.deps()); code != 0 {
		t.Fatalf("stop = %d, want 0; out %q", code, r.out.String())
	}
	if !strings.Contains(r.out.String(), "not running") {
		t.Fatalf("out %q, want it to say not running", r.out.String())
	}
	if len(r.opened) != 0 {
		t.Fatalf("opened %v with no daemon", r.opened)
	}
	r.untouched(t)
}

// A pid in a lock nobody holds is a dead daemon's - maybe another
// program's by now - and is never opened, asked or ended.
func TestStop_StaleLockPid_NotRunningAndNeverTouched(t *testing.T) {
	r := newStopRig()
	r.lockPID, r.named, r.held = 100, true, false
	if code := stopRun(r.deps()); code != 0 {
		t.Fatalf("stop = %d, want 0", code)
	}
	if len(r.opened) != 0 {
		t.Fatalf("stale pid opened: %v", r.opened)
	}
	r.untouched(t)
	if !strings.Contains(r.out.String(), "not running") || !strings.Contains(r.out.String(), "pid 100") {
		t.Fatalf("out %q, want not running naming the stale pid", r.out.String())
	}
}

func TestStop_ControlStop_ExitsZeroNothingEnded(t *testing.T) {
	r := newStopRig()
	r.running(100)
	if code := stopRun(r.deps()); code != 0 {
		t.Fatalf("stop = %d, want 0; out %q", code, r.out.String())
	}
	if len(r.opened) != 1 || r.opened[0] != 100 || r.stops != 1 {
		t.Fatalf("opened %v stops %d, want pid 100 opened and one stop", r.opened, r.stops)
	}
	if r.proc.terminated {
		t.Fatal("a daemon that stopped on the control socket was also terminated")
	}
	if r.proc.waits[0] != stopWait {
		t.Fatalf("waited %v after the stop, want %v", r.proc.waits[0], stopWait)
	}
	if !r.proc.closed {
		t.Fatal("the process handle was not closed")
	}
	if !strings.Contains(r.out.String(), "pid 100 stopped") {
		t.Fatalf("out %q", r.out.String())
	}
}

// The handle is opened BEFORE the stop: the pid cannot be reused between.
func TestStop_HandleOpenedBeforeTheStop(t *testing.T) {
	r := newStopRig()
	r.running(100)
	d := r.deps()
	inner := d.stop
	d.stop = func(p string, to time.Duration) error {
		if len(r.opened) == 0 {
			t.Fatal("stop sent before the pid's handle was opened")
		}
		return inner(p, to)
	}
	stopRun(d)
}

func TestStop_IgnoresStop_HotkeydImage_EndedByPid(t *testing.T) {
	for _, tc := range []struct{ name, image, self string }{
		{"hotkeyd.exe", `C:\Users\j\AppData\Local\hotkeyd\bin\HOTKEYD.EXE`, ""},
		{"this binary", `C:\t\hotkeyd.test.exe`, `c:\T\hotkeyd.test.exe`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newStopRig()
			r.running(100)
			r.proc.exitsOnStop = false
			r.proc.image, r.self = tc.image, tc.self
			if code := stopRun(r.deps()); code != 0 {
				t.Fatalf("stop = %d, want 0; out %q", code, r.out.String())
			}
			if !r.proc.terminated {
				t.Fatal("a hotkeyd that ignored the stop was not ended")
			}
			if !r.logger.contains("BY PID") || !r.logger.contains("never by name") {
				t.Fatalf("ending by pid not logged: %v", r.logger.all())
			}
			if !strings.Contains(r.out.String(), "ended by pid") {
				t.Fatalf("out %q, want it to say ended by pid", r.out.String())
			}
		})
	}
}

// No control socket at all (the request fails): still ended by pid.
func TestStop_ControlSocketGone_EndedByPid(t *testing.T) {
	r := newStopRig()
	r.running(100)
	r.stopErr = errors.New("dial: no such file")
	if code := stopRun(r.deps()); code != 0 {
		t.Fatalf("stop = %d; out %q", code, r.out.String())
	}
	if !r.proc.terminated {
		t.Fatal("not ended")
	}
	if !r.logger.contains("control socket's stop failed") {
		t.Fatalf("the failed request is not said: %v", r.logger.all())
	}
}

func TestStop_IgnoresStop_NotHotkeyd_RefusedNothingEnded(t *testing.T) {
	r := newStopRig()
	r.running(100)
	r.proc.exitsOnStop = false
	r.proc.image = `C:\Windows\System32\PING.EXE`
	r.self = `C:\t\hotkeyd.test.exe`
	if code := stopRun(r.deps()); code != 1 {
		t.Fatalf("stop = %d, want 1", code)
	}
	if r.proc.terminated {
		t.Fatal("a pid that is not hotkeyd was ended")
	}
	if !strings.Contains(r.out.String(), "PING.EXE") || !strings.Contains(r.out.String(), "nothing ended") {
		t.Fatalf("out %q, want the image named and nothing ended", r.out.String())
	}
}

func TestStop_ImageUnreadable_RefusedNothingEnded(t *testing.T) {
	r := newStopRig()
	r.running(100)
	r.proc.exitsOnStop = false
	r.proc.imageErr = errors.New("access denied")
	if code := stopRun(r.deps()); code != 1 {
		t.Fatalf("stop = %d, want 1", code)
	}
	if r.proc.terminated {
		t.Fatal("ended a pid whose image could not be read")
	}
}

func TestStop_StillRunningAfterTerminate_ExitsOne(t *testing.T) {
	r := newStopRig()
	r.running(100)
	r.proc.exitsOnStop = false
	r.proc.stuck = true
	if code := stopRun(r.deps()); code != 1 {
		t.Fatalf("stop = %d, want 1", code)
	}
	if !strings.Contains(r.out.String(), "still running after TerminateProcess") {
		t.Fatalf("out %q", r.out.String())
	}
}

func TestStop_HeldButNoPid_ExitsOneNothingOpened(t *testing.T) {
	r := newStopRig()
	r.held = true
	if code := stopRun(r.deps()); code != 1 {
		t.Fatalf("stop = %d, want 1", code)
	}
	if len(r.opened) != 0 {
		t.Fatalf("opened %v", r.opened)
	}
	r.untouched(t)
}

func TestStop_CannotOpen(t *testing.T) {
	t.Run("still held: exit 1", func(t *testing.T) {
		r := newStopRig()
		r.running(100)
		r.openErr, r.heldAfterOpenFail = errors.New("access denied"), true
		if code := stopRun(r.deps()); code != 1 {
			t.Fatalf("stop = %d, want 1", code)
		}
		r.untouched(t)
	})
	t.Run("gone meanwhile: not running", func(t *testing.T) {
		r := newStopRig()
		r.running(100)
		r.openErr = errors.New("invalid parameter")
		if code := stopRun(r.deps()); code != 0 || !strings.Contains(r.out.String(), "not running") {
			t.Fatalf("stop = %d, out %q; want 0, not running", code, r.out.String())
		}
		r.untouched(t)
	})
}

// recover's step 2 is the same ender: a stuck pid that is not hotkeyd is
// never ended there either, and recover exits 1 without starting another.
func TestRecover_StuckPidNotHotkeyd_NeverEnded(t *testing.T) {
	r := newRecoverRig()
	r.runningDaemon(100)
	r.proc.exitsOnStop = false
	r.proc.image = `C:\Windows\notepad.exe`
	if code := recoverRun(r.deps()); code != 1 {
		t.Fatalf("recover = %d, want 1; out %q", code, r.out.String())
	}
	if r.proc.terminated {
		t.Fatal("recover ended a pid that is not hotkeyd")
	}
	if len(r.started) != 0 {
		t.Fatalf("recover started %d daemons beside a live lock holder", len(r.started))
	}
	if !strings.Contains(r.out.String(), "notepad.exe") {
		t.Fatalf("out %q, want the image named", r.out.String())
	}
}

func TestIsHotkeydImage(t *testing.T) {
	for _, tc := range []struct {
		image, self string
		want        bool
	}{
		{`C:\x\hotkeyd.exe`, "", true},
		{`C:\x\HotKeyD.EXE`, "", true},
		{`C:/x/hotkeyd.exe`, "", true},
		{`C:\x\nothotkeyd.exe`, "", false},
		{`C:\x\hotkeyd.exe.bak`, "", false},
		{`C:\x\ping.exe`, `C:\x\ping2.exe`, false},
		{`C:\t\a.test.exe`, `c:\T\A.TEST.EXE`, true},
		{"", "", false},
		{"", `C:\t\a.exe`, false},
	} {
		if got := isHotkeydImage(tc.image, tc.self); got != tc.want {
			t.Errorf("isHotkeydImage(%q, %q) = %v, want %v", tc.image, tc.self, got, tc.want)
		}
	}
}

// --help names Windows' default input and the stop subcommand.
func TestUsage_NamesInputWin32AndStop(t *testing.T) {
	u := usageText()
	for _, want := range []string{"--input win32", "hotkeyd stop [--display DESKTOP]"} {
		if !strings.Contains(u, want) {
			t.Errorf("usage does not name %q", want)
		}
	}
}

func TestDispatch_Stop_RefusedOffWindows(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the Windows stop is stop_windows_test.go's")
	}
	if code := Dispatch([]string{"stop"}); code != 2 {
		t.Fatalf("Dispatch(stop) = %d off Windows, want 2", code)
	}
}
