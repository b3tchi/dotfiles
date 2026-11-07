// Command clipd is the cross-host clipboard agent ([[ft018]], sp039,
// adr0039). This file is subcommand dispatch only; the work lives in
// internal/.
//
// Config lives in os.UserConfigDir()/clipd — ~/.config/clipd on Linux,
// %APPDATA%\clipd on Windows — overridable with $CLIPD_CONFIG_DIR.
//
// Exit codes: 0 ok, 1 operation refused or failed, 2 usage, 78 config
// unusable (EX_CONFIG: identity missing, unreadable or too permissive).
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"filippo.io/age"

	"clipd/internal/crypt"
	"clipd/internal/entry"
	"clipd/internal/status"
	"clipd/internal/store"
)

const (
	exitFail   = 1
	exitUsage  = 2
	exitConfig = 78
)

const usage = `usage:
  clipd keygen                  create this device's age identity
  clipd recipients add <age1…>  pin a peer's recipient
  clipd recipients rm <age1…>   unpin a peer's recipient
  clipd recipients list         print pinned recipients
  clipd status                  peer heartbeats + Syncthing link (exit 0 ok, 3 stale, 4 syncthing unreachable)
  clipd agent windows           watch the Windows clipboard, write entries
  clipd agent x <display>       watch that X display's CLIPBOARD
  clipd list                    live remote entries: id, origin, age-s, preview
  clipd pick <id>|--latest [display]
                                put an entry on the native clipboard
                                (X: display, or CLIPD_DISPLAY, is required)`

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func configDir() (string, error) {
	if d := os.Getenv("CLIPD_CONFIG_DIR"); d != "" {
		return d, nil
	}
	d, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "clipd"), nil
}

func configPath(name string) (string, error) {
	d, err := configDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, name), nil
}

func loadIdentity() (*age.X25519Identity, error) {
	p, err := configPath("identity.txt")
	if err != nil {
		return nil, err
	}
	return crypt.LoadIdentity(p)
}

// exitFor maps an error to the exit code callers (clipd.nu, qs-clip.sh)
// branch on.
func exitFor(err error) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, crypt.ErrPerms), errors.Is(err, crypt.ErrBadIdentity),
		errors.Is(err, fs.ErrNotExist), errors.Is(err, fs.ErrPermission),
		errors.Is(err, errNoRuntimeDir):
		return exitConfig
	default:
		return exitFail
	}
}

func run(args []string, out, errOut io.Writer) int {
	fail := func(err error) int {
		fmt.Fprintln(errOut, "clipd:", err)
		return exitFor(err)
	}
	bad := func() int {
		fmt.Fprintln(errOut, usage)
		return exitUsage
	}
	if len(args) == 0 {
		return bad()
	}
	switch args[0] {
	case "keygen":
		if len(args) != 1 {
			return bad()
		}
		p, err := configPath("identity.txt")
		if err != nil {
			return fail(err)
		}
		rcpt, err := crypt.Keygen(p)
		if err != nil {
			// Overwriting would orphan every peer's pin: refuse, never 78.
			fmt.Fprintln(errOut, "clipd:", err)
			return exitFail
		}
		fmt.Fprintln(out, rcpt)
		return 0
	case "recipients":
		return recipients(args[1:], out, errOut, fail, bad)
	case "status":
		if len(args) != 1 {
			return bad()
		}
		return statusCmd(out, errOut, fail)
	case "agent":
		if len(args) < 2 {
			return bad()
		}
		switch args[1] {
		case "windows":
			return agentWindows(args[2:], errOut, fail, bad)
		case "x":
			return agentX(args[2:], errOut, fail, bad)
		}
		return bad()
	case "list":
		return listCmd(args[1:], out, fail, bad)
	case "pick":
		return pickCmd(args[1:], errOut, fail, bad)
	default:
		return bad()
	}
}

func recipients(args []string, out, errOut io.Writer, fail func(error) int, bad func() int) int {
	if len(args) == 0 {
		return bad()
	}
	p, err := configPath("recipients.txt")
	if err != nil {
		return fail(err)
	}
	switch {
	case args[0] == "list" && len(args) == 1:
		list, err := crypt.ListRecipients(p)
		if err != nil {
			return fail(err)
		}
		for _, r := range list {
			fmt.Fprintln(out, r)
		}
		return 0
	case args[0] == "add" && len(args) == 2:
		if err := crypt.AddRecipient(p, args[1]); err != nil {
			return fail(err)
		}
		return 0
	case args[0] == "rm" && len(args) == 2:
		removed, err := crypt.RemoveRecipient(p, args[1])
		if err != nil {
			return fail(err)
		}
		if !removed {
			fmt.Fprintln(errOut, "clipd: recipient not pinned")
			return exitFail
		}
		return 0
	default:
		return bad()
	}
}

// deviceName is this device's origin: $CLIPD_DEVICE, else the hostname
// reduced to the store's origin alphabet.
func deviceName() string {
	if d := os.Getenv("CLIPD_DEVICE"); d != "" {
		return d
	}
	h, _ := os.Hostname()
	h = regexp.MustCompile(`[^A-Za-z0-9_-]+`).ReplaceAllString(strings.SplitN(h, ".", 2)[0], "-")
	h = strings.TrimLeft(h, "_-")
	if len(h) > 64 {
		h = h[:64]
	}
	if h == "" {
		h = "clipd"
	}
	return h
}

// syncFolder is the Syncthing folder: $CLIPD_FOLDER, else tmpfs
// $XDG_RUNTIME_DIR/clipd/folder on Linux, %LOCALAPPDATA%\clipd\folder on
// Windows (sp039 plan, runtime paths).
func syncFolder() (string, error) {
	if d := os.Getenv("CLIPD_FOLDER"); d != "" {
		return d, nil
	}
	base, env := os.Getenv("XDG_RUNTIME_DIR"), "XDG_RUNTIME_DIR"
	if runtime.GOOS == "windows" {
		base, env = os.Getenv("LOCALAPPDATA"), "LOCALAPPDATA"
	}
	if base == "" {
		return "", fmt.Errorf("%w: %s unset; set CLIPD_FOLDER", errNoRuntimeDir, env)
	}
	return filepath.Join(base, "clipd", "folder"), nil
}

func statusCmd(out, errOut io.Writer, fail func(error) int) int {
	self, err := loadIdentity()
	if err != nil {
		return fail(err)
	}
	rp, err := configPath("recipients.txt")
	if err != nil {
		return fail(err)
	}
	pins, err := crypt.ListRecipients(rp)
	if err != nil {
		return fail(err)
	}
	pinned := 0
	for _, r := range pins {
		if r != self.Recipient().String() {
			pinned++
		}
	}
	in := status.Input{Self: deviceName(), Pinned: pinned, Now: time.Now(), Heartbeats: map[string]time.Time{}}

	// Heartbeats: each device's own evidence. A missing folder leaves
	// every peer "never" — reported, not fatal.
	if dir, err := syncFolder(); err != nil {
		fmt.Fprintln(errOut, "clipd: sync folder:", err)
	} else {
		st := &store.Store{Dir: dir, Origin: in.Self, Self: self, Cap: entry.DefaultCap,
			Logf: func(f string, a ...any) { fmt.Fprintf(errOut, "clipd: "+f+"\n", a...) }}
		hbs, _, err := st.Heartbeats()
		if err != nil {
			fmt.Fprintln(errOut, "clipd:", err)
		}
		for o, e := range hbs {
			in.Heartbeats[o] = time.UnixMilli(e.Created)
		}
	}

	// Syncthing link: a third party's view, shown but never trusted alone.
	paths := status.ConfigPaths()
	if p := os.Getenv("CLIPD_SYNCTHING_CONFIG"); p != "" {
		paths = []string{p}
	}
	stc, err := status.FindConfig(paths)
	if err == nil {
		stc.FolderID = "clipd"
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		in.Links, err = stc.Links(ctx)
		cancel()
	}
	in.LinkErr = err

	rep := status.Evaluate(in)
	rep.Write(out)
	return rep.Exit
}
