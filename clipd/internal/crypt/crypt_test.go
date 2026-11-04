package crypt

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"filippo.io/age"

	"clipd/internal/entry"
)

func newIdentity(t *testing.T) *age.X25519Identity {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestKeygenWritesPrivateFileAndRefusesOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cfg", "identity.txt")
	rcpt, err := Keygen(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(rcpt, "age1") {
		t.Fatalf("recipient %q", rcpt)
	}
	if runtime.GOOS != "windows" {
		st, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o600 {
			t.Fatalf("mode %v, want 0600", st.Mode().Perm())
		}
	}
	id, err := LoadIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	if id.Recipient().String() != rcpt {
		t.Fatalf("loaded identity does not match printed recipient")
	}
	before, _ := os.ReadFile(path)
	if _, err := Keygen(path); !errors.Is(err, ErrExists) {
		t.Fatalf("second keygen: want ErrExists, got %v", err)
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(before, after) {
		t.Fatal("second keygen changed the identity file")
	}
}

func TestIdentityPermsRefused(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX mode bits do not apply")
	}
	path := filepath.Join(t.TempDir(), "identity.txt")
	if _, err := Keygen(path); err != nil {
		t.Fatal(err)
	}
	for _, mode := range []os.FileMode{0o640, 0o604, 0o644} {
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadIdentity(path); !errors.Is(err, ErrPerms) {
			t.Fatalf("mode %v: want ErrPerms, got %v", mode, err)
		}
	}
	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadIdentity(path); err != nil {
		t.Fatalf("0400 should load: %v", err)
	}
}

func TestRecipientsRejectsGarbage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "recipients.txt")
	other := newIdentity(t).Recipient().String()
	for _, bad := range []string{"", "age1", "hello", "AGE-SECRET-KEY-1ABC", other + "x", "ssh-ed25519 AAAA"} {
		if err := AddRecipient(path, bad); !errors.Is(err, ErrBadRecipient) {
			t.Fatalf("%q: want ErrBadRecipient, got %v", bad, err)
		}
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("rejected recipients must not create the file")
	}
	if err := AddRecipient(path, other); err != nil {
		t.Fatal(err)
	}
	if err := AddRecipient(path, "  "+other+"\n"); err != nil {
		t.Fatal(err)
	}
	list, err := ListRecipients(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0] != other {
		t.Fatalf("list %v, want exactly [%s]", list, other)
	}
	removed, err := RemoveRecipient(path, other)
	if err != nil || !removed {
		t.Fatalf("rm: %v %v", removed, err)
	}
	removed, err = RemoveRecipient(path, other)
	if err != nil || removed {
		t.Fatalf("second rm: %v %v", removed, err)
	}
	if list, _ := ListRecipients(path); len(list) != 0 {
		t.Fatalf("list after rm %v", list)
	}
}

// A hand-edited recipients.txt with junk must fail loudly, not silently
// encrypt to fewer peers than the user thinks.
func TestLoadRecipientsRejectsCorruptFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "recipients.txt")
	ok := newIdentity(t).Recipient().String()
	os.WriteFile(path, []byte("# peers\n"+ok+"\nnot-a-key\n"), 0o600)
	if _, err := LoadRecipients(path); !errors.Is(err, ErrBadRecipient) {
		t.Fatalf("want ErrBadRecipient, got %v", err)
	}
	if rs, err := LoadRecipients(filepath.Join(t.TempDir(), "absent")); err != nil || len(rs) != 0 {
		t.Fatalf("missing file: %v %v", rs, err)
	}
}

func TestEncryptIncludesSelfAndPeers(t *testing.T) {
	self, peer, stranger := newIdentity(t), newIdentity(t), newIdentity(t)
	ct, err := Encrypt([]byte("payload"), self, []*age.X25519Recipient{peer.Recipient()})
	if err != nil {
		t.Fatal(err)
	}
	for name, id := range map[string]*age.X25519Identity{"self": self, "peer": peer} {
		pt, err := Decrypt(ct, id, 1024)
		if err != nil || string(pt) != "payload" {
			t.Fatalf("%s: %q %v", name, pt, err)
		}
	}
	if _, err := Decrypt(ct, stranger, 1024); !errors.Is(err, ErrNotForUs) {
		t.Fatalf("stranger: want ErrNotForUs, got %v", err)
	}
	// Self listed in recipients too: no duplicate stanza error.
	if _, err := Encrypt([]byte("p"), self, []*age.X25519Recipient{self.Recipient(), peer.Recipient()}); err != nil {
		t.Fatal(err)
	}
}

func TestDecryptForeignKeyIsErrNotForUs(t *testing.T) {
	writer, reader := newIdentity(t), newIdentity(t)
	ct, err := Encrypt([]byte("not yours"), writer, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Decrypt(ct, reader, 1024); !errors.Is(err, ErrNotForUs) {
		t.Fatalf("want ErrNotForUs, got %v", err)
	}
	for _, junk := range [][]byte{nil, []byte("garbage"), ct[:len(ct)/2]} {
		if _, err := Decrypt(junk, writer, 1024); err == nil {
			t.Fatalf("junk %d bytes decrypted", len(junk))
		}
	}
}

func TestDecryptRefusesOversizePlaintext(t *testing.T) {
	id := newIdentity(t)
	ct, err := Encrypt(bytes.Repeat([]byte("a"), 100), id, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Decrypt(ct, id, 100); err != nil {
		t.Fatalf("exactly max: %v", err)
	}
	if _, err := Decrypt(ct, id, 99); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("want ErrTooLarge, got %v", err)
	}
}

// The full sp039 write/read path: entry.Encode -> Encrypt -> Decrypt ->
// entry.Decode, byte-exact for text with NUL/CRLF/non-ASCII and for PNG.
func TestEntryPipelineRoundTrip(t *testing.T) {
	self, peer := newIdentity(t), newIdentity(t)
	for _, c := range []struct{ mime, data string }{
		{entry.MimeText, "Příliš žluťoučký\x00\r\nkůň"},
		{entry.MimePNG, "\x89PNG\r\n\x1a\n\x00\xff"},
	} {
		plain, err := entry.Encode(entry.Entry{Origin: "a", Created: 1, TTLs: 300, Mime: c.mime, Data: []byte(c.data)}, entry.DefaultCap)
		if err != nil {
			t.Fatal(err)
		}
		ct, err := Encrypt(plain, self, []*age.X25519Recipient{peer.Recipient()})
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(ct, []byte(c.data)) {
			t.Fatal("ciphertext contains plaintext")
		}
		got, err := Decrypt(ct, peer, entry.MaxEncoded(entry.DefaultCap))
		if err != nil {
			t.Fatal(err)
		}
		e, err := entry.Decode(got, entry.DefaultCap)
		if err != nil {
			t.Fatal(err)
		}
		if string(e.Data) != c.data || e.Mime != c.mime {
			t.Fatalf("%s changed: %q", c.mime, e.Data)
		}
	}
}
