package kwin

import (
	"path/filepath"
	"testing"
)

// Two KWins of one user (krdp-kwin, kwi3-phone) must get two grab servers:
// a shared name let the second KWin's plugin unlink the first one's socket
// and take its hotkeyd.
func TestSocketPath_OnePerWaylandSocket(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	t.Setenv("WAYLAND_DISPLAY", "krdp-kwin")
	rdp := SocketPath()
	t.Setenv("WAYLAND_DISPLAY", "kwi3-phone")
	phone := SocketPath()

	if want := filepath.Join(dir, "kwi3keys-krdp-kwin.sock"); rdp != want {
		t.Fatalf("SocketPath() under krdp-kwin = %q, want %q", rdp, want)
	}
	if want := filepath.Join(dir, "kwi3keys-kwi3-phone.sock"); phone != want {
		t.Fatalf("SocketPath() under kwi3-phone = %q, want %q", phone, want)
	}
}

// The plugin names the file after the socket's file name, so an absolute
// $WAYLAND_DISPLAY must land on the same file, and an unset one on Wayland's
// default socket.
func TestSocketName_AbsoluteAndEmptyDisplay(t *testing.T) {
	if got := SocketName("/run/user/1000/krdp-kwin"); got != "kwi3keys-krdp-kwin.sock" {
		t.Fatalf("SocketName(absolute) = %q", got)
	}
	if got := SocketName(""); got != "kwi3keys-wayland-0.sock" {
		t.Fatalf("SocketName(\"\") = %q", got)
	}
}
