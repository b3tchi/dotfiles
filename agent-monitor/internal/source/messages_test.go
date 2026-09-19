package source

import (
	"context"
	"encoding/json"
	"errors"
	"os"
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
