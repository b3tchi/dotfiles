package source

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// mixedPayload is a captured-shape fixture: two claude rows (one idle, one
// working) and three pi rows (done, blocked, running), matching the field
// set agent-census --json --detail actually emits (captured live via
// `agent-census --json --detail` while writing this task).
const mixedPayload = `[
  {"project":"copacks","account":"work","kind":"interactive","state":"","status":"idle","bucket":"idle","name":"copacks-b6","cwd":"/repos/copacks","pid":136845,"how":"pane","runtime":"claude","uid":"","role":"","branch":""},
  {"project":"copacks","account":"work","kind":"interactive","state":"","status":"busy","bucket":"working","name":"copacks-6f","cwd":"/repos/copacks","pid":3097448,"how":"pane","runtime":"claude","uid":"","role":"","branch":""},
  {"project":"dotfiles","account":"","kind":"","state":"complete","status":"","bucket":"done","name":"demo-1","cwd":"","pid":null,"how":"window","runtime":"pi","uid":"demo-1","role":"demo","branch":""},
  {"project":"dotfiles","account":"","kind":"","state":"waiting_human","status":"idle","bucket":"blocked","name":"peer-3","cwd":"","pid":null,"how":"window","runtime":"pi","uid":"peer-3","role":"peer","branch":""},
  {"project":"dotfiles","account":"","kind":"","state":"running","status":"streaming","bucket":"working","name":"peer-2","cwd":"","pid":null,"how":"window","runtime":"pi","uid":"peer-2","role":"peer","branch":""}
]`

func TestParseRows_MixedRuntimePayload(t *testing.T) {
	rows, err := ParseRows([]byte(mixedPayload))
	if err != nil {
		t.Fatalf("ParseRows: %v", err)
	}
	if len(rows) != 5 {
		t.Fatalf("got %d rows, want 5", len(rows))
	}

	var claude, pi int
	for _, r := range rows {
		switch r.Runtime {
		case "claude":
			claude++
		case "pi":
			pi++
		default:
			t.Errorf("row %q has unexpected runtime %q", r.Name, r.Runtime)
		}
	}
	if claude != 2 || pi != 3 {
		t.Fatalf("got claude=%d pi=%d, want claude=2 pi=3", claude, pi)
	}

	// A pi row's fields (uid/role) round-trip; a claude row's do not exist
	// (blank), rather than being fabricated.
	var peer3 *Row
	for i := range rows {
		if rows[i].Name == "peer-3" {
			peer3 = &rows[i]
		}
	}
	if peer3 == nil {
		t.Fatal("peer-3 row missing")
	}
	if peer3.UID != "peer-3" || peer3.Role != "peer" || peer3.State != "waiting_human" {
		t.Fatalf("peer-3 row wrong: %+v", peer3)
	}
}

func TestSortRows_BlockedFirst(t *testing.T) {
	rows, err := ParseRows([]byte(mixedPayload))
	if err != nil {
		t.Fatalf("ParseRows: %v", err)
	}
	// ParseRows already sorts; the fixture is deliberately NOT already in
	// blocked-first order, so this only passes if sorting actually ran.
	if rows[0].Bucket != "blocked" {
		t.Fatalf("first row bucket = %q, want %q (got order: %v)",
			rows[0].Bucket, "blocked", bucketsOf(rows))
	}
	for i := 1; i < len(rows); i++ {
		if priorityOf(rows[i-1].Bucket) > priorityOf(rows[i].Bucket) {
			t.Fatalf("rows not sorted by bucket priority at index %d: %v", i, bucketsOf(rows))
		}
	}
}

func bucketsOf(rows []Row) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.Bucket
	}
	return out
}

// stubExec records the argv it was called with and returns a canned
// (output, error) pair, so Poll/ForceRefresh can be tested without ever
// touching a real agent-census binary.
type stubExec struct {
	calls [][]string
	out   []byte
	err   error
}

func (s *stubExec) run(ctx context.Context, name string, args ...string) ([]byte, error) {
	s.calls = append(s.calls, append([]string{name}, args...))
	return s.out, s.err
}

// This is the single most important test in this package: the --if-changed
// gate's contract is "silence means unchanged", never "zero agents". A
// Monitor that redrew from an empty poll as zero rows would blank the
// roster on every tick it happened to catch between real changes. Seed a
// previous sample, feed Tick a stub that returns truly empty output (what
// the gate emits when nothing moved), and assert the previous sample
// survives completely untouched.
func TestMonitorTick_EmptyOutputMeansUnchanged(t *testing.T) {
	prev := &Sample{
		Rows: []Row{{Name: "dotfiles-ad", Runtime: "claude", Bucket: "idle"}},
		At:   time.Now().Add(-time.Minute),
	}
	stub := &stubExec{out: []byte("")} // the gate's "nothing moved" signal
	m := &Monitor{sampler: &Sampler{Exec: stub.run, StampPath: "/tmp/stamp"}, last: prev}

	changed := m.Tick(context.Background())

	if changed {
		t.Fatal("Tick reported changed=true for empty gate output")
	}
	if m.Last() != prev {
		t.Fatalf("Last() sample was replaced; got %+v, want the original prev pointer", m.Last())
	}
	if len(m.Last().Rows) != 1 {
		t.Fatalf("previous sample's rows were altered: got %d rows, want 1 (naive reading would yield 0)", len(m.Last().Rows))
	}
	if m.Stale() {
		t.Fatal("an unchanged (not failed) poll must not mark the sample stale")
	}
}

func TestMonitorTick_FailureLeavesPreviousSampleAndMarksStale(t *testing.T) {
	prev := &Sample{
		Rows: []Row{{Name: "dotfiles-ad", Runtime: "claude", Bucket: "idle"}},
		At:   time.Now().Add(-time.Minute),
	}
	stub := &stubExec{err: errors.New("exit status 1")}
	m := &Monitor{sampler: &Sampler{Exec: stub.run, StampPath: "/tmp/stamp"}, last: prev}

	changed := m.Tick(context.Background())

	if changed {
		t.Fatal("Tick reported changed=true for a failing exec")
	}
	if m.Last() != prev {
		t.Fatal("a failed poll must leave the previous sample exactly as it was")
	}
	if !m.Stale() {
		t.Fatal("a failed poll must mark the sample stale")
	}
}

func TestMonitorRefresh_Success(t *testing.T) {
	stub := &stubExec{out: []byte(mixedPayload)}
	m := &Monitor{sampler: &Sampler{Exec: stub.run, StampPath: "/tmp/stamp"}}

	changed := m.Refresh(context.Background())

	if !changed {
		t.Fatal("Refresh with a successful exec should report changed=true")
	}
	if m.Last() == nil || len(m.Last().Rows) != 5 {
		t.Fatalf("Refresh did not install the parsed sample: %+v", m.Last())
	}
	if m.Stale() {
		t.Fatal("a successful refresh must clear staleness")
	}
}

func TestPollArgs_CarryFastAndGate(t *testing.T) {
	stub := &stubExec{out: []byte("[]")}
	s := &Sampler{Exec: stub.run, StampPath: "/tmp/stamp-xyz"}

	if _, err := s.Poll(context.Background()); err != nil {
		t.Fatalf("Poll: %v", err)
	}
	if len(stub.calls) != 1 {
		t.Fatalf("expected 1 exec call, got %d", len(stub.calls))
	}
	argv := stub.calls[0]
	assertContains(t, argv, "--fast")
	assertContains(t, argv, "--if-changed")
	assertContains(t, argv, "/tmp/stamp-xyz")
}

func TestForceRefreshArgs_OmitFastAndGate(t *testing.T) {
	stub := &stubExec{out: []byte("[]")}
	s := &Sampler{Exec: stub.run, StampPath: "/tmp/stamp-xyz"}

	if _, err := s.ForceRefresh(context.Background()); err != nil {
		t.Fatalf("ForceRefresh: %v", err)
	}
	argv := stub.calls[0]
	assertNotContains(t, argv, "--fast")
	assertNotContains(t, argv, "--if-changed")
}

func assertContains(t *testing.T, argv []string, want string) {
	t.Helper()
	for _, a := range argv {
		if a == want {
			return
		}
	}
	t.Fatalf("argv %v does not contain %q", argv, want)
}

func assertNotContains(t *testing.T, argv []string, unwanted string) {
	t.Helper()
	for _, a := range argv {
		if a == unwanted {
			t.Fatalf("argv %v contains forbidden %q (forced refresh must bypass fast/gate)", argv, unwanted)
		}
	}
}

// TestSourceScan_NoForbiddenPathAccess is the success criterion asserting
// nothing under agent-monitor/ opens a runtime message-bus path, a claude
// account-config path, or shells out to the terminal multiplexer. It walks
// every non-test .go file under the module and fails if any of a handful of
// literal substrings — signatures of exactly those three things — appear.
// Comments in this package deliberately avoid spelling those literals for
// this reason: this test would otherwise trip on its own documentation.
func TestSourceScan_NoForbiddenPathAccess(t *testing.T) {
	root := moduleRoot(t)
	forbidden := []string{
		"XDG_RUNTIME_DIR",
		".claude/projects",
		"\"tmux\"",
	}

	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, f := range forbidden {
			if strings.Contains(string(data), f) {
				t.Errorf("%s contains forbidden literal %q", path, f)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", root, err)
	}
}

// moduleRoot finds the agent-monitor module root (the directory holding
// go.mod) by walking up from the current test file's package directory.
func moduleRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("could not find go.mod walking up from " + dir)
		}
		dir = parent
	}
}
