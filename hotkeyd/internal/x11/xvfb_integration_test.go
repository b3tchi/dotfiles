package x11

import (
	crand "crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// requireBinary skips the test if name is not on PATH.
func requireBinary(t *testing.T, name string) {
	t.Helper()
	if _, err := exec.LookPath(name); err != nil {
		t.Skipf("%s not available on PATH: %v", name, err)
	}
}

// pickFreeDisplay finds a display number with no existing Unix socket.
func pickFreeDisplay(t *testing.T) int {
	t.Helper()
	for attempt := 0; attempt < 50; attempt++ {
		n := 200 + rand.IntN(2000)
		if _, err := os.Stat(SocketPath(n)); err != nil {
			return n
		}
	}
	t.Fatal("could not find a free display number")
	return 0
}

// startXvfb launches Xvfb on the given display number with the given
// extra arguments (e.g. "-auth", path) and waits for its socket to
// appear.
func startXvfb(t *testing.T, dispNum int, extraArgs ...string) (cleanup func()) {
	t.Helper()
	requireBinary(t, "Xvfb")

	sockPath := SocketPath(dispNum)
	args := append([]string{fmt.Sprintf(":%d", dispNum), "-nolisten", "tcp", "-screen", "0", "320x240x24"}, extraArgs...)
	cmd := exec.Command("Xvfb", args...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting Xvfb: %v", err)
	}

	if !waitForSocket(sockPath, 5*time.Second) {
		cmd.Process.Kill()
		cmd.Wait()
		t.Fatalf("Xvfb did not create its socket in time: %s", stderr.String())
	}

	return func() {
		cmd.Process.Kill()
		cmd.Wait()
		os.Remove(sockPath)
	}
}

func waitForSocket(path string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

// makeXauthCookie writes a fresh Xauthority file at a temp path containing
// a MIT-MAGIC-COOKIE-1 entry for the given display number, using the real
// `xauth` binary (mirrors poc015's rig discipline: Xvfb -auth requires the
// cookie path to be genuinely exercised, gotcha 3). `xauth add` writes to
// the file directly and needs no running server, so this can run before
// Xvfb starts.
func makeXauthCookie(t *testing.T, dispNum int) (path string) {
	t.Helper()
	requireBinary(t, "xauth")

	dir := t.TempDir()
	path = filepath.Join(dir, "Xauthority")

	cookie := make([]byte, 16)
	if _, err := crand.Read(cookie); err != nil {
		t.Fatalf("generating cookie: %v", err)
	}
	hexCookie := hex.EncodeToString(cookie)

	cmd := exec.Command("xauth", "-f", path, "add", fmt.Sprintf(":%d", dispNum), "MIT-MAGIC-COOKIE-1", hexCookie)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("xauth add: %v: %s", err, out)
	}
	return path
}

// withXauthority temporarily sets $XAUTHORITY for the duration of the
// test.
func withXauthority(t *testing.T, path string) {
	t.Helper()
	old, had := os.LookupEnv("XAUTHORITY")
	os.Setenv("XAUTHORITY", path)
	t.Cleanup(func() {
		if had {
			os.Setenv("XAUTHORITY", old)
		} else {
			os.Unsetenv("XAUTHORITY")
		}
	})
}

func TestOpen_Xvfb_Bare(t *testing.T) {
	dispNum := pickFreeDisplay(t)
	cleanup := startXvfb(t, dispNum)
	defer cleanup()

	// Bare Xvfb accepts unauthenticated connections (poc015 gotcha 3) --
	// this is the "success without a cookie" half of the rig.
	withXauthority(t, filepath.Join(t.TempDir(), "nonexistent-Xauthority"))

	conn, info, err := Open(fmt.Sprintf(":%d", dispNum))
	if err != nil {
		t.Fatalf("Open bare Xvfb :%d: unexpected error: %v", dispNum, err)
	}
	defer conn.Close()

	if len(info.Screens) == 0 {
		t.Fatal("setup response has no screens")
	}
	if info.Vendor == "" {
		t.Error("setup response has an empty vendor string")
	}
	t.Logf("connected: vendor=%q screens=%d", info.Vendor, len(info.Screens))
}

func TestOpen_Xvfb_WithAuth_CorrectCookieSucceeds(t *testing.T) {
	dispNum := pickFreeDisplay(t)
	authPath := makeXauthCookie(t, dispNum)
	cleanup := startXvfb(t, dispNum, "-auth", authPath)
	defer cleanup()

	withXauthority(t, authPath)

	conn, info, err := Open(fmt.Sprintf(":%d", dispNum))
	if err != nil {
		t.Fatalf("Open authenticated Xvfb :%d with correct cookie: unexpected error: %v", dispNum, err)
	}
	defer conn.Close()
	if len(info.Screens) == 0 {
		t.Fatal("setup response has no screens")
	}
}

func TestOpen_Xvfb_WithAuth_WithheldCookieFails(t *testing.T) {
	dispNum := pickFreeDisplay(t)
	authPath := makeXauthCookie(t, dispNum)
	cleanup := startXvfb(t, dispNum, "-auth", authPath)
	defer cleanup()

	// Deliberately withhold the cookie: point XAUTHORITY at an empty file
	// instead of the real one.
	emptyAuth := filepath.Join(t.TempDir(), "empty-Xauthority")
	if err := os.WriteFile(emptyAuth, nil, 0600); err != nil {
		t.Fatalf("writing empty Xauthority: %v", err)
	}
	withXauthority(t, emptyAuth)

	_, _, err := Open(fmt.Sprintf(":%d", dispNum))
	if err == nil {
		t.Fatal("Open with a withheld cookie against an authenticated Xvfb succeeded, want a Failed setup error")
	}
	var setupFailed *ErrSetupFailed
	if !errors.As(err, &setupFailed) {
		t.Fatalf("error is %T, want *ErrSetupFailed: %v", err, err)
	}
	t.Logf("server refused as expected: %v", setupFailed)
}
