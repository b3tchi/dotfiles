// Package x11 is a zero-dependency, stdlib-only client for the X11 wire
// protocol, ported from the poc015 spike (docs/notes/lab/poc015.md). It owns
// only the requests hotkeyd needs: connection setup/auth, sequence
// correlation, and the read loop. See adr0021 for why this exists instead of
// a vendored xgb fork.
package x11

import (
	"fmt"
	"strconv"
	"strings"
)

// ParseDisplay parses an X11 $DISPLAY string of the form
// [hostname]:displaynum[.screennum] and returns the hostname (empty string
// means local), the display number, and the screen number.
func ParseDisplay(disp string) (host string, display int, screen int, err error) {
	colon := strings.LastIndexByte(disp, ':')
	if colon < 0 {
		return "", 0, 0, fmt.Errorf("x11: invalid DISPLAY %q: missing ':'", disp)
	}

	host = disp[:colon]
	rest := disp[colon+1:]
	if rest == "" {
		return "", 0, 0, fmt.Errorf("x11: invalid DISPLAY %q: missing display number", disp)
	}

	numStr := rest
	screenStr := ""
	if dot := strings.IndexByte(rest, '.'); dot >= 0 {
		numStr = rest[:dot]
		screenStr = rest[dot+1:]
	}

	display, convErr := strconv.Atoi(numStr)
	if convErr != nil {
		return "", 0, 0, fmt.Errorf("x11: invalid DISPLAY %q: bad display number: %w", disp, convErr)
	}

	if screenStr != "" {
		screen, convErr = strconv.Atoi(screenStr)
		if convErr != nil {
			return "", 0, 0, fmt.Errorf("x11: invalid DISPLAY %q: bad screen number: %w", disp, convErr)
		}
	}

	return host, display, screen, nil
}
