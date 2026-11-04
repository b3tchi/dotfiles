// Package store is clipd's view of the Syncthing folder (sp039 Task 3):
// one age-encrypted file per entry, `<16-hex>.age`, plus one heartbeat
// per device, `hb-<device>.age`.
//
// Syncthing must never ship a partial file ([[poc024]]), so every write
// goes to a dot-prefixed temp file first. Entries are published with
// link+unlink, which fails rather than overwrites if the id exists;
// heartbeats are published with rename, which replaces.
//
// The store never creates the folder: Syncthing needs `.stfolder` inside
// it, and making the folder is setup's job (Task 9). A missing folder is
// ErrNoFolder and the caller decides.
//
// Clock skew: expiry uses the writer's `created`. Our own entries expire
// at created+ttl_s; a peer's get SkewTolerance more before we delete them,
// so a peer whose clock runs up to that far behind never loses a live copy
// to us. Larger skew is not corrected.
package store

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"time"

	"filippo.io/age"

	"clipd/internal/crypt"
	"clipd/internal/entry"
)

const (
	SkewTolerance = 60 * time.Second
	// TmpMaxAge: a temp file older than this is a crashed write.
	TmpMaxAge = time.Minute

	// heartbeatRenameTries bounds the replacing rename of a heartbeat. On
	// Windows Syncthing or Defender may hold hb-<origin>.age open for a
	// moment (dotfiles-jxzw); a few short retries absorb that, and a beat
	// that still fails is one missed beat, well inside the 90 s stale bound.
	heartbeatRenameTries = 5
	heartbeatRenameWait  = 20 * time.Millisecond
)

var (
	ErrNoFolder  = errors.New("store: sync folder missing")
	ErrBadOrigin = errors.New("store: origin must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}")

	idFile   = regexp.MustCompile(`^[0-9a-f]{16}\.age$`)
	hbFile   = regexp.MustCompile(`^hb-([A-Za-z0-9][A-Za-z0-9_-]{0,63})\.age$`)
	tmpFile  = regexp.MustCompile(`^\.(?:[0-9a-f]{16}|hb-[A-Za-z0-9_-]+)\.tmp$`)
	originRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)
)

type Store struct {
	Dir    string
	Origin string // this device's name
	Self   *age.X25519Identity
	Peers  []*age.X25519Recipient
	Cap    int
	Now    func() time.Time
	// Logf receives metadata only (ids, error classes) — never payload.
	Logf func(format string, args ...any)

	newID func() (string, error) // test seam; nil = crypto/rand
	// beforePublish is a test seam called with the complete temp file
	// and the final name, just before the final name appears.
	beforePublish func(tmp, final string)
	rename        func(old, new string) error // test seam; nil = os.Rename
}

type Item struct {
	ID    string
	Entry entry.Entry
}

// Stats counts files that were skipped because they could not be
// decrypted or decoded.
type Stats struct{ Skipped int }

func (s *Store) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Store) logf(format string, args ...any) {
	if s.Logf != nil {
		s.Logf(format, args...)
	}
}

func (s *Store) checkFolder() error {
	st, err := os.Stat(s.Dir)
	if errors.Is(err, fs.ErrNotExist) || (err == nil && !st.IsDir()) {
		return fmt.Errorf("%w: %s", ErrNoFolder, s.Dir)
	}
	return err
}

func (s *Store) id() (string, error) {
	if s.newID != nil {
		return s.newID()
	}
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// ValidOrigin reports ErrBadOrigin for a device name the store would
// refuse to write under, so callers can fail at startup rather than on
// every write.
func ValidOrigin(origin string) error {
	if !originRe.MatchString(origin) {
		return ErrBadOrigin
	}
	return nil
}

func (s *Store) seal(e entry.Entry) ([]byte, error) {
	if !originRe.MatchString(s.Origin) {
		return nil, ErrBadOrigin
	}
	e.Origin = s.Origin
	plain, err := entry.Encode(e, s.Cap)
	if err != nil {
		return nil, err
	}
	return crypt.Encrypt(plain, s.Self, s.Peers)
}

// writeTmp writes ct to a new dot-prefixed temp file (O_EXCL) and returns
// its path.
func (s *Store) writeTmp(name string, ct []byte) (string, error) {
	tmp := filepath.Join(s.Dir, "."+name+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	_, err = f.Write(ct)
	if serr := f.Sync(); err == nil {
		err = serr
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return "", err
	}
	return tmp, nil
}

// Write encrypts e (Origin is set to s.Origin) and publishes it under a
// fresh random id, returned on success.
func (s *Store) Write(e entry.Entry) (string, error) {
	if err := s.checkFolder(); err != nil {
		return "", err
	}
	ct, err := s.seal(e)
	if err != nil {
		return "", err
	}
	id, err := s.id()
	if err != nil {
		return "", err
	}
	tmp, err := s.writeTmp(id, ct)
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp)
	final := filepath.Join(s.Dir, id+".age")
	if s.beforePublish != nil {
		s.beforePublish(tmp, final)
	}
	// link fails with EEXIST instead of replacing an entry that has the id.
	if err := os.Link(tmp, final); err != nil {
		return "", fmt.Errorf("store: publish %s: %w", id, err)
	}
	return id, nil
}

// WriteHeartbeat replaces hb-<origin>.age with a fresh heartbeat.
func (s *Store) WriteHeartbeat() error {
	if err := s.checkFolder(); err != nil {
		return err
	}
	ct, err := s.seal(entry.Entry{Created: s.now().UnixMilli(), TTLs: entry.DefaultTTL, Mime: entry.MimeHeartbeat})
	if err != nil {
		return err
	}
	name := "hb-" + s.Origin
	os.Remove(filepath.Join(s.Dir, "."+name+".tmp")) // our own crashed attempt
	tmp, err := s.writeTmp(name, ct)
	if err != nil {
		return err
	}
	final := filepath.Join(s.Dir, name+".age")
	if s.beforePublish != nil {
		s.beforePublish(tmp, final)
	}
	rename := s.rename
	if rename == nil {
		rename = os.Rename
	}
	for try := 1; ; try++ {
		err = rename(tmp, final)
		if err == nil {
			return nil
		}
		if try == heartbeatRenameTries {
			os.Remove(tmp)
			return fmt.Errorf("store: publish heartbeat after %d tries: %w", try, err)
		}
		time.Sleep(heartbeatRenameWait)
	}
}

// Heartbeats returns the heartbeat of every origin found in the folder,
// keyed by origin. A file whose decrypted origin differs from its name,
// that is not a heartbeat, or that cannot be decrypted is skipped and
// counted: a peer must not be credited with liveness it did not report.
func (s *Store) Heartbeats() (map[string]entry.Entry, Stats, error) {
	var st Stats
	if err := s.checkFolder(); err != nil {
		return nil, st, err
	}
	des, err := os.ReadDir(s.Dir)
	if err != nil {
		return nil, st, err
	}
	hbs := map[string]entry.Entry{}
	for _, d := range des {
		m := hbFile.FindStringSubmatch(d.Name())
		if m == nil || !d.Type().IsRegular() {
			continue
		}
		e, err := s.readHeartbeat(d.Name())
		if errors.Is(err, fs.ErrNotExist) {
			continue // replaced or removed between ReadDir and read
		}
		if err == nil && e.Origin != m[1] {
			err = errors.New("store: heartbeat origin does not match its name")
		}
		if err != nil {
			st.Skipped++
			s.logf("store: skip heartbeat %s: %v", m[1], err)
			continue
		}
		hbs[m[1]] = e
	}
	return hbs, st, nil
}

// readHeartbeat decrypts a heartbeat, bounded to what an empty-data
// envelope can need.
func (s *Store) readHeartbeat(name string) (entry.Entry, error) {
	ct, err := os.ReadFile(filepath.Join(s.Dir, name))
	if err != nil {
		return entry.Entry{}, err
	}
	plain, err := crypt.Decrypt(ct, s.Self, entry.MaxEncoded(0))
	if err != nil {
		return entry.Entry{}, err
	}
	e, err := entry.Decode(plain, 0)
	if err != nil {
		return entry.Entry{}, err
	}
	if e.Mime != entry.MimeHeartbeat {
		return entry.Entry{}, errors.New("store: entry under a heartbeat name")
	}
	return e, nil
}

// scan decrypts every entry file, skipping (and counting) the ones it
// cannot read.
func (s *Store) scan() ([]Item, Stats, error) {
	var st Stats
	if err := s.checkFolder(); err != nil {
		return nil, st, err
	}
	des, err := os.ReadDir(s.Dir)
	if err != nil {
		return nil, st, err
	}
	var items []Item
	for _, d := range des {
		name := d.Name()
		if !d.Type().IsRegular() || !idFile.MatchString(name) {
			continue
		}
		id := name[:16]
		e, err := s.read(name)
		if errors.Is(err, fs.ErrNotExist) {
			continue // swept by a peer between ReadDir and read
		}
		if err != nil {
			st.Skipped++
			s.logf("store: skip %s: %v", id, err)
			continue
		}
		items = append(items, Item{ID: id, Entry: e})
	}
	return items, st, nil
}

func (s *Store) read(name string) (entry.Entry, error) {
	ct, err := os.ReadFile(filepath.Join(s.Dir, name))
	if err != nil {
		return entry.Entry{}, err
	}
	plain, err := crypt.Decrypt(ct, s.Self, entry.MaxEncoded(s.Cap))
	if err != nil {
		return entry.Entry{}, err
	}
	e, err := entry.Decode(plain, s.Cap)
	if err != nil {
		return entry.Entry{}, err
	}
	if e.Mime == entry.MimeHeartbeat {
		return entry.Entry{}, errors.New("store: heartbeat under an entry name")
	}
	return e, nil
}

func expiry(e entry.Entry) time.Time {
	return time.UnixMilli(e.Created).Add(time.Duration(e.TTLs) * time.Second)
}

// List returns unexpired entries, newest first by created.
func (s *Store) List() ([]Item, Stats, error) {
	items, st, err := s.scan()
	if err != nil {
		return nil, st, err
	}
	now := s.now()
	live := items[:0]
	for _, it := range items {
		if !now.After(expiry(it.Entry)) {
			live = append(live, it)
		}
	}
	sort.Slice(live, func(i, j int) bool {
		if live[i].Entry.Created != live[j].Entry.Created {
			return live[i].Entry.Created > live[j].Entry.Created
		}
		return live[i].ID > live[j].ID
	})
	return live, st, nil
}

// Sweep deletes expired entries (ours at expiry, a peer's SkewTolerance
// later) and temp files older than TmpMaxAge from any writer (a crash
// leftover; Syncthing may have synced a peer's). Files it cannot decrypt are left to
// their writer. It returns how many entries it removed.
func (s *Store) Sweep() (int, Stats, error) {
	items, st, err := s.scan()
	if err != nil {
		return 0, st, err
	}
	now := s.now()
	removed := 0
	for _, it := range items {
		exp := expiry(it.Entry)
		if it.Entry.Origin != s.Origin {
			exp = exp.Add(SkewTolerance)
		}
		if !now.After(exp) {
			continue
		}
		err := os.Remove(filepath.Join(s.Dir, it.ID+".age"))
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			s.logf("store: sweep %s: %v", it.ID, err)
			continue
		}
		removed++
	}
	des, _ := os.ReadDir(s.Dir)
	for _, d := range des {
		if !tmpFile.MatchString(d.Name()) {
			continue
		}
		if fi, err := d.Info(); err == nil && now.Sub(fi.ModTime()) > TmpMaxAge {
			os.Remove(filepath.Join(s.Dir, d.Name()))
		}
	}
	return removed, st, nil
}
