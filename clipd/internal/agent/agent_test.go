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

	// per-call latency (answered, just slow — a loaded host)
	targetsDelay, readDelay time.Duration

	// gates: the next call for a target blocks until the test closes the
	// channel (one-shot) — ordering under test control, not timing.
	gates map[string]chan struct{}

	servedLog []string // payload bytes returned, per payload read
}

func (f *fakeX) wasServed(data string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, d := range f.servedLog {
		if d == data {
			return true
		}
	}
	return false
}

// within is the deadline for every wait in these tests: far beyond any
// expected latency, so a slow (loaded, -race) host only makes them
// slower, never red; a hang still fails instead of spinning forever.
const within = 10 * time.Second

func pollUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(within)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out after %v waiting for %s", within, what)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// waitArmed blocks until a clipnotify is subscribed (arm mode), so the
// next copyText raises an event.
func (f *fakeX) waitArmed(t *testing.T) {
	t.Helper()
	pollUntil(t, "clipnotify armed", func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		return f.waiter != nil
	})
}

func (f *fakeX) armed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.waiter != nil
}

// gate makes the next call for target block until the returned channel
// is closed.
func (f *fakeX) gate(target string) chan struct{} {
	ch := make(chan struct{})
	f.mu.Lock()
	if f.gates == nil {
		f.gates = map[string]chan struct{}{}
	}
	f.gates[target] = ch
	f.mu.Unlock()
	return ch
}

// waitCalls blocks until n xclip calls for target have started.
func (f *fakeX) waitCalls(t *testing.T, target string, n int) {
	t.Helper()
	pollUntil(t, fmt.Sprintf("%d %s calls", n, target), func() bool { return f.countCalls(target) >= n })
}

func (f *fakeX) countCalls(target string) int {
	n := 0
	for _, c := range f.callLog() {
		if c == target {
			n++
		}
	}
	return n
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
			f.mu.Lock()
			armDelay := f.armDelay
			f.mu.Unlock()
			if !sleep(ctx, armDelay) {
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
	d := f.readDelay
	if target == "TARGETS" {
		d = f.targetsDelay
	}
	g := f.gates[target]
	delete(f.gates, target)
	f.mu.Unlock()
	if hang {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if g != nil {
		select {
		case <-g:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if !sleep(ctx, d) {
		return nil, ctx.Err()
	}
	if len(out) > limit {
		return nil, xsel.ErrTooLarge
	}
	if target != "TARGETS" && err == nil {
		f.mu.Lock()
		f.servedLog = append(f.servedLog, string(out))
		f.mu.Unlock()
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
	startRun(t, e)
	e.x.ownText("waiting")
	e.x.notify <- nil
	pollUntil(t, "2 write attempts", func() bool { return writes.writes.Load() >= 2 })
	// bounded: backoff 20..80 ms plus heartbeat-triggered tries (10 ms)
	// is tens of attempts per 300 ms; a hot loop would be thousands.
	n := writes.writes.Load()
	time.Sleep(300 * time.Millisecond)
	if d := writes.writes.Load() - n; d > 60 {
		t.Fatalf("%d write attempts in 300ms: not bounded", d)
	}
	if err := os.Mkdir(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	waitEntry(t, e, "waiting")
	if n := len(e.entries()); n != 1 {
		t.Fatalf("%d entries", n)
	}
	pollUntil(t, "heartbeat after folder came back", func() bool {
		_, err := os.Stat(filepath.Join(folder, "hb-testhost.age"))
		return err == nil
	})
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

func waitEntries(t *testing.T, e *env, n int) {
	t.Helper()
	pollUntil(t, fmt.Sprintf("%d entries", n), func() bool { return len(e.entries()) >= n })
}

// waitEntry blocks until an entry decrypting to data exists.
func waitEntry(t *testing.T, e *env, data string) {
	t.Helper()
	pollUntil(t, "entry "+data, func() bool { return e.has(data) })
}

func (e *env) has(data string) bool {
	for _, it := range e.entries() {
		if string(it.Entry.Data) == data {
			return true
		}
	}
	return false
}

// waitQuiet blocks until no xclip call has started for quiet; a capture
// loop that never settles (confirms polling forever) fails it.
func (f *fakeX) waitQuiet(t *testing.T, quiet time.Duration) {
	t.Helper()
	n, since := len(f.callLog()), time.Now()
	pollUntil(t, fmt.Sprintf("no xclip calls for %v", quiet), func() bool {
		if m := len(f.callLog()); m != n {
			n, since = m, time.Now()
		}
		return time.Since(since) >= quiet
	})
}

func (f *fakeX) setArmDelay(d time.Duration) {
	f.mu.Lock()
	f.armDelay = d
	f.mu.Unlock()
}

func TestTimeoutContinues(t *testing.T) {
	e := newEnv(t)
	startRun(t, e)
	e.x.ownText("hung-owner")
	e.x.mu.Lock()
	e.x.hang = 1
	e.x.mu.Unlock()
	e.x.notify <- nil
	pollUntil(t, "metadata line for the timed-out read", func() bool {
		return strings.Contains(e.logs.String(), "timed out")
	})
	e.x.ownText("next-copy")
	e.x.notify <- nil
	waitEntry(t, e, "next-copy") // the loop continued past the hung owner
}

func TestBurstNoDupFinalKept(t *testing.T) {
	e := newEnv(t)
	startRun(t, e)
	for i := 0; i < 20; i++ {
		e.x.ownText(fmt.Sprintf("burst-%02d", i))
		e.x.notify <- nil
		time.Sleep(5 * time.Millisecond)
	}
	waitEntry(t, e, "burst-19") // the final copy is the clipboard: kept
	e.x.waitQuiet(t, time.Second)
	seen := map[string]int{}
	for _, it := range e.entries() {
		seen[string(it.Entry.Data)]++
	}
	for k, n := range seen {
		if n != 1 {
			t.Fatalf("%s written %d times", k, n)
		}
	}
}

func TestHeartbeatAtStartAndPeriodic(t *testing.T) {
	e := newEnv(t)
	e.a.Heartbeat = 30 * time.Millisecond
	startRun(t, e)
	hb := filepath.Join(e.st.Dir, "hb-testhost.age")
	var first time.Time
	pollUntil(t, "heartbeat rewritten", func() bool {
		fi, err := os.Stat(hb)
		if err != nil {
			return false
		}
		if first.IsZero() {
			first = fi.ModTime()
			return false
		}
		return fi.ModTime().After(first)
	})
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
// Ordering is forced, not timed: clipnotify never re-arms after C's
// event, and B lands while C's payload read is held open.
func TestRearmGapCopyNotLost(t *testing.T) {
	e := newEnv(t)
	e.x.useArm = true
	e.x.armDelay = time.Millisecond
	startRun(t, e)
	e.x.waitArmed(t)
	e.x.copyText("A")
	waitEntry(t, e, "A")
	e.x.waitCalls(t, "UTF8_STRING", 2)     // A's confirm read A (dup)
	e.x.waitQuiet(t, 200*time.Millisecond) // ...and finished its re-check
	e.x.waitArmed(t)
	e.x.setArmDelay(time.Hour) // the re-arm after C's event never subscribes
	g := e.x.gate("UTF8_STRING")
	e.x.copyText("C")
	e.x.waitCalls(t, "UTF8_STRING", 3) // A, A's confirm, C (held)
	if e.x.armed() {
		t.Fatal("clipnotify re-armed; B would raise an event")
	}
	e.x.copyText("B") // nothing armed: no event for B
	close(g)
	waitEntry(t, e, "C")
	waitEntry(t, e, "B")
}

// gateStore blocks every Write until release is closed.
type gateStore struct {
	*store.Store
	release chan struct{}
	once    *sync.Once
}

func (s gateStore) open() { s.once.Do(func() { close(s.release) }) }

func (s gateStore) Write(e entry.Entry) (string, error) {
	<-s.release
	return s.Store.Write(e)
}

// Encrypt/write must not gate the next capture (gap 2). With every Write
// blocked, the capture loop must still read each new copy; a synchronous
// write path stalls in the first Write and never reads the second.
func TestWriteOffCapturePath(t *testing.T) {
	e := newEnv(t)
	gs := gateStore{e.st, make(chan struct{}), &sync.Once{}}
	e.a.Store = gs
	e.x.useArm = true
	e.x.armDelay = time.Millisecond
	startRun(t, e)
	t.Cleanup(gs.open) // runs before startRun's: a failing run never hangs in Write
	const n = 5
	for i := 0; i < n; i++ {
		e.x.waitArmed(t)
		e.x.copyText(fmt.Sprintf("q-%02d", i))
		want := fmt.Sprintf("q-%02d", i)
		pollUntil(t, "read of "+want+" while writes are blocked", func() bool { return e.x.wasServed(want) })
	}
	gs.open()
	waitEntries(t, e, n)
	e.x.waitQuiet(t, 500*time.Millisecond)
	items := e.entries() // newest first
	if len(items) != n {
		t.Fatalf("%d entries, want %d", len(items), n)
	}
	for i, it := range items {
		if want := fmt.Sprintf("q-%02d", n-1-i); string(it.Entry.Data) != want {
			t.Fatalf("entry %d = %s, want %s (order)", i, it.Entry.Data, want)
		}
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
	if err := os.WriteFile(filepath.Join(e.state, WinPickedFile), []byte(WinHash(key, entry.MimeText, []byte("win-pick"))+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := e.a.Offer(entry.MimeText, []byte("win-pick")); got != Echo {
		t.Fatalf("pick recorded by windows code: %q, want echo", got)
	}
}

// An owner that never answers stalls a capture for the whole read bound.
// A newer copy made during the stall must supersede it — the stalled read
// is cancelled (its result is stale) and the new copy written well inside
// the bound (rejection #2: 1 s stalls swallowed copies at 150 ms spacing).
// The bound is 5 s here so "well inside" has room on a loaded host.
func TestStalledCaptureSupersededByNewerCopy(t *testing.T) {
	e := newEnv(t)
	e.sel.Timeout = 5 * time.Second
	e.x.useArm = true
	e.x.armDelay = time.Millisecond
	startRun(t, e)
	e.x.waitArmed(t)
	e.x.mu.Lock()
	e.x.hang = 1 // the next TARGETS read never gets an answer
	e.x.mu.Unlock()
	e.x.copyText("stuck-owner")
	e.x.waitCalls(t, "TARGETS", 1) // the read is now stalled
	e.x.waitArmed(t)
	t0 := time.Now()
	e.x.copyText("fresh")
	waitEntry(t, e, "fresh")
	if d := time.Since(t0); d > 2500*time.Millisecond {
		t.Fatalf("newer copy written %v after it was made (bound 5s): the stalled read was not superseded", d)
	}
	if e.has("stuck-owner") {
		t.Fatal("stale content of the stalled capture was written")
	}
	if !strings.Contains(e.logs.String(), "superseded") {
		t.Fatalf("no supersede log line:\n%s", e.logs)
	}
}

// A superseded capture must never offer what it read: a cancel that lands
// after the payload read (during the TARGETS re-check) drops the payload,
// so the hint re-check is never skipped.
func TestCancelDuringRecheckDropsPayload(t *testing.T) {
	e := newEnv(t)
	q := &queue{max: 1 << 20, wake: make(chan struct{}, 1)}
	ctx, cancel := context.WithCancel(context.Background())
	sel := &cancelOnRecheck{fakeX: e.x, cancel: cancel}
	e.x.ownText("payload-then-cancel")
	e.a.captureInto(ctx, &xsel.X{Display: ":93", Timeout: time.Second, Runner: sel}, q)
	if p := q.pop(); p != nil {
		t.Fatalf("cancelled capture queued %q", p.e.Data)
	}
	if n := len(sel.targets); n != 2 {
		t.Fatalf("%d TARGETS calls, want 2 (gate + re-check)", n)
	}
}

// cancelOnRecheck cancels the capture as the second TARGETS read starts
// and then blocks it until cancelled.
type cancelOnRecheck struct {
	*fakeX
	cancel  context.CancelFunc
	targets []string
}

func (c *cancelOnRecheck) Output(ctx context.Context, env []string, limit int, name string, args ...string) ([]byte, error) {
	if args[len(args)-2] == "TARGETS" {
		c.targets = append(c.targets, "TARGETS")
		if len(c.targets) == 2 {
			c.cancel()
			<-ctx.Done()
			return nil, ctx.Err()
		}
	}
	return c.fakeX.Output(ctx, env, limit, name, args...)
}

func pe(s string) *pendingEntry {
	return &pendingEntry{e: entry.Entry{Mime: entry.MimeText, Data: []byte(s)}, hash: s}
}

// Under a writer backlog the queue evicts oldest-first, stays within its
// byte bound, and never evicts the entry just pushed — the current
// clipboard — even when that one alone is over the bound.
func TestQueueEvictsOldestKeepsNewest(t *testing.T) {
	q := &queue{max: 10, wake: make(chan struct{}, 1)}
	var evicted []string
	for _, s := range []string{"aaaa", "bbbb", "cccc", "dddd"} {
		for _, p := range q.push(pe(s)) {
			evicted = append(evicted, string(p.e.Data))
		}
		if q.bytes > q.max {
			t.Fatalf("after %s: %d bytes > max %d", s, q.bytes, q.max)
		}
	}
	if strings.Join(evicted, ",") != "aaaa,bbbb" {
		t.Fatalf("evicted %v, want oldest first", evicted)
	}
	if p := q.items[len(q.items)-1]; string(p.e.Data) != "dddd" {
		t.Fatalf("newest not kept: %q", p.e.Data)
	}
	big := strings.Repeat("z", 25)
	ev := q.push(pe(big))
	if len(ev) != 2 || len(q.items) != 1 || string(q.items[0].e.Data) != big {
		t.Fatalf("over-max newest: evicted %d, queue %d", len(ev), len(q.items))
	}
	if p := q.pop(); string(p.e.Data) != big || q.bytes != 0 || q.pop() != nil {
		t.Fatal("pop after over-max push")
	}
}

// Through the agent: evicted entries are logged (metadata) and forgotten
// for dedupe, so copying the same content again is sent.
func TestCaptureEvictionForgetsDedupe(t *testing.T) {
	e := newEnv(t)
	q := &queue{max: 6, wake: make(chan struct{}, 1)}
	for _, s := range []string{"one", "two", "three"} {
		e.x.ownText(s)
		e.a.captureInto(context.Background(), e.sel, q)
	}
	if !strings.Contains(e.logs.String(), "drop queued") {
		t.Fatalf("no eviction log:\n%s", e.logs)
	}
	if strings.Contains(e.logs.String(), "one") {
		t.Fatal("payload in log")
	}
	// "one" was evicted unwritten: a fresh copy of it must not be a Dup.
	p, out := e.a.decide(entry.MimeText, []byte("one"))
	if p == nil || out != "" {
		t.Fatalf("re-copy of evicted content: %q", out)
	}
}

// A capture that is slow but whose in-flight call began after the newer
// copy is reading the NEW owner: it must not be superseded (under load
// that churn cancelled most of a 50 ms burst). Ordering is forced with
// gates: B lands while A's TARGETS call is held; the TARGETS call is then
// released, so the call in flight at the supersede check is the payload
// read, begun after B — held well past Supersede.
func TestSlowCaptureOnNewOwnerNotSuperseded(t *testing.T) {
	e := newEnv(t)
	e.sel.Timeout = 10 * time.Second
	e.a.Supersede = time.Second
	e.x.useArm = true
	e.x.armDelay = time.Millisecond
	startRun(t, e)
	e.x.waitArmed(t)
	gT := e.x.gate("TARGETS")
	e.x.copyText("A")
	e.x.waitCalls(t, "TARGETS", 1) // A's TARGETS held
	e.x.waitArmed(t)
	gP := e.x.gate("UTF8_STRING")
	e.x.copyText("B") // newer event while A's capture runs
	// The agent stamps the event when its loop takes it, not when the
	// owner changed; a call begun in between counts as "before" (a
	// harmless false positive: the replacement capture reads the same
	// new owner). Let the loop take B first: the watcher re-arms only
	// after handing the event over, and a quarter of Supersede is ample.
	e.x.waitArmed(t)
	time.Sleep(e.a.Supersede / 4)
	close(gT)
	e.x.waitCalls(t, "UTF8_STRING", 1) // payload read began after B
	time.Sleep(3 * e.a.Supersede)      // the supersede check runs meanwhile
	close(gP)
	waitEntry(t, e, "B")
	e.x.waitQuiet(t, 500*time.Millisecond)
	if strings.Contains(e.logs.String(), "superseded") {
		t.Fatalf("slow-but-live capture was superseded:\n%s", e.logs)
	}
}

// Copies that keep landing while clipnotify is still re-arming raise no
// events at all; a confirm that finds a new copy must be followed by
// another confirm, or the copy after it is lost though it is current.
// Ordering is forced: clipnotify never re-arms after A's event; B lands
// while A's payload read is held, C while the first confirm's is.
func TestConfirmChainsWhileCopiesKeepComing(t *testing.T) {
	e := newEnv(t)
	e.x.useArm = true
	e.x.armDelay = time.Millisecond
	startRun(t, e)
	e.x.waitArmed(t)
	e.x.setArmDelay(time.Hour) // after this event, clipnotify never re-arms
	g1 := e.x.gate("UTF8_STRING")
	e.x.copyText("A")
	e.x.waitCalls(t, "UTF8_STRING", 1) // A's read, held
	e.x.copyText("B")                  // no event
	g2 := e.x.gate("UTF8_STRING")
	close(g1)
	e.x.waitCalls(t, "UTF8_STRING", 2) // first confirm reads B, held
	e.x.copyText("C")                  // no event: only a second confirm sees it
	close(g2)
	waitEntry(t, e, "A")
	waitEntry(t, e, "B")
	waitEntry(t, e, "C")
	// and the chain ends: once a confirm finds nothing new, polling stops.
	e.x.waitQuiet(t, time.Second)
}
