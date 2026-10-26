package win32

// sp012 Task 5 (kwi3-hoex.5): the WH_KEYBOARD_LL hook. One goroutine,
// locked to its OS thread for its whole life, installs the hook and runs
// the message loop Windows calls the hook from. The callback reads the
// KBDLLHOOKSTRUCT, asks Hook.Decide (llhook.go) and returns 1 to swallow
// or CallNextHookEx to pass - nothing else: no call into the daemon, no
// wait.
//
// SAFETY: a low-level hook is SESSION-wide - installed from any desktop it
// sees, and can swallow, every key typed in the session, Jan's included.
// So:
//   - DryRun installs nothing (HOTKEYD_WIN32_DRYRUN=1, cmd/hotkeyd);
//   - a test binary can NEVER install a real one: the real installer
//     refuses when testing.Testing() - a test passes HookOptions.Install;
//   - the recover chord always passes (llhook.go).
//
// A hook Windows has removed (a callback past LowLevelHooksTimeout is
// unhooked without a word) is noticed by a probe every ProbeEvery: when
// the keyboard's modifier state disagrees with what the hook tracked, and
// still does a moment later, the hook is reinstalled and the state resynced
// from GetAsyncKeyState. The probe also re-states the tracked modifiers
// every tick (Hook.Remind), healing a dropped or out-of-order "mods".
//
// Over RDP the session sees Alt+Tab only when the client forwards Windows
// key combinations: Jan's .rdp needs `keyboardhook:i:1` ("Apply Windows key
// combinations: On the remote computer"). Without it mstsc keeps Alt+Tab
// on the client and this hook never sees it; Alt+<letter> arrives either
// way. The .rdp is Jan's file - documented here, never edited by hotkeyd.

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

var (
	procSetWindowsHookExW   = modUser32.NewProc("SetWindowsHookExW")
	procUnhookWindowsHookEx = modUser32.NewProc("UnhookWindowsHookEx")
	procCallNextHookEx      = modUser32.NewProc("CallNextHookEx")
	procPostThreadMessageW  = modUser32.NewProc("PostThreadMessageW")
	procPeekMessageW        = modUser32.NewProc("PeekMessageW")
)

const (
	whKeyboardLL = 13
	wmKeyUp      = 0x0101
	wmSysKeyUp   = 0x0105
	wmQuit       = 0x0012
	wmReinstall  = wmApp + 10
	wmRemind     = wmApp + 11
)

// kbdllhookstruct is KBDLLHOOKSTRUCT.
type kbdllhookstruct struct {
	vkCode      uint32
	scanCode    uint32
	flags       uint32
	time        uint32
	dwExtraInfo uintptr
}

// HookOptions configure StartHook.
type HookOptions struct {
	// DryRun installs no hook: Decide is reached only through Proc (a
	// test calling the callback directly).
	DryRun bool
	// Install stands in for SetWindowsHookExW(WH_KEYBOARD_LL, proc,
	// hInstance, 0), Uninstall for UnhookWindowsHookEx. A test passes
	// both; production leaves them nil.
	Install   func(proc uintptr) (uintptr, error)
	Uninstall func(h uintptr) error
	// KeyDown reads the keyboard (default: GetAsyncKeyState).
	KeyDown func(vk uint16) bool
	// ProbeEvery is the removed-hook probe's interval (default 10s);
	// ProbeConfirm the wait before a disagreement counts (default 100ms).
	ProbeEvery   time.Duration
	ProbeConfirm time.Duration
	Log          func(string)
}

// HookThread is the running hook.
type HookThread struct {
	hook    *Hook
	opts    HookOptions
	tid     uint32
	handle  uintptr
	stopped chan struct{}
	stop    chan struct{}

	installs   atomic.Int32
	reinstalls atomic.Int32
	closeOnce  sync.Once
}

// The callback is one process-wide function (syscall.NewCallback slots are
// never freed), dispatching to whichever hook is current.
var (
	cbOnce  sync.Once
	cbAddr  uintptr
	current atomic.Pointer[Hook]
)

func callbackAddr() uintptr {
	cbOnce.Do(func() { cbAddr = syscall.NewCallback(hookProc) })
	return cbAddr
}

func callNext(nCode, wParam, lParam uintptr) uintptr {
	r, _, _ := procCallNextHookEx.Call(0, nCode, wParam, lParam)
	return r
}

// hookProc is the LowLevelKeyboardProc. lParam is the KBDLLHOOKSTRUCT.
func hookProc(nCode, wParam uintptr, k *kbdllhookstruct) uintptr {
	h := current.Load()
	if int32(nCode) < 0 || h == nil || k == nil {
		return callNext(nCode, wParam, uintptr(unsafe.Pointer(k)))
	}
	in := KeyInput{VK: uint16(k.vkCode), Scan: k.scanCode, Flags: k.flags,
		Up: wParam == wmKeyUp || wParam == wmSysKeyUp}
	if h.Decide(in) {
		return 1
	}
	return callNext(nCode, wParam, uintptr(unsafe.Pointer(k)))
}

// Proc is the hook procedure's address, for a test that calls it directly
// (syscall.SyscallN) with a KBDLLHOOKSTRUCT of its own.
func Proc() uintptr { return callbackAddr() }

// NewKBDLLHookStruct builds the struct hookProc reads, for such a test.
func NewKBDLLHookStruct(vk uint16, flags uint32) unsafe.Pointer {
	return unsafe.Pointer(&kbdllhookstruct{vkCode: uint32(vk), flags: flags})
}

var errInstallInTest = errors.New("refusing a real WH_KEYBOARD_LL hook in a test binary: it would see and swallow every key in the session")

func realInstall(proc uintptr) (uintptr, error) {
	if testing.Testing() {
		return 0, errInstallInTest
	}
	hinst, _, _ := procGetModuleHandleW.Call(0)
	h, _, err := procSetWindowsHookExW.Call(whKeyboardLL, proc, hinst, 0)
	if h == 0 {
		return 0, fmt.Errorf("SetWindowsHookExW(WH_KEYBOARD_LL): %w", err)
	}
	return h, nil
}

func realUninstall(h uintptr) error {
	if r, _, err := procUnhookWindowsHookEx.Call(h); r == 0 {
		return err
	}
	return nil
}

// StartHook installs the hook on a thread of its own and returns once it
// is installed (or with why it could not be). The hook state is first
// resynced from the keyboard, so a $mod released while hotkeyd was not
// running leaves nothing held.
func StartHook(h *Hook, opts HookOptions) (*HookThread, error) {
	if opts.Install == nil {
		opts.Install = realInstall
	}
	if opts.Uninstall == nil {
		opts.Uninstall = realUninstall
	}
	if opts.KeyDown == nil {
		opts.KeyDown = KeyDown
	}
	if opts.ProbeEvery <= 0 {
		opts.ProbeEvery = 10 * time.Second
	}
	if opts.ProbeConfirm <= 0 {
		opts.ProbeConfirm = 100 * time.Millisecond
	}
	if opts.Log == nil {
		opts.Log = func(string) {}
	}
	if !current.CompareAndSwap(nil, h) {
		return nil, errors.New("a low-level hook is already running in this process")
	}
	t := &HookThread{hook: h, opts: opts, stopped: make(chan struct{}), stop: make(chan struct{})}
	ready := make(chan error, 1)
	go t.loop(ready)
	if err := <-ready; err != nil {
		current.CompareAndSwap(h, nil)
		return nil, err
	}
	go t.probe()
	return t, nil
}

// Installs is how many times the hook was installed (1, plus reinstalls);
// 0 in DryRun.
func (t *HookThread) Installs() int { return int(t.installs.Load()) }

// Reinstalls is how many times the probe found the hook gone.
func (t *HookThread) Reinstalls() int { return int(t.reinstalls.Load()) }

func (t *HookThread) install() error {
	if t.opts.DryRun {
		return nil
	}
	hh, err := t.opts.Install(callbackAddr())
	if err != nil {
		return err
	}
	t.handle = hh
	t.installs.Add(1)
	return nil
}

func (t *HookThread) uninstall() {
	if t.handle != 0 {
		_ = t.opts.Uninstall(t.handle) // fails for a hook Windows removed
		t.handle = 0
	}
}

func (t *HookThread) loop(ready chan<- error) {
	runtime.LockOSThread()
	// Never unlocked: the hook belongs to this thread and goes with it.
	defer close(t.stopped)

	tid, _, _ := procGetCurrentThread.Call()
	t.tid = uint32(tid)
	var m msg
	// Create the thread's message queue before anyone posts to it.
	procPeekMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0, 0)
	t.hook.Resync(t.opts.KeyDown)
	if err := t.install(); err != nil {
		ready <- err
		return
	}
	ready <- nil

	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 { // WM_QUIT or an error
			break
		}
		if m.hwnd == 0 {
			switch m.message {
			case wmReinstall:
				t.uninstall()
				t.hook.Resync(t.opts.KeyDown)
				if err := t.install(); err != nil {
					t.opts.Log("low-level hook: reinstall failed: " + err.Error())
				}
				continue
			case wmRemind:
				t.hook.Remind()
				continue
			}
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	t.uninstall()
}

func (t *HookThread) post(message uint32) {
	procPostThreadMessageW.Call(uintptr(t.tid), uintptr(message), 0, 0)
}

// probe is the removed-hook check, one tick per ProbeEvery.
func (t *HookThread) probe() {
	tick := time.NewTicker(t.opts.ProbeEvery)
	defer tick.Stop()
	for {
		select {
		case <-t.stop:
			return
		case <-tick.C:
		}
		if t.hook.Stale(t.opts.KeyDown) {
			select {
			case <-t.stop:
				return
			case <-time.After(t.opts.ProbeConfirm):
			}
			if t.hook.Stale(t.opts.KeyDown) {
				n := t.reinstalls.Add(1)
				t.opts.Log(fmt.Sprintf("low-level hook: modifier state %#x but the hook saw %#x - Windows removed it? reinstalling (%d so far)",
					ModBits(t.opts.KeyDown), t.hook.Mods(), n))
				t.post(wmReinstall)
				continue
			}
		}
		t.post(wmRemind)
	}
}

// Close removes the hook and ends its thread.
func (t *HookThread) Close() {
	t.closeOnce.Do(func() {
		close(t.stop)
		t.post(wmQuit)
		<-t.stopped
		current.CompareAndSwap(t.hook, nil)
	})
}
