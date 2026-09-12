// messages.go samples `pi-worker messages --json`: the whole project's bus,
// newest-last. Unlike census.go's gated Poll, there is no --if-changed
// equivalent here — the bus is local file reads, cheap enough to re-read in
// full on every tick (sp030 T9 design note) — so Poll always execs and
// always returns a real sample or a real error, never a gate's "unchanged".
package source

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"time"
)

// Message is one envelope, in the shape `pi-worker messages --json` emits:
// {at, id, from, to, kind, content}. Content stays a json.RawMessage — the
// transport interprets no content (adr0028), and this package is not the
// transport either; only render.DeriveSubject ever looks inside it, and only
// exactly as far as its documented derivation rules go.
type Message struct {
	At      string          `json:"at"`
	ID      string          `json:"id"`
	From    string          `json:"from"`
	To      []string        `json:"to"`
	Kind    string          `json:"kind"`
	Content json.RawMessage `json:"content"`
}

const messagesBinary = "pi-worker"

// ParseMessages decodes one `pi-worker messages --json` payload. An empty or
// whitespace-only payload is a genuine empty bus (pi-worker's own `messages`
// verb prints `[]` for an empty project, but a defensive empty-string check
// costs nothing and matches the empty-bus edge case: "empty list, exit 0,
// not an error").
//
// Ids are ULIDs, lexically sortable by construction, and pi-worker's own
// `bus-messages` already returns them sorted by filename (= id). ParseMessages
// re-sorts anyway — cheap, and it means this package's ordering contract
// does not silently depend on a future pi-worker build preserving its own
// internal sort.
func ParseMessages(data []byte) ([]Message, error) {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 {
		return []Message{}, nil
	}
	var msgs []Message
	if err := json.Unmarshal(trimmed, &msgs); err != nil {
		return nil, fmt.Errorf("agent-monitor: parse messages payload: %w", err)
	}
	sort.SliceStable(msgs, func(i, j int) bool { return msgs[i].ID < msgs[j].ID })
	return msgs, nil
}

// MessageSample is one full frame of the message pane: the envelopes
// pi-worker reported, and when the frame was captured. Same freshness
// reasoning as source.Sample (census.go): the payload carries no per-row
// staleness marker of its own, so the sample's own capture time is the only
// honest age this pane can show.
type MessageSample struct {
	Messages []Message
	At       time.Time
}

// MessagesAvailable checks pi-worker is on PATH. Called once at startup,
// exactly like Available() for agent-census — adr0014 guard 1: a missing
// binary is not something a retry fixes.
func MessagesAvailable() error {
	if _, err := exec.LookPath(messagesBinary); err != nil {
		return fmt.Errorf("agent-monitor: %s not found on PATH: %w", messagesBinary, err)
	}
	return nil
}

// MessagesSampler wraps the one way agent-monitor asks pi-worker for a
// frame: `pi-worker messages --json`, ungated, every tick.
type MessagesSampler struct {
	Exec Exec
}

// NewMessagesSampler builds a MessagesSampler against the real pi-worker
// binary.
func NewMessagesSampler() *MessagesSampler {
	return &MessagesSampler{Exec: RealExec}
}

// Poll execs `pi-worker messages --json` and parses the result. There is no
// --if-changed flag to pass — pi-worker's messages verb has no gate
// equivalent, and does not need one: it is a local file read, not a
// per-account `claude` invocation.
func (s *MessagesSampler) Poll(ctx context.Context) (*MessageSample, error) {
	out, err := s.Exec(ctx, messagesBinary, "messages", "--json")
	if err != nil {
		return nil, err
	}
	msgs, err := ParseMessages(out)
	if err != nil {
		return nil, err
	}
	return &MessageSample{Messages: msgs, At: time.Now()}, nil
}

// MessagesMonitor holds the last good message sample and whether it is
// stale, with the same never-blank contract as census.go's Monitor: a failed
// Tick leaves Last() exactly as it was and sets Stale(), never invents an
// empty frame.
type MessagesMonitor struct {
	sampler *MessagesSampler
	last    *MessageSample
	stale   bool
}

// NewMessagesMonitor builds a MessagesMonitor over the given sampler.
func NewMessagesMonitor(sampler *MessagesSampler) *MessagesMonitor {
	return &MessagesMonitor{sampler: sampler}
}

// Last returns the most recent sample that ever parsed successfully, or nil
// before the first one lands.
func (m *MessagesMonitor) Last() *MessageSample { return m.last }

// Stale reports whether the last poll attempt failed. The previous sample
// (if any) is still in Last() — staleness is a flag on it, not a replacement.
func (m *MessagesMonitor) Stale() bool { return m.stale }

// Tick runs one poll and reports whether the displayed frame changed.
func (m *MessagesMonitor) Tick(ctx context.Context) bool {
	sample, err := m.sampler.Poll(ctx)
	if err != nil {
		m.stale = true
		return false
	}
	m.last = sample
	m.stale = false
	return true
}

// RunMessagesLoop drives one clock against a MessagesMonitor until ctx is
// cancelled. Unlike census's RunLoop there is only one clock here: the
// messages verb has no gate to bound a second, slower clock against — see
// Poll's doc comment.
//
// It carries adr0014's three guards, named exactly as census.go's RunLoop
// does:
//
//   - guard 1, fail fast on unrecoverable setup: MessagesAvailable() is
//     checked once, before this loop is ever started (cmd/agent-monitor/main.go),
//     never retried from inside the loop.
//   - guard 2, a sleep floor on every iteration: the ticker's own interval is
//     its floor. No failure inside Tick can make the loop exec faster than
//     once per interval.
//   - guard 3, retry bounded by a timer outside the loop: a failed Tick is
//     retried only on the ticker's own next firing, never inline.
func RunMessagesLoop(ctx context.Context, m *MessagesMonitor, interval time.Duration, onTick func(changed bool)) {
	ticker := time.NewTicker(interval) // guard 2: sleep floor
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			changed := m.Tick(ctx) // guard 3: bounded retry, next tick only
			if onTick != nil {
				onTick(changed)
			}
		}
	}
}
