package main

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwi3rpc"
	"hotkeyd/internal/kwin"
	"hotkeyd/internal/layer"
	"hotkeyd/internal/proc"
)

// errKwinNeedsKwi3Sock is the kwin input's refusal when $KWI3SOCK is unset:
// chords would have nowhere to go but an i3 IPC socket, and a kwin session
// has no i3 - never a silent fallback to whatever i3 the environment names.
var errKwinNeedsKwi3Sock = errors.New("--input kwin needs $KWI3SOCK (kwi3's JSON-RPC socket): " +
	"there is no i3 to fall back to on a KWin session")

// runKwin is run() for `--input kwin`: no X connection, no XI2, no display
// probe, no pointer query. Hold-layer modifier state comes from the plugin's
// mods events (Daemon.kwinModQuery).
func runKwin(grabPath string) int {
	kwi3Sock := os.Getenv("KWI3SOCK")
	if kwi3Sock == "" {
		daemonLog(errKwinNeedsKwi3Sock.Error())
		return 78
	}
	display := kwinDisplay
	mod := bind.DefaultMod

	lock, err := proc.AcquireLock(proc.LockPath(display))
	if err != nil {
		daemonLog(err.Error())
		return exitAlreadyRunning
	}
	activeBinds := effectiveBinds(kwi3Sock)
	if err := validateTable(activeBinds, Layers, mod); err != nil {
		daemonLog(err.Error())
		lock.Release()
		return 1
	}

	gm, err := kwin.NewGrabManager(grabPath, mod, func(n string) (uint32, bool) {
		v, ok := keysymByName[n]
		return v, ok
	}, daemonLog)
	if err != nil {
		daemonLog(err.Error())
		lock.Release()
		return 1
	}

	pub, pubCloser := buildPublisher(display, daemonLog)
	enginePub, modeRep := enginePublisher(pub, kwi3Sock, daemonLog)
	if modeRep != nil {
		defer modeRep.Close()
	}
	engine := layer.NewEngine(activeBinds, Layers, layer.Config{Publisher: enginePub, Mod: mod})
	ctl := buildControl(display, daemonLog)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(sig)

	cfg := DaemonConfig{
		KeyEvents: gm.Events(),
		Grabs:     kwinGrabs{gm},
		Engine:    engine,
		Lock:      lock,
		Publisher: pubCloser,
		XConn:     closerFunc(gm.Close),
		Binds:     activeBinds,
		Layers:    Layers,
		Mod:       mod,
		Display:   display,
		Log:       daemonLog,
		Kwi3: kwi3rpc.New(kwi3Sock, kwi3rpc.WithLog(daemonLog),
			kwi3rpc.WithOnConnect(modeRep.Resync)),
	}
	if ctl != nil {
		cfg.Control = ctl.Commands()
		cfg.ControlCloser = ctl
	}
	dae := NewDaemon(cfg)
	dae.resyncGrabs()
	daemonLog(fmt.Sprintf("%d chords grabbed via kwi3keys at %s ($mod=%s)", len(kwinGrabs{gm}.Active()), grabPath, mod))

	return dae.Run(sig)
}

type closerFunc func()

func (f closerFunc) Close() error { f(); return nil }
