// Package agent is clipd's clipboard-to-folder loop (sp039 Task 4): it
// watches one native clipboard and writes each new copy as one encrypted
// entry into the sync folder. It never applies anything to the clipboard
// — remote entries reach it only through `clipd pick` ([[adr0010]]).
//
// The platform-neutral half is Agent.Offer and Agent.Tick: dedupe, echo
// guard, pending-write retry, heartbeat and sweep. Platform wiring feeds
// Offer: RunX drives X through internal/xsel; the Windows agent
// (windows*.go, Task 7) feeds the same Offer from the Win32 listener.
//
// Gate order in CaptureX, which is the security property:
//
//  1. read TARGETS (bounded); a password-manager hint means stop here —
//     the payload is never requested;
//  2. read image/png if advertised, else UTF8_STRING; nothing else
//     (image/bmp-only owners are skipped, never laundered into text);
//  3. re-read TARGETS and drop the payload if a hint-bearing owner took
//     the selection between 1 and 2 (the clip-store.sh TOCTOU re-check;
//     fails closed).
//
// Dedupe and echo guard compare keyed hashes (HMAC-SHA256, key in
// StateDir/hash.key, 0600), never plaintext: an unkeyed hash of a short
// password would be a brute-forceable copy of it on disk. last-written is
// per agent (StateDir/last-written.<Name>); last-picked is shared by every
// agent on the host and is written by `clipd pick` via RecordPick, so the
// agent does not re-send content the user just picked from a peer.
//
// Logs carry metadata only: ids, mime, sizes, targets counts, error
// classes. Payload bytes never reach Logf or an error.
//
// Bounded failure ([[adr0014]]): a missing folder keeps the newest copy
// pending in memory and retries it with exponential backoff (RetryBase
// doubling to RetryMax) until it expires; clipnotify failures back off the
// same way and RunX returns an error after MaxWatchFailures in a row
// (usually the display is gone) instead of respawning hot; every watcher
// iteration takes at least Floor.
package agent

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"clipd/internal/entry"
	"clipd/internal/store"
	"clipd/internal/xsel"
)

const (
	DefaultHeartbeat = 30 * time.Second
	DefaultFloor     = 20 * time.Millisecond
	DefaultRetryBase = time.Second
	DefaultRetryMax  = 30 * time.Second
	MaxWatchFailures = 5

	keyFile    = "hash.key"
	pickedFile = "last-picked"
)

// Outcome says what Offer did with one copy.
type Outcome string

const (
	Written Outcome = "written"
	Dup     Outcome = "dup"     // same as the last entry this agent wrote
	Echo    Outcome = "echo"    // same as the last `clipd pick`
	Pending Outcome = "pending" // folder missing; retried with backoff
	Dropped Outcome = "dropped" // refused (size, empty) or expired pending
)

// Store is the subset of store.Store the agent uses.
type Store interface {
	Write(entry.Entry) (string, error)
	WriteHeartbeat() error
	Sweep() (int, store.Stats, error)
}

// Selection is one watched clipboard; *xsel.X implements it.
type Selection interface {
	Targets(ctx context.Context) ([]string, error)
	Read(ctx context.Context, target string, limit int) ([]byte, error)
	Wait(ctx context.Context) error
}

type Agent struct {
	Store    Store
	StateDir string // created 0700 if missing
	Name     string // state-file suffix for this agent, e.g. the display
	Cap      int    // payload cap; 0 = entry.DefaultCap
	TTL      int    // seconds; 0 = entry.DefaultTTL

	Heartbeat time.Duration // 0 = DefaultHeartbeat
	Floor     time.Duration // 0 = DefaultFloor
	RetryBase time.Duration // 0 = DefaultRetryBase
	RetryMax  time.Duration // 0 = DefaultRetryMax

	Now  func() time.Time
	Logf func(format string, args ...any) // metadata only

	key         []byte
	lastWritten string
	pending     *pendingEntry
	retryIn     time.Duration
	retryAt     time.Time
	hbFailing   bool
}

type pendingEntry struct {
	e    entry.Entry
	hash string
}

var nameRe = regexp.MustCompile(`[^A-Za-z0-9._-]`)

func dur(d, def time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	return def
}

func (a *Agent) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

func (a *Agent) logf(format string, args ...any) {
	if a.Logf != nil {
		a.Logf(format, args...)
	}
}

func (a *Agent) cap() int {
	if a.Cap > 0 {
		return a.Cap
	}
	return entry.DefaultCap
}

func (a *Agent) ttl() int {
	if a.TTL > 0 {
		return a.TTL
	}
	return entry.DefaultTTL
}

func (a *Agent) writtenPath() string {
	return filepath.Join(a.StateDir, "last-written."+nameRe.ReplaceAllString(a.Name, "_"))
}

// Init prepares the state dir and hash key and loads last-written. RunX
// calls it; Offer callers that skip RunX (Windows wiring, tests) call it
// first.
func (a *Agent) Init() error {
	key, err := loadKey(a.StateDir)
	if err != nil {
		return err
	}
	a.key = key
	if b, err := os.ReadFile(a.writtenPath()); err == nil {
		a.lastWritten = strings.TrimSpace(string(b))
	}
	return nil
}

// loadKey returns StateDir's hash key, creating dir and key on first use.
func loadKey(dir string) ([]byte, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("agent: state dir: %w", err)
	}
	p := filepath.Join(dir, keyFile)
	for i := 0; i < 2; i++ {
		if b, err := os.ReadFile(p); err == nil && len(b) == 32 {
			return b, nil
		} else if err == nil {
			return nil, fmt.Errorf("agent: %s: want 32 bytes, have %d", p, len(b))
		} else if !errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("agent: hash key: %w", err)
		}
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return nil, err
		}
		if err := writeExcl(p, key); err != nil && !errors.Is(err, fs.ErrExist) {
			return nil, fmt.Errorf("agent: hash key: %w", err)
		}
		// lost a create race with a concurrent agent/pick: read theirs.
	}
	return nil, fmt.Errorf("agent: hash key %s unreadable", p)
}

func writeExcl(p string, b []byte) error {
	tmp := p + ".tmp" + hex.EncodeToString(randBytes(4))
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	defer os.Remove(tmp)
	return os.Link(tmp, p) // fails with EEXIST, never replaces
}

func writeReplace(p string, b []byte) error {
	tmp := p + ".tmp" + hex.EncodeToString(randBytes(4))
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	rand.Read(b)
	return b
}

func keyedHash(key []byte, mime string, data []byte) string {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(mime))
	m.Write([]byte{0})
	m.Write(data)
	return hex.EncodeToString(m.Sum(nil))
}

// RecordPick stores the keyed hash of content `clipd pick` just published
// (Task 5), so every agent on this host treats it as an echo, not a copy.
func RecordPick(stateDir, mime string, data []byte) error {
	key, err := loadKey(stateDir)
	if err != nil {
		return err
	}
	return writeReplace(filepath.Join(stateDir, pickedFile), []byte(keyedHash(key, mime, data)+"\n"))
}

func (a *Agent) lastPicked() string {
	b, err := os.ReadFile(filepath.Join(a.StateDir, pickedFile))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// Offer handles one copy read from the native clipboard. data is owned by
// the agent from here on and zeroed once it is no longer needed.
func (a *Agent) Offer(mime string, data []byte) Outcome {
	if a.key == nil {
		panic("agent: Offer before Init")
	}
	h := keyedHash(a.key, mime, data)
	switch h {
	case a.lastWritten:
		clear(data)
		a.logf("agent: skip dup mime=%s size=%d", mime, len(data))
		return Dup
	case a.lastPicked():
		clear(data)
		a.logf("agent: skip echo of pick mime=%s size=%d", mime, len(data))
		return Echo
	}
	if a.pending != nil {
		clear(a.pending.e.Data) // superseded by a newer copy
	}
	a.pending = &pendingEntry{
		e:    entry.Entry{Created: a.now().UnixMilli(), TTLs: a.ttl(), Mime: mime, Data: data},
		hash: h,
	}
	a.retryIn = 0
	return a.flush()
}

// flush tries to write the pending entry.
func (a *Agent) flush() Outcome {
	p := a.pending
	if p == nil {
		return ""
	}
	size := len(p.e.Data)
	if a.now().After(time.UnixMilli(p.e.Created).Add(time.Duration(p.e.TTLs) * time.Second)) {
		a.dropPending()
		a.logf("agent: drop pending mime=%s size=%d: expired before the folder came back", p.e.Mime, size)
		return Dropped
	}
	id, err := a.Store.Write(p.e)
	switch {
	case err == nil:
		a.lastWritten = p.hash
		if werr := writeReplace(a.writtenPath(), []byte(p.hash+"\n")); werr != nil {
			a.logf("agent: state: %v", werr)
		}
		a.dropPending()
		a.logf("agent: wrote %s mime=%s size=%d", id, p.e.Mime, size)
		return Written
	case errors.Is(err, store.ErrNoFolder):
		a.retryIn = min(max(2*a.retryIn, dur(a.RetryBase, DefaultRetryBase)), dur(a.RetryMax, DefaultRetryMax))
		a.retryAt = a.now().Add(a.retryIn)
		a.logf("agent: folder missing, entry mime=%s size=%d pending, retry in %v", p.e.Mime, size, a.retryIn)
		return Pending
	default:
		a.dropPending()
		a.logf("agent: drop mime=%s size=%d: %v", p.e.Mime, size, err)
		return Dropped
	}
}

func (a *Agent) dropPending() {
	if a.pending != nil {
		clear(a.pending.e.Data)
		a.pending = nil
	}
	a.retryIn = 0
}

// RetryDue returns when the pending entry should be retried; ok is false
// when nothing is pending.
func (a *Agent) RetryDue() (time.Time, bool) {
	if a.pending == nil {
		return time.Time{}, false
	}
	return a.retryAt, true
}

// Retry re-attempts the pending entry (call at RetryDue).
func (a *Agent) Retry() Outcome { return a.flush() }

// Tick writes the heartbeat and sweeps expired entries; a heartbeat that
// succeeds while an entry is pending retries it at once (the folder is
// back).
func (a *Agent) Tick() {
	err := a.Store.WriteHeartbeat()
	switch {
	case err != nil && !a.hbFailing:
		a.hbFailing = true
		a.logf("agent: heartbeat: %v", err)
	case err == nil && a.hbFailing:
		a.hbFailing = false
		a.logf("agent: heartbeat ok again")
	}
	if err != nil {
		return
	}
	if n, st, err := a.Store.Sweep(); err != nil {
		a.logf("agent: sweep: %v", err)
	} else if n > 0 || st.Skipped > 0 {
		a.logf("agent: sweep removed=%d skipped=%d", n, st.Skipped)
	}
	if a.pending != nil {
		a.flush()
	}
}

// CaptureX reads the current X CLIPBOARD through the gates in the package
// doc and offers it. It returns "" when nothing was offered.
func (a *Agent) CaptureX(ctx context.Context, sel Selection) Outcome {
	ts, err := sel.Targets(ctx)
	if err != nil {
		a.logf("agent: skip: %v", err)
		return ""
	}
	if xsel.Hinted(ts) {
		a.logf("agent: skip: password-manager hint (%d targets), payload not read", len(ts))
		return ""
	}
	target, ok := xsel.Choose(ts)
	if !ok {
		a.logf("agent: skip: no image/png or UTF8_STRING target (%d targets)", len(ts))
		return ""
	}
	data, err := sel.Read(ctx, target, a.cap())
	if err != nil {
		a.logf("agent: skip: %v", err)
		return ""
	}
	if len(data) == 0 {
		a.logf("agent: skip: empty %s", target)
		return ""
	}
	ts, err = sel.Targets(ctx)
	if err != nil || xsel.Hinted(ts) {
		clear(data)
		a.logf("agent: drop %s size=%d: owner changed to a hinted or unreadable one during read", target, len(data))
		return ""
	}
	mime := entry.MimeText
	if target == xsel.TargetPNG {
		mime = entry.MimePNG
	}
	return a.Offer(mime, data)
}

// RunX watches sel until ctx ends (returns nil) or the watcher gives up
// (returns its error). A heartbeat is written at start and every
// Heartbeat.
func (a *Agent) RunX(ctx context.Context, sel Selection) error {
	if err := a.Init(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	var wg sync.WaitGroup
	defer wg.Wait()
	defer cancel()

	events := make(chan struct{}, 1) // coalescing: one pending event is enough
	errc := make(chan error, 1)
	wg.Add(1)
	go func() {
		defer wg.Done()
		a.watch(ctx, sel, events, errc)
	}()

	hb := time.NewTicker(dur(a.Heartbeat, DefaultHeartbeat))
	defer hb.Stop()
	a.Tick()
	for {
		var retry <-chan time.Time
		var t *time.Timer
		if at, ok := a.RetryDue(); ok {
			t = time.NewTimer(max(at.Sub(a.now()), 0))
			retry = t.C
		}
		select {
		case <-ctx.Done():
			a.dropPending()
			return nil
		case err := <-errc:
			a.dropPending()
			return err
		case <-events:
			a.CaptureX(ctx, sel)
		case <-hb.C:
			a.Tick()
		case <-retry:
			a.Retry()
		}
		if t != nil {
			t.Stop()
		}
	}
}

// watch re-arms clipnotify in its own goroutine so a slow capture never
// widens the re-arm gap; events coalesce in the 1-slot channel and the
// capture reads the newest clipboard. Copies overwritten while a capture
// runs are gone from X itself and cannot be recovered by any reader.
func (a *Agent) watch(ctx context.Context, sel Selection, events chan<- struct{}, errc chan<- error) {
	fails := 0
	backoff := time.Duration(0)
	for {
		start := time.Now()
		err := sel.Wait(ctx)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			fails++
			if fails >= MaxWatchFailures {
				errc <- fmt.Errorf("agent: watcher gave up after %d failures: %w", fails, err)
				return
			}
			backoff = min(max(2*backoff, dur(a.RetryBase, DefaultRetryBase)), dur(a.RetryMax, DefaultRetryMax))
			a.logf("agent: watch: %v; retry in %v", err, backoff)
			if !sleep(ctx, backoff) {
				return
			}
			continue
		}
		fails, backoff = 0, 0
		select {
		case events <- struct{}{}:
		default:
		}
		if !sleep(ctx, dur(a.Floor, DefaultFloor)-time.Since(start)) {
			return
		}
	}
}

func sleep(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return ctx.Err() == nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
