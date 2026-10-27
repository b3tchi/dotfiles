package main

// kwi3-hoex.27 on a real Windows file system: deploy.sh's layout under a
// private directory (t.TempDir, never the real %LOCALAPPDATA%), read with
// os.ReadFile/os.Stat. Run through hotkeyd/test-win32.sh.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"hotkeyd/internal/bind"
)

func TestKwi3RunPath_Windows_RealFS(t *testing.T) {
	lad := t.TempDir()
	run := filepath.Join(lad, "kwi3", "run")
	for _, v := range []string{"v1", "v2"} {
		if err := os.MkdirAll(filepath.Join(run, v), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(run, v, "kwi3-run.exe"), []byte("MZ"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cur := filepath.Join(run, "current.txt")
	rfs := runFS{ReadFile: os.ReadFile, Stat: os.Stat}

	if p, why := resolveKwi3Run(lad, rfs); p != "" || !strings.Contains(why, cur) {
		t.Fatalf("no current.txt: %q %q", p, why)
	}
	// What deploy.sh writes: the absolute directory and CRLF.
	if err := os.WriteFile(cur, []byte(filepath.Join(run, "v1")+"\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var started, logged []string
	s := &kwi3RunStarter{
		start:  func(c string) error { started = append(started, c); return nil },
		getenv: func(k string) string { return map[string]string{"LOCALAPPDATA": lad}[k] },
		fs:     rfs,
		log:    func(l string) { logged = append(logged, l) },
	}
	_ = s.Run("kwi3-run.exe launcher")
	if err := os.WriteFile(cur, []byte(filepath.Join(run, "v2")+"\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_ = s.Run("kwi3-run.exe switcher")
	want := []string{
		`"` + filepath.Join(run, "v1", "kwi3-run.exe") + `" launcher`,
		`"` + filepath.Join(run, "v2", "kwi3-run.exe") + `" switcher`,
	}
	if strings.Join(started, "|") != strings.Join(want, "|") || len(logged) != 2 {
		t.Fatalf("started %q logged %q, want %q and two lines", started, logged, want)
	}
	if err := os.Remove(filepath.Join(run, "v2", "kwi3-run.exe")); err != nil {
		t.Fatal(err)
	}
	if p, why := resolveKwi3Run(lad, rfs); p != "" || !strings.Contains(why, "no "+filepath.Join(run, "v2", "kwi3-run.exe")) {
		t.Fatalf("exe removed: %q %q", p, why)
	}
}

// asKwi3RunEnv makes this test binary act as a deployed kwi3-run.exe
// (TestMain): it writes kwi3-run-ran.txt into the directory named, then
// exits.
const asKwi3RunEnv = "HOTKEYD_TEST_AS_KWI3RUN"

// The daemon's own Run (startWin32 with no cfg.Run) starts the copy
// current.txt names - a copy of this test binary under a private
// %LOCALAPPDATA% - for a posted WM_HOTKEY bound to `kwi3-run.exe launcher`.
// Nothing is on PATH under that name.
func TestKwi3Run_Windows_Deployed(t *testing.T) {
	// A SHORT private directory: the daemon's sockets live under
	// %LOCALAPPDATA%, and t.TempDir's names overflow sun_path.
	lad, err := os.MkdirTemp("", "hk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(lad) })
	t.Setenv("LOCALAPPDATA", lad)
	v1 := filepath.Join(lad, "kwi3", "run", "v1")
	if err := os.MkdirAll(v1, 0o755); err != nil {
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
	exe := filepath.Join(v1, "kwi3-run.exe")
	if err := os.WriteFile(exe, img, 0o755); err != nil {
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
	waitForLong(t, "the deployed kwi3-run.exe runs", func() bool {
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
