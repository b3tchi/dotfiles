package source

import (
	"context"
	"errors"
	"testing"
)

// fixedExec builds an Exec that ignores its arguments and returns a fixed
// payload/error pair. census_test.go's stubExec is a struct with the same
// purpose but also records the argv it saw, which none of these cases need.
func fixedExec(payload string, err error) Exec {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if err != nil {
			return nil, err
		}
		return []byte(payload), nil
	}
}

// TestResolveIdentity_RegisteredUser is criterion 1: a clean `whoami --json`
// positive resolves every field ResolveIdentity promises.
func TestResolveIdentity_RegisteredUser(t *testing.T) {
	exec := fixedExec(`{"user":"jan","label":"jan","address":"aABCDEFGHJKMNPQRSTVWXYZ012","kind":"person","registered":true}`, nil)

	got := ResolveIdentity(context.Background(), exec, "")

	want := Identity{User: "jan", Label: "jan", Address: "aABCDEFGHJKMNPQRSTVWXYZ012", Registered: true}
	if got != want {
		t.Fatalf("ResolveIdentity() = %+v, want %+v", got, want)
	}
}

// TestResolveIdentity_UnregisteredIsNotAnError is criterion 3's clean
// negative: `registered: false` is a real answer (adr0017), not a refusal —
// exit 0, address null — and ResolveIdentity turns it into the zero Identity
// rather than an error a caller might treat as fatal.
func TestResolveIdentity_UnregisteredIsNotAnError(t *testing.T) {
	exec := fixedExec(`{"user":"jan","label":"jan","address":null,"kind":null,"registered":false}`, nil)

	got := ResolveIdentity(context.Background(), exec, "")

	if got != (Identity{}) {
		t.Fatalf("ResolveIdentity() = %+v, want the zero Identity", got)
	}
}

// TestResolveIdentity_BadJSONDegradesToNoIdentity covers a whoami that prints
// unparseable JSON (or a shape from something other than pi-worker on PATH,
// or an older pi-worker missing fields this project never returns as valid
// JSON) — criterion 3's "no identity" degradation, never a panic or a
// propagated parse error.
func TestResolveIdentity_BadJSONDegradesToNoIdentity(t *testing.T) {
	exec := fixedExec("not json at all", nil)

	got := ResolveIdentity(context.Background(), exec, "")

	if got != (Identity{}) {
		t.Fatalf("ResolveIdentity() = %+v, want the zero Identity", got)
	}
}

// TestResolveIdentity_MissingBinaryDegradesToNoIdentity covers a whoami that
// exits non-zero — a refusal (outside a git repo, an ambiguous label under
// dotfiles-bg65's rule, a broken `id -un`) or, in production, `exec.LookPath`
// failing outright before pi-worker even runs. Either way Exec returns an
// error, and ResolveIdentity must degrade rather than propagate it —
// criterion 3's "the binary starts normally" covers both causes identically.
func TestResolveIdentity_MissingBinaryDegradesToNoIdentity(t *testing.T) {
	exec := fixedExec("", errors.New("agent-monitor: exec pi-worker: exec: \"pi-worker\": executable file not found in $PATH"))

	got := ResolveIdentity(context.Background(), exec, "")

	if got != (Identity{}) {
		t.Fatalf("ResolveIdentity() = %+v, want the zero Identity", got)
	}
}

// TestResolveIdentity_AsOverridesLabelNotAddress is criterion 2: --as renames
// the LABEL an already-resolved identity carries; it never fabricates an
// address of its own; the address stays exactly what the one whoami answer
// reported.
func TestResolveIdentity_AsOverridesLabelNotAddress(t *testing.T) {
	exec := fixedExec(`{"user":"jan","label":"jan","address":"aABCDEFGHJKMNPQRSTVWXYZ012","kind":"person","registered":true}`, nil)

	got := ResolveIdentity(context.Background(), exec, "orchestrator")

	want := Identity{User: "jan", Label: "orchestrator", Address: "aABCDEFGHJKMNPQRSTVWXYZ012", Registered: true}
	if got != want {
		t.Fatalf("ResolveIdentity() = %+v, want %+v", got, want)
	}
}

// TestResolveIdentity_AsAgainstUnregisteredStaysNoIdentity is edge case 4:
// --as naming a label nobody holds cannot be verified without opening the
// registry (forbidden by ## plan's conventions), so a whoami answer that
// says "unregistered" stays "no identity" even when --as was given — the
// escape hatch renames a resolved identity, it does not manufacture one.
func TestResolveIdentity_AsAgainstUnregisteredStaysNoIdentity(t *testing.T) {
	exec := fixedExec(`{"user":"jan","label":"jan","address":null,"kind":null,"registered":false}`, nil)

	got := ResolveIdentity(context.Background(), exec, "orchestrator")

	if got != (Identity{}) {
		t.Fatalf("ResolveIdentity() = %+v, want the zero Identity", got)
	}
}
