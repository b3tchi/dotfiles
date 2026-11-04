// Command clipd is the cross-host clipboard agent ([[ft018]], sp039,
// adr0039). This file is subcommand dispatch only; the work lives in
// internal/. Task 2 adds keygen and recipients; agent, list, pick and
// status arrive with Tasks 4-8.
//
// Config lives in os.UserConfigDir()/clipd — ~/.config/clipd on Linux,
// %APPDATA%\clipd on Windows — overridable with $CLIPD_CONFIG_DIR.
//
// Exit codes: 0 ok, 1 operation refused or failed, 2 usage, 78 config
// unusable (EX_CONFIG: identity missing, unreadable or too permissive).
package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"filippo.io/age"

	"clipd/internal/crypt"
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
  clipd recipients list         print pinned recipients`

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
		errors.Is(err, fs.ErrNotExist), errors.Is(err, fs.ErrPermission):
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
