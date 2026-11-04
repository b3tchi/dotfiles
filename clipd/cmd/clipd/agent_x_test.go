package main

import (
	"strings"
	"testing"
)

func TestAgentXDisplayRequired(t *testing.T) {
	cfg := t.TempDir()
	t.Setenv("DISPLAY", ":0") // inherited: must be ignored
	t.Setenv("CLIPD_DISPLAY", "")
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	code, _, errOut := runCLI(t, cfg, "agent", "x")
	if code != 78 || !strings.Contains(errOut, "display required") {
		t.Fatalf("no display: exit %d err %q", code, errOut)
	}
	for _, bad := range []string{"0", "foo", ":", ":1;rm"} {
		if code, _, _ := runCLI(t, cfg, "agent", "x", bad); code != 78 {
			t.Fatalf("display %q: exit %d", bad, code)
		}
	}
	if code, _, _ := runCLI(t, cfg, "agent", "x", ":1", ":2"); code != 2 {
		t.Fatalf("two displays: exit %d", code)
	}
	if code, _, _ := runCLI(t, cfg, "agent", "windowz"); code != 2 {
		t.Fatalf("unknown agent: exit %d", code)
	}
}

func TestAgentXConfigErrorsAre78(t *testing.T) {
	cfg := t.TempDir() // no identity.txt
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	if code, _, _ := runCLI(t, cfg, "agent", "x", ":93"); code != 78 {
		t.Fatalf("missing identity: exit %d", code)
	}
	t.Setenv("XDG_RUNTIME_DIR", "")
	t.Setenv("CLIPD_FOLDER", "")
	if code, _, errOut := runCLI(t, cfg, "agent", "x", ":93"); code != 78 || !strings.Contains(errOut, "XDG_RUNTIME_DIR") {
		t.Fatalf("no runtime dir: exit %d %q", code, errOut)
	}
}

func TestAgentXBadOriginIs78(t *testing.T) {
	cfg := t.TempDir()
	if code, _, _ := runCLI(t, cfg, "keygen"); code != 0 {
		t.Fatal("keygen")
	}
	run := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", run)
	for _, bad := range []string{"bad name", "-lead", "a/b", strings.Repeat("x", 65)} {
		t.Setenv("CLIPD_DEVICE", bad)
		code, _, errOut := runCLI(t, cfg, "agent", "x", ":93")
		if code != 78 || !strings.Contains(errOut, "origin must match") {
			t.Fatalf("CLIPD_DEVICE=%q: exit %d err %q", bad, code, errOut)
		}
	}
}
