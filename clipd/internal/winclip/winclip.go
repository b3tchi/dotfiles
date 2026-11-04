// Package winclip is clipd's Win32 clipboard driver (sp039 Task 7,
// [[poc024]]): a message-only window registered with
// AddClipboardFormatListener, bounded OpenClipboard, format enumeration,
// CF_UNICODETEXT / PNG / CF_DIB reads, and the pick publisher that tags
// every write with CanIncludeInClipboardHistory=0 and
// CanUploadToCloudClipboard=0.
//
// Win32 goes through stdlib syscall only (adr0039: no x/sys/windows import).
// The Win32 half lives in winclip_windows.go; winclip_other.go stubs it so
// the OS-neutral parts (this file, dib.go) build and test anywhere.
//
// Errors never carry clipboard bytes — callers log them.
package winclip

import (
	"errors"
	"time"
)

// Predefined clipboard format ids (winuser.h).
const (
	CFUnicodeText = 13
	CFDIB         = 8
	CFDIBV5       = 17
)

// Registered clipboard format names.
const (
	// ExcludeName marks a copy that clipboard monitors must not read
	// (KeePass, password managers). Checked before any payload read.
	ExcludeName = "ExcludeClipboardContentFromMonitorProcessing"
	// HistoryName / CloudName, set to DWORD 0 on every pick, keep a picked
	// remote entry out of Win+V history and the cloud clipboard.
	HistoryName = "CanIncludeInClipboardHistory"
	CloudName   = "CanUploadToCloudClipboard"
	// PNGName is the de-facto registered PNG format (browsers, Office).
	PNGName = "PNG"
)

// OpenTries × OpenWait bound every OpenClipboard (sp039 Task 7 edge case:
// contention → 20 × 25 ms, then skip).
const (
	OpenTries = 20
	OpenWait  = 25 * time.Millisecond
)

var (
	// ErrBusy: another process held the clipboard for all OpenTries.
	ErrBusy = errors.New("winclip: clipboard busy")
	// ErrTooLarge: the payload is over the caller's cap; nothing returned.
	ErrTooLarge = errors.New("winclip: payload over size cap")
	// ErrUnsupported: not on Windows (winclip_other.go).
	ErrUnsupported = errors.New("winclip: Win32 clipboard needs windows")
)

// Format is one clipboard format: its id and, for registered formats, the
// registered name (predefined formats get their CF_* name).
type Format struct {
	ID   uint32
	Name string
}

var predefined = map[uint32]string{
	1: "CF_TEXT", 2: "CF_BITMAP", 3: "CF_METAFILEPICT", 4: "CF_SYLK",
	5: "CF_DIF", 6: "CF_TIFF", 7: "CF_OEMTEXT", 8: "CF_DIB", 9: "CF_PALETTE",
	10: "CF_PENDATA", 11: "CF_RIFF", 12: "CF_WAVE", 13: "CF_UNICODETEXT",
	14: "CF_ENHMETAFILE", 15: "CF_HDROP", 16: "CF_LOCALE", 17: "CF_DIBV5",
}

// PredefinedName names a predefined format id ("" if unknown).
func PredefinedName(id uint32) string { return predefined[id] }
