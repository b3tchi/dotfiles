package main

import (
	"bytes"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"hotkeyd/internal/layer"
	"hotkeyd/internal/proc"
)

// On Windows the control socket is AF_UNIX at %LOCALAPPDATA%\hotkeyd\
// <desktop>.sock, and `hotkeyd set-layer` reaches a running daemon's run
// loop through it: the real listener (buildControl, as startup builds it),
// the real Run loop, the real CLI verb.
func TestControl_Windows_SetLayerReachesRunningDaemon(t *testing.T) {
	// Not t.TempDir(): its name carries the test's, and an AF_UNIX path
	// must stay under 108 bytes.
	base, err := os.MkdirTemp("", "hk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	t.Setenv("LOCALAPPDATA", base)
	const desk = "kwi3t-ctl"

	// Startup order: the lock first (it makes the runtime dir), then the
	// control socket.
	lock, err := proc.AcquireLock(proc.LockPath(desk))
	if err != nil {
		t.Fatalf("AcquireLock: %v", err)
	}
	defer lock.Release()
	logger := &fakeLogger{}
	ctl := buildControl(desk, logger.log)
	if ctl == nil {
		t.Fatalf("buildControl returned nil; log: %v", logger.all())
	}
	defer ctl.Close()
	want := filepath.Join(base, "hotkeyd", desk+".sock")
	if ctl.Path() != want {
		t.Fatalf("control socket at %q, want %q", ctl.Path(), want)
	}
	if fi, err := os.Lstat(want); err != nil || fi.Mode()&os.ModeSocket == 0 && fi.Mode()&os.ModeIrregular == 0 {
		t.Fatalf("no AF_UNIX socket at %s (%v, %v)", want, fi, err)
	}

	h := newHarness(t)
	go func() {
		for cmd := range ctl.Commands() {
			h.control <- cmd
		}
	}()
	sig := make(chan os.Signal, 1)
	done := make(chan int, 1)
	go func() { done <- h.dae.Run(sig) }()

	var out, errOut bytes.Buffer
	if code := setLayer(testLayers(), "drag", desk, setLayerTimeout, &out, &errOut); code != SetLayerOK {
		t.Fatalf("set-layer drag = %d: %s", code, errOut.String())
	}
	if got := h.engine.State().Layer; got != "drag" {
		t.Fatalf("engine layer = %q after set-layer drag, want drag", got)
	}
	if code := runSetLayerCmd([]string{"default", "--display", desk}); code != SetLayerOK {
		t.Fatalf("hotkeyd set-layer default --display %s = %d", desk, code)
	}
	if got := h.engine.State().Layer; got != layer.DefaultLayer {
		t.Fatalf("engine layer = %q after set-layer default, want %q", got, layer.DefaultLayer)
	}

	sig <- syscall.SIGTERM
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return")
	}
}
