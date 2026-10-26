package proc

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Windows has no $XDG_RUNTIME_DIR and no X display. The daemon's runtime
// files live under %LOCALAPPDATA%\hotkeyd\, keyed on the DESKTOP the
// daemon serves (the `display` argument every path helper takes is that
// desktop's name on this build), so two desktops never share a lock, a
// grab report or a control socket.

// Log reports the few things this package says on its own on Windows: a
// stale lock taken over, a job that forbids breakaway. The daemon's log is
// stderr with the "hotkeyd: " prefix (daemonLog); a caller may replace it.
var Log = func(msg string) { fmt.Fprintln(os.Stderr, "hotkeyd: "+msg) }

// RuntimeDir is %LOCALAPPDATA%\hotkeyd. With %LOCALAPPDATA% unset (never on
// a real session) it falls back to the user cache dir, then the temp dir,
// so a path is always returned and the error surfaces at the open.
func RuntimeDir() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		if d, err := os.UserCacheDir(); err == nil {
			base = d
		} else {
			base = os.TempDir()
		}
	}
	return filepath.Join(base, "hotkeyd")
}

// DesktopTag turns a desktop name into the file-name part every runtime
// path shares: ":"-prefixed X-style names lose the colon and screen suffix
// (NormalizeDisplay, so ":0" still reads "0"), and anything outside
// [A-Za-z0-9_-] becomes "_" - the same alphabet the kwi3 host sanitises
// its pipe name to. An empty name is "Default".
func DesktopTag(desktop string) string {
	if strings.HasPrefix(desktop, ":") {
		desktop = NormalizeDisplay(desktop)
	}
	if desktop == "" {
		return "Default"
	}
	var b strings.Builder
	for _, r := range desktop {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}

// LockPath is %LOCALAPPDATA%\hotkeyd\<desktop>.lock.
func LockPath(desktop string) string {
	return filepath.Join(RuntimeDir(), DesktopTag(desktop)+".lock")
}

// GrabReportPath is %LOCALAPPDATA%\hotkeyd\<desktop>.grabs.
func GrabReportPath(desktop string) string {
	return filepath.Join(RuntimeDir(), DesktopTag(desktop)+".grabs")
}

// ControlPath is the AF_UNIX control socket, %LOCALAPPDATA%\hotkeyd\
// <desktop>.sock (Windows 10 1803+ has AF_UNIX; Go's net package dials and
// listens on it unchanged, so control.go and setlayer.go need nothing of
// their own here).
func ControlPath(desktop string) string {
	return filepath.Join(RuntimeDir(), DesktopTag(desktop)+".sock")
}

// HomeDir is %USERPROFILE%: what "~" means in a Run command, and the
// working directory every started program gets.
func HomeDir() string {
	if h := os.Getenv("USERPROFILE"); h != "" {
		return h
	}
	h, _ := os.UserHomeDir()
	return h
}

// ExpandHome replaces a leading "~" ("~", "~/x", `~\x`) with HomeDir and
// turns the rest of such a word's "/" into `\`. Any other word is
// returned unchanged.
func ExpandHome(word string) string {
	if word == "~" {
		return HomeDir()
	}
	if strings.HasPrefix(word, "~/") || strings.HasPrefix(word, `~\`) {
		return filepath.Join(HomeDir(), filepath.FromSlash(strings.ReplaceAll(word[2:], `\`, "/")))
	}
	return word
}
