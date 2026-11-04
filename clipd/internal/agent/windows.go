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
	// WinPickedFile holds the hex hash of the last pick (echo guard).
	WinPickedFile = "last-picked"
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
}

// WinHash is the content hash used for dedupe and the echo guard.
func WinHash(mime string, data []byte) string {
	h := sha256.New()
	h.Write([]byte(mime))
	h.Write([]byte{0})
	h.Write(data)
	return hex.EncodeToString(h.Sum(nil))
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

// Prime marks the clipboard as it is now settled, so content copied
// before the agent started is not published.
func (a *WinAgent) Prime() {
	a.lastSeq, a.settled = a.Clip.Seq(), true
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
	h := WinHash(mime, data)
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
	a.Prime()
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

// ErrWinNotFound: no live entry with that id (expired, swept, never
// existed) or, for --latest, no live remote entry. CLI exit 1.
var ErrWinNotFound = errors.New("no such live entry")

// WinList writes `<id>\t<origin>\t<age-s>\t<preview>` for every live
// remote entry, newest first. Own entries are omitted: they are already
// on this host's clipboard. Decrypted in memory only. (OS-neutral; named
// Win* only to stay clear of Task 4/5 identifiers until they merge.)
func WinList(s *store.Store, w interface{ Write([]byte) (int, error) }) error {
	items, _, err := s.List()
	if err != nil {
		return err
	}
	now := s.Now
	if now == nil {
		now = time.Now
	}
	for _, it := range items {
		if it.Entry.Origin == s.Origin {
			continue
		}
		age := now().Sub(time.UnixMilli(it.Entry.Created)) / time.Second
		if age < 0 {
			age = 0
		}
		fmt.Fprintf(w, "%s\t%s\t%d\t%s\n", it.ID, it.Entry.Origin, int64(age), WinPreview(it.Entry))
	}
	return nil
}

// WinPreview renders an entry on one line of at most 80 runes: control,
// format (bidi, zero-width) and line-break characters are escaped as
// \n, \t, \r or \u{XXXX}; PNG entries read `[image WxH]`.
func WinPreview(e entry.Entry) string {
	if e.Mime == entry.MimePNG {
		if w, h, ok := pngSize(e.Data); ok {
			return fmt.Sprintf("[image %dx%d]", w, h)
		}
		return "[image]"
	}
	const max = 80
	var out []rune
	for _, r := range strings.ToValidUTF8(string(e.Data), "\uFFFD") {
		switch {
		case r == '\n':
			out = append(out, '\\', 'n')
		case r == '\t':
			out = append(out, '\\', 't')
		case r == '\r':
			out = append(out, '\\', 'r')
		case r == '\\':
			out = append(out, '\\', '\\')
		case unsafeRune(r):
			out = append(out, []rune(fmt.Sprintf(`\u{%04X}`, r))...)
		default:
			out = append(out, r)
		}
		if len(out) > max {
			return string(out[:max-1]) + "…"
		}
	}
	return string(out)
}

func unsafeRune(r rune) bool {
	switch {
	case r < 0x20, r == 0x7F, r >= 0x80 && r < 0xA0: // C0, DEL, C1
		return true
	case r == 0x061C, r == 0x200E, r == 0x200F, // bidi marks
		r >= 0x202A && r <= 0x202E, r >= 0x2066 && r <= 0x2069, // embeddings, isolates
		r >= 0x200B && r <= 0x200D, r == 0x2060, r == 0xFEFF, // zero-width
		r == 0x2028, r == 0x2029: // line / paragraph separator
		return true
	}
	return false
}

// pngSize reads width/height from the IHDR chunk.
func pngSize(b []byte) (int, int, bool) {
	if len(b) < 24 || string(b[1:4]) != "PNG" || string(b[12:16]) != "IHDR" {
		return 0, 0, false
	}
	be := func(p []byte) int { return int(p[0])<<24 | int(p[1])<<16 | int(p[2])<<8 | int(p[3]) }
	return be(b[16:20]), be(b[20:24]), true
}

// WinPick finds entry id (or, with id == "", the newest live remote
// entry), records its hash as the echo guard in stateDir, then hands it
// to publish. The guard is written first so the agent, woken by the
// publish, already sees it. Errors: ErrWinNotFound (exit 1), a state or
// publish failure (exit 2); never payload.
func WinPick(s *store.Store, id, stateDir string, publish func(isPNG bool, data []byte) error) (entry.Entry, error) {
	items, _, err := s.List()
	if err != nil {
		return entry.Entry{}, err
	}
	var hit *store.Item
	for i := range items {
		it := &items[i]
		if (id == "" && it.Entry.Origin != s.Origin) || (id != "" && it.ID == id) {
			hit = it
			break
		}
	}
	if hit == nil {
		return entry.Entry{}, ErrWinNotFound
	}
	e := hit.Entry
	if err := writeState(stateDir, WinPickedFile, WinHash(e.Mime, e.Data)); err != nil {
		return e, fmt.Errorf("%w: echo guard: %v", ErrWinPublish, err)
	}
	if err := publish(e.Mime == entry.MimePNG, e.Data); err != nil {
		return e, fmt.Errorf("%w: %v", ErrWinPublish, err)
	}
	return e, nil
}

// ErrWinPublish: the native clipboard was not set. CLI exit 2.
var ErrWinPublish = errors.New("publish failed")

// writeState replaces stateDir/name atomically (temp + rename).
func writeState(dir, name, val string) error {
	if dir == "" {
		return nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+name+".*")
	if err != nil {
		return err
	}
	_, err = tmp.WriteString(val + "\n")
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), filepath.Join(dir, name))
	}
	if err != nil {
		os.Remove(tmp.Name())
	}
	return err
}
