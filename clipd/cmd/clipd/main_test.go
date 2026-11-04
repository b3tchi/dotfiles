package main

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"time"

	"filippo.io/age"

	"clipd/internal/entry"
	"clipd/internal/store"
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

// winRig: identity in a config dir, a folder, a state dir, and one entry
// written as a peer device into the shared folder.
func winRig(t *testing.T) (cfg, id string) {
	t.Helper()
	cfg = t.TempDir()
	folder, state := t.TempDir(), t.TempDir()
	t.Setenv("CLIPD_FOLDER", folder)
	t.Setenv("CLIPD_STATE_DIR", state)
	if code, _, _ := runCLI(t, cfg, "keygen"); code != 0 {
		t.Fatal("keygen")
	}
	self, err := loadIdentity()
	if err != nil {
		t.Fatal(err)
	}
	peer := &store.Store{Dir: folder, Origin: "peer", Self: self, Cap: entry.DefaultCap}
	id, err = peer.Write(entry.Entry{Created: time.Now().UnixMilli(), TTLs: 300, Mime: entry.MimeText, Data: []byte("hi\tthere")})
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLIPD_DEVICE", "self")
	return cfg, id
}

func TestListCLI(t *testing.T) {
	cfg, id := winRig(t)
	code, out, _ := runCLI(t, cfg, "list")
	if code != 0 || !strings.HasPrefix(out, id+"\tpeer\t") || !strings.HasSuffix(out, "\thi\\tthere\n") {
		t.Fatalf("list: exit %d out %q", code, out)
	}
	t.Setenv("CLIPD_DEVICE", "peer") // own entries are not listed
	if code, out, _ := runCLI(t, cfg, "list"); code != 0 || out != "" {
		t.Fatalf("own list: exit %d out %q", code, out)
	}
	if code, _, _ := runCLI(t, cfg, "list", "x"); code != exitUsage {
		t.Fatalf("list x: exit %d", code)
	}
}

func TestPickCLIExitCodes(t *testing.T) {
	cfg, id := winRig(t)
	if code, _, _ := runCLI(t, cfg, "pick", "ffffffffffffffff"); code != exitFail {
		t.Fatalf("unknown id: exit %d", code)
	}
	if code, _, _ := runCLI(t, cfg, "pick", "../etc"); code != exitUsage {
		t.Fatalf("malformed id: exit %d", code)
	}
	if runtime.GOOS != "windows" { // no native publisher here → 2, payload not echoed
		code, out, errOut := runCLI(t, cfg, "pick", id)
		if code != 2 || out != "" || strings.Contains(errOut, "there") {
			t.Fatalf("pick: exit %d out %q err %q", code, out, errOut)
		}
		if code, _, _ := runCLI(t, cfg, "agent", "windows"); code != exitFail {
			t.Fatalf("agent windows on %s: exit %d", runtime.GOOS, code)
		}
	}
	t.Setenv("CLIPD_CONFIG_DIR", t.TempDir()) // no identity
	if code, _, _ := runCLI(t, filepath.Join(t.TempDir(), "none"), "list"); code != exitConfig {
		t.Fatalf("no identity: exit %d", code)
	}
}
