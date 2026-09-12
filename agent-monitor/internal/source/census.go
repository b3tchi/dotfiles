// Package source samples the published CLI surfaces agent-monitor renders.
// It execs a supported command-line interface and parses its JSON — nothing
// here reads a runtime directory layout directly. See the file tree note in
// sp030's plan: "Consumers read the supported surface."
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

// Row is one agent, in the shape agent-census's --json --detail emits.
// Field names mirror the action's detail-rows / pi-detail-row output
// (nushell/actions/agent-census) so json.Unmarshal needs no translation
// layer.
type Row struct {
	Project string `json:"project"`
	Account string `json:"account"`
	Kind    string `json:"kind"`
	State   string `json:"state"`  // job axis (background/bus work)
	Status  string `json:"status"` // process axis (self-reported activity)
	Bucket  string `json:"bucket"`
	Name    string `json:"name"`
	CWD     string `json:"cwd"`
	PID     *int   `json:"pid"`
	How     string `json:"how"`
	Runtime string `json:"runtime"`
	UID     string `json:"uid"`
	Role    string `json:"role"`
	Branch  string `json:"branch"`
}

// bucketPriority orders buckets so rows needing attention sort first.
// Anything not listed here (a bucket this build has never seen) sorts last,
// alongside "other" — never dropped, never promoted above a real blocker.
var bucketPriority = map[string]int{
	"blocked": 0,
	"working": 1,
	"idle":    2,
	"done":    3,
	"other":   4,
}

func priorityOf(bucket string) int {
	if p, ok := bucketPriority[bucket]; ok {
		return p
	}
	return len(bucketPriority) // unrecognised bucket: sorts after every known one
}

// SortRows orders rows blocked-first, then by the remaining bucket priority,
// with a stable, deterministic tie-break (project then uid/name) so two
// samples of the same world render identically.
func SortRows(rows []Row) {
	sort.SliceStable(rows, func(i, j int) bool {
		pi, pj := priorityOf(rows[i].Bucket), priorityOf(rows[j].Bucket)
		if pi != pj {
			return pi < pj
		}
		if rows[i].Project != rows[j].Project {
			return rows[i].Project < rows[j].Project
		}
		return displayName(rows[i]) < displayName(rows[j])
	})
}

// displayName is the uid/name column value: a pi row's Name already carries
// its uid (pi-detail-row sets name from uid), so this is just Name for both
// runtimes today. Kept as a function rather than inlined so the roster
// renderer and the sort share one definition of "what identifies a row".
func displayName(r Row) string {
	return r.Name
}

// DisplayName exports displayName for the render package.
func DisplayName(r Row) string { return displayName(r) }

// ParseRows decodes one agent-census --json --detail payload. An empty or
// whitespace-only payload is the --if-changed gate's "unchanged" signal, not
// a zero-row sample, and callers must check for it BEFORE calling ParseRows
// (Poll does this). ParseRows itself is only ever handed real JSON.
func ParseRows(data []byte) ([]Row, error) {
	var rows []Row
	if err := json.Unmarshal(data, &rows); err != nil {
		return nil, fmt.Errorf("agent-monitor: parse census payload: %w", err)
	}
	SortRows(rows)
	return rows, nil
}

// Sample is one full frame of the roster: the rows agent-census reported,
// and when the frame was captured. Age is derived from At relative to the
// caller's clock, never invented — the source payload carries no per-row
// timestamp (nothing upstream promises one), so a sample's own capture time
// is the only honest freshness signal available.
//
// At is a truthful staleness bound for pi rows too, not only claude's,
// despite the --if-changed gate being blind to pi (dotfiles-eee4): every
// actual agent-census invocation — whether the gate let a Poll through, or
// RunLoop's bound clock forced one — re-probes pi unconditionally
// (nushell/actions/agent-census's probe-all calls probe-pi-workers with no
// --fast/--if-changed conditional at all). So a Sample never carries a pi
// reading older than At; what dotfiles-eee4 actually threatens is CADENCE
// (an execution might not happen often enough), which RunLoop's bound clock
// bounds, not the freshness label on data that WAS returned. See
// TestPoll_GatedSuccessCarriesFreshPiRows for the pinned proof.
type Sample struct {
	Rows []Row
	At   time.Time
}

// Exec runs one command and returns its stdout. Swapped out in tests for a
// stub that never touches a real binary.
type Exec func(ctx context.Context, name string, args ...string) ([]byte, error)

// RealExec shells out for real, translating a non-zero exit into an error
// the caller can act on (never a panic, never a silently swallowed failure).
func RealExec(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("agent-monitor: exec %s: %w", name, err)
	}
	return out, nil
}

const censusBinary = "agent-census"

// Sampler wraps the two ways agent-monitor asks agent-census for a frame:
// gated (cheap, ticker-driven, may report "unchanged") and forced (the `r`
// key: a full read, no --fast, no gate).
type Sampler struct {
	Exec      Exec
	StampPath string
}

// NewSampler builds a Sampler against the real agent-census binary.
func NewSampler(stampPath string) *Sampler {
	return &Sampler{Exec: RealExec, StampPath: stampPath}
}

// Available checks agent-census is on PATH. Called once at startup — this
// is adr0014 guard 1 (fail fast on unrecoverable setup) applied before the
// loop ever starts: a missing binary is not something a retry fixes, so
// agent-monitor must say so once and exit, never spin an empty UI that
// looks like "no agents".
func Available() error {
	if _, err := exec.LookPath(censusBinary); err != nil {
		return fmt.Errorf("agent-monitor: %s not found on PATH: %w", censusBinary, err)
	}
	return nil
}

// Poll execs the gated, fast probe: `agent-census --json --detail --fast
// --if-changed <stamp>`. Silence (blank stdout) means "unchanged" — the gate
// contract agent-census documents at its --if-changed flag — and Poll
// returns (nil, nil) for it. A caller that redrew from that nil as "zero
// rows" would blank the roster every tick; Poll's job is to make that
// mistake impossible to make by accident: nil-with-no-error is the ONLY
// unchanged signal, and it is never returned alongside rows.
//
// The gate is blind to pi workers (dotfiles-eee4): agent-census's
// --if-changed token fingerprints only each claude account's session/job
// files, so a pi worker spawning, changing state, publishing presence or
// exiting never opens the gate on its own. Silence from THIS call means
// "no claude account file moved" — it says nothing about pi. Do not read
// "unchanged" as "the whole world is unchanged"; that is exactly why
// RunLoop below runs a second, ungated clock to bound how stale a pi row
// can get regardless of what claude is doing.
func (s *Sampler) Poll(ctx context.Context) (*Sample, error) {
	out, err := s.Exec(ctx, censusBinary,
		"--json", "--detail", "--fast", "--if-changed", s.StampPath)
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(out)) == 0 {
		return nil, nil // unchanged: keep whatever sample the caller already has
	}
	rows, err := ParseRows(out)
	if err != nil {
		return nil, err
	}
	return &Sample{Rows: rows, At: time.Now()}, nil
}

// ForceRefresh execs the full, ungated probe: `agent-census --json --detail`
// — no --fast, no --if-changed. This is what the `r` key triggers. Unlike
// Poll, empty output here is real JSON ("[]"), a genuine zero-agent sample,
// not the gate's silence.
func (s *Sampler) ForceRefresh(ctx context.Context) (*Sample, error) {
	out, err := s.Exec(ctx, censusBinary, "--json", "--detail")
	if err != nil {
		return nil, err
	}
	rows, err := ParseRows(out)
	if err != nil {
		return nil, err
	}
	return &Sample{Rows: rows, At: time.Now()}, nil
}

// Monitor holds the last good sample and whether it is stale (its last
// refresh attempt failed). It never blanks: a failed Tick or Refresh leaves
// Last() exactly as it was, and Stale() reports the failure so the renderer
// can say so without inventing a new value.
type Monitor struct {
	sampler *Sampler
	last    *Sample
	stale   bool
}

// NewMonitor builds a Monitor over the given Sampler.
func NewMonitor(sampler *Sampler) *Monitor {
	return &Monitor{sampler: sampler}
}

// Last returns the most recent sample that ever parsed successfully, or nil
// before the first one lands.
func (m *Monitor) Last() *Sample { return m.last }

// Stale reports whether the last poll/refresh attempt failed. The previous
// sample (if any) is still in Last() — staleness is a flag on it, not a
// replacement for it.
func (m *Monitor) Stale() bool { return m.stale }

// Tick runs one gated poll and reports whether the displayed frame changed.
// - unchanged (nil, nil): Last() is untouched, Stale() cleared, changed=false.
// - failure (nil, err): Last() is untouched, Stale() set, changed=false.
// - success: Last() replaced, Stale() cleared, changed=true.
func (m *Monitor) Tick(ctx context.Context) bool {
	sample, err := m.sampler.Poll(ctx)
	if err != nil {
		m.stale = true
		return false
	}
	if sample == nil {
		// Unchanged: an old failure's staleness clears once a gated poll
		// actually succeeds again, even with nothing new to show.
		m.stale = false
		return false
	}
	m.last = sample
	m.stale = false
	return true
}

// Refresh runs one forced, ungated probe (the `r` key). Same failure
// contract as Tick: a failure leaves Last() untouched and sets Stale().
func (m *Monitor) Refresh(ctx context.Context) bool {
	sample, err := m.sampler.ForceRefresh(ctx)
	if err != nil {
		m.stale = true
		return false
	}
	m.last = sample
	m.stale = false
	return true
}

// RunLoop drives two clocks against one Monitor until ctx is cancelled:
//
//   - fast ticks call Tick — the cheap, gated poll. Correct and sufficient
//     for claude rows, which are what the gate was built to protect against
//     re-probing on every tick.
//   - bound ticks call Refresh — the full, ungated probe, on a much slower
//     cadence. This clock exists ONLY because the gate is blind to pi
//     (dotfiles-eee4, see Poll's doc): without it, a machine where claude
//     stays quiet would never re-read pi state at all, no matter how long
//     agent-monitor ran. bound is what puts a finite ceiling on pi
//     staleness. It also happens to re-validate claude, which is harmless.
//
// onTick(changed) fires after every fast or bound tick, whichever produced
// it, so a caller tracking frame age can redraw on either clock.
//
// It carries adr0014's three guards, named:
//
//   - guard 1, fail fast on unrecoverable setup: checked by Available()
//     before RunLoop is ever called (see cmd/agent-monitor/main.go) — a
//     missing dependency is not retried from inside this loop.
//   - guard 2, a sleep floor on every iteration: each ticker's own interval
//     is its floor. No failure path inside Tick or Refresh can make either
//     clock spin faster than one exec per interval. bound must be >= fast
//     (callers are expected to pass a slower bound; RunLoop does not
//     re-derive one from the other, since the two costs are deliberately
//     different by an order of magnitude, not a ratio worth computing).
//   - guard 3, retry bounded by a timer outside the loop: a failed Tick or
//     Refresh is retried only on ITS OWN ticker's next firing, never inline
//     and never immediately — the same shape adr0014 requires of a respawn.
func RunLoop(ctx context.Context, m *Monitor, fast, bound time.Duration, onTick func(changed bool)) {
	fastTicker := time.NewTicker(fast) // guard 2: sleep floor for the gated poll
	defer fastTicker.Stop()
	boundTicker := time.NewTicker(bound) // guard 2: sleep floor for the forced, pi-bounding refresh
	defer boundTicker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-fastTicker.C:
			changed := m.Tick(ctx) // guard 3: bounded retry, next fast tick only
			if onTick != nil {
				onTick(changed)
			}
		case <-boundTicker.C:
			changed := m.Refresh(ctx) // guard 3: bounded retry, next bound tick only
			if onTick != nil {
				onTick(changed)
			}
		}
	}
}
