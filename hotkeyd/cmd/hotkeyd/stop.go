package main

// kwi3-hoex.30: `hotkeyd stop [--display DESKTOP]`, the Windows daemon's
// stop - what install-win32.sh asks for before it replaces a running
// hotkeyd.exe, and what a person runs instead of `taskkill`. Plain
// `taskkill /PID` reports SUCCESS and leaves the daemon running (it has no
// console and no top-level window that answers WM_CLOSE; MEASURED under
// kwi3-hoex.18), and `/F` is a TerminateProcess: no shutdown, the lock
// file left naming a dead pid.
//
// The sequence, each step said:
//
//  1. no daemon - the lock is not held - is exit 0, "not running": the
//     state a caller asked for already holds. A pid the file still names
//     is a dead daemon's and may be another program's by now; it is left
//     alone.
//  2. a {"stop":true} on the desktop's control socket: the daemon answers,
//     leaves its run loop and shuts down as on SIGTERM - every
//     RegisterHotKey released, its low-level hook removed, the state feed
//     and control socket closed, the lock released and its file emptied
//     (so the next start has no dead pid to "take over" from).
//  3. up to stopWait for the process to exit, on a handle opened by the
//     lock's pid BEFORE the request, so the pid cannot be reused between.
//  4. one that has not exited (or whose control socket does not answer)
//     is ended BY THAT HANDLE (TerminateProcess) - but only when the
//     handle's image is hotkeyd.exe (or this very binary); anything else
//     is refused, exit 1, nothing ended. Never by name.
//
// Exit codes: 0 stopped or not running; 1 the daemon could not be stopped
// (named why); 2 a usage error.
//
// No modifier key-up is sent: the daemon's hook passes every modifier
// (internal/win32 llhook.go), so its exit strands none, and synthetic
// input stays recover's alone ([[adr0021]]'s amended second case).
//
// Pure over stopDeps, like recover: stop_test.go drives every branch on
// Linux; recover_windows.go wires the real ones.

import (
	"fmt"
	"io"
	"strings"
	"time"

	"hotkeyd/internal/proc"
)

const (
	// stopControlTimeout bounds the stop request.
	stopControlTimeout = time.Second
	// stopWait bounds each wait for the daemon to exit: after the stop
	// request, and again after TerminateProcess.
	stopWait = 5 * time.Second
)

// stopDeps is `hotkeyd stop`'s I/O seam set.
type stopDeps struct {
	display  string
	lockPID  func(path string) (int, bool)
	lockHeld func(path string) bool
	openProc func(pid int) (recoverProc, error)
	stop     func(controlPath string, timeout time.Duration) error
	// selfImage: see recoverDeps.selfImage.
	selfImage string
	log       func(string)
	out       io.Writer
}

// stopRun is `hotkeyd stop`: the exit code.
func stopRun(d stopDeps) int {
	disp := resolveDisplay(d.display)
	lp := proc.LockPath(disp)
	pid, named := d.lockPID(lp)
	if !d.lockHeld(lp) {
		if named {
			fmt.Fprintf(d.out, "hotkeyd stop: %s — not running (%s names pid %d, which no longer holds it; that pid is left alone)\n", disp, lp, pid)
		} else {
			fmt.Fprintf(d.out, "hotkeyd stop: %s — not running\n", disp)
		}
		return 0
	}
	if !named {
		fmt.Fprintf(d.out, "hotkeyd stop: %s — %s is held but names no pid; nothing ended\n", disp, lp)
		return 1
	}
	p, err := d.openProc(pid)
	if err != nil {
		if !d.lockHeld(lp) {
			fmt.Fprintf(d.out, "hotkeyd stop: %s — not running (pid %d exited as the stop began)\n", disp, pid)
			return 0
		}
		fmt.Fprintf(d.out, "hotkeyd stop: %s — the lock is held by pid %d, which cannot be opened: %s; nothing ended\n", disp, pid, err)
		return 1
	}
	defer p.Close()
	e := daemonEnder{name: "stop", stop: d.stop, selfImage: d.selfImage, log: d.log}
	byPid, err := e.end(p, pid, proc.ControlPath(disp), stopWait, func(b time.Duration) time.Duration { return b })
	if err != nil {
		fmt.Fprintf(d.out, "hotkeyd stop: %s — %s\n", disp, err)
		return 1
	}
	if byPid {
		fmt.Fprintf(d.out, "hotkeyd stop: %s — pid %d ended by pid (it did not stop on the control socket's stop)\n", disp, pid)
	} else {
		fmt.Fprintf(d.out, "hotkeyd stop: %s — pid %d stopped\n", disp, pid)
	}
	return 0
}

// daemonEnder ends a running daemon: `hotkeyd stop`'s and recover's step 2.
type daemonEnder struct {
	name      string // "stop" or "recover": the log prefix
	stop      func(controlPath string, timeout time.Duration) error
	selfImage string
	log       func(string)
}

// end sends the control socket's stop, waits up to wait for p to exit,
// and ends one that has not BY p's handle, only if its image is hotkeyd's.
// bound cuts every timeout and wait (recover's shared budget; identity for
// stop). nil error means the process is gone; byPid says how.
func (e daemonEnder) end(p recoverProc, pid int, controlPath string, wait time.Duration, bound func(time.Duration) time.Duration) (byPid bool, err error) {
	if err := e.stop(controlPath, bound(recoverControlTimeout)); err != nil {
		e.log(fmt.Sprintf("%s: pid %d: the control socket's stop failed: %s", e.name, pid, err))
	}
	w := bound(wait)
	if p.Wait(w) {
		e.log(fmt.Sprintf("%s: pid %d stopped on the control socket's stop", e.name, pid))
		return false, nil
	}
	image, ierr := p.Image()
	if ierr != nil {
		return false, fmt.Errorf("pid %d did not exit within %s of the stop, and its image cannot be read (%s); nothing ended", pid, w, ierr)
	}
	if !isHotkeydImage(image, e.selfImage) {
		return false, fmt.Errorf("pid %d did not exit within %s of the stop, and it runs %s, not hotkeyd.exe; nothing ended", pid, w, image)
	}
	e.log(fmt.Sprintf("%s: pid %d did not exit within %s of the stop; ending it BY PID (TerminateProcess on pid %d, %s, never by name)",
		e.name, pid, w, pid, image))
	if err := p.Terminate(); err != nil {
		return false, fmt.Errorf("TerminateProcess on pid %d failed: %s", pid, err)
	}
	if !p.Wait(bound(wait)) {
		return false, fmt.Errorf("pid %d is still running after TerminateProcess", pid)
	}
	e.log(fmt.Sprintf("%s: pid %d ended by pid", e.name, pid))
	return true, nil
}

// isHotkeydImage: image (a full Windows path) is a hotkeyd.exe, or exactly
// self - the binary asking. Case-insensitive, as Windows paths are.
func isHotkeydImage(image, self string) bool {
	if image == "" {
		return false
	}
	if strings.EqualFold(winBase(image), "hotkeyd.exe") {
		return true
	}
	return self != "" && strings.EqualFold(image, self)
}

// winBase is the last element of a Windows (or slash) path.
func winBase(p string) string {
	if i := strings.LastIndexAny(p, `\/`); i >= 0 {
		return p[i+1:]
	}
	return p
}
