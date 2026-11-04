// Package crypt owns this device's age identity, the locally pinned
// recipient list, and entry encryption (sp039 Task 2).
//
// Recipients come only from the local recipients.txt — nothing in the
// shared folder can change who an entry is encrypted to. This device's own
// recipient is always added, so a host can read back what it wrote.
package crypt

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"filippo.io/age"
)

var (
	ErrExists       = errors.New("crypt: identity file already exists")
	ErrPerms        = errors.New("crypt: identity file readable by group or others")
	ErrBadIdentity  = errors.New("crypt: identity file holds no single X25519 identity")
	ErrBadRecipient = errors.New("crypt: not an age X25519 recipient")
	ErrNotForUs     = errors.New("crypt: entry not encrypted to this device")
	ErrTooLarge     = errors.New("crypt: plaintext over size limit")
)

// Keygen creates a new identity at path (mode 0600, parent 0700) and
// returns its public recipient. It never overwrites: an existing file is
// ErrExists and is left untouched.
func Keygen(path string) (string, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	id, err := age.GenerateX25519Identity()
	if err != nil {
		return "", err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, fs.ErrExist) {
		return "", fmt.Errorf("%w: %s", ErrExists, path)
	}
	if err != nil {
		return "", err
	}
	rcpt := id.Recipient().String()
	_, werr := fmt.Fprintf(f, "# created: %s\n# public key: %s\n%s\n",
		time.Now().Format(time.RFC3339), rcpt, id.String())
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		os.Remove(path)
		return "", werr
	}
	return rcpt, nil
}

// LoadIdentity reads the identity at path, refusing a file whose POSIX mode
// lets group or others read it. On Windows mode bits do not describe access
// (ACLs do) and the check is skipped.
func LoadIdentity(path string) (*age.X25519Identity, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if runtime.GOOS != "windows" {
		st, err := f.Stat()
		if err != nil {
			return nil, err
		}
		if st.Mode().Perm()&0o077 != 0 {
			return nil, fmt.Errorf("%w: %s is %v, want 0600", ErrPerms, path, st.Mode().Perm())
		}
	}
	ids, err := age.ParseIdentities(f)
	if err != nil || len(ids) != 1 {
		return nil, fmt.Errorf("%w: %s", ErrBadIdentity, path)
	}
	id, ok := ids[0].(*age.X25519Identity)
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrBadIdentity, path)
	}
	return id, nil
}

func parseRecipient(s string) (*age.X25519Recipient, error) {
	r, err := age.ParseX25519Recipient(strings.TrimSpace(s))
	if err != nil {
		return nil, ErrBadRecipient
	}
	return r, nil
}

// ListRecipients returns the pinned recipient strings in file order. A
// missing file is an empty list; any line that does not parse is an error,
// so a corrupt file never silently encrypts to fewer peers.
func ListRecipients(path string) ([]string, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	sc := bufio.NewScanner(bytes.NewReader(b))
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if _, err := parseRecipient(line); err != nil {
			return nil, fmt.Errorf("%w: %s line %d", ErrBadRecipient, path, n)
		}
		out = append(out, line)
	}
	return out, sc.Err()
}

func LoadRecipients(path string) ([]*age.X25519Recipient, error) {
	list, err := ListRecipients(path)
	if err != nil {
		return nil, err
	}
	rs := make([]*age.X25519Recipient, 0, len(list))
	for _, s := range list {
		r, _ := parseRecipient(s) // validated by ListRecipients
		rs = append(rs, r)
	}
	return rs, nil
}

// AddRecipient pins s. Adding one already pinned is a no-op.
func AddRecipient(path, s string) error {
	r, err := parseRecipient(s)
	if err != nil {
		return err
	}
	list, err := ListRecipients(path)
	if err != nil {
		return err
	}
	for _, have := range list {
		if have == r.String() {
			return nil
		}
	}
	return writeRecipients(path, append(list, r.String()))
}

// RemoveRecipient unpins s and reports whether it was pinned.
func RemoveRecipient(path, s string) (bool, error) {
	list, err := ListRecipients(path)
	if err != nil {
		return false, err
	}
	want := strings.TrimSpace(s)
	kept := list[:0]
	for _, have := range list {
		if have != want {
			kept = append(kept, have)
		}
	}
	if len(kept) == len(list) {
		return false, nil
	}
	return true, writeRecipients(path, kept)
}

// writeRecipients replaces the file via temp + rename so a crash never
// leaves a half-written recipient list.
func writeRecipients(path string, list []string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	var b strings.Builder
	b.WriteString("# clipd pinned age recipients, one per line\n")
	for _, s := range list {
		b.WriteString(s + "\n")
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Encrypt encrypts plain to self plus every peer, deduplicated.
func Encrypt(plain []byte, self *age.X25519Identity, peers []*age.X25519Recipient) ([]byte, error) {
	seen := map[string]bool{}
	var rs []age.Recipient
	for _, r := range append([]*age.X25519Recipient{self.Recipient()}, peers...) {
		if !seen[r.String()] {
			seen[r.String()] = true
			rs = append(rs, r)
		}
	}
	var buf bytes.Buffer
	w, err := age.Encrypt(&buf, rs...)
	if err != nil {
		return nil, err
	}
	if _, err := w.Write(plain); err != nil {
		return nil, err
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Decrypt returns the plaintext of ct, reading at most max bytes of it: an
// entry larger than this host accepts is refused without being buffered.
func Decrypt(ct []byte, id *age.X25519Identity, max int) ([]byte, error) {
	r, err := age.Decrypt(bytes.NewReader(ct), id)
	var nomatch *age.NoIdentityMatchError
	if errors.As(err, &nomatch) {
		return nil, ErrNotForUs
	}
	if err != nil {
		return nil, fmt.Errorf("crypt: decrypt: %w", err)
	}
	plain, err := io.ReadAll(io.LimitReader(r, int64(max)+1))
	if err != nil {
		return nil, fmt.Errorf("crypt: decrypt: %w", err)
	}
	if len(plain) > max {
		return nil, ErrTooLarge
	}
	return plain, nil
}
