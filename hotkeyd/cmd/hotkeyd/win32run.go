//go:build windows

package main

// sp012 Task 4 (kwi3-hoex.4): run() for `--input win32`, the kwinrun.go
// shape. No X connection, no XI2, no display: the per-instance files are
// keyed on the Windows desktop this process runs on, $mod is Alt (Mod1),
// chords are RegisterHotKey registrations on internal/win32's message-loop
// thread, and every chord goes to kwi3 over its named pipe.

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwi3rpc"
	"hotkeyd/internal/layer"
	"hotkeyd/internal/proc"
	"hotkeyd/internal/win32"
)

// defaultInput is the key source a Windows build starts with when
// --input is not given: there is no X display to grab on.
const defaultInput = "win32"

// win32DryRunEnv, set to 1, makes the daemon register NO chord: only a
// WM_HOTKEY posted to its window reaches it. Registrations are shared by
// every desktop of the window station, so a test or rig run of hotkeyd on
// a CreateDesktop desktop would otherwise take Jan's live chords.
const win32DryRunEnv = "HOTKEYD_WIN32_DRYRUN"

// defaultDisplay is the Windows answer to resolveDisplay's last tier: the
// desktop this process runs on, as the per-instance file names spell it.
func defaultDisplay() string {
	name, err := win32.DesktopName()
	if err != nil {
		return proc.DesktopTag("")
	}
	return proc.DesktopTag(name)
}

// hostPipe is the Win32 host's own default pipe for this user and desktop,
// \\.\pipe\kwi3-<user>-<desktop>, each part sanitised to [A-Za-z0-9_-]
// as the host does (i3kwin/adapters/win32).
func hostPipe(user, desktop string) string {
	return `\\.\pipe\kwi3-` + proc.DesktopTag(user) + "-" + proc.DesktopTag(desktop)
}

// win32Config is everything startWin32 needs; runWin32 fills it from the
// environment and the built table, a test fills it with its own.
type win32Config struct {
	Display  string
	Kwi3Sock string
	Binds    []bind.Bind
	Layers   map[string]bind.Layer
	Source   win32.Options
	Lock     lockBeater // nil: none (a test)
	Log      func(string)
}

// startWin32 starts the hotkey thread and builds the daemon over it, with
// the default layer's chords registered. The returned daemon owns the
// thread: its shutdown releases every registration and ends the loop.
func startWin32(cfg win32Config) (*Daemon, *win32.Source, error) {
	log := cfg.Log
	if log == nil {
		log = daemonLog
	}
	if err := validateTable(cfg.Binds, cfg.Layers, win32Mod); err != nil {
		return nil, nil, err
	}
	src, err := win32.Start(cfg.Source)
	if err != nil {
		return nil, nil, err
	}
	hk := win32.NewHotkeys(src, win32Mod, func(n string) (uint32, bool) {
		v, ok := keysymByName[n]
		return v, ok
	}, releaseOnlyChords(cfg.Binds, cfg.Layers, win32Mod), log)

	pub, pubCloser := buildPublisher(cfg.Display, log)
	enginePub, modeRep := enginePublisher(pub, cfg.Kwi3Sock, log)
	engine := layer.NewEngine(cfg.Binds, cfg.Layers, layer.Config{Publisher: enginePub, Mod: win32Mod})
	// A status request asks whether the kwi3 address answers (--health's
	// kwi3rpc check, sp012 Task 7).
	var probe func() error
	if cfg.Kwi3Sock != "" {
		probe = kwi3ProbeFor(cfg.Kwi3Sock)
	}
	ctl := buildControlProbe(cfg.Display, log, probe)
	lock := cfg.Lock
	if lock == nil {
		lock = noLock{}
	}

	dcfg := DaemonConfig{
		KeyEvents:   win32KeyEvents(src.Events()),
		Grabs:       win32Grabs{hk},
		Engine:      engine,
		Lock:        lock,
		NewModQuery: win32ModQuery(win32.KeyDown),
		XConn: closerFunc(func() {
			hk.ReleaseAll()
			src.Close()
			if modeRep != nil {
				modeRep.Close()
			}
		}),
		Binds:   cfg.Binds,
		Layers:  cfg.Layers,
		Mod:     win32Mod,
		Display: cfg.Display,
		Log:     log,
	}
	if cfg.Kwi3Sock != "" {
		opts := []kwi3rpc.Option{kwi3rpc.WithLog(log)}
		if modeRep != nil {
			opts = append(opts, kwi3rpc.WithOnConnect(modeRep.Resync))
		}
		dcfg.Kwi3 = kwi3rpc.New(cfg.Kwi3Sock, opts...)
	}
	// Only a real publisher goes in the io.Closer field: a nil
	// *StatePublisher there is a non-nil interface, and shutdown would
	// call Close on nil (the typed-nil trap buildControl's caller names).
	if pubCloser != nil {
		dcfg.Publisher = pubCloser
	}
	if ctl != nil {
		dcfg.Control = ctl.Commands()
		dcfg.ControlCloser = ctl
	}
	dae := NewDaemon(dcfg)
	dae.resyncGrabs()
	return dae, src, nil
}

// noLock stands in for the instance lock when a test runs the daemon.
type noLock struct{}

func (noLock) Beat()    {}
func (noLock) Release() {}

// runWin32 is run() for `--input win32`.
func runWin32() int {
	desktop, err := win32.DesktopName()
	if err != nil {
		daemonLog(fmt.Sprintf("cannot name this desktop: %s", err))
		return 1
	}
	display := proc.DesktopTag(desktop)
	kwi3Sock := os.Getenv("KWI3SOCK")
	if kwi3Sock == "" {
		kwi3Sock = hostPipe(os.Getenv("USERNAME"), desktop)
		daemonLog(fmt.Sprintf("$KWI3SOCK unset: using the host's pipe %s", kwi3Sock))
	}

	lock, err := proc.AcquireLock(proc.LockPath(display))
	if err != nil {
		daemonLog(err.Error())
		return exitAlreadyRunning
	}
	// What `hotkeyd recover` restarts this daemon with (sp012 Task 7).
	if err := writeArgsRecord(display, os.Args[1:], os.Getenv); err != nil {
		daemonLog(fmt.Sprintf("cannot record this daemon's arguments for recover: %s", err))
	}
	dry := strings.TrimSpace(os.Getenv(win32DryRunEnv)) == "1"
	if dry {
		daemonLog(fmt.Sprintf("%s=1: registering NO chord; only a WM_HOTKEY posted to the window is served", win32DryRunEnv))
	}
	activeBinds := effectiveBinds(kwi3Sock)
	dae, src, err := startWin32(win32Config{
		Display:  display,
		Kwi3Sock: kwi3Sock,
		Binds:    activeBinds,
		Layers:   Layers,
		Source:   win32.Options{DryRun: dry},
		Lock:     lock,
		Log:      daemonLog,
	})
	if err != nil {
		daemonLog(err.Error())
		lock.Release()
		return 1
	}
	wanted, active, missing := dae.grabs.GrabReport()
	how := "registered via RegisterHotKey"
	if dry {
		how = "accepted, DRY RUN: none registered with Windows"
	}
	daemonLog(fmt.Sprintf("%d of %d chords %s on desktop %s ($mod=%s), window %#x, %d refused",
		active, wanted, how, desktop, win32Mod, src.Window(), len(missing)))

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(sig)
	return dae.Run(sig)
}
