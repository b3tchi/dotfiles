// check.go is the CLI entry point for `--check` (sp021 Task 13, bd
// dotfiles-ylmp.12) and Dispatch, the argv router every subcommand this
// task adds (`check --ownership`, `--health`, `state-tail`) goes through --
// see Dispatch's doc for why main.go's own flag surface stays exactly as
// thin as its doc comment promises.
//
// # The dwm model
//
// hotkeyd.py's `--check` accepts a `--binds PATH` flag so a hook or a human
// can validate an alternate table without installing it (hotkeyd.py:1895-
// 1896). This binary has NO equivalent flag, on purpose: the table is
// COMPILED IN (config.go's Binds/Layers are Go values, not a runtime-loaded
// module), dwm config.h style. Trying a different table means editing
// config.go and running `go build` -- there is no file path to point a flag
// at. --help says this explicitly (usageText) rather than silently
// dropping the flag, matching dotfiles-2ats's finding that the --binds
// runtime-injection stages have no Go equivalent.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"

	"hotkeyd/internal/bind"
)

// usageText is Dispatch's --help output, factored out from fs.Usage so
// TestUsageText_NoBindsFlag_PointsAtGoBuild can assert on its content
// directly rather than capturing os.Stderr.
func usageText() string {
	return `usage:
  hotkeyd [--display DISPLAY]
        start the daemon

  hotkeyd --check
        validate the compiled bind table and exit; no grabs, no X
        connection, no i3 -- runs with no $DISPLAY set (us020 AC2)

  hotkeyd --health [--display DISPLAY]
        report whether this display's daemon is SERVING (not merely
        alive) -- see docs/notes/adr0017.md for the exit codes (0, 6,
        7, 8, 9, 10), each naming the probe that failed

  hotkeyd check --ownership [--display DISPLAY]
        report per-display chord ownership (i3 / daemon / neither /
        BOTH) from i3's GET_CONFIG and the compiled table; non-zero
        if any chord is owned by BOTH

  hotkeyd state-tail [DISPLAY]
        connect to this display's layer-state socket and print every
        line verbatim, exiting the moment it is missing or closes --
        no internal retry (adr0014); drop-in for state-tail.py

  hotkeyd set-layer NAME [--display DISPLAY]
        set (or clear, with NAME=default) this display's
        external-trigger layer over its per-display control socket
        (sp023) -- NARROW ON PURPOSE: only names declared External in
        the COMPILED table are accepted (e.g. screenshot-drag), plus
        "default" to clear; every other layer stays chord-only and is
        refused BY NAME before this client even dials the socket
        (adr0021's compile-time discipline, checked here AND again by
        the daemon). One connect attempt, no retry (adr0014). Exit
        codes: 0 on {"ok":true}; 1 if REFUSED -- by this client's own
        pre-check or by the daemon, either way a wrong request; 2 on a
        usage error (no NAME, or a bad flag); 3 if the daemon is
        UNREACHABLE -- no connection, no reply before the deadline, or
        an unparseable reply -- distinct from 1 so a caller script can
        tell "wrong request" from "no daemon"

There is no --binds flag: unlike hotkeyd.py, the bind table is
compiled into this binary (the dwm config.h model). To try a
different table, edit cmd/hotkeyd/config.go and run 'go build'.
`
}

// Dispatch is main's real entry point (see main.go's main(), which just
// calls os.Exit(Dispatch(os.Args[1:]))): it recognizes the subcommand
// forms this task adds (a leading "state-tail" or "check" argument) and,
// failing that, parses --check/--health/--display against a small flag set
// before falling through to the existing daemon-start path (run(), in
// main.go, unchanged). main.go's own doc comment anticipates exactly this
// wiring ("Task 13 ... adds --check/--health/state-tail as sibling files")
// -- run()'s flag surface stays untouched; every new flag/subcommand is
// owned here instead.
func Dispatch(argv []string) int {
	if len(argv) > 0 {
		switch argv[0] {
		case "state-tail":
			return runStateTailCmd(argv[1:])
		case "check":
			return runCheckSubcommand(argv[1:])
		case "set-layer":
			return runSetLayerCmd(argv[1:])
		}
	}

	fs := flag.NewFlagSet("hotkeyd", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprint(os.Stderr, usageText()) }
	check := fs.Bool("check", false, "validate the compiled bind table headless and exit")
	health := fs.Bool("health", false, "report whether this display's daemon is SERVING")
	display := fs.String("display", "", "X display (default: $DISPLAY)")
	if err := fs.Parse(argv); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}

	switch {
	case *check:
		return runCheck()
	case *health:
		code, msg := runHealth(*display)
		fmt.Println(msg)
		return code
	default:
		return run(argv)
	}
}

// runCheckSubcommand handles `hotkeyd check [--ownership] [--display D]`.
// With no --ownership it behaves exactly like top-level --check (both
// bottom out in runCheck()) -- `check` and `--check` are deliberately two
// spellings of the same validation when no subcommand-specific flag is
// given.
func runCheckSubcommand(argv []string) int {
	fs := flag.NewFlagSet("hotkeyd check", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprint(os.Stderr, usageText()) }
	ownership := fs.Bool("ownership", false, "report per-display chord ownership (i3 vs daemon)")
	display := fs.String("display", "", "X display used to resolve the i3 IPC socket (default: $DISPLAY)")
	if err := fs.Parse(argv); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if *ownership {
		return runOwnership(*display)
	}
	return runCheck()
}

// validateAllResolutions runs bind.Validate once per entry in
// bind.ModResolutions and returns every problem found, prefixed with which
// $mod resolution it was found under. --check has no live display to
// resolve $mod against (us020 AC2: headless), so it must prove the table
// valid under EVERY resolution this repo actually runs on -- a table valid
// under Mod4 but broken under Mod1 (or vice versa) must still be refused
// by name, matching config_test.go's own
// TestValidatorOverRealTable_BothModResolutions.
func validateAllResolutions(binds []bind.Bind, layers map[string]bind.Layer) []string {
	var out []string
	for _, mod := range bind.ModResolutions {
		for _, p := range bind.Validate(binds, layers, mod) {
			out = append(out, fmt.Sprintf("[$mod=%s] %s", mod, p))
		}
	}
	return out
}

// runCheck is `--check`'s production entry point: validate the compiled
// table (config.go's Binds/Layers) headless, print conflicts by name, exit
// non-zero on any problem. Ported from hotkeyd.py's check(), extended to
// validate under every $mod resolution (see validateAllResolutions) since
// this binary carries no --binds flag to re-invoke per resolution the way
// a shell loop over hotkeyd.py could.
func runCheck() int {
	problems := validateAllResolutions(Binds, Layers)
	if len(problems) > 0 {
		fmt.Fprintf(os.Stderr, "hotkeyd: %d problem(s) in the bind table:\n", len(problems))
		for _, p := range problems {
			fmt.Fprintf(os.Stderr, "  %s\n", p)
		}
		return 1
	}

	nLayerBinds := 0
	for _, l := range Layers {
		nLayerBinds += len(l.Binds)
		for _, m := range l.Mods {
			nLayerBinds += len(m.Binds)
		}
	}
	chords := chordsForCheck(Binds, Layers)
	fmt.Printf("hotkeyd: OK — %d global bind(s), %d layer(s), %d layer bind(s), %d chord(s) to grab "+
		"(validated for every $mod this repo runs: %v)\n",
		len(Binds), len(Layers), nLayerBinds, len(chords), bind.ModResolutions)
	return 0
}

// chordsForCheck is --check's "how many chords total" summary count:
// global chords plus every layer's own chord set, deduplicated, under the
// DEFAULT $mod resolution (a display-agnostic count -- the two resolutions
// can only differ once a DisplayMod-qualified bind ships, and the shipped
// table has none yet; see config.go's package doc).
func chordsForCheck(binds []bind.Bind, layers map[string]bind.Layer) []string {
	out := globalChords(binds, bind.DefaultMod)
	for _, l := range layers {
		out = append(out, layerChords(l, bind.DefaultMod)...)
	}
	return dedupOrdered(out)
}
