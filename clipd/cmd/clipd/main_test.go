package main

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"filippo.io/age"
)

func runCLI(t *testing.T, cfg string, args ...string) (int, string, string) {
	t.Helper()
	t.Setenv("CLIPD_CONFIG_DIR", cfg)
	var out, errOut bytes.Buffer
	code := run(args, &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestKeygenCLI(t *testing.T) {
	cfg := t.TempDir()
	code, out, _ := runCLI(t, cfg, "keygen")
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	rcpt := strings.TrimSpace(out)
	if _, err := age.ParseX25519Recipient(rcpt); err != nil {
		t.Fatalf("stdout %q is not a recipient", out)
	}
	if strings.Contains(out, "AGE-SECRET-KEY") {
		t.Fatal("secret key printed")
	}
	code, out, errOut := runCLI(t, cfg, "keygen")
	if code != 1 || out != "" || !strings.Contains(errOut, "already exists") {
		t.Fatalf("second keygen: exit %d out %q err %q", code, out, errOut)
	}
}

func TestRecipientsCLI(t *testing.T) {
	cfg := t.TempDir()
	id, _ := age.GenerateX25519Identity()
	peer := id.Recipient().String()

	if code, _, errOut := runCLI(t, cfg, "recipients", "add", "garbage"); code != 1 || !strings.Contains(errOut, "not an age X25519 recipient") {
		t.Fatalf("garbage: exit %d err %q", code, errOut)
	}
	if code, _, _ := runCLI(t, cfg, "recipients", "add", peer); code != 0 {
		t.Fatalf("add exit %d", code)
	}
	if code, out, _ := runCLI(t, cfg, "recipients", "list"); code != 0 || strings.TrimSpace(out) != peer {
		t.Fatalf("list: exit %d out %q", code, out)
	}
	if code, _, _ := runCLI(t, cfg, "recipients", "rm", peer); code != 0 {
		t.Fatalf("rm exit %d", code)
	}
	if code, _, errOut := runCLI(t, cfg, "recipients", "rm", peer); code != 1 || !strings.Contains(errOut, "not pinned") {
		t.Fatalf("rm absent: exit %d err %q", code, errOut)
	}
	if _, err := os.Stat(filepath.Join(cfg, "recipients.txt")); err != nil {
		t.Fatal(err)
	}
}

func TestIdentityPermsExit78(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX mode bits do not apply")
	}
	cfg := t.TempDir()
	if code, _, _ := runCLI(t, cfg, "keygen"); code != 0 {
		t.Fatal("keygen")
	}
	os.Chmod(filepath.Join(cfg, "identity.txt"), 0o644)
	// No Task 2 verb loads the identity yet (agent/list/pick do, Tasks
	// 4-6); they all go through loadIdentity + exitFor, tested here.
	_, err := loadIdentity()
	if code := exitFor(err); code != exitConfig || !strings.Contains(err.Error(), "readable by group or others") {
		t.Fatalf("exit %d err %v", code, err)
	}
}

func TestUsageExit2(t *testing.T) {
	for _, args := range [][]string{nil, {"bogus"}, {"recipients"}, {"recipients", "add"}, {"recipients", "frob", "x"}} {
		if code, _, _ := runCLI(t, t.TempDir(), args...); code != 2 {
			t.Fatalf("%v: exit %d, want 2", args, code)
		}
	}
}
