package x11

import (
	"errors"
	"strings"
	"testing"
)

func TestOpen_InvalidDisplayString(t *testing.T) {
	_, _, err := Open("not-a-display")
	if err == nil {
		t.Fatal("Open(\"not-a-display\") = nil error, want error")
	}
	if !strings.Contains(err.Error(), "invalid DISPLAY") {
		t.Errorf("error %q does not name the invalid DISPLAY problem", err.Error())
	}
}

func TestOpen_NoServerAtDisplay(t *testing.T) {
	// Display number chosen to be extremely unlikely to have a real X
	// server listening.
	_, _, err := Open(":19999")
	if err == nil {
		t.Fatal("Open(\":19999\") = nil error, want error (no server listening)")
	}
	var noServer *ErrNoServer
	if !errors.As(err, &noServer) {
		t.Errorf("error is %T, want *ErrNoServer: %v", err, err)
	}
}
