package agent

// Windows agent wiring (sp039 Task 7, [[poc024]]). Everything here is
// OS-neutral: the Win32 side is behind WinClipboard / WinView, which
// internal/winclip implements on Windows and the tests fake anywhere.
//
// Per WM_CLIPBOARDUPDATE:
//
//  1. GetClipboardSequenceNumber unchanged since the last settled event →
//     nothing to do (one copy fires 2-3 events).
//  2. Open the clipboard (bounded: winclip.OpenTries × OpenWait), enumerate
//     formats. ExcludeClipboardContentFromMonitorProcessing present →
//     close, write nothing, read nothing.
//  3. Read CF_UNICODETEXT if offered, else an image (registered PNG, else
//     CF_DIB → PNG). Text wins over image on Windows: Office and Excel
//     put a bitmap next to the text of an ordinary text copy.
//  4. Nothing readable yet (only DataObject / Ole Private Data, or empty
//     text — the owner renders late) → wait WinRereadDelay, read once
//     more; still nothing → skip.
//  5. Content hash equal to the last entry written (burst) or to the last
//     `clipd pick` (echo guard, state file) → no entry. Else one entry.

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"clipd/internal/entry"
	"clipd/internal/store"
	"clipd/internal/winclip"
)

const (
	// WinRereadDelay is the single re-read after a delayed-render event.
	WinRereadDelay = 100 * time.Millisecond
	// WinHeartbeat is the heartbeat (and sweep) period.
	WinHeartbeat = 30 * time.Second
	// WinPickedFile holds the keyed hash of the last pick (echo guard);
	// WinKeyFile the 32-byte HMAC key. Same names and scheme as the X
	// agent's state (Task 4), so either side's pick is honoured.
	WinPickedFile = "last-picked"
	WinKeyFile    = "hash.key"
)

// WinView is an open clipboard.
type WinView interface {
	Formats() ([]winclip.Format, error)
	// Text returns CF_UNICODETEXT as UTF-8; nil when not rendered.
	Text(max int) ([]byte, error)
	// Image returns PNG bytes; nil when no image is rendered.
	Image(max int) ([]byte, error)
}

// WinClipboard is the Win32 clipboard as the agent sees it.
type WinClipboard interface {
	Seq() uint32
	// View opens the clipboard (bounded retries, then winclip.ErrBusy),
	// runs fn, closes.
	View(fn func(WinView) error) error
}

// WinSink receives entries; *store.Store implements it.
type WinSink interface {
	Write(entry.Entry) (string, error)
}

// WinOutcome is what one event resulted in (tests and logs).
type WinOutcome int

const (
	WinSameSeq  WinOutcome = iota // sequence number already settled
	WinWritten                    // one entry written
	WinDup                        // same content as the last entry
	WinEcho                       // content of the last pick
	WinExcluded                   // password-manager marker: not read
	WinDelayed                    // nothing rendered even after the re-read
	WinSkipped                    // over cap, unsupported, empty, write failed
	WinBusy                       // OpenClipboard contention: skipped
)

func (o WinOutcome) String() string {
	return [...]string{"same-seq", "written", "dup", "echo", "excluded", "delayed", "skipped", "busy"}[o]
}

// WinAgent turns clipboard events into entries.
type WinAgent struct {
	Clip WinClipboard
	Sink WinSink
	Cap  int
	TTL  int
	// StateDir holds WinPickedFile; "" disables the echo guard.
	StateDir string
	Now      func() time.Time
	Sleep    func(time.Duration)
	// Logf receives metadata only (seq, outcome, mime, size, id).
	Logf func(format string, args ...any)

	lastSeq  uint32
	settled  bool
	lastHash string
	key      []byte
}

// WinHash is the content hash used for dedupe and the echo guard:
// HMAC-SHA256 under the state dir's key, never a plain hash — a plain
// sha256 of a short password in last-picked could be brute-forced.
func WinHash(key []byte, mime string, data []byte) string {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(mime))
	h.Write([]byte{0})
	h.Write(data)
	return hex.EncodeToString(h.Sum(nil))
}

// winLoadKey returns dir's 32-byte hash key, creating dir (0700) and key
// (0600, O_EXCL — a concurrent creator wins and we read theirs).
func winLoadKey(dir string) ([]byte, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("winagent: state dir: %w", err)
	}
	p := filepath.Join(dir, WinKeyFile)
	for i := 0; i < 2; i++ {
		b, err := os.ReadFile(p)
		switch {
		case err == nil && len(b) == 32:
			return b, nil
		case err == nil:
			return nil, fmt.Errorf("winagent: %s: want 32 bytes, have %d", p, len(b))
		case !errors.Is(err, os.ErrNotExist):
			return nil, fmt.Errorf("winagent: hash key: %w", err)
		}
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("winagent: hash key: %w", err)
		}
		_, err = f.Write(key)
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			os.Remove(p)
			return nil, fmt.Errorf("winagent: hash key: %w", err)
		}
		return key, nil
	}
	return nil, fmt.Errorf("winagent: hash key %s unreadable", p)
}

func (a *WinAgent) logf(format string, args ...any) {
	if a.Logf != nil {
		a.Logf(format, args...)
	}
}

func (a *WinAgent) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

func (a *WinAgent) sleep(d time.Duration) {
	if a.Sleep != nil {
		a.Sleep(d)
		return
	}
	time.Sleep(d)
}

func (a *WinAgent) picked() string {
	if a.StateDir == "" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(a.StateDir, WinPickedFile))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// Prime loads the hash key (a random in-memory one when StateDir is "")
// and marks the clipboard as it is now settled, so content copied before
// the agent started is not published.
func (a *WinAgent) Prime() error {
	if a.StateDir == "" {
		a.key = make([]byte, 32)
		rand.Read(a.key)
	} else {
		k, err := winLoadKey(a.StateDir)
		if err != nil {
			return err
		}
		a.key = k
	}
	a.lastSeq, a.settled = a.Clip.Seq(), true
	return nil
}

// capture reads the clipboard once. data is nil unless outcome is
// WinWritten-eligible (the caller hashes and writes).
func (a *WinAgent) capture() (WinOutcome, string, []byte) {
	var (
		out  WinOutcome
		mime string
		data []byte
	)
	err := a.Clip.View(func(v WinView) error {
		fs, err := v.Formats()
		if err != nil {
			return err
		}
		hasText, hasImage := false, false
		for _, f := range fs {
			switch {
			case f.Name == winclip.ExcludeName:
				out = WinExcluded // checked before any payload read
				return nil
			case f.ID == winclip.CFUnicodeText:
				hasText = true
			case f.ID == winclip.CFDIB, f.ID == winclip.CFDIBV5, f.Name == winclip.PNGName:
				hasImage = true
			}
		}
		switch {
		case hasText:
			mime = entry.MimeText
			data, err = v.Text(a.Cap)
		case hasImage:
			mime = entry.MimePNG
			data, err = v.Image(a.Cap)
		case len(fs) == 0:
			out = WinSkipped // clipboard emptied
			return nil
		}
		if err != nil {
			return err
		}
		if len(data) == 0 {
			out = WinDelayed
			return nil
		}
		out = WinWritten
		return nil
	})
	switch {
	case errors.Is(err, winclip.ErrBusy):
		return WinBusy, "", nil
	case err != nil:
		a.logf("winagent: read: %v", err) // winclip errors carry no payload
		return WinSkipped, "", nil
	}
	return out, mime, data
}

// Handle processes one clipboard event.
func (a *WinAgent) Handle() WinOutcome {
	seq := a.Clip.Seq()
	if a.settled && seq == a.lastSeq {
		return WinSameSeq
	}
	out, mime, data := a.capture()
	if out == WinDelayed {
		a.sleep(WinRereadDelay)
		seq = a.Clip.Seq()
		out, mime, data = a.capture()
	}
	if out == WinBusy || out == WinDelayed {
		// Not settled: the next event for this seq gets another try.
		a.logf("winagent: seq %d %s", seq, out)
		return out
	}
	a.lastSeq, a.settled = seq, true
	if out != WinWritten {
		a.logf("winagent: seq %d %s", seq, out)
		return out
	}
	h := WinHash(a.key, mime, data)
	switch h {
	case a.lastHash:
		out = WinDup
	case a.picked():
		out = WinEcho
	}
	if out != WinWritten {
		a.logf("winagent: seq %d %s", seq, out)
		return out
	}
	id, err := a.Sink.Write(entry.Entry{Created: a.now().UnixMilli(), TTLs: a.TTL, Mime: mime, Data: data})
	if err != nil {
		a.logf("winagent: seq %d write %s %d bytes: %v", seq, mime, len(data), err)
		return WinSkipped
	}
	a.lastHash = h
	a.logf("winagent: seq %d wrote %s %s %d bytes", seq, id, mime, len(data))
	return WinWritten
}

// WinRun handles events until ctx ends, writing a heartbeat and sweeping
// expired entries every WinHeartbeat. A missing folder is logged on each
// write/heartbeat and the loop carries on (setup creates it).
func WinRun(ctx context.Context, a *WinAgent, s *store.Store, events <-chan struct{}) error {
	beat := func() {
		if err := s.WriteHeartbeat(); err != nil {
			a.logf("winagent: heartbeat: %v", err)
			return
		}
		if n, _, err := s.Sweep(); err != nil {
			a.logf("winagent: sweep: %v", err)
		} else if n > 0 {
			a.logf("winagent: swept %d", n)
		}
	}
	if err := a.Prime(); err != nil {
		return err
	}
	beat()
	t := time.NewTicker(WinHeartbeat)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case _, ok := <-events:
			if !ok {
				return errors.New("winagent: listener closed")
			}
			a.Handle()
		case <-t.C:
			beat()
		}
	}
}

// WinBackoff retries start (e.g. winclip.Listen before the logon
// session's window station is ready) with doubling delays from 1 s up to
// 30 s, at most tries times ([[adr0014]]: bounded, fail fast).
func WinBackoff[T any](ctx context.Context, tries int, sleep func(time.Duration), logf func(string, ...any), start func() (T, error)) (T, error) {
	var zero T
	d := time.Second
	var err error
	for i := 1; i <= tries; i++ {
		var v T
		if v, err = start(); err == nil {
			return v, nil
		}
		if i == tries || ctx.Err() != nil {
			break
		}
		logf("winagent: start attempt %d/%d: %v; retry in %s", i, tries, err, d)
		sleep(d)
		if d *= 2; d > 30*time.Second {
			d = 30 * time.Second
		}
	}
	return zero, fmt.Errorf("winagent: gave up after %d attempts: %w", tries, err)
}
