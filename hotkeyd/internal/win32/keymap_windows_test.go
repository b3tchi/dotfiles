package win32

// sp012 Task 3's cross-check: Windows' own answer for the US layout
// (00000409) against the pure table. Run on Windows through
// hotkeyd/test-win32.sh. It only READS layouts the session already has
// loaded (GetKeyboardLayoutList); it never loads, activates or changes one.

import (
	"syscall"
	"testing"
	"unsafe"
)

var (
	user32                    = syscall.NewLazyDLL("user32.dll")
	procGetKeyboardLayoutList = user32.NewProc("GetKeyboardLayoutList")
	procVkKeyScanExW          = user32.NewProc("VkKeyScanExW")
	procMapVirtualKeyExW      = user32.NewProc("MapVirtualKeyExW")
)

// usHKL is the plain US layout's HKL, 0x04090409 (language 0409, layout
// 0409), when the session has it loaded.
func usHKL(t *testing.T) uintptr {
	t.Helper()
	n, _, _ := procGetKeyboardLayoutList.Call(0, 0)
	if n == 0 {
		t.Fatalf("GetKeyboardLayoutList: no layouts")
	}
	list := make([]uintptr, n)
	got, _, _ := procGetKeyboardLayoutList.Call(n, uintptr(unsafe.Pointer(&list[0])))
	for _, h := range list[:got] {
		t.Logf("loaded layout %#x", h)
	}
	for _, h := range list[:got] {
		if h&0xffffffff == 0x04090409 {
			return h
		}
	}
	t.Skipf("UNVERIFIED: the US layout 00000409 (HKL 0x04090409) is not loaded in this session; not loading one")
	return 0
}

func TestWindows_ToVKAgreesWithVkKeyScanEx(t *testing.T) {
	hkl := usHKL(t)
	for ch := uint32(0x20); ch <= 0x7e; ch++ {
		r, _, _ := procVkKeyScanExW.Call(uintptr(ch), hkl)
		res := uint16(r)
		if res == 0xffff {
			t.Errorf("VkKeyScanExW(%q) = -1 on the US layout", rune(ch))
			continue
		}
		vk, state := res&0xff, res>>8
		if state&^1 != 0 {
			t.Errorf("VkKeyScanExW(%q) needs shift state %#x beyond Shift", rune(ch), state)
		}
		key, ok := ToVK(ch)
		if !ok || key.VK != vk || key.Shift != (state&1 != 0) {
			t.Errorf("ToVK(%q 0x%x) = %+v, %v; Windows says VK 0x%02x shift=%v",
				rune(ch), ch, key, ok, vk, state&1 != 0)
		}
	}
}

// The reverse: for every VK whose unshifted keysym is printable ASCII,
// MapVirtualKeyEx(MAPVK_VK_TO_CHAR) gives the same character (letters in
// upper case, as it reports them).
func TestWindows_ToKeysymAgreesWithMapVirtualKeyEx(t *testing.T) {
	hkl := usHKL(t)
	const mapvkVKToChar = 2
	n := 0
	for vk := uint16(0); vk <= 0xff; vk++ {
		ks, ok := ToKeysym(vk)
		if !ok || ks < 0x20 || ks > 0x7e {
			continue
		}
		n++
		r, _, _ := procMapVirtualKeyExW.Call(uintptr(vk), mapvkVKToChar, hkl)
		ch := uint32(r) & 0x7fffffff
		want := ks
		if want >= 'a' && want <= 'z' {
			want -= 'a' - 'A'
		}
		if ch != want {
			t.Errorf("VK 0x%02x: ToKeysym %q, MapVirtualKeyExW %q", vk, rune(ks), rune(ch))
		}
	}
	if n < 47 {
		t.Fatalf("checked only %d VKs", n)
	}
}
