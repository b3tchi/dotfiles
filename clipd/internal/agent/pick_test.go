package agent

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"filippo.io/age"

	"clipd/internal/entry"
	"clipd/internal/store"
)

// --- list / pick against a real store ---

func storeRig(t *testing.T) (*store.Store, *store.Store) {
	t.Helper()
	dir := t.TempDir()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	mk := func(origin string) *store.Store {
		return &store.Store{Dir: dir, Origin: origin, Self: id, Cap: entry.DefaultCap, Now: func() time.Time { return now }}
	}
	return mk("win"), mk("linux")
}

func put(t *testing.T, s *store.Store, mime string, data []byte, age time.Duration, ttl int) string {
	t.Helper()
	id, err := s.Write(entry.Entry{Created: s.Now().Add(-age).UnixMilli(), TTLs: ttl, Mime: mime, Data: data})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func pngOf(w, h int) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	img.Set(0, 0, color.NRGBA{255, 0, 0, 255})
	var b bytes.Buffer
	png.Encode(&b, img)
	return b.Bytes()
}

func TestListOmitsOwnAndExpired(t *testing.T) {
	self, peer := storeRig(t)
	put(t, self, entry.MimeText, []byte("own"), time.Second, 300)
	put(t, peer, entry.MimeText, []byte("expired"), 400*time.Second, 300)
	older := put(t, peer, entry.MimeText, []byte("line1\nline2‮"), 20*time.Second, 300)
	newer := put(t, peer, entry.MimePNG, pngOf(3, 2), 5*time.Second, 300)

	var out bytes.Buffer
	if err := List(self, &out); err != nil {
		t.Fatal(err)
	}
	want := newer + "\tlinux\t5\t[image 3x2]\n" + older + "\tlinux\t20\tline1\\nline2\\u{202E}\n"
	if out.String() != want {
		t.Fatalf("list:\n%q\nwant\n%q", out.String(), want)
	}
}

func TestPreviewEscapesControlChars(t *testing.T) {
	p := Preview(entry.Entry{Mime: entry.MimeText, Data: []byte(strings.Repeat("é", 200))})
	if n := len([]rune(p)); n != 80 || !strings.HasSuffix(p, "…") {
		t.Fatalf("preview %d runes: %q", n, p)
	}
	p = Preview(entry.Entry{Mime: entry.MimeText, Data: []byte("a\x00b​c\td")})
	if p != `a\u{0000}b\u{200B}c\td` {
		t.Fatalf("preview %q", p)
	}
}

func TestPick(t *testing.T) {
	self, peer := storeRig(t)
	state := t.TempDir()
	put(t, self, entry.MimeText, []byte("own newest"), 0, 300)
	old := put(t, peer, entry.MimeText, []byte("old"), 30*time.Second, 300)
	put(t, peer, entry.MimeText, []byte("latest remote"), 10*time.Second, 300)
	gone := put(t, peer, entry.MimeText, []byte("expired"), 301*time.Second, 300)

	var got []string
	pub := func(isPNG bool, b []byte) error { got = append(got, string(b)); return nil }

	if _, err := Pick(self, "", state, pub); err != nil || got[0] != "latest remote" {
		t.Fatalf("--latest: %v %v", err, got)
	}
	h, _ := os.ReadFile(filepath.Join(state, WinPickedFile))
	key, err := os.ReadFile(filepath.Join(state, WinKeyFile))
	if err != nil || len(key) != 32 {
		t.Fatalf("hash key: %v len %d", err, len(key))
	}
	if strings.TrimSpace(string(h)) != WinHash(key, entry.MimeText, []byte("latest remote")) {
		t.Fatalf("echo guard not recorded: %q", h)
	}
	// Keyed, not a plain sha256 a short secret could be brute-forced from.
	plain := sha256.Sum256(append([]byte(entry.MimeText+"\x00"), "latest remote"...))
	if strings.Contains(string(h), hex.EncodeToString(plain[:])) || strings.Contains(string(h), "latest") {
		t.Fatal("last-picked holds an unkeyed hash or plaintext")
	}
	if fi, _ := os.Stat(filepath.Join(state, WinKeyFile)); runtime.GOOS != "windows" && fi.Mode().Perm() != 0o600 {
		t.Fatalf("hash.key mode %v", fi.Mode().Perm())
	}
	if _, err := Pick(self, old, state, pub); err != nil || got[1] != "old" {
		t.Fatalf("by id: %v %v", err, got)
	}
	for _, id := range []string{gone, "ffffffffffffffff"} {
		if _, err := Pick(self, id, state, pub); !errors.Is(err, ErrNotFound) || len(got) != 2 {
			t.Fatalf("pick %s: %v, published %v", id, err, got)
		}
	}
	if _, err := Pick(self, old, state, func(bool, []byte) error { return errors.New("busy") }); !errors.Is(err, ErrPublish) {
		t.Fatalf("publish failure: %v", err)
	}
	empty, _ := storeRig(t)
	if _, err := Pick(empty, "", state, pub); !errors.Is(err, ErrNotFound) {
		t.Fatalf("latest with no remote: %v", err)
	}
}

// rigWith returns a store view (origin "win") holding one remote text entry.
func rigWith(t *testing.T, text string) *store.Store {
	self, peer := storeRig(t)
	put(t, peer, entry.MimeText, []byte(text), time.Second, 300)
	return self
}

func TestPickRecordsEchoHash(t *testing.T) {
	e := newEnv(t)
	dir := t.TempDir()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	peer := &store.Store{Dir: dir, Origin: "peer", Self: id, Cap: entry.DefaultCap}
	self := &store.Store{Dir: dir, Origin: "self", Self: id, Cap: entry.DefaultCap}
	picked := []byte("from peer")
	got, err := peer.Write(entry.Entry{Created: time.Now().UnixMilli(), TTLs: 300, Mime: entry.MimeText, Data: picked})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Pick(self, got, e.state, func(bool, []byte) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if out := e.a.Offer(entry.MimeText, []byte("from peer")); out != Echo {
		t.Fatalf("agent saw the pick as %q, want echo", out)
	}
}
