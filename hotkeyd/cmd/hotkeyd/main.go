// main.go is the CLI entry point (sp021 Task 12, bd dotfiles-ylmp.11): it
// does the real I/O — opening the X connection, probing XI2, acquiring the
// single-instance lock, resolving $mod, validating the table, and wiring
// every dependency daemon.go's Daemon needs — then hands off to
// (*Daemon).Run. Task 13 (bd dotfiles-ylmp.12) adds --check/--health/
// state-tail as sibling files; this file's flag surface is deliberately
// thin (just --display) so those land without reshaping it.
//
// Ported from hotkeyd.py's main_argv/run_daemon (hotkeyd.py:1548-1670,
// 1893-1934), keeping its distinct startup exit codes: 3 = another daemon
// already holds this display, 5 = XI2 unavailable. Runtime (not startup)
// failures use 1, matching hotkeyd.py's ConnectionClosedError/TableInvalid
// handling — see daemon.go's exitXConnLost.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/i3"
	"hotkeyd/internal/layer"
	"hotkeyd/internal/proc"
	"hotkeyd/internal/x11"
)

// Startup exit codes distinct from exitXConnLost (daemon.go) — named,
// never a silent fallback (adr0021's anti-pattern list: "core XGrabKey
// fallback when XI2 is missing (exit 5, named — never silent
// degradation)").
const (
	exitAlreadyRunning = 3
	exitXI2Unavailable = 5
)

// main is the process entry point. It hands off to Dispatch (check.go,
// sp021 Task 13 / bd dotfiles-ylmp.12) rather than calling run() directly:
// Dispatch recognizes --check/--health/the "check"/"state-tail"
// subcommands and falls through to run() unchanged for the plain
// daemon-start path -- see Dispatch's own doc for why this keeps run()'s
// flag surface exactly as thin as this file's package doc promises.
func main() {
	os.Exit(Dispatch(os.Args[1:]))
}

// run is main's testable body — daemon_test.go exercises the pure helpers
// below it (validateTable, requireXI2, i3SocketResolver, buildPublisher,
// newPointerModifierQuery) directly rather than run() itself, since run()
// is inherently real-I/O startup glue (X connect, lock, lookup a live
// display) that cannot be driven without Xvfb. The interfaces those
// helpers are written against are exactly what makes them testable
// without it.
func run(argv []string) int {
	fs := flag.NewFlagSet("hotkeyd", flag.ContinueOnError)
	displayFlag := fs.String("display", "", "X display (default: $DISPLAY)")
	if err := fs.Parse(argv); err != nil {
		return 2
	}

	display := *displayFlag
	if display == "" {
		display = os.Getenv("DISPLAY")
	}
	if display == "" {
		display = ":0"
	}

	conn, info, err := x11.Open(display)
	if err != nil {
		daemonLog(fmt.Sprintf("cannot open display %s: %s", display, err))
		return 1
	}

	// XI2 probed BEFORE the lock and any grab, so a display that cannot do
	// XI2 costs a named exit and leaves nothing behind to reap (us019-
	// adjacent fail-fast discipline, ported from hotkeyd.py's require_xi2
	// call order in run_daemon).
	ext, err := requireXI2(conn)
	if err != nil {
		daemonLog(fmt.Sprintf("XI2 unavailable -- %s", err))
		conn.Close()
		return exitXI2Unavailable
	}

	lock, err := proc.AcquireLock(proc.LockPath(display))
	if err != nil {
		daemonLog(err.Error())
		conn.Close()
		return exitAlreadyRunning
	}

	if len(info.Screens) == 0 {
		daemonLog(fmt.Sprintf("display %s: setup response has no screens", display))
		lock.Release()
		conn.Close()
		return 1
	}
	root := info.Screens[0].Root

	mod := ResolveMod(conn.GetPropertyAll, root)

	// Table validated BEFORE any grab (us019 AC: refused by name, daemon
	// does not start on an invalid table).
	if err := validateTable(Binds, Layers, mod); err != nil {
		daemonLog(err.Error())
		lock.Release()
		conn.Close()
		return 1
	}

	if err := conn.XISelectEvents(ext.MajorOpcode, root, []x11.EventMaskEntry{
		{DeviceID: x11.DeviceAll, Mask: []uint32{x11.XIEventMaskHierarchy | x11.XIEventMaskDeviceChanged}},
	}); err != nil {
		// Best-effort: without this, a device hot-plug/unplug just means a
		// stale name cache until the next restart -- not fatal to serving
		// the keyboard (adr0014).
		daemonLog(fmt.Sprintf("XISelectEvents (device watch): %s", err))
	}

	grabs := NewGrabManager(conn, ext.MajorOpcode, root, x11.DeviceAllMaster,
		info.MinKeycode, info.MaxKeycode, mod, nil)
	devices := NewDeviceRegistry(func(deviceid uint16) ([]x11.XIDeviceInfo, error) {
		return conn.XIQueryDevice(ext.MajorOpcode, deviceid)
	})

	pub, pubCloser := buildPublisher(display, daemonLog)
	engine := layer.NewEngine(Binds, Layers, layer.Config{Publisher: pub, Mod: mod})

	// dae is assigned below, before wireI3Mode (called from NewDaemon)
	// ever drives a real Subscribe/PollEvents -- the onEvent closure reads
	// dae at CALL time, not at closure-creation time.
	var dae *Daemon
	i3Client := i3.NewClient(i3SocketResolver(display), func(kind uint32, data map[string]any) {
		dae.onI3Event(kind, data)
	})

	dae = NewDaemon(DaemonConfig{
		Events:      conn.Events,
		I3:          i3Client,
		Grabs:       grabs,
		Devices:     devices,
		Engine:      engine,
		Lock:        lock,
		Publisher:   pubCloser,
		XConn:       conn,
		NewModQuery: newPointerModifierQuery(conn, root),
		Binds:       Binds,
		Layers:      Layers,
		Mod:         mod,
		Display:     display,
		Log:         daemonLog,
	})

	// Initial grab set: the default layer's global chords. GrabManager
	// reports each problem itself the first time it appears (grabs.go),
	// so nothing further is printed here.
	dae.resyncGrabs()
	daemonLog(fmt.Sprintf("%d chords grabbed on %s via XI2 ($mod=%s)", len(grabs.Active()), display, mod))

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(sig)

	return dae.Run(sig)
}

// validateTable enforces us019's AC: an invalid table is refused BY NAME
// and the daemon does not start, checked before any grab. Pure --
// reused by run()'s startup path and unit-tested directly without X.
func validateTable(binds []bind.Bind, layers map[string]bind.Layer, mod string) error {
	problems := bind.Validate(binds, layers, mod)
	if len(problems) == 0 {
		return nil
	}
	msgs := make([]string, len(problems))
	for i, p := range problems {
		msgs[i] = string(p)
	}
	return fmt.Errorf("%d problem(s) in the bind table:\n  %s", len(problems), strings.Join(msgs, "\n  "))
}

// xiVersionSource is the subset of *x11.Conn's behaviour requireXI2
// needs -- the seam that lets it be unit-tested with a fake XI2-less (or
// XI2-1.x) server, no Xvfb required.
type xiVersionSource interface {
	QueryExtension(name string) (x11.ExtensionInfo, error)
	XIQueryVersion(majorOpcode byte, major, minor uint16) (x11.XIVersion, error)
}

var _ xiVersionSource = (*x11.Conn)(nil)

// requireXI2 asserts this display can do XI2, or returns a named error --
// fail fast at startup (exit 5, see run()) rather than a silent fallback
// to core XGrabKey (adr0021's anti-pattern list) or a stack trace at the
// first keypress. Ported from hotkeyd.py's require_xi2.
func requireXI2(x xiVersionSource) (x11.ExtensionInfo, error) {
	ext, err := x.QueryExtension("XInputExtension")
	if err != nil {
		return ext, fmt.Errorf("cannot query the XInputExtension on this display: %w", err)
	}
	if !ext.Present {
		return ext, fmt.Errorf(
			"this display has no XInputExtension -- hotkeyd grabs via XI2 " +
				"and will not fall back to core grabs, which carry no source device")
	}
	ver, err := x.XIQueryVersion(ext.MajorOpcode, 2, 3)
	if err != nil {
		return ext, fmt.Errorf("XIQueryVersion failed on this display: %w", err)
	}
	if ver.Major < 2 {
		return ext, fmt.Errorf("this display speaks XInput %d.%d; hotkeyd needs XI2 (2.0 or later)", ver.Major, ver.Minor)
	}
	return ext, nil
}

// i3SocketResolver returns a display-pinned, $I3SOCK-safe i3 IPC socket
// path resolver for display — the pathFn NewClient's own doc says a
// daemon (as opposed to a quick CLI tool) must inject (bd notes on this
// task): the package's own DiscoverSocket reads $I3SOCK, which i3
// injects into the environment of every process it execs, so a daemon
// started for :10 by :0's i3 would inherit :0's socket and every
// dispatch would land on the wrong window manager (a chord in the RDP
// session moving a window on the native desktop).
//
// Order: $HOTKEYD_I3SOCK (an operator/test override i3 never injects, so
// it cannot mis-route a session) -> `i3 --get-socketpath` run with
// DISPLAY pinned to THIS daemon's display and I3SOCK scrubbed from its
// environment.
//
// Deliberately narrower than hotkeyd.py's i3_socket_path, which tries the
// I3_SOCKET_PATH root-window property (via its own X connection) before
// falling back to the CLI: that property is an i3-defined atom, and
// internal/x11 has no InternAtom request yet (out of every landed sp021
// task's files_touched) — filed as discovered work rather than silently
// reproduced with a hand-rolled request here. The safety property this
// task actually needs — never resolving to the WRONG i3 — is fully
// preserved by the two tiers kept: neither reads $I3SOCK, and the CLI
// tier is pinned to this daemon's own display every time.
func i3SocketResolver(display string) func() (string, error) {
	return func() (string, error) {
		if p := os.Getenv("HOTKEYD_I3SOCK"); p != "" {
			return p, nil
		}
		env := make([]string, 0, len(os.Environ())+1)
		for _, kv := range os.Environ() {
			if strings.HasPrefix(kv, "I3SOCK=") {
				continue
			}
			env = append(env, kv)
		}
		env = append(env, "DISPLAY="+display)
		cmd := exec.Command("i3", "--get-socketpath")
		cmd.Env = env
		out, err := cmd.Output()
		if err != nil {
			return "", fmt.Errorf("i3 --get-socketpath: %w", err)
		}
		return strings.TrimSpace(string(out)), nil
	}
}

// buildPublisher constructs display's state-socket publisher (internal/
// layer, sp021 Task 8 / bd dotfiles-ylmp.7). initial is the engine's
// actual starting state — always {Layer: layer.DefaultLayer, Mod: ""} for
// a freshly constructed Engine (NewEngine seeds layerName to DefaultLayer,
// and Mod stays "" until some modifier is observed held; see engine.go),
// so this is computed without needing a live Engine to ask, and is passed
// to NewEngine's own Config.Publisher afterwards — see run()'s
// construction order.
//
// Policy (bd notes on this task, routed from ylmp.7's implementer): the
// feed is best-effort — grabs are the daemon's job, the state socket is a
// convenience for ft009's bars — so ANY failure to bind the socket
// (layer.ErrChannelUnavailable, or any other error NewStatePublisher
// returns) is logged and the daemon proceeds with publisher == nil, which
// layer.Engine already treats as "no feed" (engine.go's publish() checks
// `e.publisher != nil`).
func buildPublisher(display string, log func(string)) (layer.Publisher, *layer.StatePublisher) {
	initial := layer.State{Layer: layer.DefaultLayer}
	pub, err := layer.NewStatePublisher(layer.SocketPath(display), initial)
	if err != nil {
		log(fmt.Sprintf("state publisher unavailable, continuing without a state feed: %s", err))
		return nil, nil
	}
	return pub, pub
}

// pointerQuerier is the subset of *x11.Conn's behaviour
// newPointerModifierQuery needs.
type pointerQuerier interface {
	QueryPointer(window uint32) (x11.PointerInfo, error)
}

var _ pointerQuerier = (*x11.Conn)(nil)

// newPointerModifierQuery builds a DaemonConfig.NewModQuery factory over a
// real X connection. Each call to the returned func() layer.ModifierDown
// gives one PollIdle tick a query that issues AT MOST ONE QueryPointer
// round trip, regardless of how many canons that tick asks about (at most
// two: the held set's members plus the active hold layer's modifier — see
// hold.go's PollIdle) — decoded once from PointerInfo.Mask and cached in
// the closure for every subsequent ModifierDown call within that same
// tick.
//
// Design note (bd notes on this task, routed from ylmp.6's implementer):
// layer.PollIdle's ModifierDown(mod) signature asks one modifier at a
// time rather than taking a whole down-set. That shape is kept AS-IS —
// QueryPointer's core-protocol Mask field already reports every modifier
// at once, so this wrapper absorbs the "one round trip, many questions"
// optimisation at the CALLER instead of changing PollIdle's signature.
// Changing the signature would only move where the caching lives, not
// remove the need for it, and the per-modifier shape is simpler to unit
// test (hold_test.go already does) and to fake in daemon_test.go — so
// this task confirms per-modifier querying rather than asking for a
// down-mask parameter.
func newPointerModifierQuery(x pointerQuerier, root uint32) func() layer.ModifierDown {
	return func() layer.ModifierDown {
		var (
			fetched  bool
			mask     uint16
			fetchErr error
		)
		return func(mod string) (bool, error) {
			if !fetched {
				info, err := x.QueryPointer(root)
				fetched = true
				if err != nil {
					fetchErr = err
				} else {
					mask = info.Mask
				}
			}
			if fetchErr != nil {
				return false, fetchErr
			}
			bit, ok := maskByModifier[bind.Modifier(mod)]
			if !ok {
				return false, fmt.Errorf("newPointerModifierQuery: unknown modifier %q", mod)
			}
			return uint32(mask)&bit != 0, nil
		}
	}
}
