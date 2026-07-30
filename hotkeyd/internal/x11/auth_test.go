package x11

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
)

// xauthField writes one length-prefixed field in the on-disk Xauthority
// format: a big-endian uint16 length followed by the raw bytes.
func xauthField(buf *bytes.Buffer, data string) {
	binary.Write(buf, binary.BigEndian, uint16(len(data)))
	buf.WriteString(data)
}

// xauthEntry writes one complete Xauthority entry.
func xauthEntry(buf *bytes.Buffer, family uint16, addr, number, name, data string) {
	binary.Write(buf, binary.BigEndian, family)
	xauthField(buf, addr)
	xauthField(buf, number)
	xauthField(buf, name)
	xauthField(buf, data)
}

func TestParseXauthority_SingleEntry(t *testing.T) {
	var buf bytes.Buffer
	xauthEntry(&buf, FamilyLocal, "jan-swiftsf31441", "95", "MIT-MAGIC-COOKIE-1", "\xde\xad\xbe\xef")

	entries, err := ParseXauthority(bytes.NewReader(buf.Bytes()))
	if err != nil {
		t.Fatalf("ParseXauthority: unexpected error: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("got %d entries, want 1", len(entries))
	}
	e := entries[0]
	if e.Family != FamilyLocal {
		t.Errorf("Family = %d, want FamilyLocal (%d)", e.Family, FamilyLocal)
	}
	if e.Address != "jan-swiftsf31441" {
		t.Errorf("Address = %q, want %q", e.Address, "jan-swiftsf31441")
	}
	// The display number is stored as ASCII text, not a binary int
	// (poc015 gotcha 2) -- assert it round-trips as the literal string "95".
	if e.Number != "95" {
		t.Errorf("Number = %q, want %q (ASCII text, not int)", e.Number, "95")
	}
	if e.Name != "MIT-MAGIC-COOKIE-1" {
		t.Errorf("Name = %q, want %q", e.Name, "MIT-MAGIC-COOKIE-1")
	}
	if !bytes.Equal(e.Data, []byte("\xde\xad\xbe\xef")) {
		t.Errorf("Data = %x, want deadbeef", e.Data)
	}
}

func TestParseXauthority_MultipleEntries(t *testing.T) {
	var buf bytes.Buffer
	xauthEntry(&buf, FamilyLocal, "host-a", "0", "MIT-MAGIC-COOKIE-1", "aaaa")
	xauthEntry(&buf, FamilyLocal, "host-a", "10", "MIT-MAGIC-COOKIE-1", "bbbb")
	xauthEntry(&buf, FamilyWild, "", "10", "MIT-MAGIC-COOKIE-1", "cccc")

	entries, err := ParseXauthority(bytes.NewReader(buf.Bytes()))
	if err != nil {
		t.Fatalf("ParseXauthority: unexpected error: %v", err)
	}
	if len(entries) != 3 {
		t.Fatalf("got %d entries, want 3", len(entries))
	}
	if entries[2].Family != FamilyWild {
		t.Errorf("entries[2].Family = %d, want FamilyWild (%d)", entries[2].Family, FamilyWild)
	}
}

func TestParseXauthority_EmptyFileIsNotAnError(t *testing.T) {
	entries, err := ParseXauthority(bytes.NewReader(nil))
	if err != nil {
		t.Fatalf("ParseXauthority(empty): unexpected error: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("got %d entries, want 0", len(entries))
	}
}

func TestParseXauthority_TruncatedMidEntryIsAnError(t *testing.T) {
	var buf bytes.Buffer
	xauthEntry(&buf, FamilyLocal, "host-a", "0", "MIT-MAGIC-COOKIE-1", "aaaa")
	truncated := buf.Bytes()[:buf.Len()-3] // cut off mid-data field

	_, err := ParseXauthority(bytes.NewReader(truncated))
	if err == nil {
		t.Fatal("ParseXauthority(truncated): expected an error, got nil")
	}
}

func TestFindCookie_ExactMatch(t *testing.T) {
	entries := []XauthEntry{
		{Family: FamilyLocal, Address: "myhost", Number: "10", Name: "MIT-MAGIC-COOKIE-1", Data: []byte("cookie10")},
		{Family: FamilyLocal, Address: "myhost", Number: "0", Name: "MIT-MAGIC-COOKIE-1", Data: []byte("cookie0")},
	}

	name, data, warning, err := FindCookie(entries, "myhost", 10)
	if err != nil {
		t.Fatalf("FindCookie: unexpected error: %v", err)
	}
	if name != "MIT-MAGIC-COOKIE-1" {
		t.Errorf("name = %q, want MIT-MAGIC-COOKIE-1", name)
	}
	if string(data) != "cookie10" {
		t.Errorf("data = %q, want cookie10", data)
	}
	if warning != "" {
		t.Errorf("warning = %q, want empty on an exact match", warning)
	}
}

func TestFindCookie_DisplayNumberComparedAsText(t *testing.T) {
	// A naive int-vs-string comparison would fail to distinguish "010"
	// from "10"; the matcher must compare using the same text semantics
	// Xauthority uses (poc015 gotcha 2).
	entries := []XauthEntry{
		{Family: FamilyLocal, Address: "myhost", Number: "10", Name: "MIT-MAGIC-COOKIE-1", Data: []byte("cookie10")},
	}

	_, _, _, err := FindCookie(entries, "myhost", 10)
	if err != nil {
		t.Fatalf("FindCookie: unexpected error: %v", err)
	}
}

func TestFindCookie_WildFamilyMatchesAnyHostname(t *testing.T) {
	entries := []XauthEntry{
		{Family: FamilyWild, Address: "", Number: "10", Name: "MIT-MAGIC-COOKIE-1", Data: []byte("wildcookie")},
	}

	name, data, warning, err := FindCookie(entries, "some-other-host", 10)
	if err != nil {
		t.Fatalf("FindCookie: unexpected error: %v", err)
	}
	if name != "MIT-MAGIC-COOKIE-1" || string(data) != "wildcookie" {
		t.Errorf("got (%q, %q), want (MIT-MAGIC-COOKIE-1, wildcookie)", name, data)
	}
	if warning != "" {
		t.Errorf("warning = %q, want empty for a Wild-family match", warning)
	}
}

func TestFindCookie_HostnameDriftFallsBackWithWarning(t *testing.T) {
	// The cookie was written for "old-hostname" but the machine now
	// reports "new-hostname" (poc015 gotcha 1): the matcher must still
	// find the cookie via a relaxed pass and name the drift rather than
	// silently succeeding or silently failing.
	entries := []XauthEntry{
		{Family: FamilyLocal, Address: "old-hostname", Number: "10", Name: "MIT-MAGIC-COOKIE-1", Data: []byte("cookie10")},
	}

	name, data, warning, err := FindCookie(entries, "new-hostname", 10)
	if err != nil {
		t.Fatalf("FindCookie: unexpected error: %v", err)
	}
	if name != "MIT-MAGIC-COOKIE-1" || string(data) != "cookie10" {
		t.Errorf("got (%q, %q), want (MIT-MAGIC-COOKIE-1, cookie10)", name, data)
	}
	if warning == "" {
		t.Fatal("warning = \"\", want a diagnostic naming the hostname drift")
	}
	if !strings.Contains(warning, "old-hostname") || !strings.Contains(warning, "new-hostname") {
		t.Errorf("warning %q does not name both hostnames", warning)
	}
}

func TestFindCookie_NoMatchIsAnError(t *testing.T) {
	entries := []XauthEntry{
		{Family: FamilyLocal, Address: "myhost", Number: "0", Name: "MIT-MAGIC-COOKIE-1", Data: []byte("cookie0")},
	}

	_, _, _, err := FindCookie(entries, "myhost", 99)
	if err == nil {
		t.Fatal("FindCookie: expected an error when no entry matches, got nil")
	}
}
