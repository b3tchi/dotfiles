package main

// `clipd agent x <display>` (sp039 Task 4). The display comes from the
// argument or $CLIPD_DISPLAY and nothing else: an inherited $DISPLAY is
// never consulted (the clip-sync.sh contract — adr0004 keeps two X servers
// live). Missing or malformed → exit 78.
//
// env: CLIPD_DISPLAY    display to serve (alternative to the argument)
//      CLIPD_FOLDER     sync folder (default $XDG_RUNTIME_DIR/clipd/folder)
//      CLIPD_STATE_DIR  agent state (default $XDG_RUNTIME_DIR/clipd/state)
//      CLIPD_DEVICE     origin name (default: hostname)
//      CLIPD_XCLIP, CLIPD_CLIPNOTIFY  binaries (default from PATH)
// exit: 0 on signal or lost single-instance race, 1 when the watcher gives
//       up (display gone), 78 config unusable.

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
	"strings"
	"syscall"

	"clipd/internal/agent"
	"clipd/internal/crypt"
	"clipd/internal/entry"
	"clipd/internal/store"
	"clipd/internal/xsel"
)

var (
	displayRe    = regexp.MustCompile(`^[A-Za-z0-9._-]*:[0-9]+(\.[0-9]+)?$`)
	agentXOrigin = regexp.MustCompile(`[^A-Za-z0-9_-]+`)
)

// agentXRuntime resolves an $XDG_RUNTIME_DIR/clipd/<sub> path unless the
// override env var is set.
func agentXRuntime(override, sub string) (string, error) {
	if d := os.Getenv(override); d != "" {
		return d, nil
	}
	base := os.Getenv("XDG_RUNTIME_DIR")
	if base == "" {
		return "", fmt.Errorf("XDG_RUNTIME_DIR unset; set %s", override)
	}
	return filepath.Join(base, "clipd", sub), nil
}

func agentXDevice() string {
	if d := os.Getenv("CLIPD_DEVICE"); d != "" {
		return d
	}
	h, _ := os.Hostname()
	h = strings.TrimLeft(agentXOrigin.ReplaceAllString(strings.SplitN(h, ".", 2)[0], "-"), "_-")
	if len(h) > 64 {
		h = h[:64]
	}
	if h == "" {
		h = "clipd"
	}
	return h
}

func agentX(args []string, errOut io.Writer, fail func(error) int, bad func() int) int {
	if len(args) > 1 {
		return bad()
	}
	dpy := os.Getenv("CLIPD_DISPLAY")
	if len(args) == 1 {
		dpy = args[0]
	}
	if dpy == "" {
		fmt.Fprintln(errOut, "clipd: agent x: display required (argument or CLIPD_DISPLAY); inherited $DISPLAY is never used")
		return exitConfig
	}
	if !displayRe.MatchString(dpy) {
		fmt.Fprintf(errOut, "clipd: agent x: %q is not an X display name\n", dpy)
		return exitConfig
	}
	folder, err := agentXRuntime("CLIPD_FOLDER", "folder")
	if err != nil {
		fmt.Fprintln(errOut, "clipd: agent x:", err)
		return exitConfig
	}
	state, err := agentXRuntime("CLIPD_STATE_DIR", "state")
	if err != nil {
		fmt.Fprintln(errOut, "clipd: agent x:", err)
		return exitConfig
	}
	self, err := loadIdentity()
	if err != nil {
		return fail(err)
	}
	rp, err := configPath("recipients.txt")
	if err != nil {
		return fail(err)
	}
	peers, err := crypt.LoadRecipients(rp)
	if err != nil {
		fmt.Fprintln(errOut, "clipd: agent x:", err)
		return exitConfig
	}
	if err := os.MkdirAll(state, 0o700); err != nil {
		fmt.Fprintln(errOut, "clipd: agent x:", err)
		return exitConfig
	}
	release, ok, err := xsel.Lock(filepath.Join(state, "agent-x."+strings.ReplaceAll(dpy, ":", "_")+".lock"))
	if err != nil {
		fmt.Fprintln(errOut, "clipd: agent x: lock:", err)
		return exitConfig
	}
	if !ok {
		fmt.Fprintf(errOut, "clipd: agent x: another agent serves %s\n", dpy)
		return 0
	}
	defer release()

	lg := log.New(errOut, "clipd: ", log.LstdFlags)
	origin := agentXDevice()
	st := &store.Store{Dir: folder, Origin: origin, Self: self, Peers: peers, Cap: entry.DefaultCap, Logf: lg.Printf}
	sel := &xsel.X{Display: dpy, Xclip: os.Getenv("CLIPD_XCLIP"), Clipnotify: os.Getenv("CLIPD_CLIPNOTIFY")}
	a := &agent.Agent{Store: st, StateDir: state, Name: dpy, Logf: lg.Printf}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	lg.Printf("agent x: serving %s as %s, folder %s, %d peers", dpy, origin, folder, len(peers))
	if err := a.RunX(ctx, sel); err != nil {
		lg.Printf("agent x: %v", err)
		if errors.Is(err, store.ErrBadOrigin) {
			return exitConfig
		}
		return exitFail
	}
	return 0
}
