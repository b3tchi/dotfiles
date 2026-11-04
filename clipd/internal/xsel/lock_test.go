//go:build unix

package xsel

import (
	"path/filepath"
	"testing"
)

func TestLockSingleInstance(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a.lock")
	rel, ok, err := Lock(p)
	if err != nil || !ok {
		t.Fatalf("first: %v %v", ok, err)
	}
	if _, ok2, err := Lock(p); err != nil || ok2 {
		t.Fatalf("second got lock: %v %v", ok2, err)
	}
	rel()
	rel3, ok3, err := Lock(p)
	if err != nil || !ok3 {
		t.Fatalf("after release: %v %v", ok3, err)
	}
	rel3()
}
