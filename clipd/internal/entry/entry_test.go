package entry

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func textEntry(data []byte) Entry {
	return Entry{V: Version, Origin: "wsl-kwi3", Created: 1762160000000, TTLs: DefaultTTL, Mime: MimeText, Data: data}
}

// Non-ASCII, an embedded NUL and CRLF are exactly the bytes a careless
// string/line-oriented codec would mangle; all must survive unchanged.
func TestRoundTripUnicodeText(t *testing.T) {
	in := []byte("heslo: Žluťoučký kůň 🐎\x00tail\r\nnext line\r\n")
	b, err := Encode(textEntry(in), DefaultCap)
	if err != nil {
		t.Fatal(err)
	}
	out, err := Decode(b, DefaultCap)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out.Data, in) {
		t.Fatalf("data changed:\n got %q\nwant %q", out.Data, in)
	}
	if out.Origin != "wsl-kwi3" || out.Created != 1762160000000 || out.TTLs != DefaultTTL || out.Mime != MimeText {
		t.Fatalf("metadata changed: %+v", out)
	}
}

func TestRoundTripPNGBytes(t *testing.T) {
	png := []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff\xfe\x00\x80")
	e := textEntry(png)
	e.Mime = MimePNG
	b, err := Encode(e, DefaultCap)
	if err != nil {
		t.Fatal(err)
	}
	out, err := Decode(b, DefaultCap)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out.Data, png) || out.Mime != MimePNG {
		t.Fatalf("png changed: %q %s", out.Data, out.Mime)
	}
}

func TestCapBoundary(t *testing.T) {
	const cap = 64
	if _, err := Encode(textEntry(bytes.Repeat([]byte("a"), cap)), cap); err != nil {
		t.Fatalf("exactly cap refused: %v", err)
	}
	if _, err := Encode(textEntry(bytes.Repeat([]byte("a"), cap+1)), cap); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("cap+1: want ErrTooLarge, got %v", err)
	}
	if _, err := Encode(textEntry([]byte("x")), cap); err != nil {
		t.Fatalf("1 byte refused: %v", err)
	}
	if _, err := Encode(textEntry(nil), cap); !errors.Is(err, ErrEmpty) {
		t.Fatalf("empty: want ErrEmpty, got %v", err)
	}
	// A peer with a bigger cap must not be able to push past ours.
	big, err := Encode(textEntry(bytes.Repeat([]byte("a"), cap+1)), cap*2)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Decode(big, cap); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("decode cap+1: want ErrTooLarge, got %v", err)
	}
}

func TestHeartbeatHasNoData(t *testing.T) {
	b, err := Encode(Entry{V: Version, Origin: "win", Created: 1, TTLs: DefaultTTL, Mime: MimeHeartbeat}, DefaultCap)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Decode(b, DefaultCap); err != nil {
		t.Fatal(err)
	}
}

func TestDecodeRejectsUnknownVersion(t *testing.T) {
	b := []byte(`{"v":2,"origin":"x","created":1,"ttl_s":300,"mime":"text/plain;charset=utf-8","data":"YQ=="}`)
	if _, err := Decode(b, DefaultCap); !errors.Is(err, ErrVersion) {
		t.Fatalf("want ErrVersion, got %v", err)
	}
}

func TestDecodeRejectsUnknownMime(t *testing.T) {
	b := []byte(`{"v":1,"origin":"x","created":1,"ttl_s":300,"mime":"text/html","data":"YQ=="}`)
	if _, err := Decode(b, DefaultCap); !errors.Is(err, ErrMime) {
		t.Fatalf("want ErrMime, got %v", err)
	}
	e := textEntry([]byte("a"))
	e.Mime = "application/x-sh"
	if _, err := Encode(e, DefaultCap); !errors.Is(err, ErrMime) {
		t.Fatalf("encode: want ErrMime, got %v", err)
	}
}

func TestDecodeRejectsGarbage(t *testing.T) {
	for _, in := range []string{"", "{", "null", `{"v":1}`} {
		if _, err := Decode([]byte(in), DefaultCap); err == nil {
			t.Fatalf("%q decoded without error", in)
		}
	}
}

// Errors must never carry payload bytes into logs (sp039 anti-pattern).
func TestErrorsDoNotLeakPayload(t *testing.T) {
	secret := "hunter2-secret"
	e := textEntry([]byte(secret))
	e.Mime = "bogus"
	_, err := Encode(e, DefaultCap)
	if err == nil || strings.Contains(err.Error(), secret) {
		t.Fatalf("err %v", err)
	}
	_, err = Encode(textEntry([]byte(secret)), 3)
	if err == nil || strings.Contains(err.Error(), secret) {
		t.Fatalf("err %v", err)
	}
}
