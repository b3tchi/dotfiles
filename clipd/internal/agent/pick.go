package agent

// `clipd list` and `clipd pick` (sp039 Tasks 5 and 7): the folder side of
// picking, shared by every platform. The caller supplies publish, which
// puts the bytes on the native clipboard (xsel on X, winclip on Windows).
// Only pick writes the native clipboard, and it is only ever run by the
// user ([[adr0010]]): copies, never pastes.

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"clipd/internal/entry"
	"clipd/internal/store"
)

// ErrNotFound: no live entry with that id (expired, swept, never
// existed) or, for --latest, no live remote entry. CLI exit 1.
var ErrNotFound = errors.New("no such live entry")

// List writes `<id>\t<origin>\t<age-s>\t<preview>` for every live
// remote entry, newest first. Own entries are omitted: they are already
// on this host's clipboard. Decrypted in memory only.
func List(s *store.Store, w interface{ Write([]byte) (int, error) }) error {
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
		fmt.Fprintf(w, "%s\t%s\t%d\t%s\n", it.ID, it.Entry.Origin, int64(age), Preview(it.Entry))
	}
	return nil
}

// Preview renders an entry on one line of at most 80 runes: control,
// format (bidi, zero-width) and line-break characters are escaped as
// \n, \t, \r or \u{XXXX}; PNG entries read `[image WxH]`.
func Preview(e entry.Entry) string {
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

// Pick finds entry id (or, with id == "", the newest live remote
// entry), records its hash as the echo guard in stateDir, then hands it
// to publish. The guard is written first so the agent, woken by the
// publish, already sees it. Errors: ErrNotFound (exit 1), a state or
// publish failure (exit 2); never payload.
func Pick(s *store.Store, id, stateDir string, publish func(isPNG bool, data []byte) error) (entry.Entry, error) {
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
		return entry.Entry{}, ErrNotFound
	}
	e := hit.Entry
	if err := RecordPick(stateDir, e.Mime, e.Data); err != nil {
		return e, fmt.Errorf("%w: echo guard: %v", ErrPublish, err)
	}
	if err := publish(e.Mime == entry.MimePNG, e.Data); err != nil {
		return e, fmt.Errorf("%w: %v", ErrPublish, err)
	}
	return e, nil
}

// ErrPublish: the native clipboard was not set. CLI exit 2.
var ErrPublish = errors.New("publish failed")
