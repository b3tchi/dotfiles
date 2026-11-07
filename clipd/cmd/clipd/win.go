package main

// sp039 Tasks 5 and 7: `agent windows`, `list`, `pick <id>|--latest`, with
// a display argument on X.
//
// Folder and device name come from syncFolder / deviceName (main.go).
// Echo-guard state: $CLIPD_STATE_DIR, else %LOCALAPPDATA%\clipd\state
// (Windows) / $XDG_RUNTIME_DIR/clipd/state.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"time"

	"clipd/internal/agent"
	"clipd/internal/crypt"
	"clipd/internal/entry"
	"clipd/internal/store"
	"clipd/internal/winclip"
	"clipd/internal/xsel"
)

var (
	errNoRuntimeDir = errors.New("no runtime dir")
	idArg           = regexp.MustCompile(`^[0-9a-f]{16}$`)
)

// runtimePath resolves env, else <runtime base>/clipd/<leaf>.
func runtimePath(env, leaf string) (string, error) {
	if v := os.Getenv(env); v != "" {
		return v, nil
	}
	base := os.Getenv("XDG_RUNTIME_DIR")
	if runtime.GOOS == "windows" {
		base = os.Getenv("LOCALAPPDATA")
	}
	if base == "" {
		return "", fmt.Errorf("%w: LOCALAPPDATA / XDG_RUNTIME_DIR unset; set %s", errNoRuntimeDir, env)
	}
	return filepath.Join(base, "clipd", leaf), nil
}

// openStore loads identity + pinned recipients and points at the folder.
func openStore(logf func(string, ...any)) (*store.Store, error) {
	self, err := loadIdentity()
	if err != nil {
		return nil, err
	}
	rp, err := configPath("recipients.txt")
	if err != nil {
		return nil, err
	}
	peers, err := crypt.LoadRecipients(rp)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err // no recipients file = no peers yet, entries for self only
	}
	dir, err := syncFolder()
	if err != nil {
		return nil, err
	}
	return &store.Store{Dir: dir, Origin: deviceName(), Self: self, Peers: peers, Cap: entry.DefaultCap, Logf: logf}, nil
}

// agentWindows runs `clipd agent windows` (args: none).
func agentWindows(args []string, errOut io.Writer, fail func(error) int, bad func() int) int {
	if len(args) != 0 {
		return bad()
	}
	if runtime.GOOS != "windows" {
		fmt.Fprintln(errOut, "clipd: agent windows runs on windows only")
		return exitFail
	}
	lg := log.New(errOut, "clipd ", log.LstdFlags|log.Lmicroseconds)
	s, err := openStore(lg.Printf)
	if err != nil {
		return fail(err)
	}
	state, err := runtimePath("CLIPD_STATE_DIR", "state")
	if err != nil {
		return fail(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	// Started at logon, the session's clipboard may not be usable yet.
	l, err := agent.WinBackoff(ctx, 8, time.Sleep, lg.Printf, winclip.Listen)
	if err != nil {
		return fail(err)
	}
	defer l.Close()
	a := &agent.WinAgent{Clip: winClipboard{}, Sink: s, Cap: s.Cap, TTL: entry.DefaultTTL, StateDir: state, Logf: lg.Printf}
	lg.Printf("winagent: listening device=%s folder=%s", s.Origin, s.Dir)
	if err := agent.WinRun(ctx, a, s, l.Events()); err != nil {
		return fail(err)
	}
	return 0
}

// winClipboard adapts winclip.Clipboard to agent.WinClipboard.
type winClipboard struct{ c winclip.Clipboard }

func (w winClipboard) Seq() uint32 { return w.c.Seq() }
func (w winClipboard) View(fn func(agent.WinView) error) error {
	return w.c.View(func(v winclip.View) error { return fn(v) })
}

func listCmd(args []string, out io.Writer, fail func(error) int, bad func() int) int {
	if len(args) != 0 {
		return bad()
	}
	s, err := openStore(nil)
	if err != nil {
		return fail(err)
	}
	if err := agent.List(s, out); err != nil {
		return fail(err)
	}
	return 0
}

// pickCmd: exit 0 published, 1 not found/expired, 2 publish failed, 78
// config. Mirrors ft007's clip-set.sh contract. The display is resolved
// first, so a missing one publishes nothing and records no echo guard.
func pickCmd(args []string, errOut io.Writer, fail func(error) int, bad func() int) int {
	maxArgs := 2 // <id>|--latest [display]
	if runtime.GOOS == "windows" {
		maxArgs = 1
	}
	if len(args) < 1 || len(args) > maxArgs {
		return bad()
	}
	id := args[0]
	if id == "--latest" {
		id = ""
	} else if !idArg.MatchString(id) {
		return bad()
	}
	publish := winclip.Publish
	if runtime.GOOS != "windows" {
		dpy, err := namedDisplay(args[1:])
		if err != nil {
			fmt.Fprintln(errOut, "clipd: pick:", err)
			return exitConfig
		}
		x := &xsel.X{Display: dpy, Xclip: os.Getenv("CLIPD_XCLIP")}
		publish = func(isPNG bool, data []byte) error {
			target := xsel.TargetUTF8
			if isPNG {
				target = xsel.TargetPNG
			}
			return x.Publish(context.Background(), target, data)
		}
	}
	s, err := openStore(nil)
	if err != nil {
		return fail(err)
	}
	state, err := runtimePath("CLIPD_STATE_DIR", "state")
	if err != nil {
		return fail(err)
	}
	_, err = agent.Pick(s, id, state, publish)
	switch {
	case err == nil:
		return 0
	case errors.Is(err, agent.ErrPublish):
		fmt.Fprintln(errOut, "clipd:", err)
		return exitUsage // 2 = publish failed (clip-set.sh contract)
	case errors.Is(err, agent.ErrNotFound):
		fmt.Fprintln(errOut, "clipd:", err)
		return exitFail
	default:
		return fail(err)
	}
}
