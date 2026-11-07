package store

import (
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

	"clipd/internal/crypt"
	"clipd/internal/entry"
)

var t0 = time.UnixMilli(1762160000000)

type rig struct {
	dir  string
	self *age.X25519Identity
	now  time.Time
	logs []string
	mu   sync.Mutex
}

func newRig(t *testing.T) (*rig, *Store) {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	r := &rig{dir: t.TempDir(), self: id, now: t0}
	return r, r.store("me", id)
}

func (r *rig) store(origin string, id *age.X25519Identity, peers ...*age.X25519Recipient) *Store {
	return &Store{
		Dir: r.dir, Origin: origin, Self: id, Peers: peers, Cap: entry.DefaultCap,
		Now: func() time.Time { return r.now },
		Logf: func(f string, a ...any) {
			r.mu.Lock()
			defer r.mu.Unlock()
			r.logs = append(r.logs, fmt.Sprintf(f, a...))
		},
	}
}

func text(s string, created time.Time, ttl int) entry.Entry {
	return entry.Entry{Created: created.UnixMilli(), TTLs: ttl, Mime: entry.MimeText, Data: []byte(s)}
}

func names(t *testing.T, dir string) []string {
	t.Helper()
	des, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, d := range des {
		out = append(out, d.Name())
	}
	return out
}

func TestWriteIsAtomicUnderConcurrentList(t *testing.T) {
	r, s := newRig(t)
	const n = 300
	payload := strings.Repeat("x", 1<<20)
	// Same plaintext length and recipients => same ciphertext length, so a
	// reader can judge completeness with a cheap stat instead of a slow
	// decrypt — fast enough to catch a non-atomic write mid-flight.
	ct, err := s.seal(text(payload, t0, 300))
	if err != nil {
		t.Fatal(err)
	}
	want := int64(len(ct))

	var done atomic.Bool
	var partial atomic.Int32
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		// Every <id>.age is checked once, the moment it is first seen —
		// what a Syncthing scan racing the writer would pick up.
		seen := map[string]bool{}
		f, err := os.Open(r.dir)
		if err != nil {
			t.Error(err)
			return
		}
		defer f.Close()
		for !done.Load() {
			f.Seek(0, 0)
			names, _ := f.Readdirnames(-1)
			for _, name := range names {
				if seen[name] || !idFile.MatchString(name) {
					continue
				}
				seen[name] = true
				if st, err := os.Stat(filepath.Join(r.dir, name)); err == nil && st.Size() != want {
					partial.Add(1)
				}
			}
		}
	}()
	for i := 0; i < n; i++ {
		if _, err := s.Write(text(payload, t0, 300)); err != nil {
			t.Fatal(err)
		}
	}
	done.Store(true)
	wg.Wait()
	if p := partial.Load(); p != 0 {
		t.Fatalf("reader saw %d partial .age files", p)
	}
	items, st, err := s.List()
	if err != nil || len(items) != n || st.Skipped != 0 {
		t.Fatalf("list: %d items, %+v, %v", len(items), st, err)
	}
	for _, name := range names(t, r.dir) {
		if strings.HasSuffix(name, ".tmp") {
			t.Fatalf("leftover tmp %s", name)
		}
	}
}

func TestWriteNeverOverwrites(t *testing.T) {
	r, s := newRig(t)
	id := "00112233445566aa"
	os.WriteFile(filepath.Join(r.dir, id+".age"), []byte("existing"), 0o600)
	s.newID = func() (string, error) { return id, nil }
	if _, err := s.Write(text("a", t0, 300)); err == nil {
		t.Fatal("write over existing id succeeded")
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, id+".age")); string(b) != "existing" {
		t.Fatal("existing entry overwritten")
	}
	if got := names(t, r.dir); len(got) != 1 {
		t.Fatalf("leftovers: %v", got)
	}
}

func TestListIgnoresSyncthingFiles(t *testing.T) {
	r, s := newRig(t)
	id, err := s.Write(text("real", t0, 300))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(r.dir, id+".age"))
	// Valid ciphertext under every name List must ignore: if it read any
	// of them it would return more than one item.
	for _, n := range []string{
		".stignore", "." + id + ".tmp", "hb-me.age",
		id + ".sync-conflict-20261103-101010-ABCDEFG.age",
		"0011223344556677.age.tmp", "ABCDEF0123456789.age", "0123456789abcde.age",
		"0123456789abcdef0.age", "~syncthing~0123456789abcdef.age.tmp",
	} {
		os.WriteFile(filepath.Join(r.dir, n), b, 0o600)
	}
	os.Mkdir(filepath.Join(r.dir, ".stfolder"), 0o700)
	items, st, err := s.List()
	if err != nil || len(items) != 1 || items[0].ID != id || st.Skipped != 0 {
		t.Fatalf("items %+v stats %+v err %v", items, st, err)
	}
}

func TestListNewestFirst(t *testing.T) {
	r, s := newRig(t)
	for i, w := range []string{"b", "c", "a"} { // created out of order
		created := t0.Add(time.Duration([]int{2, 3, 1}[i]) * time.Second)
		if _, err := s.Write(text(w, created, 300)); err != nil {
			t.Fatal(err)
		}
	}
	r.now = t0.Add(5 * time.Second)
	items, _, err := s.List()
	if err != nil {
		t.Fatal(err)
	}
	var got string
	for _, it := range items {
		got += string(it.Entry.Data)
	}
	if got != "cba" {
		t.Fatalf("order %q, want cba", got)
	}
	if items[0].Entry.Origin != "me" {
		t.Fatalf("origin %q", items[0].Entry.Origin)
	}
}

func TestListHidesExpired(t *testing.T) {
	r, s := newRig(t)
	s.Write(text("old", t0, 10))
	s.Write(text("new", t0, 300))
	r.now = t0.Add(11 * time.Second)
	items, _, _ := s.List()
	if len(items) != 1 || string(items[0].Entry.Data) != "new" {
		t.Fatalf("items %+v", items)
	}
}

func TestSweepExpiresOnlyExpired(t *testing.T) {
	r, s := newRig(t)
	keep, _ := s.Write(text("keep", t0, 300))
	gone, _ := s.Write(text("gone", t0, 10))
	r.now = t0.Add(10 * time.Second) // created+ttl == now: not yet expired
	if n, _, err := s.Sweep(); err != nil || n != 0 {
		t.Fatalf("at boundary removed %d, %v", n, err)
	}
	r.now = t0.Add(10*time.Second + time.Millisecond)
	if n, _, err := s.Sweep(); err != nil || n != 1 {
		t.Fatalf("removed %d, %v", n, err)
	}
	if _, err := os.Stat(filepath.Join(r.dir, gone+".age")); !os.IsNotExist(err) {
		t.Fatal("expired own entry still present")
	}
	if _, err := os.Stat(filepath.Join(r.dir, keep+".age")); err != nil {
		t.Fatal("unexpired entry removed")
	}
}

func TestSweepKeepsForeignUnexpired(t *testing.T) {
	r, mine := newRig(t)
	peerID, _ := age.GenerateX25519Identity()
	peer := r.store("peer", peerID, r.self.Recipient())
	fresh, _ := peer.Write(text("fresh", t0, 300))
	stale, _ := peer.Write(text("stale", t0, 10))

	// Foreign entries get SkewTolerance past their expiry: a peer whose
	// clock runs behind must not have its copies deleted early by us.
	r.now = t0.Add(10*time.Second + SkewTolerance)
	if n, _, _ := mine.Sweep(); n != 0 {
		t.Fatalf("removed %d foreign entries inside skew window", n)
	}
	r.now = r.now.Add(time.Millisecond)
	if n, _, _ := mine.Sweep(); n != 1 {
		t.Fatalf("removed %d, want the stale foreign entry", n)
	}
	if _, err := os.Stat(filepath.Join(r.dir, stale+".age")); !os.IsNotExist(err) {
		t.Fatal("stale foreign entry kept")
	}
	if _, err := os.Stat(filepath.Join(r.dir, fresh+".age")); err != nil {
		t.Fatal("fresh foreign entry removed")
	}
}

// Files we cannot decrypt (not for us, corrupt) tell us nothing about
// their expiry; Sweep must leave them to their writer.
func TestSweepLeavesUndecryptable(t *testing.T) {
	r, s := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "0123456789abcdef.age"), []byte("junk"), 0o600)
	r.now = t0.Add(24 * time.Hour)
	if n, st, _ := s.Sweep(); n != 0 || st.Skipped != 1 {
		t.Fatalf("removed %d skipped %d", n, st.Skipped)
	}
}

func TestSweepRemovesStaleTmp(t *testing.T) {
	r, s := newRig(t)
	tmp := filepath.Join(r.dir, ".0123456789abcdef.tmp")
	fresh := filepath.Join(r.dir, ".fedcba9876543210.tmp")
	os.WriteFile(tmp, []byte("crash leftover"), 0o600)
	os.WriteFile(fresh, []byte("in flight"), 0o600)
	os.Chtimes(tmp, t0.Add(-2*time.Minute), t0.Add(-2*time.Minute))
	os.Chtimes(fresh, t0, t0)
	s.Sweep()
	if _, err := os.Stat(tmp); !os.IsNotExist(err) {
		t.Fatal("stale tmp kept")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Fatal("in-flight tmp removed")
	}
}

func TestMissingFolderErr(t *testing.T) {
	r, s := newRig(t)
	s.Dir = filepath.Join(r.dir, "gone")
	if _, err := s.Write(text("a", t0, 300)); !errors.Is(err, ErrNoFolder) {
		t.Fatalf("write: %v", err)
	}
	if _, _, err := s.List(); !errors.Is(err, ErrNoFolder) {
		t.Fatalf("list: %v", err)
	}
	if _, _, err := s.Sweep(); !errors.Is(err, ErrNoFolder) {
		t.Fatalf("sweep: %v", err)
	}
	if err := s.WriteHeartbeat(); !errors.Is(err, ErrNoFolder) {
		t.Fatalf("heartbeat: %v", err)
	}
	if _, err := os.Stat(s.Dir); !os.IsNotExist(err) {
		t.Fatal("store created the folder")
	}
}

func TestCorruptEntrySkipped(t *testing.T) {
	r, s := newRig(t)
	good, _ := s.Write(text("secret-good", t0, 300))
	other, _ := age.GenerateX25519Identity()
	foreign := r.store("x", other)
	foreign.Write(text("not for me", t0, 300))
	os.WriteFile(filepath.Join(r.dir, "0123456789abcdef.age"), []byte("garbage"), 0o600)
	// Valid age, invalid entry JSON.
	ct, _ := crypt.Encrypt([]byte(`{"v":9}`), r.self, nil)
	os.WriteFile(filepath.Join(r.dir, "fedcba9876543210.age"), ct, 0o600)

	items, st, err := s.List()
	if err != nil || len(items) != 1 || items[0].ID != good {
		t.Fatalf("items %+v err %v", items, err)
	}
	if st.Skipped != 3 {
		t.Fatalf("skipped %d, want 3", st.Skipped)
	}
	if len(r.logs) != 3 {
		t.Fatalf("logged %d lines, want 3", len(r.logs))
	}
	for _, l := range r.logs {
		if strings.Contains(l, "secret") || strings.Contains(l, "garbage") {
			t.Fatalf("log leaks payload: %q", l)
		}
	}
}

func TestWriteHeartbeat(t *testing.T) {
	r, s := newRig(t)
	if err := s.WriteHeartbeat(); err != nil {
		t.Fatal(err)
	}
	r.now = t0.Add(time.Minute)
	if err := s.WriteHeartbeat(); err != nil {
		t.Fatal(err)
	}
	got := names(t, r.dir)
	if len(got) != 1 || got[0] != "hb-me.age" {
		t.Fatalf("files %v", got)
	}
	b, _ := os.ReadFile(filepath.Join(r.dir, "hb-me.age"))
	pt, err := crypt.Decrypt(b, r.self, 4096)
	if err != nil {
		t.Fatal(err)
	}
	e, err := entry.Decode(pt, entry.DefaultCap)
	if err != nil || e.Mime != entry.MimeHeartbeat || e.Created != t0.Add(time.Minute).UnixMilli() {
		t.Fatalf("heartbeat %+v %v", e, err)
	}
	s.Origin = "../evil"
	if err := s.WriteHeartbeat(); err == nil {
		t.Fatal("path-unsafe origin accepted")
	}
}

// Deterministic half of the atomicity claim: the final name appears only
// after a complete, decryptable temp file exists, for entries and
// heartbeats alike. (The concurrent test above is the black-box half; a
// non-atomic write can slip between its reads.)
func TestPublishOnlyAfterCompleteTmp(t *testing.T) {
	r, s := newRig(t)
	calls := 0
	s.beforePublish = func(tmp, final string) {
		calls++
		if !strings.HasPrefix(filepath.Base(tmp), ".") {
			t.Errorf("tmp %s not dot-prefixed", tmp)
		}
		if _, err := os.Stat(final); err == nil && !strings.Contains(final, "hb-") {
			t.Errorf("%s visible before publish", final)
		}
		b, err := os.ReadFile(tmp)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := crypt.Decrypt(b, r.self, entry.MaxEncoded(entry.DefaultCap)); err != nil {
			t.Errorf("tmp not complete at publish: %v", err)
		}
	}
	if _, err := s.Write(text(strings.Repeat("y", 200<<10), t0, 300)); err != nil {
		t.Fatal(err)
	}
	if err := s.WriteHeartbeat(); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("publish seam called %d times, want 2", calls)
	}
}

// Edge case: the temp name is opened O_EXCL, so a pre-existing temp file
// (a second writer, a stale leftover) fails the write and is left intact.
func TestWriteRefusesExistingTmp(t *testing.T) {
	r, s := newRig(t)
	id := "0011223344556677"
	tmp := filepath.Join(r.dir, "."+id+".tmp")
	os.WriteFile(tmp, []byte("other writer"), 0o600)
	s.newID = func() (string, error) { return id, nil }
	if _, err := s.Write(text("a", t0, 300)); err == nil {
		t.Fatal("write over existing tmp succeeded")
	}
	if b, _ := os.ReadFile(tmp); string(b) != "other writer" {
		t.Fatalf("tmp changed: %q", b)
	}
	if _, err := os.Stat(filepath.Join(r.dir, id+".age")); !os.IsNotExist(err) {
		t.Fatal("entry published anyway")
	}
}

func TestListSkipsHeartbeatUnderEntryName(t *testing.T) {
	r, s := newRig(t)
	if err := s.WriteHeartbeat(); err != nil {
		t.Fatal(err)
	}
	os.Rename(filepath.Join(r.dir, "hb-me.age"), filepath.Join(r.dir, "0123456789abcdef.age"))
	items, st, _ := s.List()
	if len(items) != 0 || st.Skipped != 1 {
		t.Fatalf("items %d skipped %d", len(items), st.Skipped)
	}
}

func TestHeartbeatsReadsEveryOrigin(t *testing.T) {
	r, me := newRig(t)
	peerID, _ := age.GenerateX25519Identity()
	peer := r.store("peer-1", peerID, r.self.Recipient())
	if err := me.WriteHeartbeat(); err != nil {
		t.Fatal(err)
	}
	r.now = t0.Add(-time.Minute)
	if err := peer.WriteHeartbeat(); err != nil {
		t.Fatal(err)
	}
	// An entry, a temp file and Syncthing's marker are not heartbeats.
	if _, err := me.Write(text("x", t0, 300)); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(r.dir, ".hb-x.tmp"), []byte("junk"), 0o600)
	os.Mkdir(filepath.Join(r.dir, ".stfolder"), 0o700)

	hbs, st, err := me.Heartbeats()
	if err != nil || st.Skipped != 0 {
		t.Fatalf("err %v skipped %d", err, st.Skipped)
	}
	if len(hbs) != 2 || hbs["me"].Created != t0.UnixMilli() || hbs["peer-1"].Created != t0.Add(-time.Minute).UnixMilli() {
		t.Fatalf("heartbeats %+v", hbs)
	}
}

// A heartbeat whose decrypted origin disagrees with its filename is a
// peer claiming another's liveness: skipped, never credited.
func TestHeartbeatsRejectOriginMismatch(t *testing.T) {
	r, me := newRig(t)
	liar := r.store("liar", r.self)
	if err := liar.WriteHeartbeat(); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(r.dir, "hb-liar.age"), filepath.Join(r.dir, "hb-honest.age")); err != nil {
		t.Fatal(err)
	}
	// An entry stored under a heartbeat name is not a heartbeat either.
	id, err := me.Write(text("payload-secret", t0, 300))
	if err != nil {
		t.Fatal(err)
	}
	os.Rename(filepath.Join(r.dir, id+".age"), filepath.Join(r.dir, "hb-entry.age"))
	// Undecryptable garbage.
	os.WriteFile(filepath.Join(r.dir, "hb-garbage.age"), []byte("not age"), 0o600)

	hbs, st, err := me.Heartbeats()
	if err != nil {
		t.Fatal(err)
	}
	if len(hbs) != 0 || st.Skipped != 3 {
		t.Fatalf("heartbeats %+v skipped %d", hbs, st.Skipped)
	}
	for _, l := range r.logs {
		if strings.Contains(l, "payload-secret") {
			t.Fatalf("payload in log %q", l)
		}
	}
}

func TestHeartbeatsMissingFolder(t *testing.T) {
	_, s := newRig(t)
	s.Dir = filepath.Join(s.Dir, "gone")
	if _, _, err := s.Heartbeats(); !errors.Is(err, ErrNoFolder) {
		t.Fatalf("err %v", err)
	}
}

// Windows: Syncthing or Defender can hold hb-<origin>.age open for a
// moment, failing the replacing rename (dotfiles-jxzw). A bounded retry
// absorbs it; a persistent failure still surfaces and leaves no temp.
func TestHeartbeatRenameRetriesTransient(t *testing.T) {
	r, s := newRig(t)
	var calls int
	s.rename = func(a, b string) error {
		calls++
		if calls < 3 {
			return errors.New("sharing violation")
		}
		return os.Rename(a, b)
	}
	if err := s.WriteHeartbeat(); err != nil {
		t.Fatalf("transient failure not absorbed: %v", err)
	}
	if calls != 3 {
		t.Fatalf("rename calls %d", calls)
	}
	calls = 0
	s.rename = func(a, b string) error { calls++; return errors.New("held") }
	if err := s.WriteHeartbeat(); err == nil {
		t.Fatal("persistent failure swallowed")
	}
	if calls != heartbeatRenameTries {
		t.Fatalf("unbounded retry: %d calls", calls)
	}
	if got := names(t, r.dir); len(got) != 1 || got[0] != "hb-me.age" {
		t.Fatalf("files %v", got)
	}
}

func TestValidOrigin(t *testing.T) {
	for _, ok := range []string{"a", "host-1", "Host_2", strings.Repeat("x", 64)} {
		if err := ValidOrigin(ok); err != nil {
			t.Errorf("%q: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "-a", "_a", "a b", "a.b", strings.Repeat("x", 65)} {
		if err := ValidOrigin(bad); !errors.Is(err, ErrBadOrigin) {
			t.Errorf("%q: %v", bad, err)
		}
	}
}

// A folder writer chooses the origin it seals: age has no sender auth, and
// recipients are public. `clipd list` prints origin as a column, so a tab or
// newline in it would forge rows the user then picks from.
func TestListSkipsInvalidOrigin(t *testing.T) {
	r, s := newRig(t)
	for i, origin := range []string{"evil\tinjected\nffffffffffffffff\tfake\t0\tforged", "esc\x1b[2Jape", "-dash", " "} {
		pt, err := entry.Encode(entry.Entry{Origin: origin, Created: time.Now().UnixMilli(), TTLs: 300, Mime: entry.MimeText, Data: []byte("x")}, entry.DefaultCap)
		if err != nil {
			t.Fatal(err)
		}
		ct, err := crypt.Encrypt(pt, s.Self, s.Peers)
		if err != nil {
			t.Fatal(err)
		}
		name := fmt.Sprintf("%016x.age", i+1)
		if err := os.WriteFile(filepath.Join(r.dir, name), ct, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Write(entry.Entry{Created: time.Now().UnixMilli(), TTLs: 300, Mime: entry.MimeText, Data: []byte("good")}); err != nil {
		t.Fatal(err)
	}
	items, st, err := s.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || string(items[0].Entry.Data) != "good" {
		t.Fatalf("items %+v", items)
	}
	if st.Skipped != 4 {
		t.Fatalf("skipped %d, want 4", st.Skipped)
	}
}
