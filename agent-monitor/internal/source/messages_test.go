package source

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixture is a captured `pi-worker messages --json` payload (the first three
// rows, taken from a live project bus on 2026-09-10, with the one real
// pi-worker session UUID and its window name replaced by synthetic
// placeholders — 00000000-0000-4000-8000-00000000000N, the style already
// used in tests/agent-census/fixtures/pi-workers.json) with one hand-added
// multi-recipient row appended (the live bus had none at capture time, and
// the test plan requires asserting one) — see testdata/messages.json.
func fixture(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("testdata/messages.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	return data
}

func TestParseMessages_OrdersById(t *testing.T) {
	msgs, err := ParseMessages(fixture(t))
	if err != nil {
		t.Fatalf("ParseMessages: %v", err)
	}
	if len(msgs) != 4 {
		t.Fatalf("got %d messages, want 4", len(msgs))
	}
	for i := 1; i < len(msgs); i++ {
		if msgs[i-1].ID >= msgs[i].ID {
			t.Fatalf("messages not in ascending id order at %d: %q >= %q", i, msgs[i-1].ID, msgs[i].ID)
		}
	}
}

func TestParseMessages_AllSixFields(t *testing.T) {
	msgs, err := ParseMessages(fixture(t))
	if err != nil {
		t.Fatalf("ParseMessages: %v", err)
	}
	first := msgs[0]
	if first.At == "" || first.ID == "" || first.From == "" || first.Kind == "" {
		t.Fatalf("missing scalar field(s): %+v", first)
	}
	if len(first.To) != 1 || first.To[0] != "smoke-1" {
		t.Fatalf("got To=%v, want [smoke-1]", first.To)
	}
	var content string
	if err := json.Unmarshal(first.Content, &content); err != nil || content != "ping-verify" {
		t.Fatalf("got content %s, want \"ping-verify\"", first.Content)
	}
}

func TestParseMessages_MultiRecipientRow_KeepsFullList(t *testing.T) {
	msgs, err := ParseMessages(fixture(t))
	if err != nil {
		t.Fatalf("ParseMessages: %v", err)
	}
	var fanout *Message
	for i := range msgs {
		if msgs[i].From == "smoke-operator" {
			fanout = &msgs[i]
		}
	}
	if fanout == nil {
		t.Fatalf("multi-recipient row not found")
	}
	if len(fanout.To) != 2 || fanout.To[0] != "peer-1" || fanout.To[1] != "peer-2" {
		t.Fatalf("got To=%v, want [peer-1 peer-2] (never silently just the first)", fanout.To)
	}
}

func TestParseMessages_ObjectContent_PassedThroughOpaque(t *testing.T) {
	// adr0028: content is opaque. The third fixture row carries an object
	// (status/summary/...) under kind "message" — ParseMessages must not
	// interpret it, just carry the raw bytes through.
	msgs, err := ParseMessages(fixture(t))
	if err != nil {
		t.Fatalf("ParseMessages: %v", err)
	}
	var got struct {
		Status  string `json:"status"`
		Summary string `json:"summary"`
	}
	found := false
	for _, m := range msgs {
		if m.From == "smoke-1" {
			if err := json.Unmarshal(m.Content, &got); err != nil {
				t.Fatalf("content not valid JSON: %v", err)
			}
			found = true
		}
	}
	if !found {
		t.Fatalf("object-content row not found")
	}
	if got.Status != "complete" || got.Summary != "delivered" {
		t.Fatalf("got %+v, want status=complete summary=delivered", got)
	}
}

// sp033 T1: bus-messages now publishes from_address/to_addresses alongside
// the rendered from/to. This fixture is inline rather than testdata/
// messages.json, which deliberately stays in the pre-T1 shape so it can
// double as the missing-fields fixture below.
const addressFieldsFixture = `[
  {
    "at": "2026-09-19T00:00:00Z",
    "id": "01M24E11K5M3AYPRFHRVH70394",
    "from": "impl-1",
    "to": ["impl-2"],
    "kind": "inbox",
    "content": "hello",
    "from_address": "aADDR0000000000000000000001",
    "to_addresses": ["aADDR0000000000000000000002"]
  },
  {
    "at": "2026-09-19T00:01:00Z",
    "id": "01M24E67X055CVGG48A3ZDXT2E",
    "from": "retired-label",
    "to": ["impl-2", "impl-3"],
    "kind": "inbox",
    "content": "signing off",
    "from_address": "aADDR0000000000000000000009",
    "to_addresses": ["aADDR0000000000000000000002", "aADDR0000000000000000000003"]
  }
]`

func TestParseMessages_AddressFieldsPopulated(t *testing.T) {
	msgs, err := ParseMessages([]byte(addressFieldsFixture))
	if err != nil {
		t.Fatalf("ParseMessages: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("got %d messages, want 2", len(msgs))
	}

	first := msgs[0]
	if first.FromAddress != "aADDR0000000000000000000001" {
		t.Fatalf("got FromAddress=%q, want aADDR0000000000000000000001", first.FromAddress)
	}
	if len(first.ToAddresses) != 1 || first.ToAddresses[0] != "aADDR0000000000000000000002" {
		t.Fatalf("got ToAddresses=%v, want [aADDR0000000000000000000002]", first.ToAddresses)
	}

	// The tombstone case: From renders the (possibly tombstoned) label while
	// FromAddress reports the sender's raw address regardless — the two
	// fields are allowed to disagree on purpose.
	second := msgs[1]
	if second.From != "retired-label" {
		t.Fatalf("got From=%q, want retired-label (the rendered label)", second.From)
	}
	if second.FromAddress != "aADDR0000000000000000000009" {
		t.Fatalf("got FromAddress=%q, want aADDR0000000000000000000009", second.FromAddress)
	}
	if len(second.ToAddresses) != 2 || second.ToAddresses[0] != "aADDR0000000000000000000002" || second.ToAddresses[1] != "aADDR0000000000000000000003" {
		t.Fatalf("got ToAddresses=%v, want two addresses in order", second.ToAddresses)
	}
}

func TestParseMessages_MissingAddressFieldsAreEmptyNotAnError(t *testing.T) {
	// testdata/messages.json predates from_address/to_addresses entirely —
	// exactly the shape an older pi-worker on PATH still emits. Criterion 3:
	// this must degrade to empty values, never a parse error.
	msgs, err := ParseMessages(fixture(t))
	if err != nil {
		t.Fatalf("ParseMessages on a pre-T1 payload must not error: %v", err)
	}
	if len(msgs) != 4 {
		t.Fatalf("got %d messages, want 4", len(msgs))
	}
	for i, m := range msgs {
		if m.FromAddress != "" {
			t.Fatalf("message %d: got FromAddress=%q, want empty on a payload missing the field", i, m.FromAddress)
		}
		if len(m.ToAddresses) != 0 {
			t.Fatalf("message %d: got ToAddresses=%v, want empty on a payload missing the field", i, m.ToAddresses)
		}
	}
}

func TestParseMessages_EmptyPayload_EmptyListNotError(t *testing.T) {
	msgs, err := ParseMessages([]byte(""))
	if err != nil {
		t.Fatalf("ParseMessages(empty): %v", err)
	}
	if len(msgs) != 0 {
		t.Fatalf("got %d messages, want 0", len(msgs))
	}

	msgs, err = ParseMessages([]byte("[]"))
	if err != nil {
		t.Fatalf("ParseMessages([]): %v", err)
	}
	if len(msgs) != 0 {
		t.Fatalf("got %d messages, want 0", len(msgs))
	}
}

func TestParseMessages_Malformed_ReturnsError(t *testing.T) {
	_, err := ParseMessages([]byte("not json"))
	if err == nil {
		t.Fatalf("expected an error for malformed payload")
	}
}

// --- MessagesSampler / MessagesMonitor: no gate, ungated read every tick ---

func TestMessagesSampler_Poll_ExecsMessagesJSON_NoGateFlags(t *testing.T) {
	var gotName string
	var gotArgs []string
	sampler := &MessagesSampler{Exec: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		gotName = name
		gotArgs = args
		return []byte("[]"), nil
	}}
	if _, err := sampler.Poll(context.Background()); err != nil {
		t.Fatalf("Poll: %v", err)
	}
	if gotName != "pi-worker" {
		t.Fatalf("got binary %q, want pi-worker", gotName)
	}
	for _, forbidden := range []string{"--fast", "--if-changed"} {
		for _, a := range gotArgs {
			if a == forbidden {
				t.Fatalf("args %v contain gate flag %q; messages has no --if-changed equivalent", gotArgs, forbidden)
			}
		}
	}
	if len(gotArgs) != 2 || gotArgs[0] != "messages" || gotArgs[1] != "--json" {
		t.Fatalf("got args %v, want [messages --json]", gotArgs)
	}
}

func TestMessagesMonitor_NeverBlanksOnFailure(t *testing.T) {
	good := fixture(t)
	stub := &stubExec{out: good}
	sampler := &MessagesSampler{Exec: stub.run}
	m := NewMessagesMonitor(sampler)

	if !m.Tick(context.Background()) {
		t.Fatalf("first tick should report changed=true")
	}
	if m.Last() == nil || len(m.Last().Messages) != 4 {
		t.Fatalf("expected 4 messages after first tick")
	}
	if m.Stale() {
		t.Fatalf("should not be stale after a good tick")
	}

	failStub := &stubExec{err: errors.New("boom")}
	sampler.Exec = failStub.run
	if m.Tick(context.Background()) {
		t.Fatalf("failing tick should report changed=false")
	}
	if m.Last() == nil || len(m.Last().Messages) != 4 {
		t.Fatalf("a failed tick must not blank the previous sample")
	}
	if !m.Stale() {
		t.Fatalf("should be stale after a failed tick")
	}
}

// writeSendStub drops an executable shell script named `pi-worker` into dir
// — the real-subprocess twin of stubExec above, needed here because the
// argv/metacharacter cases (sp033 T9) have to prove exec.Command never
// invokes a shell, which a Go-level stub cannot: a `sh -c` shortcut and a
// direct exec.Command call look identical to a Go func stub that just
// records the (name, args) it was handed, but they differ the moment a real
// `$`, backtick or embedded newline reaches an actual process. This is a
// small local copy of cmd/agent-monitor/main_test.go's own writeStub rather
// than a shared export — a source-internal test helper reaching into cmd/
// would invert this package's own dependency direction.
func writeSendStub(t *testing.T, dir, script string) {
	t.Helper()
	p := filepath.Join(dir, "pi-worker")
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatalf("write pi-worker stub: %v", err)
	}
}

// readNullSeparated reads a NUL-delimited argv dump written by the stub
// scripts below (`printf '%s\0' "$a"` per argument) — NUL is the one byte
// that cannot appear inside a Unix argv element, so it is the only safe
// delimiter for an argument that may itself contain a literal newline
// (TestSend_BodyWithMetacharactersArrivesIntact).
func readNullSeparated(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	parts := strings.Split(string(data), "\x00")
	if len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

func withStubPath(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// TestSend_ArgvShape is the test_plan's argv case: a stub `pi-worker`
// records every argv element it received, and this asserts the exact five
// flags ft014's `main send` documents plus the verb, with the body arriving
// as ONE argument — not a shell-quoted fragment of a longer string a `sh -c`
// implementation would produce instead.
func TestSend_ArgvShape(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "argv.out")
	writeSendStub(t, dir, "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done > \""+out+"\"\n")
	withStubPath(t, dir)

	sender := &Sender{Exec: RealExec}
	if err := sender.Send(context.Background(), "addr-from", "addr-to", "hello world"); err != nil {
		t.Fatalf("Send: %v", err)
	}

	got := readNullSeparated(t, out)
	want := []string{"send", "--as", "addr-from", "--to", "addr-to", "--content", "hello world"}
	if len(got) != len(want) {
		t.Fatalf("got argv %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got argv %v, want %v", got, want)
		}
	}
}

// TestSend_BodyWithMetacharactersArrivesIntact is criterion 5 against a real
// subprocess: quotes, `$`, a backtick and an embedded newline all reach
// pi-worker's argv exactly as typed, because exec.Command never hands
// anything to a shell to re-interpret.
func TestSend_BodyWithMetacharactersArrivesIntact(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "argv.out")
	writeSendStub(t, dir, "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done > \""+out+"\"\n")
	withStubPath(t, dir)

	body := "quote\" dollar$VAR backtick`whoami` newline\nend"
	sender := &Sender{Exec: RealExec}
	if err := sender.Send(context.Background(), "me", "you", body); err != nil {
		t.Fatalf("Send: %v", err)
	}

	got := readNullSeparated(t, out)
	if len(got) != 7 {
		t.Fatalf("got argv %v, want 7 elements", got)
	}
	if got[6] != body {
		t.Fatalf("got body arg %q, want %q byte-identical", got[6], body)
	}
}

// TestSend_NonZeroExitReturnsStderr proves the real extraction path: a
// stub that exits non-zero after writing to stderr, run through RealExec's
// actual cmd.Output() (which populates *exec.ExitError.Stderr), comes back
// as an error whose message IS that stderr text — not "exit status 1", and
// not silently swallowed (dotfiles-oj4c, dotfiles-9oa4).
func TestSend_NonZeroExitReturnsStderr(t *testing.T) {
	dir := t.TempDir()
	writeSendStub(t, dir, "#!/bin/sh\necho 'send refused: unknown recipient' >&2\nexit 1\n")
	withStubPath(t, dir)

	sender := &Sender{Exec: RealExec}
	err := sender.Send(context.Background(), "me", "ghost", "hi")
	if err == nil {
		t.Fatalf("expected an error")
	}
	if err.Error() != "send refused: unknown recipient" {
		t.Fatalf("got error %q, want the CLI's stderr verbatim", err.Error())
	}
}

// TestSend_MissingBinaryIsAnErrorNotAPanic covers pi-worker disappearing
// from PATH mid-session (## edge_cases): PATH points at an empty directory,
// so the underlying error is a LookPath failure (*exec.Error, not
// *exec.ExitError) — Send's errors.As branch must not match it, and must
// not panic either.
func TestSend_MissingBinaryIsAnErrorNotAPanic(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir)

	sender := &Sender{Exec: RealExec}
	err := sender.Send(context.Background(), "me", "you", "hi")
	if err == nil {
		t.Fatalf("expected an error when pi-worker is not on PATH")
	}
}
