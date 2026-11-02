//go:build windows

package main

// kwi3-wv1u on a real Windows file system: the daemon's own Run (startWin32
// with no cfg.Run) starts scoop's WezTerm under a PRIVATE %USERPROFILE% -
// a copy of this test binary as
// <USERPROFILE>\scoop\apps\wezterm\current\wezterm-gui.exe - for a posted
// WM_HOTKEY bound to `wezterm-gui.exe start`. Nothing named
// wezterm-gui.exe needs to be on PATH, and the Windows Terminal fallback
// is never reached (it would open a real window; termpath_test.go covers
// it): PATH holds only System32 here. Run through hotkeyd/test-win32.sh.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/bind"
)

func TestTermStarter_Windows_ScoopWezTerm(t *testing.T) {
	home, err := os.MkdirTemp("", "hk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(home) })
	t.Setenv("USERPROFILE", home)
	t.Setenv("SCOOP", "")
	// No scoop shim and no wt.exe on PATH: a resolver that missed the
	// private copy could otherwise start Jan's real WezTerm or Windows
	// Terminal; this way it starts nothing and the test fails.
	t.Setenv("PATH", filepath.Join(os.Getenv("SystemRoot"), "System32"))
	// The daemon's sockets live under %LOCALAPPDATA%: keep it short too.
	t.Setenv("LOCALAPPDATA", home)
	cur := filepath.Join(home, "scoop", "apps", "wezterm", "current")
	if err := os.MkdirAll(cur, 0o755); err != nil {
		t.Fatal(err)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	img, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(cur, "wezterm-gui.exe")
	if err := os.WriteFile(exe, img, 0o755); err != nil {
		t.Fatal(err)
	}
	marker := t.TempDir()
	// The copy says which image ran with which arguments (TestMain).
	t.Setenv(asKwi3RunEnv, marker)

	modes := newModeServer(t, false)
	binds := []bind.Bind{{Chord: "$mod+1", Actions: runAction(wezGuiExe + " start")}}
	_, src, sig, done := startDryRunDaemonWith(t, modes.addr, true, binds, map[string]bind.Layer{})
	postAltDigit(t, src, '1')
	var got string
	waitForWithin(t, "scoop's wezterm-gui.exe runs", freshImageWait, func() bool {
		b, err := os.ReadFile(filepath.Join(marker, "kwi3-run-ran.txt"))
		got = string(b)
		return err == nil && strings.Contains(got, "\n")
	})
	if want := exe + "\nstart"; !strings.EqualFold(got, want) {
		t.Errorf("ran %q, want %q", got, want)
	}
	sig <- os.Interrupt
	select {
	case code := <-done:
		done <- code
	case <-time.After(5 * time.Second):
		t.Fatal("daemon did not stop")
	}
}
