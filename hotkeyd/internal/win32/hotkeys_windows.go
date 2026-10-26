package win32

// sp012 Task 4 (kwi3-hoex.4): the RegisterHotKey thread. One goroutine,
// locked to its OS thread for its whole life, owns a message-only window
// and runs its message loop. RegisterHotKey and UnregisterHotKey must run
// on the thread that owns the window, so the daemon's calls (Registrar)
// are queued to the loop and woken with a posted message; every
// WM_HOTKEY the window receives is translated (Translate) and sent on
// Events. When the loop's thread ends, Windows frees whatever it still
// held.
//
// SAFETY: registrations are shared by every desktop of the window station
// (measured by kwi3-hoex.8: a registration from a CreateDesktop desktop
// took the chord from Jan's live one). A test must never register a chord
// anybody types; DryRun registers nothing at all.

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"syscall"
	"unsafe"
)

var (
	modUser32            = syscall.NewLazyDLL("user32.dll")
	modKernel32          = syscall.NewLazyDLL("kernel32.dll")
	procRegisterClassExW = modUser32.NewProc("RegisterClassExW")
	procCreateWindowExW  = modUser32.NewProc("CreateWindowExW")
	procDestroyWindow    = modUser32.NewProc("DestroyWindow")
	procDefWindowProcW   = modUser32.NewProc("DefWindowProcW")
	procGetMessageW      = modUser32.NewProc("GetMessageW")
	procTranslateMessage = modUser32.NewProc("TranslateMessage")
	procDispatchMessageW = modUser32.NewProc("DispatchMessageW")
	procPostMessageW     = modUser32.NewProc("PostMessageW")
	procRegisterHotKey   = modUser32.NewProc("RegisterHotKey")
	procUnregisterHotKey = modUser32.NewProc("UnregisterHotKey")
	procGetAsyncKeyState = modUser32.NewProc("GetAsyncKeyState")
	procGetThreadDesktop = modUser32.NewProc("GetThreadDesktop")
	procGetUserObjectInf = modUser32.NewProc("GetUserObjectInformationW")
	procGetModuleHandleW = modKernel32.NewProc("GetModuleHandleW")
	procGetCurrentThread = modKernel32.NewProc("GetCurrentThreadId")
)

const (
	hwndMessage             = ^uintptr(2) // HWND_MESSAGE, (HWND)-3
	wmApp                   = 0x8000
	wmWake                  = wmApp + 1 // run the queued requests
	wmStop                  = wmApp + 2 // leave the loop
	errorClassAlreadyExists = 1410
	uoiName                 = 2

	// ClassName is the message-only window's class: a test or the rig
	// finds the daemon's window by it (FindWindowEx(HWND_MESSAGE, ...)).
	ClassName = "hotkeyd-win32"
)

type wndClassEx struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     uintptr
	hIcon         uintptr
	hCursor       uintptr
	hbrBackground uintptr
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       uintptr
}

type msg struct {
	hwnd     uintptr
	message  uint32
	wParam   uintptr
	lParam   uintptr
	time     uint32
	ptX, ptY int32
	lPrivate uint32
}

// Options configure a Source.
type Options struct {
	// DryRun makes Register and Unregister succeed without calling
	// Windows: nothing is registered, and only a WM_HOTKEY posted to the
	// window reaches Events. For a test, or a rig that must prove
	// dispatch without taking a chord from the window station.
	DryRun bool
	// Register, when set, stands in for RegisterHotKey on the loop's
	// thread (a test's way to answer with a chosen result).
	Register func(hwnd uintptr, id int32, mods uint32, vk uint16) error
	// Buffer is the Events channel's size (default 64). A WM_HOTKEY
	// arriving with the channel full is dropped and counted (Dropped).
	Buffer int
}

// Source is the running hotkey thread. It implements Registrar.
type Source struct {
	hwnd    uintptr
	tid     uint32
	opts    Options
	events  chan Event
	reqs    chan func()
	stopped chan struct{}

	mu      sync.Mutex
	closed  bool
	dropped int
}

// Start starts the thread, creates its window and returns once the window
// exists (or with the reason it could not be created).
func Start(opts Options) (*Source, error) {
	if opts.Buffer <= 0 {
		opts.Buffer = 64
	}
	s := &Source{opts: opts, events: make(chan Event, opts.Buffer),
		reqs: make(chan func(), 16), stopped: make(chan struct{})}
	ready := make(chan error, 1)
	go s.loop(ready)
	if err := <-ready; err != nil {
		return nil, err
	}
	return s, nil
}

// Window is the message-only window's handle.
func (s *Source) Window() uintptr { return s.hwnd }

// ThreadID is the loop thread's id.
func (s *Source) ThreadID() uint32 { return s.tid }

// Events is the translated WM_HOTKEY stream; it is closed when the loop
// ends.
func (s *Source) Events() <-chan Event { return s.events }

// Dropped is how many WM_HOTKEYs found Events full.
func (s *Source) Dropped() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dropped
}

var errStopped = errors.New("the hotkey thread has stopped")

// call runs f on the loop's thread and waits for it.
func (s *Source) call(f func()) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return errStopped
	}
	s.mu.Unlock()
	done := make(chan struct{})
	select {
	case s.reqs <- func() { f(); close(done) }:
	case <-s.stopped:
		return errStopped
	}
	if r, _, err := procPostMessageW.Call(s.hwnd, wmWake, 0, 0); r == 0 {
		return fmt.Errorf("PostMessageW (wake the hotkey thread): %w", err)
	}
	select {
	case <-done:
		return nil
	case <-s.stopped:
		return errStopped
	}
}

// Register is RegisterHotKey(window, id, mods, vk) on the loop's thread.
func (s *Source) Register(id int32, mods uint32, vk uint16) error {
	var res error
	if err := s.call(func() { res = s.register(id, mods, vk) }); err != nil {
		return err
	}
	return res
}

// Unregister is UnregisterHotKey(window, id) on the loop's thread.
func (s *Source) Unregister(id int32) error {
	var res error
	if err := s.call(func() { res = s.unregister(id) }); err != nil {
		return err
	}
	return res
}

func (s *Source) register(id int32, mods uint32, vk uint16) error {
	if s.opts.DryRun {
		return nil
	}
	if s.opts.Register != nil {
		return s.opts.Register(s.hwnd, id, mods, vk)
	}
	r, _, err := procRegisterHotKey.Call(s.hwnd, uintptr(id), uintptr(mods), uintptr(vk))
	if r == 0 {
		return err
	}
	return nil
}

func (s *Source) unregister(id int32) error {
	if s.opts.DryRun || s.opts.Register != nil {
		return nil
	}
	r, _, err := procUnregisterHotKey.Call(s.hwnd, uintptr(id))
	if r == 0 {
		return err
	}
	return nil
}

// Close ends the loop and waits for it. Windows frees every registration
// the thread still held when it ends.
func (s *Source) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		<-s.stopped
		return
	}
	s.closed = true
	s.mu.Unlock()
	procPostMessageW.Call(s.hwnd, wmStop, 0, 0)
	<-s.stopped
}

func (s *Source) loop(ready chan<- error) {
	runtime.LockOSThread()
	// Never unlocked: the thread is the window's owner and ends with the
	// goroutine, taking any registration left with it.
	defer close(s.stopped)
	defer close(s.events)

	tid, _, _ := procGetCurrentThread.Call()
	s.tid = uint32(tid)
	hinst, _, _ := procGetModuleHandleW.Call(0)
	cls, _ := syscall.UTF16PtrFromString(ClassName)
	wc := wndClassEx{lpfnWndProc: procDefWindowProcW.Addr(), hInstance: hinst, lpszClassName: cls}
	wc.cbSize = uint32(unsafe.Sizeof(wc))
	if r, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc))); r == 0 {
		if errno, ok := err.(syscall.Errno); !ok || errno != errorClassAlreadyExists {
			ready <- fmt.Errorf("RegisterClassExW: %w", err)
			return
		}
	}
	hwnd, _, err := procCreateWindowExW.Call(0, uintptr(unsafe.Pointer(cls)), uintptr(unsafe.Pointer(cls)),
		0, 0, 0, 0, 0, hwndMessage, 0, hinst, 0)
	if hwnd == 0 {
		ready <- fmt.Errorf("CreateWindowExW (message-only): %w", err)
		return
	}
	s.hwnd = hwnd
	ready <- nil

	var m msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 { // WM_QUIT or an error: the loop cannot go on
			break
		}
		if m.hwnd == hwnd {
			switch m.message {
			case WM_HOTKEY:
				if ev, ok := Translate(m.lParam); ok {
					select {
					case s.events <- ev:
					default:
						s.mu.Lock()
						s.dropped++
						s.mu.Unlock()
					}
				}
				continue
			case wmWake:
				s.drain()
				continue
			case wmStop:
				s.drain()
				procDestroyWindow.Call(hwnd)
				s.mu.Lock()
				s.closed = true
				s.mu.Unlock()
				return
			}
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	s.mu.Lock()
	s.closed = true
	s.mu.Unlock()
	procDestroyWindow.Call(hwnd)
}

func (s *Source) drain() {
	for {
		select {
		case f := <-s.reqs:
			f()
		default:
			return
		}
	}
}

// KeyDown is GetAsyncKeyState's "down now" bit, for the hold-layer poll.
// It reads 0 for every key while this desktop is not the input desktop.
func KeyDown(vk uint16) bool {
	r, _, _ := procGetAsyncKeyState.Call(uintptr(vk))
	return r&0x8000 != 0
}

// DesktopName is the name of the desktop the calling thread is on
// ("Default" on Jan's session, kwi3t-<pid>-<group> on a rig desktop).
func DesktopName() (string, error) {
	tid, _, _ := procGetCurrentThread.Call()
	h, _, err := procGetThreadDesktop.Call(tid)
	if h == 0 {
		return "", fmt.Errorf("GetThreadDesktop: %w", err)
	}
	buf := make([]uint16, 256)
	var need uint32
	r, _, err := procGetUserObjectInf.Call(h, uoiName, uintptr(unsafe.Pointer(&buf[0])),
		uintptr(len(buf)*2), uintptr(unsafe.Pointer(&need)))
	if r == 0 {
		return "", fmt.Errorf("GetUserObjectInformationW(UOI_NAME): %w", err)
	}
	return syscall.UTF16ToString(buf), nil
}
