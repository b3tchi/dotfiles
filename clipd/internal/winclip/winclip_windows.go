//go:build windows

package winclip

import (
	"bytes"
	"errors"
	"fmt"
	"image/png"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")

	pRegisterClassExW              = user32.NewProc("RegisterClassExW")
	pCreateWindowExW               = user32.NewProc("CreateWindowExW")
	pDestroyWindow                 = user32.NewProc("DestroyWindow")
	pDefWindowProcW                = user32.NewProc("DefWindowProcW")
	pGetMessageW                   = user32.NewProc("GetMessageW")
	pDispatchMessageW              = user32.NewProc("DispatchMessageW")
	pPostMessageW                  = user32.NewProc("PostMessageW")
	pPostQuitMessage               = user32.NewProc("PostQuitMessage")
	pAddClipboardFormatListener    = user32.NewProc("AddClipboardFormatListener")
	pRemoveClipboardFormatListener = user32.NewProc("RemoveClipboardFormatListener")
	pOpenClipboard                 = user32.NewProc("OpenClipboard")
	pCloseClipboard                = user32.NewProc("CloseClipboard")
	pEmptyClipboard                = user32.NewProc("EmptyClipboard")
	pEnumClipboardFormats          = user32.NewProc("EnumClipboardFormats")
	pGetClipboardFormatNameW       = user32.NewProc("GetClipboardFormatNameW")
	pRegisterClipboardFormatW      = user32.NewProc("RegisterClipboardFormatW")
	pIsClipboardFormatAvailable    = user32.NewProc("IsClipboardFormatAvailable")
	pGetClipboardData              = user32.NewProc("GetClipboardData")
	pSetClipboardData              = user32.NewProc("SetClipboardData")
	pGetClipboardSequenceNumber    = user32.NewProc("GetClipboardSequenceNumber")

	pGetModuleHandleW = kernel32.NewProc("GetModuleHandleW")
	pGlobalAlloc      = kernel32.NewProc("GlobalAlloc")
	pGlobalFree       = kernel32.NewProc("GlobalFree")
	pGlobalLock       = kernel32.NewProc("GlobalLock")
	pGlobalUnlock     = kernel32.NewProc("GlobalUnlock")
	pGlobalSize       = kernel32.NewProc("GlobalSize")
)

const (
	hwndMessage        = ^uintptr(2) // (HWND)-3
	wmDestroy          = 0x0002
	wmClipboardUpdate  = 0x031D
	wmStop             = 0x8000 + 1 // WM_APP+1
	gmemMoveable       = 0x0002
	errClassExists     = 1410
	className          = "clipdMsgWindow"
	maxFormatNameUnits = 256
)

type wndClassEx struct {
	size       uint32
	style      uint32
	wndProc    uintptr
	clsExtra   int32
	wndExtra   int32
	instance   uintptr
	icon       uintptr
	cursor     uintptr
	background uintptr
	menuName   *uint16
	className  *uint16
	iconSm     uintptr
}

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	ptX     int32
	ptY     int32
	private uint32
}

var (
	classOnce sync.Once
	classErr  error
	wndProcCB = syscall.NewCallback(wndProc)

	// listeners maps a listener window to its event channel. Only the
	// pump thread that owns the window touches it via wndProc.
	listeners sync.Map // uintptr → chan struct{}
)

func wndProc(hwnd, m, wp, lp uintptr) uintptr {
	switch m {
	case wmClipboardUpdate:
		if v, ok := listeners.Load(hwnd); ok {
			select { // never block the pump; the agent dedupes by seq anyway
			case v.(chan struct{}) <- struct{}{}:
			default:
			}
		}
		return 0
	case wmStop:
		pDestroyWindow.Call(hwnd)
		return 0
	case wmDestroy:
		if _, ok := listeners.LoadAndDelete(hwnd); ok {
			pRemoveClipboardFormatListener.Call(hwnd)
			pPostQuitMessage.Call(0)
		}
		return 0
	}
	r, _, _ := pDefWindowProcW.Call(hwnd, m, wp, lp)
	return r
}

func utf16Ptr(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(s)
	return p
}

// newMsgWindow creates a message-only window on the calling (locked) OS
// thread.
func newMsgWindow() (uintptr, error) {
	inst, _, _ := pGetModuleHandleW.Call(0)
	classOnce.Do(func() {
		wc := wndClassEx{wndProc: wndProcCB, instance: inst, className: utf16Ptr(className)}
		wc.size = uint32(unsafe.Sizeof(wc))
		if r, _, err := pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc))); r == 0 {
			if en, ok := err.(syscall.Errno); !ok || en != errClassExists {
				classErr = fmt.Errorf("winclip: RegisterClassExW: %v", err)
			}
		}
	})
	if classErr != nil {
		return 0, classErr
	}
	h, _, err := pCreateWindowExW.Call(0,
		uintptr(unsafe.Pointer(utf16Ptr(className))), 0, 0,
		0, 0, 0, 0, hwndMessage, 0, inst, 0)
	if h == 0 {
		return 0, fmt.Errorf("winclip: CreateWindowExW: %v", err)
	}
	return h, nil
}

// Listener owns a message-only window registered with
// AddClipboardFormatListener; every WM_CLIPBOARDUPDATE becomes one
// (coalescing, non-blocking) send on Events.
type Listener struct {
	events chan struct{}
	hwnd   uintptr
	done   chan struct{}
}

// Listen creates the window and registers it. It fails (for the caller to
// retry with backoff) when the session has no usable window station yet.
func Listen() (*Listener, error) {
	l := &Listener{events: make(chan struct{}, 16), done: make(chan struct{})}
	errc := make(chan error, 1)
	go func() {
		runtime.LockOSThread() // the window and its queue belong to this thread
		defer close(l.done)
		h, err := newMsgWindow()
		if err != nil {
			errc <- err
			return
		}
		listeners.Store(h, l.events)
		if r, _, err := pAddClipboardFormatListener.Call(h); r == 0 {
			listeners.Delete(h)
			pDestroyWindow.Call(h)
			errc <- fmt.Errorf("winclip: AddClipboardFormatListener: %v", err)
			return
		}
		l.hwnd = h
		errc <- nil
		var m msg
		for {
			r, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) <= 0 { // 0 = WM_QUIT, -1 = error
				return
			}
			pDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
		}
	}()
	if err := <-errc; err != nil {
		<-l.done
		return nil, err
	}
	return l, nil
}

func (l *Listener) Events() <-chan struct{} { return l.events }

// Close unregisters the listener, destroys the window and waits for the
// pump to exit.
func (l *Listener) Close() {
	pPostMessageW.Call(l.hwnd, wmStop, 0, 0)
	<-l.done
}

// Seq is GetClipboardSequenceNumber.
func Seq() uint32 {
	r, _, _ := pGetClipboardSequenceNumber.Call()
	return uint32(r)
}

func open(hwnd uintptr) error {
	for i := 0; i < OpenTries; i++ {
		if r, _, _ := pOpenClipboard.Call(hwnd); r != 0 {
			return nil
		}
		time.Sleep(OpenWait)
	}
	return ErrBusy
}

func register(name string) uint32 {
	r, _, _ := pRegisterClipboardFormatW.Call(uintptr(unsafe.Pointer(utf16Ptr(name))))
	return uint32(r)
}

// Clipboard is the reading side used by the agent.
type Clipboard struct{}

func (Clipboard) Seq() uint32 { return Seq() }

// View opens the clipboard (bounded: OpenTries × OpenWait, then ErrBusy),
// runs fn and closes it. All of fn runs on one locked OS thread, as the
// clipboard is opened per thread.
func (Clipboard) View(fn func(View) error) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := open(0); err != nil {
		return err
	}
	defer pCloseClipboard.Call()
	return fn(View{})
}

// View is an open clipboard. Valid only inside Clipboard.View's fn.
type View struct{}

func (View) Formats() ([]Format, error) {
	var out []Format
	var id uintptr
	for {
		id, _, _ = pEnumClipboardFormats.Call(id)
		if id == 0 {
			return out, nil
		}
		f := Format{ID: uint32(id), Name: PredefinedName(uint32(id))}
		if id >= 0xC000 {
			var buf [maxFormatNameUnits]uint16
			n, _, _ := pGetClipboardFormatNameW.Call(id, uintptr(unsafe.Pointer(&buf[0])), maxFormatNameUnits)
			f.Name = syscall.UTF16ToString(buf[:n])
		}
		out = append(out, f)
	}
}

// memAt views n bytes of locked global memory. The caller copies before
// unlocking. (Indirection keeps vet's uintptr→Pointer check quiet: the
// address is OS-owned memory, not a Go pointer.)
func memAt(p uintptr, n int) []byte {
	return unsafe.Slice(*(**byte)(unsafe.Pointer(&p)), n)
}

// global copies the bytes of clipboard format id, refusing with
// ErrTooLarge above max before copying. (nil, nil) = not rendered.
func global(id uint32, max int) ([]byte, error) {
	h, _, _ := pGetClipboardData.Call(uintptr(id))
	if h == 0 {
		return nil, nil
	}
	size, _, _ := pGlobalSize.Call(h)
	if size == 0 {
		return nil, nil
	}
	if size > uintptr(max) {
		return nil, fmt.Errorf("%w: %d bytes (format %d)", ErrTooLarge, size, id)
	}
	p, _, _ := pGlobalLock.Call(h)
	if p == 0 {
		return nil, nil
	}
	defer pGlobalUnlock.Call(h)
	return bytes.Clone(memAt(p, int(size))), nil
}

// Text returns CF_UNICODETEXT as UTF-8 (up to the first NUL), or nil when
// the owner has not rendered it. More than max bytes → ErrTooLarge.
func (View) Text(max int) ([]byte, error) {
	// UTF-8 is never shorter than its UTF-16 unit count, so a buffer of
	// more than max units (+NUL) is over the cap whatever it holds.
	raw, err := global(CFUnicodeText, 2*max+2)
	if err != nil || raw == nil {
		return nil, err
	}
	u := make([]uint16, len(raw)/2)
	for i := range u {
		u[i] = uint16(raw[2*i]) | uint16(raw[2*i+1])<<8
	}
	for i, c := range u {
		if c == 0 {
			u = u[:i]
			break
		}
	}
	out := []byte(string(utf16.Decode(u)))
	if len(out) > max {
		return nil, fmt.Errorf("%w: %d bytes", ErrTooLarge, len(out))
	}
	return out, nil
}

// Image returns the copy as PNG: the registered "PNG" format verbatim if
// present, else CF_DIB / CF_DIBV5 converted in memory. (nil, nil) = no
// image rendered yet.
func (View) Image(max int) ([]byte, error) {
	if id := register(PNGName); id != 0 {
		if r, _, _ := pIsClipboardFormatAvailable.Call(uintptr(id)); r != 0 {
			b, err := global(id, max)
			if err != nil || b == nil {
				return nil, err
			}
			if _, err := png.DecodeConfig(bytes.NewReader(b)); err != nil {
				return nil, errors.New("winclip: registered PNG format holds no PNG")
			}
			return b, nil
		}
	}
	for _, id := range []uint32{CFDIB, CFDIBV5} {
		if r, _, _ := pIsClipboardFormatAvailable.Call(uintptr(id)); r == 0 {
			continue
		}
		b, err := global(id, 40+4*MaxPixels+1024)
		if err != nil || b == nil {
			return nil, err
		}
		return DIBToPNG(b, max)
	}
	return nil, nil
}

// setGlobal hands a copy of b to the clipboard as format id.
func setGlobal(id uint32, b []byte) error {
	n := len(b)
	if n == 0 {
		n = 1
	}
	h, _, err := pGlobalAlloc.Call(gmemMoveable, uintptr(n))
	if h == 0 {
		return fmt.Errorf("winclip: GlobalAlloc: %v", err)
	}
	p, _, err := pGlobalLock.Call(h)
	if p == 0 {
		pGlobalFree.Call(h)
		return fmt.Errorf("winclip: GlobalLock: %v", err)
	}
	copy(memAt(p, n), b)
	pGlobalUnlock.Call(h)
	if r, _, err := pSetClipboardData.Call(uintptr(id), h); r == 0 {
		pGlobalFree.Call(h) // ownership passes only on success
		return fmt.Errorf("winclip: SetClipboardData(%d): %v", id, err)
	}
	return nil
}

// Publish replaces the clipboard with text (mime text) or a PNG (written
// as registered "PNG" plus CF_DIB), always tagged
// CanIncludeInClipboardHistory=0 and CanUploadToCloudClipboard=0 so a
// picked remote entry stays out of Win+V history and the cloud.
func Publish(isPNG bool, data []byte) error {
	var dib []byte
	if isPNG {
		var err error
		if dib, err = PNGToDIB(data); err != nil {
			return err
		}
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	// EmptyClipboard with a NULL owner makes SetClipboardData fail, so the
	// publisher owns a throwaway message-only window.
	h, err := newMsgWindow()
	if err != nil {
		return err
	}
	defer pDestroyWindow.Call(h)
	if err := open(h); err != nil {
		return err
	}
	defer pCloseClipboard.Call()
	if r, _, err := pEmptyClipboard.Call(); r == 0 {
		return fmt.Errorf("winclip: EmptyClipboard: %v", err)
	}
	zero := []byte{0, 0, 0, 0} // DWORD 0
	for _, name := range []string{HistoryName, CloudName} {
		if err := setGlobal(register(name), zero); err != nil {
			return err
		}
	}
	if isPNG {
		if err := setGlobal(register(PNGName), data); err != nil {
			return err
		}
		return setGlobal(CFDIB, dib)
	}
	u := utf16.Encode([]rune(string(data)))
	b := make([]byte, 2*len(u)+2)
	for i, c := range u {
		b[2*i], b[2*i+1] = byte(c), byte(c>>8)
	}
	return setGlobal(CFUnicodeText, b)
}
