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
	// (status/summary/...) under kind "inbox" — ParseMessages must not
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
