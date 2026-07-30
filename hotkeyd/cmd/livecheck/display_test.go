package main

import (
	"strings"
	"testing"
)

// THE SAFETY RULE, encoded. Twice in sp021's execution a run inherited a
// developer's live $DISPLAY, took a keyboard grab on it and hijacked the
// session (once blocking for five minutes on :10.0). livecheck grabs chords
// and starts a daemon that grabs the whole shipped table, so the ONLY safe
// contract is: the display is named explicitly, never inherited, and a
// session-range display number is refused outright.
func TestResolveTargetDisplay_NeverFallsBackToAmbientDISPLAY(t *testing.T) {
	env := func(k string) string {
		if k == "DISPLAY" {
			return ":10.0" // the developer's live xrdp session
		}
		return ""
	}
	got, err := resolveTargetDisplay("", env)
	if err == nil {
		t.Fatalf("resolved %q from an ambient $DISPLAY; it must refuse", got)
	}
	if !strings.Contains(err.Error(), "--display") {
		t.Errorf("error %q does not tell the caller what to pass", err)
	}
}

func TestResolveTargetDisplay_RefusesSessionRangeDisplays(t *testing.T) {
	none := func(string) string { return "" }
	for _, d := range []string{":0", ":0.0", ":1", ":10", ":10.0", ":19"} {
		if got, err := resolveTargetDisplay(d, none); err == nil {
			t.Errorf("%s: accepted %q, but :0-:19 are session displays", d, got)
		}
	}
}

func TestResolveTargetDisplay_AcceptsAPrivateRigDisplay(t *testing.T) {
	none := func(string) string { return "" }
	for _, d := range []string{":20", ":89", ":871.0"} {
		if _, err := resolveTargetDisplay(d, none); err != nil {
			t.Errorf("%s: refused a private rig display: %v", d, err)
		}
	}
}

// The escape hatch exists for one caller only (a rig that genuinely wants a
// low number) and must be explicit, so it can never be reached by accident.
func TestResolveTargetDisplay_LowDisplayNeedsAnExplicitOptIn(t *testing.T) {
	env := func(k string) string {
		if k == unsafeDisplayEnv {
			return "1"
		}
		return ""
	}
	if _, err := resolveTargetDisplay(":0", env); err != nil {
		t.Errorf("with %s=1 set, :0 should be allowed: %v", unsafeDisplayEnv, err)
	}
}

func TestResolveTargetDisplay_RejectsGarbage(t *testing.T) {
	none := func(string) string { return "" }
	for _, d := range []string{"nonsense", ":", "::"} {
		if _, err := resolveTargetDisplay(d, none); err == nil {
			t.Errorf("%q: accepted a display that does not parse", d)
		}
	}
}

// Every child process livecheck spawns (xdotool, the daemon, xrdb,
// setxkbmap, i3-msg) must be pinned to the rig — inheriting DISPLAY or
// I3SOCK is exactly how a stray command lands on the developer's session.
func TestChildEnv_PinsDisplayAndScrubsI3SOCK(t *testing.T) {
	base := []string{"PATH=/bin", "DISPLAY=:10.0", "I3SOCK=/run/user/1000/i3/ipc.sock", "HOME=/home/jan"}
	got := childEnv(base, ":871", "")

	var sawDisplay bool
	for _, kv := range got {
		switch {
		case strings.HasPrefix(kv, "DISPLAY="):
			sawDisplay = true
			if kv != "DISPLAY=:871" {
				t.Errorf("DISPLAY not pinned to the rig: %q", kv)
			}
		case strings.HasPrefix(kv, "I3SOCK="):
			t.Errorf("I3SOCK survived into the child: %q", kv)
		}
	}
	if !sawDisplay {
		t.Error("child env has no DISPLAY at all")
	}
}

func TestChildEnv_OverridesHOMEWhenSandboxed(t *testing.T) {
	got := childEnv([]string{"HOME=/home/jan"}, ":871", "/tmp/sandbox")
	var home string
	for _, kv := range got {
		if strings.HasPrefix(kv, "HOME=") {
			home = kv
		}
	}
	if home != "HOME=/tmp/sandbox" {
		t.Errorf("HOME=%q, want the sandbox — a Run action expands ~ against the CHILD's HOME, and the shipped table's actions point into ~/.dotfiles", home)
	}
}
