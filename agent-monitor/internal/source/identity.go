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
// whose bus label deliberately is not their OS username. It is passed
// straight through as whoami's own `--label` flag (dotfiles-ng1w.11), so the
// resolved identity is that NAMED party's own record — address, kind,
// registered — never the OS-user record with the label swapped in. That is
// the only way --as can carry an address at all without a second, Go-side
// registry lookup (sp033's plan forbids one; dotfiles-3yg4 already paid for
// that duplication once).
//
// answer.User is deliberately never read to decide WHO the identity is:
// whoami always reports it as the OS user asking (`id -un`), even when
// --label names someone else entirely (dotfiles-ng1w.11's audit advisory).
// Only address/kind/registered say who was asked about; identity.User below
// carries answer.User purely as "who is running this monitor" metadata, not
// as part of the identity being resolved.
//
// Whatever the reason — a label nobody holds (registered: false), a label
// two `kind: person` parties share (whoami refuses by name, non-zero exit),
// a tombstoned label, or whoami failing for any other reason — this
// resolves to the zero Identity. There is no partial state where a Label is
// set without a matching Address: that half-identity is exactly what would
// let this file's for-you comparison and Sender.Send's --as disagree about
// who the operator is (adr0034).
func ResolveIdentity(ctx context.Context, exec Exec, as string) Identity {
	args := []string{"whoami", "--json"}
	if as != "" {
		args = append(args, "--label", as)
	}
	out, err := exec(ctx, identityBinary, args...)
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
	return identity
}
