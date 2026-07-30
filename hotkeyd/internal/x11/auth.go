package x11

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// X11 auth family constants (Xauth.h). Only the families hotkeyd's matcher
// cares about are named; every real entry poc015 measured on live sessions
// used FamilyLocal.
const (
	FamilyLocal uint16 = 256
	FamilyWild  uint16 = 65535
)

// XauthEntry is one record from an ~/.Xauthority file. Number is kept as the
// raw ASCII text the file stores it as (poc015 gotcha 2): comparing it
// against a binary int silently fails to match.
type XauthEntry struct {
	Family  uint16
	Address string
	Number  string
	Name    string
	Data    []byte
}

// ParseXauthority reads the binary Xauthority record format: repeated
// length-prefixed fields (family, address, number, name, data) until EOF. A
// clean EOF at a record boundary ends parsing successfully; an EOF in the
// middle of a record is a truncation error, never a silently short read.
func ParseXauthority(r io.Reader) ([]XauthEntry, error) {
	var entries []XauthEntry
	for {
		var family uint16
		if err := binary.Read(r, binary.BigEndian, &family); err != nil {
			if err == io.EOF {
				return entries, nil
			}
			return entries, fmt.Errorf("x11: Xauthority: truncated reading family of entry %d: %w", len(entries), err)
		}

		addr, err := readXauthField(r)
		if err != nil {
			return entries, fmt.Errorf("x11: Xauthority: truncated reading address of entry %d: %w", len(entries), err)
		}
		number, err := readXauthField(r)
		if err != nil {
			return entries, fmt.Errorf("x11: Xauthority: truncated reading number of entry %d: %w", len(entries), err)
		}
		name, err := readXauthField(r)
		if err != nil {
			return entries, fmt.Errorf("x11: Xauthority: truncated reading name of entry %d: %w", len(entries), err)
		}
		data, err := readXauthField(r)
		if err != nil {
			return entries, fmt.Errorf("x11: Xauthority: truncated reading data of entry %d: %w", len(entries), err)
		}

		entries = append(entries, XauthEntry{
			Family:  family,
			Address: string(addr),
			Number:  string(number),
			Name:    string(name),
			Data:    data,
		})
	}
}

// readXauthField reads one length-prefixed field: a big-endian uint16
// length followed by that many raw bytes.
func readXauthField(r io.Reader) ([]byte, error) {
	var length uint16
	if err := binary.Read(r, binary.BigEndian, &length); err != nil {
		return nil, err
	}
	buf := make([]byte, length)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

// ReadXauthorityFile reads and parses the Xauthority file at path (typically
// $XAUTHORITY or ~/.Xauthority).
func ReadXauthorityFile(path string) ([]XauthEntry, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("x11: opening Xauthority %s: %w", path, err)
	}
	defer f.Close()
	return ParseXauthority(f)
}

// DefaultXauthorityPath returns $XAUTHORITY if set, else ~/.Xauthority.
func DefaultXauthorityPath() (string, error) {
	if p := os.Getenv("XAUTHORITY"); p != "" {
		return p, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("x11: resolving home directory for Xauthority: %w", err)
	}
	return filepath.Join(home, ".Xauthority"), nil
}

// FindCookie locates the MIT-MAGIC-COOKIE-1 entry for (hostname, displayNum)
// among the parsed Xauthority entries. It tries three passes in order,
// mirroring poc015's measured real-world entries:
//
//  1. Exact: FamilyLocal, Address == hostname, Number == displayNum (as text).
//  2. Wild: FamilyLocal entries are skipped, FamilyWild entries match on
//     Number alone -- a Wild entry has no address to compare.
//  3. Relaxed: FamilyLocal, Number matches but Address does not -- the
//     hostname has drifted since the cookie was written (poc015 gotcha 1).
//     This still returns the cookie, but with a non-empty warning naming
//     both hostnames so the drift is diagnosable rather than silent.
func FindCookie(entries []XauthEntry, hostname string, displayNum int) (name string, data []byte, warning string, err error) {
	numText := fmt.Sprintf("%d", displayNum)

	// Pass 1: exact match.
	for _, e := range entries {
		if e.Family == FamilyLocal && e.Address == hostname && e.Number == numText {
			return e.Name, e.Data, "", nil
		}
	}

	// Pass 2: Wild family, matches on display number only.
	for _, e := range entries {
		if e.Family == FamilyWild && e.Number == numText {
			return e.Name, e.Data, "", nil
		}
	}

	// Pass 3: relaxed -- FamilyLocal with the right display number but a
	// different hostname. Degrade to a warning rather than a hard failure.
	for _, e := range entries {
		if e.Family == FamilyLocal && e.Number == numText && e.Address != hostname {
			warning = fmt.Sprintf(
				"x11: Xauthority hostname drift: cookie was written for %q, this host reports %q; using it anyway (relaxed match)",
				e.Address, hostname)
			return e.Name, e.Data, warning, nil
		}
	}

	return "", nil, "", fmt.Errorf("x11: no Xauthority cookie found for host %q display %d", hostname, displayNum)
}
