package main

import (
	"fmt"
	"strings"

	"hotkeyd/internal/x11"
)

// unsafeDisplayEnv is the one, explicit opt-out of the session-range
// refusal below. Named rather than a bare flag so it shows up in a process
// listing and in `env`, and so grepping the repo for it finds every caller.
const unsafeDisplayEnv = "HOTKEYD_LIVECHECK_UNSAFE_DISPLAY"

// lowestPrivateDisplay is the first display number livecheck will touch
// without the opt-out. :0 and :1 are native sessions, :10 is what adr0004's
// xrdp session uses (and :10.0 is what a developer's $DISPLAY actually
// reads on this repo's own machine), so everything below :20 is treated as
// somebody's real desktop. The Go integration tests already pick rig
// displays in the 200-2200 range (internal/x11's pickFreeDisplay).
const lowestPrivateDisplay = 20

// resolveTargetDisplay returns the display livecheck may operate on, or an
// error explaining the refusal.
//
// # Why there is no $DISPLAY fallback
//
// hotkeyd grabs keyboard chords; the daemon this tool starts grabs the whole
// shipped table; --health's verdict-8 probe takes an EXCLUSIVE keyboard
// grab. Any of those landing on a live session hijacks it. Twice during
// sp021 a run inherited a developer's $DISPLAY and did exactly that — one of
// them blocked for five minutes on :10.0. An inherited display is the only
// way that happens, so this function does not read $DISPLAY at all: the
// caller names the rig or the run refuses. env is consulted ONLY for the
// named opt-out, never for a default.
func resolveTargetDisplay(flagDisplay string, env func(string) string) (string, error) {
	if strings.TrimSpace(flagDisplay) == "" {
		return "", fmt.Errorf(
			"livecheck: no display given — pass --display :<n> explicitly. " +
				"This tool grabs chords and starts a daemon that grabs the whole " +
				"table; it will not inherit $DISPLAY and land on a live session")
	}
	display := strings.TrimSpace(flagDisplay)

	host, num, _, err := x11.ParseDisplay(display)
	if err != nil {
		return "", fmt.Errorf("livecheck: --display %q does not parse: %w", display, err)
	}
	if host != "" {
		return "", fmt.Errorf("livecheck: --display %q names a remote host; only local rigs are allowed", display)
	}
	if num < lowestPrivateDisplay && env(unsafeDisplayEnv) == "" {
		return "", fmt.Errorf(
			"livecheck: refusing --display %q — :0-:%d are session displays "+
				"(:10 is adr0004's xrdp session). Start a private Xvfb on :%d or "+
				"higher, or set %s=1 if you really mean it",
			display, lowestPrivateDisplay-1, lowestPrivateDisplay, unsafeDisplayEnv)
	}
	return display, nil
}

// childEnv builds the environment for every process livecheck spawns:
// DISPLAY pinned to the rig, I3SOCK scrubbed, and (when sandboxHome is
// non-empty) HOME redirected.
//
// I3SOCK is scrubbed for the reason main.go's i3SocketResolver documents: i3
// injects it into the environment of everything it execs, so a tool started
// from a developer's session carries THEIR i3's socket and every dispatch
// lands on the wrong window manager.
//
// HOME is redirected because the shipped bind table's Run actions are shell
// strings pointing at ~/.dotfiles/quickshell/qs-overlay.sh and
// ~/.local/bin/..., and proc.Run executes them through /bin/sh -c — so `~`
// expands against the CHILD's HOME. Pointing HOME at a sandbox means a live
// check can drive the switcher gesture through the REAL daemon and the REAL
// shipped table without ever spawning the operator's own scripts, and the
// stub the sandbox does contain records exactly which actions were
// dispatched. (live_check.py substitutes a stand-in bind table for the same
// reason; the Go daemon compiles its table in — the dwm model — so the
// substitution has to happen in the environment instead.)
func childEnv(base []string, display, sandboxHome string) []string {
	out := make([]string, 0, len(base)+2)
	for _, kv := range base {
		switch {
		case strings.HasPrefix(kv, "DISPLAY="),
			strings.HasPrefix(kv, "I3SOCK="):
			continue
		case sandboxHome != "" && strings.HasPrefix(kv, "HOME="):
			continue
		}
		out = append(out, kv)
	}
	out = append(out, "DISPLAY="+display)
	if sandboxHome != "" {
		out = append(out, "HOME="+sandboxHome)
	}
	return out
}
