// setlayer.go implements the `set-layer` CLI verb (sp023 Task 4, bd
// dotfiles-1m4t.4): the CLIENT side of Task 3's per-display control
// socket. `hotkeyd set-layer <name> [--display :N]` dials
// proc.ControlPath(display), sends one {"set_layer":"<name>"} request line
// (control.go's own controlRequest/controlReply wire types, reused
// verbatim -- one wire shape, defined once) and reads one reply line.
//
// # Two gates, not one (adr0021's compile-time discipline at the CLI)
//
// Before dialing anything, setLayer runs the SAME validateControlLayer
// check control.go's daemon-side handler runs (literally the same
// function -- control.go and this file are one package), against the
// compiled table THIS binary carries. An undeclared name, or a real but
// chord-only layer's name, is refused right here, with the offending name
// in the message, and the control socket is never touched -- proven in
// setlayer_test.go by a listener that asserts zero Accept calls.
//
// This is deliberately NOT the only gate: the daemon re-checks the SAME
// table on its own side (control.go's validateControlLayer, called from
// the run loop) regardless of what this client believed, because the
// daemon's compiled table is the one that actually governs the engine.
// The two checks agree by construction (same function, same source file)
// but the client-side one exists purely so a caller sees "refused: not
// declared external-triggerable" a socket round trip sooner, and so a
// missing/unreachable daemon cannot be confused with a wrong request (see
// the exit codes below).
//
// # No retry (adr0014)
//
// Exactly one dial, one write, one read, all under a single deadline
// (setLayerTimeout) started right after a successful dial. A connect
// failure, a read timeout, an early peer close, or a reply that is not
// valid JSON are all answered the same way: a named error to stderr and a
// non-zero exit, immediately -- never a loop, never a silent hang. adr0014
// leaves any retry policy to whatever spawned this process (qs-region.py's
// fire-and-forget DEVNULL call, qs-screenshot.sh's `|| true` guard -- see
// sp023's plan "Consumer spawn discipline").
//
// # Exit codes (documented again, verbatim, in usageText)
//
//	0  {"ok":true} -- or a pre-validation pass on "default" with nothing
//	   to clear (an ok no-op, callers clear unconditionally on every exit
//	   path)
//	1  refused -- either this client's own pre-validation refused the
//	   name, or the daemon replied {"ok":false,...}; either way, the
//	   request was UNDERSTOOD and rejected by name (a caller script's
//	   "wrong request" bucket)
//	2  usage error -- no NAME argument, or an unparseable flag
//	   (flag.ContinueOnError's own convention, matching every other verb
//	   in this package)
//	3  unreachable -- could not connect, the deadline elapsed with no
//	   reply, the peer closed before a reply line arrived, or the reply
//	   was not valid JSON; a caller script's "no daemon" bucket, distinct
//	   from 1 on purpose (sp023 Task 4's success criteria)
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/proc"
)

// Named exit codes for `set-layer`, documented in usageText.
const (
	SetLayerOK          = 0
	SetLayerRefused     = 1
	SetLayerUnreachable = 3
)

// setLayerTimeout bounds the ENTIRE post-dial exchange (write the request,
// read the reply) behind one deadline set right after a successful dial.
// Generous relative to a local write of a few dozen bytes and a reply of
// the same size; short enough that a wedged or silent daemon releases this
// process promptly. Mirrors control.go's controlReadTimeout or this
// verb's own client-side half of the SAME round trip -- see that file's
// doc for why 2s was picked there; this adds slack for the write half too.
const setLayerTimeout = 3 * time.Second

// runSetLayerCmd is `set-layer`'s production entry point. argv is
// everything after the "set-layer" subcommand word (Dispatch already
// stripped it): a required leading NAME, then an optional --display flag
// -- `hotkeyd set-layer <name> [--display :N]`, matching usageText.
//
// The NAME argument is positional and REQUIRED, so it is checked by hand
// before handing the rest to a flag.FlagSet: Go's flag package stops
// parsing at the first non-flag argument, which is exactly NAME here, so
// letting fs.Parse see argv unmodified would silently leave --display
// unrecognised whenever it followed NAME (the usage form this verb
// documents) rather than preceded it.
func runSetLayerCmd(argv []string) int {
	if len(argv) == 0 || strings.HasPrefix(argv[0], "-") {
		fmt.Fprint(os.Stderr, usageText())
		return 2
	}
	name := argv[0]

	fs := flag.NewFlagSet("hotkeyd set-layer", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprint(os.Stderr, usageText()) }
	display := fs.String("display", "", "X display (default: $DISPLAY)")
	if err := fs.Parse(argv[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}

	return setLayer(Layers, name, *display, setLayerTimeout, os.Stdout, os.Stderr)
}

// setLayer is set-layer's testable core: pre-validate name against layers
// (the compiled table), then -- only if that passes -- dial display's
// control socket and run the one-request/one-reply exchange. Factored out
// from runSetLayerCmd so setlayer_test.go can drive it against a fixture
// table and a real unix listener in t.TempDir(), with injected writers, no
// subprocess needed (statetail.go's stateTail is the precedent this
// mirrors).
func setLayer(layers map[string]bind.Layer, name, display string, timeout time.Duration, out, errOut io.Writer) int {
	if err := validateControlLayer(layers, name); err != nil {
		fmt.Fprintf(errOut, "set-layer: refused (not declared external-triggerable at compile time): %s\n", err)
		return SetLayerRefused
	}

	disp := resolveDisplay(display)
	path := proc.ControlPath(disp)

	ok, daemonMsg, err := dialSetLayer(path, name, timeout)
	if err != nil {
		fmt.Fprintf(errOut, "set-layer: cannot reach the control socket at %s: %s\n", path, err)
		return SetLayerUnreachable
	}
	if !ok {
		fmt.Fprintf(errOut, "set-layer: refused by the daemon: %s\n", daemonMsg)
		return SetLayerRefused
	}

	fmt.Fprintln(out, "ok")
	return SetLayerOK
}

// dialSetLayer performs the ENTIRE socket exchange: one dial, one write of
// the request line, one read of the reply line, all under a single
// deadline set immediately after the dial succeeds (adr0014 -- one
// attempt, no retry, no hang). Returns (true, "", nil) on {"ok":true};
// (false, daemon's error text, nil) when the daemon answered but refused;
// and (false, "", err) for every other failure -- connect, write, read
// timeout, an early peer close, or a reply that fails to parse as JSON --
// which the caller (setLayer) maps to SetLayerUnreachable uniformly, since
// all of those mean "could not complete an exchange with a daemon", not
// "the daemon understood and said no".
//
// Reuses control.go's controlRequest/controlReply wire types directly
// (same package) rather than redeclaring the JSON shape here -- one
// struct pair, one source of truth for the wire format on both sides.
func dialSetLayer(path, name string, timeout time.Duration) (ok bool, daemonMsg string, err error) {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return false, "", err
	}
	defer conn.Close()

	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return false, "", fmt.Errorf("cannot set a deadline: %w", err)
	}

	req := controlRequest{SetLayer: &name}
	data, err := json.Marshal(req)
	if err != nil {
		return false, "", fmt.Errorf("cannot encode the request: %w", err)
	}
	data = append(data, '\n')
	if _, err := conn.Write(data); err != nil {
		return false, "", fmt.Errorf("request write failed: %w", err)
	}

	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil && line == "" {
		return false, "", fmt.Errorf("no reply: %w", err)
	}

	var rep controlReply
	if uerr := json.Unmarshal([]byte(strings.TrimSpace(line)), &rep); uerr != nil {
		return false, "", fmt.Errorf("malformed reply %q: %w", strings.TrimSpace(line), uerr)
	}
	if !rep.OK {
		return false, rep.Error, nil
	}
	return true, "", nil
}
