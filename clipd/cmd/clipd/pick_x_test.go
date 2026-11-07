package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"clipd/internal/entry"
	"clipd/internal/store"
)

// stubXclip installs a fake xclip that stores each selection in a file and
// serves it back, logging its DISPLAY and arguments. No X server needed.
func stubXclip(t *testing.T, fail bool) (dir string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("X only")
	}
	dir = t.TempDir()
	body := `#!/bin/sh
echo "DISPLAY=$DISPLAY $*" >>"` + dir + `/log"
sel=; prev=
for a in "$@"; do [ "$prev" = -selection ] && sel=$a; prev=$a; done
case " $* " in
  *" -i "*) ` + map[bool]string{true: "exit 1", false: `cat >"` + dir + `/sel.$sel"`}[fail] + ` ;;
  *) cat "` + dir + `/sel.$sel" 2>/dev/null ;;
esac
`
	p := filepath.Join(dir, "xclip")
	if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLIPD_XCLIP", p)
	t.Setenv("DISPLAY", ":77") // inherited: must never be used
	t.Setenv("CLIPD_DISPLAY", "")
	return dir
}

func xclipCalls(dir string) string {
	b, _ := os.ReadFile(filepath.Join(dir, "log"))
	return string(b)
}

func pickedState() bool {
	_, err := os.Stat(filepath.Join(os.Getenv("CLIPD_STATE_DIR"), "last-picked"))
	return err == nil
}

func TestPickPublishesToNamedDisplay(t *testing.T) {
	cfg, id := winRig(t)
	x := stubXclip(t, false)
	code, out, errOut := runCLI(t, cfg, "pick", id, ":93")
	if code != 0 || out != "" || errOut != "" {
		t.Fatalf("pick: exit %d out %q err %q", code, out, errOut)
	}
	for _, sel := range []string{"clipboard", "primary"} {
		b, err := os.ReadFile(filepath.Join(x, "sel."+sel))
		if err != nil || string(b) != "hi\tthere" {
			t.Fatalf("%s holds %q (%v)", sel, b, err)
		}
	}
	calls := xclipCalls(x)
	if strings.Contains(calls, "DISPLAY=:77") || !strings.Contains(calls, "DISPLAY=:93 -display :93") {
		t.Fatalf("wrong display:\n%s", calls)
	}
	if !strings.Contains(calls, "-t UTF8_STRING -i") {
		t.Fatalf("text must be published as UTF8_STRING:\n%s", calls)
	}
	if !pickedState() {
		t.Fatal("echo guard not recorded")
	}
}

func TestPickPNGUsesImageTarget(t *testing.T) {
	cfg, _ := winRig(t)
	x := stubXclip(t, false)
	self, err := loadIdentity()
	if err != nil {
		t.Fatal(err)
	}
	peer := &store.Store{Dir: os.Getenv("CLIPD_FOLDER"), Origin: "peer", Self: self, Cap: entry.DefaultCap}
	png := []byte("\x89PNG\r\n\x1a\n\x00bytes")
	id, err := peer.Write(entry.Entry{Created: time.Now().UnixMilli(), TTLs: 300, Mime: entry.MimePNG, Data: png})
	if err != nil {
		t.Fatal(err)
	}
	if code, _, errOut := runCLI(t, cfg, "pick", id, ":93"); code != 0 {
		t.Fatalf("pick: exit %d err %q", code, errOut)
	}
	if !strings.Contains(xclipCalls(x), "-t image/png -i") {
		t.Fatalf("calls:\n%s", xclipCalls(x))
	}
	if b, _ := os.ReadFile(filepath.Join(x, "sel.clipboard")); string(b) != string(png) {
		t.Fatalf("clipboard %q", b)
	}
}

func TestPickDisplayFromEnv(t *testing.T) {
	cfg, id := winRig(t)
	x := stubXclip(t, false)
	t.Setenv("CLIPD_DISPLAY", ":94")
	if code, _, errOut := runCLI(t, cfg, "pick", id); code != 0 {
		t.Fatalf("exit %d err %q", code, errOut)
	}
	if !strings.Contains(xclipCalls(x), "DISPLAY=:94 ") {
		t.Fatalf("calls:\n%s", xclipCalls(x))
	}
}

func TestPickDisplayMissingIs78(t *testing.T) {
	cfg, id := winRig(t)
	x := stubXclip(t, false)
	for _, args := range [][]string{{"pick", id}, {"pick", id, "garbage"}, {"pick", id, ":1;rm"}} {
		if code, _, _ := runCLI(t, cfg, args...); code != exitConfig {
			t.Fatalf("%v: exit %d, want 78", args, code)
		}
	}
	if calls := xclipCalls(x); calls != "" {
		t.Fatalf("published anyway:\n%s", calls)
	}
	if pickedState() {
		t.Fatal("echo guard written without a publish")
	}
}

func TestPickExpiredIsExit1(t *testing.T) {
	cfg, _ := winRig(t)
	x := stubXclip(t, false)
	self, err := loadIdentity()
	if err != nil {
		t.Fatal(err)
	}
	peer := &store.Store{Dir: os.Getenv("CLIPD_FOLDER"), Origin: "peer", Self: self, Cap: entry.DefaultCap}
	id, err := peer.Write(entry.Entry{Created: time.Now().Add(-301 * time.Second).UnixMilli(), TTLs: 300, Mime: entry.MimeText, Data: []byte("old")})
	if err != nil {
		t.Fatal(err)
	}
	if code, _, _ := runCLI(t, cfg, "pick", id, ":93"); code != exitFail {
		t.Fatalf("exit %d, want 1", code)
	}
	if calls := xclipCalls(x); calls != "" {
		t.Fatalf("expired entry published:\n%s", calls)
	}
	if pickedState() {
		t.Fatal("expired pick wrote the echo guard")
	}
}

func TestPickPublishFailureIsExit2(t *testing.T) {
	cfg, id := winRig(t)
	stubXclip(t, true)
	code, out, errOut := runCLI(t, cfg, "pick", id, ":93")
	if code != 2 || out != "" || strings.Contains(errOut, "there") {
		t.Fatalf("exit %d out %q err %q", code, out, errOut)
	}
}
