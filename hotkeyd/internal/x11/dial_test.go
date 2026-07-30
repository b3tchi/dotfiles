package x11

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestSocketPath(t *testing.T) {
	got := SocketPath(10)
	want := "/tmp/.X11-unix/X10"
	if got != want {
		t.Fatalf("SocketPath(10) = %q, want %q", got, want)
	}
}

func TestDialUnixWithAbstractFallback_NormalSocket(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "normal.sock")

	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err == nil {
			c.Close()
		}
	}()

	c, err := dialUnixWithAbstractFallback(path)
	if err != nil {
		t.Fatalf("dialUnixWithAbstractFallback(%q) unexpected error: %v", path, err)
	}
	c.Close()
}

func TestDialUnixWithAbstractFallback_AbstractOnly(t *testing.T) {
	// No filesystem entry exists at this path at all -- only an
	// abstract-namespace listener bound to "@path" is reachable, which
	// forces the fallback branch (poc015 gotcha 11).
	dir := t.TempDir()
	path := filepath.Join(dir, "abstract-only.sock")

	ln, err := net.Listen("unix", "@"+path)
	if err != nil {
		t.Skipf("abstract-namespace unix sockets unsupported on this platform: %v", err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err == nil {
			c.Close()
		}
	}()

	if _, statErr := os.Stat(path); statErr == nil {
		t.Fatalf("expected no filesystem entry at %q, but one exists", path)
	}

	c, err := dialUnixWithAbstractFallback(path)
	if err != nil {
		t.Fatalf("dialUnixWithAbstractFallback(%q) unexpected error: %v", path, err)
	}
	c.Close()
}

func TestDialUnixWithAbstractFallback_NoServer(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nothing-here.sock")

	_, err := dialUnixWithAbstractFallback(path)
	if err == nil {
		t.Fatal("expected an error when neither normal nor abstract socket exists")
	}
	var connErr *ErrNoServer
	if !errors.As(err, &connErr) {
		t.Fatalf("expected *ErrNoServer, got %T: %v", err, err)
	}
}
