package agent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"filippo.io/age"

	"clipd/internal/entry"
	"clipd/internal/store"
	"clipd/internal/xsel"
)

// fakeX is an X CLIPBOARD behind a fake xsel.Runner: it records every
// xclip call so tests can assert what was (not) requested from the owner.
type fakeX struct {
	mu      sync.Mutex
	targets []string
	served  map[string][]byte
	calls   []string // xclip -t argument per call
	hang    int      // the next N TARGETS reads block until their deadline
	// after: targets swapped in once the payload was read (TOCTOU owner)
	after []string

	notify   chan error // clipnotify returns each value sent
	waits    atomic.Int32
	failWait error // when set, clipnotify fails at once with it

	// arm mode (useArm): clipnotify subscribes armDelay after it is
	// spawned, like a real process; copy() wakes only an armed waiter, so
	// a copy landing while nothing is armed produces no event at all.
	useArm   bool
	armDelay time.Duration
	waiter   chan struct{}
}

// copyText replaces the clipboard (a new owner) and, in arm mode, fires
// the armed clipnotify, if any.
func (f *fakeX) copyText(s string) {
	f.ownText(s)
	f.mu.Lock()
	if f.waiter != nil {
		close(f.waiter)
		f.waiter = nil
	}
	f.mu.Unlock()
}

func newFakeX() *fakeX { return &fakeX{notify: make(chan error, 64)} }

func (f *fakeX) own(targets []string, served map[string][]byte) {
	f.mu.Lock()
	f.targets, f.served, f.after = targets, served, nil
	f.mu.Unlock()
}

func (f *fakeX) ownText(s string) {
	f.own([]string{"TARGETS", "UTF8_STRING", "STRING"}, map[string][]byte{"UTF8_STRING": []byte(s), "STRING": []byte(s)})
}

func (f *fakeX) Output(ctx context.Context, env []string, limit int, name string, args ...string) ([]byte, error) {
	if name == "clipnotify" {
		f.waits.Add(1)
		if f.failWait != nil {
			return nil, f.failWait
		}
		if f.useArm {
			if !sleep(ctx, f.armDelay) {
				return nil, ctx.Err()
			}
			ch := make(chan struct{})
			f.mu.Lock()
			f.waiter = ch
			f.mu.Unlock()
			select {
			case <-ch:
				return nil, nil
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		select {
		case err := <-f.notify:
			return nil, err
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	target := args[len(args)-2]
	f.mu.Lock()
	f.calls = append(f.calls, target)
	hang := target == "TARGETS" && f.hang > 0
	if hang {
		f.hang--
	}
	var out []byte
	var err error
	if target == "TARGETS" {
		out = []byte(strings.Join(f.targets, "\n") + "\n")
	} else if b, ok := f.served[target]; ok {
		out = append([]byte(nil), b...)
		if f.after != nil {
			f.targets = f.after
		}
	} else {
		err = errors.New("exit status 1")
	}
	f.mu.Unlock()
	if hang {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if len(out) > limit {
		return nil, xsel.ErrTooLarge
	}
	return out, err
}

func (f *fakeX) callLog() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

type env struct {
	t     *testing.T
	x     *fakeX
	sel   *xsel.X
	st    *store.Store
	a     *Agent
	logs  *syncBuf
	state string
}

type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) logf(format string, args ...any) {
	s.mu.Lock()
	fmt.Fprintf(&s.b, format+"\n", args...)
	s.mu.Unlock()
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func newEnv(t *testing.T) *env {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	folder := filepath.Join(dir, "folder")
	if err := os.Mkdir(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	logs := &syncBuf{}
	st := &store.Store{Dir: folder, Origin: "testhost", Self: id, Cap: entry.DefaultCap, Logf: logs.logf}
	x := newFakeX()
	e := &env{
		t: t, x: x, st: st, logs: logs, state: filepath.Join(dir, "state"),
		sel: &xsel.X{Display: ":93", Timeout: 100 * time.Millisecond, Runner: x},
	}
	e.a = &Agent{Store: st, StateDir: e.state, Name: ":93", Logf: logs.logf,
		Heartbeat: time.Hour, RetryBase: 20 * time.Millisecond, RetryMax: 80 * time.Millisecond}
	if err := e.a.Init(); err != nil {
		t.Fatal(err)
	}
	return e
}

func (e *env) entries() []store.Item {
	e.t.Helper()
	items, st, err := e.st.List()
	if err != nil || st.Skipped != 0 {
		e.t.Fatalf("list: %v skipped=%d", err, st.Skipped)
	}
	return items
}

func (e *env) capture() Outcome { return e.a.CaptureX(context.Background(), e.sel) }

func TestHintGateSkipsWithoutPayloadRead(t *testing.T) {
	for _, hint := range xsel.Hints {
		t.Run(hint, func(t *testing.T) {
			e := newEnv(t)
			e.x.own([]string{"TARGETS", "UTF8_STRING", "image/png", hint},
				map[string][]byte{"UTF8_STRING": []byte("hunter2"), "image/png": []byte("png"), hint: []byte("secret")})
			if got := e.capture(); got != "" {
				t.Fatalf("outcome %q", got)
			}
			if calls := e.x.callLog(); len(calls) != 1 || calls[0] != "TARGETS" {
				t.Fatalf("xclip calls %v, want only TARGETS", calls)
			}
			if n := len(e.entries()); n != 0 {
				t.Fatalf("%d entries", n)
			}
		})
	}
}

func TestHintAfterReadDropsPayload(t *testing.T) {
	e := newEnv(t)
	e.x.ownText("benign")
	e.x.after = []string{"TARGETS", "UTF8_STRING", "application/x-kde-passwordManagerHint"}
	if got := e.capture(); got != "" {
		t.Fatalf("outcome %q", got)
	}
	if n := len(e.entries()); n != 0 {
		t.Fatalf("%d entries after TOCTOU owner swap", n)
	}
}

func TestPrefersPNG(t *testing.T) {
	e := newEnv(t)
	png := []byte("\x89PNG\r\n\x1a\nfake")
	e.x.own([]string{"TARGETS", "UTF8_STRING", "image/png"},
		map[string][]byte{"UTF8_STRING": []byte("file:///x.png"), "image/png": png})
	if got := e.capture(); got != Written {
		t.Fatalf("outcome %q", got)
	}
	calls := e.x.callLog()
	for _, c := range calls {
		if c == "UTF8_STRING" {
			t.Fatalf("text read although png advertised: %v", calls)
		}
	}
	items := e.entries()
	if len(items) != 1 || items[0].Entry.Mime != entry.MimePNG || !bytes.Equal(items[0].Entry.Data, png) {
		t.Fatalf("items %+v", items)
	}
}

func TestBMPOnlyOwnerSkipped(t *testing.T) {
	e := newEnv(t)
	e.x.own([]string{"TARGETS", "image/bmp"}, map[string][]byte{"image/bmp": []byte("BMxx")})
	if got := e.capture(); got != "" {
		t.Fatalf("outcome %q", got)
	}
	if calls := e.x.callLog(); len(calls) != 1 {
		t.Fatalf("calls %v", calls)
	}
	if n := len(e.entries()); n != 0 {
		t.Fatalf("%d entries", n)
	}
}

func TestTextRoundTripsByteExact(t *testing.T) {
	e := newEnv(t)
	s := "žluťoučký\r\n\x00tab\t"
	e.x.ownText(s)
	if got := e.capture(); got != Written {
		t.Fatalf("outcome %q", got)
	}
	items := e.entries()
	if len(items) != 1 || string(items[0].Entry.Data) != s || items[0].Entry.Mime != entry.MimeText || items[0].Entry.Origin != "testhost" {
		t.Fatalf("items %+v", items)
	}
}

func TestDedupeSameHash(t *testing.T) {
	e := newEnv(t)
	seq := []struct {
		s    string
		want Outcome
	}{{"a", Written}, {"a", Dup}, {"b", Written}, {"a", Written}, {"a", Dup}}
	for i, c := range seq {
		e.x.ownText(c.s)
		if got := e.capture(); got != c.want {
			t.Fatalf("step %d (%s): %q want %q", i, c.s, got, c.want)
		}
	}
	if n := len(e.entries()); n != 3 {
		t.Fatalf("%d entries, want 3", n)
	}
	// last-written survives a restart: a fresh agent on the same state
	// does not re-send the unchanged clipboard.
	a2 := &Agent{Store: e.st, StateDir: e.state, Name: ":93"}
	if err := a2.Init(); err != nil {
		t.Fatal(err)
	}
	if got := a2.Offer(entry.MimeText, []byte("a")); got != Dup {
		t.Fatalf("after restart: %q", got)
	}
	// ...but another display's agent has its own last-written.
	a3 := &Agent{Store: e.st, StateDir: e.state, Name: ":10"}
	if err := a3.Init(); err != nil {
		t.Fatal(err)
	}
	if got := a3.Offer(entry.MimeText, []byte("a")); got != Written {
		t.Fatalf("other display: %q", got)
	}
}

func TestEchoGuardSkipsPickedX(t *testing.T) {
	e := newEnv(t)
	if err := RecordPick(e.state, entry.MimeText, []byte("from-peer")); err != nil {
		t.Fatal(err)
	}
	e.x.ownText("from-peer")
	if got := e.capture(); got != Echo {
		t.Fatalf("outcome %q", got)
	}
	// same bytes under another mime are not the pick
	if got := e.a.Offer(entry.MimePNG, []byte("from-peer")); got != Written {
		t.Fatalf("png outcome %q", got)
	}
	e.x.ownText("own-copy")
	if got := e.capture(); got != Written {
		t.Fatalf("own copy %q", got)
	}
	if n := len(e.entries()); n != 2 {
		t.Fatalf("%d entries", n)
	}
}

func TestStateHoldsNoPlaintext(t *testing.T) {
	e := newEnv(t)
	secret := "correct-horse-battery"
	e.x.ownText(secret)
	e.capture()
	RecordPick(e.state, entry.MimeText, []byte(secret+"2"))
	des, _ := os.ReadDir(e.state)
	for _, d := range des {
		b, _ := os.ReadFile(filepath.Join(e.state, d.Name()))
		if bytes.Contains(b, []byte(secret)) {
			t.Fatalf("%s holds plaintext", d.Name())
		}
		if fi, _ := d.Info(); fi.Mode().Perm()&0o077 != 0 {
			t.Fatalf("%s mode %v", d.Name(), fi.Mode())
		}
	}
	if strings.Contains(e.logs.String(), secret) {
		t.Fatal("plaintext in logs")
	}
}

func TestOverCapSkipped(t *testing.T) {
	e := newEnv(t)
	e.a.Cap = 4
	e.x.ownText("12345")
	if got := e.capture(); got != "" {
		t.Fatalf("outcome %q", got)
	}
	if n := len(e.entries()); n != 0 {
		t.Fatalf("%d entries", n)
	}
}

func TestMissingFolderRetriesWithBoundedBackoff(t *testing.T) {
	e := newEnv(t)
	folder := e.st.Dir
	os.Remove(folder)
	writes := &countingStore{Store: e.st}
	e.a.Store = writes
	e.a.Heartbeat = 10 * time.Millisecond

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- e.a.RunX(ctx, e.sel) }()
	e.x.ownText("waiting")
	e.x.notify <- nil
	time.Sleep(300 * time.Millisecond)
	// backoff 20,40,80,80ms plus heartbeat-triggered tries are bounded
	// by heartbeat (10ms): far below a hot loop's thousands.
	if n := writes.writes.Load(); n < 2 || n > 60 {
		t.Fatalf("%d write attempts in 300ms", n)
	}
	if err := os.Mkdir(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for len(e.entries()) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	items := e.entries()
	if len(items) != 1 || string(items[0].Entry.Data) != "waiting" {
		t.Fatalf("items %+v", items)
	}
	if _, err := os.Stat(filepath.Join(folder, "hb-testhost.age")); err != nil {
		t.Fatalf("no heartbeat after folder came back: %v", err)
	}
}

func TestPendingExpires(t *testing.T) {
	e := newEnv(t)
	now := time.Now()
	e.a.Now = func() time.Time { return now }
	os.Remove(e.st.Dir)
	if got := e.a.Offer(entry.MimeText, []byte("x")); got != Pending {
		t.Fatalf("%q", got)
	}
	now = now.Add(time.Duration(entry.DefaultTTL+1) * time.Second)
	if got := e.a.Retry(); got != Dropped {
		t.Fatalf("%q", got)
	}
	if _, ok := e.a.RetryDue(); ok {
		t.Fatal("still pending")
	}
}

type countingStore struct {
	*store.Store
	writes atomic.Int32
}

func (c *countingStore) Write(e entry.Entry) (string, error) {
	c.writes.Add(1)
	return c.Store.Write(e)
}

func startRun(t *testing.T, e *env) (context.CancelFunc, chan error) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- e.a.RunX(ctx, e.sel) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	return cancel, done
}

func waitEntries(t *testing.T, e *env, n int, within time.Duration) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if len(e.entries()) >= n {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%d entries after %v, want %d", len(e.entries()), within, n)
}

func TestTimeoutContinues(t *testing.T) {
	e := newEnv(t)
	startRun(t, e)
	e.x.ownText("hung-owner")
	e.x.hang = 1
	start := time.Now()
	e.x.notify <- nil
	for len(e.x.callLog()) == 0 {
		time.Sleep(time.Millisecond)
	}
	// let the hung read reach its deadline, then copy again
	time.Sleep(150 * time.Millisecond)
	e.x.ownText("next-copy")
	e.x.notify <- nil
	waitEntries(t, e, 1, 2*time.Second)
	if d := time.Since(start); d > time.Second {
		t.Fatalf("next copy processed after %v", d)
	}
	items := e.entries()
	if len(items) != 1 || string(items[0].Entry.Data) != "next-copy" {
		t.Fatalf("items %+v", items)
	}
	if !strings.Contains(e.logs.String(), "timed out") {
		t.Fatalf("no metadata line for the timeout:\n%s", e.logs)
	}
}

func TestBurstNoDupFinalKept(t *testing.T) {
	e := newEnv(t)
	startRun(t, e)
	for i := 0; i < 20; i++ {
		e.x.ownText(fmt.Sprintf("burst-%02d", i))
		e.x.notify <- nil
		time.Sleep(5 * time.Millisecond)
	}
	waitEntries(t, e, 1, time.Second)
	time.Sleep(200 * time.Millisecond)
	seen := map[string]int{}
	for _, it := range e.entries() {
		seen[string(it.Entry.Data)]++
	}
	for k, n := range seen {
		if n != 1 {
			t.Fatalf("%s written %d times", k, n)
		}
	}
	if seen["burst-19"] != 1 {
		t.Fatalf("final copy lost; have %v", seen)
	}
}

func TestHeartbeatAtStartAndPeriodic(t *testing.T) {
	e := newEnv(t)
	e.a.Heartbeat = 30 * time.Millisecond
	startRun(t, e)
	hb := filepath.Join(e.st.Dir, "hb-testhost.age")
	var first time.Time
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if fi, err := os.Stat(hb); err == nil {
			if first.IsZero() {
				first = fi.ModTime()
			} else if fi.ModTime().After(first) {
				return
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("heartbeat not rewritten")
}

func TestWatcherGivesUpBounded(t *testing.T) {
	e := newEnv(t)
	e.x.failWait = errors.New("exit status 1")
	start := time.Now()
	err := e.a.RunX(context.Background(), e.sel)
	if err == nil || !strings.Contains(err.Error(), "gave up") {
		t.Fatalf("err %v", err)
	}
	if n := e.x.waits.Load(); n != MaxWatchFailures {
		t.Fatalf("%d clipnotify runs", n)
	}
	// backoff 20+40+80+80 ms between the 5 tries
	if d := time.Since(start); d < 200*time.Millisecond {
		t.Fatalf("no backoff: gave up after %v", d)
	}
}

func TestSweepRunsOnTick(t *testing.T) {
	e := newEnv(t)
	now := time.Now()
	e.a.Now = func() time.Time { return now }
	e.st.Now = e.a.Now
	e.a.Offer(entry.MimeText, []byte("old"))
	now = now.Add(time.Duration(entry.DefaultTTL+1) * time.Second)
	e.a.Tick()
	if n := len(e.entries()); n != 0 {
		t.Fatalf("own expired entry not swept: %d", n)
	}
}

// A copy landing after a capture's reads but before clipnotify re-arms
// produces no event. The agent must still end up with it: it is the
// current clipboard (rejection #1, gap 1: A, C, B -> {A, C} on 4a81bd02).
func TestRearmGapCopyNotLost(t *testing.T) {
	e := newEnv(t)
	e.x.useArm = true
	e.x.armDelay = 150 * time.Millisecond
	startRun(t, e)
	time.Sleep(200 * time.Millisecond) // first arm
	e.x.copyText("A")
	waitEntries(t, e, 1, time.Second)
	time.Sleep(200 * time.Millisecond) // re-armed
	e.x.copyText("C")
	waitEntries(t, e, 2, time.Second)
	time.Sleep(20 * time.Millisecond) // C read; clipnotify still arming
	e.x.copyText("B")
	waitEntries(t, e, 3, 2*time.Second)
	got := map[string]bool{}
	for _, it := range e.entries() {
		got[string(it.Entry.Data)] = true
	}
	if !got["A"] || !got["B"] || !got["C"] {
		t.Fatalf("entries %v, want A B C", got)
	}
}

// slowStore makes every Write take d, like encrypt + fsync on a busy box.
type slowStore struct {
	*store.Store
	d time.Duration
}

func (s slowStore) Write(e entry.Entry) (string, error) {
	time.Sleep(s.d)
	return s.Store.Write(e)
}

// Encrypt/write must not gate the next capture (gap 2): with writes at
// 60 ms and copies every 30 ms (above Floor), every copy is still read
// and written; a synchronous write path loses about half.
func TestWriteOffCapturePath(t *testing.T) {
	e := newEnv(t)
	e.a.Store = slowStore{e.st, 60 * time.Millisecond}
	e.x.useArm = true
	e.x.armDelay = time.Millisecond
	startRun(t, e)
	time.Sleep(50 * time.Millisecond)
	const n = 10
	for i := 0; i < n; i++ {
		e.x.copyText(fmt.Sprintf("q-%02d", i))
		time.Sleep(30 * time.Millisecond)
	}
	waitEntries(t, e, n, 3*time.Second)
	items := e.entries()
	seen := map[string]bool{}
	for _, it := range items {
		if seen[string(it.Entry.Data)] {
			t.Fatalf("dup %s", it.Entry.Data)
		}
		seen[string(it.Entry.Data)] = true
	}
	// ordering: created follows copy order
	for i := 1; i < len(items); i++ {
		// List is newest first
		if string(items[i-1].Entry.Data) <= string(items[i].Entry.Data) {
			t.Fatalf("order: %s before %s", items[i-1].Entry.Data, items[i].Entry.Data)
		}
	}
	if len(items) != n {
		t.Fatalf("%d entries, want %d", len(items), n)
	}
}

// The X agent and the Windows code share one echo-guard format: same
// hash.key, same keyed hash, same last-picked file. A pick recorded by
// either side is an echo to the X agent.
func TestPickHashSharedWithWindows(t *testing.T) {
	e := newEnv(t)
	key, err := winLoadKey(e.state)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(key, e.a.key) {
		t.Fatal("hash.key differs between X agent and windows code")
	}
	if got, want := keyedHash(key, entry.MimeText, []byte("p")), WinHash(key, entry.MimeText, []byte("p")); got != want {
		t.Fatalf("hash %s != WinHash %s", got, want)
	}
	if err := writeState(e.state, WinPickedFile, WinHash(key, entry.MimeText, []byte("win-pick"))); err != nil {
		t.Fatal(err)
	}
	if got := e.a.Offer(entry.MimeText, []byte("win-pick")); got != Echo {
		t.Fatalf("pick recorded by windows code: %q, want echo", got)
	}
}
