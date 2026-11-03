package main

// The runner beside hotkeyd.exe on a real Windows file system: kwi3's
// package layout under a private directory (t.TempDir), read with os.Stat.
// Run through hotkeyd/test-win32.sh.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/bind"
)

func TestKwi3RunPath_Windows_RealFS(t *testing.T) {
	pkgDir := filepath.Join(t.TempDir(), "kwi3", "0.3.0")
	if err := os.MkdirAll(pkgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"hotkeyd.exe", "kwi3-run.exe"} {
		if err := os.WriteFile(filepath.Join(pkgDir, n), []byte("MZ"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	var started, logged []string
	s := &kwi3RunStarter{
		start: func(c string) error { started = append(started, c); return nil },
		self:  filepath.Join(pkgDir, "hotkeyd.exe"),
		fs:    runFS{Stat: os.Stat},
		log:   func(l string) { logged = append(logged, l) },
	}
	_ = s.Run("kwi3-run.exe launcher")
	if err := os.Remove(filepath.Join(pkgDir, "kwi3-run.exe")); err != nil {
		t.Fatal(err)
	}
	_ = s.Run("kwi3-run.exe switcher")
	want := []string{
		`"` + filepath.Join(pkgDir, "kwi3-run.exe") + `" launcher`,
		`kwi3-run.exe switcher`,
	}
	if strings.Join(started, "|") != strings.Join(want, "|") || len(logged) != 2 {
		t.Fatalf("started %q logged %q, want %q and two lines", started, logged, want)
	}
}

// asKwi3RunEnv makes this test binary act as a deployed kwi3-run.exe
// (TestMain): it writes kwi3-run-ran.txt into the directory named, then
// exits.
const asKwi3RunEnv = "HOTKEYD_TEST_AS_KWI3RUN"

// The daemon's own Run (startWin32 with no cfg.Run) starts the
// kwi3-run.exe beside this executable - a copy of this test binary written
// next to it - for a posted WM_HOTKEY bound to `kwi3-run.exe launcher`.
// Nothing is on PATH under that name, and a retired current.txt deploy
// under the private %LOCALAPPDATA% is never read.
func TestKwi3Run_Windows_BesideHotkeyd(t *testing.T) {
	// A SHORT private directory: the daemon's sockets live under
	// %LOCALAPPDATA%, and t.TempDir's names overflow sun_path.
	lad, err := os.MkdirTemp("", "hk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(lad) })
	t.Setenv("LOCALAPPDATA", lad)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	img, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(filepath.Dir(self), "kwi3-run.exe")
	if err := os.WriteFile(exe, img, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(exe) })
	// The retired deploy: a second copy current.txt names. Started, it
	// would report ITS path, not exe's.
	v1 := filepath.Join(lad, "kwi3", "run", "v1")
	if err := os.MkdirAll(v1, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(v1, "kwi3-run.exe"), img, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(lad, "kwi3", "run", "current.txt"), []byte(v1+"\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	marker := t.TempDir()
	t.Setenv(asKwi3RunEnv, marker)

	modes := newModeServer(t, false)
	binds := []bind.Bind{{Chord: "$mod+1", Actions: runAction("kwi3-run.exe launcher")}}
	_, src, sig, done := startDryRunDaemonWith(t, modes.addr, true, binds, map[string]bind.Layer{})
	postAltDigit(t, src, '1')
	var got string
	waitForWithin(t, "the kwi3-run.exe beside hotkeyd runs", freshImageWait, func() bool {
		b, err := os.ReadFile(filepath.Join(marker, "kwi3-run-ran.txt"))
		got = string(b)
		return err == nil && strings.Contains(got, "\n")
	})
	if want := exe + "\nlauncher"; !strings.EqualFold(got, want) {
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
