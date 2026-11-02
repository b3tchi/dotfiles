package x11

import (
	crand "crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"hotkeyd/internal/xvfbtest"
)

// requireBinary skips the test if name is not on PATH.
func requireBinary(t *testing.T, name string) {
	t.Helper()
	if _, err := exec.LookPath(name); err != nil {
		t.Skipf("%s not available on PATH: %v", name, err)
	}
}

// makeXauthCookie writes a fresh Xauthority file at a temp path containing
// a MIT-MAGIC-COOKIE-1 entry for the given display number, using the real
// `xauth` binary (mirrors poc015's rig discipline: Xvfb -auth requires the
// cookie path to be genuinely exercised, gotcha 3). `xauth add` writes to
// the file directly and needs no running server, so this runs before
// Xvfb starts, once per display number xvfbtest.StartWith tries.
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
	dispNum := xvfbtest.Start(t).Num

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
	var authPath string
	dispNum := xvfbtest.StartWith(t, func(n int) []string {
		authPath = makeXauthCookie(t, n)
		return []string{"-auth", authPath}
	}).Num

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
	var authPath string
	dispNum := xvfbtest.StartWith(t, func(n int) []string {
		authPath = makeXauthCookie(t, n)
		return []string{"-auth", authPath}
	}).Num

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
