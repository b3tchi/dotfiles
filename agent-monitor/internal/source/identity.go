// identity.go answers ONE question at startup: which bus party is the
// operator sitting at this terminal? `pi-worker whoami --json` is the only
// place that answer is computed — the registry lookup lives in pi-worker.nu,
// never here (dotfiles-3yg4 is the cost of a second copy of that layout
// written in Go, and sp033's `## plan` conventions are absolute about it) —
// so this file's whole job is to exec that verb once and parse its answer.
//
// Every way the answer can come back short of a clean positive — an
// unregistered user, a refusal (non-zero exit: outside a git repo, an
// ambiguous label, a broken `id -un`), unparseable JSON, or the binary
// missing from PATH — degrades to the zero Identity. None of those is an
// error this package propagates: per adr0017, absence of evidence is an
// observation, not licence to abort startup or to guess who is watching.
package source

import (
	"bytes"
	"context"
	"encoding/json"
)

const identityBinary = "pi-worker"

// Identity is who the monitor believes is watching it: the operator's own
// bus address, resolved once at startup and never re-derived on a tick — a
// user who registers mid-session stays unresolved until the monitor
// restarts, stated by the header's continued silence rather than a stale
// claim (sp033 T4 edge case 3). The zero value (Registered false) is "no
// identity": startup proceeds and every pane renders exactly as it did
// before this type existed (criterion 3).
type Identity struct {
	User       string
	Label      string
	Address    string
	Registered bool
}

// whoamiAnswer is `pi-worker whoami --json`'s wire shape:
// {user, label, address, kind, registered}. Address is nullable — an
// unregistered user gets `address: null` — so it unmarshals into a pointer.
// Kind is read by nobody here: the nu side already applied the
// kind == "person" rule before deciding Registered, and re-checking it in Go
// would be exactly the label-only shortcut `## plan`'s anti-patterns forbid.
type whoamiAnswer struct {
	User       string  `json:"user"`
	Label      string  `json:"label"`
	Address    *string `json:"address"`
	Registered bool    `json:"registered"`
}

// ResolveIdentity execs `pi-worker whoami --json` exactly once and returns
// the operator's identity, or the zero Identity for every way that answer
// can come back short of a clean positive. Callers invoke this ONCE at
// startup (cmd/agent-monitor/main.go) — there is no Tick/Poll pair here the
// way census.go and messages.go have one, because identity does not change
// over a session.
//
// as, when non-empty, is --as's value: the escape hatch for an operator
// whose bus label deliberately is not their OS username. It overrides the
// LABEL only, never the address — the address always comes from this same
// whoami answer, so --as never becomes a second, Go-side registry lookup.
// An --as given against an unregistered whoami answer has no address to
// attach to, so it still resolves to the zero Identity: "a label nobody
// holds" (edge case 4) is exactly what an unregistered whoami answer already
// says, and main.go's caller is what decides whether to say so on stderr.
func ResolveIdentity(ctx context.Context, exec Exec, as string) Identity {
	out, err := exec(ctx, identityBinary, "whoami", "--json")
	if err != nil {
		return Identity{}
	}
	var answer whoamiAnswer
	if err := json.Unmarshal(bytes.TrimSpace(out), &answer); err != nil {
		return Identity{}
	}
	if !answer.Registered {
		return Identity{}
	}
	identity := Identity{User: answer.User, Label: answer.Label, Registered: true}
	if answer.Address != nil {
		identity.Address = *answer.Address
	}
	if as != "" {
		identity.Label = as
	}
	return identity
}
