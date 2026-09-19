package source

import (
	"context"
	"errors"
	"reflect"
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

// TestResolveIdentity_NoAsCallsWhoamiJSONOnly pins the absent-flag argv
// (criterion 4, the regression anchor): no --label is ever appended when
// --as is empty, so a whoami built before dotfiles-ng1w.11 landed sees the
// exact same invocation it always has.
func TestResolveIdentity_NoAsCallsWhoamiJSONOnly(t *testing.T) {
	stub := &stubExec{out: []byte(`{"user":"jan","label":"jan","address":"aABCDEFGHJKMNPQRSTVWXYZ012","kind":"person","registered":true}`)}

	ResolveIdentity(context.Background(), stub.run, "")

	want := []string{identityBinary, "whoami", "--json"}
	if len(stub.calls) != 1 || !reflect.DeepEqual(stub.calls[0], want) {
		t.Fatalf("got exec calls %v, want exactly one call to %v", stub.calls, want)
	}
}

// TestResolveIdentity_AsCallsWhoamiWithLabelFlag is the plumbing half of
// dotfiles-ng1w.13: --as's value must reach whoami as `--label <as>`, not be
// swallowed into a Go-side override, since that flag is the only thing that
// can turn a label into a NAMED party's own address.
func TestResolveIdentity_AsCallsWhoamiWithLabelFlag(t *testing.T) {
	stub := &stubExec{out: []byte(`{"user":"jan","label":"orchestrator","address":"aORCH0000000000000000000002","kind":"person","registered":true}`)}

	ResolveIdentity(context.Background(), stub.run, "orchestrator")

	want := []string{identityBinary, "whoami", "--json", "--label", "orchestrator"}
	if len(stub.calls) != 1 || !reflect.DeepEqual(stub.calls[0], want) {
		t.Fatalf("got exec calls %v, want exactly one call to %v", stub.calls, want)
	}
}

// TestResolveIdentity_AsResolvesNamedPartysOwnAddress is criterion 1 and the
// audit advisory together: when --label answers about a party other than
// the caller, `user` stays the OS asker (`jan`) while `address` belongs to
// the NAMED party (`orchestrator`). ResolveIdentity must report the named
// party's own address — never the caller's, and never a fabricated one —
// proving it reads address/kind/registered, not user, to decide who was
// resolved.
func TestResolveIdentity_AsResolvesNamedPartysOwnAddress(t *testing.T) {
	exec := fixedExec(`{"user":"jan","label":"orchestrator","address":"aORCH0000000000000000000002","kind":"person","registered":true}`, nil)

	got := ResolveIdentity(context.Background(), exec, "orchestrator")

	want := Identity{User: "jan", Label: "orchestrator", Address: "aORCH0000000000000000000002", Registered: true}
	if got != want {
		t.Fatalf("ResolveIdentity() = %+v, want %+v", got, want)
	}
}

// TestResolveIdentity_AsAgainstUnregisteredStaysNoIdentity is edge case 4:
// --as naming a label nobody holds cannot be verified without opening the
// registry (forbidden by ## plan's conventions), so a whoami --label answer
// that says "unregistered" stays "no identity" — never a Label set with no
// Address.
func TestResolveIdentity_AsAgainstUnregisteredStaysNoIdentity(t *testing.T) {
	exec := fixedExec(`{"user":"jan","label":"orchestrator","address":null,"kind":null,"registered":false}`, nil)

	got := ResolveIdentity(context.Background(), exec, "orchestrator")

	if got != (Identity{}) {
		t.Fatalf("ResolveIdentity() = %+v, want the zero Identity", got)
	}
}

// TestResolveIdentity_AsAgainstAmbiguousLabelDegradesToNoIdentity covers the
// other half of "no half-identity, ever": whoami refuses by name (non-zero
// exit) when two `kind: person` addresses share a label, exactly like the
// missing-binary case already pinned above. --as must degrade to the zero
// Identity here too, never surface a Label with no Address.
func TestResolveIdentity_AsAgainstAmbiguousLabelDegradesToNoIdentity(t *testing.T) {
	exec := fixedExec("", errors.New("'shared' is worn by 2 `kind: person` addresses in this project"))

	got := ResolveIdentity(context.Background(), exec, "shared")

	if got != (Identity{}) {
		t.Fatalf("ResolveIdentity() = %+v, want the zero Identity", got)
	}
}
