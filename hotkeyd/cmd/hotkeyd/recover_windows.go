//go:build windows

package main

// sp012 Task 7 (kwi3-hoex.7): the real recoverDeps and the Windows --health
// probes. recover.go has the sequence; this file only reaches Windows.

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"hotkeyd/internal/proc"
	"hotkeyd/internal/win32"
)

var (
	modUser32Recover       = syscall.NewLazyDLL("user32.dll")
	modKernel32Recover     = syscall.NewLazyDLL("kernel32.dll")
	procSendInput          = modUser32Recover.NewProc("SendInput")
	procMapVirtualKeyW     = modUser32Recover.NewProc("MapVirtualKeyW")
	procOpenProcess        = modKernel32Recover.NewProc("OpenProcess")
	procGetExitCodeProcess = modKernel32Recover.NewProc("GetExitCodeProcess")
)

const (
	processTerminate               = 0x0001
	processQueryLimitedInformation = 0x1000
	processSynchronize             = 0x00100000
	stillActive                    = 259

	inputKeyboard        = 1
	keyeventfExtendedKey = 0x0001
	keyeventfKeyUp       = 0x0002
	mapvkVKToVSC         = 0
)

// keybdInput is INPUT with its KEYBDINPUT arm: 40 bytes on amd64, the size
// of the union's largest arm (MOUSEINPUT), which is what SendInput checks
// cbSize against.
type keybdInput struct {
	typ   uint32
	_     uint32
	vk    uint16
	scan  uint16
	flags uint32
	time  uint32
	extra uintptr
	_     [8]byte
}

// extendedModifier: the right Ctrl and Alt and both Win keys are extended
// keys, and a key-up without the flag would read as the left/numpad one.
func extendedModifier(vk uint16) bool {
	switch vk {
	case win32.VK_RCONTROL, win32.VK_RMENU, win32.VK_LWIN, win32.VK_RWIN:
		return true
	}
	return false
}

// sendKeyUp is ONE SendInput call carrying ONE key-up of vk - the only
// synthetic input hotkeyd ever sends ([[adr0021]]'s amended second case).
func sendKeyUp(vk uint16) error {
	scan, _, _ := procMapVirtualKeyW.Call(uintptr(vk), mapvkVKToVSC)
	in := keybdInput{typ: inputKeyboard, vk: vk, scan: uint16(scan), flags: keyeventfKeyUp}
	if extendedModifier(vk) {
		in.flags |= keyeventfExtendedKey
	}
	n, _, err := procSendInput.Call(1, uintptr(unsafe.Pointer(&in)), unsafe.Sizeof(in))
	if n != 1 {
		return fmt.Errorf("SendInput: %w", err)
	}
	return nil
}

// pidAlive: a process with this pid exists and has not exited.
func pidAlive(pid int) bool {
	h, _, _ := procOpenProcess.Call(processQueryLimitedInformation, 0, uintptr(pid))
	if h == 0 {
		return false
	}
	defer syscall.CloseHandle(syscall.Handle(h))
	var code uint32
	if r, _, _ := procGetExitCodeProcess.Call(h, uintptr(unsafe.Pointer(&code))); r == 0 {
		return false
	}
	return code == stillActive
}

// winProc is the old daemon's process handle, opened once by pid before
// the stop is sent: Wait and Terminate act on that process and no other,
// whatever the pid means by then.
type winProc struct{ h syscall.Handle }

func openWinProc(pid int) (recoverProc, error) {
	h, _, err := procOpenProcess.Call(processSynchronize|processTerminate|processQueryLimitedInformation, 0, uintptr(pid))
	if h == 0 {
		return nil, fmt.Errorf("OpenProcess(%d): %w", pid, err)
	}
	return winProc{syscall.Handle(h)}, nil
}

func (p winProc) Wait(d time.Duration) bool {
	ev, _ := syscall.WaitForSingleObject(p.h, uint32(d/time.Millisecond))
	return ev == syscall.WAIT_OBJECT_0
}

func (p winProc) Terminate() error { return syscall.TerminateProcess(p.h, 1) }
func (p winProc) Close()           { _ = syscall.CloseHandle(p.h) }

// startedChild is the new daemon; its Wait runs in the background so
// recover can tell an early exit from a slow start.
type startedChild struct {
	pid  int
	mu   sync.Mutex
	code int
	done bool
}

func (c *startedChild) PID() int { return c.pid }
func (c *startedChild) Exited() (int, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.code, c.done
}

// logPath is <desktop>.log beside the lock: the new daemon's stderr (a
// -H windowsgui program has no console). The previous one's is kept as
// <desktop>.log.1.
func logPath(display string) string {
	return strings.TrimSuffix(proc.LockPath(display), ".lock") + ".log"
}

// startDaemon starts this executable as the new daemon with rec's
// arguments and environment, detached.
func startDaemon(display string, rec argsRecord) (recoverChild, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("cannot name this executable: %w", err)
	}
	if err := os.MkdirAll(proc.RuntimeDir(), 0o755); err != nil {
		return nil, err
	}
	lp := logPath(display)
	_ = os.Rename(lp, lp+".1")
	logf, err := os.OpenFile(lp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		logf = nil
	}
	argv := append([]string{exe}, rec.Args...)
	cmd, err := proc.StartDetached(argv, childEnv(os.Environ(), rec), logf)
	if logf != nil {
		logf.Close()
	}
	if err != nil {
		return nil, err
	}
	c := &startedChild{pid: cmd.Process.Pid}
	go func() {
		_ = cmd.Wait()
		c.mu.Lock()
		c.code, c.done = cmd.ProcessState.ExitCode(), true
		c.mu.Unlock()
	}()
	return c, nil
}

// stopViaControl sends {"stop":true}.
func stopViaControl(path string) error {
	t := true
	rep, err := controlCall(path, controlRequest{Stop: &t}, recoverControlTimeout)
	if err != nil {
		return err
	}
	if !rep.OK {
		return errors.New(rep.Error)
	}
	return nil
}

// win32Probes is --health's real I/O on Windows.
func win32Probes() win32HealthProbes {
	return win32HealthProbes{
		lockPID:  proc.LockPID,
		pidAlive: pidAlive,
		status: func(path string) (controlReply, error) {
			return controlStatusAt(path, kwi3ProbeTimeout+recoverControlTimeout)
		},
	}
}

// runHealth is --health's production entry point on Windows.
func runHealth(display string) (int, string) {
	return healthWin32(display, win32Probes())
}

// runRecoverCmd is `hotkeyd recover [--display DESKTOP]`.
func runRecoverCmd(argv []string) int {
	fs := flag.NewFlagSet("hotkeyd recover", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprint(os.Stderr, usageText()) }
	display := fs.String("display", "", "desktop (default: the one this process runs on)")
	if err := fs.Parse(argv); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	dry := strings.TrimSpace(os.Getenv(win32DryRunEnvName)) == "1"
	return recoverRun(recoverDeps{
		display:  *display,
		dryRun:   dry,
		keyDown:  win32.KeyDown,
		keyUp:    sendKeyUp,
		lockPID:  proc.LockPID,
		lockHeld: proc.LockHeld,
		openProc: openWinProc,
		stop:     stopViaControl,
		readArgs: readArgsRecord,
		start: func(rec argsRecord) (recoverChild, error) {
			return startDaemon(resolveDisplay(*display), rec)
		},
		health: runHealth,
		now:    time.Now,
		sleep:  time.Sleep,
		log:    daemonLog,
		out:    os.Stdout,
	})
}
